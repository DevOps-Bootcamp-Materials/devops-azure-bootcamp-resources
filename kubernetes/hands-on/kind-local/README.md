# kind — multi-node cluster, local image loading, ingress through localhost

This is the deep-dive companion to the bootcamp hands-on `week-16/local-kubernetes/hands-on/02_kind_multinode.md`. The bootcamp file is the walkthrough; this README explains the machinery underneath — the config file fields and what else they can do, how `kind load` works, how the host→node→controller chain is wired, the upstream manifest change we hit live while testing (and its full diagnosis), version pinning, CI usage, and the LoadBalancer options we skip in class.

## What this folder contains

- `README.md` — this file: the full walkthrough with every detail and tangent
- `commands.sh` — the complete command sequence as a quick reference
- `kind-config.yaml` — the 3-node cluster definition (port mappings + ingress-ready label)
- `app/Dockerfile`, `app/index.html` — the image built on the host and shipped in with `kind load`
- `manifests/namespace.yaml` — the `hello` namespace
- `manifests/deployment.yaml` — 4-replica Deployment of the local image (watch the spread)
- `manifests/service.yaml` — ClusterIP Service
- `manifests/ingress.yaml` — Ingress routing `hello.kind`

## Prerequisites

- Docker Desktop installed and running
- `kind` >= 0.30, `kubectl` >= 1.30
- The kind deep-dive lesson; the minikube hands-on for the image-into-cluster context

## How to use this folder

```bash
git clone https://github.com/DevOps-Bootcamp-Materials/devops-azure-bootcamp-resources.git
cd devops-azure-bootcamp-resources/kubernetes/hands-on/kind-local
```

---

## Part 1 — The config file, field by field

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: dev
nodes:
  - role: control-plane
    kubeadmConfigPatches: [...]
    extraPortMappings: [...]
  - role: worker
  - role: worker
