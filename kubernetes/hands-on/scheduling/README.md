# Hands-on 09: Scheduling — placing Pods where you want them

## Objective

The Kubernetes scheduler is the component that watches for Pods without a `nodeName` and assigns each one to a node. It does this in two phases:

1. **Filtering** — eliminate every node that cannot host the Pod (insufficient resources, taints not tolerated, node selector mismatch, hostPort conflicts).
2. **Scoring** — rank the remaining nodes by a set of priority functions, pick the highest score.

This lab covers the **mechanisms you, as the workload author, use to influence both phases**:

- `nodeSelector` — the simplest hard filter
- `nodeAffinity` — required vs preferred, with rich match expressions
- `podAffinity` / `podAntiAffinity` — place Pods relative to other Pods
- **Taints and tolerations** — the *node* says "I do not want random Pods"
- `topologySpreadConstraints` — even distribution across zones / nodes
- A realistic combined scenario: a "GPU pool" pattern that mixes all of the above

By the end you will know **which tool to reach for** when a workload has a placement requirement, and how to read scheduling failures in `kubectl describe pod`.

---

## Prerequisites

This lab requires a **multi-node cluster with at least two node pools** so we can demonstrate node-aware scheduling. We use the AKS cluster from lab 06.

> **Cost warning.** Running an extra AKS node pool with one node costs ~0.02–0.04 EUR/hour. Always run the Part 7 cleanup to delete the extra pool when you finish.

### Verify the existing cluster

```bash
RG=rg-aks-lab05
CLUSTER=aks-lab05

kubectl config use-context "$CLUSTER"
kubectl get nodes
# Expected: 2 system nodes (the default 'nodepool1' or 'agentpool')
```

### Add a second node pool with a distinguishing label

```bash
az aks nodepool add \
  --resource-group "$RG" \
  --cluster-name "$CLUSTER" \
  --name workload \
  --node-count 1 \
  --node-vm-size Standard_B2s \
  --labels role=workload tier=app

# Confirm the new node appears with the label:
kubectl get nodes --show-labels | grep role=workload
```

You should now have 3 nodes total: 2 system nodes and 1 workload node. The workload node carries `role=workload` — that is the label we will target.

### Create the lab namespace

```bash
kubectl create namespace lab09
kubectl config set-context --current --namespace=lab09
```

---

## Part 1 — `nodeSelector`: the simplest hard constraint

`nodeSelector` is a Pod-level field. The scheduler will only consider nodes whose labels match every key/value in the map.

```bash
kubectl apply -f manifests/01-nodeselector-pod.yaml

# Check where it landed:
kubectl get pod selector-pod -o wide
# NODE column should be the new 'workload' node, not the system pool.
```

### What happens when no node matches?

```bash
kubectl apply -f manifests/01-nodeselector-impossible.yaml

kubectl get pod selector-impossible
# Expected: Pending forever.

kubectl describe pod selector-impossible | grep -A5 Events
# Expected event: "0/3 nodes are available: 3 node(s) didn't match Pod's node affinity/selector"
```

> `nodeSelector` cannot express "prefer this but tolerate falling back" or "any of these labels". That is why `nodeAffinity` exists.

---

## Part 2 — `nodeAffinity`: expressive node selection

`nodeAffinity` has two flavors:

| Flavor | Behavior |
|--------|----------|
| `requiredDuringSchedulingIgnoredDuringExecution` | Hard filter. Pod stays Pending if no node matches. Same effect as `nodeSelector` but more expressive (supports operators). |
| `preferredDuringSchedulingIgnoredDuringExecution` | Soft preference with a weight. Scheduler prefers matching nodes but falls back to any node if none match. |

> The `IgnoredDuringExecution` suffix means the constraint is only evaluated at *scheduling* time. If you change a node's labels after the Pod is scheduled, nothing happens — the Pod is not evicted.

### 2.1 Required affinity (with operators)

