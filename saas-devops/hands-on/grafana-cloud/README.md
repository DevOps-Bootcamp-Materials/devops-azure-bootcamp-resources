# Grafana Cloud free tier — monitor a local cluster via remote_write

This is the deep-dive companion to the bootcamp hands-on `week-18/saas-devops/hands-on/03_grafana_cloud_remote_write.md`. The bootcamp file walks the flow; this README explains the machinery: the remote_write protocol, the credential model (and the `glc_`/`glsa_` trap), the two relabeling stages and which one to use, the cardinality numbers we measured and why, Grafana Alloy as the lighter alternative, and the rest of the free tier (logs, traces) you can reach the same way.

## What this folder contains

- `README.md` — this file
- `commands.sh` — the complete command sequence
- `values-remote-write.yaml` — kube-prometheus-stack values: local UI disabled, 2h retention, remoteWrite to the cloud, and the allowlist `writeRelabelConfigs` that lands under the free budget

## Prerequisites

- Docker Desktop, `k3d`, `kubectl`, `helm`
- A free Grafana Cloud account; a `glc_` Access Policy token in `$GRAFANA_CLOUD_TOKEN`
- The free-tier DevOps toolbox lesson

---

## Part 1 — What remote_write actually is

`remote_write` is a Prometheus protocol: the local Prometheus batches the samples it scrapes and POSTs them, Snappy-compressed protobuf, to a remote endpoint that speaks the same protocol. Grafana Cloud's hosted Prometheus (built on Mimir) is such an endpoint. The shape:

```
local pods → local Prometheus (scrape) → remote_write batches → HTTPS POST →
  Grafana Cloud (Mimir) → stored + queryable via the same PromQL API
```

The local Prometheus is reduced to a **forwarder with a tiny buffer**: 2h retention locally is plenty because the data's real home is the cloud. Two properties matter:

- **It is push, not pull.** The cloud never connects to your laptop — your Prometheus initiates the outbound POST. That is why this works behind NAT/firewalls with no inbound exposure (same reason tunnels work).
- **It is lossy under backpressure.** If the endpoint is slow or you exceed limits, the local queue fills and samples are dropped (with `prometheus_remote_storage_samples_dropped_total` ticking up). Watch that metric if data looks incomplete.

## Part 2 — Credentials: the `glc_` vs `glsa_` trap (verified)

Grafana issues several token types and they are not interchangeable:

| Token | Prefix | Created in | Works for remote_write / Cloud API? |
|---|---|---|---|
| Cloud Access Policy token | `glc_` | **grafana.com portal** → Security → Access Policies | **Yes** — this is the one |
| Grafana service-account token | `glsa_` | *Inside* your `*.grafana.net` → Administration → Service accounts | No — only for the Grafana HTTP API (dashboards, etc.) |
| Legacy API key | `eyJ...` | Deprecated | Being retired |

We hit this live: a `glsa_` token returned `{"code":"InvalidCredentials","message":"Token could not be parsed"}` from `grafana.com/api/instances`. The fix is an Access Policy token with `metrics:write` (push), `metrics:read` (query-back verification), `stacks:read` (the instance discovery in Step 1). Scope it to exactly those; treat it like a password.

**The instance ID is the username.** Basic auth for both push and query is `<hmInstancePromId>:<glc_token>` — e.g. `3301080:glc_...`. A 401 on push almost always means you used the wrong username (the stack slug instead of the numeric ID) or a `glsa_` token.

## Part 3 — Two relabeling stages, and which to use

Prometheus has two relabel hooks that people constantly confuse:

| Stage | Field | Runs | Use for |
|---|---|---|---|
| **metricRelabelings** | per scrape job (`metricRelabelings`) | After scrape, before local storage | Drop series you never want stored at all |
| **writeRelabelConfigs** | per remote_write (`writeRelabelConfigs`) | After local storage, before push | Store locally but ship only a subset to the cloud |

This hands-on uses **`writeRelabelConfigs`**: keep full fidelity locally (for live debugging via port-forward) but ship only the curated allowlist to the cloud (to fit the budget). If you never need the local data, `metricRelabelings` is lighter (less stored). Both take the same relabel rules; the difference is *when* and *what is affected*.

The relabel actions used:

- `action: keep` with `sourceLabels: [job]` — drop every series whose `job` is not in the regex.
- `action: keep` with `sourceLabels: [__name__]` — of what remains, drop every series whose metric name is not in the allowlist.

Two `keep` stages compose as AND: a series must pass both to be shipped.

## Part 4 — The cardinality numbers, explained (measured)

Active series is the billing unit of every managed Prometheus. Measured on a 1-server/1-agent k3d cluster, querying the cloud / the local TSDB:

| Strategy | Series | Why |
|---|---|---|
| Keep 4 jobs (kubelet, ksm, node-exporter, apiserver) | **72,561** | kubelet carries cadvisor `container_*` (per-container × per-metric); apiserver carries huge request/response histograms |
| + drop `container_*` + big `*_bucket` histograms | **47,894** | removes the cadvisor and histogram bombs, but kubelet/apiserver still expose thousands of base series each |
| Allowlist: 2 jobs (node-exporter + ksm) + ~16 metric names | **478** | only curated, low-cardinality, high-value series leave the cluster |

