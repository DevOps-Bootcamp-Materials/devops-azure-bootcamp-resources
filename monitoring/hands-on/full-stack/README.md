# Full Monitoring Stack — Prometheus + Grafana + Node Exporter

> **Two hands-on share this folder.** Part A is the entry point referenced from the bootcamp's `02_full_stack_prometheus_grafana.md` (stack setup, datasource provisioning, first panels). Part B is referenced from `06_grafana_dashboards.md` (build dashboards from scratch, parametrize with variables, share as JSON). The Docker Compose, Prometheus config and Grafana provisioning are the same for both — what differs is the focus of the walkthrough. Run the stack once (Part A's "Start the stack" section), then move on to whichever Part the class is on.

## Assets in this folder

| File | What it does |
|---|---|
| `docker-compose.yml` | Brings up Prometheus, Grafana, two Node Exporters and a demo app on a shared bridge network. |
| `prometheus.yml` | Scrape config — Prometheus scrapes itself, both Node Exporters, and the demo app. |
| `grafana/provisioning/datasources/prometheus.yml` | Grafana loads the Prometheus datasource on startup. No manual setup. |
| `grafana/provisioning/dashboards/dashboards.yml` | Tells Grafana to watch `/var/lib/grafana/dashboards` and auto-import any JSON found there. |
| `grafana/dashboards/host_and_app.json` | The finished Part B dashboard (CPU, memory, network, p95 latency, two variables). |

---

## Part A — Stack setup, datasource as code, first panels

Companion to bootcamp hands-on `02_full_stack_prometheus_grafana.md`.

### Objective

In the previous hands-on you queried Prometheus metrics using only the Expression Browser. Real operations work happens in Grafana dashboards that teams can share, alert from, and iterate on without writing PromQL by hand.

This hands-on introduces the standard three-tier monitoring stack and the workflow for building dashboards on top of it.

By the end of Part A you will be able to:

- Run a production-representative monitoring stack with Docker Compose.
- Understand what Node Exporter does and what metrics it exposes.
- See how Grafana datasource provisioning works.
- Import an existing community dashboard.
- Build a custom panel from scratch using a PromQL query.

### Prerequisites

```bash
cd monitoring/hands-on/full-stack

# Confirm nothing is using ports 9090, 3000, 9100, 9101 or 8080
# (Linux/macOS) — on Windows use Get-NetTCPConnection or netstat -ano
lsof -i :9090 -i :3000 -i :9100 -i :9101 -i :8080 2>/dev/null || echo "check ports manually"
```

### A.1 — Start the stack

```bash
docker compose up -d

# Follow the logs to confirm all containers start cleanly
docker compose logs -f
# Press Ctrl+C when you see "msg=Server is ready to receive web requests" from Prometheus
```

Verify all targets are up in Prometheus:

```
http://localhost:9090/targets
```

You should see five targets — `prometheus`, two `node-exporter` instances (`node-exporter:9100` and `node-exporter-b:9100`) and `demo` — all `UP`.

**What is Node Exporter doing?** It reads hardware and OS metrics directly from Linux kernel interfaces (`/proc`, `/sys`) and exposes them as Prometheus metrics at port 9100. Run this to see the raw output:

```bash
curl -s http://localhost:9100/metrics | grep "^node_cpu" | head -20
```

Each line is a time series. Notice the `mode` label: `idle`, `user`, `system`, `iowait`, etc. Node Exporter does not interpret these values — it just exposes them. The interpretation (e.g., "CPU is overloaded") happens in PromQL queries or Grafana alert rules.

**Why two Node Exporters?** Both containers read the same `/proc` underneath, so the metric values will be nearly identical. The point is that Prometheus sees them as **two distinct `instance` label values**, which makes the `$instance` dashboard variable in Part B meaningful (a dropdown with one option is not a dropdown). For Part A this is just bonus realism.

### A.2 — Grafana provisioning: datasource as code

Open Grafana at `http://localhost:3000` and log in with `admin / admin`. Skip the password change prompt for now.

Go to **Connections → Data sources**. You will see a Prometheus datasource already configured — you did not add it manually. This is **Grafana provisioning**.

Look at `grafana/provisioning/datasources/prometheus.yml`. That YAML file was mounted into the Grafana container at `/etc/grafana/provisioning/datasources/` and loaded automatically at startup. It defines the datasource name, URL, and a stable `uid` (`prometheus-main`) that dashboards can reference by ID.

This is the recommended approach in production: datasource and dashboard configuration lives in your git repository alongside everything else, not in a Grafana database that someone has to export and back up manually.

