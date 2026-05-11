# Hands-on 08: Labels, selectors, and resource management

## Objective

Labels and resource requests are the two Pod-level properties that drive **everything else** in Kubernetes:

- **Labels** are how Services find their Pods, how Deployments find their replicas, how `kubectl` queries, how NetworkPolicies match, and how the scheduler is told "place this on a node with property X" (lab 09).
- **Resource requests** are how the scheduler decides whether a Pod *fits* on a node. **Resource limits** are how the kubelet enforces ceiling behavior at runtime (CPU throttling, OOMKill).

By the end of this lab you will understand:
- The difference between labels and annotations, and when to use each
- Equality-based vs set-based selectors and how `kubectl`, Services, and Deployments use them
- Why a Deployment's `spec.selector` is immutable
- The three QoS classes (Guaranteed, Burstable, BestEffort) and how they map to `requests`/`limits`
- Why memory limits are *hard* (OOMKill) but CPU limits are *soft* (throttle)
- How `LimitRange` and `ResourceQuota` let cluster admins set defaults and ceilings per namespace

---

## Prerequisites

```bash
minikube start

kubectl create namespace lab08
kubectl config set-context --current --namespace=lab08
```

This lab runs fine on a single-node cluster — every concept here is Pod-level, not node-level. Node-aware scheduling is the next lab (`scheduling`).

---

## Part 1 — Labels and annotations

A **label** is a `key=value` pair attached to an object's metadata. Labels are *identifying*: they are how Kubernetes finds objects. An **annotation** is also a `key=value` pair, but it is *non-identifying*: arbitrary metadata for tooling, humans, or operators.

```bash
# Apply six Pods with deliberately diverse labels:
kubectl apply -f manifests/01-labeled-pods.yaml

# Look at the labels of each Pod:
kubectl get pods --show-labels
```

You should see Pods with combinations of `app`, `tier`, `env`, and `version`. Try modifying a label live:

```bash
# Add or overwrite a label on a running Pod:
kubectl label pod frontend-prod canary=true
kubectl label pod frontend-prod canary=false --overwrite
kubectl label pod frontend-prod canary-                # the trailing '-' removes the label

kubectl get pod frontend-prod --show-labels
```

### Annotations

```bash
# Annotations are mutated the same way but DO NOT affect selectors:
kubectl annotate pod frontend-prod owner="team-platform" --overwrite
kubectl describe pod frontend-prod | grep -A2 Annotations
```

**Rule of thumb:** if a controller or selector should be able to *find* the object by it → label. If it is just metadata for humans or tooling → annotation.

---

## Part 2 — Selectors

Selectors are how you query labels. There are two flavors.

### 2.1 Equality-based (the common one)

```bash
# All Pods labelled app=frontend:
kubectl get pods -l app=frontend

# Two conditions ANDed:
kubectl get pods -l 'app=frontend,env=prod'

# Negation:
kubectl get pods -l 'env!=prod'
```

### 2.2 Set-based (more expressive)

```bash
# Membership:
kubectl get pods -l 'tier in (web,cache)'

# Non-membership:
kubectl get pods -l 'tier notin (db)'

# Existence (the label exists regardless of value):
kubectl get pods -l 'canary'

# Non-existence:
kubectl get pods -l '!canary'

# Combined:
kubectl get pods -l 'app in (frontend,backend),env=prod,!canary'
```

### 2.3 Mass operations driven by selectors

```bash
# Delete all dev Pods at once:
kubectl delete pod -l env=dev

# Re-label every remaining frontend Pod at once:
kubectl label pods -l app=frontend reviewed=2026 --overwrite
kubectl get pods -l app=frontend --show-labels
```

This is the single most common kubectl pattern for operating real clusters: "everything that belongs to app X".

---

## Part 3 — How resources use selectors

Services, Deployments, and most other workload resources use selectors internally to find the Pods they manage.

```bash
kubectl apply -f manifests/02-broken-service.yaml
kubectl get pods,svc,endpoints -l app=demo
```

The Service `demo-svc` defines `selector: {app: demo, tier: web}`. The Deployment `demo-app` creates Pods with exactly those labels. Look at the `Endpoints` resource — it lists the Pod IPs the Service load-balances to.

### 3.1 Break the selector on purpose

