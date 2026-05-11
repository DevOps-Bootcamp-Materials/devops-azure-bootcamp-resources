#!/usr/bin/env bash
# =============================================================================
# Lab 04 — Volumes (ephemeral storage primitives): command walkthrough
# =============================================================================
# Purpose: demonstrate the four ephemeral/projected volume types you will use
#          in 90% of real Pods before ever touching a PersistentVolume:
#          emptyDir, hostPath, configMap-as-volume, secret-as-volume, subPath.
#
# How to use:
#   Read the explanation, then run each block. Watch the output between blocks.
#
# Prerequisites:
#   minikube start
# =============================================================================

# --- 0. SETUP ----------------------------------------------------------------

kubectl create namespace lab04
kubectl config set-context --current --namespace=lab04


# =============================================================================
# PART 2 — emptyDir + sidecar pattern
# =============================================================================
# Two containers, one Pod, one shared emptyDir. nginx writes its access log,
# a busybox sidecar tails the log and prints to stdout (where a cluster log
# collector would pick it up in production).

kubectl apply -f manifests/01-emptydir-sidecar.yaml
kubectl wait --for=condition=Ready pod/web-with-logger --timeout=60s

# Generate some HTTP traffic against nginx (from inside the Pod, so we do not
# need a Service yet):
kubectl exec web-with-logger -c nginx -- sh -c "for i in 1 2 3 4 5; do wget -qO- localhost >/dev/null; done"

# Both containers see the SAME bytes, mounted at different paths:
echo '--- nginx sees /var/log/nginx/ ---'
kubectl exec web-with-logger -c nginx       -- ls -la /var/log/nginx/

echo '--- log-shipper sees the same content at /logs/ ---'
kubectl exec web-with-logger -c log-shipper -- ls -la /logs/

# The sidecar is streaming nginx's access log to its stdout — visible via kubectl logs:
kubectl logs web-with-logger -c log-shipper --tail=10

kubectl delete -f manifests/01-emptydir-sidecar.yaml


# =============================================================================
# PART 2.2 — emptyDir.medium: Memory (tmpfs)
# =============================================================================

kubectl apply -f manifests/02-emptydir-memory.yaml
kubectl wait --for=condition=Ready pod/tmpfs-cache --timeout=30s

# Confirm /cache is tmpfs, not disk:
kubectl exec tmpfs-cache -- mount | grep /cache
# Expected: tmpfs on /cache type tmpfs (rw,relatime,size=65536k)

# Optional experiment: try to write more than the sizeLimit and watch it fail:
# kubectl exec tmpfs-cache -- sh -c "dd if=/dev/zero of=/cache/big bs=1M count=80"
# → dd: error writing '/cache/big': No space left on device

kubectl delete -f manifests/02-emptydir-memory.yaml


# =============================================================================
# PART 3 — hostPath: mount a node directory
# =============================================================================

kubectl apply -f manifests/03-hostpath-debugger.yaml
kubectl wait --for=condition=Ready pod/node-inspector --timeout=30s

# Inspect what's actually on the minikube node:
kubectl exec node-inspector -- ls /host-var-log/

# Discussion point: if you delete this Pod and recreate it on a different node
# (in a real multi-node cluster), the contents of /host-var-log would be
# completely different — they belong to whichever node Kubernetes picked.

kubectl delete -f manifests/03-hostpath-debugger.yaml


# =============================================================================
# PART 4 — configMap as a volume (+ live reload demo)
# =============================================================================

kubectl apply -f manifests/04-configmap-volume.yaml
kubectl wait --for=condition=Ready pod/nginx-configured --timeout=30s

# Each ConfigMap KEY is a FILE in the mounted directory:
kubectl exec nginx-configured -- ls -la /etc/nginx/conf.d/
kubectl exec nginx-configured -- cat /etc/nginx/conf.d/default.conf

# Confirm the custom config is in effect:
kubectl exec nginx-configured -- wget -qO- localhost
# Expected: "Hello from ConfigMap"


# --- 4.2 LIVE-RELOAD DEMO ----------------------------------------------------
# Edit the ConfigMap (or patch it for scripted use), wait for the kubelet to
# refresh the mounted volume (~60s), and verify that the FILE changed even
# though the Pod was NOT restarted.

kubectl patch configmap nginx-config --type=merge -p '
data:
  default.conf: |
    server {
      listen 80;
      location / {
        return 200 "Hello from UPDATED ConfigMap\n";
        add_header Content-Type text/plain;
      }
    }
'

echo 'Waiting ~70s for the kubelet to refresh the mounted ConfigMap volume...'
sleep 70

# The FILE on disk changed without restarting the Pod:
kubectl exec nginx-configured -- grep return /etc/nginx/conf.d/default.conf

# But the running nginx process still serves the OLD content because nginx
# only reads its config at startup:
kubectl exec nginx-configured -- wget -qO- localhost
# Expected: still "Hello from ConfigMap" (the old one)

# Reload nginx to pick up the new config:
kubectl exec nginx-configured -- nginx -s reload
kubectl exec nginx-configured -- wget -qO- localhost
# Expected now: "Hello from UPDATED ConfigMap"

kubectl delete -f manifests/04-configmap-volume.yaml


# =============================================================================
# PART 5 — secret as a volume
# =============================================================================

kubectl apply -f manifests/05-secret-volume.yaml
kubectl wait --for=condition=Ready pod/tls-consumer --timeout=30s

# The secret values are DECODED automatically at mount time:
kubectl exec tls-consumer -- ls -la /etc/tls/
# Expected file mode: -r-------- (0400) — owner-only read

kubectl exec tls-consumer -- cat /etc/tls/tls.crt | head -3
# Expected: starts with "-----BEGIN CERTIFICATE-----"

# Check the underlying mount: it's tmpfs — the secret never touched the node's disk:
kubectl exec tls-consumer -- mount | grep /etc/tls
# Expected: tmpfs on /etc/tls type tmpfs (ro,...)

kubectl delete -f manifests/05-secret-volume.yaml


# =============================================================================
# PART 6 — subPath: mount a single file into a populated directory
# =============================================================================

kubectl apply -f manifests/06-subpath.yaml
kubectl wait --for=condition=Ready pod/subpath-demo --timeout=30s

# The ORIGINAL contents of /etc/nginx/ from the image are still there:
kubectl exec subpath-demo -- ls /etc/nginx/
# Expected: nginx.conf (our override), mime.types, fastcgi_params, ...

# Our overridden nginx.conf is what nginx actually loads:
kubectl exec subpath-demo -- head -5 /etc/nginx/nginx.conf

# Hit nginx to confirm:
kubectl exec subpath-demo -- wget -qO- localhost
# Expected: "subPath demo"

kubectl delete -f manifests/06-subpath.yaml


# =============================================================================
# CLEANUP
# =============================================================================

kubectl delete -f manifests/ --ignore-not-found
kubectl delete namespace lab04
kubectl config set-context --current --namespace=default