Click the Prometheus datasource and scroll to the bottom — click **Save & test** to confirm it can reach Prometheus. You will see "Successfully queried the Prometheus API."

### A.3 — Import the Node Exporter Full dashboard

The Grafana community maintains hundreds of pre-built dashboards published at `grafana.com/grafana/dashboards`. Dashboard **1860** ("Node Exporter Full") is the most-used host monitoring dashboard in production.

1. In the left sidebar, click **Dashboards → New → Import**.
2. In the **Find and import dashboards** field, enter `1860` and click **Load**.
3. Select the **Prometheus** data source you saw above.
4. Click **Import**.

Spend two minutes exploring the dashboard:

- What is the current CPU utilization? (Look for the "CPU Busy" panel.)
- How much memory is available vs used?
- What is the disk read/write throughput?
- At the top, the **Host** dropdown lets you switch between the two `instance` values — this is a dashboard variable in action. We build one of these from scratch in Part B.

These are all PromQL queries that Grafana is running against Prometheus in the background. Click the title of any panel and select **Edit** to see the query.

### A.4 — Build a custom panel from scratch

You will build a panel that shows the CPU utilization percentage of the host as a time series graph.

1. Click **Dashboards → New dashboard → Add visualization**.
2. Select the **Prometheus** data source.
3. In the query editor, switch to **Code** mode (toggle in the top right of the query box) and enter:

   ```promql
   100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
   ```

4. Click **Run queries**. You should see a graph line between 0 and 100.

**Understanding this query:**

- `node_cpu_seconds_total` is a counter that tracks total CPU time per mode and per core.
- `rate(...[5m])` converts it to a per-second rate over the last 5 minutes.
- `avg(...)` averages across all CPU cores **and across both Node Exporter instances** — since we did not break it out by `instance`. In Part B we fix that with a variable.
- The `mode="idle"` filter gives us the fraction of time CPUs spent idle.
- We multiply by 100 to get a percentage, then subtract from 100 to get "time doing work" rather than "time doing nothing".

5. Set the **Panel title** to `CPU Utilization (%)`.
6. In the right panel, under **Standard options**, set **Unit** to `Percent (0-100)` and **Max** to `100`.
7. Click **Save** (top right), name the dashboard `My Host Dashboard`.

### A.5 — Add two more panels

Add the following panels to the same dashboard.

**Available memory in GB** — suggested type **Stat**, unit `gigabytes`:

```promql
node_memory_MemAvailable_bytes / 1024 / 1024 / 1024
```

**Network traffic received (bytes/sec)** — suggested type **Time series**, unit `bytes/sec (SI)`. The `device!="lo"` filter excludes the loopback interface:

```promql
rate(node_network_receive_bytes_total{device!="lo"}[5m])
```

Save the dashboard when done. Part B picks up from here.

### A.6 — Cleanup (skip if continuing to Part B)

```bash
docker compose down

# To also remove stored data volumes:
docker compose down -v
```

### Discussion questions

1. The Node Exporter runs with `volumes: ["/proc:/host/proc:ro", "/sys:/host/sys:ro"]`. Why does it need access to these paths? What would happen if you removed them?
2. You connected Grafana to Prometheus using `http://prometheus:9090` instead of `http://localhost:9090`. Why does `localhost` not work here?
3. The CPU query uses `rate(...[5m])`. What would happen if you changed the range to `[1m]`? Would the graph be more or less accurate? More or less noisy?
4. What is the difference between importing a community dashboard and building one from scratch? When would you prefer each approach?

---

## Part B — Dashboards: build, parametrize, share

Companion to bootcamp hands-on `06_grafana_dashboards.md`.

### Objective

Part A got you from zero to a few hand-built panels. Real dashboards in production go further: one dashboard works for many targets (instances, environments, services) thanks to **variables**, and the dashboard itself lives **as code in git**, not as a hand-clicked artifact in someone's Grafana. Part B closes that gap.

By the end of Part B you will be able to:

- Build a dashboard with panels covering host metrics (CPU, memory, network) and application metrics (p95 latency).
- Parametrize the dashboard with `$instance` and `$handler` query variables so one dashboard serves many targets.
- Repeat a panel per variable value to see all instances side by side without a dropdown.
- Share a dashboard three ways — snapshot link, time-bounded share link, and JSON export auto-loaded via provisioning.

If you are continuing from Part A, the stack is already running. If not, start it with `docker compose up -d` from this folder and check `http://localhost:9090/targets` shows five UP targets.

### B.1 — Anatomy of a panel (build the CPU panel for real)