```bash
# Mutate one Pod's 'tier' label so it no longer matches the Service:
POD=$(kubectl get pod -l app=demo -o jsonpath='{.items[0].metadata.name}')
kubectl label pod "$POD" tier=detached --overwrite

# The Pod is REMOVED from the Service's Endpoints:
kubectl get endpoints demo-svc
# (only 1 IP listed now instead of 2)
```

The Pod is still running. The Deployment will notice that the labels no longer match its own selector and spin up a new Pod to replace it (because the Deployment counts only Pods with `app=demo,tier=web`):

```bash
kubectl get pods -l app=demo
# You now have 3 Pods: 2 owned by the Deployment + 1 orphaned by the relabel.
```

This is the *escape hatch* used in production for debugging: "remove a misbehaving Pod from rotation without killing it" by changing its label.

### 3.2 Why Deployment.spec.selector is immutable

```bash
# This FAILS:
kubectl patch deployment demo-app --type=json -p='[{"op":"replace","path":"/spec/selector/matchLabels/tier","value":"api"}]' 2>&1 | tail -3
# Error: field is immutable
```

If you could change the selector, the Deployment could lose track of the Pods it owns (orphaning them) or accidentally adopt Pods it did not create. The API server refuses to allow this — you have to delete and re-create the Deployment to change its selector.

---

## Part 4 — Resource requests: scheduler input

`requests` tell the scheduler **the minimum amount** of CPU/memory the Pod needs. The scheduler sums all requests of currently-running Pods on each node, compares with node capacity, and only places the Pod where it fits.

```bash
# A Pod that asks for an absurd amount of memory:
kubectl apply -f manifests/03-impossible-request.yaml

# It stays Pending forever:
kubectl get pod memory-hog
kubectl describe pod memory-hog | grep -A5 Events
# Expected: FailedScheduling — "Insufficient memory"
```

Limits don't matter to the scheduler. Only **requests** affect placement.

```bash
# Look at all nodes' allocatable resources vs current requests:
kubectl describe nodes | grep -A5 'Allocated resources'

kubectl delete pod memory-hog
```

---

## Part 5 — Resource limits and QoS classes

When a Pod has both `requests` and `limits`, Kubernetes assigns it one of three **QoS classes**, which determine eviction priority under pressure:

| QoS | Pattern | Behavior under memory pressure |
|-----|---------|--------------------------------|
| **Guaranteed** | `requests == limits` for ALL containers, ALL resources | Last to be evicted. The promise is real. |
| **Burstable** | At least one container has `requests < limits` | Evicted before Guaranteed if it exceeds its request |
| **BestEffort** | NO container declares requests or limits | First to be evicted, and the OOM killer targets it first |

```bash
# Create one Pod in each QoS class:
kubectl apply -f manifests/04-qos-classes.yaml

# The qosClass field is computed by Kubernetes, not set by you:
kubectl get pod -l demo=qos -o custom-columns='NAME:.metadata.name,QOS:.status.qosClass'
# Expected:
#   guaranteed-pod   Guaranteed
#   burstable-pod    Burstable
#   besteffort-pod   BestEffort
```

### 5.1 Memory limit is HARD: OOMKilled demo

```bash
# This Pod requests 64 MiB, limit 128 MiB, then tries to allocate 300 MiB:
kubectl apply -f manifests/05-oom-kill-demo.yaml

# Watch the kubelet OOM-kill it:
kubectl get pod oom-victim -w
# State should oscillate: ContainerCreating → Running → OOMKilled → CrashLoopBackOff

# Confirm the cause:
kubectl describe pod oom-victim | grep -A3 'Last State'
# Expected: Last State: Terminated, Reason: OOMKilled, Exit Code: 137

kubectl delete pod oom-victim
```

Exit code 137 = 128 + 9 (SIGKILL). That's the kernel's OOM killer at work, dispatched the moment the cgroup memory limit is exceeded.

### 5.2 CPU limit is SOFT: throttling demo

CPU is throttled, not killed. A Pod with `limits.cpu: 100m` simply gets less time on the CPU each scheduling slice — but it stays alive and runs at reduced speed.

