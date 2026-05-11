# Hands-on 05: Observability in Action — A Live Incident Scenario

## Objective

Everything in the previous hands-on sessions was set up in isolation:
Prometheus here, Grafana there, alert rules in a config file. This hands-on
ties it all together with a realistic scenario.

You will operate a running application, watch its metrics evolve in a
pre-built dashboard, trigger a real incident by injecting failures, and
follow the alert through the entire pipeline — Prometheus rule → Alertmanager
routing → email delivered to your inbox.

By the end of this hands-on you will be able to:
- Explain Grafana provisioning: how datasources and dashboards can be
  delivered as code rather than manual configuration
- Read a RED dashboard and identify which signal indicates a problem
- Trigger and resolve an incident in a controlled environment
- Trace the path of an alert from Prometheus rule to email delivery
- Understand what Alertmanager routing buys you (different receivers per severity)

---

## The scenario

You are on-call for a payment processing API. The service has three endpoints:
`/api/orders`, `/api/users`, and `/api/payments`. Each runs at a baseline
error rate of 1-4%. Payments historically fail more than orders because they
depend on a third-party gateway.

Tonight, the gateway starts returning errors. You need to detect the problem,
understand its scope, and verify the alert machinery is working.

The Grafana dashboard is already configured — no clicking required. Emails
arrive in a local web interface. The application generates its own traffic
so you see live data immediately.

---

## Service map

| Service | Port | Purpose |
|---------|------|---------|
| faulty-app | 8080 | The application — API + `/metrics` |
| Prometheus | 9090 | Scrapes metrics, evaluates alert rules |
| Alertmanager | 9093 | Routes fired alerts to receivers |
| Grafana | 3000 | Dashboards (pre-provisioned, login: admin/admin) |
| Mailhog | 8025 | Fake email inbox — receives Alertmanager notifications |
| Node Exporter | 9100 | Host metrics |

---

## Prerequisites

```bash
cd monitoring/hands-on/realistic-scenario

# The application image needs to be built locally
docker compose build

# Verify the build succeeded
docker images | grep faulty-app
```

---

## Part 1 — Start the stack and explore the provisioned setup

```bash
docker compose up -d
docker compose ps   # all 6 services should be Running
```

Open Grafana at `http://localhost:3000` (admin / admin).

**Without clicking anything**, you should already see:
- A datasource called "Prometheus" in **Connections → Data sources**
- A dashboard called "Faulty App — RED Overview" in **Dashboards**

This is **Grafana provisioning** in action. The two YAML files in
`grafana/provisioning/datasources/` and `grafana/provisioning/dashboards/`
are mounted into the container and loaded at startup. No manual setup required.

Open the dashboard. Within 30-60 seconds (one scrape interval + one dashboard
refresh cycle) you will see live data: request rate, error rate, and latency
broken down by endpoint.

**Spend 5 minutes just reading the dashboard in steady state:**
- Which endpoint has the highest request rate?
- Which endpoint has the highest error rate at baseline?
- Which endpoint has the highest latency? Is this expected?
- Are the four stat panels at the top aligned with what the time series show?

---

## Part 2 — Understand the provisioning files

Before triggering anything, look at how the stack is configured.

### Grafana datasource provisioning

```bash
cat grafana/provisioning/datasources/prometheus.yml
```

This YAML is equivalent to going into Grafana UI → Connections → Add data
source → Prometheus → fill in the URL → Save. The key fields are `url`,
`uid` (used by dashboard JSON to reference this datasource), and `isDefault`.

The `uid: prometheus-main` is what the dashboard JSON uses to reference this
datasource. If you change it here without changing the dashboard JSON, the
panels break.

### Grafana dashboard provisioning

```bash
cat grafana/provisioning/dashboards/provider.yml
```

The provider tells Grafana: "look in this directory for `.json` files and
load them as dashboards". The `disableDeletion: true` setting means the
dashboard cannot be deleted from the UI — it always comes back from the file.

### The alert rules

```bash
cat rules/app-alerts.yml
```

There are three alert rules: `AppDown`, `PaymentHighErrorRate`, and
`PaymentSlowP95`. Read the `PaymentHighErrorRate` rule carefully. What
condition must be true, for how long, before the alert fires?

