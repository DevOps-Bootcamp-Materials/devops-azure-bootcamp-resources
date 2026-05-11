#!/usr/bin/env bash
# =============================================================================
# Lab 09 — Scheduling: command walkthrough
# =============================================================================
# Purpose: exercise every placement mechanism the scheduler exposes.
#
# Cluster requirement:
#   - AKS cluster from lab 06 (rg-aks-lab05 / aks-lab05)
#   - A second node pool 'workload' with labels role=workload tier=app
#
# Cost warning:
#   The extra node pool bills until you run Part 7. Don't skip cleanup.
# =============================================================================

# --- 0. CONFIG ---------------------------------------------------------------

RG=rg-aks-lab05
CLUSTER=aks-lab05


# --- 1. CLUSTER PREREQUISITES ------------------------------------------------

kubectl config use-context "$CLUSTER"
kubectl get nodes

# Add the second node pool (idempotent: skips if already exists):
az aks nodepool show \
  --resource-group "$RG" --cluster-name "$CLUSTER" --name workload \
  --output none 2>/dev/null || \
az aks nodepool add \
  --resource-group "$RG" \
  --cluster-name "$CLUSTER" \
  --name workload \
  --node-count 1 \
  --node-vm-size Standard_B2s \
  --labels role=workload tier=app

# Confirm 3 nodes total and the workload node carries the label:
kubectl get nodes --show-labels | grep -E 'role=workload|NAME'

kubectl create namespace lab09
kubectl config set-context --current --namespace=lab09


# =============================================================================
# PART 1 — nodeSelector
# =============================================================================

kubectl apply -f manifests/01-nodeselector-pod.yaml
kubectl wait --for=condition=Ready pod/selector-pod --timeout=60s
kubectl get pod selector-pod -o wide
# NODE column → the workload node.

# Apply a Pod with an impossible selector and watch it stay Pending:
kubectl apply -f manifests/01-nodeselector-impossible.yaml
sleep 3
kubectl get pod selector-impossible
kubectl describe pod selector-impossible | grep -A5 Events

kubectl delete pod selector-pod selector-impossible


# =============================================================================
# PART 2 — nodeAffinity
# =============================================================================

kubectl apply -f manifests/02-nodeaffinity-required.yaml
kubectl wait --for=condition=Ready pod/affinity-required --timeout=60s
kubectl get pod affinity-required -o wide
kubectl describe pod affinity-required | grep -A8 'Node-Selectors\|Affinity'

kubectl apply -f manifests/02-nodeaffinity-preferred.yaml
kubectl wait --for=condition=Ready pod/affinity-preferred --timeout=60s
kubectl get pod affinity-preferred -o wide

kubectl delete pod affinity-required affinity-preferred


# =============================================================================
# PART 3 — podAntiAffinity
# =============================================================================

kubectl apply -f manifests/03-podantiaffinity-deployment.yaml
kubectl rollout status deployment/web-spread --timeout=120s
kubectl get pods -l app=web-spread -o wide
# Each replica should be on a different node.

# Stress test: scale to N+1 replicas — the extra one should stay Pending:
kubectl scale deployment web-spread --replicas=4
sleep 10
kubectl get pods -l app=web-spread -o wide
# Look for the Pending Pod, then check why:
kubectl describe pod -l app=web-spread | grep -B2 -A5 'didn'\''t match pod anti-affinity' || true

kubectl scale deployment web-spread --replicas=3
kubectl delete deployment web-spread


# =============================================================================
# PART 4 — Taints & tolerations
# =============================================================================

WORKLOAD_NODE=$(kubectl get node -l role=workload -o jsonpath='{.items[0].metadata.name}')
echo "Tainting node: $WORKLOAD_NODE"

# 4.1 Taint the workload node
kubectl taint node "$WORKLOAD_NODE" dedicated=ml:NoSchedule --overwrite
kubectl describe node "$WORKLOAD_NODE" | grep -i taint

# 4.2 A Pod WITHOUT toleration cannot land on the tainted node:
kubectl apply -f manifests/04-pod-no-toleration.yaml
kubectl wait --for=condition=Ready pod/intolerant --timeout=60s
kubectl get pod intolerant -o wide
# NODE → one of the system nodes (NOT the workload node).

# 4.3 A Pod WITH toleration + nodeSelector lands on the tainted node:
kubectl apply -f manifests/04-pod-with-toleration.yaml
kubectl wait --for=condition=Ready pod/tolerant --timeout=60s
kubectl get pod tolerant -o wide
# NODE → the workload node.

# 4.4 Why kube-system Pods can run everywhere — they tolerate all taints:
kubectl get daemonset -n kube-system kube-proxy \
  -o jsonpath='{.spec.template.spec.tolerations}' \
  | python -m json.tool 2>/dev/null || \
  kubectl get daemonset -n kube-system kube-proxy -o yaml | grep -A20 tolerations

kubectl delete pod intolerant tolerant

# 4.5 Remove the taint
kubectl taint node "$WORKLOAD_NODE" dedicated-


# =============================================================================
# PART 5 — topologySpreadConstraints
# =============================================================================

kubectl apply -f manifests/05-topologyspread-deployment.yaml
kubectl rollout status deployment/spread-app --timeout=180s
kubectl get pods -l app=spread-app -o wide
# Distribution: ~2 Pods per node (6 replicas / 3 nodes), maxSkew=1 honoured.

kubectl delete deployment spread-app


# =============================================================================
# PART 6 — Realistic combined scenario: dedicated ML pool
# =============================================================================

# Re-taint and re-label for the ML pool scenario:
kubectl taint node "$WORKLOAD_NODE" workload-type=ml:NoSchedule --overwrite
kubectl label node "$WORKLOAD_NODE" workload-type=ml --overwrite

kubectl apply -f manifests/06-ml-scenario/
sleep 15

echo '--- web workload (system nodes only, never on the ML pool) ---'
kubectl get pods -l app=web-workload -o wide

echo '--- ML jobs (workload node only, anti-affine to each other) ---'
kubectl get pods -l app=ml-job -o wide

# Pending ML jobs explanation:
kubectl describe pod -l app=ml-job | grep -B2 -A5 'didn'\''t match pod anti-affinity' || true


# =============================================================================
# PART 7 — Cleanup (DO NOT SKIP — the extra node pool keeps billing)
# =============================================================================

# 7.1 Tear down Kubernetes objects
kubectl delete -f manifests/06-ml-scenario/ --ignore-not-found
kubectl delete -f manifests/ --ignore-not-found
kubectl delete namespace lab09

# 7.2 Remove taints from the workload node (clean state before pool deletion)
WORKLOAD_NODE=$(kubectl get node -l role=workload -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$WORKLOAD_NODE" ]; then
  kubectl taint node "$WORKLOAD_NODE" workload-type- 2>/dev/null || true
  kubectl taint node "$WORKLOAD_NODE" dedicated-     2>/dev/null || true
fi

# 7.3 Delete the extra AKS node pool
az aks nodepool delete \
  --resource-group "$RG" \
  --cluster-name "$CLUSTER" \
  --name workload \
  --no-wait

kubectl config set-context --current --namespace=default
echo
echo "Pool deletion submitted. Verify with:"
echo "  az aks nodepool list --resource-group $RG --cluster-name $CLUSTER --output table"
