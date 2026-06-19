# minikube — end to end: cluster, addons, app, ingress, tunnel

This is the deep-dive companion to the bootcamp hands-on `week-16/local-kubernetes/hands-on/01_minikube_end_to_end.md`. The bootcamp file is the walkthrough you follow in class or on first read; this README covers the same flow but explains everything underneath — how the docker driver actually works, what the tunnel really does, every way to get an image into the cluster, the multi-node and mount features we skip in class, and every failure mode we hit while testing on Windows.

## What this folder contains

- `README.md` — this file: the full walkthrough with every detail and tangent
- `commands.sh` — the complete command sequence as a quick reference
- `manifests/namespace.yaml` — the `hello` namespace all demo objects live in
- `manifests/configmap-html.yaml` — the HTML page nginx serves (mounted as a volume)
- `manifests/deployment.yaml` — 2-replica nginx Deployment with requests/limits and a readiness probe
- `manifests/service.yaml` — ClusterIP Service in front of the Deployment
- `manifests/service-lb.yaml` — LoadBalancer Service used for the `minikube tunnel` demo
- `manifests/ingress.yaml` — Ingress routing `hello.local` to the Service
- `manifests/deployment-local-image.yaml` — Deployment that references the locally built image (the ErrImagePull demo)
- `app/Dockerfile`, `app/index.html` — the tiny image you build on the host and load into the cluster

## Prerequisites

- Docker Desktop installed and running
- `minikube` >= 1.35, `kubectl` >= 1.30
- The local Kubernetes landscape lesson and the minikube deep-dive lesson

## How to use this folder

```bash
git clone https://github.com/DevOps-Bootcamp-Materials/devops-azure-bootcamp-resources.git
cd devops-azure-bootcamp-resources/kubernetes/hands-on/minikube-local
```

This README walks through the same steps as the bootcamp hands-on, but expanded. Read it after the hands-on for full depth, or open it directly if you already know the basics.

---

## Part 1 — Cluster creation, and what actually happens

```bash
minikube start --driver=docker
```

**What `minikube start` really does, step by step:**

1. **Driver selection.** minikube checks for an explicit `--driver`, then your persisted config (`minikube config view`), then auto-detects. The docker driver wins on most machines because it needs no hypervisor.
2. **Base image pull.** The node is created from the `kicbase` image ("Kubernetes In Container"). It is a heavyweight image (~1 GB) containing systemd, a container runtime, kubelet, and all the tooling a node needs. This is the slow part of the first start, and the reason later starts are fast — the image is cached.
3. **Node container creation.** One Docker container named `minikube`, with its own network namespace, attached to a dedicated Docker network (`minikube`). It gets an IP like `192.168.49.2` on that network — this is what `minikube ip` returns.
4. **Kubernetes bootstrap.** Inside the container, `kubeadm` initializes the control plane: etcd, kube-apiserver, kube-scheduler, kube-controller-manager, then the kubelet joins the node to itself.
5. **kubeconfig merge.** minikube writes the cluster, user (client certificates) and context into your `~/.kube/config` and activates the `minikube` context. This is why `kubectl` "just works" afterwards.
6. **Default addons.** `storage-provisioner` (a hostPath dynamic provisioner) and `default-storageclass` (the `standard` StorageClass) are applied, which is why PVCs bind out of the box.

**Misconception: "minikube is a simulator."** No — it is upstream Kubernetes, bit-for-bit, packaged for one machine. The API server answering your `kubectl` is the same binary AKS runs. What differs is the *substrate* (one container instead of a fleet of VMs) and the *integrations* (no cloud APIs), never the Kubernetes behavior itself.

**Pinning versions.** For reproducible classes and CI, pin the Kubernetes version: `minikube start --kubernetes-version=v1.33.0`. Without it you get the default of your minikube release, which changes as you upgrade minikube.

**Sizing.** Defaults are 2 CPUs / 2-4 GB. For heavier stacks (kube-prometheus, several apps), create with `minikube start --cpus=4 --memory=6g`. These are per-profile creation-time settings — changing them requires `minikube delete` + recreate.