Open Grafana at `http://localhost:3000`, then **Dashboards → New dashboard → Add visualization**. Select the Prometheus datasource.

In **Code** mode, enter:

```promql
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
```

The only difference from Part A's query is `avg by (instance)` instead of `avg`. That gives us **one series per Node Exporter** instead of a single averaged line. With two instances you should see two distinct lines (very close together, since both read the same `/proc`).

Now walk the right-side panel options. These are the ones that matter daily:

| Section | Field | Set to | Why |
|---|---|---|---|
| Panel | Title | `CPU Utilization (%)` | Self-documenting at a glance |
| Standard options | Unit | `Percent (0-100)` | Without a unit Grafana shows `0.42` instead of `42%` |
| Standard options | Min / Max | `0` / `100` | Y-axis stays stable when load drops to zero |
| Graph styles | Line width | `2` | Easier to read at a glance |
| Graph styles | Fill opacity | `10` | Light shading under each line |
| Thresholds | Steps | `green/orange@70/red@90` | Visual cue when something is hot |
| Legend | Display mode | `Table` | One row per series with stats |
| Legend | Calculations | `Last *, Max` | Numbers next to each series |

Click **Apply** (top right) to drop the panel into the dashboard, then **Save dashboard** (disk icon). Call it `Host and App Overview`.

**Aside on `[5m]` vs `$__rate_interval`.** A hard-coded `[5m]` always covers 5 minutes. Grafana also offers `$__rate_interval`, a magic variable that picks a window adapted to the current zoom level and the scrape interval. It is the safer default for dashboards that get zoomed in and out — but it is one extra concept and we want one PromQL query to teach at a time. Use `[5m]` here and read about `$__rate_interval` in the references section below.

### B.2 — Stat panel with thresholds (memory available)

Click **Add → Visualization** in the dashboard.

```promql
node_memory_MemAvailable_bytes
```

In the visualization picker (top right), choose **Stat**. Then on the right:

- Title: `Memory Available`
- Unit: `bytes(IEC)` (Grafana auto-formats GB/MB/KB)
- Color mode (under Stat styles): `Background`
- Thresholds:
  - `red` from `0` (anything under the next step is red)
  - `orange` at `536870912` (512 MiB)
  - `green` at `2147483648` (2 GiB)

The stat now has a green/orange/red background depending on the value. **Same data, different read.** That is the panel-type lesson: the visualization decides how the data is interpreted by the eye; the query stays the same.

Note that this panel currently shows ONE value, not one per instance. We fix that with variables in B.4.

### B.3 — Latency panel from a histogram

Click **Add → Visualization**, time-series.

```promql
histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))
```

If you've done hands-on `01_prometheus_basics`, this shape is familiar — it is the canonical histogram quantile query. We `rate()` the bucket counter (mandatory — buckets are cumulative counters and never decrease), `sum by (le)` aggregates across labels we don't care about while keeping the bucket boundary, then `histogram_quantile()` interpolates the value below which 95% of observations fell.

Settings:

- Title: `p95 HTTP latency`
- Unit: `seconds (s)`
- Legend display: `Table`, calcs `max, mean`

If the demo app is idle and there are no requests in the last 5 minutes, generate some:

```bash
for i in $(seq 1 200); do curl -s http://localhost:8080/ > /dev/null; done
for i in $(seq 1 50);  do curl -s http://localhost:8080/err > /dev/null; done
```

Refresh the panel — a single line should appear with sub-millisecond values. **One line is expected.** The `brancz/prometheus-example-app` demo only registers one handler internally, so the histogram only has one series. In a real application you would typically `sum by (le, handler)` to break it out per endpoint — see hands-on `05_realistic_scenario.md` for a richer demo app where that comes alive.

### B.4 — Dashboard variable: `$instance`

A **variable** is a placeholder you can substitute into queries. The dashboard learns the list of valid values by running a "label values" query against Prometheus on load, and re-runs the panel queries every time the dropdown changes.

In the dashboard, click the **gear icon** (top right) → **Variables** → **Add variable**.

| Field | Value |
|---|---|
| Variable type | `Query` |
| Name | `instance` |
| Label | `Instance` |
| Data source | Prometheus |
| Query type | `Label values` |
| Label | `instance` |
| Metric | `node_exporter_build_info` |
| Refresh | `On dashboard load` |
| Multi-value | off |
| Include All option | off |

Click **Apply**, then **Back to dashboard**. A dropdown labelled `Instance` appears at the top — `node-exporter:9100` / `node-exporter-b:9100`.

Now rewrite the CPU panel query to use it:

```promql
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle", instance="$instance"}[5m])) * 100)
```

And the memory panel:

```promql
node_memory_MemAvailable_bytes{instance="$instance"}
```

Switch the dropdown — both panels rebind to the selected instance. **One dashboard, N targets.** This is the single most important property a production dashboard has.

#### Repeat a panel per variable value

What if you want to see both instances side by side without flipping the dropdown? Click the CPU panel title → **Edit** → on the right scroll to **Repeat options** → **Repeat by variable** = `instance`, **Max per row** = `2`. Click **Apply**.

You now have two CPU panels, one per instance, generated automatically from the variable. Add a new value to the variable later (a third Node Exporter) and the repeat picks it up without editing the dashboard.

### B.5 — Multi-value variable: `$code`

Add another variable, this time multi-value. Pedagogically `$code` (status code, two values: `200` and `404`) shows the multi-value experience well — the demo app's histogram has only one `handler` value, so a `$handler` variable would be a single-option dropdown and the multi-value lesson would not land.

| Field | Value |
|---|---|
| Variable type | `Query` |
| Name | `code` |
| Label | `Status code` |
| Query type | `Label values` |
| Label | `code` |
| Metric | `http_requests_total` |
| Multi-value | on |
| Include All option | on |
| Custom all value | `.*` |

Then add a new panel. **Add → Visualization** → time-series.

```promql
sum by (code) (rate(http_requests_total{code=~"$code"}[5m]))
```

- Title: `Request rate by status code`
- Unit: `requests/sec (1/s)` (or `short`)
- Legend format: `{{code}}`

Two important things in the query:

- `code=~"$code"` uses the **regex match operator `=~`** because multi-value variables interpolate as a regex alternation (`200|404`). The exact match `="$code"` does not work in multi-value mode — there is no single status string that equals "200|404".
- `Custom all value = ".*"` makes "All" interpolate as the regex `.*` — matches any code. Without it, "All" interpolates as the literal `$__all` and the panel returns no series.

Tick and untick codes — lines appear and disappear. Pick "All" — both come back.

### B.6 — Save and inspect the JSON model

Click **Save dashboard** (disk icon, top right) → keep the name `Host and App Overview`.

Now click the **gear icon → JSON Model**. This is your dashboard as JSON. Every panel, every variable, every threshold, every legend setting is in there. Two things to notice:

- The `templating.list` array contains your two variables, exactly as you configured them.
- Each panel under `panels` has its `targets` (the PromQL queries) and a `fieldConfig` with the unit/min/max/thresholds you set.

This JSON is what "dashboard as code" means. You can copy it to a file in git and Grafana can load it from disk at startup. Let's do exactly that.

### B.7 — Share three ways

#### B.7.1 — Snapshot (point-in-time, no live data)

Click the **Share** icon (next to the dashboard title) → **Snapshot** tab → **Publish to snapshots.raintank.io** is disabled in self-hosted, so use **Local Snapshot** → **Publish**.

You get a URL like `http://localhost:3000/dashboard/snapshot/<id>`. Open it in a private window — no login needed, no datasource needed. The data is **embedded** at the moment of publishing. Useful for incident post-mortems ("here is what the dashboard looked like at 14:02 UTC") or for sharing with someone who does not have Grafana access.

Snapshots are also why we set `GF_SECURITY_ALLOW_EMBEDDING=true` in the compose — without it the share-as-iframe variant is blocked.

#### B.7.2 — Share link with time range

Same Share dialog → **Link** tab → toggle **Lock time range** → copy the URL. The link encodes the dashboard UID, the current time range (`from`/`to` as epoch ms), and the current variable selections. Pasting it into Slack reproduces exactly what you are seeing — including which instance is selected.

This is the canonical "look at this" link during an incident. It is shareable but live: the receiver sees the current data within the locked time window.

#### B.7.3 — Dashboard as code (the prod-grade way)

This is what teams actually run with.

1. Copy the JSON Model from B.6 to a file on your machine.
2. Save it into `grafana/dashboards/host_and_app.json` in this folder (overwrite the example we ship if you want — your hand-built version is now canonical).
3. Restart Grafana so it re-reads the provisioning configuration:

   ```bash
   docker compose restart grafana
   ```

4. After a few seconds, open Grafana → **Dashboards** → **Course** folder. Your dashboard is there, marked as "provisioned" (small icon next to the title — editing is allowed because we set `allowUiUpdates: true` in `dashboards.yml`, but Grafana warns you that on-disk wins on restart).

The loop that closes this picture in production:

```
edit dashboard in Grafana → save → export JSON → commit JSON to git → CI deploys
provisioning folder → Grafana picks it up automatically on next reload
```

No one ever clicks anything in production. Dashboards are reviewed in pull requests like code.

The dashboard we ship in `grafana/dashboards/host_and_app.json` is essentially the dashboard you just built — keep yours, or use the shipped one as an answer key.

### B.8 — Cleanup

```bash
docker compose down

# To also remove stored data volumes (Prometheus TSDB + Grafana DB):
docker compose down -v
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Grafana datasource Save & test` fails with `Bad Gateway` | Grafana tried to reach `http://prometheus:9090` but the container is not on the same network or is still starting. | `docker compose ps` — wait until `prometheus` is healthy; check both containers are on the `monitoring` network (`docker network inspect full-stack_monitoring`). |
| `$instance` dropdown is empty | Variable query returned no series. Most likely `node_exporter_build_info` is not yet scraped. | Wait 15s for the first scrape; re-open the dashboard. Confirm in Prometheus that `node_exporter_build_info` returns rows. |
| `$instance` dropdown has only one value | Only one Node Exporter is being scraped. | Check `prometheus.yml` — both `node-exporter:9100` and `node-exporter-b:9100` should be listed; `http://localhost:9090/targets` should show two UP node-exporter targets. |
| `$code=~"$code"` panel shows nothing when "All" is selected | Custom all value is empty or `$__all` instead of `.*`. Empty interpolates as an empty regex and matches nothing in some PromQL versions. | Variable settings → set `Custom all value` to `.*`. |
| `$code` dropdown only shows `200` (or empty) | No traffic has reached the demo app yet, so `http_requests_total` has not been recorded with the 404 code. | Generate some 404 traffic (`for i in $(seq 1 20); do curl -s http://localhost:8080/notapath > /dev/null; done`) and wait one scrape interval. |
| `$handler` variable returns no values | The demo app exposes `handler` only on `http_request_duration_seconds_bucket`, not on `http_requests_total`. | Use `label_values(http_request_duration_seconds_bucket, handler)` — but the only value is `found`. For real handler variety use the `realistic-scenario` demo app instead. |
| Snapshot link returns 404 in a private window | The local snapshot store was wiped (`docker compose down -v`). | Snapshots live in the `grafana-data` volume; do not use `down -v` if you want them to persist. |
| Provisioned dashboard does not appear | JSON in wrong folder, JSON invalid, or filename has spaces/odd characters. | `docker compose logs grafana | grep -i provisioning` shows parse errors. Validate the JSON with `jq . file.json`. |
| Histogram quantile returns `NaN` | No requests in the last 5 minutes — every bucket rate is zero, division undefined. | Generate traffic (`for i in $(seq 1 200); do curl -s http://localhost:8080/ > /dev/null; done`). |
| Two CPU lines on top of each other | Both Node Exporters read the same `/proc` so the values match. | Expected. The point is the `instance` label is different, not the values. |
| `node_exporter` and `node-exporter-b` show different filesystem mounts | They genuinely run in different containers with subtly different views of `/`. | Expected. Filesystem metrics will diverge slightly between the two. |

---

## References

- [Grafana — Variables](https://grafana.com/docs/grafana/latest/dashboards/variables/) — official reference for all variable types (query, custom, datasource, interval, text box, constant, ad-hoc, global).
- [Grafana — Variable syntax and interpolation](https://grafana.com/docs/grafana/latest/dashboards/variables/variable-syntax/) — exact rules for `$var`, `${var}`, `${var:regex}`, `${var:csv}` and what each does in multi-value mode.
- [Grafana — Provision dashboards and data sources](https://grafana.com/docs/grafana/latest/administration/provisioning/) — the official guide to the configuration files we mounted into `/etc/grafana/provisioning/`.
- [Grafana — Dashboard JSON model](https://grafana.com/docs/grafana/latest/dashboards/build-dashboards/view-dashboard-json-model/) — every field you saw in the JSON Model dialog explained.
- [Grafana — Share dashboards and panels](https://grafana.com/docs/grafana/latest/sharing/share-dashboard/) — links, snapshots, embeds, and what data each form includes.
- [Grafana — `$__rate_interval`](https://grafana.com/blog/2020/09/28/new-in-grafana-7.2-__rate_interval-for-prometheus-rate-queries-that-just-work/) — the magic variable that adapts the rate window to the dashboard zoom level.
- [Brian Brazil — PromQL for Grafana](https://www.robustperception.io/common-query-patterns-in-promql) — query patterns that are dashboard-friendly.
