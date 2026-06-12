#!/usr/bin/env bash
# Grafana Cloud — monitor a local Kubernetes cluster from a SaaS Grafana.
# Needs: a Grafana Cloud free account + an Access Policy token with
# metrics:write, metrics:read, stacks:read (stored in $GRAFANA_CLOUD_TOKEN).

# --- 1. Discover your stack's Prometheus endpoint via the Cloud API ----------
curl -s -H "Authorization: Bearer $GRAFANA_CLOUD_TOKEN" \
  https://grafana.com/api/instances | \
  python3 -c "import sys,json; [print(i['slug'], '| prom user:', i['hmInstancePromId'], '| prom url:', i['hmInstancePromUrl']) for i in json.load(sys.stdin)['items']]"
# Note the numeric ID (remote_write username) and the URL (push endpoint base).

# --- 2. A local cluster to monitor -------------------------------------------
k3d cluster create gcloud-demo --servers 1 --agents 1

# --- 3. Credentials as a Secret (never in values files) ------------------------
kubectl create namespace monitoring
# username = the numeric hmInstancePromId from step 1, NOT the stack slug.
kubectl create secret generic grafana-cloud-credentials -n monitoring \
  --from-literal=username=<PROM_INSTANCE_ID> \
  --from-literal=password=$GRAFANA_CLOUD_TOKEN

# --- 4. kube-prometheus-stack, shipping to the cloud ---------------------------
# Edit values-remote-write.yaml first: REMOTE_WRITE_URL = <hmInstancePromUrl>/api/prom/push
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install kps prometheus-community/kube-prometheus-stack \
  -n monitoring -f values-remote-write.yaml

kubectl get pods -n monitoring

# --- 5. Verify samples are leaving the cluster ---------------------------------
kubectl port-forward -n monitoring svc/kps-kube-prometheus-stack-prometheus 9090:9090 &
sleep 3
curl -s 'http://localhost:9090/api/v1/query?query=prometheus_remote_storage_samples_total' | head -c 400
kill %1

# --- 6. Verify samples ARRIVED in Grafana Cloud (the e2e proof) -----------------
curl -s -u "<PROM_INSTANCE_ID>:$GRAFANA_CLOUD_TOKEN" \
  "<hmInstancePromUrl>/api/prom/api/v1/query?query=count(up)" | head -c 400
# Verified result shape: count(up)=10 across kubelet/node-exporter/ksm/apiserver.
# A non-empty result = your laptop's cluster is visible from the SaaS side.
# Now open https://<your-stack>.grafana.net -> Explore -> select the
# grafanacloud-*-prom datasource -> query: up

# --- 7. Watch the free-tier budget ----------------------------------------------
curl -s -u "<PROM_INSTANCE_ID>:$GRAFANA_CLOUD_TOKEN" \
  "<hmInstancePromUrl>/api/prom/api/v1/query?query=count({__name__!=\"\"})" | head -c 400
# Active series being ingested. Free tier = 10k; our writeRelabelConfigs keep
# only an allowlist of curated metric names to stay under it.
# Measured journey on a 1-server/1-agent cluster: 72,561 -> 47,894 -> 478 series.

# --- 8. Cleanup -------------------------------------------------------------------
k3d cluster delete gcloud-demo
# Metrics already shipped remain queryable in the cloud until retention (14d) expires.