Check that Prometheus has loaded the rules:
```
http://localhost:9090/rules
```

All three should appear as `Inactive` — no alerts are firing yet.

---

## Part 3 — Check Alertmanager routing

Open `alertmanager.yml` and trace what happens when `PaymentHighErrorRate`
fires:

1. The alert has labels `severity: critical` and `team: payments`.
2. The `routes` section in `alertmanager.yml` matches `severity: critical`
   AND `team: payments` → routes to receiver `email-payments-critical`.
3. That receiver sends to `payments-oncall@ironhack-lab.local` via SMTP.
4. Mailhog is listening on port 1025 as a fake SMTP server. It accepts
   the email and makes it available in its web UI at port 8025.

Open Mailhog now to confirm it is running:
```
http://localhost:8025
```

The inbox should be empty — no alerts are firing yet.

---

## Part 4 — Inject the incident

Now you will simulate the payment gateway starting to fail. The `/chaos`
endpoint raises the error rate on `/api/payments` to a configurable value.

```bash
# Set the payments error rate to 60%
curl -X POST "http://localhost:8080/chaos?error_rate=0.6"
```

You should receive:
```json
{"message": "Payments error rate set to 60%", "current_rates": {...}}
```

Switch to the Grafana dashboard and watch the **Error Rate by Endpoint** panel.
Within 15-30 seconds the `/api/payments` line will start climbing sharply
while `/api/orders` and `/api/users` remain flat.

**This is the first thing you notice in a real incident:** one signal
deviates from the others, which rules out a host-level problem and points
to a specific service or endpoint.

---

## Part 5 — Watch the alert lifecycle

Switch to the Prometheus Alerts page:
```
http://localhost:9090/alerts
```

The `PaymentHighErrorRate` rule expression evaluates every 15 seconds. Once
the error rate exceeds 5%, the alert enters **Pending** state. It must remain
pending for the full `for: 1m` duration before moving to **Firing**.

Watch the state transition in real time. The typical sequence:

| Time | State | What is happening |
|------|-------|------------------|
| t+0s | Inactive | Error rate just crossed 5% |
| t+15s | Pending | First evaluation above threshold |
| t+75s | Firing | `for: 1m` duration elapsed |
| t+90s | Alertmanager | Alert received, `group_wait: 10s` starts |
| t+100s | Email sent | Notification delivered to Mailhog |

Once the alert is **Firing**, go to Alertmanager:
```
http://localhost:9093
```

You will see the alert listed there with its labels and annotations. Click
**Info** to expand it and see the full payload.

---

## Part 6 — Read the email

Open Mailhog at `http://localhost:8025`.

You should see one or two emails depending on routing:
- One to `oncall@ironhack-lab.local` (default receiver, if other alerts fired)
- One to `payments-oncall@ironhack-lab.local` (payments critical receiver)

Click the email to open it. Notice:
- The subject contains `[FIRING]` and the alert name
- The body includes the `summary` and `description` annotations from the rule
- The `{{ printf "%.1f" (mul $value 100) }}%` template rendered to the actual
  percentage value at the time the alert fired
- The alert includes the `team: payments` label — in production this would
  route to the payments team's PagerDuty, not the general on-call

**This is the complete alerting pipeline.** From a PromQL expression
evaluating to `true`, through Alertmanager routing, to a human-readable
notification.

---

## Part 7 — Correlate with the dashboard annotation

Go back to the Grafana dashboard. You should now see a **red vertical line**
on the time series panels — this is the alert annotation, automatically added
when the alert fired.

If you do not see it, check that the annotation is enabled: click the
dashboard title → **Dashboard settings** → **Annotations**. The "Firing Alerts"
annotation should be enabled.

Hover over the red line. It shows the alert name and the label values. This
is how SREs correlate "when did the alert fire" with "what was the metric
doing at that moment" on a single view.

---

## Part 8 — Resolve the incident

```bash
# Restore default error rates
curl -X POST "http://localhost:8080/reset"
```

Watch the dashboard: the error rate on `/api/payments` will drop back to
baseline within 1-2 minutes as the rate window (`[2m]`) fills with new
(successful) samples.

