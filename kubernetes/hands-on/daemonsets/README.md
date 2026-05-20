# Hands-on 10: DaemonSets — one Pod per node

## Objective

A **DaemonSet** guarantees that *every node* (or every node matching a selector) runs exactly one copy of a Pod. As nodes join the cluster the controller adds Pods automatically; as nodes leave, the Pods are garbage-collected. This is the controller behind every "node-level agent": log shippers, monitoring agents, CNI plugins, CSI drivers, kube-proxy.

By the end of this lab you will be able to:

- Recognise the use cases that call for a DaemonSet instead of a Deployment.
- Author a DaemonSet, including `nodeSelector`, `tolerations` and `hostPath` volumes.
- Restrict a DaemonSet to a subset of nodes and observe the controller react to label changes.
- Roll out an update with `RollingUpdate` vs `OnDelete` strategies.
- Inspect the DaemonSets that already run on every Kubernetes cluster (`kube-proxy`, CSI drivers, log/metric agents).

---

## Prerequisites

The lab runs on the **AKS cluster from lab 06** (`rg-aks-lab05` / `aks-lab05`). A multi-node cluster makes the "one Pod per node" behaviour visible — on a single-node minikube/kind everything still works but you only ever see one Pod.

> **Cost note.** The lab uses only the existing AKS nodes. If you finished lab 09, make sure you already deleted the extra `workload` node pool. We will add it back for Part 4 and remove it again in Part 6.

```bash
RG=rg-aks-lab05
CLUSTER=aks-lab05

kubectl config use-context "$CLUSTER"
kubectl get nodes
# Expected: at least 2 nodes (the default system pool).

kubectl create namespace lab10
kubectl config set-context --current --namespace=lab10
```

---

## Part 1 — Your first DaemonSet

The simplest DaemonSet runs a single container per node. We start with a `busybox` Pod that just sleeps — enough to see the controller create one Pod per node and clean them up.

```bash
kubectl apply -f manifests/01-daemonset-basic.yaml

# Watch the controller place one Pod per node:
kubectl get daemonset node-heartbeat
# Look at: DESIRED, CURRENT, READY, UP-TO-DATE, AVAILABLE, NODE SELECTOR

kubectl get pods -l app=node-heartbeat -o wide
# One Pod per node, each landed on a different node.
```

### What the controller did

```bash
kubectl describe daemonset node-heartbeat | sed -n '/Events/,$p'
# You will see 'SuccessfulCreate' events, one per node.
```

If you add a node to the cluster (e.g. `az aks scale --node-count`), the DaemonSet controller will create one extra Pod within seconds — no `kubectl scale` required. That is the core distinction from a Deployment.

> **Deployment vs DaemonSet.** A Deployment thinks in *replicas* ("give me N copies somewhere"). A DaemonSet thinks in *nodes* ("give me one copy on every node that matches"). Replica count is not configurable; it is derived from the node set.

---

## Part 2 — Restricting placement with `nodeSelector`

Most real-world DaemonSets do **not** run on every node — only on the ones that need the agent (Linux nodes only, GPU nodes only, ingress nodes only). The mechanism is `spec.template.spec.nodeSelector` (or `nodeAffinity`).

### 2.1 Label one node

```bash
# Pick any node and give it a label:
NODE=$(kubectl get node -o jsonpath='{.items[0].metadata.name}')
kubectl label node "$NODE" agent-role=logs --overwrite
kubectl get node --show-labels | grep agent-role
```

### 2.2 Apply a DaemonSet restricted to that label

```bash
kubectl apply -f manifests/02-daemonset-nodeselector.yaml

kubectl get daemonset logs-agent
# DESIRED should equal the number of nodes carrying agent-role=logs (so: 1).

kubectl get pods -l app=logs-agent -o wide
# Exactly one Pod, on the node you labelled.
```

### 2.3 Add the label to a second node — the controller reacts

```bash
OTHER_NODE=$(kubectl get node -o jsonpath='{.items[1].metadata.name}')
kubectl label node "$OTHER_NODE" agent-role=logs --overwrite

# Within seconds:
kubectl get pods -l app=logs-agent -o wide
# DESIRED jumps to 2 and a new Pod appears on the second node.
```

