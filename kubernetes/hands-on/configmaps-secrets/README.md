# Hands-on 03: ConfigMaps and Secrets

## Objective

Demonstrate that hardcoding configuration or credentials into Docker images breaks portability across environments. Kubernetes solves this with **ConfigMaps** (non-sensitive configuration) and **Secrets** (sensitive data). Both are injected into Pods either as environment variables or as mounted files.

By the end of this lab you will understand:
- Why separating code from configuration is an architectural principle (12-factor app, factor III)
- How to consume configuration from Pods without rebuilding the image
- The differences between ConfigMaps and Secrets and when to use each
- The two injection methods: environment variables vs. mounted volumes

---

## Prerequisites

```bash
minikube start

kubectl create namespace lab03
kubectl config set-context --current --namespace=lab03
```

---

## Part 1 — ConfigMap: non-sensitive configuration

A ConfigMap stores key-value pairs or complete configuration files. Its content is stored as plain text in etcd.

### 1.1 Create a ConfigMap imperatively

```bash
# From literals
kubectl create configmap app-config \
  --from-literal=APP_ENV=production \
  --from-literal=LOG_LEVEL=info \
  --from-literal=MAX_CONNECTIONS=100

# Inspect
kubectl get configmap app-config -o yaml
```

### 1.2 Create the ConfigMap with a manifest

The equivalent manifest is in `manifests/configmap.yaml`:

```bash
kubectl apply -f manifests/configmap.yaml
kubectl describe configmap app-config-manifest
```

### 1.3 Create a ConfigMap from a file

```bash
# Create a local configuration file
cat > app.properties << EOF
database.host=postgres-service
database.port=5432
feature.dark-mode=true
EOF

kubectl create configmap file-config --from-file=app.properties
kubectl get configmap file-config -o yaml
```

---

## Part 2 — Secret: sensitive data

A Secret is conceptually the same as a ConfigMap, but its value is stored **base64-encoded** in etcd. In properly configured clusters, etcd is encrypted at rest and access to Secrets is restricted via RBAC.

> **Important note:** base64 is NOT encryption, it is encoding. A Secret without encryption at rest and RBAC is essentially plain text. In production, use solutions like Sealed Secrets, External Secrets Operator, or Vault.

### 2.1 Create a Secret imperatively

```bash
kubectl create secret generic db-credentials \
  --from-literal=DB_USER=admin \
  --from-literal=DB_PASSWORD=supersecret123

# The value appears in base64
kubectl get secret db-credentials -o yaml

# Decode (for verification purposes in the lab only)
kubectl get secret db-credentials -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
```

### 2.2 Create the Secret with a manifest

```bash
kubectl apply -f manifests/secret.yaml
kubectl describe secret app-secret
```

---

## Part 3 — Injecting configuration into a Pod

There are two consumption patterns: **environment variables** and **volumes mounted as files**. Each has its own trade-offs.

### 3.1 Apply the example Pod

```bash
kubectl apply -f manifests/pod-with-config.yaml
kubectl get pod config-demo
```

### 3.2 Verify environment variables

```bash
kubectl exec -it config-demo -- env | grep -E 'APP_|LOG_|DB_'
```

Expected output:
```
APP_ENV=production
LOG_LEVEL=info
DB_USER=admin
DB_PASSWORD=supersecret123
```

### 3.3 Verify the file mounted from the ConfigMap

```bash
kubectl exec -it config-demo -- cat /etc/config/app.properties
```

### 3.4 Update the ConfigMap and observe propagation

```bash
# Edit the ConfigMap
kubectl edit configmap app-config-manifest
# Change LOG_LEVEL from "info" to "debug" and save

# Files mounted as volumes are updated automatically (≈60s)
# Environment variables are NOT updated: the Pod must be restarted

kubectl exec -it config-demo -- cat /etc/config/log-level
# After ~1 minute it will show "debug"
```

**Key conclusion:** mount frequently-changing configuration as a volume rather than as an environment variable to avoid Pod restarts.

---

## Part 4 — Cleanup

```bash
kubectl delete -f manifests/
kubectl delete configmap file-config app-config
kubectl delete secret db-credentials
kubectl delete namespace lab03
kubectl config set-context --current --namespace=default
```

---

## Discussion questions

1. Why should you never store Secrets in a Git repository, not even in base64?
2. What tool would you use in production to manage credentials securely, integrated with Kubernetes?
3. What is the practical difference between `envFrom` and `env[].valueFrom.configMapKeyRef`?

---

## Key concepts

| Object | Data | Typical use |
|--------|------|-------------|
| ConfigMap | Plain text | App parameters, configuration files |
| Secret | Base64 (optionally encrypted at rest) | Passwords, tokens, TLS certificates |

| Injection method | Updates without Pod restart |
|-----------------|----------------------------|
| Environment variable (`envFrom`, `env[].valueFrom`) | ❌ No |
| Mounted volume (`volumes[].configMap`, `volumes[].secret`) | ✅ Yes (≈60s) |
