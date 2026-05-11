# Hands-on 01: Full Monitoring Stack — Prometheus + Grafana + Node Exporter

## Objective

In the previous hands-on you queried Prometheus metrics using only the
Expression Browser. Real operations work happens in Grafana dashboards that
teams can share, alert from, and iterate on without writing PromQL by hand.

This hands-on introduces the standard three-tier monitoring stack and the
workflow for building dashboards on top of it.

By the end of this hands-on you will be able to:
- Run a production-representative monitoring stack with Docker Compose
- Understand what Node Exporter does and what metrics it exposes
- Add Prometheus as a data source in Grafana
- Import an existing community dashboard
- Build a custom panel from scratch using a PromQL query

---

## Prerequisites

```bash
# Complete hands-on 00 before this one
cd monitoring/hands-on/full-stack

# Confirm nothing is using ports 9090, 3000, or 9100
lsof -i :9090 -i :3000 -i :9100 2>/dev/null || echo "ports are free"
```

---

## Part 1 — Start the stack

```bash
docker compose up -d

# Follow the logs to confirm all containers start cleanly
docker compose logs -f
# Press Ctrl+C when you see "msg=Server is ready to receive web requests" from Prometheus
```

Verify all four targets are up in Prometheus:

```
http://localhost:9090/targets
```

You should see `prometheus`, `node-exporter`, and `demo` — all `UP`.

**What is Node Exporter doing?** It reads hardware and OS metrics directly
from Linux kernel interfaces (`/proc`, `/sys`) and exposes them as Prometheus
metrics at port 9100. Run this to see the raw output:

```bash
curl http://localhost:9100/metrics | grep "^node_cpu" | head -20
```

Each line is a time series. Notice the `mode` label: `idle`, `user`, `system`,
`iowait`, etc. Node Exporter does not interpret these values — it just exposes
them. The interpretation (e.g., "CPU is overloaded") happens in PromQL queries
or Grafana alert rules.

---

## Part 2 — Grafana provisioning: datasource as code

Open Grafana at `http://localhost:3000` and log in with `admin / admin`.
Skip the password change prompt for now.

Go to **Connections → Data sources**. You will see a Prometheus datasource
already configured — you did not add it manually. This is **Grafana provisioning**.

Look at `grafana/provisioning/datasources/prometheus.yml`. That YAML file was
mounted into the Grafana container at `/etc/grafana/provisioning/datasources/`
and loaded automatically at startup. It defines the datasource name, URL, and
a stable `uid` that dashboards can reference by ID.

This is the recommended approach in production: datasource and dashboard
configuration lives in your git repository alongside everything else, not
in a Grafana database that someone has to export and back up manually.

Click the Prometheus datasource and scroll to the bottom — click **Save & test**
to confirm it can reach Prometheus. You will see "Successfully queried the
Prometheus API."

**Note for hands-on 05:** the complete version of this pattern (provisioned
datasource + provisioned dashboard + pre-wired alert annotations) is shown
in `realistic-scenario` — come back to it once you have finished this
hands-on.

---

## Part 3 — Import the Node Exporter Full dashboard

The Grafana community maintains hundreds of pre-built dashboards published at
`grafana.com/grafana/dashboards`. Dashboard **1860** ("Node Exporter Full") is
the most-used host monitoring dashboard in production.

1. In the left sidebar, click **Dashboards → Import**.
2. In the **Import via grafana.com** field, enter `1860` and click **Load**.
3. Select the **Prometheus** data source you created above.
4. Click **Import**.

Spend two minutes exploring the dashboard:
- What is the current CPU utilization? (Look for the "CPU Busy" panel.)
- How much memory is available vs used?
- What is the disk read/write throughput?

These are all PromQL queries that Grafana is running against Prometheus in the
background. Click the title of any panel and select **Edit** to see the query.

---

## Part 4 — Build a custom panel from scratch

You will build a panel that shows the CPU utilization percentage of the host
as a time series graph.

1. Click **Dashboards → New dashboard → Add visualization**.
2. Select the **Prometheus** data source.
3. In the query editor, switch to **Code** mode (toggle in the top right of
   the query box) and enter:
   ```promql
   100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
   ```
4. Click **Run queries**. You should see a graph line between 0 and 100.

**Understanding this query:**
- `node_cpu_seconds_total` is a counter that tracks total CPU time per mode and per core.
- `rate(...[5m])` converts it to a per-second rate over the last 5 minutes.
- `avg(...)` averages across all CPU cores.
- The `mode="idle"` filter gives us the fraction of time CPUs spent idle.
- We multiply by 100 to get a percentage, then subtract from 100 to get
  "time doing work" rather than "time doing nothing".

5. Set the **Panel title** to `CPU Utilization (%)`.
6. In the right panel, under **Standard options**, set **Unit** to
   `Percent (0-100)` and **Max** to `100`.
7. Click **Save** (top right), name the dashboard `My Host Dashboard`.

---

## Part 5 — Add two more panels

Add the following panels to the same dashboard. Use the queries provided and
choose a visualization type that makes sense (time series, gauge, or stat panel).

**Available memory in GB:**
```promql
node_memory_MemAvailable_bytes / 1024 / 1024 / 1024
```
Suggested type: **Stat** panel. Unit: `gigabytes`.

**Network traffic received (bytes/sec):**
```promql
rate(node_network_receive_bytes_total{device!="lo"}[5m])
```
Suggested type: **Time series**. Unit: `bytes/sec (SI)`. The `device!="lo"`
filter excludes the loopback interface.

Save the dashboard when done.

---

## Part 6 — Cleanup

```bash
docker compose down

# To also remove stored data volumes:
docker compose down -v
```

---

## Discussion questions

1. The Node Exporter runs with `volumes: ["/proc:/host/proc:ro", "/sys:/host/sys:ro"]`.
   Why does it need access to these paths? What would happen if you removed them?
2. You connected Grafana to Prometheus using `http://prometheus:9090` instead of
   `http://localhost:9090`. Why does `localhost` not work here?
3. The CPU query uses `rate(...[5m])`. What would happen if you changed the
   range to `[1m]`? Would the graph be more or less accurate? More or less noisy?
4. What is the difference between importing a community dashboard and building
   one from scratch? When would you prefer each approach?

---

## Key concepts

| Concept | Description |
|---------|-------------|
| Node Exporter | Agent that reads `/proc` and `/sys` and exposes host metrics at `:9100/metrics` |
| `node_cpu_seconds_total` | Counter of CPU time per core and mode. Always use `rate()` on it. |
| Grafana data source | A connection from Grafana to a metrics backend (Prometheus, in this case) |
| Dashboard import | Load a pre-built community dashboard by ID from grafana.com/dashboards |
| `rate(counter[5m])` | Per-second average rate of increase over the last 5 minutes |
| Docker network | Services on the same Compose network reach each other by container name |
