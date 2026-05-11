# Hands-on 00: Prometheus Basics — Data Model and First Queries

## Objective

Before touching dashboards or exporters, understand what Prometheus actually is
at its core: a time-series database with a pull-based collection model and a
query language built around that model.

By the end of this hands-on you will be able to:
- Explain the Prometheus data model: metric name, labels, and samples
- Distinguish the four metric types (Counter, Gauge, Histogram, Summary)
- Read raw metrics from a `/metrics` endpoint and interpret what you see
- Write basic PromQL queries in the Expression Browser: instant vectors,
  label filters, and `rate()` on a counter

No Grafana, no exporters yet — just Prometheus and its own internal metrics.
Prometheus's `/metrics` endpoint is rich enough to demonstrate all four metric
types without any additional services.

---

## Prerequisites

```bash
# Docker and Docker Compose must be installed
docker --version
docker compose version

# Clone or navigate to this directory
cd monitoring/hands-on/prometheus-basics
```

---

## Part 1 — Start Prometheus and explore the UI

```bash
docker compose up -d
```

Prometheus takes a few seconds to start. Open the Expression Browser:

```
http://localhost:9090
```

Navigate to **Status → Targets** (`http://localhost:9090/targets`).

You should see one target: `prometheus (1/1 up)`. Prometheus is scraping itself.

**What is happening here?** Every 15 seconds Prometheus sends an HTTP GET to
`/metrics` on each target, parses the response, and stores the resulting
samples in its local time-series database. This is the **pull model**: targets
do not push data to Prometheus — Prometheus comes to them.

---

## Part 2 — Read a raw `/metrics` endpoint

Before writing queries, look at the raw data format Prometheus ingests.

```bash
# Prometheus exposes its own metrics at this endpoint
curl http://localhost:9090/metrics | head -60
```

You will see output like this:

```
# HELP go_goroutines Number of goroutines that currently exist.
# TYPE go_goroutines gauge
go_goroutines 8

# HELP prometheus_http_requests_total Counter of HTTP requests.
# TYPE prometheus_http_requests_total counter
prometheus_http_requests_total{code="200",handler="/metrics"} 42
prometheus_http_requests_total{code="200",handler="/api/v1/query"} 7
```

Three things to notice:

1. **`# HELP`** — human-readable description of the metric.
2. **`# TYPE`** — declares the metric type (`gauge`, `counter`, `histogram`, `summary`).
3. **The data line** — `metric_name{label="value"} numeric_value`. Each unique
   combination of metric name + label set is a separate **time series**.

The same metric name `prometheus_http_requests_total` appears twice with
different `handler` labels. These are two independent time series that happen
to share a name.

---

## Part 3 — The four metric types

Open the Expression Browser at `http://localhost:9090/graph` and run each
query below. Use the **Table** view to see current values.

### 3.1 Gauge — a value that goes up and down

A gauge represents the current state of something.

```promql
go_goroutines
```

Run this a few times. The value changes slightly as Prometheus creates and
destroys goroutines internally. A gauge is always the raw current value —
you can use it directly without any function.

Other examples of gauges in production: CPU temperature, memory used,
number of open connections, replica count.

```promql
# Useful functions for gauges
max_over_time(go_goroutines[5m])   # highest value in the last 5 minutes
avg_over_time(go_goroutines[5m])   # average over the last 5 minutes
```

### 3.2 Counter — a value that only increases

A counter starts at 0 and only goes up (it resets to 0 on restart).
Prometheus HTTP request counts are counters.

```promql
prometheus_http_requests_total
```

You will see one row per `{code, handler}` combination. The raw number is
not very useful on its own — what matters is the **rate of change**.

```promql
# Never query a counter as a raw value for dashboards.
# Always wrap it in rate() to get "requests per second over the last 5 min":
rate(prometheus_http_requests_total[5m])
```

`[5m]` is the **range selector** — it tells PromQL to look at 5 minutes of
samples to calculate the rate. Switch to the **Graph** tab to see how the
rate evolves over time.

### 3.3 Histogram — distribution of observations

A histogram counts how many observations fell into pre-defined buckets, plus
a total count and a running sum. Prometheus tracks the duration of its own
HTTP requests as a histogram — no demo app needed.

```promql
prometheus_http_request_duration_seconds_bucket
```

You will see multiple rows per `handler`, each with an `le` (less-than-or-equal)
label representing the upper bound of a bucket. The value is the cumulative
count of requests that completed within that duration.

Generate a few scrapes first so the histogram has data:

