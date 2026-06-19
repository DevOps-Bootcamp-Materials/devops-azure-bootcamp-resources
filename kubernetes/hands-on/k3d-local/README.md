# k3d — registry, Traefik, ServiceLB: the batteries-included local cluster

This is the deep-dive companion to the bootcamp hands-on `week-16/local-kubernetes/hands-on/03_k3d_registry.md`. The bootcamp file walks the flow; this README explains the machinery: what K3s strips and substitutes, how the k3d registry wiring works name by name (including the Docker Desktop two-name reality we verified), what ServiceLB actually does to answer a LoadBalancer Service, how to turn the bundled components off, and every quirk we hit while testing on Windows.

## What this folder contains

- `README.md` — this file: the full walkthrough with every detail and tangent
- `commands.sh` — the complete command sequence as a quick reference
- `k3d-config.yaml` — cluster + registry + port mappings in one declarative file
- `app/Dockerfile`, `app/index.html` — the image pushed through the local registry
- `manifests/namespace.yaml` — the `hello` namespace
- `manifests/deployment.yaml` — 3-replica Deployment pulling from the local registry
- `manifests/service.yaml` — ClusterIP Service
- `manifests/service-lb.yaml` — the LoadBalancer that gets a real EXTERNAL-IP
- `manifests/ingress.yaml` — standard Ingress routed by the bundled Traefik

## Prerequisites

- Docker Desktop installed and running
- `k3d` >= 5.8, `kubectl` >= 1.30
- The k3d deep-dive lesson; the minikube and kind hands-on for the comparisons

## How to use this folder

```bash
git clone https://github.com/DevOps-Bootcamp-Materials/devops-azure-bootcamp-resources.git
cd devops-azure-bootcamp-resources/kubernetes/hands-on/k3d-local
```

---

## Part 1 — What `k3d cluster create` builds (verified inventory)

```bash
k3d cluster create --config k3d-config.yaml
k3d node list
```

**Output (verified, k3d v5.9 / K3s v1.35.5+k3s1):**

```
NAME                 ROLE           CLUSTER   STATUS
k3d-dev-agent-0      agent          dev       running
k3d-dev-agent-1      agent          dev       running
k3d-dev-server-0     server         dev       running
k3d-dev-serverlb     loadbalancer   dev       running
k3d-dev-tools                       dev       running
registry.localhost   registry       dev       running
```

Component by component:

- **`server-0`** — runs the K3s server binary: API server, scheduler, controller-manager, and the datastore (SQLite at this size; embedded etcd if you ask for `--servers 3`). Unlike kind, the server node is also schedulable — K3s does not taint its control plane by default (verified: one of our app pods landed there). That choice comes from K3s's edge heritage, where wasting a whole node on control-plane-only duty is unacceptable.
- **`agent-0/1`** — K3s agents (workers).
- **`serverlb`** — a small nginx proxy in front of the cluster. All your declared `ports:` mappings land here, and it forwards to the nodes. This is also what keeps the kubeconfig stable: your kubectl talks to the serverlb, which proxies to whichever server is alive.
- **`tools`** — a k3d helper container (image imports, etc.). It comes and goes; ignore it.
- **`registry.localhost`** — the OCI registry from the config's `registries.create` block. Note it kept the name **as written** in the config; a registry created from the CLI (`k3d registry create foo`) gets prefixed to `k3d-foo`. The canonical truth is always `k3d node list`.

**Config-file vs flags.** Everything in `k3d-config.yaml` maps to a CLI flag (`--servers`, `--agents`, `--port`, `--registry-create`), but the file is the version-controllable artifact — same philosophy as kind's config. The schema is `k3d.io/v1alpha5`, documented in the k3d config reference (link below).

---

## Part 2 — The K3s bundle, piece by piece (verified)

```bash
kubectl get pods -n kube-system
```