---

## Part 2 — Under the hood: the node as a container

```bash
docker ps --filter name=minikube
minikube ssh
```

Inside the node, run `docker ps` (the node has its *own* Docker daemon when created with the docker runtime) and you will see the control-plane components themselves running as containers: `kube-apiserver`, `etcd`, `kube-scheduler`, `kube-controller-manager`, `coredns`, plus a pause container per Pod.

**The two-daemons picture**, worth drawing on a whiteboard once:

```
Your host
├── Docker daemon (host)          <- `docker build` puts images HERE
│   └── container: minikube      <- the "node"
│       └── Docker daemon (node)  <- the kubelet pulls/runs images from HERE
│           ├── kube-apiserver, etcd, scheduler, ...
│           └── your application Pods
```

Everything about the image-loading trap (Part 7) follows from this picture: two daemons, two image stores, no automatic sync.

**Edge case — `minikube ssh` vs `docker exec`.** `minikube ssh` is sugar for an SSH session into the node container; `docker exec -it minikube bash` lands you in the same place. Either is useful to inspect kubelet logs (`journalctl -u kubelet`) when a Pod refuses to start for node-level reasons.

---

## Part 3 — Addons in depth

```bash
minikube addons list
minikube addons enable ingress
minikube addons enable metrics-server
```

An addon is a set of pre-templated Kubernetes manifests that minikube applies and tracks. `minikube addons list` shows ~30 of them. The ones that matter most in practice:

| Addon | What it installs | When you need it |
|---|---|---|
| `ingress` | ingress-nginx controller in `ingress-nginx` namespace | Any time you create `Ingress` objects |
| `metrics-server` | metrics-server Deployment in `kube-system` | `kubectl top`, HPA |
| `dashboard` | Kubernetes Dashboard + `minikube dashboard` command | Visual exploration |
| `storage-provisioner` (default) | hostPath dynamic provisioner | PVC binding |
| `registry` | An in-cluster image registry | Alternative to `image load` for registry-like flows |
| `csi-hostpath-driver` | A full CSI driver with snapshot support | Practicing CSI/snapshots locally |

**How the ingress addon differs from a manual install:** it is the same upstream ingress-nginx, but minikube patches it to run with `hostPort` networking on the node, so the controller listens directly on the node's :80/:443. That is what makes the tunnel/ingress flow in Part 6 work. On a cloud cluster the controller would instead sit behind a `LoadBalancer` Service.

**Misconception: "addons are minikube-only magic."** They install ordinary resources you can inspect: `kubectl get all -n ingress-nginx`. Disabling an addon deletes those resources. Nothing stops you from ignoring addons entirely and installing ingress-nginx with Helm exactly as you would in production — addons are a convenience, not a different technology.

---

## Part 4 — The sample app

```bash
kubectl apply -f manifests/namespace.yaml
kubectl apply -f manifests/configmap-html.yaml
kubectl apply -f manifests/deployment.yaml
kubectl apply -f manifests/service.yaml
kubectl get pods -n hello
```

Design notes, since every line of these manifests is a deliberate choice:

- **ConfigMap-as-volume for the HTML.** It lets us change the page content without rebuilding any image (`kubectl edit configmap` + pod restart), and it reviews a pattern students know. The whole directory `/usr/share/nginx/html` is replaced by the volume mount.
- **Requests and limits** (`50m/32Mi` requests, `200m/128Mi` limits) make `kubectl top` output meaningful in Part 8 and keep the scheduler honest. Omitting requests is the most common cause of "everything scheduled onto one node" complaints in multi-node setups.
- **The readiness probe** makes the Service's endpoint list trustworthy: a Pod that cannot serve `/` is removed from rotation. With nginx the probe passes almost immediately, but the pattern is what matters.

**Edge case — ConfigMap updates do not restart Pods.** If you edit `hello-html`, running Pods keep the old mounted content for up to a minute (the kubelet sync period) and nginx will serve the refreshed file only after the projected volume updates; for an immediate flip, `kubectl rollout restart deployment/hello-web -n hello`.

