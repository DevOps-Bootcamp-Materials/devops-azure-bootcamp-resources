# Prometheus Basics — Data model and first queries (full reference)

The complete deep-dive companion to the bootcamp hands-on `week-14/monitoring/hands-on/01_prometheus_basics.md`. Same walkthrough, but with every misconception addressed, every edge case explained, and the troubleshooting table at the bottom.

Read this README after going through the bootcamp hands-on once, or open it directly if you already know the basics and want depth.

## What this folder contains

- `README.md` — this file, the deep-dive walkthrough.
- `docker-compose.yml` — one-service Prometheus stack on port `9090`.
- `prometheus.yml` — minimal Prometheus scrape configuration (Prometheus scrapes itself).

## Prerequisites

- Docker and Docker Compose (`docker --version`, `docker compose version`).
- The lessons `01_introduction_to_monitoring_observability.md` and `02_intro_prometheus.md`.

## How to use this folder

```bash
git clone https://github.com/DevOps-Bootcamp-Materials/devops-azure-bootcamp-resources.git
cd devops-azure-bootcamp-resources/monitoring/hands-on/prometheus-basics
```

---

## Part 1 — The pull model in practice

```bash
docker compose up -d
```

After a few seconds, open `http://localhost:9090` and go to **Status → Targets**.

**Output:**

A single target card: `prometheus (1/1 up)`, URL `http://localhost:9090/metrics`, scrape duration in milliseconds, last scrape under 15 seconds ago.

**Explanation:**

Every 15 seconds (the `scrape_interval` configured in `prometheus.yml`), Prometheus performs an HTTP GET on each target's `/metrics` endpoint, parses the plain-text response, and writes one sample per metric per scrape into its local time-series database. There is no agent on the target side: targets just expose a tiny HTTP server, and Prometheus comes to read it.

**Common misconception #1 — "the target sends data to Prometheus".** No. The target is passive. Prometheus is the active party. This is the **pull model** and it is the single defining architectural choice of Prometheus.

**Why pull instead of push?** Pull is the right default for monitoring because:

- **Service discovery is centralised.** Prometheus knows which targets exist; you do not have to configure each target with the address of the monitoring system.
- **Health is observable for free.** If a scrape fails, you know the target is down. With push, an absent push could mean "the target is fine but quiet" or "the target is dead" — and you cannot tell.
- **Backpressure is automatic.** If Prometheus is overloaded, scrapes slow down naturally. With push, a target can flood the monitoring system.

**When push makes sense (the push gateway).** For very short-lived jobs (batch scripts, CI builds) the process may not be alive long enough for Prometheus to scrape it. Such jobs push their metrics to an intermediary **Push Gateway**, which Prometheus then scrapes. The push gateway is a workaround, not a default. Use it only for jobs whose lifetime is shorter than the scrape interval.

**HTTP-less services and exporters.** Many things you want to monitor (databases, Linux hosts, message brokers) do not speak HTTP. You bridge that gap with an **exporter** — a small process that sits next to the service, queries it natively, and exposes a `/metrics` HTTP endpoint that Prometheus can scrape. Examples: Node Exporter (host metrics), cAdvisor (container metrics), mysqld_exporter (MySQL), redis_exporter (Redis). We will see Node Exporter and cAdvisor in the next hands-on sessions.