Back in Prometheus, the alert will move from **Firing** → **Inactive** once
the expression evaluates to false for a full evaluation cycle.

In Alertmanager, the alert will disappear from the active list.

In Mailhog, a new email will arrive with `[RESOLVED]` in the subject and the
alert's end time. The `send_resolved: true` setting in `alertmanager.yml`
controls this behaviour.

---

## Part 9 — Experiment on your own

Use the following commands to explore different failure modes and observe
how the dashboard and alerts respond.

```bash
# Gradual degradation (just above the 5% threshold — tests the for: duration)
curl -X POST "http://localhost:8080/chaos?error_rate=0.08"

# Catastrophic failure (should trigger PaymentHighErrorRate immediately)
curl -X POST "http://localhost:8080/chaos?error_rate=0.95"

# Error rate just below the threshold (alert should NOT fire)
curl -X POST "http://localhost:8080/chaos?error_rate=0.04"

# Reset to normal
curl -X POST "http://localhost:8080/reset"
```

For each scenario, predict before running: will the alert fire? How long
will it take? Which receiver will get the notification?

---

## Part 10 — Look inside the application metrics

The application exposes its raw metrics at `/metrics`. Compare what you see
in the raw endpoint with what Prometheus has ingested:

```bash
# Raw metrics from the application
curl http://localhost:8080/metrics | grep "^app_"

# The same metric as stored in Prometheus
# (open in Expression Browser)
# app_requests_total
# app_request_duration_seconds_bucket
```

Notice that the raw `/metrics` endpoint shows cumulative counters — the
total since the app started. What Grafana shows is `rate()` applied to those
counters, which gives you the per-second rate over a sliding window.

---

## Part 11 — Cleanup

```bash
docker compose down -v
```

---

## Discussion questions

1. The dashboard was already configured when Grafana started. Explain the
   mechanism: what files were loaded, where, and in what format. What are
   the operational benefits of this approach vs clicking through the UI?
2. The `PaymentHighErrorRate` alert has `for: 1m`. You tried `error_rate=0.04`
   and the alert did not fire. Why not? At what value does the expression
   become true?
3. Two separate email receivers exist for `payments-critical` and
   `email-default`. In a production environment, what would these map to?
   What does this tell you about the relationship between alert labels and
   routing policy?
4. The alert annotation appeared as a red line on the dashboard timeline.
   Why is this more useful than just looking at the Alertmanager UI?
5. When you called `/reset`, the error rate dropped immediately in the
   application but the alert took 1-2 minutes to resolve on the dashboard.
   Why the delay?

---

## How provisioning fits into your workflow

```
Repository
└── grafana/
    └── provisioning/
        ├── datasources/
        │   └── prometheus.yml       ← YAML: which backends Grafana connects to
        └── dashboards/
            ├── provider.yml         ← YAML: where to find dashboard JSON files
            └── app-overview.json    ← JSON: the actual dashboard definition
```

When a new engineer joins the team, they run `docker compose up` and get
a fully configured Grafana instance — no setup docs to follow, no screenshots
to replicate. When a dashboard is improved, the change goes through git review
like any other code change.

In Kubernetes, the same files are delivered via a ConfigMap mounted into the
Grafana pod, or via the Grafana Operator CRD. The provisioning mechanism
is identical.

---

## Key concepts

| Concept | Description |
|---------|-------------|
| Grafana provisioning | Loading datasources and dashboards from files at startup — configuration as code |
| `grafana/provisioning/datasources/` | YAML files that define which backends Grafana connects to |
| `grafana/provisioning/dashboards/` | A provider YAML + dashboard JSON files loaded automatically |
| Dashboard UID | Stable identifier in the JSON. Used by the provisioning system and in URLs. |
| Alert annotation | A vertical marker on a Grafana graph showing when an alert fired/resolved |
| Mailhog | Fake SMTP server with a web UI. Accepts any email without external connectivity. |
| `/chaos` endpoint | Teacher-controlled endpoint that sets the application's error rate at runtime |
| `send_resolved: true` | Alertmanager setting that sends a recovery notification when an alert clears |
| `group_wait` | How long Alertmanager waits before sending the first notification for a new group |
