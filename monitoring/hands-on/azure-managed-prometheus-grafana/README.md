# Monitoring — Azure Monitor managed Prometheus + Azure Managed Grafana on AKS

Deep-dive companion to `week-15/monitoring/hands-on/02_azure_managed_prometheus_grafana.md`. The bootcamp hands-on walks through the demo end-to-end with focused explanations; this README is where the architecture, the misconceptions, and the troubleshooting live. Read it after the bootcamp file, or skim straight to the parts you need.

The hands-on swaps the self-managed `kube-prometheus-stack` (W15.1) for the Azure-native managed pair: an **Azure Monitor Workspace** as the Prometheus store + query API, and an **Azure Managed Grafana** as the visualization layer. The AKS cluster ingests metrics via the **Azure Monitor metrics add-on** (`ama-metrics`), which is a customised Prometheus running as a deployment plus a DaemonSet inside `kube-system`.

## What this folder contains

- `README.md` — this file: the full deep-dive.
- `provision.sh` — single idempotent script with every `az` command from steps 2–4 of the bootcamp hands-on.
- `manifests/namespace.yaml` — `demo-app` namespace.
- `manifests/deployment.yaml` — `brancz/prometheus-example-app` (same image used in W14 hands-on 02 and W15.1).
- `manifests/service.yaml` — ClusterIP service in front of the deployment.
- `manifests/pod-monitor.yaml` — `PodMonitor` CRD under the forked `azmonitoring.coreos.com/v1` API group (see Part 4 for why).
- `manifests/logs/log-generator.yaml` — a chatty workload (DEBUG/INFO/WARN/ERROR to stdout) used by the optional **logs** flow (Part 8). In a subfolder so the metrics `kubectl apply -f manifests/` (non-recursive) never picks it up.
- `ama-metrics-prometheus-config.example.yaml` — example custom scrape config via ConfigMap (Part 6). Kept **outside** `manifests/` on purpose so `kubectl apply -f manifests/` does not overwrite the add-on's live ConfigMap by mistake.

## Prerequisites

- Active Azure subscription with permissions to create `Microsoft.ContainerService/managedClusters`, `Microsoft.Monitor/accounts`, `Microsoft.Dashboard/grafana`, and to assign the `Monitoring Data Reader` role.
- `az` CLI 2.55+ logged in. The Monitor / Grafana / AKS providers must be registered (the script will surface a clear error if any are not).
- `kubectl` and `jq` installed.
- Familiarity with W15.1 (`kubernetes-monitoring`) — the comparison is the point of this hands-on.

## How to use this folder

```bash
git clone https://github.com/DevOps-Bootcamp-Materials/devops-azure-bootcamp-resources.git
cd devops-azure-bootcamp-resources/monitoring/hands-on/azure-managed-prometheus-grafana

# Provision everything (RG, Workspace, Grafana, AKS with add-on)
bash provision.sh

# Deploy the sample app + PodMonitor
kubectl apply -f manifests/

# At the end:
az group delete --name rg-bootcamp-test-azmon-prom-grafana --yes --no-wait
```

---

## Part 1 — Architecture in full

### 1.1 What the managed pair replaces

Compared to `kube-prometheus-stack` (W15.1), the managed pair makes the following components disappear from your responsibility:

| W15.1 (self-managed)                           | This hands-on (managed)                                 |
|------------------------------------------------|---------------------------------------------------------|
| Prometheus server (StatefulSet, PVC, TSDB)     | Azure Monitor Workspace — managed, durable storage      |
| Grafana StatefulSet + persistent volume        | Azure Managed Grafana — multi-tenant managed service    |
| Alertmanager StatefulSet                       | Azure Monitor alert rules + Action Groups (separate)    |
| node-exporter DaemonSet                        | Part of `ama-metrics-node` DaemonSet                    |
| kube-state-metrics Deployment                  | Deployed by the add-on, in `kube-system`                |
| Scrape config maintenance                      | Curated set + your PodMonitor/ServiceMonitor CRDs       |

The data path is otherwise the same:

```
   Pods / kubelet / cAdvisor / kube-state-metrics
                    │
                    ▼  (scraped locally by the add-on)
         ┌─────────────────────────┐
         │  ama-metrics replicas   │   (Deployment, 2 replicas)
         │  ama-metrics-node DS    │   (1 pod per node)
         └─────────────────────────┘
                    │
                    │  Prometheus remote_write (HTTPS,
                    │  AAD token in `Authorization` header)
                    ▼
         ┌─────────────────────────┐
         │ Azure Monitor Workspace │   (managed Prometheus TSDB,
         │  - ingestion endpoint   │    18-month retention by default)
         │  - query endpoint       │
         └─────────────────────────┘
                    ▲
                    │  PromQL via /api/v1/query, AAD-authenticated
                    │
         ┌─────────────────────────┐
         │ Azure Managed Grafana   │   (Essential SKU)
         └─────────────────────────┘
```

### 1.2 The `ama-metrics` add-on is a Prometheus fork

`ama-metrics` is not "Azure code that pretends to be Prometheus". It is the upstream Prometheus codebase, packaged with Azure-specific bits:

- A small wrapper that pulls scrape config from a known ConfigMap shape (`ama-metrics-prometheus-config`, `ama-metrics-prometheus-config-node`, etc.) and from the Prometheus Operator CRDs (`PodMonitor`, `ServiceMonitor`).
- Remote-write configured by default to your Azure Monitor Workspace, using an AAD token instead of basic auth.
- A "metrics extension" sidecar (the `metrics-extension` container in each pod) that handles the AAD token acquisition and the remote-write authentication.
- No on-disk TSDB. The local Prometheus storage is sized to a tiny WAL buffer; the workspace is the real store.

