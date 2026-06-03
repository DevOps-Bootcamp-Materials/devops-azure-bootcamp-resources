# Hands-on 04: Kubernetes Monitoring with kube-prometheus-stack

## Objective

The previous three hands-on sessions used Docker Compose. In production,
applications run on Kubernetes — and monitoring a Kubernetes cluster is
meaningfully different from monitoring a set of containers on a single host.

The cluster itself is a system that needs monitoring: nodes, pods, the control
plane, the scheduler, resource quotas. And on top of that, every application
running on the cluster needs its own metrics.

`kube-prometheus-stack` is the Helm chart that deploys the complete monitoring
stack — Prometheus Operator, Prometheus, Grafana, Alertmanager, Node Exporter,
kube-state-metrics, and a set of pre-built dashboards and alert rules — in a
single command.

By the end of this hands-on you will be able to:
- Install and configure `kube-prometheus-stack` via Helm
- Navigate the default Kubernetes dashboards in Grafana
- Understand what the Prometheus Operator does and why it exists
- Deploy an application that exposes Prometheus metrics and configure
  automatic scraping using a `ServiceMonitor`
- Build a custom Grafana dashboard for application-level RED metrics

---

## Prerequisites

```bash
# A running Kubernetes cluster is required.
# Options:
#   1. Use the AKS cluster from kubernetes/hands-on/aks (already provisioned with Terraform)
#   2. A local minikube cluster: minikube start --memory 4096 --cpus 2
#   3. A local kind cluster: kind create cluster

kubectl get nodes   # should show at least 1 node in Ready state

# Helm must be installed
helm version

cd monitoring/hands-on/kubernetes-monitoring
```

---

## Part 1 — Install kube-prometheus-stack

```bash
# Add the Prometheus Community Helm repository
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Create a dedicated namespace
kubectl create namespace monitoring

# Install the chart with our classroom overrides
helm install kube-prom prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values values.yaml \
  --wait
```

The `--wait` flag blocks until all pods are `Running`. This may take 2-3
minutes on the first run as Kubernetes pulls images.

Verify the installation:

```bash
kubectl get pods -n monitoring
```

You should see pods for: prometheus, grafana, alertmanager, node-exporter
(one per node), and kube-state-metrics.

**What is kube-state-metrics?** It listens to the Kubernetes API server and
exposes object state as metrics: number of running pods, deployment replica
counts, job completion status, and so on. Node Exporter exposes what the
OS is doing; kube-state-metrics exposes what Kubernetes objects are doing.

---

## Part 2 — Access the interfaces

Open three terminal tabs and run these port-forwards:

```bash
# Grafana
kubectl port-forward -n monitoring svc/kube-prom-grafana 3000:80

# Prometheus Expression Browser
kubectl port-forward -n monitoring svc/kube-prom-kube-prometheus-prometheus 9090:9090

# Alertmanager
kubectl port-forward -n monitoring svc/kube-prom-kube-prometheus-alertmanager 9093:9093
```

Open in your browser:
- `http://localhost:3000` — Grafana (user: `admin`, password: `prom-operator`)
- `http://localhost:9090` — Prometheus
- `http://localhost:9093` — Alertmanager

---

## Part 3 — Explore the default dashboards

In Grafana, go to **Dashboards**. You will see a folder called
**Kubernetes / ...** with over 20 pre-built dashboards. Explore these three:

**Kubernetes / Compute Resources / Cluster**
This is the top-level view: how much CPU and memory the cluster is consuming
vs its total capacity. Note the "CPU Requests Commitment" and "Memory Requests
Commitment" — these show how much of the cluster's allocatable capacity has
been requested by pods.

**Kubernetes / Compute Resources / Namespace (Pods)**
Select the `monitoring` namespace from the dropdown. You can see CPU and
memory usage per pod. This is what an SRE looks at during an incident to
identify which pod is consuming unexpected resources.

**Node Exporter / Nodes**
This is the same Node Exporter data from hands-on 01, but now running inside
Kubernetes. Notice that the metrics and queries are identical — the underlying
data model does not change between Docker Compose and Kubernetes.

---

## Part 4 — The Prometheus Operator and ServiceMonitor

In Docker Compose, you edited `prometheus.yml` manually and reloaded Prometheus
to add new scrape targets. In Kubernetes, this approach does not scale —
applications are deployed dynamically across many namespaces and pods come and
go constantly.

The **Prometheus Operator** solves this with Custom Resource Definitions (CRDs).
Instead of editing a config file, you create Kubernetes objects:

| Prometheus Operator CRD | What it does |
|--------------------------|--------------|
| `ServiceMonitor` | Tells Prometheus to scrape a Service |
| `PodMonitor` | Tells Prometheus to scrape pods directly |
| `PrometheusRule` | Defines alerting and recording rules |

The Operator watches for these objects and automatically updates the Prometheus
configuration. No restarts, no manual config edits.

Inspect the existing ServiceMonitors installed by the chart:

```bash
kubectl get servicemonitors -n monitoring
```