```

- **`name: dev`** — becomes container names (`dev-control-plane`, `dev-worker`, ...) and the kubeconfig context (`kind-dev`). Without it, the cluster is called `kind` and the context `kind-kind` — a name that confuses everyone at least once.
- **`nodes`** — one entry per node, each a `kindest/node` container. Add more `role: worker` lines for bigger topologies; add more `role: control-plane` entries for an HA control plane (kind then puts a small load balancer in front of the API servers).
- **`extraPortMappings`** — literal Docker `-p hostPort:containerPort` flags for that node's container. They exist **only at creation time**: you cannot add a port mapping to a running cluster (Docker limitation) — you recreate. That asymmetry with minikube's dynamic `tunnel` is a deliberate design trade: kind is declarative and immutable, recreate instead of mutate.
- **`kubeadmConfigPatches`** — raw kubeadm configuration merged into the bootstrap. We use it for one thing: registering the node with the `ingress-ready=true` label so an ingress controller can be pinned to the only node with mapped ports. Anything kubeadm can configure (API server flags, kubelet flags) can be patched here — the escape hatch to "real cluster" configuration.

**Version pinning.** Each kind release embeds a default `kindest/node` image; our test run used `kindest/node:v1.36.1`. To make the cluster reproducible across machines and time, pin it explicitly:

```bash
kind create cluster --config kind-config.yaml --image kindest/node:v1.36.1
```

In CI, always pin — "whatever kind ships" is not a test matrix.

---

## Part 2 — Nodes as containers: what is actually inside

```bash
docker ps --filter name=dev- --format "table {{.Names}}\t{{.Image}}\t{{.Ports}}"
```

**Output (verified):**

```
NAMES               IMAGE                  PORTS
dev-worker2         kindest/node:v1.36.1
dev-worker          kindest/node:v1.36.1
dev-control-plane   kindest/node:v1.36.1   0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp, 127.0.0.1:5xxxx->6443/tcp
```

Each `kindest/node` container runs systemd as PID 1, **containerd** as the container runtime (not Docker — this matters below), kubelet, and on the control-plane node the static Pods for the control plane. The auto-mapped `127.0.0.1:5xxxx->6443` is the API server endpoint kind wrote into your kubeconfig.

**Misconception: "kind nodes run Docker inside Docker."** They run **containerd** inside Docker. Consequences you will actually feel:

- `docker exec dev-worker docker ps` fails — there is no docker CLI/daemon in the node.
- The node-side image tooling is `crictl`: `docker exec dev-worker crictl images`.
- Images loaded with `kind load` land in containerd's store, namespaced as `docker.io/library/<name>` if you used a short name — which is why `crictl images | grep hello-kind` shows `docker.io/library/hello-kind`.

---

## Part 3 — `kind load` under the hood

```bash
docker build -t hello-kind:1.0 ./app
kind load docker-image hello-kind:1.0 --name dev
```

**Output (verified):** one "not yet present on node ..., loading..." line per node — three copies for three nodes.

What happens: kind asks the host Docker daemon for an image tarball (`docker save`), streams it into each node container, and imports it with `ctr --namespace k8s.io images import`. Three nodes = three independent copies; a 1 GB image loads three times. For big images on big clusters this is the moment to switch to a registry-based flow (the GHCR hands-on, or k3d's built-in registry).

**The archive variant** skips rebuilding the tarball per cluster:

```bash
docker save hello-kind:1.0 -o hello-kind.tar
kind load image-archive hello-kind.tar --name dev
```

Useful in CI when the image was built in a previous job and travels as an artifact.

**The same two rules as minikube** (they are kubelet rules, not tool rules): tag explicitly (never `:latest`) and use `imagePullPolicy: IfNotPresent`, or the kubelet will try the registry and ignore the loaded image.

---

## Part 4 — Ingress: the full chain, and the upstream change we hit live

### The chain

```
your browser → localhost:80
  → Docker port mapping (extraPortMappings)        [host → control-plane container]
    → hostPort 80 of the ingress-nginx Pod          [container port binding]
      → controller matches Host: hello.kind         [Ingress rules]
        → Service hello-kind-svc → Pod on a worker  [cluster networking]
```

Four links; any one missing produces a distinct failure signature (see Troubleshooting). This chain — not any specific controller — is the thing to learn.

### What we hit while testing (2026-06-11), step by step

1. Applied `https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml`; controller became Ready.
2. `curl http://localhost -H "Host: hello.kind"` → **`Empty reply from server`** (curl exit 52). Connection accepted, zero bytes back.
3. Diagnosis: `kubectl get pods -n ingress-nginx -o wide` → controller running on **`dev-worker2`**. Its hostPort 80 was bound on a node with no host mapping; Docker's proxy on localhost:80 forwarded into the control-plane node where *nothing* listened → empty reply.
4. Root cause: `kubectl get deployment -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.template.spec.nodeSelector}'` → `{"kubernetes.io/os":"linux"}` only. **Manifests v1.13+ dropped the historical `ingress-ready: "true"` nodeSelector** (v1.12.1 still has it — we checked the tags). With the selector gone, the scheduler is free to place the controller anywhere.
5. Fix (and a free lesson on nodeSelector):

```bash
kubectl -n ingress-nginx patch deployment ingress-nginx-controller --type merge \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"ingress-ready":"true","kubernetes.io/os":"linux"}}}}}'
kubectl -n ingress-nginx rollout status deployment ingress-nginx-controller
```

Controller rescheduled to `dev-control-plane`; curl returned the page.

**PowerShell note (verified the hard way):** inline JSON in `-p '...'` breaks on PowerShell quoting. Use a patch file:

```powershell
@'
{"spec":{"template":{"spec":{"nodeSelector":{"ingress-ready":"true","kubernetes.io/os":"linux"}}}}}
'@ | Set-Content -NoNewline "$env:TEMP\ingress-patch.json"
kubectl -n ingress-nginx patch deployment ingress-nginx-controller --type merge --patch-file "$env:TEMP\ingress-patch.json"
```