---

## Part 5 — Access path 1: port-forward

```bash
kubectl port-forward -n hello svc/hello-svc 8080:80
curl http://localhost:8080
```

**How it works:** `port-forward` opens a tunnel from your localhost through the **API server** into a Pod (when you target a Service, kubectl resolves it to one ready Pod first — it does not load-balance). Traffic flows over the same authenticated channel as `kubectl exec`. That is why it works on any cluster, anywhere, with zero networking setup: if `kubectl get pods` works, `port-forward` works.

**Why it is not a serving mechanism:** single client process, single target Pod, dies with the terminal, no load balancing across replicas. It is the right tool for debugging and the wrong tool for everything else.

---

## Part 6 — Access path 2 and 3: LoadBalancer + tunnel, and Ingress

### The `<pending>` moment

```bash
kubectl apply -f manifests/service-lb.yaml
kubectl get svc -n hello hello-lb     # EXTERNAL-IP: <pending>
```

In the cloud, a `LoadBalancer` Service is fulfilled by the **cloud-controller-manager**, which calls the provider's API (Azure: creates a rule on an Azure Load Balancer + a public IP). A local cluster has no cloud-controller-manager with a working cloud behind it, so the request sits unfulfilled forever. Kubernetes is not broken — it is *waiting*.

### What `minikube tunnel` actually does

```bash
minikube tunnel    # separate terminal, leave running
```

The tunnel process does two things:

1. **Acts as the missing load-balancer provider:** it watches Services of type `LoadBalancer` and patches their status with an ingress IP, which is why `EXTERNAL-IP` flips from `<pending>` to a real value while the tunnel runs — and flips back when you stop it.
2. **Creates the network path:** on Linux it adds a route from your host to the cluster's service network. On Windows/macOS with the docker driver, where no direct route into the container network exists, it instead binds the exposed ports on `127.0.0.1` and proxies into the cluster — which is why you see `EXTERNAL-IP: 127.0.0.1` on those platforms and why it may ask for elevation (binding privileged ports 80/443).

**Windows-specific reality (verified):** EXTERNAL-IP becomes `127.0.0.1`, the LoadBalancer Service is reachable at `http://127.0.0.1:<port>`, and the ingress controller's 80/443 also ride the same tunnel. On Linux you would instead see a `10.x` ClusterIP-range IP and could curl it directly.

### Ingress

```bash
kubectl apply -f manifests/ingress.yaml
curl http://127.0.0.1 -H "Host: hello.local"
```

The flow of that request: host `127.0.0.1:80` → tunnel → node :80 (ingress-nginx via hostPort) → controller matches `Host: hello.local` against its rules → proxies to `hello-svc` → one of the two nginx Pods.

**Hosts-file option** for a browser-friendly URL: add this line to `C:\Windows\System32\drivers\etc\hosts` (as Administrator) / `/etc/hosts`:

```
127.0.0.1 hello.local
```

Then `http://hello.local` works in the browser while the tunnel runs. Remember to remove it later — stale hosts entries are a classic source of "why does this domain resolve weirdly" confusion months later.

**Misconception: "the ADDRESS column on the Ingress means it is reachable there."** That column shows the node's internal IP (e.g. `192.168.49.2`). On Linux you can curl it directly; on Windows/macOS with the docker driver you cannot — there is no route from the host into the Docker network, which is exactly the problem the tunnel solves.

---

## Part 7 — Every way to get a local image into minikube

The bootcamp hands-on demonstrates the trap and the `image load` fix. Here is the complete map:

### 1. `minikube image load` (what we used)

```bash
docker build -t hello-local:1.0 ./app
minikube image load hello-local:1.0
```

Under the hood: the host image is saved to a tarball, streamed into the node, and imported into the node's runtime. Cost: a full copy per load — fine for occasional loads, slow in a tight loop with big images. `minikube image ls` shows what is inside the node.

### 2. `minikube image build`

```bash
minikube image build -t hello-local:1.0 ./app
```

