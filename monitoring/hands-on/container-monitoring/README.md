# Hands-on 02: Container Monitoring with cAdvisor

## Objective

Node Exporter tells you what the **host machine** is doing. But in a containerized
environment you also need to know what **each container** is doing — which ones
are consuming the most CPU, which ones are leaking memory, and which ones have
restarted unexpectedly.

cAdvisor (Container Advisor) is Google's open-source agent that reads container
metrics from the Docker daemon and Linux cgroups, and exposes them to Prometheus.

By the end of this hands-on you will be able to:
- Run cAdvisor alongside the existing monitoring stack
- Distinguish `container_` metrics (per container) from `node_` metrics (per host)
- Write PromQL queries to identify resource consumption by container
- Build a Grafana dashboard that shows CPU and memory per container

---

## Prerequisites

```bash
# Hands-on 01 should be completed — you already know how to use Grafana
# Navigate to this directory
cd monitoring/hands-on/container-monitoring
```

---

## Part 1 — Start the stack with cAdvisor

This compose file extends the stack from hands-on 01 with one new service:
`cadvisor`.

```bash
docker compose up -d

# Wait for all services to start
docker compose ps
```

cAdvisor exposes its own UI and a `/metrics` endpoint on port 8081:

```
http://localhost:8081
```

Browse the cAdvisor UI briefly. You can see per-container CPU and memory usage
in real time. This UI is useful for quick inspection but is not persistent —
it shows no history. That is why we still need Prometheus + Grafana.

Verify that Prometheus is scraping cAdvisor:

```
http://localhost:9090/targets
```

The `cadvisor` job should appear as `UP`.

---

## Part 2 — Explore container metrics in the Expression Browser

Open `http://localhost:9090/graph` and explore the `container_` namespace.

```promql
# List all time series from the cadvisor job
{job="cadvisor"}
```

This returns hundreds of series — filter it down to something useful.

### 2.1 CPU usage per container

```promql
# Rate of CPU seconds consumed per container (averaged over 5 minutes)
rate(container_cpu_usage_seconds_total{name!=""}[5m])
```

The `name!=""` filter excludes system-level cgroup entries that cAdvisor also
exposes (they have an empty `name` label). The result is one time series per
running container.

```promql
# Sort containers by CPU consumption (highest first)
topk(5, rate(container_cpu_usage_seconds_total{name!=""}[5m]))
```

Switch to the **Graph** tab. You will see one line per container. Notice that
`prometheus` and `cadvisor` itself are the busiest, because they are actively
scraping.

### 2.2 Memory usage per container

```promql
# Working set memory (what the OS cannot easily reclaim)
container_memory_working_set_bytes{name!=""}
```

Compare this with `container_memory_usage_bytes` — the working set is usually
more relevant because it excludes file cache, which the kernel can reclaim
under pressure.

```promql
# Top 5 containers by memory working set
topk(5, container_memory_working_set_bytes{name!=""})
```

### 2.3 Container restarts

A container that restarts frequently is a reliability problem.

```promql
# Number of restarts for each container in the last hour
changes(container_start_time_seconds{name!=""}[1h])
```

`changes()` counts how many times the value of `container_start_time_seconds`
changed — i.e., how many times the container was (re)started.

---

## Part 3 — Compare node metrics vs container metrics

This is a key conceptual exercise. Run both queries side by side.

```promql
# Host-level total CPU (all cores, all processes)
100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
```

```promql
# Container-level CPU (sum across all containers)
sum(rate(container_cpu_usage_seconds_total{name!=""}[5m]))
```

The container sum will be lower than the host utilization — this is expected.
The host also runs kernel processes, system daemons, and Docker itself, which
are not attributed to any specific container.

---

## Part 4 — Build a container dashboard in Grafana

Open Grafana at `http://localhost:3000` (if you lost the Prometheus data source
from hands-on 01, re-add it following Part 2 of that hands-on).

Create a new dashboard with three panels:

**Panel 1 — CPU usage by container (time series)**
```promql
rate(container_cpu_usage_seconds_total{name!=""}[5m])
```
- In the **Legend** field (below the query), enter `{{name}}` so each line
  is labeled with the container name instead of the full label set.
- Unit: `short` (CPU seconds/sec — no special unit needed).

**Panel 2 — Memory usage by container (bar gauge)**
```promql
topk(6, container_memory_working_set_bytes{name!=""})
```
- Visualization type: **Bar gauge**.
- Unit: `bytes (SI)`.
- Legend: `{{name}}`.

**Panel 3 — Container restart count (stat)**
```promql
sum by (name) (changes(container_start_time_seconds{name!=""}[1h]))
```
- Visualization type: **Table**.
- This gives you a quick view of which containers are unstable.

Save the dashboard as `Container Overview`.

---

## Part 5 — Simulate a memory-hungry container

Start a container that consumes memory and watch the dashboard update.

```bash
# Run a container that allocates ~100 MB of memory using a Python one-liner
docker run --rm --name memory-hog python:3.11-slim \
  python3 -c "import time; data = bytearray(100 * 1024 * 1024); time.sleep(120)"
```

Wait 15-30 seconds (one scrape interval) and check the **Panel 2** bar gauge.
You should see `memory-hog` appear in the list. Kill it when done:

```bash
docker stop memory-hog
```

---

## Part 6 — Cleanup

```bash
docker compose down -v
```

---

## Discussion questions

1. cAdvisor requires `privileged: true` and access to `/var/run`, `/sys`, and
   `/var/lib/docker`. Why does it need these permissions? What is the security
   implication of running a privileged container in production?
2. What is the difference between `container_memory_usage_bytes` and
   `container_memory_working_set_bytes`? Which one should you alert on and why?
3. You have Node Exporter showing host CPU at 60% and the sum of container CPUs
   at 40%. What accounts for the 20% difference?
4. In Kubernetes, cAdvisor is built into the kubelet — you do not deploy it as
   a separate container. What does this tell you about how Kubernetes was
   designed with observability in mind?

---

## Key concepts

| Concept | Description |
|---------|-------------|
| cAdvisor | Google agent that reads container stats from cgroups and Docker and exposes them at `/metrics` |
| `container_` prefix | Namespace for all cAdvisor-sourced metrics |
| `name!=""` filter | Excludes system-level cgroup entries; keeps only named containers |
| `container_memory_working_set_bytes` | Memory the kernel cannot reclaim. Better alerting signal than total usage. |
| `changes(m[1h])` | Number of times a value changed in the last hour. Used to detect restarts. |
| `topk(n, expr)` | Returns the n highest-valued time series from the expression |