```
coredns-...                        1/1   Running
helm-install-traefik-crd-...      0/1   Completed
helm-install-traefik-...          0/1   Completed
local-path-provisioner-...        1/1   Running
metrics-server-...                1/1   Running
svclb-traefik-... (x3, one per node)   2/2   Running
traefik-...                        1/1   Running
```

- **The two `helm-install-traefik*` jobs** are K3s's own Helm controller installing Traefik — one job for the CRDs, one for the chart. This is worth pausing on: K3s ships a controller that turns `HelmChart` custom resources into installed charts; Traefik arrives through that mechanism, not baked into the binary. `kubectl get helmcharts -n kube-system` shows the resource.
- **`svclb-traefik` is a DaemonSet** — one pod per node. This is **ServiceLB (klipper-lb)** at work: for every `LoadBalancer` Service, K3s spawns a DaemonSet whose pods bind the service's port on the host network of each node and forward to the Service. The "load balancer" is therefore *every node at once*; the EXTERNAL-IP column lists all node IPs (verified: `192.168.80.3,192.168.80.4,192.168.80.5` on the cluster's Docker network).
- **metrics-server** — preinstalled; `kubectl top` works from minute one (on minikube it was an addon; on kind you would install it yourself).
- **local-path-provisioner** — the default StorageClass `local-path`, `VolumeBindingMode: WaitForFirstConsumer` (PVCs stay Pending until a Pod uses them — expected, not a bug).

**Misconception: "K3s is a toy / not real Kubernetes."** K3s is CNCF-certified conformant and runs in production at the edge (retail stores, factories, telco). What it is *not* is upstream-default-packaged: substitutions (SQLite, ServiceLB, Traefik) are exactly what the lesson's table lists, and all of them can be turned off (Part 6).

---

## Part 3 — The registry: names, trust, and the Docker Desktop boundary

### The wiring k3d did for you

Every node got this file (verified):

```bash
docker exec k3d-dev-server-0 cat /etc/rancher/k3s/registries.yaml
```

```yaml
mirrors:
  registry.localhost:5000:
    endpoint:
    - http://registry.localhost:5000
```

That is containerd registry configuration: "when asked for images from `registry.localhost:5000`, go to that endpoint over plain HTTP". The registry container and the nodes share a Docker network, where the container's name resolves natively. Setting this up by hand on a generic cluster means editing containerd config on every node and restarting kubelets — the single most fiddly part of self-hosted registries, automated away.

### The two-name reality on Docker Desktop (verified the hard way)

| Where | Name that works | Why |
|---|---|---|
| Inside the cluster (manifests) | `registry.localhost:5000` | Docker-network DNS + the registries.yaml above |
| Host curl / browser (Windows) | `localhost:5000` *and* `registry.localhost:5000` | Windows resolves `*.localhost` to loopback (RFC 6761); port 5000 is published |
| **Host `docker push`** | **`localhost:5000` only** | The docker **daemon** runs inside the WSL2 VM, where `*.localhost` does NOT resolve to the Windows loopback. Push to `registry.localhost:5000` fails with `lookup registry.localhost: no such host` |

Hence the canonical Docker Desktop flow:

```bash
docker build -t registry.localhost:5000/hello-k3d:1.0 ./app     # cluster-side name in the tag
docker tag registry.localhost:5000/hello-k3d:1.0 localhost:5000/hello-k3d:1.0
docker push localhost:5000/hello-k3d:1.0                         # host-side name for the push
```

On native Linux, pushing straight to `registry.localhost:5000` works and the tag dance disappears. Either way it is one registry, one store: the catalog shows the image regardless of which name pushed it.

### Why this beats `image load` (and when it doesn't)

The registry flow exercises the **same code path as production**: kubelet → containerd → registry pull, with image digests, layer caching, and `imagePullPolicy` semantics all real. `k3d image import` (the tarball path, like `kind load`) is still there and is fine for one-off images; the registry pays off when you iterate (`push` only uploads changed layers) and when you practice CI flows locally.