**Alternatives to the patch:**

- Pin the old manifest: `.../controller-v1.12.1/deploy/static/provider/kind/deploy.yaml` still carries the nodeSelector. Works, but pins you to an old controller of a retired project.
- On a **single-node** kind cluster the problem cannot occur (only one node to land on) — which is why most tutorials never mention it and why multi-node testing finds what single-node testing hides.
- Install Traefik or another controller via Helm with an explicit `nodeSelector` value — the modern path, covered in the Traefik hands-on.

### Why the controller tolerates the control-plane taint but your app does not

The kind deploy manifest gives the controller Pod tolerations for `node-role.kubernetes.io/control-plane:NoSchedule`. Your app has no toleration, so the taint repels it to the workers. Same mechanism, opposite outcomes, visible in one `kubectl get pods -A -o wide` — bring this up in class when students ask why the controller "ignored" the taint.

---

## Part 5 — Scheduling observations on a real multi-node cluster

```bash
kubectl get pods -n hello -o wide
```

**Output (verified):** 4 replicas spread exactly 2+2 across `dev-worker` and `dev-worker2`, none on the control plane.

Two forces produce this:

1. **The control-plane taint** (`node-role.kubernetes.io/control-plane:NoSchedule`) excludes the control-plane node outright.
2. **Scheduler scoring** — among the remaining nodes, the default plugins (`PodTopologySpread` with its default cluster-wide constraints, `NodeResourcesBalancedAllocation`) prefer balancing identical Pods, giving the clean 2+2.

Things to try that make the scheduling lessons tangible (all reversible):

```bash
# Force everything onto one worker
kubectl -n hello patch deployment hello-kind --type merge -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"dev-worker"}}}}}'

# Watch what happens when a node "dies" (stop its container!)
docker stop dev-worker2
kubectl get nodes -w          # NotReady after ~40s, pods rescheduled after the eviction timeout
docker start dev-worker2
```

That second experiment — killing a node by stopping a container — is something a managed cluster never lets you do. It is the best argument for multi-node local clusters as a learning tool.

---

## Part 6 — kind in CI (the snippet to steal)

The create-test-delete cycle from the hands-on, as a GitHub Actions job:

```yaml
jobs:
  integration:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Create kind cluster
        uses: helm/kind-action@v1
        with:
          cluster_name: ci
          config: kind-config-ci.yaml      # pin node image + topology here

      - name: Build and load the app image
        run: |
          docker build -t myapp:${{ github.sha }} .
          kind load docker-image myapp:${{ github.sha }} --name ci

      - name: Deploy and test
        run: |
          kubectl apply -f manifests/
          kubectl wait --for=condition=ready pod -l app=myapp --timeout=120s
          ./run-integration-tests.sh
# No teardown needed: the runner VM is destroyed after the job.
```

Every pull request gets a fresh, real Kubernetes cluster for the price of ~90 extra seconds of CI time. This pattern is the single most common professional use of kind.

---

## Part 7 — LoadBalancer on kind (beyond the class demo)

`type: LoadBalancer` Services stay `<pending>` on kind — no cloud, no klipper, no tunnel. The options:

| Option | What it is | When |
|---|---|---|
| `kubectl port-forward` | API-server tunnel | Quick checks, demos |
| NodePort + `extraPortMappings` | Map the NodePort range entry you need at creation | Static, simple, no extra components |
| **cloud-provider-kind** | A small host process implementing the cloud LB API for kind clusters | The most realistic EXTERNAL-IP experience |
| **MetalLB** | A real bare-metal LB (ARP/L2 mode) inside the cluster | Doubles as practice with a production-grade tool |

