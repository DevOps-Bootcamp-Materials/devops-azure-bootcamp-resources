#!/usr/bin/env bash
# =============================================================================
# Lab 10 — DaemonSets: command walkthrough
# =============================================================================
# Purpose: walk through every behaviour of the DaemonSet controller — one Pod
# per node, node selection, host access, tolerations, update strategies.
#
# Cluster requirement:
#   - AKS cluster from lab 06 (rg-aks-lab05 / aks-lab05) with >= 2 nodes.
#     A single-node minikube/kind cluster also works, but you will only ever
#     see one Pod, so Part 2/4 are less interesting.
#
# Cost warning:
#   Part 4 temporarily adds a tainted node pool. Part 6 deletes it. Don't skip.
# =============================================================================

# --- 0. CONFIG ---------------------------------------------------------------

RG=rg-aks-lab05
CLUSTER=aks-lab05

kubectl config use-context "$CLUSTER"
kubectl get nodes

kubectl create namespace lab10 2>/dev/null || true
kubectl config set-context --current --namespace=lab10


# --- 1. BASIC DAEMONSET ------------------------------------------------------

kubectl apply -f manifests/01-daemonset-basic.yaml

kubectl get daemonset node-heartbeat
kubectl get pods -l app=node-heartbeat -o wide
kubectl describe daemonset node-heartbeat | sed -n '/Events/,$p'


# --- 2. NODESELECTOR REACTS TO LABEL CHANGES --------------------------------

NODE=$(kubectl get node -o jsonpath='{.items[0].metadata.name}')
kubectl label node "$NODE" agent-role=logs --overwrite

kubectl apply -f manifests/02-daemonset-nodeselector.yaml
kubectl get pods -l app=logs-agent -o wide

# Label a second node — Pod count grows.
OTHER_NODE=$(kubectl get node -o jsonpath='{.items[1].metadata.name}')
kubectl label node "$OTHER_NODE" agent-role=logs --overwrite
sleep 5
kubectl get pods -l app=logs-agent -o wide

# Remove the label — Pod is evicted.
kubectl label node "$OTHER_NODE" agent-role-
sleep 5
kubectl get pods -l app=logs-agent -o wide


# --- 3. REAL-WORLD: LOG COLLECTOR WITH HOSTPATH -----------------------------

kubectl apply -f manifests/03-daemonset-logcollector.yaml
kubectl rollout status daemonset/log-collector

POD=$(kubectl get pod -l app=log-collector -o jsonpath='{.items[0].metadata.name}')
kubectl exec "$POD" -- ls /host-logs | head
kubectl logs "$POD" --tail=5


# --- 4. TOLERATIONS: RUNNING ON TAINTED NODES -------------------------------

# Add a tainted node pool (idempotent: skips if it already exists).
az aks nodepool show \
  --resource-group "$RG" --cluster-name "$CLUSTER" --name workload \
  --output none 2>/dev/null || \
az aks nodepool add \
  --resource-group "$RG" \
  --cluster-name "$CLUSTER" \
  --name workload \
  --node-count 1 \
  --node-vm-size Standard_B2s \
  --node-taints "dedicated=ml:NoSchedule"

kubectl get nodes
kubectl describe node -l agentpool=workload | grep -i taints

# Basic DaemonSet does NOT land on the tainted node:
kubectl get pods -l app=node-heartbeat -o wide

# Tolerate-everything DaemonSet covers the tainted node too:
kubectl apply -f manifests/04-daemonset-tolerate-all.yaml
sleep 10
kubectl get pods -l app=cluster-agent -o wide

# Inspect the real kube-proxy DaemonSet — same pattern:
kubectl get daemonset -n kube-system
kubectl get daemonset -n kube-system kube-proxy -o yaml | grep -A20 tolerations


# --- 5. UPDATE STRATEGIES ---------------------------------------------------

# 5.1 RollingUpdate (default) — controller rolls Pods automatically:
kubectl set image daemonset/log-collector log-collector=busybox:1.37
kubectl rollout status daemonset/log-collector
kubectl rollout undo daemonset/log-collector
kubectl rollout status daemonset/log-collector

# 5.2 OnDelete — operator drives the rollout, Pod by Pod:
kubectl apply -f manifests/05-daemonset-ondelete.yaml
kubectl get daemonset manual-agent -o jsonpath='{.spec.updateStrategy.type}{"\n"}'

kubectl set image daemonset/manual-agent c=busybox:1.37
kubectl get pods -l app=manual-agent -o wide   # nothing changed
POD=$(kubectl get pod -l app=manual-agent -o jsonpath='{.items[0].metadata.name}')
kubectl delete pod "$POD"
sleep 5
kubectl get pods -l app=manual-agent -o wide   # only the deleted Pod is on the new image


# --- 6. CLEANUP --------------------------------------------------------------
# DO NOT SKIP — the extra node pool bills until you delete it.

kubectl delete -f manifests/ --ignore-not-found
kubectl delete namespace lab10

for n in $(kubectl get node -o name); do
  kubectl label "$n" agent-role- 2>/dev/null || true
done

az aks nodepool delete \
  --resource-group "$RG" \
  --cluster-name "$CLUSTER" \
  --name workload \
  --no-wait

kubectl config set-context --current --namespace=default
echo "Cleanup initiated. Verify with: az aks nodepool list --resource-group $RG --cluster-name $CLUSTER --output table"
