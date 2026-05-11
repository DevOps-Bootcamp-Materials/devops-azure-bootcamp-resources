#!/usr/bin/env bash
# =============================================================================
# Lab 03 — ConfigMaps and Secrets: command walkthrough
# =============================================================================
# Purpose: demonstrate the three injection patterns (envFrom, valueFrom, volume
#          mount), show the live-update behaviour of volume-mounted ConfigMaps,
#          and illustrate why Secrets need additional hardening in production.
#
# How to use:
#   Run each block manually. Read the explanation before executing each command.
# =============================================================================

# --- 0. SETUP ----------------------------------------------------------------

kubectl create namespace lab03
kubectl config set-context --current --namespace=lab03


# =============================================================================
# PART 1 — ConfigMap creation and inspection
# =============================================================================

# --- 1.1 Create imperatively (useful to understand the data model) -------------

kubectl create configmap app-config \
  --from-literal=APP_ENV=production \
  --from-literal=LOG_LEVEL=info \
  --from-literal=MAX_CONNECTIONS=100

# View the raw YAML stored in Kubernetes.
# Notice: no base64, no encoding — plain text. This is why ConfigMaps
# must not hold sensitive data.
kubectl get configmap app-config -o yaml


# --- 1.2 Create from the manifest ---------------------------------------------

kubectl apply -f manifests/configmap.yaml

# Describe shows the data keys and their values (truncated for long values):
kubectl describe configmap app-config-manifest

# View only the keys (useful for large ConfigMaps):
kubectl get configmap app-config-manifest \
  -o jsonpath='{.data}' | python3 -m json.tool


# --- 1.3 Create from a file ---------------------------------------------------

cat > /tmp/app.properties << EOF
database.host=postgres-service
database.port=5432
feature.dark-mode=true
EOF

kubectl create configmap file-config --from-file=/tmp/app.properties

# Notice: the entire file content is stored under the filename as the key:
kubectl get configmap file-config -o yaml


# =============================================================================
# PART 2 — Secret creation and inspection
# =============================================================================

# --- 2.1 Create imperatively --------------------------------------------------

kubectl create secret generic db-credentials \
  --from-literal=DB_USER=admin \
  --from-literal=DB_PASSWORD=supersecret123

# Observe: the values are base64-encoded in the YAML output.
# This is NOT encryption — it is just encoding for safe transport.
kubectl get secret db-credentials -o yaml


# --- 2.2 Decode a Secret value ------------------------------------------------

# Any user with 'get secret' RBAC permission can do this:
kubectl get secret db-credentials \
  -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
echo   # add newline after the decoded value

# This is why RBAC on Secrets matters and why you should use
# Sealed Secrets / External Secrets / Vault in production.


# --- 2.3 Create from the manifest ---------------------------------------------

kubectl apply -f manifests/secret.yaml

# 'describe' intentionally hides values — shows only byte size:
kubectl describe secret app-secret

# Full output includes base64 values:
kubectl get secret app-secret -o yaml


# =============================================================================
# PART 3 — Inject configuration into a Pod
# =============================================================================

# --- 3.1 Apply the demo Pod ---------------------------------------------------

kubectl apply -f manifests/pod-with-config.yaml

# Watch the Pod start. 'restartPolicy: Never' means it won't restart on failure.
kubectl get pod config-demo -w
# Ctrl+C when Running.


# --- 3.2 Pattern 1 — Verify envFrom (bulk env var load) ----------------------

# All keys from app-config-manifest are available as environment variables.
# Note that 'app.properties' and 'log-level' are NOT valid env var names,
# so envFrom silently skips them.
kubectl exec config-demo -- env | sort | grep -E 'APP_ENV|LOG_LEVEL|MAX_CONN'


# --- 3.3 Pattern 2 — Verify individual valueFrom (with renaming) -------------

# DB_USER and DB_PASSWORD come from the Secret.
# RUNTIME_ENV is the ConfigMap's APP_ENV key under a different name.
kubectl exec config-demo -- env | grep -E 'DB_USER|DB_PASSWORD|RUNTIME_ENV'


# --- 3.4 Pattern 3 — Verify volume-mounted files -----------------------------

# Files appear at /etc/config/ with the key name as filename:
kubectl exec config-demo -- ls -la /etc/config/

# Read the mounted app.properties file:
kubectl exec config-demo -- cat /etc/config/app.properties

# Read the log-level file:
kubectl exec config-demo -- cat /etc/config/log-level


# =============================================================================
# PART 4 — Live update: volume vs environment variable
# =============================================================================

# This is a KEY difference between the two injection methods.

# --- 4.1 Update the ConfigMap -------------------------------------------------

# Change LOG_LEVEL from 'info' to 'debug' in the ConfigMap:
kubectl patch configmap app-config-manifest \
  --type merge \
  -p '{"data":{"LOG_LEVEL":"debug","log-level":"debug\n"}}'

# Confirm the ConfigMap was updated:
kubectl get configmap app-config-manifest -o jsonpath='{.data.LOG_LEVEL}'
echo


# --- 4.2 Check the VOLUME-MOUNTED file (updates within ~60 seconds) ----------

# The kubelet syncs ConfigMap-backed volumes on its sync interval (default 1m).
# Poll every 10 seconds until the file reflects the new value:
echo "Waiting for volume to update..."
for i in $(seq 1 12); do
  VALUE=$(kubectl exec config-demo -- cat /etc/config/log-level 2>/dev/null)
  echo "[$i] /etc/config/log-level = $VALUE"
  [ "$VALUE" = "debug" ] && echo "✓ Volume updated!" && break
  sleep 10
done


# --- 4.3 Check the ENVIRONMENT VARIABLE (does NOT update without restart) ----

# The env var still shows the old value:
kubectl exec config-demo -- env | grep LOG_LEVEL
# Expected: LOG_LEVEL=info  ← still the old value

echo ""
echo "→ To pick up the new LOG_LEVEL env var, the Pod must be restarted."
echo "  In a Deployment this is done via: kubectl rollout restart deployment/<name>"


# =============================================================================
# BONUS — Inspect Secrets that Kubernetes creates automatically
# =============================================================================

# Every ServiceAccount gets a Secret with a JWT token for API authentication.
# This is how Pods authenticate to the Kubernetes API server by default.
kubectl get secrets
kubectl describe secret $(kubectl get secrets -o name | head -1)


# =============================================================================
# CLEANUP
# =============================================================================

kubectl delete -f manifests/
kubectl delete configmap file-config app-config 2>/dev/null || true
kubectl delete secret db-credentials 2>/dev/null || true
kubectl delete namespace lab03
kubectl config set-context --current --namespace=default