```bash
# Run this a few times to generate HTTP requests against Prometheus
for i in $(seq 1 20); do curl -s http://localhost:9090/metrics > /dev/null; done
```

Then query the 95th percentile latency of all Prometheus HTTP handlers:

```promql
histogram_quantile(
  0.95,
  sum by (handler, le) (rate(prometheus_http_request_duration_seconds_bucket[5m]))
)
```

This is one of the most common queries in production monitoring. The `handler`
label lets you see latency broken down by endpoint.

### 3.4 Summary — pre-computed quantiles

A summary is similar to a histogram but computes quantiles on the client side.
The Go runtime exposes garbage collection duration as a summary:

```promql
go_gc_duration_seconds
```

You will see rows with a `quantile` label (`0`, `0.25`, `0.5`, `0.75`, `1`).
These are computed inside the process — you can read them directly, but you
cannot aggregate them across multiple instances the way you can with histograms.
Query it like a gauge: no `histogram_quantile()` needed.

---

## Part 4 — Label filtering and aggregation

Labels are what make PromQL powerful. You can slice and aggregate any metric
by any combination of labels.

### 4.1 Filter by label

```promql
# Only HTTP 200 responses
prometheus_http_requests_total{code="200"}

# All non-200 responses (regex negation)
prometheus_http_requests_total{code!="200"}

# Handlers that match a pattern
prometheus_http_requests_total{handler=~"/api.*"}
```

### 4.2 Aggregate across labels

```promql
# Total request rate across ALL handlers and codes
sum(rate(prometheus_http_requests_total[5m]))

# Request rate broken down by HTTP status code
sum by (code) (rate(prometheus_http_requests_total[5m]))

# Which handler receives the most traffic?
topk(3, sum by (handler) (rate(prometheus_http_requests_total[5m])))
```

Switch to the **Graph** tab for the last query. You will see one line per
handler, letting you compare traffic distribution at a glance.

---

## Part 5 — Putting it together: build a request rate dashboard query

Prometheus's own HTTP server is instrumented with the same patterns you will
use in production applications. Use it to practice combining everything from
Parts 3 and 4 into a single meaningful query.

```promql
# Total request rate into Prometheus (all handlers combined)
sum(rate(prometheus_http_requests_total[5m]))
```

```promql
# Request rate broken down by handler — which endpoint is busiest?
sum by (handler) (rate(prometheus_http_requests_total[5m]))
```

```promql
# Error rate: fraction of non-200 responses
sum(rate(prometheus_http_requests_total{code!="200"}[5m]))
  /
sum(rate(prometheus_http_requests_total[5m]))
```

If the error rate returns `NaN`, the numerator is zero — no errors. That is
expected and correct. `NaN` in PromQL means the result is undefined (division
by zero or an absent series), not that something is broken.

```promql
# p99 latency of the /metrics handler specifically
histogram_quantile(
  0.99,
  rate(prometheus_http_request_duration_seconds_bucket{handler="/metrics"}[5m])
)
```

Switch to the **Graph** tab and set a time range of **Last 15 minutes**. You
will see the self-scrape traffic as a steady low-rate signal — exactly the
kind of baseline you would see from a real service in production.

---

## Part 6 — Cleanup

```bash
docker compose down
```

---

## Discussion questions

1. Why does Prometheus use a **pull model** rather than having applications push
   metrics? What are the operational implications of each approach?
2. What is the difference between a `counter` and a `gauge`? Give a real-world
   example of a metric that would be wrong to model as a counter.
3. Why should you never build a dashboard panel using the raw value of a
   counter? What function do you need and why?
4. Two Prometheus instances are scraping the same target. Can you aggregate
   their data? What problem does this create with histograms vs counters?

---

## Key concepts

| Concept | Description |
|---------|-------------|
| Time series | A metric name + a unique set of labels. Each scrape adds a sample (timestamp + value). |
| Pull model | Prometheus initiates the scrape; targets expose a `/metrics` HTTP endpoint |
| Counter | Monotonically increasing value. Always use `rate()` or `increase()` to query it. |
| Gauge | Current value that can go up or down. Query directly or with `*_over_time()` functions. |
| Histogram | Distribution of observations across pre-defined buckets. Use `histogram_quantile()`. Example: `prometheus_http_request_duration_seconds_bucket`. |
| Label selector | `{key="value"}` — filters time series by label. Supports `=`, `!=`, `=~`, `!~`. |
| `rate(m[5m])` | Per-second average rate of a counter over the last 5 minutes. |
| Range vector | `metric[5m]` — selects all samples in the last 5 minutes for a metric. |