References:
- [Pull doesn't scale — or does it?](https://prometheus.io/blog/2016/07/23/pull-does-not-scale-or-does-it/) — the canonical explanation from the Prometheus team.

---

## Part 2 — The exposition format

```bash
curl -s http://localhost:9090/metrics | head -40
```

**Output:**

```
# HELP go_goroutines Number of goroutines that currently exist.
# TYPE go_goroutines gauge
go_goroutines 37

# HELP prometheus_http_requests_total Counter of HTTP requests.
# TYPE prometheus_http_requests_total counter
prometheus_http_requests_total{code="200",handler="/-/ready"} 12
prometheus_http_requests_total{code="200",handler="/api/v1/query"} 4
prometheus_http_requests_total{code="200",handler="/metrics"} 31
```

**Explanation:**

The Prometheus **exposition format** is plain-text, line-oriented, and intentionally simple. There are three relevant elements:

1. **`# HELP <name> <description>`** — human-readable description. Shown in the Expression Browser and Grafana tooltips. Can be used in alert messages.
2. **`# TYPE <name> <type>`** — the metric type: `counter`, `gauge`, `histogram`, or `summary`. The type tells you **how to query the metric**. The wrong query against the wrong type is the most common PromQL beginner mistake.
3. **The data line** — `metric_name{label_a="value", label_b="value"} numeric_value`. Each unique combination of metric name + label set is a separate **time series**. Three rows of `prometheus_http_requests_total` with different `{code, handler}` pairs = three independent time series.

**Common misconception #2 — "metric_name is the time series".** It is not. A time series is `metric_name + full label set`. Two rows with the same name but different labels are two different series. This is what lets you slice the data along any dimension you instrumented — `instance`, `job`, `endpoint`, `customer_tier`, whatever you defined.

**Common misconception #3 — "scientific notation means something is wrong".** Look at `go_memstats_alloc_bytes 1.0234208e+07`. That is `10,234,208` bytes (~10 MB), expressed in Go's default formatting. Prometheus does not reformat numbers; whatever the client library produces is what you read.

**The empty-labels case.** A metric without any labels is still a time series — just one of them. `go_goroutines 37` is one series whose label set is empty.

References:
- [Prometheus exposition formats](https://prometheus.io/docs/instrumenting/exposition_formats/) — the formal grammar.

---

## Part 3 — The four metric types

Open the Expression Browser at `http://localhost:9090/graph`. Use the **Table** tab for everything until told otherwise.

### 3.1 Gauge

A **gauge** represents the **current state of a measurable value that can go up and down**. Reading a gauge is like reading a sensor: you ask "what is the value right now?" and you get a number that stands on its own at every timestamp.

```promql
go_goroutines
```

**Output:**

```
go_goroutines{instance="localhost:9090", job="prometheus"}   38
```

Run the query 2–3 times — the value will jitter (38 → 41 → 39). That is the gauge personality.

**Common misconception #4 — "gauges only increase slowly".** Memory and goroutine count happen to be relatively stable, but the defining property of a gauge is **not stability**: it is that every timestamp has a well-defined current value that does not depend on the previous one. Counter-example: `node_load1`, the 1-minute system load, is a gauge and can swing wildly within seconds.

Because the raw value is meaningful on its own, you can query a gauge directly. To look at a gauge over a time window, use any of the `*_over_time` functions:

```promql
max_over_time(go_goroutines[5m])    # peak in the last 5 minutes
avg_over_time(go_goroutines[5m])    # average over the last 5 minutes
min_over_time(go_goroutines[5m])    # lowest value in the last 5 minutes
stddev_over_time(go_goroutines[5m]) # standard deviation in the last 5 minutes
quantile_over_time(0.95, go_goroutines[5m])  # 95th percentile
```

The `[5m]` part is called a **range selector**. Read it literally: "give me every sample of this metric from the last 5 minutes". An `*_over_time` function collapses that window into one number per series. The same query shape underpins almost every gauge-based dashboard panel: "peak memory of each container in the last hour", "average queue depth this morning", and so on.

References:
- [PromQL functions — over_time family](https://prometheus.io/docs/prometheus/latest/querying/functions/#aggregation_over_time).

### 3.2 Counter

A **counter** is a value that **only increases** during the lifetime of the process. It resets to zero when the process restarts. Examples in production: total HTTP requests served, total bytes sent on an interface, total errors logged.

Generate some traffic first so the counters move:

```bash
for i in $(seq 1 30); do curl -s "http://localhost:9090/api/v1/query?query=up" > /dev/null; done
```

Then in the **Table** tab:

```promql
prometheus_http_requests_total
```

**Output:**

```
{code="200",handler="/-/ready"}      18
{code="200",handler="/api/v1/query"} 40
{code="200",handler="/metrics"}      52
{code="200",handler="/graph"}        3
...
```

**Explanation:**

This is the wrong way to look at a counter. The raw number says "this many requests have happened since the process started, ever" — that tells you nothing about whether traffic is healthy right now. What you want is the **rate of change**, expressed as per-second. Hence the single most important function in PromQL:

```promql
rate(prometheus_http_requests_total[5m])
```

**Output:**

```
{code="200",handler="/-/ready"}       0.0667
{code="200",handler="/api/v1/query"}  0.111
{code="200",handler="/metrics"}       0.0667
```

`0.0667 req/sec on /-/ready` ≈ one request every 15 seconds, which is exactly the self-scrape rhythm.

**Mental model.** `rate()` looks at the samples in the window, computes the slope of the counter across them, and returns "per-second" units. A window of `[5m]` is "smooth over the last 5 minutes". Narrower windows are reactive but noisy; wider windows are smoother but laggier. `5m` is a sane default for dashboards; alerts that must react fast often use `1m` or `2m`.

**Common misconception #5 — "I'll just subtract the values to get the delta".** Don't. Counters reset to zero on restart, and a naive subtraction across a restart gives you a negative number that means nothing. PromQL knows this: **`rate()` automatically detects and corrects counter resets**. This is why `rate()` is mandatory on counters and you must never compute deltas by hand.

**Related counter functions:**

- `increase(metric[5m])` — total increase in the window (no per-second normalisation). Useful in alert messages: *"there were 12 errors in the last 5 minutes"*.
- `irate(metric[5m])` — rate computed from only the **last two samples** in the window. Very reactive; very spiky. Use sparingly, for example on very fast-moving counters where a 5-minute average would hide what you care about.

**Default to `rate()`**. Reach for the others only when you can articulate why.

References:
- [How does a Prometheus Counter work?](https://www.robustperception.io/how-does-a-prometheus-counter-work/) by Brian Brazil — short and required reading.

### 3.3 Histogram

A **histogram** is used to measure things with a distribution: latencies, response sizes, queue wait times. The question it answers is *"what is the p95 latency?"* — the value below which 95% of observations fell.

Internally a histogram is **three families of time series at once**:

- `<basename>_bucket{le="X"}` — a counter per bucket, counting observations whose value was less than or equal to X.
- `<basename>_count` — total number of observations.
- `<basename>_sum` — sum of all observed values, so `_sum / _count` is the average.

Look at the buckets:

```promql
prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query"}
```

**Output:**

```
{le="0.1"}   40
{le="0.2"}   40
{le="0.4"}   40
{le="1"}     40
{le="3"}     40
{le="8"}     40
{le="20"}    40
{le="60"}    40
{le="120"}   40
{le="+Inf"}  40
```

The numbers are **cumulative**: the `le="0.4"` bucket counts every observation under 0.4s, including the ones under 0.1s. The `le="+Inf"` bucket always equals the total count.

In this output every bucket has the same count because every `/api/v1/query` finished in under 0.1s — Prometheus scraping itself is extremely fast. In a real application you would see numbers spreading across buckets, like `le="0.1"=800, le="0.2"=950, le="1"=990, le="+Inf"=1000`. That spread is the histogram's information.

To answer "what is the p95?", use `histogram_quantile`:

```promql
histogram_quantile(
  0.95,
  rate(prometheus_http_request_duration_seconds_bucket{handler="/api/v1/query"}[5m])
)
```

**Output:**

```
{handler="/api/v1/query"}   0.095
```

**Explanation, inside out:**

1. `prometheus_http_request_duration_seconds_bucket{...}[5m]` — five minutes of samples from every bucket.
2. `rate(...)` — convert each bucket counter into a per-second rate. **This is mandatory** before quantile calculation because the bucket values are cumulative counters and we want the recent shape of the distribution, not the all-time shape.
3. `histogram_quantile(0.95, ...)` — interpolate the bucket counts to find the value `X` such that 95% of recent observations are below `X`.

`0.095` means "in the last 5 minutes, 95% of `/api/v1/query` requests finished in under 0.095 seconds". **This query pattern is the single most useful one in production observability** — almost every SLO is expressed as "p95 latency under X" or "p99 latency under X".

**Common misconception #6 — "the p95 from my histogram is the exact p95".** It is interpolated inside buckets. If your slowest bucket boundary is `le="1"` and all 1000 requests fall inside it, you cannot tell whether the real p95 is 0.1s or 0.99s. The accuracy depends entirely on how well-chosen your buckets are. Default Prometheus buckets are reasonable for typical HTTP latencies, but bad for, say, database queries that always take milliseconds. When you instrument your own code, **tune the buckets to the expected distribution**.

**Bucket design rule of thumb.** Pick boundaries that bracket your SLO. If your SLO is "p99 < 500ms", you want buckets densely packed around 500ms (200ms, 300ms, 400ms, 500ms, 600ms, …) so the interpolation is tight there. Far from the SLO you can afford to be coarse.

References:
- [Prometheus — Histograms and Summaries](https://prometheus.io/docs/practices/histograms/) — the official guide on choosing between them.

### 3.4 Summary

A **summary** also tracks a distribution, but instead of exposing raw buckets the **client library calculates the quantiles itself** and exposes them as gauges. The Go runtime exposes garbage collection pause durations as a summary:

```promql
go_gc_duration_seconds
```

**Output:**

```
{quantile="0"}     2.9e-05
{quantile="0.25"}  4.3e-05
{quantile="0.5"}   1.5e-04
{quantile="0.75"}  2.2e-04
{quantile="1"}     2.8e-04
```

Each row is one pre-computed quantile. `quantile="0.5"` = median GC pause (150 µs). `quantile="1"` = the slowest GC pause seen. No bucket math, no `histogram_quantile`: you read the value directly.

That sounds simpler than a histogram, so why are histograms the recommended default for 99% of cases? Two reasons:

1. **You cannot aggregate summaries across instances.** If 10 replicas of your API each expose a summary, you **cannot meaningfully compute the global p95** — averaging quantiles is mathematically wrong. With histograms you sum the buckets across replicas, then run `histogram_quantile` once, and the result is statistically correct.
2. **The exposed quantiles are fixed at instrumentation time.** If the application exposes `0.5, 0.75, 0.95`, you can never ask "what is the p99?" later without changing the code and redeploying.

**The rule.** Histograms for almost everything, especially anything that scales horizontally. Summaries only for single-instance things where you want a quick read and never need cross-replica aggregation (the Go runtime is a fair example; most application code is not).

Note that newer Prometheus versions support **native histograms** (also called "sparse histograms"), which solve the bucket-tuning problem and several scaling problems of classic histograms. They are out of scope for this hands-on but worth being aware of when you read code or docs from late 2023 onward.

References:
- [Native histograms](https://prometheus.io/docs/concepts/native_histograms/) — for context.

---

## Part 4 — Label filtering and aggregation

Labels are what make PromQL feel powerful instead of just a number-fetcher. PromQL has four label matchers:

```promql
prometheus_http_requests_total{code="200"}            # exact match
prometheus_http_requests_total{code!="200"}           # negation
prometheus_http_requests_total{handler=~"/api.*"}     # regex match (Go RE2)
prometheus_http_requests_total{handler!~"/api.*"}     # regex negation
```

**All matchers in the curly braces are AND'ed together.** There is no `OR` directly; you express OR with regex: `{code=~"500|502|503"}`.

To compute totals or breakdowns, you use **aggregation operators**:

```promql
sum(rate(prometheus_http_requests_total[5m]))
```

**Output:**

```
{}    0.22
```

`sum()` collapses every series into a single number. If you want to keep a label as a dimension while collapsing the rest, use `by`:

```promql
sum by (code) (rate(prometheus_http_requests_total[5m]))
```

**Output:**

```
{code="200"}   0.22
```

(Two rows if there are both 2xx and other codes; in this demo only `code="200"` ever appears.)

The other commonly-useful aggregators:

```promql
avg by (handler) (rate(prometheus_http_requests_total[5m]))
max by (handler) (rate(prometheus_http_requests_total[5m]))
topk(3, sum by (handler) (rate(prometheus_http_requests_total[5m])))
bottomk(3, ...)
count(metric)
count_values("value", metric)
quantile(0.5, ...)
stddev(...)
```

`topk` and `bottomk` are particularly useful for "which N things stand out": *which 5 endpoints are slowest, which 10 services have the most errors, which 3 nodes have the highest CPU*.

References:
- [PromQL — operators and aggregation](https://prometheus.io/docs/prometheus/latest/querying/operators/).

---

## Part 5 — Production-style queries

The remaining queries combine a metric type, a filter, and an aggregator into the shapes you will see daily.

### 5.1 Total request rate

```promql
sum(rate(prometheus_http_requests_total[5m]))
```

The simplest "is my service receiving traffic" query.

### 5.2 Request rate per handler

```promql
sum by (handler) (rate(prometheus_http_requests_total[5m]))
```

One line per endpoint. In a real app this answers "which API route is busiest" — useful for capacity planning and for spotting unexpected traffic shifts.

### 5.3 Error rate as a fraction (SRE error budget query)

```promql
sum(rate(prometheus_http_requests_total{code=~"5.."}[5m]))
  /
sum(rate(prometheus_http_requests_total[5m]))
```

Numerator: total 5xx per second. Denominator: total RPS. The ratio is *"what fraction of my traffic is failing right now"*. An alert on this query (`> 0.01` for 5 minutes) is the canonical "my service is broken" alert.

Two edge cases worth understanding:

- **Empty result vector.** If no 5xx series exist at all in the lookback window, the numerator has nothing to match and the result is empty — not zero. The fix is "send some errors" or, in practice, relax the filter.
- **`NaN`.** If both sides have series but the denominator evaluates to zero (no traffic at all), the result is `NaN`. `NaN` in PromQL means "undefined", not "error".

### 5.4 p99 latency for a specific handler

```promql
histogram_quantile(
  0.99,
  sum by (le) (rate(prometheus_http_request_duration_seconds_bucket{handler="/metrics"}[5m]))
)
```

**Remember this shape:** `histogram_quantile(QUANTILE, sum by (le) (rate(METRIC_bucket{FILTERS}[5m])))`. The `sum by (le)` aggregates buckets across labels you do not care about (`instance`, `job`, etc.) while keeping the bucket boundaries (`le`) needed for the quantile calculation. **Forgetting `sum by (le)` is the second-most-common PromQL mistake** after forgetting to wrap a counter in `rate()`.

---

## Part 6 — Cleanup

```bash
docker compose down
```

No volumes are kept, so the TSDB is removed with the container.

---

## Discussion questions

1. Why does Prometheus use a pull model rather than push? What are the operational implications of each? When would you choose push?
2. What is the difference between a counter and a gauge? Give a real-world example of a metric that would be wrong to model as a counter.
3. Why must you never build a dashboard panel using the raw value of a counter? What function do you need and why?
4. Two replicas of your API each expose a request-duration metric. You want the global p95 latency. Why must this metric be a histogram and not a summary? How would you write the query?
5. Your `histogram_quantile` query returns a value that seems too low for what you observe in logs. What is the most likely cause, and how would you fix it?

## Troubleshooting

| Symptom | Root cause | Fix |
|---|---|---|
| `http://localhost:9090` unreachable after `docker compose up` | Another process holds port 9090 — often a kube-prometheus stack left running | `docker ps` to find it, stop it; or remap the port in `docker-compose.yml` to `"9091:9090"` and use `localhost:9091` |
| `docker compose up` fails with "container name `/prometheus` is already in use" | A previous run was not cleaned up | `docker rm -f prometheus`, then `docker compose up -d` again |
| Target shows `DOWN` in `/targets` with `connection refused` | Container is still starting | Wait ~10 seconds and refresh; if persistent, `docker logs prometheus` |
| `histogram_quantile(...)` returns `NaN` | No samples in the lookback window | Generate traffic with the curl loop |
| Error rate query returns empty | No 5xx in the lookback window | Expected; relax the filter or wait for real errors |
| Error rate query returns `NaN` | Denominator is zero (no traffic) | Send any request to Prometheus |
| `curl ... --data-urlencode 'query=...{handler="/api/v1/query"}'` returns empty in Git Bash on Windows | MSYS path conversion mangles `/api/v1/query` inside the query string | `MSYS_NO_PATHCONV=1 curl ...`. Not an issue when using the Expression Browser UI |
| Image pulls slowly on first run | First time pulling `prom/prometheus:v2.51.0` | Pre-pull with `docker pull prom/prometheus:v2.51.0` |

## References

- [Prometheus — Overview](https://prometheus.io/docs/introduction/overview/)
- [Prometheus — Data model](https://prometheus.io/docs/concepts/data_model/)
- [Prometheus — Metric types](https://prometheus.io/docs/concepts/metric_types/)
- [Prometheus — Querying basics](https://prometheus.io/docs/prometheus/latest/querying/basics/)
- [Prometheus — Histograms and summaries](https://prometheus.io/docs/practices/histograms/)
- [How does a Prometheus Counter work? — Brian Brazil](https://www.robustperception.io/how-does-a-prometheus-counter-work/)
- [PromQL Cheat Sheet — PromLabs](https://promlabs.com/promql-cheat-sheet/)