### Sharing a registry across clusters

A standalone registry survives clusters:

```bash
k3d registry create shared --port 5000
k3d cluster create a --registry-use k3d-shared:5000
k3d cluster create b --registry-use k3d-shared:5000
```

Push once, both clusters pull. (Note the `k3d-` prefix on CLI-created registries.) Our config-created registry instead **dies with the cluster** — verified: after `k3d cluster delete dev`, the registry container is gone and `k3d registry delete` has nothing to remove.

---

## Part 4 — Traffic: serverlb → Traefik → Service, and ServiceLB

### The Ingress path (port 8080)

```
host:8080
  → k3d-dev-serverlb (the "8080:80@loadbalancer" mapping)
    → Traefik's LoadBalancer Service, port 80
      → Traefik pod
        → Ingress rule host=hello.k3d
          → hello-k3d-svc → app pod
```

Because Traefik is the **default IngressClass** (`kubectl get ingressclass`), a plain `networking.k8s.io/v1` Ingress with no class set would also be picked up; our manifest sets `ingressClassName: traefik` explicitly for self-documentation. **Annotation portability warning:** `nginx.ingress.kubernetes.io/*` annotations from tutorials are no-ops on Traefik. Traefik's own behaviors are configured with its middleware system, which the Traefik hands-on covers in depth.

### The LoadBalancer path (port 8081, verified)

Applying `service-lb.yaml`:

1. K3s's ServiceLB controller sees the new `LoadBalancer` Service.
2. It creates a DaemonSet `svclb-hello-k3d-lb` in the same namespace — check it: `kubectl get pods -n hello | grep svclb`.
3. Those pods bind port 8081 on the host network of **every node** and forward to the Service.
4. The Service's EXTERNAL-IP is patched with the node IPs (the `192.168.x.x` triplet).
5. Our `8081:8081@loadbalancer` mapping carries host:8081 → serverlb → nodes:8081.

The limits: one port can only be claimed by one LoadBalancer Service cluster-wide (klipper binds real node ports), and the IPs are Docker-network-internal — host reachability always goes through declared serverlb mappings. For the three-tool comparison table, see the bootcamp hands-on Step 6.

---

## Part 5 — Lifecycle: stop/start quirk, multi-cluster

### stop/start (verified, with a quirk)

```bash
k3d cluster stop dev
k3d cluster start dev
```

State survives (SQLite datastore and volumes persist). **Quirk we hit:** `k3d cluster start` exited with `FATA ... error overwriting contents of /etc/hosts: ... container is restarting` — yet `kubectl get nodes` immediately after showed all three nodes Ready and the cluster fully functional. The start command races against agent containers still restarting; the error is about a post-start nicety (hosts file injection), not the cluster itself. Check `k3d cluster list` before believing a FATA from `k3d cluster start`; re-run the start if the cluster is genuinely down.

### Multi-cluster (verified)

```bash
k3d cluster create second --servers 1 --agents 0   # ~20s, one container + serverlb
k3d cluster list
k3d cluster delete second
```

Each cluster gets its own serverlb and kubeconfig context (`k3d-second`). Port mappings must differ per cluster (two clusters cannot both claim host 8080). A 1-server/0-agent K3s cluster is the cheapest functional Kubernetes you can run — server nodes schedule workloads, remember.

---

## Part 6 — Slimming K3s down (when batteries get in the way)

Reasons to disable bundled components: you want ingress-nginx parity with an existing cluster, MetalLB instead of ServiceLB, or a minimal footprint. K3s takes `--disable` flags, passed through k3d per node group:

```bash
k3d cluster create lean \
  --k3s-arg "--disable=traefik@server:0" \
  --k3s-arg "--disable=servicelb@server:0" \
  --k3s-arg "--disable=metrics-server@server:0"
```