### 2.4 Remove the label — the Pod is evicted

```bash
kubectl label node "$OTHER_NODE" agent-role-
kubectl get pods -l app=logs-agent -o wide
# Back down to one Pod.
```

This reconciliation loop (node labels ↔ DaemonSet Pods) is what powers cluster-wide agents that auto-install on the right hardware.

---

## Part 3 — A realistic example: log collector with `hostPath`

Real node-level agents need access to host resources: the host's log directory, the container runtime socket, the host network. The classic primitive is a `hostPath` volume.

```bash
kubectl apply -f manifests/03-daemonset-logcollector.yaml

kubectl rollout status daemonset/log-collector
kubectl get pods -l app=log-collector -o wide
```

Inspect what the agent actually sees:

```bash
POD=$(kubectl get pod -l app=log-collector -o jsonpath='{.items[0].metadata.name}')

# The container has the host's /var/log mounted read-only:
kubectl exec "$POD" -- ls /host-logs | head

# And it is printing them to its own stdout — that is what a real log shipper
# would forward to Elasticsearch / Loki / Azure Monitor.
kubectl logs "$POD" --tail=5
```

> **Why `hostPath` is special.** Most workloads should never use `hostPath` — it ties the Pod to a specific node and bypasses storage abstractions. Node-level agents are the legitimate exception: they *want* to read the node's files. Keep `readOnly: true` whenever possible.

---

## Part 4 — Tolerations: running on tainted nodes

Taints block normal Pods from a node (we covered this in lab 09). A DaemonSet that should run *everywhere* must therefore tolerate every taint the cluster might use. That is why `kube-proxy` and CSI driver DaemonSets carry blanket tolerations.

### 4.1 Add a tainted node pool

```bash
RG=rg-aks-lab05
CLUSTER=aks-lab05

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
# You should see one new node. It carries a taint:
kubectl describe node -l agentpool=workload | grep -i taints
```

### 4.2 The basic DaemonSet from Part 1 does NOT land there

```bash
kubectl get pods -l app=node-heartbeat -o wide
# Notice: still only as many Pods as untainted nodes. No Pod on the workload node.

kubectl describe daemonset node-heartbeat | grep -i 'desired\|current\|available'
# DESIRED reflects the number of nodes WITHOUT a blocking taint — DaemonSet
# controller pre-filters tainted nodes when the template has no toleration.
```

### 4.3 Apply a DaemonSet that tolerates everything

```bash
kubectl apply -f manifests/04-daemonset-tolerate-all.yaml

kubectl get pods -l app=cluster-agent -o wide
# Now there is ONE Pod per node, including the tainted workload node and
# (on real clusters) the control plane nodes.
```

The `tolerations` block uses `operator: Exists` with no `key` — that matches *any* taint. This is the pattern you'll see in every production node-agent.

### 4.4 Inspect a real-world DaemonSet

```bash
# kube-proxy is itself a DaemonSet — every cluster has one.
kubectl get daemonset -n kube-system

# Look at how kube-proxy tolerates taints so that it keeps running on every node:
kubectl get daemonset -n kube-system kube-proxy \
  -o jsonpath='{.spec.template.spec.tolerations}' | python -m json.tool 2>/dev/null \
  || kubectl get daemonset -n kube-system kube-proxy -o yaml | grep -A20 tolerations
```

---

## Part 5 — Update strategies

DaemonSets support two `updateStrategy` values:

| Strategy | Behaviour |
|----------|-----------|
| `RollingUpdate` (default) | Replace Pods node-by-node, respecting `maxUnavailable`. Good for stateless agents. |
| `OnDelete` | Do not touch existing Pods. The new template applies only as Pods are manually deleted. Useful when you want operators to choose the rollout pace. |

### 5.1 Rolling update — bump the image

```bash
# Patch the image; the controller rolls Pods one by one.
kubectl set image daemonset/log-collector log-collector=busybox:1.37

kubectl rollout status daemonset/log-collector
# Watch each Pod be recreated with the new image. Use:
#   kubectl get pods -l app=log-collector -o wide -w
# (Ctrl-C to stop)

# Roll back:
kubectl rollout undo daemonset/log-collector
kubectl rollout status daemonset/log-collector
```