You will see one for each component: prometheus, grafana, alertmanager,
node-exporter, kube-state-metrics. Each one points at a Service and tells
Prometheus which port and path to scrape.

Look at one in detail:

```bash
kubectl describe servicemonitor -n monitoring kube-prom-node-exporter
```

---

## Part 5 — Deploy the instrumented sample application

Now you will deploy an application that exposes Prometheus metrics and
configure automatic scraping via a ServiceMonitor.

```bash
kubectl apply -f manifests/
```

Verify the deployment:

```bash
kubectl get all -n demo-app
```

The `ServiceMonitor` in `manifests/service-monitor.yaml` tells the Prometheus
Operator to scrape the `sample-app` Service. The Operator updates Prometheus
configuration automatically within a few seconds.

Verify that Prometheus has picked up the new target:

```
http://localhost:9090/targets
```

Look for a target in the `serviceMonitor/demo-app/sample-app` section.
It should appear as `UP` within 30 seconds.

Query the application metrics:

```promql
# Request rate per handler
sum by (handler) (rate(http_requests_total{job="sample-app"}[5m]))

# p95 latency per handler
histogram_quantile(0.95, sum by (handler, le) (rate(http_request_duration_seconds_bucket{job="sample-app"}[5m])))
```

---

## Part 6 — Build a RED dashboard for the sample app

Create a new Grafana dashboard with four panels. This is the standard
**RED dashboard** (Rate, Errors, Duration) that every service in a production
environment should have.

**Panel 1 — Request rate (requests/sec)**
```promql
sum by (handler) (rate(http_requests_total{job="sample-app"}[5m]))
```
Type: Time series. Legend: `{{handler}}`. Unit: `requests/sec`.

**Panel 2 — Error rate (%)**
```promql
sum by (handler) (rate(http_requests_total{job="sample-app", code!~"2.."}[5m]))
  /
sum by (handler) (rate(http_requests_total{job="sample-app"}[5m]))
  * 100
```
Type: Time series. Legend: `{{handler}}`. Unit: `Percent (0-100)`. Add a threshold
at 5% (red) so errors become immediately visible.

**Panel 3 — p95 latency (seconds)**
```promql
histogram_quantile(
  0.95,
  sum by (handler, le) (rate(http_request_duration_seconds_bucket{job="sample-app"}[5m]))
)
```
Type: Time series. Legend: `{{handler}}`. Unit: `seconds`.

**Panel 4 — Pod count (how many replicas are running)**
```promql
count by (pod) (kube_pod_status_ready{namespace="demo-app", condition="true"})
```
Type: Stat panel. Shows how many pods are ready. This comes from
kube-state-metrics, not from the application itself.

Save as `Sample App — RED Dashboard`.

---

## Part 7 — Scale the deployment and observe

```bash
# Scale up to 4 replicas
kubectl scale deployment sample-app -n demo-app --replicas=4
kubectl get pods -n demo-app -w   # watch pods come up

# Check the Pod count panel in your dashboard — it should update within 15 seconds

# Scale back down
kubectl scale deployment sample-app -n demo-app --replicas=2
```

---

## Part 8 — Cleanup

```bash
# Remove the sample application
kubectl delete -f manifests/

# Uninstall the monitoring stack
helm uninstall kube-prom -n monitoring
kubectl delete namespace monitoring
```

---

## Discussion questions

1. In Docker Compose you edited `prometheus.yml` to add scrape targets. In
   Kubernetes you created a `ServiceMonitor`. What problem does the Prometheus
   Operator solve that the static config approach cannot?
2. `kube-state-metrics` exposes object state (number of pods, deployment
   status). Node Exporter exposes host metrics (CPU, memory). Neither one
   exists in Docker Compose environments. What does this tell you about the
   complexity increase when moving from containers to Kubernetes?
3. You deployed two replicas of the sample app. In the Expression Browser,
   query `up` and filter by the demo-app ServiceMonitor. How many targets do
   you see? What happens to these targets when you scale to 4 replicas?
4. The `values.yaml` disables `kubeControllerManager`, `kubeScheduler`, and
   `kubeEtcd`. In a managed Kubernetes service (AKS, EKS, GKE) these control
   plane components are not accessible. What does this mean for your alerting
   strategy?

---

## Key concepts

| Concept | Description |
|---------|-------------|
| kube-prometheus-stack | Helm chart that deploys the full Prometheus/Grafana/Alertmanager stack on Kubernetes |
| Prometheus Operator | Kubernetes controller that manages Prometheus configuration via CRDs |
| ServiceMonitor | CRD that tells the Operator which Service and port to scrape |
| kube-state-metrics | Exports Kubernetes object state (pod counts, deployment status) as Prometheus metrics |
| `kube_pod_status_ready` | Gauge: 1 if the pod is ready, 0 otherwise. Sourced from kube-state-metrics. |
| RED dashboard | Standard application dashboard: Rate (req/s), Errors (% of 5xx), Duration (p95 latency) |
| `helm install --wait` | Blocks until all chart resources are ready before returning |
