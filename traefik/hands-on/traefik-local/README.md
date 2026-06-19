# Traefik — dynamic routing on Docker, then on Kubernetes

This is the deep-dive companion to the bootcamp hands-on `week-17/traefik/hands-on/01_traefik_docker_kubernetes.md`. The bootcamp file walks the flow; this README explains the machinery: how the static/dynamic split actually works, what watching the Docker socket means (and what mounting it costs you in security terms), the full anatomy of routing labels, what K3s really does to put Traefik in your cluster and how to bend or remove it, where `Ingress`, `IngressRoute`, and the Gateway API each stand in 2026, and the production ACME shape this local lab cannot demo. Every output below was captured on the tested run (Windows 11, Docker Desktop, Traefik v3.7 for Part A, k3d v5.9 / K3s v1.35.5+k3s1 with bundled Traefik v3.6 for Part B).

## What this folder contains

- `README.md` — this file: the full walkthrough with every detail and tangent
- `commands.sh` — the complete command sequence as a quick reference
- `docker/compose.yaml` — Part A: Traefik v3.7 + two `traefik/whoami` services configured entirely by labels
- `kubernetes/namespace.yaml` — the `traefik-demo` namespace
- `kubernetes/deployment.yaml` — whoami Deployment (2 replicas) + ClusterIP Service
- `kubernetes/ingress.yaml` — the standard `networking.k8s.io/v1` Ingress (host `whoami.k3d`)
- `kubernetes/middleware.yaml` — Traefik `Middleware` CRD adding a response header
- `kubernetes/ingressroute.yaml` — Traefik `IngressRoute` CRD (host `whoami-crd.k3d`) chaining that middleware

## Prerequisites

- Docker Desktop installed and running; host ports 80 and 8080 free
- `k3d` >= 5.8, `kubectl` >= 1.30
- The Traefik lesson (the entrypoint → router → middleware → service model is assumed throughout)

## How to use this folder

```bash
git clone https://github.com/DevOps-Bootcamp-Materials/devops-azure-bootcamp-resources.git
cd devops-azure-bootcamp-resources/traefik/hands-on/traefik-local
```

This README walks the same steps as the bootcamp hands-on but expands every explanation. Read it after the hands-on for full depth, or jump to the part you have questions about.

---

## Part 1 — Static vs dynamic configuration, made concrete

The compose file is small enough to hold in your head, and it draws Traefik's most important architectural line — so read it before running it.

```yaml
services:
  traefik:
    image: traefik:v3.7
    command:
      - --api.insecure=true
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --entrypoints.web.address=:80
    ports:
      - "80:80"
      - "8080:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro

  whoami:
    image: traefik/whoami
    labels:
      - traefik.enable=true
      - traefik.http.routers.whoami.rule=Host(`whoami.localhost`)
      - traefik.http.routers.whoami.entrypoints=web
```

**Everything under `command:` is static configuration** — the frame. It answers three startup questions: which ports does Traefik listen on (`entrypoints.web.address=:80`), where does it learn routes from (`providers.docker=true`), and is the operations API on (`api.insecure=true`)? Static config can come from flags (used here), environment variables (`TRAEFIK_PROVIDERS_DOCKER=true`), or a `traefik.yml` file — three syntaxes, one schema, and the three sources cannot be mixed for the same option. Changing any of it means restarting Traefik. That is acceptable precisely because this layer changes rarely: you do not add entrypoints on Tuesday afternoons.

**Everything in the other containers' `labels:` is dynamic configuration** — the content. Routers, middlewares, services. Traefik never reads these at startup from a file; it *discovers* them, continuously, from the provider. This is the inversion the lesson described: the proxy asks the platform what exists. The payoff comes in Part 4, where the routing table changes at runtime with no process management at all.

Two static flags deserve a second look:

- `--providers.docker.exposedbydefault=false` — without it, **every container on the host** becomes routable under a default rule (``Host(`{container-name}`)``). On a laptop that is merely surprising; on a shared host it is an incident. Opt-in via `traefik.enable=true` is the only sane default. Make this muscle memory.
- `--api.insecure=true` — serves the dashboard and API on a dedicated `traefik` entrypoint (:8080) with **no authentication**. Fine on localhost for learning; in production you either keep it off or expose the dashboard through a normal router protected by middlewares (`basicAuth`, IP allowlist) — the dashboard docs show the pattern. The dashboard is read-only, but it enumerates your entire routing topology, backend addresses included; treat it as sensitive.