Sends the build context into the node and builds **there** — no host image, no copy step. Useful when you do not need the image on the host at all.

### 3. The `docker-env` trick (docker driver/runtime only)

```bash
# bash / zsh
eval $(minikube docker-env)
docker build -t hello-local:1.0 ./app    # lands DIRECTLY in the node's daemon
eval $(minikube docker-env -u)

# PowerShell
& minikube -p minikube docker-env --shell powershell | Invoke-Expression
docker build -t hello-local:1.0 ./app
& minikube docker-env --shell powershell -u | Invoke-Expression
```

This points your shell's `docker` CLI at the **node's** daemon, so the build output never exists on the host at all. Fastest inner loop; the catch is every `docker` command in that shell now talks to the node (people forget and wonder where their host images went). Undo with `-u`.

### 4. The `registry` addon / a real registry

`minikube addons enable registry` runs a registry inside the cluster; or push to GHCR and let the cluster pull like production does. The GHCR hands-on covers the production path in full.

### The two rules that make loaded images work

1. **Never `:latest`.** With the `:latest` tag, Kubernetes defaults `imagePullPolicy` to `Always`, so the kubelet contacts the registry even though the image sits right there in the node. Tag explicitly (`1.0`, a git SHA).
2. **`imagePullPolicy: IfNotPresent`.** States the intent explicitly: use the local store first. With a non-`latest` tag this is also the default, but writing it out makes manifests self-documenting.

**Why the broken Pod self-heals after `image load` (verified):** `ErrImagePull` puts the Pod in a retry loop with exponential backoff (`ImagePullBackOff` is the waiting state between retries). On the next retry after the load, the kubelet checks its local store (policy `IfNotPresent`), finds the image, and starts the container — no `kubectl` intervention needed. Worst case you wait out the current backoff interval (up to ~5 minutes if it failed many times; delete the Pod to skip the wait).

---

## Part 8 — Metrics

```bash
kubectl top nodes
kubectl top pods -n hello
```

metrics-server scrapes resource usage from each kubelet every ~15s and serves it through the Metrics API (`metrics.k8s.io`). `kubectl top` is a client of that API — and so is the HorizontalPodAutoscaler. No metrics-server, no HPA. The first scrape takes a minute or two after enabling the addon; `error: Metrics API not available` simply means "wait" (or the addon is not enabled).

Numbers worth pointing at in class (verified): each idle nginx Pod sits around 1m CPU / 12Mi memory — compare that with the `50m/32Mi` requests in the manifest to open the over- and under-provisioning conversation.

---

## Part 9 — Profiles, multi-node, and mounts (beyond the class demo)

### Profiles

```bash
minikube profile list
minikube start -p second --kubernetes-version=v1.32.0   # an independent second cluster
kubectl config get-contexts                              # 'second' context added
minikube profile second                                  # make it the default for minikube cmds
minikube delete -p second
```

Every profile has independent: node container(s), Kubernetes version, addons, kubeconfig context. Use cases: one cluster per course module, testing an app against two Kubernetes versions, keeping a "clean" cluster while experimenting on another.

### Multi-node

```bash
minikube start -p multi --nodes 3
kubectl get nodes
minikube node add -p multi      # grow later
minikube node delete m03 -p multi
```

Real multi-node scheduling on your laptop: `nodeSelector`, affinity, taints, DaemonSets all behave properly. Each node is a full kicbase container, so RAM adds up fast — for serious multi-node practice kind is lighter (its nodes share more), but profiles+nodes in minikube keep everything in one tool.

### Mounts

```bash
minikube mount C:/work/data:/mnt/data    # leave running
```

Exposes a host directory inside the node (9P filesystem), so Pods can `hostPath`-mount `/mnt/data`. Good for feeding test data in without images; not a performance king — for heavy I/O prefer baking data into images or PVCs.

---

## Cleanup

```bash
kubectl delete namespace hello      # removes every demo object at once
minikube stop                       # cluster preserved on disk
# minikube delete                   # full removal (next start = from scratch)
# minikube delete --all             # remove every profile
docker image rm hello-local:1.0     # optional: clean the host image too
```