```bash
kubectl apply -f manifests/02-nodeaffinity-required.yaml

kubectl get pod affinity-required -o wide
kubectl describe pod affinity-required | grep -A6 'Node-Selectors\|Affinity'
```

The manifest uses the `In` operator: "place me where `role` is `workload` OR `app`". Other operators available: `NotIn`, `Exists`, `DoesNotExist`, `Gt`, `Lt`.

### 2.2 Preferred affinity (soft)

```bash
kubectl apply -f manifests/02-nodeaffinity-preferred.yaml

kubectl get pod affinity-preferred -o wide
```

Note that the Pod is **scheduled even if no node matches**. The preference just tilts the scheduler's score; it does not act as a filter. Apply this same manifest to a cluster without the `role=workload` label and the Pod still runs.

### 2.3 AKS-provided node labels you can target

Every node in AKS automatically carries useful labels you can use as scheduling inputs without setting anything manually:

```bash
kubectl get node -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .metadata.labels}{"  "}{@}{": "}{@}{"\n"}{end}{end}' \
  | head -40
```

The most commonly targeted ones:

| Label | Example | Use case |
|-------|---------|----------|
| `topology.kubernetes.io/zone` | `westeurope-1` | Spread across availability zones |
| `topology.kubernetes.io/region` | `westeurope` | Multi-region clusters |
| `kubernetes.azure.com/agentpool` | `workload` | Target a specific AKS node pool |
| `kubernetes.io/arch` | `amd64` | Avoid arm64 nodes (or require them) |
| `node.kubernetes.io/instance-type` | `Standard_B2s` | Pin to a VM SKU |

---

## Part 3 — `podAffinity` and `podAntiAffinity`

These let you place a Pod *relative to other Pods* (already running) instead of relative to nodes.

| Mechanism | Says |
|-----------|------|
| `podAffinity` | "Schedule me near Pods that match this label, in the same topology" |
| `podAntiAffinity` | "Keep me away from Pods that match this label, in the same topology" |

`topologyKey` is the node label that defines "same":
- `kubernetes.io/hostname` → same node
- `topology.kubernetes.io/zone` → same availability zone

### 3.1 Spread Deployment replicas across nodes (anti-affinity)

The classic pattern: avoid two replicas of the same Deployment on the same node, so a node failure does not take out the entire service.

```bash
kubectl apply -f manifests/03-podantiaffinity-deployment.yaml
kubectl rollout status deployment/web-spread

# Look at where the replicas landed:
kubectl get pods -l app=web-spread -o wide
# Each replica should be on a different node (we have 3, replicas=3).
```

If you scale to 4 replicas, the 4th sits Pending because there is no fourth node that satisfies the constraint. Try it:

```bash
kubectl scale deployment web-spread --replicas=4
sleep 5
kubectl get pods -l app=web-spread -o wide
# The 4th Pod is Pending. Its 'describe' explains: "node(s) didn't match pod anti-affinity rules"

kubectl scale deployment web-spread --replicas=3
```

---

## Part 4 — Taints and tolerations: the *node's* veto

Affinity is *Pod-driven*: the Pod chooses where to go. Taints are *node-driven*: the node refuses Pods that have not explicitly opted in.

A taint has the form `key=value:effect` and three possible effects:

| Effect | Meaning |
|--------|---------|
| `NoSchedule` | Do not place new Pods here unless they tolerate this taint |
| `PreferNoSchedule` | Try to avoid placing Pods here, but it's a soft rule |
| `NoExecute` | Evict already-running Pods that do not tolerate, AND block new ones |

### 4.1 Taint the workload node

```bash
WORKLOAD_NODE=$(kubectl get node -l role=workload -o jsonpath='{.items[0].metadata.name}')
echo "Tainting node: $WORKLOAD_NODE"

kubectl taint node "$WORKLOAD_NODE" dedicated=ml:NoSchedule

# Verify:
kubectl describe node "$WORKLOAD_NODE" | grep -i taint
```

