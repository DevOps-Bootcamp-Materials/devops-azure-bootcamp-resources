# Hands-on: Helm

## Objective

Put the concepts from the Helm lesson into practice by building a chart from scratch, deploying it to two environments with different values, walking through the release lifecycle (install → upgrade → rollback → uninstall) and finally consuming a public chart from a remote repository.

By the end of this lab you will understand:

- The anatomy of a Helm Chart (`Chart.yaml`, `values.yaml`, `templates/`, `_helpers.tpl`)
- How Go templates expand against `.Values`, `.Chart` and `.Release`
- How to deploy the **same chart** to `dev` and `prod` with different value files
- How Helm tracks revisions and how `helm rollback` actually works
- How to render and debug a chart locally without touching the cluster
- How to consume a chart from a public repository (Bitnami)

---

## Prerequisites

You need:

- A running Kubernetes cluster — `minikube`, `kind`, an AKS cluster, or Docker Desktop's built-in cluster.
- `kubectl` configured against that cluster (`kubectl get nodes` must return at least one node).
- `helm` v3+ installed locally.

Install Helm if you do not have it:

```bash
# macOS
brew install helm

# Linux
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Windows (winget)
winget install Helm.Helm

# Verify
helm version
```

Create a dedicated namespace for the lab:

```bash
kubectl create namespace helm-lab
kubectl config set-context --current --namespace=helm-lab
```

---

## Part 1 — Scaffold a chart with `helm create`

Helm ships with a scaffolding command that generates a working chart. It is the easiest way to see the layout for the first time.

```bash
mkdir -p ~/helm-playground && cd ~/helm-playground
helm create demo

# Inspect what was generated:
tree demo
```

You should see roughly this structure:

```
demo/
├── Chart.yaml
├── values.yaml
├── charts/
└── templates/
    ├── _helpers.tpl
    ├── deployment.yaml
    ├── hpa.yaml
    ├── ingress.yaml
    ├── NOTES.txt
    ├── service.yaml
    ├── serviceaccount.yaml
    └── tests/
        └── test-connection.yaml
```

That scaffolded chart already deploys an nginx Pod. You can install it right now to see Helm in action:

```bash
helm install demo ./demo
helm list
kubectl get all -l app.kubernetes.io/instance=demo
helm uninstall demo
```

The scaffold is useful as a reference, but it is too generic. In Part 2 we will build our own chart — small enough to read end-to-end.

---

## Part 2 — Our chart: `webapp`

This repository ships a small but realistic chart under `charts/webapp/`. It deploys:

- A **Deployment** of a configurable container image
- A **Service** exposing it inside the cluster
- A **ConfigMap** with a banner message that the app reads as an environment variable

Take a few minutes to read the files:

```bash
# From this hands-on directory:
ls charts/webapp/
cat charts/webapp/Chart.yaml
cat charts/webapp/values.yaml
ls charts/webapp/templates/
```

Things to notice in the templates:

- `{{ include "webapp.fullname" . }}` — a named template defined in `_helpers.tpl`, reused across every manifest to keep names consistent.
- `{{ .Values.image.repository }}` — references a value from `values.yaml`.
- `{{ .Release.Name }}` — references the Helm Release object: the name the user gave at install time.
- `{{- if .Values.banner.enabled }}` — conditional rendering: the ConfigMap is only generated when the user opts in.

### 2.1 Render locally (no cluster involved)

Before installing anything, render the templates to see what Helm *would* send to the API server:

```bash
helm template my-release ./charts/webapp
```

This is your debugging best friend. The output is plain YAML — the exact manifests `kubectl apply` would receive. If something looks wrong here, the bug is in your templates, not in the cluster.

Try changing a value on the fly:

```bash
helm template my-release ./charts/webapp --set replicaCount=5 | grep replicas
```

### 2.2 Install the chart

```bash
helm install web ./charts/webapp
```

You should see a `NOTES.txt` printed by Helm — that comes from `templates/NOTES.txt` in the chart and is a great place to tell users how to reach the application once installed.

```bash
helm list
kubectl get all -l app.kubernetes.io/instance=web
helm status web
```

Reach the app with `kubectl port-forward`:

```bash
kubectl port-forward svc/web-webapp 8080:80
# In another terminal:
curl http://localhost:8080
```

---

## Part 3 — Same chart, two environments (`dev` and `prod`)

This is the **whole point** of Helm: deploy the same chart to multiple environments with different parameters.

The repository ships two value files:

- `values/dev.yaml` — 1 replica, banner enabled, low resources
- `values/prod.yaml` — 3 replicas, banner disabled, higher resources

Install both as separate releases:

```bash
# Dev release
helm install webapp-dev ./charts/webapp \
  -f values/dev.yaml \
  --namespace helm-lab-dev --create-namespace

# Prod release
helm install webapp-prod ./charts/webapp \
  -f values/prod.yaml \
  --namespace helm-lab-prod --create-namespace
```

Compare what was generated:

```bash
kubectl -n helm-lab-dev  get deploy webapp-dev-webapp  -o jsonpath='{.spec.replicas}{"\n"}'
kubectl -n helm-lab-prod get deploy webapp-prod-webapp -o jsonpath='{.spec.replicas}{"\n"}'

# The ConfigMap only exists in dev (banner.enabled: true in dev, false in prod):
kubectl -n helm-lab-dev  get configmap
kubectl -n helm-lab-prod get configmap
```

Same chart. Two completely different deployments. No copy-pasted YAML.

---

## Part 4 — The release lifecycle: `upgrade`, `history`, `rollback`

Let's evolve the `webapp-dev` release through a few revisions.

### 4.1 Upgrade with `--set`

