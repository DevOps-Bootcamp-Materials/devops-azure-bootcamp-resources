# Hands-on 04: Volumes (ephemeral storage primitives)

## Objective

Before diving into PersistentVolumes, you need to understand what a **Volume** actually is in Kubernetes: a directory that one or more containers in a Pod can share, backed by some kind of *driver* (an empty disk, a node path, a ConfigMap, a Secret, a cloud disk…).

This lab covers the **ephemeral and projected volume types** — the ones that do *not* outlive the Pod. They are extremely common in production: shipping logs from a sidecar, mounting configuration files, injecting TLS certificates, sharing scratch space between containers.

By the end of this lab you will understand:
- The `spec.volumes[]` + `containers[].volumeMounts[]` primitive that every other storage option builds on
- When to use `emptyDir` (and when `emptyDir.medium: Memory`)
- Why `hostPath` exists, when it is legitimate, and why you should almost never use it for application data
- How `configMap` and `secret` behave when mounted as volumes (vs injected as env vars)
- The `subPath` trick for mounting a single file into an existing directory

---

## Prerequisites

```bash
minikube start

kubectl create namespace lab04
kubectl config set-context --current --namespace=lab04
```

---

## Part 1 — The volume primitive

A Pod can declare volumes at the Pod level (`spec.volumes[]`) and each container mounts the ones it cares about (`spec.containers[].volumeMounts[]`). The volume itself has a **type** — that is what determines where the bytes actually live.

```
spec:
  volumes:                            ← Pod-level declarations (any type)
    - name: shared-scratch
      emptyDir: {}
  containers:
    - name: writer
      volumeMounts:                   ← Container-level mounts (reference by name)
        - name: shared-scratch
          mountPath: /out
    - name: reader
      volumeMounts:
        - name: shared-scratch
          mountPath: /in
```

Two containers in the same Pod can mount the same volume at different paths. That is the foundation of the sidecar pattern.

---

## Part 2 — `emptyDir` and the sidecar pattern

`emptyDir` is the simplest volume type: an empty directory created when the Pod is scheduled, deleted when the Pod is removed. Its real value is **inter-container communication** within a Pod.

### 2.1 The classic logs sidecar

We deploy a Pod with two containers:
- `nginx` writes its access log to `/var/log/nginx/access.log`
- A `log-shipper` container (busybox in this lab; in production this would be Fluent Bit, Vector, or Promtail) tails that same file and prints it to stdout, where it gets picked up by the cluster logging stack

Both containers mount the same `emptyDir` at different paths.

```bash
kubectl apply -f manifests/01-emptydir-sidecar.yaml
kubectl wait --for=condition=Ready pod/web-with-logger --timeout=60s

# Generate some traffic against nginx (port-forward from a second terminal,
# or just curl from inside the Pod):
kubectl exec web-with-logger -c nginx -- sh -c "for i in 1 2 3; do wget -qO- localhost > /dev/null; done"

# Inspect both containers — they see the same file at different paths:
kubectl exec web-with-logger -c nginx       -- ls -la /var/log/nginx/
kubectl exec web-with-logger -c log-shipper -- ls -la /logs/

# The log-shipper is streaming nginx's access log to its stdout:
kubectl logs web-with-logger -c log-shipper --tail=10
```

This is exactly how the EFK/Loki sidecar pattern works. The `emptyDir` is the IPC mechanism.

### 2.2 `emptyDir.medium: Memory` — tmpfs

You can back the emptyDir with RAM instead of disk:

```bash
kubectl apply -f manifests/02-emptydir-memory.yaml
kubectl wait --for=condition=Ready pod/tmpfs-cache --timeout=30s

# Verify it's a tmpfs mount (not a disk-backed directory):
kubectl exec tmpfs-cache -- mount | grep /cache
# → tmpfs on /cache type tmpfs (rw,relatime)
```

Use cases: session cache, in-memory queue, secrets that should never touch disk. **Caveat:** the bytes count against the container's memory limit.

---

## Part 3 — `hostPath`: mount a node directory

`hostPath` mounts a directory from the underlying node into the Pod. It is **node-bound** (the Pod sees whatever is on *that specific* node) and **dangerous** when used carelessly (a Pod with hostPath can read host secrets, container runtime sockets, kernel modules…).

### 3.1 The legitimate use case: node-level log shipping

The reason hostPath still exists is precisely the log-shipping DaemonSet pattern: an agent (Fluent Bit, Filebeat) running on every node needs to read `/var/log/containers/` from the node. There is no other way.

```bash
kubectl apply -f manifests/03-hostpath-debugger.yaml
kubectl wait --for=condition=Ready pod/node-inspector --timeout=30s

# Look at what is happening on the minikube node:
kubectl exec node-inspector -- ls /host-var-log/
kubectl exec node-inspector -- sh -c "tail -n 5 /host-var-log/messages 2>/dev/null || echo '(no messages file)'"
```

### 3.2 Why you should not use hostPath for app data

- **Not portable across nodes.** If the Pod is rescheduled to another node, the directory is empty.
- **Security surface.** Anyone with `create pod` permissions can read arbitrary host paths.
- **Permission collisions.** The container runs as some UID; the host directory may not match.

Use `emptyDir` for scratch, PVCs for persistence. `hostPath` is for *infrastructure* Pods that explicitly need to see the node.

---

## Part 4 — `configMap` as a volume

We covered ConfigMaps as environment variables in lab 03. Mounting one as a *volume* is different: each key becomes a file, and the mount stays in sync if you edit the ConfigMap.

### 4.1 Mount an nginx config