**Misconception: "Traefik has no configuration files."** It can use them — the file provider feeds dynamic config from watched YAML, and static config can live in `traefik.yml`. The accurate claim is narrower and more interesting: *routing* configuration does not have to live in any file you maintain, because providers generate it from platform state.

---

## Part 2 — The Docker provider: how discovery works, and what the socket costs

```yaml
volumes:
  - /var/run/docker.sock:/var/run/docker.sock:ro
```

This one line is the entire discovery mechanism. `/var/run/docker.sock` is the Unix socket the Docker daemon serves its HTTP API on — the same API the `docker` CLI uses. With it mounted, Traefik does at startup what `docker ps` does, then subscribes to the event stream (`docker system events` shows you the same feed): container started, container died, container's labels say X. Each event triggers a recalculation of the dynamic configuration. There is no polling loop to tune and no cache to invalidate; the latency from `docker compose up` to "route live" is however long the event takes to arrive plus a few milliseconds of rebuild — observed in Part 4 as roughly a second end to end.

(On Docker Desktop for Windows, the compose file's socket path works even though Windows itself has no Unix sockets — the path is resolved inside the WSL2 VM where the daemon actually runs. The same line works unchanged on Linux and macOS, which is why it is written this way.)

### The security bill

The Docker socket is not a metrics endpoint — it is **root-equivalent control of the host**. Anything that can write to it can start a privileged container with the host filesystem mounted, and at that point the game is over. So "mount the socket into the proxy" deserves scrutiny, because the proxy is by definition the component exposed to the internet.

Graded mitigations, weakest to strongest:

1. **`:ro` (what this lab uses).** Honest assessment: it helps less than it appears to. The `ro` flag makes the socket *file* read-only (blocks unlink/rename), but the API conversation over it is read-write — a compromised container could still POST `/containers/create`. Why include it anyway? It documents intent and blocks crude attacks; it is the floor.
2. **A socket proxy.** Run a tiny filtering proxy (the standard one is [Tecnativa/docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy)) that exposes only the GET endpoints Traefik needs (`/containers`, `/events`, `/version`) and denies everything else, then point Traefik at it over TCP: `--providers.docker.endpoint=tcp://socket-proxy:2375`. The raw socket is mounted only into the proxy container, which is not internet-facing. This is the widely recommended production pattern for Docker hosts.
3. **Rootless Docker / Podman.** The socket then maps to an unprivileged user, capping the blast radius at that user's permissions.
4. **Not using the Docker provider at all** — on Kubernetes (Part B) Traefik talks to the API server with a scoped RBAC ServiceAccount, and this entire problem class disappears. The socket question is specifically the single-Docker-host deployment's trade-off.

**Misconception: "Traefik needs the socket to route traffic."** No — only to *discover* it. Traffic flows over the compose network directly to container IPs. If discovery came from elsewhere (the file provider, say), no socket would be needed; the mount is the price of the Docker provider specifically.

---

## Part 3 — Label anatomy, and reading the discovered state back

### The label grammar

Every Traefik label is a path into the dynamic-configuration tree:

```
traefik.http.routers.<router-name>.rule          = Host(`whoami.localhost`)
traefik.http.routers.<router-name>.entrypoints   = web
traefik.http.routers.<router-name>.middlewares   = taught-by
traefik.http.middlewares.<mw-name>.headers.customresponseheaders.X-Taught-By = Traefik
traefik.http.services.<svc-name>.loadbalancer.server.port = 8080   # only when the app's port isn't detectable
```

Read them as: protocol (`http`/`tcp`/`udp`) → object type (`routers`/`middlewares`/`services`) → **your chosen name** → property. The names are declarations, not references to anything pre-existing: writing `traefik.http.routers.whoami.rule` *creates* a router named `whoami`. The same grammar appears in the file provider as nested YAML and in Kubernetes as CRD fields — one schema, three serializations. This is why the lesson insists the model is learned once.

What you usually do **not** write is the service: Traefik auto-generates one per group of containers and wires the router to it (a router with exactly one service in scope binds automatically). You only write `services.` labels to override — the classic case being a container exposing several ports, where Traefik cannot guess which one to balance to.

Rule syntax worth knowing beyond `Host()`: ``PathPrefix(`/api`)``, ``Path(`/exact`)``, `HostRegexp(...)`, combined with `&&`/`||` and negated with `!`. Routers also take a `priority` (longer rules win by default — you saw computed priorities 22/24 in the API output, derived from rule length).

### The dashboard API: discovered state as JSON

```bash
curl -s http://localhost:8080/api/http/routers
```

**Output (the two Docker-provided routers, formatted):**

```json
{"entryPoints":["web"], "service":"whoami-docker", "rule":"Host(`whoami.localhost`)",
 "priority":24, "status":"enabled", "name":"whoami@docker", "provider":"docker"}
{"entryPoints":["web"], "middlewares":["taught-by@docker"], "service":"echo-docker",
 "rule":"Host(`echo.localhost`)", "priority":22, "status":"enabled", "name":"echo@docker", "provider":"docker"}
```

The endpoints worth bookmarking — these answer "what does Traefik *think* is configured", which is the first question in any debugging session:

| Endpoint | Returns |
|---|---|
| `/api/overview` | Counts and health per protocol, enabled providers |
| `/api/entrypoints` | The listening ports (static config, reflected) |
| `/api/http/routers` | All routers, their rules, status, attached middlewares |
| `/api/http/routers/whoami@docker` | One router in full |
| `/api/http/services` | Services with their backend server lists and health |
| `/api/http/middlewares` | All middlewares and their settings |
| `/api/version` | Traefik version |
| `/dashboard/` | The UI rendering of all of the above |

Naming convention throughout: `name@provider`. The suffix matters as soon as multiple providers coexist (Part B runs `kubernetes-ingress` and `kubernetes-crd` side by side; `whoami@docker` and a hypothetical `whoami@file` are different routers). The two `@internal` routers you also get (`api@internal`, `dashboard@internal`) are Traefik exposing its own API through its own model — `--api.insecure=true` is really just sugar for creating those on a dedicated entrypoint.

Service naming for the Docker provider: containers are grouped by compose service, and the Traefik service is named `<compose-service>-<compose-project>` — our project (the folder) is `docker`, hence `whoami-docker`. The grouping is the load-balancing unit, which is exactly what the next part exploits.

---

## Part 4 — Scaling: what actually happens in that one second

```bash
docker compose up -d --scale whoami=3
curl -s http://whoami.localhost | grep Hostname   # x6
```

**Output (verified):**

```
Hostname: cff68478136d
Hostname: 21c418839d7d
Hostname: cdc99f6f5813
Hostname: 21c418839d7d
Hostname: cdc99f6f5813
Hostname: cff68478136d
```

The sequence under the hood:

1. Compose creates `docker-whoami-2` and `docker-whoami-3`. Labels are part of the service definition, so the new containers carry them automatically — *labels scale with replicas*; nobody re-declares anything.
2. The Docker daemon emits `container start` events on the socket.
3. Traefik's provider receives them, sees `traefik.enable=true` plus the same router/service identity, and rebuilds the dynamic config: the `whoami-docker` service now has three server entries (the three container IPs on the compose network).
4. New requests round-robin across all three. Established connections are untouched — there was no reload, so there is nothing to drain or re-establish. This is the structural advantage over reload-based proxies: configuration change and connection handling are decoupled.

Round-robin is the default and only the start: Traefik services also support weighted round-robin (canary by percentage), sticky sessions via cookie, health checks that eject failing backends, and mirroring. All of it is dynamic config — labels here, CRD fields in Kubernetes.

### The convergence window (we hit it)

Scaling **down** has a hard edge scaling up does not: for the instant between "container is being removed" and "event processed", Traefik can still route to the dying backend. In our test, a curl fired in the same second as `--scale whoami=1` failed once; the next request was fine. Window observed: well under a second. Production handling: graceful shutdown in the app (finish in-flight requests on SIGTERM), retry middleware (`traefik.http.middlewares.retry...`) for idempotent routes, and health checks to shrink the window. Kubernetes narrows the same race further with readiness gates and endpoint propagation — but it exists there too; it is distributed-systems physics, not a Traefik bug.

**Misconception: "the dashboard shows it, therefore traffic flows."** The dashboard shows *control-plane* state — what Traefik believes. A backend can be discovered yet unreachable (wrong internal port, app not listening yet, network partition). Data-plane truth comes from requests; with health checks enabled the service view shows per-server health, which closes most of the gap.

---

## Part 5 — K3s's bundled Traefik: the HelmChart machinery

Part B's cluster came with Traefik running before you applied anything. The mechanism is worth understanding because you will meet it on every K3s/k3d cluster you ever touch.

```bash
kubectl get pods -n kube-system
```

**Output (verified, ~30s after create):**

```
NAME                                      READY   STATUS      RESTARTS   AGE
coredns-8db54c48d-c6w6l                   1/1     Running     0          33s
helm-install-traefik-4grpz                0/1     Completed   1          30s
helm-install-traefik-crd-z2c25            0/1     Completed   0          30s
local-path-provisioner-5d9d9885bc-bz6dt   1/1     Running     0          33s
metrics-server-786d997795-nvlr7           1/1     Running     0          33s
svclb-traefik-867d1476-dqnz2              2/2     Running     0          17s
svclb-traefik-867d1476-rrjdf              2/2     Running     0          17s
traefik-9bcdbbd9-4p9r7                    1/1     Running     0          17s
```

K3s embeds a **Helm controller**: any `HelmChart` custom resource in the cluster gets reconciled into an installed chart by a job. K3s drops two such resources at startup — see them:

```bash
kubectl get helmcharts -n kube-system
```

```
NAME          CHART
traefik       https://%{KUBERNETES_API}%/static/charts/traefik-39.0.701+up39.0.7.tgz
traefik-crd   https://%{KUBERNETES_API}%/static/charts/traefik-crd-39.0.701+up39.0.7.tgz
```

The charts are *bundled inside the K3s binary* and served from the API server's static path — the install works fully offline. Two charts because CRDs must exist before objects of their kinds can be applied: `traefik-crd` installs the CRD definitions, `traefik` installs the controller. That ordering is also why you may catch `helm-install-traefik` in `Error` status with a restart count: it raced the CRD job, failed, retried, completed. Expected, not a problem — and worth knowing so you do not "fix" it.

The bundled version lags upstream deliberately (stability over freshness): this K3s (v1.35.5+k3s1) ships chart 39.0.7 running `rancher/mirrored-library-traefik:3.6.13` — Traefik v3.6 while Part A used v3.7. Same major, same model, same CRD apiVersion.

### Customizing it: HelmChartConfig, not kubectl edit

Editing the Traefik Deployment directly is futile — the Helm controller reconciles it back. The supported path is a `HelmChartConfig` resource whose values merge into the bundled chart:

```yaml
# /var/lib/rancher/k3s/server/manifests/traefik-config.yaml on a real K3s node,
# or just kubectl apply it
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    additionalArguments:
      - "--log.level=DEBUG"
      - "--accesslog=true"
```

Any value from the upstream Traefik chart goes in `valuesContent` — dashboard exposure, replica count, resource limits, extra entrypoints. The Helm controller notices the change and re-runs the install job with merged values.

### Removing it

Sometimes you want no Traefik (parity with a cluster running something else, or installing your own newer Traefik chart). K3s takes `--disable traefik`; through k3d:

```bash
k3d cluster create lean --k3s-arg "--disable=traefik@server:0"
```

The cluster then behaves like kind: no IngressClass until you install a controller. With it disabled you can `helm install traefik traefik/traefik` yourself and control the version — the common choice on K3s clusters that want current Traefik features.

One more piece of the Part B path worth naming: the `svclb-traefik` pods are **ServiceLB** (klipper-lb) exposing Traefik's `LoadBalancer` Service on every node's host network — that is how `--port "8080:80@loadbalancer"` ultimately reaches Traefik, and why the Ingress ADDRESS column showed the node IPs (`192.168.80.3,192.168.80.4`). The k3d deep-dive README covers ServiceLB exhaustively.

---

## Part 6 — Ingress vs IngressRoute vs Gateway API

Part B deliberately routed the same app twice. Here is the full positioning behind that choice.

### Standard Ingress (`networking.k8s.io/v1`) — the `kubernetes-ingress` provider

Traefik watches Ingress objects like any ingress controller and translates them into its model: rule → router, backend Service → Traefik service. Strengths: it is *the* portable API — every controller speaks it, every tutorial and chart emits it, and on K3s it works with zero installs (verified in B2: apply, curl, done). Weakness: the schema is frozen at host/path/backend/TLS-secret. It cannot express a header transformation, a retry policy, a canary weight, or a TCP route. Historically every controller papered over this with annotations — stringly-typed, unvalidated, controller-specific. The `nginx.ingress.kubernetes.io/*` annotations in half the tutorials on the internet are exactly that, and they are no-ops under Traefik.

(Traefik does also accept annotations on Ingress objects — e.g. `traefik.ingress.kubernetes.io/router.middlewares: traefik-demo-taught-by@kubernetescrd` would attach our middleware to the standard Ingress. Note the mandatory `<namespace>-<name>@kubernetescrd` form; forgetting the namespace prefix is a classic silent failure. The hands-on uses the CRD route instead because typed objects are the pattern worth learning.)

### IngressRoute (`traefik.io/v1alpha1`) — the `kubernetes-crd` provider

Traefik's native resources expose the full model as typed, schema-validated Kubernetes objects: `IngressRoute` (+ TCP/UDP variants), `Middleware`, `TraefikService` (weighted/mirrored), `ServersTransport`, `TLSOption`. What the types buy over annotations in an organization: `kubectl apply` rejects malformed specs instead of silently ignoring them; RBAC can grant an app team `IngressRoute` in their namespace while platform owns `Middleware`; `kubectl explain ingressroute.spec` documents the schema. Cost: vendor lock-in — an `IngressRoute` means nothing to any other proxy, so migrating away becomes a rewrite. That is the trade: expressiveness now, portability later.

Namespace rule that bites people: a `Middleware` referenced from an `IngressRoute` must live in the **same namespace** unless the provider runs with `allowCrossNamespace=true` (off by default, deliberately — cross-namespace references are a privilege-escalation surface). Our `taught-by` middleware sits in `traefik-demo` next to its IngressRoute for exactly this reason.

apiVersion history, because old tutorials will betray you: the group was `traefik.containo.us/v1alpha1` until Traefik v2.x renamed it to `traefik.io/v1alpha1` (the old group died with v3). Manifests carrying the old group fail with `no matches for kind "IngressRoute"`. Truth source on any cluster: `kubectl get crd ingressroutes.traefik.io -o jsonpath='{.spec.versions[*].name}'` — on our cluster: `v1alpha1` under `traefik.io`, matching these manifests.

### Gateway API — the standards-track resolution

The Kubernetes project's successor to Ingress: `GatewayClass`/`Gateway`/`HTTPRoute` as standard typed resources with the expressiveness Ingress lacked (header matching and filters, traffic splitting, cross-namespace delegation with explicit grants) — portable across implementations like Ingress, expressive like vendor CRDs. Traefik v3 implements it (`--providers.kubernetesgateway`). 2026 reading: it is where the ecosystem is heading, accelerated by the ingress-nginx retirement, but the annotation-era installed base is enormous, so all three APIs will coexist for years. Practical guidance: existing Ingress keeps working — don't rewrite for sport; need Traefik-specific power today — IngressRoute, eyes open about lock-in; new platform with implementation-independence as a goal — evaluate Gateway API first.

The B4 output is the migration story in one screen: one Traefik, both providers active, both routes serving — adopt the richer API per-route, no big bang.

---

## Part 7 — ACME / Let's Encrypt: the production shape

This lab is HTTP-only: Let's Encrypt must reach your endpoint on a public domain to validate, which localhost cannot offer. But the production configuration is short enough to read here and recognize later. Static config (the frame — a TLS entrypoint and a certificate resolver):

```yaml
# traefik.yml (or the equivalent flags)
entryPoints:
  web:
    address: ":80"
    http:
      redirections:           # global HTTP -> HTTPS
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"

certificatesResolvers:
  le:
    acme:
      email: you@example.com
      storage: /letsencrypt/acme.json    # mount a volume; chmod 600
      httpChallenge:
        entryPoint: web                  # or tlsChallenge: {} / dnsChallenge for wildcards
```

Dynamic config (per route, labels or CRD alike):

```yaml
labels:
  - traefik.http.routers.whoami.rule=Host(`whoami.example.com`)
  - traefik.http.routers.whoami.entrypoints=websecure
  - traefik.http.routers.whoami.tls.certresolver=le
```

That last label is the whole user-facing API: Traefik sees a TLS router with a resolver, checks `acme.json`, performs the challenge if needed, obtains the certificate, and renews it ~30 days before expiry — no certbot, no cron, no reload. Challenge choice in one line each: `httpChallenge` needs port 80 reachable; `tlsChallenge` does it on 443; `dnsChallenge` needs DNS-provider API credentials and is the only way to wildcards. Two operational notes that save real pain: `acme.json` is state — persist it (a container recreate without the volume re-issues every cert, and Let's Encrypt rate-limits you: 50 certs/domain/week); and develop against the LE *staging* CA server first (`caServer: https://acme-staging-v02.api.letsencrypt.org/directory`) so a config loop does not burn the production quota. On Kubernetes, cert-manager fills this role with more flexibility (and is what the bundled K3s Traefik pairs with, since its ACME state would need a PVC anyway); for a single Docker host, built-in ACME remains the simplest TLS story there is.

---

## Cleanup

```bash
cd docker && docker compose down && cd ..   # Part A (also removes the compose network)
k3d cluster delete traefik-demo             # Part B (cluster, containers, kubeconfig context)
docker image rm traefik:v3.7 traefik/whoami # optional: reclaim the pulled images
```

Verified: `k3d cluster list` empty afterwards; nothing survives either part.

---

## Discussion questions

1. Scaling `whoami` to 3 changed Traefik's routing with no restart, yet adding an HTTPS entrypoint would require one. Draw the static/dynamic line precisely and explain *why* the architecture puts entrypoints on the static side.
2. The compose file mounts `docker.sock` read-only. Explain why `:ro` does not prevent a compromised Traefik from starting containers, and how the socket-proxy pattern actually does. What changes about this whole threat model on Kubernetes?
3. In Part A the middleware was two labels; in Part B it was a `Middleware` object plus a reference. List three concrete things the Kubernetes platform can do with the typed object that it cannot do with an annotation string.
4. `curl -H "Host: whoami-crd.k3d"` returned 404 for a few seconds after `kubectl apply`, then 200. Which components and watch loops sit between `kubectl apply` and "route live"? Compare the propagation path with Part A's Docker-event path.
5. Your team edits the Traefik Deployment in `kube-system` on a K3s cluster to add a flag, and the change keeps reverting. What is reverting it, and what is the supported way to make the change stick?
6. A teammate proposes converting all existing `Ingress` objects to `IngressRoute` "for consistency" during a Traefik migration. Argue both sides using the lock-in/expressiveness trade-off, and state what the Gateway API changes about the decision.

## Troubleshooting

| Symptom | Root cause | Fix |
|---|---|---|
| `docker compose up` → `Bind for 0.0.0.0:80 failed: port is already allocated` (or 8080) | Another container or host service (IIS, dev server, another proxy) holds the port | Find it (`docker ps`, then host services) and stop it, or remap (`"8000:80"`) and adjust URLs |
| `curl http://whoami.localhost` → could not resolve host | `*.localhost` → loopback (RFC 6761) holds on Windows/macOS hosts and modern browsers, but not in every resolver — notably from inside a WSL2 distro or some Linux setups | `curl -H "Host: whoami.localhost" http://localhost`, or add a hosts-file entry |
| Traefik answers `404 page not found` on a route you expect | No router matched: missing `traefik.enable=true` (with `exposedbydefault=false`), Host typo, or wrong entrypoint | `curl -s localhost:8080/api/http/routers` — if the router is absent, fix labels; if present, compare its rule against the exact Host you send |
| `X-Taught-By` header missing in Part A | Router/middleware name mismatch in labels — the chain label references a name that was never defined (silent failure) | Names in `routers.echo.middlewares=taught-by` and `middlewares.taught-by...` must match; check `/api/http/middlewares` |
| One failed request right after `--scale whoami=1` | Convergence window: request raced the container removal | Retry — sub-second. Production: graceful shutdown + retry middleware + health checks (Part 4) |
| `helm-install-traefik` pod shows `Error` / restarts in kube-system | Raced the `traefik-crd` job; retries by design | Wait — `kubectl wait --for=condition=complete job --all -n kube-system --timeout=240s` |
| `curl -H "Host: whoami-crd.k3d"` → 404 right after apply | Traefik's CRD watch had not propagated yet (observed: ~5 s) | Retry. If persistent: `kubectl describe ingressroute -n traefik-demo`, and confirm `entryPoints: [web]` — `web`/`websecure` are the bundled Traefik's entrypoint names |
| IngressRoute routes, but its middleware does nothing | `Middleware` in a different namespace; cross-namespace refs are off by default | Co-locate middleware and IngressRoute, or set `allowCrossNamespace=true` via HelmChartConfig knowingly |
| Middleware on a standard Ingress annotation does nothing | Annotation needs the full form `<namespace>-<name>@kubernetescrd` | e.g. `traefik.ingress.kubernetes.io/router.middlewares: traefik-demo-taught-by@kubernetescrd` |
| `no matches for kind "IngressRoute" in version "traefik.containo.us/v1alpha1"` | Pre-v3 API group from an old tutorial | Use `traefik.io/v1alpha1`; verify with `kubectl get crd ingressroutes.traefik.io` |
| `nginx.ingress.kubernetes.io/*` annotations ignored | Controller is Traefik; nginx annotations are foreign | Express the behavior as Traefik middleware, or run ingress-nginx instead (disable bundled Traefik, Part 5) |
| Dashboard reachable from other machines on your network | `--api.insecure=true` binds 8080 on all interfaces via the port mapping | Local learning only. Production: drop the flag, expose `api@internal` through a router + auth middleware |
| `curl localhost:8080` connection refused in Part B | Cluster created without the `--port` mapping (it is creation-time), or Part A's stack still holds 8080 | `docker compose down` the Part A stack; recreate the cluster with the mapping |

## References

- [Traefik — Docker provider](https://doc.traefik.io/traefik/providers/docker/) — label reference, `exposedByDefault`, endpoint options, the socket discussion
- [Traefik — Providers overview](https://doc.traefik.io/traefik/providers/overview/) — the discovery model and the full provider list
- [Traefik — Routers](https://doc.traefik.io/traefik/routing/routers/) — rule syntax, priorities, entrypoint binding
- [Traefik — Middlewares overview](https://doc.traefik.io/traefik/middlewares/overview/) — the full middleware catalog for HTTP and TCP
- [Traefik — Dashboard and API](https://doc.traefik.io/traefik/operations/dashboard/) — securing the dashboard properly, beyond `api.insecure`
- [Traefik — Kubernetes Ingress provider](https://doc.traefik.io/traefik/providers/kubernetes-ingress/) — how standard Ingress objects are consumed, supported annotations
- [Traefik — Kubernetes CRD provider](https://doc.traefik.io/traefik/providers/kubernetes-crd/) — IngressRoute/Middleware reference, `allowCrossNamespace`
- [Traefik — Kubernetes Gateway provider](https://doc.traefik.io/traefik/providers/kubernetes-gateway/) — Traefik's Gateway API implementation
- [Traefik — Let's Encrypt / ACME](https://doc.traefik.io/traefik/https/acme/) — resolvers, challenge types, storage, the staging CA
- [K3s — Helm controller](https://docs.k3s.io/helm) — HelmChart and HelmChartConfig, the mechanism that installs and customizes the bundled Traefik
- [K3s — Networking services](https://docs.k3s.io/networking/networking-services) — the bundled Traefik and ServiceLB, including how to disable both
- [traefik/whoami](https://github.com/traefik/whoami) — the echo server used throughout; its output fields explained
- [Tecnativa/docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy) — the filtering proxy for the socket-exposure pattern (Part 2)