Because it is upstream Prometheus, `PodMonitor`/`ServiceMonitor` work exactly as they do in `kube-prometheus-stack`, and the **PromQL semantics are identical**. The differences you can observe in practice are:

- **Retention is not controlled by `--storage.tsdb.retention.time` on the local pod** — it is fixed at 18 months on the workspace side (configurable upward at higher cost).
- **Remote-write back-pressure**: if the workspace ingestion endpoint throttles, the add-on buffers in memory and drops oldest first. You can monitor this with `ama-metrics`-internal metrics like `prometheus_remote_storage_samples_pending`.
- **Default scrape config is curated**: the chart-managed Prometheus would scrape every Operator-flagged target on the cluster, but the add-on starts with a focused list (kubelet, cAdvisor, node-exporter, kube-state-metrics, kube-proxy, the API server, and a few CoreDNS bits). Anything else you want, you bring with a PodMonitor / ServiceMonitor / custom ConfigMap.

### 1.3 The DCR / DCE / DCRA trio

When `--enable-azure-monitor-metrics` runs on `az aks create`, three Azure resources are created in addition to the visible ones:

- **Data Collection Endpoint (DCE)** — the URL the add-on remote-writes to. Lives in the workspace's region. Its existence allows the add-on to authenticate via AAD without baked-in secrets.
- **Data Collection Rule (DCR)** — a JSON document that says "samples arriving at this DCE should be stored in this workspace, with these data flows". For managed Prometheus the rule is very narrow: one flow, source `Microsoft-PrometheusMetrics`, destination the workspace.
- **Data Collection Rule Association (DCRA)** — the link between the rule and the AKS cluster (the resource that owns the add-on identity).

You will rarely edit these by hand, but knowing they exist is critical because **broken DCRA is the single most common cause of "I enabled the add-on but no metrics show up"**. The troubleshooting table at the bottom of this README shows how to inspect them.

