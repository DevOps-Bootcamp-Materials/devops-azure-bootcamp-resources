# Hands-on 03: PromQL in Depth and Alerting

## Objective

Dashboards are great for humans looking at screens. Alerting is what makes
monitoring useful at 3 AM when nobody is looking. This hands-on covers two
things: advanced PromQL patterns you will use constantly in production, and
the alerting pipeline — from a rule expression in Prometheus to a notification
delivered by Alertmanager.

By the end of this hands-on you will be able to:
- Write PromQL queries using binary operators, `by`/`without` aggregation,
  `histogram_quantile()`, and recording rules
- Write alerting rules with `expr`, `for`, and annotation templates
- Understand the flow from a firing rule → Alertmanager → receiver
- Inspect firing alerts in both the Prometheus UI and Alertmanager UI

---

## Prerequisites

```bash
cd monitoring/hands-on/promql-alerting
docker compose up -d
docker compose ps   # confirm all 7 services are running
```

Open these three tabs in your browser:
- `http://localhost:9090` — Prometheus (Expression Browser + Alerts)
- `http://localhost:9093` — Alertmanager
- `http://localhost:9000` — Webhook logger (prints alert notifications as JSON)

---

## Part 1 — PromQL: binary operators and vector matching

So far we have used functions like `rate()` and `sum()`. PromQL also supports
arithmetic and comparison between two metric vectors.

### 1.1 Arithmetic between metrics

```promql
# Memory used = total - available
node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes
```

```promql
# Memory utilization as a percentage
(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes)
  / node_memory_MemTotal_bytes * 100
```

Prometheus matches time series by their label sets. Both metrics above have
an `instance` label, so Prometheus matches them pair-by-pair. This is called
**one-to-one vector matching** and is the default behaviour.

### 1.2 Comparison operators — instant results

```promql
# Returns only the instances where memory utilization exceeds 50%
(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes)
  / node_memory_MemTotal_bytes * 100 > 50
```

When the condition is false, the time series disappears from the result.
This is the foundation of alerting: an alert fires when the expression
returns any time series.

### 1.3 Aggregation: `by` vs `without`

```promql
# Total CPU rate across ALL cores and instances
sum(rate(node_cpu_seconds_total[5m]))

# CPU rate per instance (sum across cores, keep instance label)
sum by (instance) (rate(node_cpu_seconds_total[5m]))

# CPU rate per mode (sum across instances and cores, keep mode label)
sum by (mode) (rate(node_cpu_seconds_total[5m]))

# Same result using without (drop the specified labels, keep everything else)
sum without (cpu) (rate(node_cpu_seconds_total[5m]))
```

`by (labels)` keeps only the named labels in the output.
`without (labels)` drops the named labels and keeps everything else.
Use `by` when you know what you want to group on; use `without` when you want
to drop a high-cardinality label like `cpu` or `core`.

---

## Part 2 — PromQL: histograms and percentile latency

Request latency is almost always more useful as a percentile than as an
average. A p99 latency of 2 seconds tells you much more than an average of
200ms — the average hides the worst cases.

### 2.1 Percentile from a histogram

First, generate some traffic so the histogram has data to work with:

```bash
# Send 50 requests to the demo app to populate the histogram
for i in $(seq 1 50); do curl -s http://localhost:8080/ > /dev/null; done
```

```promql
# 95th percentile latency of the demo app handlers
histogram_quantile(
  0.95,
  rate(http_request_duration_seconds_bucket{job="demo"}[5m])
)
```

The `rate()` converts each bucket's counter to a per-second rate before
`histogram_quantile()` reconstructs the distribution. **Never apply
`histogram_quantile()` directly to a counter — always wrap in `rate()` first.**

```promql
# Compare p50, p95, and p99 for each handler side by side
histogram_quantile(0.50, sum by (handler, le) (rate(http_request_duration_seconds_bucket{job="demo"}[5m])))
histogram_quantile(0.95, sum by (handler, le) (rate(http_request_duration_seconds_bucket{job="demo"}[5m])))
histogram_quantile(0.99, sum by (handler, le) (rate(http_request_duration_seconds_bucket{job="demo"}[5m])))
```

Run these three queries on the **Graph** tab. The gap between p95 and p99
reveals how spiky the tail latency is.

### 2.2 The RED method

RED (Rate, Errors, Duration) is a standard framework for monitoring
request-driven services. Here is the full RED dashboard in three queries:

```promql
# Rate: requests per second
sum by (handler) (rate(http_requests_total{job="demo"}[5m]))

# Errors: fraction of requests that returned non-2xx
sum by (handler) (rate(http_requests_total{job="demo", code!~"2.."}[5m]))
  /
sum by (handler) (rate(http_requests_total{job="demo"}[5m]))

# Duration: p95 latency
histogram_quantile(0.95, sum by (handler, le) (rate(http_request_duration_seconds_bucket{job="demo"}[5m])))
```

Note the third query: when aggregating a histogram across label dimensions
(grouping by `handler`), you **must include `le`** in the `by` clause, because
`histogram_quantile()` needs the bucket boundaries to reconstruct the
distribution.

---

## Part 3 — Recording rules

Expensive or frequently-used PromQL expressions can be precomputed into new
time series called **recording rules**. Grafana dashboards that run complex
queries on every page load benefit significantly from this.

Look at the alerting rules files in `rules/host.yml` and `rules/app.yml`. Now
check what Prometheus has loaded:

```
http://localhost:9090/rules
```

You should see both rule groups listed. Click any rule to expand its
expression.

To add a recording rule yourself, edit `rules/host.yml` and add this block
inside the existing `host` group:

```yaml
      # Precomputed CPU utilization — stored as a new metric
      - record: instance:cpu_utilization:rate5m
        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
```

Hot-reload the configuration without restarting Prometheus:

```bash
curl -X POST http://localhost:9090/-/reload
```

Now query the new metric:

```promql
instance:cpu_utilization:rate5m
```

**Recording rule naming convention:** `level:metric:operation`. This is not
enforced by Prometheus but is a widely followed convention:
- `instance` — the aggregation level
- `cpu_utilization` — what is being measured
- `rate5m` — the operation applied

---

## Part 4 — Alert rules and the firing lifecycle

Look at the alert rules in `rules/host.yml`. The structure of each rule is:

```yaml
- alert: AlertName          # shown in Prometheus and Alertmanager
  expr: <promql expression> # alert fires when this returns any time series
  for: 2m                   # must be continuously true for 2 minutes before firing
  labels:
    severity: warning        # custom labels attached to the alert
  annotations:
    summary: "..."           # short human-readable title
    description: "..."       # detailed message; can reference $labels and $value
```

The `for` clause is critical: it prevents transient spikes from creating
noise. An alert goes through three states:
1. **Inactive** — expression returns no results.
2. **Pending** — expression returns results but `for` duration has not elapsed.
3. **Firing** — expression has been continuously true for the full `for` duration.

### 4.1 Trigger the TargetDown alert

Stop the demo app to simulate a target going down:

```bash
docker compose stop demo-app
```

Go to `http://localhost:9090/alerts`. Within 15 seconds you will see
`TargetDown` move to **Pending**. After 1 minute (the `for` duration) it
will move to **Firing**.

Switch to `http://localhost:9093` — the Alertmanager UI. You will see the
alert appear there too. Alertmanager is responsible for routing, grouping,
and deduplicating alerts before sending notifications.

Check the webhook logger at `http://localhost:9000` or its container logs:

```bash
docker logs webhook-logger --tail 30
```

You will see the full JSON payload that Alertmanager sent — including all
labels and annotations.

Bring the demo app back:

```bash
docker compose start demo-app
```

The alert will move back to **Firing → Pending → Inactive**, and a "resolved"
notification will be sent to the webhook logger.

### 4.2 Trigger the HighCpuUtilization alert

Simulate CPU pressure using `stress-ng` inside a temporary container:

```bash
docker run --rm --name cpu-stressor \
  polinux/stress-ng \
  stress-ng --cpu 0 --timeout 300s
```

The `--cpu 0` flag uses all available CPUs. After 15 seconds, the CPU
utilization query should exceed 80%. After the `for: 2m` window the
`HighCpuUtilization` alert will fire.

Observe the alert moving through Pending → Firing in `http://localhost:9090/alerts`.

Stop the stressor when done:

```bash
docker stop cpu-stressor
```

---

## Part 5 — Alertmanager routing

Open `alertmanager.yml`. The current configuration sends all alerts to a
single `webhook-logger` receiver. In production you would route different
severities to different channels:

```yaml
route:
  receiver: "default"
  routes:
    - match:
        severity: critical
      receiver: "pagerduty"
    - match:
        severity: warning
      receiver: "slack"
```

Modify `alertmanager.yml` to add a second receiver (another webhook-logger
on a different port) and route `critical` alerts to it:

```yaml
route:
  receiver: "webhook-logger"
  routes:
    - match:
        severity: critical
      receiver: "webhook-critical"

receivers:
  - name: "webhook-logger"
    webhook_configs:
      - url: "http://webhook-logger:9000"
  - name: "webhook-critical"
    webhook_configs:
      - url: "http://webhook-logger:9000/critical"
```

Reload Alertmanager:

```bash
curl -X POST http://localhost:9093/-/reload
```

---

## Part 6 — Cleanup

```bash
docker compose down -v
```

---

## Discussion questions

1. What is the difference between `sum by (instance)` and `sum without (mode)`
   when applied to `node_cpu_seconds_total`? When would you prefer one over
   the other?
2. The `for: 2m` clause in an alert rule creates a delay before the alert
   fires. What is the trade-off between a short `for` duration (e.g., `30s`)
   and a long one (e.g., `10m`)?
3. `histogram_quantile()` requires `le` in the `by` clause when you aggregate
   across multiple instances. What happens if you forget to include `le`?
4. What is the purpose of Alertmanager's `group_wait` setting? How does it
   relate to the concept of alert storms during a major incident?

---

## Key concepts

| Concept | Description |
|---------|-------------|
| Binary operator | Arithmetic or comparison between two metric vectors, matched by label set |
| `by (labels)` | Aggregation that keeps only the specified labels in the output |
| `histogram_quantile(φ, rate(b[5m]))` | Computes the φ-quantile from a histogram's bucket rate |
| Recording rule | Precomputed expression stored as a new metric. Reduces query load on dashboards. |
| Alert states | Inactive → Pending → Firing. `for` duration controls the Pending→Firing transition. |
| Alertmanager | Handles routing, grouping, deduplication, and silencing of fired alerts |
| `$labels` / `$value` | Template variables in alert annotations for dynamic messages |
| `group_wait` | Time Alertmanager waits before sending the first notification for a group |