```bash
kubectl apply -f manifests/04-configmap-volume.yaml
kubectl wait --for=condition=Ready pod/nginx-configured --timeout=30s

# Inside the container, the ConfigMap appears as a directory of files:
kubectl exec nginx-configured -- ls -la /etc/nginx/conf.d/
kubectl exec nginx-configured -- cat /etc/nginx/conf.d/default.conf

# Test the custom config is being used (it serves "Hello from ConfigMap"):
kubectl exec nginx-configured -- wget -qO- localhost
```

### 4.2 Live reload (the surprising part)

ConfigMaps mounted as volumes are **updated in-place** by the kubelet when the ConfigMap changes. There is a propagation delay (~1 minute by default).

```bash
# Edit the ConfigMap to change the served message:
kubectl edit configmap nginx-config
# Change "Hello from ConfigMap" to "Hello from updated ConfigMap"

# Wait ~60 seconds for the kubelet to refresh the mounted volume:
sleep 65
kubectl exec nginx-configured -- cat /etc/nginx/conf.d/default.conf | head -20

# Important: the FILE changed, but nginx still serves the old content
# because nginx only reads its config at startup. To make nginx pick up the
# new config we have to reload it:
kubectl exec nginx-configured -- nginx -s reload
kubectl exec nginx-configured -- wget -qO- localhost
```

**The lesson:** mounted ConfigMaps refresh automatically, but the application has to *do something* with the change (SIGHUP, re-read, restart). Sidecars like `Reloader` automate this.

---

## Part 5 — `secret` as a volume

Secrets behave identically to ConfigMaps when mounted as volumes, with three differences:
- The data is base64-decoded at mount time (so files contain the real value)
- The mount uses tmpfs (the bytes never hit the node's disk)
- You can set restrictive `defaultMode` like `0400`

### 5.1 Mount a TLS certificate

```bash
kubectl apply -f manifests/05-secret-volume.yaml
kubectl wait --for=condition=Ready pod/tls-consumer --timeout=30s

# The cert and key appear as files with restrictive permissions:
kubectl exec tls-consumer -- ls -la /etc/tls/
# Expected: -r-------- (0400) — only the container's user can read

# Verify the cert content:
kubectl exec tls-consumer -- cat /etc/tls/tls.crt | head -3
```

### 5.2 Why a volume and not an env var?

| Concern | Env var | Volume |
|---------|---------|--------|
| Visible in `kubectl describe pod` | Yes (name only, not value) | Reference only |
| Visible in process listings of the container | Yes (`/proc/PID/environ`) | No |
| Visible in `kubectl exec ... env` | Yes (value, to anyone who can exec) | No |
| Updates automatically when Secret changes | No (Pod restart required) | Yes |
| Multi-line values (certs, keys) | Awkward | Native |

For credentials → volumes. For toggles and short strings that the app expects from `os.getenv` → env vars.

---

## Part 6 — `subPath`: mount a single file into a populated directory

If you mount a ConfigMap volume at `/etc/nginx/`, you **wipe out** everything that was in `/etc/nginx/` in the original image (mime.types, fastcgi_params, etc.). `subPath` lets you mount **just one file** without overlaying the whole directory.

```bash
kubectl apply -f manifests/06-subpath.yaml
kubectl wait --for=condition=Ready pod/subpath-demo --timeout=30s

# The original /etc/nginx/ contents are still there:
kubectl exec subpath-demo -- ls /etc/nginx/
# Expected: nginx.conf, mime.types, fastcgi_params, ... (all from the image)
#           plus our custom nginx.conf overlaid only on that one file

# And our custom config is being used:
kubectl exec subpath-demo -- cat /etc/nginx/nginx.conf | head -5
```

**Caveat:** files mounted via `subPath` do **not** receive automatic ConfigMap updates. If you need live reload, mount the whole volume at a sibling path and use `include` directives or symlinks.

---

## Part 7 — Cleanup

```bash
kubectl delete -f manifests/
kubectl delete namespace lab04
kubectl config set-context --current --namespace=default
```

Note that *none* of these volumes need explicit cleanup at the storage layer — they all live and die with the Pod (or, for ConfigMap/Secret, with their owning resource). That is precisely the difference with PersistentVolumes, which you will see in lab 05.

---

## Discussion questions

1. You have an app that needs both a small read-only TLS cert and a 4 GB local cache that should not survive Pod restarts. Which volume types do you use for each, and why?
2. A teammate proposes using `hostPath: /var/lib/myapp` to "make data persistent without the PVC machinery". Argue against it with at least two concrete failure scenarios.
3. Your ConfigMap mounted as a volume gets updated, the file on disk refreshes, but the app does not pick up the change. List two ways to fix this *without* deleting the Pod.
4. Why can `emptyDir.medium: Memory` cause your Pod to be OOM-killed even if you write only 100 MB to it? (Hint: container memory limits.)

---

## Key concepts

| Volume type | Lives as long as… | Common use |
|-------------|-------------------|------------|
| `emptyDir` | the Pod | scratch, IPC between containers (sidecar pattern) |
| `emptyDir.medium: Memory` | the Pod | tmpfs cache, secrets that must not hit disk |
| `hostPath` | the node directory (forever) | DaemonSet agents reading node-level data |
| `configMap` (volume) | the ConfigMap | application configuration files (with optional live reload) |
| `secret` (volume) | the Secret | TLS certs, API keys, multi-line credentials |
| `projected` (not covered) | combination of the above | unified mount for token + config + secret |

**Rule of thumb:**
- Two containers need to exchange data inside one Pod → `emptyDir`
- An app needs its config file at a known path → `configMap` volume (with `subPath` if mounting next to other files)
- An app needs a TLS cert or API key as a file → `secret` volume
- You need data to outlive the Pod → that is not in this lab. See **persistent-volumes**.
