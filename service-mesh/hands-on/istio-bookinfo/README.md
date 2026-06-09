# Service Mesh — Install Istio on AKS and deploy Bookinfo

The deep-dive companion to [`week-16/service-mesh/hands-on/01_install_istio_on_aks_bookinfo.md`](https://github.com/DevOps-Bootcamp-Materials/devops-azure-bootcamp/blob/main/week-16/service-mesh/hands-on/01_install_istio_on_aks_bookinfo.md) in the bootcamp repo. The bootcamp file is the in-class teaching script and is enough on its own to install Istio, deploy Bookinfo, and inspect the mesh. This README is what to read **after** that, when you want the full picture: every Istio component explained, the install profiles in detail, the sidecar injection mechanism end-to-end, the full Istio object model (the seven CRDs you'll meet), the xDS protocol family, the AKS managed add-on, the kind/minikube local alternative, when *not* to use Istio, and the troubleshooting table.

## What this folder contains

- `README.md` — this file: the full reference walkthrough plus every discussion the bootcamp file deferred.
- `manifests/bookinfo/bookinfo.yaml` — the Bookinfo sample app at Istio 1.30, pinned. Identical to the upstream copy; bundled here so the hands-on does not break if upstream moves.
- `manifests/bookinfo/bookinfo-gateway.yaml` — the `Gateway` + `VirtualService` that expose the app at the cluster edge.
- `manifests/bookinfo/destination-rule-all.yaml` — `DestinationRule` resources naming v1/v2/v3 subsets of the Bookinfo services.
- `manifests/addons/prometheus.yaml`, `manifests/addons/kiali.yaml` — the Istio observability addons at release-1.30, pinned (Kiali v2.22). A small Prometheus for Kiali to read and the Kiali topology dashboard. The `demo` profile does not include these.
- `scripts/aks-up.sh` — creates the AKS cluster, then calls `mesh-up.sh`. Idempotent, parametrised by env vars.
- `scripts/aks-down.sh` — counterpart to `aks-up.sh`. Tears the resource group down.
- `scripts/kind-up.sh` — local, free alternative: creates a `kind` cluster, then calls `mesh-up.sh`. Idempotent.
- `scripts/kind-down.sh` — deletes the `kind` cluster (removes Istio, Bookinfo, Kiali and everything at once).
- `scripts/mesh-up.sh` — cluster-agnostic: installs Istio (`demo`) + Bookinfo + Gateway/DestinationRules + Prometheus + Kiali on the active cluster. Shared by `aks-up.sh` and `kind-up.sh` so AKS and kind get an identical mesh. Automates the *setup* so class time goes to inspecting/explaining, not typing the install.
- `scripts/traffic.sh` — generates steady load against `/productpage` so the Kiali graph lights up. Auto-detects the AKS public IP or port-forwards on kind. Run it in a separate terminal during the demo.

## Prerequisites

- Azure subscription with permission to create AKS + resource groups.
- `az` CLI (>= 2.60), logged in (`az login`, `az account show`).
- `kubectl` (1.28+).
- `istioctl` (1.30+). The bootcamp file's step 2 walks the install.
- W16.1 lesson (`week-16/service-mesh/lessons/01_intro_to_service_mesh.md`). The two-plane model (control vs data), the sidecar pattern, and the "what a mesh does and does not give you" tables are used here without re-explaining.

## How to use this folder

```bash
git clone https://github.com/DevOps-Bootcamp-Materials/devops-azure-bootcamp-resources.git
cd devops-azure-bootcamp-resources/service-mesh/hands-on/istio-bookinfo
```

Either follow the bootcamp file end-to-end and dip into this README only where it says "see the full treatment in the resources README", or read this file in order if you already know the basics and want depth without ceremony.

---

## Part 1 — What Istio actually is, beyond the lesson

The lesson laid out the generic "service mesh" concept: data plane + control plane, sidecar pattern, the cross-cutting capabilities a mesh provides. That was deliberately vendor-neutral. This section is specifically about Istio: how it is shaped, what its history is, what `istiod` actually does, what choices it makes that are *not* universal across meshes.

### Istio in one sentence

Istio is an **open-source service mesh built on Envoy**, started at Google in 2017, donated to the CNCF in 2022, graduated from incubation in 2023. Its data plane is Envoy (the proxy itself); its control plane is a single Go binary called `istiod`. The Kubernetes API is its source of truth — everything you configure flows through Kubernetes CRDs.

### The historical name to know: Pilot, Citadel, Galley

If you read any pre-2020 Istio article you will see three control-plane components named:

| Old name | What it did | Where it is now |
|---|---|---|
| **Pilot** | Took Kubernetes Services and Istio CRDs, computed Envoy config, pushed it over xDS. | Inside `istiod`. |
| **Citadel** | Signed workload certificates for mTLS, ran the CA. | Inside `istiod`. |
| **Galley** | Validated and distributed configuration to the rest of the control plane. | Inside `istiod`. |
| **Mixer** | Telemetry collection and policy checks. Lived **in the request path** as a separate pod that every sidecar called for every request. | **Removed entirely.** Telemetry is now generated by the sidecar's Envoy directly; policy checks run inline in the sidecar. |

The pre-1.5 architecture was operationally heavier — four deployments, with Mixer especially adding measurable latency since every request went out of the sidecar to a remote Mixer pod and back. The 1.5 redesign (June 2020) consolidated everything into `istiod` and pushed Mixer's functions into the Envoy proxy itself. The "old Istio is slow and complex" complaint you sometimes still hear is mostly pre-1.5; the modern version is much leaner.

Most production deployments now run a single `istiod` deployment plus one Envoy per gateway. Knowing the historical names matters only when you read older docs and try to map them to the components you see in your cluster.

### What `istiod` does, in concrete terms

`istiod` is one Go binary with several roles inside it. From a `kubectl get pod` perspective it is one container, but functionally:

| Role | What it does |
|---|---|
| **Service-and-config discovery** | Watches the Kubernetes API for `Service`, `Endpoint`, `Namespace`, `Pod`, and every Istio CRD (`VirtualService`, `DestinationRule`, `Gateway`, `ServiceEntry`, `Sidecar`, `PeerAuthentication`, `RequestAuthentication`, `AuthorizationPolicy`, etc.). Maintains an in-memory model of the desired mesh configuration. |
| **xDS server** | Serves the Envoy xDS gRPC API. Every sidecar (and every gateway Envoy) opens one long-lived gRPC stream to `istiod` and receives configuration updates over it. |
| **Sidecar webhook** | Runs the mutating admission webhook that rewrites pod specs to inject the `istio-init` init container and the `istio-proxy` sidecar container on pods in injection-enabled namespaces. |
| **Validation webhook** | Runs the validating admission webhook that checks Istio CRD updates for validity before they are accepted into the API server. Catches "this `VirtualService` references a host that does not exist" *at apply time* rather than at runtime. |
| **CA** | Issues short-lived workload certificates (default 24-hour TTL) for every meshed pod, signed by the mesh CA. The proxy gets its identity certificate via this CA, and uses it for mTLS to other proxies. |
| **CSR endpoint** | The pod-side `pilot-agent` (a thin sidecar process that boots before Envoy and reconfigures it) calls into `istiod`'s CSR endpoint with a Certificate Signing Request to obtain that workload cert at startup. |

All of this happens behind one `kubectl get pod` line. When the lesson says "the control plane is not in the request path", what it concretely means is: `istiod` participates in *configuration pushes* and *cert rotation*, not in routing live HTTP requests. Knock it offline and your services keep talking to each other; they just stop receiving new config until it comes back.

---

## Part 2 — Install profiles, every one of them

Istio ships several **install profiles**. Each is a YAML preset that toggles components on/off and tunes settings. You pick one with `istioctl install --set profile=<name>`. The profiles and when to use each:

| Profile | Components enabled | Telemetry sampling | Use case |
|---|---|---|---|
| `default` | `istiod`, `istio-ingressgateway` | 1% (production-tuned) | Production. The recommended starting point for real workloads. |
| `demo` | `istiod`, `istio-ingressgateway`, `istio-egressgateway` | 100% (every request traced) | Tutorials, learning, the Bookinfo walkthrough. **What this hands-on uses.** |
| `minimal` | `istiod` only | (no telemetry sidecar) | Multi-cluster setups where the ingress gateway lives in a different cluster. Also useful when you want only mTLS and L4 features. |
| `external` | `istiod` configured to manage proxies in a different cluster | n/a | External control plane topologies — one `istiod` managing many remote data planes. |
| `empty` | (nothing) | n/a | A starting point if you want to compose components by hand from `IstioOperator` overrides. |
| `preview` | Same as `default` plus alpha features | 1% | Early access to features not yet stable. Read the release notes carefully before using. |
| `ambient` | `istiod` + `ztunnel` (per-node L4 proxy) + waypoint proxies on demand | configurable | Istio's sidecar-less mode. See Part 9 below. |

The profile's job is to bootstrap an `IstioOperator` resource with sensible defaults. You can always go further: `istioctl install -f my-overrides.yaml` lets you pass an `IstioOperator` manifest that adds gateway replicas, tunes resource limits, enables WASM filters, or wires the mesh into a custom CA. The profile-as-a-shortcut is fine for the cases above; in real production work you maintain your own `IstioOperator` manifest in Git and apply it via your GitOps tool.

For class we pick `demo` because:

1. It enables the egress gateway too, so the cluster's outbound traffic to external services can be funneled through a single Envoy when we get to that lesson.
2. It samples 100% of traces, which makes the observability hands-on (W16.5) much easier to demonstrate.
3. It is what the official Bookinfo tutorial assumes, so the sample manifests align without surprises.

The cost: noticeably more CPU and memory than `default` because of the extra tracing work and the egress gateway pod. Fine for a teaching cluster.

---

## Part 3 — How sidecar injection actually works

The bootcamp file says "label the namespace, get sidecars in every pod". That's true. The full mechanism, end to end, is:

### 1. The label match

When you run:

```bash
kubectl label namespace bookinfo istio-injection=enabled
```

you set the label `istio-injection=enabled` on the namespace. That label is what the **mutating admission webhook** uses to decide whether to inject into a new pod. Inspect the webhook with:

```bash
kubectl get mutatingwebhookconfiguration istio-sidecar-injector -o yaml
```

You will see (among other things):

```yaml
webhooks:
- name: rev.namespace.sidecar-injector.istio.io
  namespaceSelector:
    matchExpressions:
    - key: istio-injection
      operator: In
      values: [enabled]
  rules:
  - operations: [CREATE]
    apiGroups: [""]
    apiVersions: [v1]
    resources: [pods]
```

So: any time someone CREATEs a Pod in a namespace whose `istio-injection` label is `enabled`, the API server fires off a webhook call to `istiod`'s `inject` endpoint before persisting the pod.

### 2. The webhook rewrite

`istiod`'s `inject` handler:

1. Receives the original `Pod` spec.
2. Reads its sidecar template (an embedded Go template, customisable via the `istio-sidecar-injector` ConfigMap).
3. Returns a JSON patch that adds two containers to the Pod:
   - A **run-once init container** named `istio-init`, image `proxyv2`, that runs the iptables setup script and exits.
   - The **`istio-proxy` sidecar**, image `proxyv2`, that runs the `pilot-agent` + Envoy and stays running for the pod's lifetime.

The patch also adds annotations (`sidecar.istio.io/status`, `kubectl.kubernetes.io/default-container`) and a few volumes for the workload cert and the gRPC connection to `istiod`.

The API server applies the patch and the modified pod is what schedulers actually see. **The original `Deployment` is unchanged in the API server.** The change only happens at admission time on the Pod resource. That is why `kubectl get deploy productpage-v1 -o yaml` still shows one container even though the running pod is `2/2`.

> **Native sidecars (Istio on Kubernetes 1.29+, which includes AKS 1.34 and current `kind`).** Since the [native sidecar containers](https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/) feature went stable, Istio injects `istio-proxy` not as an ordinary container but as an **`initContainer` with `restartPolicy: Always`**. Kubernetes therefore starts it *before* the app container and keeps it running for the pod's whole life. The practical consequences:
> - The pod still reports **`2/2 Ready`** — a native sidecar counts toward readiness.
> - In `kubectl describe pod`, `istio-proxy` shows under **`Init Containers:`**, alongside `istio-init`, *not* under `Containers:`. Older docs (and earlier versions of this README) show it under `Containers:` — that was the pre-native-sidecar layout.
> - This fixed a long-standing ordering bug where the app could start, and even exit, before/without the proxy being ready. You can see the layout with `kubectl get pod <pod> -n bookinfo -o jsonpath='{.spec.initContainers[*].name}'` → `istio-init istio-proxy`.

### 3. What `istio-init` does

The init container's job is to make sure every byte in and out of the pod's network namespace goes through Envoy. It does this by writing iptables rules. The relevant chain (simplified):

```
PREROUTING (inbound)   ──► REDIRECT to 15006  ──► Envoy inbound listener
OUTPUT     (outbound)  ──► REDIRECT to 15001  ──► Envoy outbound listener
```

Plus a small set of `RETURN` rules to allow:
- Loopback traffic (`127.0.0.1` ↔ `127.0.0.1`) without interception, so the app's localhost calls don't loop through the proxy.
- The init container's own setup egress, briefly, while it boots.
- A few well-known UIDs/GIDs that Envoy itself runs as, so Envoy's own egress doesn't get caught by its own rules.

You can read the exact rules with:

```bash
kubectl debug -n bookinfo "$PROD_POD" -it --image=nicolaka/netshoot --target=istio-proxy -- iptables -t nat -L -n
```

The init container then exits, having written one-shot configuration. The iptables rules persist for the lifetime of the pod's network namespace.

### 4. What `istio-proxy` does at startup

The sidecar container boots two processes inside one container:

1. **`pilot-agent`** — a thin Go process that:
   - Calls `istiod`'s CSR endpoint to obtain a workload certificate.
   - Generates the initial Envoy bootstrap configuration (where to find `istiod`, the local listener ports, the service node identity).
   - Launches Envoy as a child process.
2. **Envoy** — the actual proxy. Opens a gRPC stream to `istiod` over xDS, receives configuration, starts listening on 15001 (outbound) and 15006 (inbound).

Once Envoy is up and the workload cert is renewed periodically (default every ~12 hours, well before the 24-hour TTL), the proxy is ready. The pod becomes `2/2 Ready`.

### Things that can go wrong (briefly)

- **Pod comes up `1/1` instead of `2/2`.** Injection didn't happen. Either the namespace label is missing, or the pod has an annotation `sidecar.istio.io/inject: "false"` (rare), or you applied the manifest *before* labelling the namespace. Fix: label the namespace, then `kubectl rollout restart deployment <name> -n <ns>`.
- **Pod stuck in `Init:0/1`.** The init container is failing. Usually a permissions issue — `istio-init` needs `NET_ADMIN` and `NET_RAW`. On AKS this is enabled by default; on restricted PSP-style policies it can be denied.
- **Pod stuck in `Running 1/2`.** The Envoy sidecar is failing its readiness probe. Almost always because the proxy cannot reach `istiod`. Check `istiod` logs, check the `Service` named `istiod.istio-system.svc.cluster.local` resolves from the pod's network namespace.

The troubleshooting table at the end of this README has the full list.

---

## Part 4 — The Istio object model: every CRD you will meet

Step 7 of the bootcamp file introduces `Gateway` and `VirtualService`. Step 8 introduces `DestinationRule`. There are more, and you will meet them in the rest of week 16 and in production. Here is the full set worth knowing:

### Traffic management CRDs (the `networking.istio.io` API group)

| CRD | Purpose | When you reach for it |
|---|---|---|
| **`Gateway`** | A listener on an Istio Envoy. Says "open port 80 / 443 / 9443 on the gateway proxy, accept these hostnames, optionally terminate this TLS cert." | Whenever you want to let external traffic into the mesh. One Gateway per logical entry point (often one for the whole cluster). |
| **`VirtualService`** | An L7 route table. Says "given a request that matches this host + path + headers, send it to these destinations with these weights." | Almost every workload that needs anything beyond round-robin Service routing — header-based routing, canary, retries, timeouts, fault injection. |
| **`DestinationRule`** | Per-host policy. Says "for traffic going to this Service: here are named subsets defined by labels, and here is the load-balancing algorithm / connection pool / outlier detection / TLS mode." | When you need named subsets for canary, when you want to tune connection pooling, when you want per-Service mTLS settings. |
| **`ServiceEntry`** | Adds an entry to the mesh's internal service registry for something that is *not* a Kubernetes Service. | When you want to apply mesh policy (timeouts, retries, mTLS to external partners) to traffic to an external HTTP/gRPC/TCP service that lives outside the cluster. |
| **`Sidecar`** (note: the resource, not the proxy) | Limits which other Services a given workload's sidecar knows about. | Large clusters (hundreds of Services). The default behaviour is that every sidecar knows about every Service in the cluster, which costs memory. `Sidecar` resources let you scope it. |
| **`WorkloadEntry`** / **`WorkloadGroup`** | Brings non-Kubernetes workloads (VMs, bare metal) into the mesh as first-class endpoints. | Hybrid migrations — when you have a few legacy VMs that you want to address with the same VirtualServices as your in-cluster services. |

### Security CRDs (the `security.istio.io` API group)

| CRD | Purpose | When you reach for it |
|---|---|---|
| **`PeerAuthentication`** | Configures *transport-level* authentication for service-to-service traffic. The main knob is mTLS mode: `DISABLE` / `PERMISSIVE` / `STRICT`. | When turning on cluster-wide or namespace-wide mTLS (we will do this in W16.4). |
| **`RequestAuthentication`** | Configures *request-level* authentication — i.e., JWT validation. The proxy verifies incoming JWTs against a JWKS URL, and exposes the verified claims to subsequent policies. | When fronting APIs that authenticate end-users with OIDC tokens. |
| **`AuthorizationPolicy`** | L7 authorization rules. Says "service A's identity is allowed to do `GET /api/v1/products/*` on service B; everyone else gets a 403." | Whenever you want zero-trust between services beyond "either side has a cluster cert". W16.4 will use this extensively. |

### Telemetry CRDs (the `telemetry.istio.io` API group)

| CRD | Purpose | When you reach for it |
|---|---|---|
| **`Telemetry`** | Per-namespace or per-workload telemetry configuration: which metrics get emitted, which tracing backends get spans, which access log formats get used. | Customizing what the mesh reports to Prometheus / Jaeger / Loki without globally re-tuning `istiod`. |

### Extension CRDs (the `extensions.istio.io` API group)

| CRD | Purpose |
|---|---|
| **`WasmPlugin`** | Drop a WebAssembly filter into an Envoy proxy's filter chain. Used for custom request handling without forking Envoy. |

That's twelve resources total. You will meet **`Gateway`, `VirtualService`, `DestinationRule`** every single day. **`PeerAuthentication`, `AuthorizationPolicy`** show up the moment you turn on security. The rest are situational.

The mental shortcut for telling these apart:

- **"Where does traffic come in?"** → `Gateway`
- **"Where does traffic go?"** → `VirtualService`
- **"How does it behave going there?"** → `DestinationRule` (LB, pool, outlier detection, TLS mode), plus `VirtualService` again (retries, timeouts, fault injection)
- **"Who is allowed to call whom?"** → `AuthorizationPolicy`
- **"What identity proves this?"** → `PeerAuthentication` (for the transport) or `RequestAuthentication` (for the user)
- **"Tell the mesh about something outside Kubernetes"** → `ServiceEntry` / `WorkloadEntry`

A common student misconception is to look at a `DestinationRule` defining subsets and assume it routes traffic. It does not. The routing rule that says "10% to subset v1, 90% to subset v2" lives in a `VirtualService`; the `DestinationRule` just declares what `v1` and `v2` *are* in label terms.

---

## Part 5 — xDS, in a bit more depth

Step 9 of the bootcamp file introduces `istioctl proxy-status` and its CDS/LDS/EDS/RDS columns. The full xDS family is worth knowing because every Istio operator runs into it eventually.

**xDS** is a family of gRPC APIs originally defined by Envoy. It is the protocol every mesh built on Envoy (Istio, Consul, AWS App Mesh) uses to push configuration from the control plane to the proxies. The family:

| API | Stands for | What it carries |
|---|---|---|
| **CDS** | Cluster Discovery Service | The "clusters": upstream Service groups Envoy knows how to route to. One cluster per (Service, port) combination in the mesh, plus internal ones. |
| **EDS** | Endpoint Discovery Service | The actual pod IPs backing each cluster, including their health and locality. The control plane derives EDS from Kubernetes `EndpointSlice` watches. |
| **LDS** | Listener Discovery Service | The network listeners Envoy opens: which ports, which protocol (HTTP/1, HTTP/2, gRPC, raw TCP), which filter chain. |
| **RDS** | Route Discovery Service | The L7 HTTP route tables that live inside HTTP listeners. Match on host/path/headers → forward to a CDS cluster. |
| **SDS** | Secret Discovery Service | The TLS certs and keys the proxy uses, served as a secret that can be rotated without restarting the proxy. This is how Istio rotates the workload cert every ~12 hours without bouncing the sidecar. |
| **ECDS** | Extension Config Discovery Service | Dynamic configuration of Envoy filter extensions (HTTP filters, WASM plugins). Not commonly used in stock Istio. |

Two things to internalise:

1. **CDS + EDS + LDS + RDS are the "shape" of Envoy's configuration.** When `istioctl proxy-status` says `SYNCED` across those four, the proxy is fully caught up with `istiod`. When it says `STALE`, something is preventing the proxy from receiving updates.
2. **xDS is a *push* protocol over a long-lived gRPC stream.** Each proxy opens one stream to `istiod` and the control plane sends updates whenever something in the mesh changes. There is no polling. Latency from "you `kubectl apply` a VirtualService" to "every proxy has the new route table" is typically under a second in a healthy mesh.

`istioctl proxy-config` is your inspector tool. The subcommands map to the xDS APIs:

```bash
istioctl proxy-config clusters <pod>.<ns>     # CDS view from that proxy
istioctl proxy-config endpoints <pod>.<ns>    # EDS view
istioctl proxy-config listeners <pod>.<ns>    # LDS view
istioctl proxy-config routes <pod>.<ns>       # RDS view
istioctl proxy-config secrets <pod>.<ns>      # SDS view (workload + root certs)
istioctl proxy-config bootstrap <pod>.<ns>    # the static bootstrap config that pilot-agent generated
istioctl proxy-config log <pod>.<ns>          # change Envoy log levels at runtime
```

Whenever a student asks "why is my request returning a 503 / 404 / mTLS error from Istio", the answer is usually in one of those views. The skill of reading `proxy-config` output is the Istio equivalent of reading `kubectl describe`.

---

## Part 6 — The AKS managed Istio add-on, in detail

Microsoft ships a managed Istio add-on for AKS: enable it and Microsoft runs the control plane for you. We did *not* use it in the bootcamp hands-on because the goal there was to see every moving part. For real production work on Azure, the add-on is a strong default. Here is the comparison.

### How it differs from self-install

| Aspect | Self-install with `istioctl` | Managed add-on |
|---|---|---|
| Who runs `istiod` | You. Lives in the `istio-system` namespace, you scale it, you patch it. | Microsoft. The control plane is provisioned in a Microsoft-managed plane; you do not see the pods in your cluster. |
| Version lifecycle | You decide when to upgrade. `istioctl upgrade` is the command. | Microsoft offers supported minor versions (typically the latest two). Upgrades follow Azure's revision lifecycle (canary upgrade, blue-green between revisions, eventual deprecation of the old one). |
| Profiles available | All of them. | The add-on installs a profile equivalent to `default`. No `demo`, no `minimal`, no custom `IstioOperator`. |
| Customization surface | Full `IstioOperator` API. | Limited: Microsoft documents a specific subset of mesh config you can set via `IstioOperator`, the rest is locked down. |
| Gateways | You deploy and manage `istio-ingressgateway` / `istio-egressgateway` yourself. | Managed gateways are a separate add-on feature; you opt in per gateway. |
| Pricing | Free in terms of Microsoft fees (you pay only the compute the control plane runs on). | Included with AKS; you pay the per-cluster AKS fee but not a separate Istio fee. |
| When you'd pick it | Learning, custom mesh requirements, multi-cluster topologies Microsoft does not support, when you need a profile that is not `default`. | Production AKS clusters that want Istio's feature set without owning the operational burden of running the control plane. |

### How to enable it

```bash
az aks mesh enable \
  --resource-group <your-rg> \
  --name <your-cluster>
```

This deploys `istiod-asm-1-XX` to the `aks-istio-system` namespace and registers a revision label (e.g., `asm-1-23`) you put on your namespaces for injection:

```bash
kubectl label namespace bookinfo istio.io/rev=asm-1-23
```

Notice the difference from the self-install: instead of `istio-injection=enabled`, you use `istio.io/rev=<revision>`. The reason is that managed Istio uses **revision-based installs** by default — each version lives in its own `istiod` deployment, namespaces are pinned to a specific revision, and upgrades happen by labelling the namespace with a new revision and rolling its pods. Revisions are how Istio supports zero-downtime upgrades; the managed add-on enforces them.

You can also use revisions on self-installed Istio (`istioctl install --revision=1-30`) and it is generally a good idea for any production-shaped install — we just skipped it in the hands-on for simplicity. The official documentation calls this the "canary upgrade" pattern.

### References

- [Istio-based service mesh add-on for AKS — concepts](https://learn.microsoft.com/en-us/azure/aks/istio-about) — the Microsoft-authored overview.
- [Deploy the Istio-based service mesh add-on for AKS](https://learn.microsoft.com/en-us/azure/aks/istio-deploy-addon) — step-by-step enable / disable / customize.

---

## Part 7 — Running this hands-on locally without Azure

If you want to redo the hands-on at home without paying for AKS, a local Kubernetes cluster works perfectly. Two options:

### Option A — `kind`

```bash
# Install kind: https://kind.sigs.k8s.io/docs/user/quick-start/
kind create cluster --name istio-bookinfo
```

Then start from step 2 of the bootcamp file (install `istioctl`) and continue. To
stand the whole thing up (or tear it down) in one shot for a rehearsal, use the
bundled scripts instead: `./scripts/kind-up.sh` and `./scripts/kind-down.sh`. The only step that differs is **getting the gateway IP**: on kind, the `istio-ingressgateway` Service of type `LoadBalancer` will hang on `<pending>` forever because kind has no cloud provider to allocate an IP. Two workarounds:

```bash
# Workaround 1: use kubectl port-forward instead of the public IP
kubectl port-forward -n istio-system svc/istio-ingressgateway 8080:80
# then http://localhost:8080/productpage
```

```bash
# Workaround 2: install metallb in L2 mode (slightly more setup, gives you a real EXTERNAL-IP)
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.5/config/manifests/metallb-native.yaml
# ...then configure an IPAddressPool with a CIDR from your kind network
```

Trade-off: kind clusters live entirely on your laptop, free, fast. They don't exercise real cloud auth or a real LoadBalancer; the rest of the Istio behaviour is identical.

### Option B — `minikube`

```bash
minikube start --memory=6g --cpus=4
```

`minikube` has a `tunnel` command that emulates a cloud LoadBalancer: run `minikube tunnel` in a separate terminal and `kubectl get svc istio-ingressgateway -n istio-system` will get a real `EXTERNAL-IP`. Closer to the AKS experience than kind for the gateway specifically.

### When local is *not* the same as AKS

These behaviours need a real cluster:

- mTLS to external Azure services (Key Vault, ACR via managed identity).
- Real DNS / TLS certs at the edge.
- Multi-node scheduling decisions (kind/minikube are single-node by default).
- AKS-specific add-ons (Azure Monitor, AGIC, the managed Istio add-on).

For the install + Bookinfo + CRD inspection that this hands-on covers, local is functionally equivalent.

---

## Part 8 — When *not* to use Istio

The lesson covered "what a mesh does not give you" generically. This section is specifically about when Istio is the wrong tool. The bootcamp file is biased toward "Istio is great" because that is what we are teaching; the responsible counterweight is:

### When you should NOT install Istio

- **You have fewer than ~5 microservices.** The footprint is real (one Envoy per pod, ~30–100 MiB and a few percent CPU each), the CRD surface to learn is large, and most of the problems Istio solves don't yet exist at this scale. A monolith plus three services rarely needs a mesh. Reach for Istio when service-to-service is genuinely the bottleneck.
- **Your team has no spare capacity to operate it.** Istio is non-trivial infrastructure. Real production use requires someone who can read `istioctl proxy-config` output, understand xDS, debug Envoy filter chains, and own version upgrades. A small team that is already stretched will find that "we added a service mesh" becomes "we now have a new class of outages we don't understand."
- **You only need one of the mesh's features and there is a lighter way.** Need mTLS but not L7 routing or auth? SPIFFE-only solutions (`spire-server` + `spire-agent`) or a CNI-level mTLS (Cilium's WireGuard-based encryption) might fit better. Need traffic splitting only? `Argo Rollouts` plus Kubernetes Services + a `flagger`-style sidecar can do canary without a mesh. Don't pull in 12 CRDs to solve one problem.
- **You have hard latency budgets in the sub-millisecond range.** Each sidecar hop adds 1–3 ms p99 in stock configurations. For latency-critical paths (HFT, ad-bidding), that is too much. Consider ambient mode or sidecarless meshes (see Part 9) or just keep those services outside the mesh.
- **You run on a platform without strong Envoy support.** This is rare now (Envoy runs everywhere), but if your stack is built around a non-Envoy proxy you already operate, adding Istio is duplicating infrastructure.
- **You can use a managed alternative that solves the actual problem.** Azure Front Door + Application Gateway covers a lot of north-south needs without a mesh. Managed mTLS in service-to-service can be done with Azure Container Apps' built-in Dapr. Pick the lightest tool that solves the actual problem; a mesh is rarely the lightest.

### When Istio IS the right tool

- **10+ microservices, growing.** The point where the L7 traffic management, mTLS, and per-hop telemetry stop being "nice to have" and become "necessary to debug production."
- **Multi-team, multi-language platform.** Teams in Go, Python, Node, Java all need retries / timeouts / circuit breakers in similar ways. Solving that once in the mesh is much cheaper than solving it five times in five HTTP clients.
- **Zero-trust requirements.** Identity-aware authorization between services, mTLS by default, audit logging — Istio's security CRDs hit all three.
- **Existing investment in Envoy or the CNCF ecosystem.** Istio composes with Argo Rollouts, Kiali, Jaeger, Prometheus, KEDA. If you are already in that orbit, Istio fits cleanly.

---

## Part 9 — Ambient mode, in one section

The lesson mentions Istio's **ambient mesh** as the sidecarless alternative. Worth one paragraph because it is the future direction of Istio and you will be asked about it in interviews within the year.

Ambient mode replaces the per-pod sidecar with two new components:

- **`ztunnel`** — a per-node L4 proxy (one DaemonSet on each node). Handles mTLS and identity for every pod on that node. Each pod's connections are intercepted at the node level instead of inside the pod.
- **Waypoint proxies** — optional per-namespace (or per-service-account) Envoy proxies that handle the L7 features (VirtualService routing, AuthorizationPolicy with HTTP path matching, retries, fault injection). Opt in only for namespaces that need L7.

The split lets you pick "just mTLS + identity, no L7 cost" (ztunnel only) or "full mesh" (ztunnel + waypoint) per namespace. The promise is the same feature set with lower overhead — no sidecar per pod, no pod lifecycle weirdness from a second container, no `2/2 Ready` waiting on Envoy.

As of Istio 1.30, ambient mode is **GA**. We use sidecar mode in this hands-on because:

1. Every Istio tutorial, blog post and Stack Overflow answer for the next 12 months still assumes sidecars. The skills transfer; the syntax doesn't change.
2. The concepts (VirtualService, DestinationRule, AuthorizationPolicy) are identical between modes — only what runs the data plane is different.
3. Sidecars are still what >90% of production Istio deployments use today.

When you decide to adopt ambient in production, you will keep the same CRD model, and what changes is the install (`profile=ambient`) and the namespace label (`istio.io/dataplane-mode=ambient` instead of `istio-injection=enabled`). Read the [Istio ambient overview](https://istio.io/latest/docs/ambient/overview/) for the full picture.

---

## Part 10 — Bookinfo in more detail

The bootcamp file describes Bookinfo with a small diagram. A bit more depth, because you will be staring at this app for several lessons:

| Service | Language | Replicas | What it returns |
|---|---|---|---|
| `productpage` | Python (Flask) | 1 | The HTML page. Calls `details` and `reviews` to populate the response. |
| `details` | Ruby | 1 | Book metadata (author, year, ISBN) as JSON. |
| `reviews-v1` | Java (Spring) | 1 | Reviews JSON, no ratings. |
| `reviews-v2` | Java (Spring) | 1 | Reviews JSON, calls `ratings`, renders black stars in HTML. |
| `reviews-v3` | Java (Spring) | 1 | Reviews JSON, calls `ratings`, renders red stars in HTML. |
| `ratings` | Node.js | 1 | Numeric rating as JSON. |

There is one Kubernetes `Service` per logical service. **`reviews` has three Deployments but one Service** — that is the entire reason Bookinfo exists as a teaching app. When you hit `/productpage` repeatedly, the `reviews` Service round-robins across three pods carrying different `version` labels, so you visually see three different reviews blocks. This is what the W16.3 `VirtualService` weights will replace.

A few things students often ask:

- **"Why are v1, v2, v3 written in the same language?"** They're not three different implementations; they're three different versions of the same Spring app. In real life you'd model them as Helm chart releases at different versions, but Istio shows them as three Deployments because that's the shape `DestinationRule.subsets` works with.
- **"Why does v1 not call `ratings`?"** v1 represents "old version of the app, before the ratings feature existed". v2 adds the call but renders the stars in black. v3 represents "design refresh", stars in red. The progression is on purpose so the canary story (W16.3) has something visible to canary *between*.
- **"Why is the productpage Python and the reviews Java?"** Bookinfo deliberately uses four languages to demonstrate that the mesh is language-agnostic — none of the apps know they're meshed, none has Istio-specific code.

The Bookinfo manifests at `manifests/bookinfo/` in this folder are pinned to Istio release-1.30. The upstream URL is in the bootcamp file; the pinned copy here is for when upstream moves (which it does whenever Istio releases a new minor version and shifts the `release-1.30` branch's HEAD).

---

## Cleanup

```bash
kubectl delete -n bookinfo -f manifests/bookinfo/bookinfo-gateway.yaml --ignore-not-found
kubectl delete -n bookinfo -f manifests/bookinfo/destination-rule-all.yaml --ignore-not-found
kubectl delete -n bookinfo -f manifests/bookinfo/bookinfo.yaml --ignore-not-found
kubectl delete namespace bookinfo --ignore-not-found
istioctl uninstall --purge -y
kubectl delete namespace istio-system --ignore-not-found

./scripts/aks-down.sh
```

Or, if you skipped the scripts:

```bash
az group delete --name rg-bootcamp-test-istio-bookinfo --yes --no-wait
```

---

## Discussion questions

Questions a careful reader should be able to answer after working through this hands-on. Useful for instructors preparing for in-class Q&A.

1. The lesson said "the control plane is not in the request path". `istiod` is one pod — what would happen to live productpage requests if you `kubectl delete pod` it for a minute? What would *stop* working in that minute?
2. The mutating webhook injects sidecars only at pod *creation*. You label `default` with `istio-injection=enabled` after a Deployment is already running. What do you have to do to get the existing pods meshed?
3. Why is `DestinationRule` separate from `VirtualService`? Couldn't all the policy live on one resource? What is the design pressure that motivated splitting them?
4. The bootcamp file uses `istioctl install --profile=demo`. The AKS managed add-on installs the equivalent of `default`. List two concrete differences you would experience between those two clusters at runtime.
5. `istioctl proxy-status` shows CDS / LDS / EDS / RDS. If only EDS is `STALE` while the rest are `SYNCED`, what is the most likely cause and what would you look at first?
6. The lesson said "a service mesh is per-route configurable". On Bookinfo as installed today, how would you configure retries with backoff for calls to `ratings` but not for calls to `details`? Which resource(s) would you edit?
7. You enable strict mTLS in `bookinfo` and a Pod from a non-meshed namespace tries to call `productpage`. What does it see? What HTTP error (if any) does it get?
8. You install Istio on a 200-pod cluster. Estimate the additional memory the sidecars contribute, and compare it to the control plane's footprint.

---

## Troubleshooting

| Symptom | Root cause | Fix |
|---|---|---|
| `az aks create` fails with `InsufficientVCPUQuota for family standardBsv2Family` | B-series VM quota disabled in this subscription / region. | Use `Standard_D2s_v3` (the script's default). If you need B-series specifically, request a quota increase. |
| `istioctl install` hangs on `Processing resources for Istiod` then times out | The cluster is too small for `istiod`'s resource requests, or there is no node with available CPU/memory. | Confirm `kubectl get nodes` shows >= 2 nodes Ready and >= 1 vCPU available per node. Re-run after `az aks scale --node-count 2` if needed. |
| Bookinfo pods come up `1/1` instead of `2/2` | Sidecar injection didn't happen. | (a) Confirm `kubectl get ns bookinfo --show-labels` shows `istio-injection=enabled`. (b) Confirm the pod was created *after* the namespace was labelled (delete and recreate the Deployments, or `kubectl rollout restart deploy -n bookinfo`). (c) Confirm `kubectl get mutatingwebhookconfiguration istio-sidecar-injector` exists and is `Active`. |
| Bookinfo pods stuck in `Init:0/1` | `istio-init` init container failing. Usually `NET_ADMIN` capability denied. | On AKS this is allowed by default; if you are on a custom node image or have a strict OPA/Kyverno policy, allow the cap for the `istio-init` container or use [Istio CNI plugin](https://istio.io/latest/docs/setup/additional-setup/cni/) (no init container, programs iptables from the CNI). |
| Bookinfo pods stuck `1/2 Running` for >2 min | The `istio-proxy` sidecar cannot reach `istiod`. Often DNS resolution or a `NetworkPolicy` blocking pod-to-pod egress. | `kubectl logs -n bookinfo <pod> -c istio-proxy` — look for `failed to connect to upstream` errors. Confirm `kubectl get svc istiod -n istio-system` exists. If you have NetworkPolicies, ensure egress from `bookinfo` to `istio-system:15012` is allowed. |
| `istio-ingressgateway` Service `EXTERNAL-IP` stays `<pending>` for >5 min | AKS load balancer cannot provision a public IP. Usually a quota issue (public IP quota), or you are using a private cluster. | `az network public-ip list -g MC_<rg>_<cluster>_<region>` to see the LB attempt. If it's a private cluster, use `kubectl port-forward` to test instead. |
| `curl http://$GATEWAY_IP/productpage` returns `404` | The `Gateway` or `VirtualService` was not applied, or the `VirtualService` does not have `/productpage` in its match list. | `kubectl get gateway,virtualservice -n bookinfo`. Re-apply `manifests/bookinfo/bookinfo-gateway.yaml`. |
| `curl` returns `503 UC` from the gateway | "Upstream Connection" failure. The gateway accepted the request but cannot reach the destination Service. | Usually means the `productpage` Service has no Ready endpoints, or the pods are not in the mesh and the gateway expects mTLS. `kubectl get endpoints productpage -n bookinfo` — should list the productpage pod IP. |
| `curl` returns `503 NR` | "No Route". The gateway has no routing rule that matches the request. | The `VirtualService` `match:` rules don't cover your URL. The default Bookinfo `VirtualService` only matches `/productpage`, `/static/*`, `/login`, `/logout`, `/api/v1/products/*`. Hitting `/` will give NR. |
| Browser shows productpage but the reviews block always says "Sorry, product reviews are currently unavailable" | The `productpage` app can reach `details` but not `reviews`. Usually injection on `reviews-*` pods didn't happen. | `kubectl get pods -n bookinfo -l app=reviews -o wide` — confirm 3 pods, all `2/2 Ready`. If `1/1`, see the injection troubleshooting row above. |
| `istioctl proxy-status` shows one row as `STALE` on CDS or LDS | The proxy hasn't acknowledged the latest config push. Usually transient. | Wait 30 seconds and re-run. If it persists, `kubectl logs -n istio-system deploy/istiod` for the push errors. Sometimes a single proxy hitting a stale version is benign — but if it persists across all proxies, there's something wrong with `istiod`. |
| `istioctl proxy-status` errors out with `no running Istio pods in "istio-system"` | `istiod` is not installed, or you are pointed at the wrong cluster, or the namespace was renamed. | `kubectl get pods -n istio-system`. Re-run `istioctl install --set profile=demo -y` if missing. |
| `istioctl install` complains about `Istio control plane is already installed` | A previous `istioctl install` ran and the same `IstioOperator` is still in place. | `istioctl uninstall --purge -y` first, or run with `--skip-confirmation` if you intentionally want to upgrade. |
| On Windows in Git Bash, paths in `kubectl ... /healthz` get mangled to `C:/Program Files/Git/healthz` | MSYS path conversion treats leading `/` as a Windows path. | `export MSYS_NO_PATHCONV=1` in that shell, or use PowerShell / WSL. |
| `kubectl exec -c istio-proxy -- curl localhost:15000/server_info` returns nothing | The Envoy admin endpoint is not on 15000 — sometimes only listens on the pod IP, not localhost, under custom Sidecar configurations. | Check the sidecar's bootstrap: `istioctl proxy-config bootstrap <pod>.<ns> | grep admin -A 3` will show the admin address. The default is `127.0.0.1:15000`. |
| Pod sees connection refused when calling another in-mesh Service | Possible mTLS mismatch — e.g., one namespace is `STRICT` mTLS and the other is non-meshed. | Check `kubectl get peerauthentication -A`. For this hands-on we don't enable strict mTLS (it's the W16.4 lesson), so the default `PERMISSIVE` mode should make this a non-issue. |

---

## References

### Istio official documentation

- [Istio — Architecture](https://istio.io/latest/docs/ops/deployment/architecture/) — the canonical sidecar-mode architecture page. Part 1 of this README maps to this.
- [Istio — Installation overview](https://istio.io/latest/docs/setup/install/) — landing page for install paths (istioctl, Helm, Operator, managed).
- [Istio — Install with `istioctl`](https://istio.io/latest/docs/setup/install/istioctl/) — what step 3 of the bootcamp file is really doing.
- [Istio — Installation configuration profiles](https://istio.io/latest/docs/setup/additional-setup/config-profiles/) — the full profile catalogue from Part 2.
- [Istio — Sidecar injection](https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/) — the mechanism from Part 3.
- [Istio — Traffic management overview](https://istio.io/latest/docs/concepts/traffic-management/) — the conceptual home of `Gateway`, `VirtualService`, `DestinationRule`.
- [Istio — Security overview](https://istio.io/latest/docs/concepts/security/) — `PeerAuthentication`, `RequestAuthentication`, `AuthorizationPolicy`. We'll use these in W16.4.
- [Istio — Ambient overview](https://istio.io/latest/docs/ambient/overview/) — Part 9 of this README maps to this.
- [Istio — Bookinfo application](https://istio.io/latest/docs/examples/bookinfo/) — the upstream Bookinfo tutorial. We pin our manifests; their docs are the canonical reference.

### Envoy

- [Envoy — What is Envoy?](https://www.envoyproxy.io/docs/envoy/latest/intro/what_is_envoy) — the data plane behind Istio.
- [Envoy — xDS protocol overview](https://www.envoyproxy.io/docs/envoy/latest/api-docs/xds_protocol) — Part 5 of this README maps to this.
- [Envoy — Administration interface](https://www.envoyproxy.io/docs/envoy/latest/operations/admin) — the `:15000` endpoint we curl in step 6.

### Microsoft Azure

- [Istio-based service mesh add-on for AKS — concepts](https://learn.microsoft.com/en-us/azure/aks/istio-about) — Part 6 of this README maps to this.
- [Deploy the Istio-based service mesh add-on for AKS](https://learn.microsoft.com/en-us/azure/aks/istio-deploy-addon) — step-by-step enable / disable / customize for the managed add-on.

### Background

- [SPIFFE — Overview](https://spiffe.io/docs/latest/spiffe-about/overview/) — the workload identity model Istio uses for mTLS.
- [Christian Posta — "What is a Service Mesh and what isn't?" talk recording](https://www.youtube.com/watch?v=cHCXBkjsx70) — a clear, vendor-neutral framing of the trade-offs. Highly recommended after this hands-on.