Bump the replica count without touching any file:

```bash
helm upgrade webapp-dev ./charts/webapp \
  -f values/dev.yaml \
  --set replicaCount=3 \
  --namespace helm-lab-dev
```

Helm creates a **new revision** of the release. You can see all revisions:

```bash
helm history webapp-dev -n helm-lab-dev
```

### 4.2 Upgrade by editing values

Bump the image tag in `values/dev.yaml` from `1.27` to `1.28`, then:

```bash
helm upgrade webapp-dev ./charts/webapp \
  -f values/dev.yaml \
  --namespace helm-lab-dev
```

(If you do not want to edit the file, just pass `--set image.tag=1.28`.)

### 4.3 Rollback

Suppose the new image broke something. Roll back to the previous revision:

```bash
helm history  webapp-dev -n helm-lab-dev
helm rollback webapp-dev 1 -n helm-lab-dev   # revision 1 is the original install
helm history  webapp-dev -n helm-lab-dev     # rollback shows as a new revision
```

The rollback is itself a new revision — Helm never rewrites history.

### 4.4 The `--atomic` flag (recommended for CI)

If an upgrade fails midway, the release ends up in a `failed` state. `--atomic` makes Helm rollback automatically:

```bash
# Force a failure: pull from a non-existent image:
helm upgrade webapp-dev ./charts/webapp \
  -f values/dev.yaml \
  --set image.repository=does-not-exist/nope \
  --atomic --timeout 30s \
  --namespace helm-lab-dev
```

The upgrade will fail and Helm will automatically roll back to the previous good state. Verify:

```bash
helm history webapp-dev -n helm-lab-dev
kubectl get pods   -n helm-lab-dev
```

---

## Part 5 — `--dry-run` and `--debug`: debugging without installing

When a chart misbehaves, you usually want to see *exactly* what Helm would send to the API server, with the templates fully expanded and validated.

```bash
helm install webapp-test ./charts/webapp \
  -f values/dev.yaml \
  --dry-run --debug
```

This:

1. Renders all templates against the values
2. Runs the result through the Kubernetes server-side schema (validates kinds, fields, etc.)
3. Prints the rendered YAML
4. **Does not actually create anything**

If a template has a syntax error, you will see it here before touching the cluster.

---

## Part 6 — Consuming a public chart (Bitnami NGINX)

Most of the time you will not write charts from scratch — you will install community-maintained ones. Add Bitnami's repository and install nginx:

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

# Inspect what is available:
helm search repo bitnami/nginx --versions | head -5

# See the chart's default values (this is where you learn what is parameterisable):
helm show values bitnami/nginx | head -80

# Install it:
helm install mynginx bitnami/nginx --version 18.* --namespace helm-lab
```

Verify and reach the service:

```bash
helm list -n helm-lab
kubectl get pods,svc -l app.kubernetes.io/instance=mynginx -n helm-lab
kubectl port-forward svc/mynginx 8081:80 -n helm-lab
# In another terminal:
curl http://localhost:8081
```

This is exactly how the ecosystem distributes things like Prometheus, Redis, PostgreSQL, ingress-nginx, cert-manager…

---

## Part 7 — Cleanup

```bash
# Uninstall all releases:
helm uninstall web           -n helm-lab           || true
helm uninstall mynginx       -n helm-lab           || true
helm uninstall webapp-dev    -n helm-lab-dev       || true
helm uninstall webapp-prod   -n helm-lab-prod      || true

# Remove namespaces:
kubectl delete namespace helm-lab helm-lab-dev helm-lab-prod

# Reset kubectl context:
kubectl config set-context --current --namespace=default
```

---

## Discussion questions

1. Your `values.yaml` declares `replicaCount: 2`, but `values/prod.yaml` declares `replicaCount: 3`, and the user runs `helm upgrade ... -f values/prod.yaml --set replicaCount=5`. What is the effective value, and why?
2. You upgrade a release with a bad image tag. The new Pods stay in `ImagePullBackOff`, but `helm upgrade` returns success. Why? What flag would have prevented that?
3. Why are `Chart.version` and `Chart.appVersion` separate fields? Give an example where you would bump one but not the other.
4. Sub-chart values are scoped under the sub-chart name (e.g. `redis.password`). What is the trade-off vs flat values?
5. Helm 3 installs CRDs from `crds/` only on first install, never on upgrade. Why was that design choice made, and what does it imply for chart maintainers?

---

## Key concepts

| Concept | What it is |
|---------|-----------|
| **Chart** | A directory of templated manifests + `Chart.yaml` + `values.yaml`. The distributable unit. |
| **Release** | An installed instance of a chart in a cluster. Each release has its own revision history. |
| **Revision** | One version of a release. Created by `helm install`, `helm upgrade`, `helm rollback`. |
| **Values** | Parameters that customise a chart. Precedence: `values.yaml` < `-f file` < `--set`. |
| **Template** | A manifest in `templates/` with Go template placeholders evaluated at render time. |
| **Named template** | Reusable snippet defined in `_helpers.tpl` and consumed via `{{ include }}`. |
| **Hook** | A manifest annotated to run at a specific lifecycle point (pre-install, post-upgrade…). |
| **Repository** | HTTP server or OCI registry hosting published charts (e.g. Bitnami, ACR). |

**Rule of thumb:**

- Use `helm template` or `--dry-run --debug` *before* every real install/upgrade.
- Use `--atomic` in CI/CD so failed upgrades self-heal.
- Pin chart versions (`--version 1.2.3`) in production — never let "latest" sneak in.
- Treat the rendered manifests, not the templates, as the source of truth for "what is actually in the cluster".