The lesson, stated plainly: **you cannot shrink a kube-prometheus-stack into 10k by subtraction.** The kubelet and apiserver jobs are structurally enormous. The only reliable path is *addition from zero* — an allowlist of metric names you actually use. This is exactly what Grafana's official Kubernetes integration ships (a long curated allowlist), and what every team eventually does to control a managed-Prometheus bill. The skill transfers directly to paid tiers: active series is the line item that grows silently and blows budgets.

Cardinality sources to memorize (the usual suspects):

- **cadvisor `container_*`** — multiplies by every container × every metric × every label. The #1 bomb.
- **Histogram `*_bucket` series** — each histogram is N bucket series; apiserver/etcd/rest_client histograms have many buckets × many handlers.
- **High-cardinality labels** — anything with `pod`, `id`, `path`, `le` (bucket) labels fans out fast.
- **kube-state-metrics** scales with object count — usually fine on a lab, watch it on big clusters.

## Part 5 — Grafana Alloy: the lighter agent

kube-prometheus-stack runs a full Prometheus locally. If all you want is to forward to the cloud, **Grafana Alloy** (the successor to the Grafana Agent) is purpose-built: it scrapes and remote_writes without keeping a queryable local TSDB, with a smaller footprint, and Grafana Cloud's "Kubernetes Monitoring" onboarding generates an Alloy config with the allowlist already baked in. For this hands-on we used kube-prometheus-stack because students have already met it and the port-forward "see it locally too" step is pedagogically useful — but in a real zero-cost setup, Alloy is the leaner choice. The `remote_write` concepts and the cardinality discipline are identical.

## Part 6 — The rest of the free tier reachable the same way

The 50 GB each of logs, traces, and profiles are reached with the same Access Policy token (add `logs:write`, `traces:write` scopes):

- **Logs** → Grafana Loki via Alloy/Promtail `loki.write` to the stack's Loki push URL.
- **Traces** → Grafana Tempo via OTLP to the stack's Tempo endpoint.
- **Profiles** → Pyroscope.

Same model throughout: tiny local agent, hosted backend, one token, cardinality/volume budget to respect. A complete personal observability stack — metrics + logs + traces — at zero cost, for any local cluster.

## Cleanup

```bash
k3d cluster delete gcloud-demo
# Active series decay to 0 once nothing writes; shipped data persists until 14-day retention.
```

## Discussion questions

1. remote_write is push-based. Explain why that makes Grafana Cloud reachable from a laptop behind NAT, and name the local metric you would watch to detect dropped samples.
2. You used a `glc_` token and got a 401 on push anyway. Walk the two most likely causes before you suspect the token itself.
3. Dropping `container_*` cut series from 72k to 48k but not under 10k. Why is subtraction the wrong strategy here, and what is the right one?
4. When would you put a filter in `metricRelabelings` instead of `writeRelabelConfigs`? What do you give up either way?
5. Your allowlist ships 478 series for a lab cluster. A teammate adds 200 microservices. Which of your allowlisted metrics grows, which stays flat, and how would you predict the new series count before deploying?
6. Grafana Cloud bills on active series; so does every managed Prometheus. How does the discipline you practiced here translate to keeping a production observability bill flat?

## Troubleshooting

| Symptom | Root cause | Fix |
|---|---|---|
| `InvalidCredentials / Token could not be parsed` from grafana.com/api | Using a `glsa_` (in-Grafana service account) token | Create a `glc_` Access Policy token in the grafana.com portal |
| 401 on remote_write push | Username is the slug, not the numeric instance ID; or wrong token | Use `<hmInstancePromId>:<glc_token>`; verify scopes include `metrics:write` |
| Data pushes but query-back is empty | Queried the wrong instance/region URL | Use the exact `hmInstancePromUrl` from Step 1; append `/api/prom` for the query API |
| Active series far over budget | Shipping full kube-prometheus-stack | Apply the allowlist `writeRelabelConfigs` (Part 4) |
| `prometheus_remote_storage_samples_dropped_total` rising | Hitting rate/series limits; backpressure | Tighten the allowlist; check the cloud's usage page for limit errors |
| 429 / `per-metric series limit` errors in Prometheus logs | Exceeded the free active-series limit | Reduce series before they are sent (allowlist), not after |
| Metrics stop after cluster delete but still show "active" briefly | Active-series window has not elapsed | Expected — decays to 0 within the window once nothing writes |
| Prometheus pod OOMKilled | remote_write queue + full scrape on a small cluster | Raise memory in the values, or switch to Alloy (Part 5) |

## References

- [Prometheus — remote_write spec](https://prometheus.io/docs/specs/prw/remote_write_spec/) — the wire protocol Grafana Cloud ingests
- [Grafana Cloud — Metrics overview](https://grafana.com/docs/grafana-cloud/send-data/metrics/) — endpoints, auth, and limits
- [Grafana Cloud — Access Policies and tokens](https://grafana.com/docs/grafana-cloud/account-management/authentication-and-permissions/access-policies/) — the `glc_` token model used here
- [Grafana Cloud — Control metrics costs / cardinality](https://grafana.com/docs/grafana-cloud/cost-management-and-billing/reduce-costs/metrics-costs/control-metrics-usage/) — the official cardinality-reduction guidance behind Part 4
- [Grafana Alloy](https://grafana.com/docs/alloy/latest/) — the lighter remote_write agent from Part 5
- [kube-prometheus-stack chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) — the chart and every value, including `remoteWrite` and relabeling
- [Prometheus — relabeling](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#relabel_config) — `metricRelabelings` vs `writeRelabelConfigs` semantics