### 5.2 `OnDelete` strategy

```bash
kubectl apply -f manifests/05-daemonset-ondelete.yaml
kubectl get daemonset manual-agent -o jsonpath='{.spec.updateStrategy.type}{"\n"}'

# Bump the image — nothing happens:
kubectl set image daemonset/manual-agent c=busybox:1.37
kubectl get pods -l app=manual-agent -o wide
# Same Pods, same age, same old image.

# Force a refresh on one node by deleting its Pod:
POD=$(kubectl get pod -l app=manual-agent -o jsonpath='{.items[0].metadata.name}')
kubectl delete pod "$POD"
kubectl get pods -l app=manual-agent -o wide
# The new Pod uses the updated template; the others remain on the old version
# until you delete them too.
```

This is the strategy you want when the agent has side effects (drains a buffer, flushes counters) and you need each upgrade to be driven manually.

---

## Part 6 — Cleanup

> **⚠️ DO NOT SKIP.** The extra `workload` node pool keeps billing as long as it exists.

```bash
# 6.1 Kubernetes resources
kubectl delete -f manifests/ --ignore-not-found
kubectl delete namespace lab10

# 6.2 Strip the lab labels from nodes
for n in $(kubectl get node -o name); do
  kubectl label "$n" agent-role- 2>/dev/null || true
done

# 6.3 Delete the extra AKS node pool (added in Part 4)
RG=rg-aks-lab05
CLUSTER=aks-lab05
az aks nodepool delete \
  --resource-group "$RG" \
  --cluster-name "$CLUSTER" \
  --name workload \
  --no-wait

kubectl config set-context --current --namespace=default
echo "Cleanup initiated. Verify with: az aks nodepool list --resource-group $RG --cluster-name $CLUSTER --output table"
```

---

## Discussion questions

1. Why does the DaemonSet API have no `replicas` field? What controls the Pod count instead?
2. You add a brand-new node to the cluster. Walk through the sequence of events that places a `kube-proxy` Pod on it within seconds.
3. A DaemonSet is configured without any tolerations. The cluster admin taints a node with `NoExecute`. What happens to the DaemonSet Pod already running there? What about new nodes that get the same taint at creation time?
4. When would you choose `updateStrategy: OnDelete` over `RollingUpdate`? Give a concrete example involving a stateful node-level agent.
5. A Deployment of 50 replicas spread across 5 nodes by anti-affinity vs a DaemonSet on those same 5 nodes: in what situations is each one the right answer?

---

## Key concepts

| Concept | What to remember |
|---------|------------------|
| **One Pod per node** | The number of Pods is derived from the node set, not configured. |
| **`nodeSelector` / `nodeAffinity`** | Restrict the DaemonSet to a subset of nodes; the controller reacts to label changes in real time. |
| **`tolerations`** | Required if the DaemonSet must run on tainted nodes — the canonical "tolerate everything" pattern lets cluster-wide agents survive any taint. |
| **`hostPath` volumes** | The legitimate use case for `hostPath`: node-level agents that need to read host files (logs, metrics, sockets). Keep them read-only when possible. |
| **`updateStrategy`** | `RollingUpdate` (default, controller-driven) vs `OnDelete` (operator-driven, one Pod at a time). |
| **Real-world examples** | `kube-proxy`, CNI plugins (`azure-cni`, `cilium`), CSI drivers, log shippers (`fluent-bit`, `promtail`), metric agents (`node-exporter`, `azure-monitor-agent`). |

**Decision flow — "do I want a DaemonSet?":**

```
Does the workload need to run ON every node (or every node of a kind)?
    yes → DaemonSet
    no  → Deployment + replicas + affinity

Does it need access to the node's filesystem, network or kernel?
    yes → DaemonSet (with hostPath / hostNetwork / privileged as needed)

Does scaling mean "more capacity"?
    yes → Deployment (scale replicas)
Does scaling mean "more nodes covered"?
    yes → DaemonSet (scale the cluster, controller reacts)
```