References:
- [Azure Monitor managed service for Prometheus — overview](https://learn.microsoft.com/azure/azure-monitor/metrics/prometheus-metrics-overview)
- [Collect Prometheus metrics from AKS — high-level](https://learn.microsoft.com/azure/azure-monitor/containers/kubernetes-monitoring-enable)
- [Data collection rules — concept](https://learn.microsoft.com/azure/azure-monitor/essentials/data-collection-rule-overview)

---

## Part 2 — Provisioning, step by step

`provision.sh` runs the four commands the bootcamp hands-on covers individually. The reason it exists as a script is that you will end up re-running this hands-on more than once (re-testing on a fresh subscription, demoing twice in two cohorts, etc.) and the unattended path through provisioning is too useful to leave only in markdown.

### 2.1 Resource group

Nothing surprising. The script uses a per-hands-on RG (`rg-bootcamp-test-azmon-prom-grafana`) so the final cleanup is one command and there is no chance of orphaning resources by RG-name confusion.

### 2.2 Azure Monitor Workspace

`az monitor account create` provisions the workspace. The CLI verb is `monitor account`, not `monitor workspace`, for legacy naming reasons — there is a separate `monitor log-analytics workspace` family for Logs. The two are different products and create different resource types:

- `Microsoft.Monitor/accounts` — Azure Monitor Workspace (managed Prometheus).
- `Microsoft.OperationalInsights/workspaces` — Log Analytics workspace (managed Logs).

When students search "Azure Monitor workspace" in the portal they will find both. The bootcamp hands-on is about the first.

### 2.3 Azure Managed Grafana — SKU choice

The script uses `--sku Standard`. Standard is the SKU the Microsoft Learn integration documentation explicitly lists as the prerequisite for connecting an Azure Monitor Workspace as a data source. Essential carries no per-hour charge but does not support that integration path — and using a portal/CLI command that the SKU doesn't support produces confusing "feature not enabled" errors that are not worth the savings during a 1-hour test.

Standard is priced per hour (~$0.20/h at the time of writing). For a bootcamp test session that is on the order of cents; for an always-on demo environment it is on the order of $150/month. Plan cleanup accordingly.

If you genuinely need Essential — for example, a long-running classroom Grafana instance with cheap dashboards that talk to non-AMW data sources — keep the SKU at Essential and add the data source by hand (URL = workspace query endpoint, Authentication = Azure Authentication, App Registration credentials). The lab `02_lab_monitoring_azure_container_app.md` walks through that manual path.

### 2.4 The Grafana ↔ Workspace integration command

```bash
az grafana integrations monitor add \
  --name "$GRAFANA" --resource-group "$RG" \
  --monitor-name "$AMW" \
  --monitor-resource-group-name "$RG"
```

(The Microsoft Learn page sometimes shows the older `az grafana update --azure-monitor-workspace-integrations` shape — that flag does not exist in the current `amg` CLI extension. Use the `integrations monitor add` subcommand.)

This single command does three things internally:

1. Provisions a data source inside the Grafana instance, of type `prometheus`, with the URL pointing at the workspace's `prometheusQueryEndpoint` and `Azure Authentication` set to `Managed Identity`.
2. Grants the Grafana instance's system-assigned managed identity the `Monitoring Data Reader` role at the **workspace** scope. This is what allows Grafana, in turn, to acquire AAD tokens for the workspace API.
3. Imports a folder of pre-built Kubernetes dashboards into Grafana (the ones the bootcamp hands-on tours in step 8).

If you ever need to do this by hand — e.g. against an external Grafana, not a Managed one — the equivalent is: register an AAD app, give it `Monitoring Data Reader` on the workspace, and configure the Grafana data source with `Azure Authentication: App Registration` and the app's tenant / client ID / client secret. The lab `02_lab_monitoring_azure_container_app.md` walks students through that path explicitly.

### 2.5 AKS create with the metrics add-on

```bash
az aks create ... --enable-azure-monitor-metrics --azure-monitor-workspace-resource-id "$AMW_ID"
```

The two flags must appear together. `--enable-azure-monitor-metrics` is the actual on-switch; `--azure-monitor-workspace-resource-id` tells the add-on which workspace to remote-write to. If you only give the first flag, the CLI errors out (`workspace resource id is required`). The third flag you might expect — `--azure-monitor-workspace-location` — is inferred from the workspace.

If your cluster already exists, the equivalent is:

```bash
az aks update --resource-group "$RG" --name "$AKS" \
  --enable-azure-monitor-metrics \
  --azure-monitor-workspace-resource-id "$AMW_ID"
```

To remove the add-on:

```bash
az aks update --resource-group "$RG" --name "$AKS" --disable-azure-monitor-metrics
```

Disabling the add-on does **not** delete the workspace or the DCR. The historical data stays where it is. Removing the cluster also leaves the workspace intact — useful when you reprovision clusters but want to keep history.

---

## Part 3 — Verifying the data path

The bootcamp hands-on shows two verification points (kubectl pods + a curl to the workspace query endpoint). Here is the longer list, in order of "narrow the failure".

### 3.1 The add-on pods are running

```bash
kubectl get pods -n kube-system -l rsName=ama-metrics
kubectl get pods -n kube-system -l dsName=ama-metrics-node
```

The `rsName=ama-metrics` label is what the add-on's ReplicaSet sets on its pods. Two pods, `Running 2/2` (the second container is the `metrics-extension` token sidecar). The DaemonSet has one pod per node.

If pods are `CrashLoopBackOff`, look at the `prometheus-collector` container logs:

```bash
kubectl logs -n kube-system -l rsName=ama-metrics -c prometheus-collector --tail=200
```

The most informative line is one that says either `Successfully sent batch` (good) or `Failed to send batch ... 403` (DCRA missing or identity not yet propagated).

### 3.2 The workspace is reachable

```bash
QUERY_ENDPOINT=$(az monitor account show --name amw-bootcamp --resource-group rg-bootcamp-test-azmon-prom-grafana --query metrics.prometheusQueryEndpoint -o tsv)
TOKEN=$(az account get-access-token --resource "https://prometheus.monitor.azure.com" --query accessToken -o tsv)

curl -s -H "Authorization: Bearer $TOKEN" "${QUERY_ENDPOINT}/api/v1/labels" | jq '.data | length'
```

`labels` is cheaper than `query=up` because it doesn't evaluate over a time range. If the call returns 200 with a positive number of label names, the workspace is alive and reachable from your shell. If it 401s, your `az login` is for a different tenant than the workspace.

### 3.3 Series have actually been ingested

```bash
curl -s -H "Authorization: Bearer $TOKEN" "${QUERY_ENDPOINT}/api/v1/query?query=up" \
  | jq '.data.result | length'
```

A positive integer here is the strongest signal that ingestion works end-to-end. The number should match roughly the number of scrape targets the add-on covers (kubelet × node count, cAdvisor × node count, kube-state-metrics, etc.) — on a 2-node cluster this is usually in the 30–60 range.

### 3.4 The DCRA exists

The DCR association is the link that the add-on actually depends on. List all DCR associations on the cluster:

```bash
AKS_ID=$(az aks show --resource-group rg-bootcamp-test-azmon-prom-grafana --name aks-bootcamp-azmon --query id -o tsv)
az monitor data-collection rule association list --resource "$AKS_ID" -o table
```

You want at least one row whose name starts with `MSProm-` and whose `dataCollectionRuleId` points at a DCR in the same RG.

---

## Part 4 — Custom application metrics

### 4.1 PodMonitor (the recommended path)

The `manifests/pod-monitor.yaml` we apply is almost unremarkable in shape, with one critical Azure-specific detail:

```yaml
apiVersion: azmonitoring.coreos.com/v1   # forked CRD, not monitoring.coreos.com
kind: PodMonitor
metadata:
  name: sample-app
  namespace: demo-app
  labels:
    app: sample-app
spec:
  labelLimit: 63
  labelNameLengthLimit: 511
  labelValueLengthLimit: 1023
  selector:
    matchLabels:
      app: sample-app
  podMetricsEndpoints:
    - port: http-metrics
      interval: 30s
      path: /metrics
```

The `apiVersion` is **`azmonitoring.coreos.com/v1`**, not the upstream `monitoring.coreos.com/v1`. The AKS metrics add-on installs forked CRDs under a different API group precisely so it can coexist with a separately-installed kube-prometheus-stack on the same cluster (two Prometheus Operator installations would otherwise fight over the same CRDs). The schema is otherwise identical — every field that works on `monitoring.coreos.com/v1.PodMonitor` works here.

`labelLimit`, `labelNameLengthLimit`, `labelValueLengthLimit` come from Microsoft's reference template and match the workspace ingestion limits (63 labels, 511-char names, 1023-char values). Without them, scraped samples that exceed those limits get silently dropped at ingest. Even though the defaults are usually fine for in-house apps, copying these three lines from the reference template is the safe path.

The add-on watches all namespaces by default, so the namespace this lives in is irrelevant. The `selector` must match the pod labels — the deployment sets `app: sample-app` on the pod template, so the PodMonitor finds them.

`port: http-metrics` is the **port name** on the pod template, not a number. This is the most common source of "PodMonitor exists but nothing is scraped" — students forget to name the container port and try `port: 8080` (which would be wrong; the field is for the name).

### 4.2 ServiceMonitor (when scraping via Service)

Same shape, but selects a `Service` instead of pods directly. Useful when you want the Service's load-balancing semantics applied before scraping (e.g. only one of several backends should be hit). For most cases, `PodMonitor` is simpler because every pod is scraped exactly once regardless of Service.

### 4.3 Custom ConfigMap (when neither CRD fits)

`manifests/ama-metrics-prometheus-config.example.yaml` shows the escape hatch. Anything you can express in raw Prometheus `scrape_configs` works — including static targets, file-based service discovery, and `relabel_configs`. After applying it, restart the add-on:

```bash
kubectl rollout restart -n kube-system deploy/ama-metrics
```

The add-on **merges** this ConfigMap with the curated default jobs; you do not lose kubelet, cAdvisor, etc. by adding a custom config.

### 4.4 What does NOT work

Two patterns from raw Prometheus that look fine but don't behave as expected on the add-on:

- **`additionalScrapeConfigs` on a Prometheus CR** — the add-on is not driven by a `Prometheus` CR (because there isn't one — there is no Prometheus Operator deployed). Use the ConfigMap instead.
- **`scrape_interval` < 15s** — the workspace's ingestion endpoint rate-limits aggressively below 15s. Set 30s by default, 15s when truly needed.

---

## Part 5 — The auto-imported dashboards

The Grafana → Workspace integration imports a folder named **Azure Managed Prometheus** containing the kube-mixin dashboards. The honest assessment:

| Dashboard | Useful? | Why |
|---|---|---|
| Kubernetes / Compute Resources / Cluster | Yes | Top-level capacity view. Same shape as the W15.1 chart's. |
| Kubernetes / Compute Resources / Namespace (Pods) | Yes | Per-namespace and per-pod CPU/memory. Daily-use during incidents. |
| Kubernetes / Compute Resources / Namespace (Workloads) | Yes | Same as above but aggregated by Deployment/StatefulSet. |
| Kubernetes / Compute Resources / Node (Pods) | Mostly | Useful for spotting noisy-neighbour problems on a node. |
| Kubernetes / Compute Resources / Pod | Sometimes | Drill-down view from the Namespace (Pods) dashboard. |
| Kubernetes / Compute Resources / Workload | Sometimes | Drill-down from Namespace (Workloads). |
| Node Exporter / Nodes | Yes | Same as the dashboard 1860 students saw in W14. |
| Node Exporter / USE Method / Node | Probably | For people who think USE method. Worth knowing it exists. |
| Kubernetes / API Server | Rarely | Mostly noise unless you are debugging API server itself. |
| Kubernetes / Networking / Cluster | Rarely | Cilium/CNI specifics. Often empty depending on CNI. |

Build your own RED dashboard for application metrics, the way W15.1 did — the auto-imports do not cover application-level work because they are intentionally generic.

---

## Part 6 — Cost considerations

The bootcamp hands-on warns about cost in the cleanup step. Here is the breakdown for a 1-hour test session, in approximate USD:

| Resource | Hourly | Notes |
|---|---|---|
| Resource Group | 0 | |
| Azure Monitor Workspace (storage) | ~ 0 | Storage charges accrue on the order of cents/GB-month for retained samples. A 1-hour test ingests a few MB. |
| Azure Monitor Workspace (queries) | ~ 0 | Query API is billed per million samples processed; an interactive session is well under 1M. |
| Azure Managed Grafana, Standard | ~ $0.20/h | Required by the Workspace integration; the dominant non-AKS cost. |
| AKS managed control plane | 0 | Free tier. |
| AKS node pool (2 × Standard_B2s_v2) | ~ $0.10/h | The dominant cost. ~$2.40/day if you forget to delete. |
| DCR / DCE / DCRA | 0 | Infrastructure resources, no charge. |
| Egress | ~ 0 | Negligible for a test. |

The takeaway: **AKS nodes + Managed Grafana Standard dominate**, and both are fast to delete. Always run `az group delete --yes --no-wait` at the end. If a student leaves the demo running for a week, that is roughly $17 of AKS + $34 of Grafana Standard — not catastrophic, but not free either.

For production, the cost picture is different and dominated by the workspace's ingestion. Azure Monitor managed Prometheus is billed per million samples ingested + per GB stored. The [pricing page](https://azure.microsoft.com/pricing/details/monitor/) is the source of truth.

---

## Part 7 — Comparison with kube-prometheus-stack (W15.1)

If a student is choosing between the two for a real project, the trade-off matrix is:

| Dimension | kube-prometheus-stack | Azure Managed Prometheus + Grafana |
|---|---|---|
| Portability | Anywhere Kubernetes runs | Azure only |
| Operational ownership | High — you operate Prometheus, Grafana, Alertmanager | Low — Azure operates the storage + UI |
| Customisation | Anything Prometheus supports | Curated default + your CRDs + ConfigMap escape hatch |
| Recording rules | Native (PrometheusRule CRD) | Native (PrometheusRule CRD — picked up by the add-on) |
| Alerting | On-cluster Alertmanager | Azure Monitor alerts + Action Groups (separate model) |
| Retention | Whatever your PV supports | 18 months by default; longer via configuration |
| HA | DIY (replicas, Thanos, etc.) | Built into the managed service |
| Cost | Just the compute you run | Compute + per-sample ingestion + per-GB storage |
| Cold-start time on a new cluster | Minutes (helm install) | Minutes (`--enable-azure-monitor-metrics`) |
| Multi-cluster aggregation | Federation / Thanos | One workspace, many clusters, all in PromQL |
| Vendor lock-in | None | Azure-specific control plane |

A common pattern: dev / lower environments on kube-prometheus-stack (cheap, fast iteration, no Azure cost), production on Azure Managed Prometheus (offload of operational burden, durable retention, multi-cluster). Both shapes can coexist because the data model and dashboards are identical.

---

## Part 8 — The other pillar: logs with Container Insights

Everything in Parts 1–7 is **metrics**. Azure Monitor's other half is **logs**, and the single most common misconception is that the metrics add-on also gives you logs. It does not. They are two independent pipelines with different add-ons, stores, identities, and query languages. This part is the optional logs extension the bootcamp hands-on covers in its Step 9.

### 8.1 Metrics vs logs — two products that share a brand

| | Metrics (managed Prometheus) | Logs (Container Insights) |
|---|---|---|
| Add-on | `ama-metrics` (`--enable-azure-monitor-metrics`) | `ama-logs` (`--enable-addons monitoring`) |
| Store resource type | `Microsoft.Monitor/accounts` (Azure Monitor Workspace) | `Microsoft.OperationalInsights/workspaces` (Log Analytics workspace) |
| Data shape | Numeric time series | Structured/text rows in tables |
| Query language | PromQL | KQL (Kusto) |
| Default retention | 18 months | 30 days (configurable to 730; archive to 12 years) |
| Billing model | Per million samples ingested + per GB stored | Per GB ingested + per GB retained beyond the free 31 days |

Both surface under "Azure Monitor" in the portal and both can be queried from the same Grafana instance, which is exactly why students conflate them. The mental model to teach: **metrics answer "how much / how fast"; logs answer "what happened / what did it say"**.

### 8.2 Enabling it, and the resource-group gotcha

```bash
az aks enable-addons --addon monitoring \
  --resource-group rg-bootcamp-test-azmon-prom-grafana \
  --name aks-bootcamp-azmon
```

`provision.sh` keeps this opt-in: it only enables Container Insights when you pass `ENABLE_LOGS=1` (`ENABLE_LOGS=1 bash provision.sh`), so metrics-only runs never incur the logs workspace or its cost. The block is idempotent and prints the workspace resource ID at the end.

With no `--workspace-resource-id`, Azure does **not** put the Log Analytics workspace in your hands-on RG. It creates (or reuses) a default one named `DefaultWorkspace-<subId>-<REGIONCODE>` inside a **separate** resource group `DefaultResourceGroup-<REGIONCODE>` (e.g. `DefaultResourceGroup-WEU`, `DefaultResourceGroup-NEU`). Consequences:

- `az group delete` on your hands-on RG leaves that workspace behind. Cleanup needs a second command (see Cleanup below).
- Multiple clusters in the same region/subscription share that one default workspace — fine for a class, but it means one student's logs sit next to another's. For isolation, pass `--workspace-resource-id` to a workspace you created in your own RG.

Find which workspace a cluster is actually wired to:

```bash
az aks show -g rg-bootcamp-test-azmon-prom-grafana -n aks-bootcamp-azmon \
  --query "addonProfiles.omsagent.config.logAnalyticsWorkspaceResourceID" -o tsv
```

The agent appears in `kube-system` as `ama-logs` (DaemonSet, one per node, 3 containers each) plus an `ama-logs-rs` ReplicaSet pod for cluster-level collection. It reads every container's stdout/stderr from the node, plus the Kubernetes API for inventory and events.

### 8.3 What logs you get automatically

Once the agent is running you do **not** need a custom app to have data — these tables fill on their own:

- **`ContainerLogV2`** — stdout/stderr of **every** container, including system ones (`coredns`, `kube-proxy`, `konnectivity-agent`, the `csi-*` drivers, even `ama-metrics`/`ama-logs` themselves). This is the table students will use 90% of the time.
- **`KubeEvents`** — the cluster's event stream (FailedScheduling, image pulls, OOMKilled, BackOff, probe failures).
- **`KubePodInventory`, `KubeNodeInventory`, `KubeServices`, `ContainerInventory`** — periodic snapshots of cluster objects and their status.
- **`KubeMonAgentEvents`** — the agent's own health (useful when ingestion looks broken).
- **`Perf`, `InsightsMetrics`** — node/container performance counters in log form (overlaps with what managed Prometheus gives you; usually prefer PromQL for these).

The metrics `sample-app` writes nothing to stdout, so it is a poor demo source. `manifests/logs/log-generator.yaml` deploys `chentex/random-logger`, which emits a steady DEBUG/INFO/WARN/ERROR stream:

```bash
kubectl apply -f manifests/logs/
kubectl logs -n demo-app -l app=log-generator --tail=5   # logs at the source
```

A useful teaching beat: Container Insights parses the level into a structured **`LogLevel`** column automatically, separate from the raw **`LogMessage`** — so you can filter/aggregate by severity without regex on the message.

### 8.4 Querying from the CLI (verify ingestion)

First ingest takes ~5–10 minutes after enabling the add-on. Verify from the shell (`az extension add --name log-analytics` once; it will not install interactively from a script):

```bash
WSID=$(az aks show -g rg-bootcamp-test-azmon-prom-grafana -n aks-bootcamp-azmon \
  --query "addonProfiles.omsagent.config.logAnalyticsWorkspaceResourceID" -o tsv)
GUID=$(az monitor log-analytics workspace show --ids "$WSID" --query customerId -o tsv)

az monitor log-analytics query -w "$GUID" --analytics-query \
  'union ContainerLogV2, KubeEvents, KubePodInventory
   | where TimeGenerated > ago(1h)
   | summarize Rows=count() by Type' -o table
```

Note `-w` takes the workspace **GUID** (`customerId`), not its resource ID or name — a frequent stumble.

### 8.5 A library of example queries

These are deliberately spread across different tables/resources so you can show the breadth in class. All assume a `Last 1 hour`–`6 hours` time range.

```kql
// Application logs: the log-generator, newest first
ContainerLogV2
| where PodNamespace == "demo-app" and PodName startswith "log-generator"
| project TimeGenerated, LogLevel, LogMessage
| order by TimeGenerated desc
| take 50
```

```kql
// Severity breakdown over time (a "log RED" timechart)
ContainerLogV2
| where PodNamespace == "demo-app"
| summarize count() by LogLevel, bin(TimeGenerated, 1m)
| render timechart
```

```kql
// Only errors and warnings, across the whole cluster
ContainerLogV2
| where LogLevel in ("error", "warning")
| project TimeGenerated, PodNamespace, PodName, LogLevel, LogMessage
| order by TimeGenerated desc
| take 100
```

```kql
// Full-text search across all container logs (the "grep" demo)
ContainerLogV2
| where LogMessage has "error"           // 'has' is case-insensitive; 'has_cs' is case-sensitive
| summarize Hits=count() by ContainerName
| order by Hits desc
```

```kql
// A system service that logs with zero app deployed — CoreDNS
ContainerLogV2
| where PodNamespace == "kube-system" and ContainerName == "coredns"
| project TimeGenerated, LogMessage
| order by TimeGenerated desc
| take 50
```

```kql
// Kubernetes events: scheduling, image pulls, OOMKilled, restarts
KubeEvents
| where TimeGenerated > ago(2h)
| project TimeGenerated, Namespace, Name, Reason, Message, Count
| order by TimeGenerated desc
```

```kql
// Current pod inventory + restart counts for a namespace
KubePodInventory
| where Namespace == "demo-app"
| summarize arg_max(TimeGenerated, PodStatus, ContainerRestartCount) by Name
```

```kql
// Pods that have restarted at all in the last 6h (incident triage)
KubePodInventory
| where TimeGenerated > ago(6h) and ContainerRestartCount > 0
| summarize MaxRestarts=max(ContainerRestartCount) by Namespace, Name
| order by MaxRestarts desc
```

```kql
// Node-level CPU usage from Container Insights perf counters.
// Perf holds K8SNode / K8SContainer counters; cpuUsageNanoCores is the raw value.
Perf
| where ObjectName == "K8SNode" and CounterName == "cpuUsageNanoCores"
| summarize avg(CounterValue) by Computer, bin(TimeGenerated, 5m)
| render timechart
```

```kql
// Cost driver: noisiest containers by log volume (every GB is billed)
ContainerLogV2
| where TimeGenerated > ago(1h)
| summarize Lines=count(), Bytes=sum(strlen(LogMessage)) by PodNamespace, ContainerName
| order by Bytes desc
| take 15
```

```kql
// Agent self-health — is anything failing to ingest?
KubeMonAgentEvents
| where TimeGenerated > ago(1h) and Level != "Info"
| project TimeGenerated, Level, Message
| order by TimeGenerated desc
```

```kql
// Join logs to inventory: enrich error lines with the owning workload
ContainerLogV2
| where LogLevel == "error"
| join kind=inner (
    KubePodInventory
    | summarize arg_max(TimeGenerated, ControllerName, ControllerKind) by PodName=Name
  ) on PodName
| project TimeGenerated, PodNamespace, PodName, ControllerKind, ControllerName, LogMessage
| order by TimeGenerated desc
| take 50
```

### 8.6 Viewing logs in Grafana

The same `Azure Monitor` data source that was preinstalled (distinct from the `Managed_Prometheus_*` Prometheus one) can query Log Analytics — its managed identity already has `Monitoring Reader` at subscription scope, which includes `Microsoft.OperationalInsights/workspaces/query`. Steps:

1. **Explore** → data source **`Azure Monitor`**.
2. **Service: `Logs`**.
3. **Resource**: pick the AKS cluster (Grafana resolves its associated workspace) or the `DefaultWorkspace-...` directly.
4. Paste a KQL query from 8.5, set the time range, **Run query**. For a panel, choose the **Logs** or **Table** visualization; for the timecharts above, **Time series**.

The number-one support question — *"I see No data"* — is almost always an **empty query editor**: Logs mode does not auto-run a default query the way the Metrics service does. The second most common cause is a time range that does not overlap the data (logs are delayed a few minutes; use `Last 1 hour`).

### 8.7 What this does NOT cover

- **Control-plane logs** (kube-apiserver, kube-audit, kube-scheduler, cloud-controller-manager) are **not** collected by Container Insights. They require **Diagnostic Settings** on the AKS resource routing the chosen log categories to a Log Analytics workspace. That is a separate enablement (`az monitor diagnostic-settings create`) and a separate set of tables (`AKSAudit`, `AKSControlPlane`, or the legacy `AzureDiagnostics`).
- **Alerting on logs** (log search alerts / scheduled query rules) is its own topic, parallel to the Prometheus alert rules mentioned in Part 1.

---

## Cleanup

```bash
az group delete --name rg-bootcamp-test-azmon-prom-grafana --yes --no-wait
```

Verify when the background delete finishes:

```bash
az group exists --name rg-bootcamp-test-azmon-prom-grafana   # 'false' once done
```

If you scoped any DCR / DCRA outside the hands-on's RG (you probably did not), check those separately:

```bash
az monitor data-collection rule list --query "[?starts_with(name, 'MSProm-')].{name:name, rg:resourceGroup}" -o table
```

**If you did Part 8 (logs):** the default Log Analytics workspace was created in `DefaultResourceGroup-<REGIONCODE>`, **outside** the hands-on RG, so the delete above does not remove it. It is storage-only (no compute) and cheap to leave, but to clean up fully:

```bash
WSID=$(az aks show -g rg-bootcamp-test-azmon-prom-grafana -n aks-bootcamp-azmon \
  --query "addonProfiles.omsagent.config.logAnalyticsWorkspaceResourceID" -o tsv 2>/dev/null)
# Capture $WSID BEFORE deleting the cluster/RG (the query needs the cluster to exist).
az monitor log-analytics workspace delete --ids "$WSID" --yes --force true
```

Other region-default workspaces may be shared by other clusters — only delete one you are sure is yours.

---

## Discussion questions

1. The bootcamp hands-on says "no Alertmanager in this picture by design". What replaces it in the managed model, and why is the model different? When would that difference push you back to kube-prometheus-stack for alerting specifically?
2. You created a `PodMonitor` and the add-on picked it up. What did the add-on do internally to discover, scrape and ship the new target? Trace the steps from the `kubectl apply` to a sample appearing in the workspace.
3. The integration command grants Grafana's managed identity the `Monitoring Data Reader` role at the workspace scope. If a team has 5 workspaces and 1 Grafana instance, what is the minimum set of role assignments needed to allow Grafana to query all 5? What if there were 1 workspace and 5 Grafana instances?
4. On a multi-cluster Azure estate (10 AKS clusters, 1 workspace), what does the cardinality model look like? Specifically, if every cluster has a `node_cpu_seconds_total{instance="..."}` series, do the 10 clusters' series collide in the workspace? What label is doing the differentiation, and where does it come from?

---

## Troubleshooting

| Symptom | Root cause | Fix |
|---|---|---|
| `az monitor account create` fails with `provider not registered`. | Subscription has not registered `Microsoft.Monitor`. | `az provider register --namespace Microsoft.Monitor --wait`. Same for `Microsoft.Dashboard` (Managed Grafana) and `Microsoft.AlertsManagement`. |
| `az grafana create` errors with `The command requires the extension amg ... EOFError` when run from a script. | The `amg` CLI extension is not installed and the CLI cannot prompt for `y/n` in non-interactive mode. | `az extension add --name amg --yes` once on the host, then re-run. `provision.sh` now does this automatically. |
| `az aks create --enable-azure-monitor-metrics` errors `azure-monitor-workspace-resource-id is required`. | Flag passed without `--azure-monitor-workspace-resource-id`. | Pass both flags together. |
| `ama-metrics` pods are `Running` but `up{}` returns 0 series after 3 minutes. | DCR association did not get created. | `az monitor data-collection rule association list --resource $AKS_ID -o table`. If empty, re-run `az aks update --enable-azure-monitor-metrics --azure-monitor-workspace-resource-id $AMW_ID`. |
| `Failed to send batch ... 403` in `prometheus-collector` logs. | AKS managed identity does not yet have ingestion role on the workspace; happens for a few minutes after add-on enable. | Wait 3–5 minutes. If it persists, check the DCRA explicitly. |
| Grafana data source test fails `403 - Authorization failed`. | Grafana's system-assigned managed identity lacks `Monitoring Data Reader` on the workspace. | `az grafana update --azure-monitor-workspace-integrations $AMW_ID` (re-runs the role assignment). |
| `curl` to `prometheusQueryEndpoint/api/v1/query` returns `401 InvalidAuthenticationTokenTenant`. | `az login` context is in a different tenant than the workspace. | `az account set --subscription <id-in-the-right-tenant>` and re-acquire the token. |
| PodMonitor applied, app pods are healthy, but `http_requests_total` does not appear. | PodMonitor's `port:` is set to a number instead of the named container port. | Edit the PodMonitor; set `port: http-metrics` to match the container's `ports[].name`. |
| PodMonitor applied with `port:` correct, still no metrics. | `interval:` set below 15s; add-on rejects the target. | Set `interval: 30s` (or 15s minimum). |
| Custom `ama-metrics-prometheus-config` ConfigMap applied, no change visible. | ConfigMap applied but pods not restarted. | `kubectl rollout restart -n kube-system deploy/ama-metrics` and the DaemonSet for node-level configs. |
| `az grafana integrations monitor add` returns `The role assignment already exists` or `Resource already exists`. | Re-running the link command after a previous successful link. | Harmless. The data source provisioning is idempotent; the role assignment is also idempotent. |
| `az grafana update ... --azure-monitor-workspace-integrations ...` fails with `unrecognized arguments`. | The current `amg` extension uses a subcommand instead of an `update` flag. | Use `az grafana integrations monitor add --name $GRAFANA -g $RG --monitor-name $AMW --monitor-resource-group-name $RG`. |
| `az aks create --azure-monitor-workspace-resource-id ...` fails with `not in the correct format. It should match /subscriptions/...`. | Git Bash on Windows (MSYS) is rewriting the resource ID (which starts with `/subscriptions/`) into a Windows path before `az` sees it. | `export MSYS_NO_PATHCONV=1` for the shell session, or set it inline: `MSYS_NO_PATHCONV=1 az aks create ...`. `provision.sh` sets it at the top. |
| `az aks create` fails with `The VM size of Standard_B2s is not allowed in your subscription`. | Some subscriptions (sponsorship / partner / classroom) block legacy SKUs. The error message includes the allow-list. | Pick a SKU from the allow-list. Cheap alternatives: `Standard_B2s_v2`, `Standard_D2als_v7`, `Standard_D2s_v3`. See the discovery flow in the bootcamp hands-on step 4. |
| `az aks create` fails with `Insufficient vcpu quota requested 4, remaining 0 for family standardBsv2Family`. | The chosen SKU's family has 0 vCPU quota in this region. | Run `az vm list-usage --location $LOCATION --query "[?limit!=\`0\` && contains(name.value, 'Family')]" -o table` and pick a family with available quota. Or request a quota increase. |
| AKS create succeeds but `kubectl get nodes` returns an empty list. | `get-credentials` not run yet, or kubeconfig points at a stale context. | `az aks get-credentials --resource-group $RG --name $AKS --overwrite-existing`. |
| `az group delete` hangs > 15 minutes. | The MC_ node resource group has a load balancer or public IP still in `Deleting`. | Wait. If still stuck after 30 min, `az network public-ip list --resource-group MC_<rg>_<aks>_<region>` to inspect; rarely needed in this hands-on because no `Service type=LoadBalancer` was created. |
| `az aks create` fails with `PublicIPCountLimitReached ... Cannot create more than 20 public IP addresses for this subscription in this region`. | The region has hit the subscription's public-IP cap (often shared classroom subscriptions full of other students' AKS clusters). AKS needs ≥1 public IP for the standard LB egress. | Deploy in a region with headroom: check with `az network list-usages --location <region> --query "[?contains(name.value,'PublicIP')]" -o table`, then set `LOCATION` to a region below the cap. Do **not** delete other people's IPs. Managed Prometheus supports AKS and the Workspace in different regions if you only want to move the cluster. |
| Logs: `az aks show ... addonProfiles.omsagent.enabled` is empty after enabling metrics. | Expected — metrics (`ama-metrics`) and logs (`ama-logs`) are separate add-ons. `--enable-azure-monitor-metrics` never turns on logs. | Enable logs explicitly: `az aks enable-addons --addon monitoring -g $RG -n $AKS`. See Part 8. |
| Logs: enabled Container Insights but the Log Analytics workspace is not in the hands-on RG. | With no `--workspace-resource-id`, Azure creates/uses a default workspace in `DefaultResourceGroup-<REGIONCODE>`, a separate RG. | Find it via `addonProfiles.omsagent.config.logAnalyticsWorkspaceResourceID`. Pass `--workspace-resource-id` to a workspace in your own RG if you want it co-located. Remember it survives the hands-on `az group delete` (see Cleanup). |
| Logs: Grafana / portal shows **"No data"** in the Logs view. | The KQL query editor is empty (Logs mode does not auto-run a default query), or the time range does not overlap the data. | Paste an explicit KQL query and set the range to `Last 1 hour`. Logs are delayed a few minutes; the first ingest after enabling the add-on takes 5–10 min. |
| `az monitor log-analytics query` prompts to install an extension and then fails with `EOFError` in a script. | The `log-analytics` CLI extension is missing and cannot prompt non-interactively. | `az extension add --name log-analytics --yes` once, then re-run. Pass the workspace **GUID** (`customerId`) to `-w`, not the resource ID. |
| Logs: `kubectl logs -n demo-app -l app=sample-app` is empty, so nothing shows in `ContainerLogV2` for the app. | `prometheus-example-app` (the metrics sample) writes nothing to stdout. | Deploy the log source: `kubectl apply -f manifests/logs/` (the `log-generator`). Use system pods like `coredns` for an app-free example. |

---

## References

- [Azure Monitor managed service for Prometheus — overview](https://learn.microsoft.com/azure/azure-monitor/metrics/prometheus-metrics-overview) — the canonical entry point. Architecture, ingestion, query.
- [Enable Prometheus and Grafana for an AKS cluster](https://learn.microsoft.com/azure/azure-monitor/containers/kubernetes-monitoring-enable) — the AKS-side flag reference and the alternatives (Terraform, Bicep, portal).
- [Customize scraping of Prometheus metrics in Azure Monitor managed service](https://learn.microsoft.com/azure/azure-monitor/containers/prometheus-metrics-scrape-configuration) — the authoritative reference for PodMonitor / ServiceMonitor / custom ConfigMap on the add-on.
- [Azure Managed Grafana — Connect to an Azure Monitor workspace](https://learn.microsoft.com/azure/managed-grafana/how-to-connect-azure-monitor-workspace) — the integration command and the manual UI equivalent.
- [Data collection rules in Azure Monitor](https://learn.microsoft.com/azure/azure-monitor/essentials/data-collection-rule-overview) — DCR / DCE / DCRA concepts in full.
- [Azure Monitor pricing](https://azure.microsoft.com/pricing/details/monitor/) — sample-based pricing for managed Prometheus.
- [Azure Managed Grafana pricing](https://azure.microsoft.com/pricing/details/managed-grafana/) — Essential vs Standard SKU breakdown.
- [Container Insights overview](https://learn.microsoft.com/azure/azure-monitor/containers/container-insights-overview) — the logs/Container Insights pillar (Part 8).
- [Container Insights log schema (ContainerLogV2, KubeEvents, inventory tables)](https://learn.microsoft.com/azure/azure-monitor/containers/container-insights-log-schema) — every table the agent writes and its columns.
- [Log Analytics / KQL tutorial](https://learn.microsoft.com/azure/azure-monitor/logs/log-analytics-tutorial) — the query language used in Part 8.
- [Change Log Analytics retention and archive](https://learn.microsoft.com/azure/azure-monitor/logs/data-retention-configure) — the 30-day default, up to 730 days, archive to 12 years.
- [AKS control-plane / resource logs via Diagnostic Settings](https://learn.microsoft.com/azure/aks/monitor-aks#aks-control-planeresource-logs) — what Container Insights does NOT cover (Part 8.7).