### 4.2 A Pod without toleration: rejected

```bash
kubectl apply -f manifests/04-pod-no-toleration.yaml

kubectl get pod intolerant -o wide
kubectl describe pod intolerant | grep -A5 Events
# Expected: "1 node(s) had untolerated taint {dedicated: ml}"
# The Pod is scheduled to one of the SYSTEM nodes (which are not tainted),
# but it CANNOT land on the workload node anymore.

kubectl delete pod intolerant
```

### 4.3 A Pod WITH toleration: allowed onto the tainted node

```bash
kubectl apply -f manifests/04-pod-with-toleration.yaml

kubectl get pod tolerant -o wide
# Should land on the workload node — the toleration matches the taint.
```

Note: a toleration just *allows* the Pod onto a tainted node; it does **not force** it there. To force the Pod onto the workload node we also add a `nodeSelector` (or `nodeAffinity`). That combination is the real-world pattern, demonstrated in Part 6.

### 4.4 Why kube-system Pods can run on any node

```bash
# Look at a kube-system DaemonSet — it tolerates everything:
kubectl get daemonset -n kube-system kube-proxy -o jsonpath='{.spec.template.spec.tolerations}' | python -m json.tool
```

You will see entries with `operator: Exists` and no key — meaning "tolerate ANY taint". That is how cluster-critical Pods (kube-proxy, CSI drivers, monitoring agents) keep running on nodes that have been tainted, including for graceful shutdown (`NoExecute`).

### 4.5 Cleanup: remove the taint

```bash
# IMPORTANT: with the trailing '-' to delete the taint by key.
kubectl taint node "$WORKLOAD_NODE" dedicated-
```

---

## Part 5 — `topologySpreadConstraints`

Anti-affinity is binary ("never together"). `topologySpreadConstraints` is granular: "spread evenly with at most N more Pods on any one bucket".

```bash
kubectl apply -f manifests/05-topologyspread-deployment.yaml
kubectl rollout status deployment/spread-app

# Check the spread:
kubectl get pods -l app=spread-app -o wide
# With maxSkew=1 and topologyKey=kubernetes.io/hostname, no node should have
# more than (min + 1) Pods of this Deployment.
```

`maxSkew` is the allowed imbalance: "the difference between the most populous bucket and the least populous must not exceed N". `whenUnsatisfiable: DoNotSchedule` makes it a hard constraint; `ScheduleAnyway` makes it a preference.

This is the constraint you want for any production multi-replica workload that should survive a node or zone failure. Anti-affinity becomes annoying once you have more replicas than nodes; spread constraints handle that gracefully.

---

## Part 6 — Realistic combined scenario: the "ML pool" pattern

Imagine a node pool reserved for machine-learning training jobs. Three requirements:

1. **Only ML jobs land there.** Block normal workloads. → **taint** the pool.
2. **ML jobs must land there.** Don't let them schedule on the system pool. → **nodeSelector**.
3. **Among ML jobs, spread them.** Don't pile two GPU jobs on one node. → **podAntiAffinity**.

Putting all three together is the canonical "dedicated pool" pattern. We simulate it without real GPUs.

### 6.1 Re-taint the workload pool to represent "ML-only"

```bash
WORKLOAD_NODE=$(kubectl get node -l role=workload -o jsonpath='{.items[0].metadata.name}')
kubectl taint node "$WORKLOAD_NODE" workload-type=ml:NoSchedule
kubectl label node "$WORKLOAD_NODE" workload-type=ml --overwrite
```

### 6.2 Deploy the workloads

```bash
kubectl apply -f manifests/06-ml-scenario/

# Wait for everything to settle:
sleep 10
```

### 6.3 Verify placement

```bash
echo '--- web workload (should be on system nodes only) ---'
kubectl get pods -l app=web-workload -o wide

echo '--- ML jobs (should be on the workload node, anti-affine to each other) ---'
kubectl get pods -l app=ml-job -o wide
```