The `@server:0` suffix is k3d's node-filter syntax (the flag goes to the server's K3s invocation). With Traefik and ServiceLB off, the cluster behaves like kind: Ingress needs an installed controller, LoadBalancer sits `<pending>`. That convergence is itself instructive — the differences between the three tools are packaging policy, not Kubernetes.

In the config file the same is expressed as:

```yaml
options:
  k3s:
    extraArgs:
      - arg: --disable=traefik
        nodeFilters:
          - server:0
```

---

## Cleanup

```bash
k3d cluster delete dev          # also removes the config-created registry (verified)
docker image rm registry.localhost:5000/hello-k3d:1.0 localhost:5000/hello-k3d:1.0
k3d cluster list                # confirm empty
```

---

## Discussion questions

1. K3s replaces etcd with SQLite by default. What does that cost you, and at what point does K3s itself force the switch back to etcd?
2. Walk through what ServiceLB does when you apply a `LoadBalancer` Service. Why does the EXTERNAL-IP column show *three* IPs on our cluster?
3. Why does `docker push registry.localhost:5000/...` fail on Docker Desktop but work on native Linux? Which process performs the DNS lookup in each case?
4. The app pod landed on the server node — on kind it could not have. Find both behaviors' rationale and name one scenario where K3s's choice would hurt you.
5. Your team's manifests carry `nginx.ingress.kubernetes.io/rewrite-target` annotations. What happens when you apply them on a default k3d cluster, and what are your two options?
6. A registry created via the cluster config dies with the cluster; a CLI-created one survives. When is each behavior what you want?

## Troubleshooting

| Symptom | Root cause | Fix |
|---|---|---|
| `docker push registry.localhost:5000/...` → `no such host` | Docker daemon inside WSL2/VM cannot resolve `*.localhost` | Push via `localhost:5000` (two-name flow, Part 3) |
| Pods `ErrImagePull` from the local registry | Manifest uses a name the nodes don't know (e.g. `localhost:5000` — that is the *host's* loopback, not the node's) | Reference the registry by its `k3d node list` name (`registry.localhost:5000`) |
| `curl localhost:8080` → connection refused | Cluster created without the `ports:` mappings | Recreate from the config file; mappings are creation-time |
| `curl localhost:8080` → 404 | Traefik is up but no Ingress rule matches | Send `Host: hello.k3d`; check `kubectl get ingress -n hello` |
| nginx ingress annotations ignored | Default controller is Traefik | Use Traefik middlewares, or disable Traefik and install ingress-nginx (Part 6) |
| `k3d cluster start` prints FATA about /etc/hosts | Race with agent containers restarting | Check `k3d cluster list` / `kubectl get nodes`; usually already fine; re-run start if not |
| Second LoadBalancer Service stuck `<pending>` | Port already claimed by another LoadBalancer (klipper binds real node ports) | Use a different port, or one Service + Ingress paths |
| PVC stuck `Pending` with local-path | `WaitForFirstConsumer` binding mode | Expected — create the Pod that uses it |
| Wrong cluster targeted | Multiple k3d contexts | `kubectl config use-context k3d-dev` |

## References

- [k3d — Documentation](https://k3d.io/) — the project home; quick start and CLI reference
- [k3d — Config file reference](https://k3d.io/stable/usage/configfile/) — every `v1alpha5` field used in `k3d-config.yaml`
- [k3d — Registries guide](https://k3d.io/stable/usage/registries/) — create/use registries, including the naming rules
- [K3s — Architecture](https://docs.k3s.io/architecture) — servers, agents, datastore options, how the pieces fit
- [K3s — Networking (ServiceLB)](https://docs.k3s.io/networking/networking-services) — the official explanation of klipper-lb and how to disable it
- [K3s — Helm controller](https://docs.k3s.io/helm) — the mechanism that installs Traefik via HelmChart resources
- [Traefik — Kubernetes Ingress provider](https://doc.traefik.io/traefik/providers/kubernetes-ingress/) — how Traefik consumes standard Ingress objects