For the course, Ingress covers the realistic case; if you want EXTERNAL-IPs for their own sake, [cloud-provider-kind](https://github.com/kubernetes-sigs/cloud-provider-kind) is one binary and zero YAML.

---

## Cleanup

```bash
kind delete cluster --name dev
kind delete clusters --all        # if you accumulated experiments
docker image rm hello-kind:1.0
docker image prune                # reclaims old kindest/node layers if you upgraded kind
```

`kind delete` removes containers, the Docker network, and the kubeconfig context. There is no stop/resume: the config file is the durable artifact, the cluster is cattle.

---

## Discussion questions

1. Walk the four links of the localhost→Pod chain. For each link, name the failure signature when it is missing (connection refused? empty reply? 404? timeout?).
2. Why did the ingress controller end up on a worker node in our test, and why does the same install "just work" on every single-node tutorial on the internet?
3. The controller Pod runs on the control-plane node despite its `NoSchedule` taint, while your app Pods do not. Explain the exact mechanism on both sides.
4. `kind load` copied the image three times. At what cluster size / image size does this stop being acceptable, and what replaces it?
5. Your CI pipeline pins `kindest/node:v1.36.1` and your production AKS runs 1.33. Is testing on a newer version than production acceptable? What would you change?
6. Why can't you add an `extraPortMapping` to a running kind cluster, and what does that constraint teach about Docker port publishing?

## Troubleshooting

| Symptom | Root cause | Fix |
|---|---|---|
| `curl localhost` → `Empty reply from server` (exit 52) | Ingress controller scheduled on a node without host port mappings (manifests v1.13+ lost the `ingress-ready` nodeSelector) | Patch the deployment's nodeSelector (Part 4) and `rollout status` |
| `curl localhost` → connection refused | Cluster created **without** `extraPortMappings` (default config) | Recreate with `--config kind-config.yaml` — mappings cannot be added live |
| `curl localhost` → 404 from nginx | Controller fine; no Ingress rule matches | Send the right `Host:` header; check `kubectl get ingress -n hello` |
| Pods `ErrImagePull` for the local image | Forgot `kind load`, loaded into the wrong cluster name, or `:latest`+`Always` | `kind load docker-image hello-kind:1.0 --name dev`; check `--name`; pin tags |
| `docker exec dev-worker docker ps` → not found | Nodes run containerd, not Docker | Use `crictl`: `docker exec dev-worker crictl ps` / `crictl images` |
| `kubectl` hits the wrong cluster | Multiple kind clusters, wrong context | `kubectl config use-context kind-dev` |
| `kind create` fails with name conflict | Cluster (or leftover containers) with that name exist | `kind delete cluster --name dev` first; `docker ps -a` for strays |
| Patch with inline JSON fails on PowerShell | Quote mangling of `"` inside `-p '...'` | Use `--patch-file` with a here-string (Part 4) |
| Node NotReady after laptop sleep | Node containers paused/disrupted | `docker restart dev-control-plane dev-worker dev-worker2`, or recreate — it is faster |

## References

- [kind — Quick Start](https://kind.sigs.k8s.io/docs/user/quick-start/) — install, create, the config file basics
- [kind — Configuration](https://kind.sigs.k8s.io/docs/user/configuration/) — every config field, including extraPortMappings and kubeadmConfigPatches
- [kind — Ingress](https://kind.sigs.k8s.io/docs/user/ingress/) — the official ingress-on-kind guide
- [kind — Loading an image](https://kind.sigs.k8s.io/docs/user/quick-start/#loading-an-image-into-your-cluster) — `kind load` documented
- [helm/kind-action](https://github.com/helm/kind-action) — the GitHub Action wrapping the CI pattern in Part 6
- [cloud-provider-kind](https://github.com/kubernetes-sigs/cloud-provider-kind) — LoadBalancer support for kind clusters
- [Ingress NGINX Retirement: What You Need to Know](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/) — the official announcement (maintenance ended March 2026); the context behind the manifest changes and the migration conversation
- [Ingress NGINX: Statement from the Kubernetes Steering and Security Response Committees](https://kubernetes.io/blog/2026/01/29/ingress-nginx-statement/) — the follow-up clarifying what "retired" means for existing users