What you should see:
- The 3 `web-workload` Pods land on the system nodes. They cannot land on the workload node because they do not tolerate `workload-type=ml`.
- The first `ml-job` Pod lands on the workload node (it tolerates the taint, has the right nodeSelector). The second and third stay `Pending` because the anti-affinity rule says "no two ML jobs on the same node" and there is only one ML node. In real production you would add more nodes to the ML pool.

```bash
kubectl describe pod -l app=ml-job | grep -B2 -A6 'Events'
```

> **Scaling lesson:** to run more ML jobs in parallel, scale up the workload pool (`az aks nodepool scale --name workload --node-count 3`). The Pending Pods schedule automatically.

---

## Part 7 — Cleanup

> **⚠️ DO NOT SKIP.** The extra `workload` node pool keeps billing as long as it exists.

```bash
# 7.1 Remove Kubernetes resources
kubectl delete -f manifests/06-ml-scenario/ --ignore-not-found
kubectl delete -f manifests/ --ignore-not-found
kubectl delete namespace lab09

# 7.2 Remove the taint from the workload node (so we don't break the pool delete)
WORKLOAD_NODE=$(kubectl get node -l role=workload -o jsonpath='{.items[0].metadata.name}')
kubectl taint node "$WORKLOAD_NODE" workload-type- 2>/dev/null || true
kubectl taint node "$WORKLOAD_NODE" dedicated-     2>/dev/null || true

# 7.3 Delete the extra AKS node pool
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

1. You have two workloads: a latency-sensitive HTTP API that must spread across zones, and a batch job that must run on cheap spot nodes. Which scheduling mechanism does each one use?
2. A node has the taint `dedicated=ml:NoSchedule`. A Pod has the toleration `key: dedicated, operator: Exists`. Does the Pod tolerate the taint? What changes if the operator were `Equal` without a `value`?
3. `nodeAffinity` is checked at scheduling time only (`IgnoredDuringExecution`). What does this mean for a Pod that was scheduled to a node, and then someone removes the label that the affinity was matching?
4. Anti-affinity scales O(N²) with the number of Pods — large fleets can stall scheduling. What is the more scalable alternative for "spread N replicas across the cluster"?
5. The kube-system DaemonSets tolerate every taint. Why is that necessary for cluster operation, and what is the risk?

---

## Key concepts

| Mechanism | When to use |
|-----------|-------------|
| `nodeSelector` | Trivial label-equality match; quick prototype |
| `nodeAffinity` required | Hard constraint with expressive operators (In, NotIn, Exists, Gt, Lt) |
| `nodeAffinity` preferred | Soft preference for scoring; do not block scheduling |
| `podAffinity` | Co-locate Pods (e.g. a cache near its consumer) |
| `podAntiAffinity` | Separate Pods (high-availability replicas across nodes/zones) |
| Taints + tolerations | Reserve nodes for specific workloads; node-driven veto |
| `topologySpreadConstraints` | Even distribution at scale, gracefully handles imbalance |

**Reading scheduling failures:**

```
kubectl describe pod <name>
   → look for the 'Events' section
   → 'FailedScheduling' reason will tell you exactly which filter rejected each node
     ("Insufficient memory", "untolerated taint", "didn't match Pod's node affinity",
      "didn't match pod anti-affinity rules", ...)
```

**Decision flow for "where should this Pod run":**

```
Does the workload require a specific HARDWARE class (GPU, ARM, high-RAM SKU)?
    → label nodes  +  nodeSelector / nodeAffinity required

Should other random Pods NOT land on this hardware?
    → taint the nodes  +  matching toleration on the privileged Pods

Should replicas be spread for HA?
    → topologySpreadConstraints (preferred) or podAntiAffinity

Are two Pods more efficient if co-located (cache/consumer)?
    → podAffinity
```