```bash
kubectl apply -f manifests/06-cpu-throttle-demo.yaml
kubectl wait --for=condition=Ready pod/cpu-stress --timeout=30s

# Watch CPU usage stay PINNED at the limit:
# (requires metrics-server; minikube addons enable metrics-server if needed)
kubectl top pod cpu-stress --use-protocol-buffers
# Repeat the command a few times — CPU never exceeds ~100m no matter how hard
# the workload tries.

kubectl delete pod cpu-stress
```

> **Practical implication:** an under-CPU-limited Pod runs slowly but works. An under-memory-limited Pod *dies*. Always size memory limits with headroom; CPU limits can be aggressive.

---

## Part 6 — LimitRange: namespace-level defaults and bounds

Without a `LimitRange`, a Pod that omits `resources` lands in BestEffort QoS — first to be evicted. In multi-tenant clusters that is dangerous. `LimitRange` lets the admin enforce minimums and maximums, and inject defaults when developers forget.

```bash
kubectl apply -f manifests/07-limitrange.yaml
kubectl describe limitrange resources-default

# Create a Pod that declares NO resources:
kubectl apply -f manifests/03-besteffort-naked.yaml

# Look at the Pod — the LimitRange injected the defaults:
kubectl get pod naked-pod -o jsonpath='{.spec.containers[0].resources}'
echo
# Expected: requests AND limits filled in from the LimitRange defaults.

# QoS class is now Burstable, not BestEffort:
kubectl get pod naked-pod -o jsonpath='{.status.qosClass}'
echo

kubectl delete pod naked-pod
```

`LimitRange` can also reject Pods that ask for more than `max` or less than `min`:

```bash
# Try to create a Pod that asks for 4Gi memory (LimitRange max is 512Mi):
kubectl apply -f manifests/03-oversized-request.yaml 2>&1 | tail -3
# Expected: "maximum memory usage per Container is 512Mi"
```

---

## Part 7 — ResourceQuota: total cap per namespace

`ResourceQuota` enforces a hard limit on the SUM of requests/limits across the namespace. The admission controller rejects any Pod that would push the total over the limit.

```bash
kubectl apply -f manifests/08-resourcequota.yaml
kubectl describe resourcequota namespace-budget

# Try to create 3 Pods that each request 200m CPU — the quota allows 500m total:
kubectl apply -f manifests/08-quota-test-pods.yaml 2>&1 | tail -5
# Expected: the third Pod is rejected because 600m > 500m quota.

kubectl get pods -l demo=quota
# Only quota-pod-1 and quota-pod-2 were admitted.

kubectl delete pod -l demo=quota
```

---

## Part 8 — Cleanup

```bash
kubectl delete -f manifests/ --ignore-not-found
kubectl delete namespace lab08
kubectl config set-context --current --namespace=default
```

---

## Discussion questions

1. You take a stable Service and change its `selector` to use a different label key. Every existing Pod still has the old label. What does `kubectl get endpoints` show, and what happens to traffic?
2. Why is `Guaranteed` QoS only assigned when `requests == limits` for *every* container in the Pod, not just one?
3. Your team is debugging a `CrashLoopBackOff` Pod with exit code 137. You suspect OOM. What is the first command you run to confirm, and where does it look?
4. A developer asks why the cluster keeps rejecting their `replicas: 50` Deployment with the error `exceeded quota: requests.cpu`. You have a `ResourceQuota`. What two changes can the developer make to get the Deployment to fit?
5. When would you choose a strict CPU `limit` and when would you leave it unset? (Hint: latency-sensitive workloads vs throughput-oriented batch jobs.)

---

## Key concepts

| Concept | Mental model |
|---------|--------------|
| Label | Identifying tag — "this Pod belongs to X". The scheduler, Services, and controllers all key off labels. |
| Annotation | Non-identifying metadata — owner, change ticket, last-applied config. Tooling uses annotations. |
| Selector (equality) | `key=value,key2=value2` — all conditions ANDed |
| Selector (set-based) | `key in (a,b)`, `key notin (...)`, `key`, `!key` |
| `requests` | What the scheduler reserves on the node. Smaller = more Pods fit. |
| `limits` | Runtime ceiling. Exceeding memory = OOMKilled. Exceeding CPU = throttled. |
| QoS class | Guaranteed > Burstable > BestEffort — eviction priority under pressure |
| `LimitRange` | Per-namespace default & min/max enforcement at admission time |
| `ResourceQuota` | Per-namespace total budget (CPU, memory, Pod count, PVC count, etc.) |
