# Hands-on — On-call drill: diagnose a broken app with metrics

The previous monitoring hands-on built things up component by component: Prometheus here, Grafana there, an alert rule in a file. This one runs in the opposite direction. You are handed a running multi-service app that someone broke without telling you what they broke. Your job is to use the metrics in front of you to find out *what is wrong*, *which service is at fault*, and *why*, then prove the fix landed.

Three scenarios are pre-wired (S1, S2, S3). Each one is a different shape of failure — a slow downstream, a memory leak, a saturated worker pool — and each one leaves a different signature in the metrics. The walkthrough takes you through S1 step by step. S2 and S3 are for self-practice. The "what was actually broken" answers live at the very bottom of this README, under **Scenario solutions**. Don't peek before working through them.

This README is the **full reference**. It explains every PromQL expression in the dashboards, every misconception the diagnostic methodology tends to hit, and the troubleshooting steps for the stack itself. The shorter bootcamp file (`week-14/monitoring/hands-on/09_broken_app_diagnosis.md`) walks the demo end-to-end with less commentary.

---

## What is in the stack

| Service | Port | Role |
|---|---|---|
| `gateway` | 8080 | Public entry point. Routes calls to the three backends, generates its own load against itself, and emits `downstream_request_duration_seconds_*` — the client-side view of every backend call. |
| `orders` | (internal) | Backend. Bounded concurrency pool. Exposes `orders_inflight_requests` and `orders_pool_capacity`. |
| `users` | (internal) | Backend. Memory-capped at 192 MiB so the scenario-2 leak ends in `OOMKilled`. Exposes `users_leaked_bytes`. |
| `payments` | (internal) | Backend. Moderate latency baseline; scenario 1 stacks a 2–3 s sleep on top. |
| `prometheus` | 9090 | Scrapes every container every 5 s. |
| `grafana` | 3000 | Two pre-provisioned dashboards: **Broken App — RED** and **Broken App — Resources**. login `admin / admin`. |
| `node-exporter` | (internal) | Host-level CPU / memory / filesystem metrics. |

Each Python service exposes its own OS-level resource metrics for free, via the standard `prometheus_client` library: `process_cpu_seconds_total`, `process_resident_memory_bytes`, `process_start_time_seconds`. They carry the same `service` label every other metric uses, so they aggregate cleanly on the dashboard. The Resources dashboard uses them as the *infra view from within the process*. We deliberately don't run cAdvisor here — on Docker Desktop on Windows, its `name` label often comes through empty, which would break the panels. The process metrics are portable and give the same answers for our purposes.

The four application containers are built from the **same image**. `SERVICE_NAME` decides what role each container plays — the same `app.py` branches on that variable to register the right routes and metrics. This keeps the demo to a single Dockerfile and a single image build.

### File layout

```
broken-app/
├── app/
│   ├── Dockerfile
│   ├── app.py            ← gateway + 3 backends, branches on SERVICE_NAME
│   └── requirements.txt
├── docker-compose.yml
├── prometheus.yml
└── grafana/
    ├── provisioning/
    │   ├── datasources/prometheus.yml
    │   └── dashboards/provider.yml
    └── dashboards/
        ├── red.json
        └── resources.json
```

### Scenario control plane

```bash
# Trigger a scenario (only the gateway needs to be addressed):
curl -X POST http://localhost:8080/control/scenario/1
curl -X POST http://localhost:8080/control/scenario/2
curl -X POST http://localhost:8080/control/scenario/3

# Clear everything:
curl -X POST http://localhost:8080/control/reset
```

The gateway fans the request out to all three backends. Each backend keeps its own scenario flag and decides whether to apply the failure to its own work. Two side effects:

- Scenario 3 resizes the `orders` semaphore from 50 down to 3.
- Resetting from scenario 2 also clears the in-process leak buffer in `users` and zeroes the `users_leaked_bytes` gauge.

---

## Prerequisites

