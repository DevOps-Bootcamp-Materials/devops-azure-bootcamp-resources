#!/usr/bin/env bash
# =============================================================================
# Lab 01 — Pods, ReplicaSets and Deployments: command walkthrough
# =============================================================================
# Purpose: step-by-step commands to apply the manifests and observe what
#          Kubernetes is doing internally after each action.
#
# How to use:
#   Run each block manually one at a time. Read the comments before executing.
#   Do NOT pipe this whole file to bash — some commands require you to observe
#   the output of the previous one before proceeding.
#
# Prerequisites:
#   minikube start
#   kubectl config current-context  →  should show 'minikube'
# =============================================================================

# --- 0. SETUP ----------------------------------------------------------------

# Create an isolated namespace so everything from this lab lives together
# and can be cleaned up with a single 'kubectl delete namespace lab01'.
kubectl create namespace lab01

# Make lab01 the default namespace for this shell session so we don't need
# to add '-n lab01' to every command.
kubectl config set-context --current --namespace=lab01

# Verify: the prompt should now show the lab01 namespace in tools like k9s/kubectx.
kubectl config view --minify | grep namespace


# =============================================================================
# PART 1 — Pod
# =============================================================================

# --- 1.1 Apply the Pod manifest -----------------------------------------------

kubectl apply -f manifests/pod.yaml

# WHY 'apply' instead of 'create'?
# 'kubectl create' fails if the object already exists.
# 'kubectl apply' is idempotent: it creates the object on the first run and
# patches it on subsequent runs if the spec has changed.
# This is the GitOps-friendly approach.


# --- 1.2 Watch the Pod reach Running state ------------------------------------

# The -w flag streams live updates. You will see the Pod progress through:
#   Pending → ContainerCreating → Running
# Pending means the scheduler is selecting a node.
# ContainerCreating means the node is pulling the image and creating the container.
kubectl get pod nginx-pod -w
# Press Ctrl+C when you see Running.


# --- 1.3 Find out WHICH node the Pod landed on --------------------------------

# -o wide adds the NODE and NOMINATED NODE columns.
# In a single-node cluster (minikube) this is always the same node,
# but in multi-node clusters this shows scheduler decisions.
kubectl get pod nginx-pod -o wide


# --- 1.4 Inspect the full Pod object ------------------------------------------

# 'describe' is your primary debugging tool. It shows:
#   - Current conditions (PodScheduled, Initialized, ContainersReady, Ready)
#   - Container state (image, restartCount, last state if it crashed)
#   - Events: the timeline of what happened (image pull, container start, probe results)
# Always check Events at the bottom when a Pod is not behaving as expected.
kubectl describe pod nginx-pod


# --- 1.5 Read the container logs ----------------------------------------------

# Logs come from stdout/stderr of the container process (PID 1).
# nginx writes access logs and error logs to stdout/stderr by default.
kubectl logs nginx-pod

# Follow logs in real time (like 'tail -f'):
kubectl logs nginx-pod -f
# Ctrl+C to stop.


# --- 1.6 Run a command inside the running container ---------------------------

# 'exec' opens a process inside the container namespace (network, filesystem, etc.).
# Useful for inspecting config files, testing connectivity, or debugging.
kubectl exec -it nginx-pod -- /bin/bash
# Inside: try 'curl localhost', 'cat /etc/nginx/nginx.conf', 'ls /usr/share/nginx/html'
# Type 'exit' to return to your shell.


# --- 1.7 Delete the Pod and observe it does NOT come back --------------------

kubectl delete pod nginx-pod

# Kubernetes deletes it and that's final. No controller is watching this Pod.
kubectl get pods
# Expected output: 'No resources found in lab01 namespace.'


# =============================================================================
# PART 2 — ReplicaSet
# =============================================================================

# --- 2.1 Apply the ReplicaSet -------------------------------------------------

kubectl apply -f manifests/replicaset.yaml

# The ReplicaSet controller immediately creates 2 Pods (spec.replicas=2).
# Watch them appear:
kubectl get pods -w
# Ctrl+C once both show Running.


# --- 2.2 Inspect the ReplicaSet object ----------------------------------------

# KEY COLUMNS:
#   DESIRED  — what you declared in spec.replicas
#   CURRENT  — how many Pods exist with the right template hash
#   READY    — how many are passing their readinessProbe (or just running if no probe)
kubectl get replicaset nginx-rs

# Full picture including Events (e.g. "Created pod: nginx-rs-xxxxx"):
kubectl describe replicaset nginx-rs


# --- 2.3 See the labels Kubernetes stamped on each Pod -----------------------

