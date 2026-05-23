# GitOps — Install Argo CD on AKS and deploy your first Application

The deep-dive companion to [`week-15/gitops/hands-on/01_argocd_install_and_first_app.md`](https://github.com/DevOps-Bootcamp-Materials/devops-azure-bootcamp/blob/main/week-15/gitops/hands-on/01_argocd_install_and_first_app.md) in the bootcamp repo. The bootcamp file is the in-class teaching script and also enough on its own to install Argo CD, deploy the guestbook, and see drift get reverted. This README is what to read **after** that, when you want the whole picture: every Argo CD pod explained, the exposure options you skipped, the RBAC model, the timing of the reconciliation loop, the misconceptions students keep hitting, and a troubleshooting table for the install itself.

## What this folder contains

- `README.md` — this file: the full reference walkthrough plus the discussions the bootcamp file deferred.
- `applications/guestbook.yaml` — the declarative `Application` from step 7 of the bootcamp hands-on. Cloneable as-is.
- `scripts/aks-up.sh` — wrapper around the `az` commands from step 1 of the bootcamp file. Idempotent, parametrised by env vars.
- `scripts/aks-down.sh` — counterpart to `aks-up.sh`. Tears down the resource group.

## Prerequisites

- Azure subscription with permission to create AKS + resource groups.
- `az` CLI (>=2.60), logged in (`az login`, `az account show`).
- `kubectl` (1.28+).
- The `argocd` CLI (step 4 of the bootcamp file installs it).
- Read the W15.3 lesson first (`week-15/gitops/lessons/01_intro_to_gitops.md`). The four-principles vocabulary is used here without re-explaining.

## How to use this folder

```bash
git clone https://github.com/DevOps-Bootcamp-Materials/devops-azure-bootcamp-resources.git
cd devops-azure-bootcamp-resources/gitops/hands-on/argocd-first-app
```

You can either follow the bootcamp file end-to-end and dip into this README only where it says "see the full treatment in the resources README", or read this file in order if you already know the basics and want depth without ceremony.

---

## Part 1 — Why we install on AKS at all

The bootcamp file walks the `az aks create` without dwelling on it. Worth dwelling now: every GitOps demo you find online installs Argo CD on `kind`, `minikube` or `k3d`. Those are excellent for a 60-second look. The reason we use AKS instead, for this bootcamp:

- **Real cloud auth and identity.** The moment you want Argo CD to deploy an app that pulls from ACR, or reads a Key Vault secret, or talks to managed Postgres, you need a real Kubernetes cluster on a real cloud. We will not exercise that in this hands-on but the rest of week 15 will, and re-doing the install on a different substrate is a waste of time.
- **The "ServiceAccount-based deploy" story is real.** On `kind`, RBAC is trivial because everything is local. On AKS, the `argocd-application-controller` actually runs under a ServiceAccount whose token is mounted from a Kubernetes Secret, and the API server actually verifies that token on every apply. The credential story in the lesson lands harder when the cluster is genuinely remote.
- **Cost.** One `Standard_B2s` for 90 minutes of class is on the order of cents. Acceptable.

If you are running through this on your own and want to skip Azure, `kind create cluster` will work — every step from step 2 onwards is identical. The trade-off is you miss the genuine "deploy on a real cluster" feeling, and you cannot reuse the same cluster for W15.5 and W15.6.

### Why `Standard_D2s_v3` and one node

The Argo CD install footprint, warm, with one guestbook app, is roughly:

| Component | Memory | CPU (idle) |
|---|---|---|
| `argocd-application-controller` | ~250 MiB | ~10m |
| `argocd-repo-server` | ~100 MiB | ~5m |
| `argocd-server` | ~80 MiB | ~5m |
| `argocd-redis` | ~30 MiB | ~3m |
| `argocd-dex-server` | ~30 MiB | ~3m |
| `argocd-applicationset-controller` | ~50 MiB | ~3m |
| `argocd-notifications-controller` | ~40 MiB | ~3m |
| Guestbook (1 Deployment, 1 replica) | ~10 MiB | ~1m |
| AKS system pods (kube-system) | ~600 MiB | ~50m |
| **Total** | **~1.2 GiB** | **~85m** |

`Standard_D2s_v3` is 2 vCPU / 8 GiB. Comfortable headroom. If you turn on Prometheus + Grafana from W15.1 on the same cluster, jump to two nodes — three would be safer.

**Why not the cheaper B-series?** The natural pick for a small demo cluster would be a burstable `Standard_B2s` (2 vCPU / 4 GiB). On many IronHack-provisioned Azure subscriptions, however, the B-series quota in West Europe is set to 0 vCPU and `az aks create` fails with `InsufficientVCPUQuota`. `Standard_D2s_v3` is in the general-purpose D-series family which is always enabled. The hourly cost is within ~10% of B2s — not enough to justify a quota-increase ticket for a 90-minute class. If you have B-series quota and prefer it, swap the size in `aks-up.sh`.

---

## Part 2 — The seven Argo CD pods, in detail

Step 2 of the bootcamp file lists them and gives a one-line role each. Here is the full story.

### `argocd-application-controller` (StatefulSet, 1 replica by default)

The brain. The control loop. Imagine it as a `for` loop that runs forever:

```
loop:
  for each Application:
    desired_state = repo_server.render(app.repoURL, app.path, app.targetRevision)
    cluster_state = kube_api.list_for_namespace(app.destination.namespace)
    diff = compute_diff(desired_state, cluster_state)
    update_status(app, sync = diff.is_empty() ? Synced : OutOfSync, diff = diff)
    if app.syncPolicy.automated and not diff.is_empty():
       apply(diff)
    sleep_until_next_tick()
```

A few details that matter when you debug a slow or stuck `Application`:

- It is a **StatefulSet** (not a Deployment) because each replica owns a *shard* of the application set when you scale it up. Shard 0 of N reconciles applications whose name hashes to that shard. For class scale (a handful of apps), one replica is fine. At hundreds of applications, you bump replicas and let sharding distribute the load.
- It maintains an **in-memory cache of cluster state** for every namespace it watches, populated by a `watch` against the API server (not a poll). When you `kubectl edit` a Deployment, the controller knows within milliseconds — the watch event lands first.
- The **Git poll**, by contrast, is on a timer. Default 3 minutes (`timeout.reconciliation` in `argocd-cm`). This is the lag you see when a git commit takes a few minutes to show up unless you click *Refresh* in the UI. We will revisit this in Part 6.

### `argocd-repo-server` (Deployment, 1 replica by default)

The eyes. Stateless. Its job:

- Clone (or pull) a Git repository.
- Run whatever rendering tool the `Application` specifies: nothing for plain YAML, `helm template` for Helm sources, `kustomize build` for Kustomize, or a custom plugin for Jsonnet/Pulumi/etc.
- Return the rendered manifests to the controller.

Two consequences worth knowing:

- **No state.** You can scale it to 3+ replicas freely; the controller calls them round-robin.
- **Where Helm and Kustomize binaries live.** They are baked into the `argocd-repo-server` image. The official image ships with current versions of both. If you need a specific Helm version, you swap the image or use the `helm-with-version` pattern from the docs. Custom plugins live as sidecars on this pod.

### `argocd-server` (Deployment, 1 replica)

The mouth. Two things:

- Serves the **web UI** (static React app) on `:8080`.
- Serves the **gRPC + REST API** on the same port. The `argocd` CLI, every UI click, and every external integration goes through it.

The UI talks to the API on the same port via the same TLS connection. That is why `kubectl port-forward svc/argocd-server 8080:443` exposes both at once.

In production you put an Ingress / LoadBalancer in front of this pod and terminate TLS there. Internal cluster traffic from the controller to the API server does *not* go through `argocd-server`; they share the database (Redis) and the API server is for outside-facing clients only.

### `argocd-redis` (Deployment, 1 replica)

Cache. Used by `argocd-server` and `argocd-repo-server` to memoize rendered manifests, cluster state listings, and session data. **Not load-bearing for correctness.** If Redis dies, performance degrades and some UI refreshes get slow; the controller still reconciles.

You can plug in a real Redis (managed Azure Cache for Redis, for instance) for HA. For class, the bundled single-replica deployment is fine.

### `argocd-dex-server` (Deployment, 1 replica)

OIDC bridge. Idle in our install — we use the local `admin` user.

Once you turn on SSO via GitHub, Azure AD, Google, GitLab, etc., Dex becomes the thing that takes a corporate identity token and exchanges it for an Argo CD session. If you remove Dex and use Argo CD's built-in OIDC client instead, the same flow works without the proxy. Both are common in production.

### `argocd-applicationset-controller` (Deployment, 1 replica)

Templating for `Application` objects. Takes one `ApplicationSet` resource and generates N concrete `Application` resources from it. Used for two patterns:

- One app, many clusters (deploy `web` to every cluster matching a label).
- Many apps, one cluster (one Application per folder under `apps/`).

We will use this in W15.5. For W15.4 it is just running.

### `argocd-notifications-controller` (Deployment, 1 replica)

Sends notifications (Slack, email, MS Teams, generic webhooks) when sync events happen. Out of scope here. Common production use: post to Slack on every `Synced → OutOfSync` transition.

---

## Part 3 — Exposing the UI: port-forward, LoadBalancer, or Ingress?

The bootcamp file uses `kubectl port-forward` because it avoids dragging Azure networking into a GitOps hands-on. In real life you almost always want one of the other two.

### Port-forward (what we use in class)

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

- **Pros:** Zero Azure cost. No public IP. Authentication via `kubectl` credentials. Works behind a corporate proxy.
- **Cons:** One terminal blocked. URL is `localhost:8080` so any tooling that expects a stable hostname (webhooks, OIDC callbacks) does not work. Stops when your laptop sleeps.
- **When to pick it:** Class, demos, debugging a remote cluster from your laptop.

### LoadBalancer Service (the cheap public-IP path)

Edit the Service:

```bash
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'
kubectl get svc argocd-server -n argocd -w
```

After ~30–60 seconds an `EXTERNAL-IP` appears. Browse to `https://<that-ip>` (still self-signed cert, still accept the warning).

- **Pros:** Public URL. Stable across laptop reboots. Works for OIDC and webhooks.
- **Cons:** Costs a Standard Load Balancer rule (~$5/month + traffic). Self-signed cert until you front it with a TLS proxy. Open to the internet — pair with `--enable-cluster-network-policy` or an NSG before considering production.
- **When to pick it:** A small team with a dedicated Argo CD instance and no Ingress yet.

### Ingress + TLS (the production path)

Run `ingress-nginx` (or AGIC, the Azure Application Gateway Ingress Controller), terminate TLS at the ingress with a cert from Let's Encrypt or Azure Key Vault, route `argocd.your-domain.com` → `svc/argocd-server`. The official Argo CD docs have a [dedicated page on this](https://argo-cd.readthedocs.io/en/stable/operator-manual/ingress/) covering the gotchas (gRPC vs HTTP/2, the need to set `Backend Protocol` to HTTPS because Argo CD insists on TLS to the backend, and the `--insecure` flag on `argocd-server` if you terminate TLS at the edge).

- **Pros:** Real cert, real domain, real SSO. Shared with everything else on the cluster.
- **Cons:** You need an ingress controller, a DNS record, and a cert manager. Real but non-trivial setup.
- **When to pick it:** Anything with users beyond yourself.

---

## Part 4 — The bootstrap secret and the admin password

Step 3 retrieves the admin password from `argocd-initial-admin-secret`. The deeper story:

- The secret is created on first install by the `argocd-server` container, using `argocd admin initial-password` logic — a cryptographically random password baked into a Kubernetes Secret.
- It is **meant to be deleted after first login.** The first time you change the admin password (either in the UI or via `argocd account update-password`), Argo CD updates `argocd-secret.admin.password` (the persistent location) and *also* deletes the initial-admin secret in the background.
- The persistent password lives in `argocd-secret`, hashed with bcrypt, under `data.admin.password`. To rotate it from the CLI:

```bash
argocd account update-password \
  --account admin \
  --current-password <current> \
  --new-password <new>
```

- If you ever lose the password entirely, `argocd admin initial-password` (run inside the `argocd-server` pod) regenerates a one-time password. Then change it via the UI.

For this hands-on we skip changing the password so the port-forward retry path stays simple. Don't replicate that in any environment that is not throwaway.

---

## Part 5 — Sync, Health, OutOfSync, Degraded — and why they're separate

The bootcamp file introduces sync status and health status as orthogonal. Worth labouring the point with concrete combinations:

| Sync | Health | Meaning | Example |
|---|---|---|---|
| Synced | Healthy | Everything matches Git and runs. | Steady state. |
| Synced | Degraded | Cluster matches Git, but the workload itself is unhealthy. | You committed a Deployment with a bad image tag. Argo CD applied it; the pods crashloop. The fix is **in Git**, not in the cluster. |
| OutOfSync | Healthy | The cluster is running fine but doesn't match Git. | Someone `kubectl edit`-ed a replica count to a working value. Argo CD wants to revert it. |
| OutOfSync | Degraded | Cluster doesn't match Git AND is broken. | Worst case. Usually means a partial sync got cancelled, or a Helm hook failed mid-flight. |
| Synced | Missing | Git says these objects should exist; the cluster has none. Only seen transiently right after `argocd app create` and before the first sync. | First create of an `Application` on `Manual` sync. |
| Synced | Progressing | Cluster matches Git, but workloads are still rolling out. | The new Deployment's pods are coming up but not all Ready yet. |

The reason these are separate:

- **Sync is a property of the diff** between Git and the cluster. Argo CD computes it by rendering Git, listing cluster state, comparing field by field.
- **Health is a property of the live resources** — for Deployments, it's `availableReplicas >= replicas`; for StatefulSets, similar; for Services, `endpoints > 0`; etc. Argo CD has built-in [health checks per resource kind](https://argo-cd.readthedocs.io/en/stable/operator-manual/health/) and you can write [custom Lua scripts](https://argo-cd.readthedocs.io/en/stable/operator-manual/health/#custom-health-checks) for CRDs Argo CD doesn't know about (a `Certificate` from cert-manager, an `IngressRoute` from Traefik, etc.).

You will use this distinction every day. *"Why is my app red?"* is two questions: a sync question (look at the diff) or a health question (look at the workload). Asking the right one halves diagnostic time.

---

## Part 6 — The timing model

Step 9 of the bootcamp file mentions a 3-minute polling interval and a near-instant in-cluster reaction. The full picture:

| Trigger | What fires | Default interval |
|---|---|---|
| Periodic Git refresh | `argocd-application-controller` re-fetches every `Application`'s repo and re-renders | **3 minutes** (`timeout.reconciliation` in `argocd-cm`) |
| Manual refresh | UI button "Refresh" / `argocd app get --refresh` | On demand |
| In-cluster change | Controller's Kubernetes watch fires; sync status recomputed | Sub-second |
| Webhook from Git | Git provider POSTs to Argo CD's webhook endpoint; controller refreshes that one repo | Sub-second |
| `argocd app sync` | CLI/UI explicitly asks for a sync | Immediate |

Tuning these:

- **Lower the polling interval** by editing the `argocd-cm` ConfigMap:

  ```yaml
  data:
    timeout.reconciliation: 30s
  ```

  Trade-off: more load on Git and on the controller. For small fleets, 30s is fine. For 500 applications, leave it at 3m and use webhooks instead.

- **Set up webhooks** (the production answer): GitHub/GitLab/Bitbucket can POST to `https://argocd.your-domain/api/webhook` on every push. Argo CD then refreshes the `Application` immediately. Documented in [Argo CD webhook docs](https://argo-cd.readthedocs.io/en/stable/operator-manual/webhook/).

- **`selfHeal` reaction time.** When in-cluster drift is detected by the watch, `selfHeal: true` triggers an apply within ~1–3 seconds end to end. Empirically (verified in this hands-on's testing session): a `kubectl scale` from 1 to 4 replicas was caught and reverted in under 3 seconds. The controller does not wait for the next Git poll; the watch event triggers the work queue immediately.

---

## Part 7 — The `Application` CRD: every field that matters

The minimum viable `Application` we used:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: guestbook-decl
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps.git
    targetRevision: HEAD
    path: guestbook
  destination:
    server: https://kubernetes.default.svc
    namespace: guestbook-decl
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
```

The fields you will set in real life beyond this:

| Field | Purpose |
|---|---|
| `spec.source.targetRevision` | Branch, tag, commit SHA, or Helm chart version. Use a **branch** for dev, a **commit SHA** for prod (immutable references prevent surprise upgrades). |
| `spec.source.helm.valueFiles` | When source is a Helm chart: list of values files to layer on top. Order matters; later files win. |
| `spec.source.helm.values` | Inline values block. Useful for one-off overrides without committing a values file. |
| `spec.source.kustomize.namePrefix` | When source is Kustomize: name prefix to apply. |
| `spec.destination.server` | URL of the target cluster. `https://kubernetes.default.svc` is the local cluster; for multi-cluster, register external clusters first. |
| `spec.syncPolicy.automated.prune` | Delete cluster resources removed from Git. Off by default — be cautious. |
| `spec.syncPolicy.automated.selfHeal` | Revert out-of-band edits. Off by default. |
| `spec.syncPolicy.syncOptions[]` | `CreateNamespace=true`, `Validate=false` (skip kubectl validation, useful for custom CRDs), `ApplyOutOfSyncOnly=true`, etc. |
| `spec.ignoreDifferences` | List of fields to ignore in the diff (e.g. `replicas` if you let HPA manage replicas independently). Subtle and important — see below. |
| `spec.revisionHistoryLimit` | Number of sync history entries to keep. Default 10. |

### `ignoreDifferences` — the field that prevents fights with controllers

If your Deployment has an HPA managing replicas, Argo CD will see the live `spec.replicas=5` vs the Git `spec.replicas=1` and try to revert. The HPA will scale back up. You get a war.

The fix:

```yaml
spec:
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas
```

Same pattern applies to:
- `cert-manager` writing `cert-manager.io/last-applied` annotations.
- `keda` adjusting `spec.replicas`.
- Webhooks that mutate resources after creation.

Whenever you find Argo CD looping on the same field, the answer is almost always `ignoreDifferences`.

---

## Part 8 — RBAC: how the controller is allowed to apply manifests

When `argocd-application-controller` applies the guestbook Deployment, it does so as a Kubernetes ServiceAccount. Out of the box the install manifest grants Argo CD a `ClusterRoleBinding` to a `ClusterRole` that has `*` on `*` — i.e. effectively cluster-admin. This is fine for class and for single-tenant clusters. It is not fine for shared platforms.

The tightening path:

- **`AppProject`** — Argo CD's own boundary. Constrain which Git repos, which destination namespaces, which resource kinds an app can use. We are using `default` which is open; in production each team gets its own `AppProject`.
- **Per-namespace ServiceAccount via Argo CD impersonation.** With `application.sync.impersonation.enabled: true` in `argocd-cm` and a SA named in each Application's destination, Argo CD apply as *that* SA, not its own — giving each app only the permissions its own SA has.

Both are covered exhaustively in the [Argo CD RBAC docs](https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/). Not needed for this hands-on; needed before letting more than one team share an Argo CD instance.

---

## Part 9 — Sync waves, hooks, finalizers (one-liners, for completeness)

You will meet these the first time you have a non-trivial app. Each deserves its own deep dive; here's enough to know they exist.

- **Sync waves** — annotate resources with `argocd.argoproj.io/sync-wave: "1"` to control order within a sync. Lower numbers go first. Common use: deploy a CRD definition in wave -1 before the CRs in wave 0.
- **Sync hooks** — `argocd.argoproj.io/hook: PreSync` / `Sync` / `PostSync` / `SyncFail` annotations create resources at specific phases. Used for DB migrations, smoke tests, cleanup jobs. Hooks are *not* tracked as part of the application's normal state.
- **Finalizers** — adding `argocd.argoproj.io/finalizer: resources-finalizer.argocd.argoproj.io` on the `Application` itself makes `argocd app delete` cascade through cluster resources. Without it, deleting the Application leaves the underlying resources orphaned. We did not set it on `guestbook-decl` in this hands-on so the cleanup step had to delete the namespaces manually.

---

## Cleanup

```bash
argocd app delete guestbook --yes
argocd app delete guestbook-decl --yes
kubectl delete namespace guestbook guestbook-decl --ignore-not-found
kubectl delete namespace argocd
az group delete --name rg-bootcamp-test-argocd-first-app --yes --no-wait
```

Or, if you used the scripts:

```bash
./scripts/aks-down.sh
```

---

## Discussion questions

Questions a careful reader should be able to answer after this hands-on. Useful for instructors preparing for in-class Q&A.

1. The bootcamp file says the credentials problem is "solved by not having the credentials leave the cluster". But the `argocd-application-controller` ServiceAccount has cluster-admin in our install. Where exactly is the security improvement compared to a CI runner with a `kubeconfig`?
2. If you `kubectl delete deployment guestbook-ui -n guestbook-decl` (without `selfHeal: true` on), what does the application status show? What about with `selfHeal: true` on?
3. Why does enabling `prune: true` without `selfHeal: true` not delete a manually-edited resource? What does `prune` actually trigger on?
4. The reconciliation interval defaults to 3 minutes. What is the *correct* mental model for the latency between a `git push` and a deployment landing — and what does the answer depend on?
5. Argo CD installed seven pods. Which of them can you scale to N replicas without breaking anything? Which one is a StatefulSet and why?

---

## Troubleshooting

| Symptom | Root cause | Fix |
|---|---|---|
| `kubectl apply -f install.yaml` fails on `applicationsets.argoproj.io`: `metadata.annotations: Too long: may not be more than 262144 bytes` | The install manifest defines a CRD whose OpenAPI schema, when serialized into the `kubectl.kubernetes.io/last-applied-configuration` annotation by client-side apply, exceeds the 256 KiB annotation limit. | Use `kubectl apply --server-side --force-conflicts`. Server-side apply stores the field manager information in the resource directly instead of in the annotation. |
| `az aks create` fails with `(BadRequest) The VM size of Standard_B2s is not allowed in your subscription` or `InsufficientVCPUQuota for family standardBsv2Family` | B-series VM quota disabled in this subscription / region. | Use `Standard_D2s_v3` (or any D-series with `2s_v3`/`2s_v4`). Same effective resource shape for our purposes. If you really want a B-series, file a quota-increase request. |
| `argocd login localhost:8080` returns `dial tcp [::1]:8080: connectex: No connection could be made` on Windows | Windows resolves `localhost` to the IPv6 address `::1`; `kubectl port-forward` listens on IPv4 `127.0.0.1` only. The browser is unaffected (it falls back to IPv4). | Log in via `argocd login 127.0.0.1:8080` instead. |
| `kubectl port-forward` says `unable to do port forwarding: socat not found` | The kubectl tunnel needs `socat` on the node side. Rare on AKS but happens on some custom images. | `az aks update --resource-group <rg> --name <cluster>` to roll node images; or use `argocd login` via a LoadBalancer. |
| `argocd app diff <app>` prints only the resource header line and exits 1, with no actual diff body | Cosmetic quirk in argocd CLI v3.4 when the unified diff is rendered through certain non-TTY pipes (PowerShell wrapping in particular). The application status itself is correct. | Use the UI's diff button, or `argocd app get <app> --output yaml` and `kubectl get <kind> <name> -n <ns> -o yaml` and compare. Exit code 1 from `app diff` means "diff present", not "error". |
| `argocd login` returns `dial tcp 127.0.0.1:8080: connection refused` | The port-forward isn't running. | Restart it: `kubectl port-forward svc/argocd-server -n argocd 8080:443`. |
| Login succeeds but the UI says "Forbidden" on every page | Browser cached a stale session. | Hard refresh (`Ctrl+Shift+R`). If that fails, clear cookies for `localhost`. |
| First sync hangs `Progressing` for >5 min | `argocd-repo-server` cannot reach `github.com`. Often a corporate proxy or an outbound NSG. | `kubectl logs -n argocd deploy/argocd-repo-server` will say so. Configure `HTTP_PROXY` / `HTTPS_PROXY` on the `argocd-repo-server` Deployment or open the egress. |
| `OutOfSync` flips back and forth on a Deployment whose replicas you didn't touch | Something else (HPA, KEDA, a webhook) is mutating `spec.replicas`. | Add `ignoreDifferences` for `/spec/replicas` — see Part 7. |
| `argocd app delete` finishes but `kubectl get all -n <ns>` still lists resources | The `Application` had no `resources-finalizer.argocd.argoproj.io` finalizer; deletion was non-cascading. | Add the finalizer for cascading delete next time. For now, `kubectl delete` the leftovers manually. |
| On Windows in Git Bash, `kubectl ... --azure-monitor-... /subscriptions/...` rewrites the path | MSYS path conversion. (Same issue as in W15.2.) | `export MSYS_NO_PATHCONV=1` in that shell. Alternatively use PowerShell or WSL. |
| `argocd-initial-admin-secret` does not exist | Either someone already logged in and changed the password, or the install was pre-1.9 and uses a different mechanism. | If you forgot the new password, use `kubectl exec -n argocd argocd-server-<pod> -- argocd admin initial-password` to regenerate. |

## References

- [Argo CD — Overview](https://argo-cd.readthedocs.io/en/stable/) — official docs landing page.
- [Argo CD — Architecture overview](https://argo-cd.readthedocs.io/en/stable/operator-manual/architecture/) — Part 2 of this README maps 1:1 to this page.
- [Argo CD — Declarative setup](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/) — the canonical reference for the `Application` and `AppProject` YAML schemas.
- [Argo CD — Ingress configuration](https://argo-cd.readthedocs.io/en/stable/operator-manual/ingress/) — production exposure recipes including AGIC / nginx-ingress / Traefik.
- [Argo CD — RBAC](https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/) — RBAC model, AppProjects, impersonation.
- [Argo CD — Health checks](https://argo-cd.readthedocs.io/en/stable/operator-manual/health/) — built-in health logic and how to write custom Lua scripts for CRDs.
- [Argo CD — Webhook configuration](https://argo-cd.readthedocs.io/en/stable/operator-manual/webhook/) — replace the 3-minute polling lag with near-instant push notifications from Git.
- [argoproj/argocd-example-apps](https://github.com/argoproj/argocd-example-apps) — official examples repo we cloned from.