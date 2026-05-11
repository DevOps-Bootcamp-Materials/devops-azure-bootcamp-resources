#!/usr/bin/env bash
# =============================================================================
# Lab 08 — Labels, selectors, and resource management: command walkthrough
# =============================================================================
# Purpose: practice every selector flavor, then experiment with requests,
#          limits, QoS classes, and namespace-level governance (LimitRange,
#          ResourceQuota).
#
# How to use:
#   Read the explanation, then run each block. The manifests in this lab are
#   applied PIECEMEAL, never with a blanket 'kubectl apply -f manifests/' —
#   several of them are designed to FAIL (impossible request, oversized
#   request, quota exceeded) and that is the point.
#
# Prerequisites:
#   minikube start
#   minikube addons enable metrics-server   # needed for Part 5.2 (kubectl top)
# =============================================================================

# --- 0. SETUP ----------------------------------------------------------------

kubectl create namespace lab08
kubectl config set-context --current --namespace=lab08


# =============================================================================
# PART 1 — Labels and annotations
# =============================================================================

kubectl apply -f manifests/01-labeled-pods.yaml
kubectl get pods --show-labels

# Mutate a label live (adding, overwriting, removing):
kubectl label pod frontend-prod canary=true
kubectl label pod frontend-prod canary=false --overwrite
kubectl label pod frontend-prod canary-                  # trailing '-' removes it
kubectl get pod frontend-prod --show-labels

# Annotations: same syntax, different semantics (not used by selectors):
kubectl annotate pod frontend-prod owner="team-platform" --overwrite
kubectl describe pod frontend-prod | grep -A2 Annotations


# =============================================================================
# PART 2 — Selectors
# =============================================================================

# 2.1 Equality-based
kubectl get pods -l app=frontend
kubectl get pods -l 'app=frontend,env=prod'
kubectl get pods -l 'env!=prod'

# 2.2 Set-based
kubectl get pods -l 'tier in (web,cache)'
kubectl get pods -l 'tier notin (db)'
kubectl get pods -l 'canary'                # existence
kubectl get pods -l '!canary'               # non-existence
kubectl get pods -l 'app in (frontend,backend),env=prod,!canary'

# 2.3 Mass operations driven by selectors
kubectl delete pod -l env=dev
kubectl label pods -l app=frontend reviewed=2026 --overwrite
kubectl get pods -l app=frontend --show-labels


# =============================================================================
# PART 3 — How resources use selectors
# =============================================================================

kubectl apply -f manifests/02-broken-service.yaml
kubectl rollout status deployment/demo-app

kubectl get pods,svc,endpoints -l app=demo

# 3.1 Break the selector on purpose:
POD=$(kubectl get pod -l app=demo -o jsonpath='{.items[0].metadata.name}')
kubectl label pod "$POD" tier=detached --overwrite

# The Pod still runs but the Service has dropped it. Endpoints count goes 2 → 1:
kubectl get endpoints demo-svc

# The Deployment notices it owns only 1 matching Pod and creates a third:
sleep 5
kubectl get pods -l app=demo --show-labels
# Expected: 3 Pods total — 2 with tier=web (Deployment-owned) + 1 with tier=detached (orphaned).

# 3.2 Verify spec.selector is immutable:
kubectl patch deployment demo-app --type=json \
  -p='[{"op":"replace","path":"/spec/selector/matchLabels/tier","value":"api"}]' 2>&1 | tail -3
# Expected: "field is immutable"


# =============================================================================
# PART 4 — Resource requests as scheduler input
# =============================================================================

kubectl apply -f manifests/03-impossible-request.yaml

# Watch it stay Pending:
kubectl get pod memory-hog
kubectl describe pod memory-hog | grep -A5 Events
# Expected: FailedScheduling — Insufficient memory

# What the node thinks of its own capacity vs current usage:
kubectl describe nodes | grep -A6 'Allocated resources'

kubectl delete pod memory-hog


# =============================================================================
# PART 5 — QoS classes and limit enforcement
# =============================================================================

kubectl apply -f manifests/04-qos-classes.yaml
kubectl wait --for=condition=Ready pod -l demo=qos --timeout=30s

# Kubernetes derives qosClass — you do NOT set it:
kubectl get pods -l demo=qos -o custom-columns='NAME:.metadata.name,QOS:.status.qosClass'


# --- 5.1 Memory limit is HARD: OOMKilled ------------------------------------

kubectl apply -f manifests/05-oom-kill-demo.yaml

# Watch the cycle: Running → OOMKilled → CrashLoopBackOff
kubectl get pod oom-victim -w &
WATCH_PID=$!
sleep 30
kill $WATCH_PID 2>/dev/null

kubectl describe pod oom-victim | grep -A3 'Last State'
# Expected: Reason: OOMKilled, Exit Code: 137 (= 128 + 9 = SIGKILL)

kubectl delete pod oom-victim


# --- 5.2 CPU limit is SOFT: throttling --------------------------------------

kubectl apply -f manifests/06-cpu-throttle-demo.yaml
kubectl wait --for=condition=Ready pod/cpu-stress --timeout=30s

# Give metrics-server a few seconds to scrape:
sleep 30

# CPU usage plateaus at ~100m (the limit) no matter how hard the busy-loop tries:
kubectl top pod cpu-stress --use-protocol-buffers
sleep 5
kubectl top pod cpu-stress --use-protocol-buffers

kubectl delete pod cpu-stress


# =============================================================================
# PART 6 — LimitRange
# =============================================================================

kubectl apply -f manifests/07-limitrange.yaml
kubectl describe limitrange resources-default

# A Pod with NO resources block now gets defaults injected at admission time:
kubectl apply -f manifests/03-besteffort-naked.yaml
kubectl get pod naked-pod -o jsonpath='{.spec.containers[0].resources}'
echo
kubectl get pod naked-pod -o jsonpath='{.status.qosClass}'
echo
# Expected qosClass: Burstable (not BestEffort — the LimitRange rescued it)

# Try to bypass the bounds: ask for memory above the max (512Mi):
kubectl apply -f manifests/03-oversized-request.yaml 2>&1 | tail -3
# Expected: "maximum memory usage per Container is 512Mi"

kubectl delete pod naked-pod


# =============================================================================
# PART 7 — ResourceQuota
# =============================================================================

kubectl apply -f manifests/08-resourcequota.yaml
kubectl describe resourcequota namespace-budget

# Apply 3 Pods that each request 200m CPU. Quota allows 500m total → 3rd rejected:
kubectl apply -f manifests/08-quota-test-pods.yaml 2>&1 | tail -5
# Expected: pod 1 and pod 2 created; pod 3 rejected with 'exceeded quota'.

kubectl get pods -l demo=quota
# Should show 2 Pods.

# Recheck the quota — used totals should match the 2 admitted Pods:
kubectl describe resourcequota namespace-budget

kubectl delete pod -l demo=quota


# =============================================================================
# CLEANUP
# =============================================================================

kubectl delete -f manifests/ --ignore-not-found
kubectl delete namespace lab08
kubectl config set-context --current --namespace=default