# The RS adds a 'pod-template-hash' label to each Pod it creates.
# This hash is derived from the Pod template spec. It changes when the template
# changes — this is how the Deployment knows which ReplicaSet owns which Pods.
kubectl get pods --show-labels


# --- 2.4 Simulate a node/container failure: kill a Pod -----------------------

# Save the name of one Pod
POD=$(kubectl get pods -l app=nginx -o jsonpath='{.items[0].metadata.name}')
echo "Deleting Pod: $POD"

kubectl delete pod "$POD"

# Watch the ReplicaSet immediately create a replacement to restore DESIRED=2.
# You will see the deleted Pod go to Terminating and a new one appear.
kubectl get pods -w
# Ctrl+C once you see 2 Running pods again.


# --- 2.5 Scale the ReplicaSet up and down ------------------------------------

# Imperative scale (useful for quick incident response):
kubectl scale replicaset nginx-rs --replicas=5
kubectl get pods -w
# Ctrl+C when 5 are Running.

# Scale back down. Kubernetes picks which Pods to terminate
# (newest first by default):
kubectl scale replicaset nginx-rs --replicas=2
kubectl get pods -w
# Ctrl+C when 2 are Running.

# Declarative scale (the correct way for production — edit the manifest):
# Open manifests/replicaset.yaml, change replicas: 2 → replicas: 4, then:
# kubectl apply -f manifests/replicaset.yaml


# =============================================================================
# PART 3 — Deployment
# =============================================================================

# --- 3.1 Clean up the standalone ReplicaSet first ----------------------------

# We are about to create a Deployment with the same 'app=nginx' selector.
# If the RS exists, the Deployment might adopt its Pods unexpectedly.
kubectl delete replicaset nginx-rs


# --- 3.2 Apply the Deployment -------------------------------------------------

kubectl apply -f manifests/deployment.yaml

# Kubernetes creates: Deployment → ReplicaSet → 3 Pods
# The ReplicaSet name is '<deployment-name>-<pod-template-hash>'
kubectl get deployment nginx-deployment
kubectl get replicaset
kubectl get pods


# --- 3.3 Watch the rollout status ---------------------------------------------

# 'rollout status' blocks until the Deployment reaches its desired state
# or until you Ctrl+C. It prints progress messages.
kubectl rollout status deployment/nginx-deployment


# --- 3.4 Inspect the Deployment in detail ------------------------------------

# Look for:
#   - StrategyType and RollingUpdateStrategy (maxUnavailable, maxSurge)
#   - Conditions: Available, Progressing
#   - Events: ScalingReplicaSet entries
kubectl describe deployment nginx-deployment


# --- 3.5 Trigger a rolling update: change the image --------------------------

# Imperative image update (convenient for demos):
kubectl set image deployment/nginx-deployment nginx=nginx:1.26

# Watch the rolling update in real time. You will see new Pods (1.26) come up
# while old Pods (1.25) are terminated one by one:
kubectl get pods -w
# Ctrl+C when all 3 new Pods are Running.

# Verify the update completed successfully:
kubectl rollout status deployment/nginx-deployment

# Confirm the new image is in use:
kubectl describe deployment nginx-deployment | grep Image


# --- 3.6 Observe the old ReplicaSet kept for rollback -------------------------

# You will see TWO ReplicaSets:
#   - New one: DESIRED=3, CURRENT=3, READY=3
#   - Old one: DESIRED=0, CURRENT=0, READY=0  ← kept for rollback
kubectl get replicaset


# --- 3.7 Check the revision history ------------------------------------------

# Each rollout creates a new revision entry. You can add --record to annotate
# the change cause (deprecated in newer K8s versions — use annotations instead).
kubectl rollout history deployment/nginx-deployment


# --- 3.8 Roll back to the previous version ------------------------------------

kubectl rollout undo deployment/nginx-deployment

# Watch Kubernetes swap the ReplicaSets back (1.26 scales down, 1.25 scales up):
kubectl get pods -w
# Ctrl+C when done.

kubectl rollout status deployment/nginx-deployment

# Confirm the image reverted to 1.25:
kubectl describe deployment nginx-deployment | grep Image

# Roll back to a specific revision (not just the previous one):
# kubectl rollout undo deployment/nginx-deployment --to-revision=1


# --- 3.9 Live audit: watch all changes in the namespace ----------------------

# This command streams all events as they happen. Run it in a second terminal
# while you apply changes to see the full picture of what Kubernetes is doing.
kubectl get events --sort-by='.lastTimestamp' -w


# =============================================================================
# CLEANUP
# =============================================================================

kubectl delete -f manifests/
kubectl delete namespace lab01
kubectl config set-context --current --namespace=default