---

## Discussion questions

1. Your `LoadBalancer` Service shows `<pending>` on minikube but got an IP on AKS within a minute. Walk through exactly which component answers the request in each case.
2. A teammate says "Docker images are visible to Kubernetes because Kubernetes runs on Docker." Using the two-daemons picture, explain what is wrong with that statement on a minikube docker-driver setup.
3. Why does `minikube image load` of an image tagged `:latest` so often *appear* not to work? Which two manifest changes make loaded images reliable?
4. You enabled the ingress addon, applied an Ingress, and `curl http://hello.local` from your host gets connection refused. List the three independent things that must be true for that curl to succeed on Windows.
5. When would you reach for `minikube image build` or the `docker-env` trick instead of `image load`? What is the trade-off of each?
6. metrics-server is an addon and not part of core Kubernetes. What breaks in a cluster without it, and why might a managed provider still not install it by default?

## Troubleshooting

| Symptom | Root cause | Fix |
|---|---|---|
| `minikube start` hangs at "Pulling base image" | First-run kicbase download (~1 GB) on slow network | Wait; or pre-pull with `minikube start --download-only` |
| `Unable to pick a default driver` | Docker Desktop not running | Start Docker Desktop, retry |
| `EXTERNAL-IP` stays `<pending>` with tunnel running | Tunnel started before the Service existed, or lacks privileges | Restart `minikube tunnel` in an elevated terminal |
| `curl http://127.0.0.1 -H "Host: hello.local"` → connection refused | `minikube tunnel` not running (ingress 80/443 ride the tunnel on Windows/macOS docker driver) | Start the tunnel in a separate terminal and leave it open |
| Pod stuck `ImagePullBackOff` after `image load` | Image tagged `:latest` (pull policy `Always`), or load ran against another profile | Re-tag (e.g. `1.0`), set `IfNotPresent`; check `minikube image ls -p <profile>` |
| Pod recovers slowly after `image load` | Pull-retry exponential backoff (up to 5 min) | `kubectl delete pod <name>` to force an immediate retry |
| `error: Metrics API not available` | metrics-server not enabled or still warming up | `minikube addons enable metrics-server`, wait 1-2 min |
| `kubectl` talks to the wrong cluster | Active context is another profile/cluster | `kubectl config use-context minikube` |
| Cluster slow / weird after weeks of use | Accumulated state in a long-lived dev cluster | `minikube delete && minikube start` — embrace disposability |
| Hyper-V conflicts / virtualization errors | Another hypervisor holding the CPU's VT-x | Use the docker driver; ensure WSL2 backend in Docker Desktop |
| minikube output mixes English and your OS language | minikube localizes some messages from the system locale | Cosmetic only; `LC_ALL=en_US.UTF-8 minikube start` forces English |
| `kubectl.exe is version 1.33, which may have incompatibilities with Kubernetes 1.35` | Client/server version skew beyond one minor | Usually harmless for the basics; update kubectl or use `minikube kubectl -- <args>` (bundled matching client) |

## References

- [minikube — Get Started](https://minikube.sigs.k8s.io/docs/start/) — the canonical install + first-cluster guide
- [minikube — Drivers](https://minikube.sigs.k8s.io/docs/drivers/) — every driver with its trade-offs
- [minikube — Addons](https://minikube.sigs.k8s.io/docs/handbook/addons/) — the full addon catalog
- [minikube — Pushing images](https://minikube.sigs.k8s.io/docs/handbook/pushing/) — the official map of all image-into-cluster paths (mirrors Part 7)
- [minikube — Accessing apps](https://minikube.sigs.k8s.io/docs/handbook/accessing/) — NodePort, LoadBalancer and tunnel, officially explained
- [Kubernetes — Images](https://kubernetes.io/docs/concepts/containers/images/) — imagePullPolicy semantics and the `:latest` defaulting rule
- [Kubernetes — metrics-server](https://github.com/kubernetes-sigs/metrics-server) — what feeds `kubectl top` and HPA