- Hands-on 01–08 of week 14. You should already be comfortable with `rate()`, `histogram_quantile()`, label selectors, and reading a Grafana time-series panel.
- Docker and Docker Compose. The stack is sized to run comfortably on a laptop — total RAM at idle is ~600 MiB.
- A shell with `curl`. PowerShell on Windows 10+ works; `curl.exe` is bundled.

---

## Bringing the stack up

```bash
cd monitoring/hands-on/broken-app
docker compose build         # builds the single broken-app:latest image
docker compose up -d
docker compose ps            # all 8 services Up
```

Open the three UIs in three tabs:

- `http://localhost:9090/targets` — confirm every Prometheus target is `UP`. If any one of `gateway / orders / users / payments` is `DOWN`, the image hasn't started yet; wait ~10 s and refresh.
- `http://localhost:3000` (admin / admin) — open the **Broken App — RED** dashboard. Within ~30 s you should see live data on every panel.
- `http://localhost:8080/metrics` — the gateway's raw metrics. Skim it once so you know what the application is actually emitting.

Leave the load generator running. The gateway hits its own `/api/checkout`, `/api/orders` and `/api/users` endpoints in the background, so the dashboards always have fresh data even with no manual traffic.

### Establishing the baseline

Spend **five minutes** reading the RED dashboard in steady state. Note down, roughly:

- Request rate by service — `gateway` should sit around 10 r/s; each backend somewhere between 2 and 7 r/s (the gateway's `/api/checkout` calls both `orders` and `payments` per request).
- Error rate by service — the baseline rules-of-thumb baked into `backend_work()`: orders ~1 %, users ~1 %, payments ~3 %.
- p99 latency by service — orders and users under ~150 ms, payments around 700 ms (because its baseline mean is 150 ms, but the histogram is fed an exponential distribution so the tail is long).
- Gateway downstream view — the `payments` line is the highest, matching the upstream observation.

This baseline matters. Without it, "p99 is 500 ms" is meaningless — is that normal or anomalous? The first thing every on-call playbook in production says is *know what good looks like*.

---

## The diagnostic methodology

This hands-on teaches a single, repeatable diagnostic loop. The same loop works whether you are paged about a real outage or asked "why is this app slow" in a code review.

```
1. RED triage      → Which service deviates from baseline? On rate, errors, or duration?
2. Drill in        → Which endpoint inside that service? Which percentile? Which label?
3. Cross-correlate → Is the service "sick" (CPU/RAM/IO problem) or is its dependency sick?
4. Confirm         → Use application-emitted metrics to pin the exact failing component.
5. Prove the fix   → Watch the same metric return to baseline, account for window lag.
```

This is the order. Skipping straight to step 4 ("check downstream") before you've confirmed the symptom is observable is how you spend twenty minutes investigating the wrong service.

---

## Walkthrough — Scenario 1

Trigger it:

```bash
curl -X POST http://localhost:8080/control/scenario/1
```

The response:

```json
{"scenario":"1","backends":{"orders":{"service":"orders","scenario":"1"},"users":{"service":"users","scenario":"1"},"payments":{"service":"payments","scenario":"1"}}}
```

All three backends are told the scenario id is "1". Only `payments` actually does something with it (it injects 2–3 s of extra latency on its handler); the other two see the flag and ignore it. From the student's point of view, they don't know any of this — they only see that "something" changed.

### Step 1 — RED triage (~60 s)

Open **Broken App — RED**. Within one or two scrape intervals (5–10 s) you should see:

- **Request rate by service** — gateway holds steady around 10 r/s, but each downstream call now takes much longer, so the load-generator's natural rate may dip slightly. This panel does **not** point at a culprit. That's important: rate-based panels are dominated by the load mix, not by where the slowness is.
- **Error rate by service** — essentially unchanged. Payments still hovers near 3 %. Errors do not pinpoint a latency problem.
- **p99 request duration by service** — `payments` jumps from ~700 ms to **>3 s**. `gateway` jumps too, but somewhat less because not every gateway call goes through payments (only `/api/checkout` does).
- **Gateway view: p99 downstream call duration** — `payments` shoots up above 3 s; `orders` and `users` are flat.

Triage verdict in two minutes flat: *duration is the broken signal; the gateway's downstream view says payments is the culprit*.

Two takeaways:

1. **A latency problem shows up first on the duration panel, not on rate or error panels.** This is why the RED methodology insists on having all three — rate alone misses latency-only incidents (the most common kind), and error-only alerts miss "everything is slow but technically not failing".
2. **The gateway's client-side histogram is the single most useful panel in a microservice stack.** It tells you *which downstream call* is slow without you having to open eight separate dashboards. Production systems with twenty backends benefit even more.

### Step 2 — Drill into payments (~60 s)

You suspect payments. Two things to confirm:

- Is *every* payments request slow, or only a subset?
- Is this a real latency problem or just histogram-bucket-resolution noise?

In Prometheus (`http://localhost:9090/graph`), run:

```promql
histogram_quantile(0.50, sum by (le) (rate(http_request_duration_seconds_bucket{service="payments"}[2m])))
histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{service="payments"}[2m])))
histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{service="payments"}[2m])))
```

You will see all three percentiles elevated. p50 around 2 s, p95 and p99 around 3.5 s. **This is the signature of an across-the-board slowdown, not a tail problem.** A tail problem would show p50 normal, p99 very high. When p50 itself has moved, every request is slower — usually because of a single shared dependency or shared bottleneck.

Now check whether the slowness is on every endpoint of the service or just one:

```promql
histogram_quantile(0.95, sum by (le, endpoint) (rate(http_request_duration_seconds_bucket{service="payments"}[2m])))
```

Only one endpoint exists on the payments service (`/api/payments`), so the breakdown confirms what we already know. In a real service with five endpoints, this is where you'd find that only one endpoint is affected — sometimes a single endpoint is broken while every other one is fine.

### Step 3 — Cross-correlate with resources (~60 s)

Open **Broken App — Resources**.

- **Process CPU per service** — `payments` is essentially idle. Same as baseline.
- **Process RSS per service** — `payments` is flat at ~40 MiB. Same as baseline.

This is the moment that rules out a class of explanations. If payments were CPU-pinned, you would see its CPU usage at or near 1 core. If it had a memory problem, RSS would be climbing. Neither is happening.

**Conclusion: payments itself is healthy. The slowness is artificial — either an injected sleep, a downstream dependency that payments calls, or a network problem.** In this stack payments has no downstream dependency, so the candidates collapse to *the application is choosing to sleep*.

### Step 4 — Confirm with application metrics (~30 s)

The gateway's client histogram is the same payment-call timing seen from the caller's side. If gateway-side p99 and payments-side p99 are equal, the latency is being added by *the payments process itself*, not by network or by the gateway. If gateway-side p99 was much higher than payments-side p99, you'd be looking at a network or a downstream-of-payments problem.

Run:

```promql
histogram_quantile(0.99, sum by (le) (rate(downstream_request_duration_seconds_bucket{downstream="payments"}[2m])))
histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{service="payments"}[2m])))
```

The two values should be within ~50 ms of each other — they are the same handler timed twice, once from outside and once from inside. **That tight agreement is the smoking gun: payments is adding the latency itself.**

This is how the application's own custom metrics close the diagnostic loop. Infrastructure metrics told you the process isn't suffering. The downstream histogram on the *caller* combined with the duration histogram on the *callee* told you the latency is being created inside the callee.

### Step 5 — Apply the fix and watch baseline return (~90 s)

Clear the scenario:

```bash
curl -X POST http://localhost:8080/control/reset
```

The payments handler immediately stops injecting sleep. **But the p99 panel does not snap back instantly.** It takes about 2 minutes for the panel to return to baseline. Why?

Because the dashboard uses `rate(...[2m])` — a 2-minute rate window. Every sample inside that window contributes to the histogram quantile. Until the slow samples have aged out of the window, they still pull the p99 up. After exactly 2 minutes the last slow sample is outside the window and you are back to baseline.

This **window-lag** is one of the most common operational surprises. A fix lands, the team can't see it in the dashboard, panic sets in, someone rolls back. Knowing your rate windows means knowing how long to wait before declaring a fix bad. In production with `[5m]` windows, that wait is five minutes. With `[10m]` windows, ten.

---

## Self-practice — Scenario 2

Trigger:

```bash
curl -X POST http://localhost:8080/control/scenario/2
```

Walk the methodology yourself without scrolling to the solution. Track these on paper as you go:

1. Open **Broken App — RED**. Which signal (rate / errors / duration) deviates from baseline? On which service?
2. Open **Broken App — Resources**. What do you see on container CPU? On container memory (RSS)?
3. Are there any container restarts visible on the **Container uptime** panel? When?
4. Is there an application-emitted metric you can use to confirm the cause?

Reset and verify recovery:

```bash
curl -X POST http://localhost:8080/control/reset
```

Watch the `users` service come back up if it had been OOMKilled — `users_leaked_bytes` should be `0` after reset.

## Self-practice — Scenario 3

Trigger:

```bash
curl -X POST http://localhost:8080/control/scenario/3
```

Same methodology, different signature. Pay attention to:

1. RED — what happens to **request rate** this time? (Hint: it doesn't stay flat.)
2. Resources — is anything pegged?
3. Open the **Orders pool: in-flight vs capacity** panel. What's the relationship between the two lines?
4. What does p99 look like on `gateway`'s `/api/orders`? On `payments`'s `/api/payments`?

Reset:

```bash
curl -X POST http://localhost:8080/control/reset
```

---

## How to read each metric type in this stack

The three scenarios deliberately hit three different metric types so the methodology generalises. Keep this table at hand when you start writing your own metrics for the lab.

| Metric type | What it tells you | Example here | When it fails you |
|---|---|---|---|
| Counter (`*_total`) | "How many of X happened?" Always combined with `rate()` to get per-second rates. | `http_requests_total`, `downstream_request_errors_total` | Counters don't tell you about **right now**, only "over the last window". On a fast-evolving incident, your rate window may smooth out a real spike. |
| Histogram (`*_bucket`) | "How is the distribution of X shaped?" Use `histogram_quantile` with `sum by (le, ...)`. | `http_request_duration_seconds_bucket`, `downstream_request_duration_seconds_bucket` | Resolution is capped by your bucket boundaries. A request that takes 8 s falls into the `+Inf` bucket if your largest finite bucket is 5 s — quantile estimation breaks. Always include enough headroom in your buckets. |
| Gauge | "What is X right now?" No `rate()`, no aggregation needed for the value itself. | `orders_inflight_requests`, `orders_pool_capacity`, `users_leaked_bytes`, `process_resident_memory_bytes` | Gauges don't preserve history between samples. A spike that peaks between two scrapes is invisible. If you need spikes, expose a max-since-last-scrape companion. |

The unifying principle: **a counter answers "how many", a histogram answers "how were they distributed", a gauge answers "where is it now"**.

---

## Common misconceptions

**"Errors and latency are the same signal."** No. Latency-only incidents (S1, S3) leave the error counter alone for as long as the application doesn't time out. If you only alert on errors, you miss them.

**"If the RED dashboard is green, the service is healthy."** Only if your RED dashboard *covers every meaningful endpoint label*. If you accidentally drop the `endpoint` label in the histogram and bucket all your requests together, a single broken endpoint can be averaged into invisibility. Always start with the most granular labels you can afford to store.

**"`rate()` over a long window is more accurate."** It's more *stable*, not more *accurate*. Longer windows respond more slowly to changes. A 1-minute window detects an incident in ~1 minute and clears in ~1 minute. A 10-minute window does both in ~10 minutes. Pick the window for the dashboard's job: alerts use short windows, capacity planning charts use long ones.

**"Memory pressure shows up on the application's metrics."** Sometimes. A pure leak (S2) is invisible to *custom* application metrics — your business code has no idea that bytes are being held in some out-of-the-way buffer. But every `prometheus_client`-instrumented process exports `process_resident_memory_bytes` for free, and that *is* the OS-level RSS view. Production apps should also expose GC / heap metrics if they have a GC; cAdvisor or kube-state-metrics is the ground truth at the container/pod level. The point is to have *some* metric that comes from outside the application's own bookkeeping.

**"Saturation always means errors."** No. The classic saturation signature is **duration up, errors mostly flat**. Errors only appear at the boundary — when a queue is *so* full that callers time out waiting. You'll see this in S3.

**"The fix didn't work because the dashboard didn't react."** Almost always wrong. Look at the rate window of the panel; the fix usually landed and the panel is lagging.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `docker compose up` fails with port-already-in-use on 8080 | Another app on your machine is on 8080. The realistic-scenario hands-on also uses 8080. | Stop the other stack, or change the gateway port mapping in `docker-compose.yml`. |
| Grafana shows "No data" on every panel | Datasource UID mismatch, or Prometheus is still warming up. | Hard-refresh after 60 s. If still empty, check the datasource provisioning file's `uid` is `prometheus-main`. |
| The **Process CPU / RSS** panels are empty | Backend services haven't been scraped yet, or label mismatch in the panel selector. | Confirm targets are `UP` in Prometheus. The panels use `service=~"gateway\|orders\|users\|payments"` — this label is set in `prometheus.yml`, not by the application. |
| Scenario 2 never OOMs the `users` container | The container restarted (because we set `restart: unless-stopped`) and is back to baseline memory. | Look at the **Container uptime** panel — uptime resets each time it OOMs. Wait for another ~30 s of traffic and it will OOM again. |
| Scenario 3 doesn't seem to break anything | Pool was already restored, or load generator hasn't pushed enough load yet. | Wait ~30 s after triggering. The semaphore needs traffic to expose its bottleneck. |
| `orders_inflight_requests` stays at `0` | Prometheus is scraping the gauge but the metric was reset on restart and there's no in-flight traffic right now. | Run `curl http://localhost:8080/api/orders` a few times manually. |
| `users_leaked_bytes` drops to `0` mid-scenario | The container OOMKilled and restarted; the in-process buffer is gone. | This is the *expected* end state for S2. The gauge will start climbing again as soon as load resumes and the leak is still active. |
| Gateway p99 is high but downstream p99 panels are all low | The gateway itself is overloaded. Check the gateway container's CPU on **Resources**. | Not used in any scenario here, but a real diagnostic finding to keep in mind. |

To wipe state completely between scenarios:

```bash
docker compose down -v
docker compose up -d
```

The `-v` removes the named volumes (`prometheus-data` and `grafana-data`), so Prometheus history starts from scratch. Leave them in if you want to see longer history.

---

## Cleanup

```bash
docker compose down -v
```

That removes containers, networks, and named volumes. No external state to clean up.

---

## Scenario solutions

Spoiler section. Read after you've worked through S2 and S3.

### Scenario 1 — covered in the walkthrough

A 2–3 s sleep was added to the `payments` handler. Signature: `payments` p99 jumps; `payments` container CPU / RAM normal; gateway's downstream histogram for `payments` matches the payments service's own duration histogram (within ~50 ms). Conclusion: the latency is being added by the payments process itself.

### Scenario 2 — memory leak in `users`

Every call to `/api/users/<id>` appends a 1 MiB chunk to an in-process list that is never freed. With a 192 MiB container memory limit and ~6 r/s on this endpoint, the container reaches the limit in 20–25 s and is `OOMKilled` by the kernel; Docker restarts it (`restart: unless-stopped`), and the cycle begins again.

Signature on the dashboards:

- **RED — request rate by service**: a brief dip on `users` every ~25 s when the container restarts. Easy to miss.
- **RED — p99 by service**: largely unchanged; this is not a latency problem.
- **Resources — Process RSS per service** for `users`: a sawtooth — climbs to ~180 MiB, drops back to ~40 MiB, climbs again. *Sawtooth in memory is the classic OOMKill-restart pattern.*
- **Resources — Process uptime per service** for `users`: resets every ~30 s. Other services' uptimes climb linearly.
- **Resources — Users service: synthetic leak gauge**: `users_leaked_bytes` climbs from 0, jumps to near 90 MiB, and resets to 0 on each restart.

Why two signals say the same thing: `process_resident_memory_bytes` is the OS view (emitted by `prometheus_client` from inside the process), and `users_leaked_bytes` is the application's own bookkeeping. They agree because the leak is literal — the bytes the app allocates show up in the process RSS. In a real production leak (a Java app holding onto closed JDBC connections, say) the app rarely has a self-reported gauge for the leak itself — `process_resident_memory_bytes` (or kube-state-metrics / cAdvisor at the pod/container level) is the ground truth. The application gauge here exists only to show how a well-instrumented app would confirm the cause from its own perspective.

The diagnostic loop: *errors flat, latency flat, memory climbing → resource problem, not a code-path latency problem. The container that's climbing is the one with the bug.*

### Scenario 3 — saturation on `orders`

The `orders` semaphore is shrunk from 50 down to 3 and every request is forced to spend 0.8–1.4 s in the handler. With pool capacity = 3 and per-request work ≈ 1 s, the service can serve at most ~3 r/s. The gateway's offered load is much higher than that — but, importantly, the gateway calls `orders` *synchronously* through its own load-generator threads, so as `orders` slows down, the gateway's own request rate drops with it. This is **backpressure in action**: a slow downstream service silently slows down its caller.

Signature on the dashboards:

- **RED — request rate by service**: every service's request rate drops, most visibly on `gateway` (from ~14 r/s to ~3 r/s) and `orders` (from ~9 r/s to ~3 r/s). When a backend service saturates, a synchronous caller's *throughput drops* — the gateway is now spending most of its time waiting.
- **RED — error rate by service**: roughly unchanged. Whether errors show up depends on whether the calling client gives up waiting. The gateway here has a generous 10 s HTTP timeout, longer than the 4 s in-pool wait + 1 s work, so it almost always gets a (slow) success. **In a different shop with a 2 s client timeout, you'd see errors instead** — same root cause, different symptom. This is why a saturation alert should never be "error rate up"; it has to be latency *or* queue depth.
- **RED — p99 by service**: `orders` p99 climbs from ~230 ms to ~2.5 s and stays pinned there. `gateway` p99 follows it. *Both rate dropping and duration rising on the same service* is a textbook saturation signature.
- **Resources — Orders pool: in-flight vs capacity**: this is the unambiguous evidence. `in-flight` sits at or near `capacity` (3) the whole time. That overlap *is* saturation by definition: every available slot is in use, every new request must wait.
- **Resources — Process CPU / RSS**: `orders` CPU is low (most of the time is spent sleeping, not computing). This rules out "the box is too small" and points instead at "the in-process pool is too small".

The diagnostic loop: *rate down **and** latency up on the same service, process CPU/RAM idle, in-flight gauge sitting at capacity → saturation of an internal resource (a worker pool, a connection pool, a thread pool). Look for an explicit application-level gauge that names the pool.*

This is the most subtle of the three to read, because two signals move at once and process resources are clean. It is also the one whose fix in production is rarely "make the pool bigger" — that just moves the bottleneck. The right answer is usually a combination of backpressure (explicit 503s back to callers rather than indefinite waits), autoscaling, and finding why the work is slower than expected.

---

## References

- Brendan Gregg — USE method overview: https://www.brendangregg.com/usemethod.html
- Tom Wilkie — RED method (original talk): https://www.weave.works/blog/the-red-method-key-metrics-for-microservices-architecture/
- Google SRE Book — Monitoring Distributed Systems (the four golden signals): https://sre.google/sre-book/monitoring-distributed-systems/
- Prometheus best practices — Histograms and summaries: https://prometheus.io/docs/practices/histograms/
- Prometheus docs — `histogram_quantile()`: https://prometheus.io/docs/prometheus/latest/querying/functions/#histogram_quantile
- Python `prometheus_client` — Process collector (where `process_*` metrics come from): https://github.com/prometheus/client_python#process-collector
- cAdvisor metrics reference (for the production analogue at container/pod level): https://github.com/google/cadvisor/blob/master/docs/storage/prometheus.md
