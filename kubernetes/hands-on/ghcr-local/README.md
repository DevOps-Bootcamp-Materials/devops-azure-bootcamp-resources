# GHCR — push by hand, push from CI, pull from any cluster

This is the deep-dive companion to the bootcamp hands-on `week-17/container-registry/hands-on/01_ghcr_build_push_pull.md`. The bootcamp file walks the flow; this README goes deep on the parts that bite in practice: token types and scopes, exactly what `GITHUB_TOKEN` can and cannot do, the visibility and linking model, pull secrets beyond the basics (ServiceAccounts, dedicated read tokens), multi-architecture images, version retention, and the full troubleshooting table from our verified run.

A complete working reference repo (built while testing this hands-on) is public at [github.com/iscoct/hello-ghcr](https://github.com/iscoct/hello-ghcr).

## What this folder contains

- `README.md` — this file
- `app/Dockerfile`, `app/index.html` — the sample image (note the OCI `source` label)
- `workflow/build-and-push.yml` — the Actions workflow to copy into your repo (pinned to Node 24-ready action majors, verified green)
- `manifests/namespace.yaml` — the `hello` namespace
- `manifests/deployment-public.yaml` — pulls the public package, no credentials
- `manifests/deployment-private.yaml` — pulls the private package via `imagePullSecrets`

## Prerequisites

- Docker Desktop, `kind` (or minikube/k3d), `kubectl`, `gh` CLI authenticated
- The GHCR deep-dive lesson

---

## Part 1 — Tokens: the complete map

GHCR accepts three kinds of credentials, and most confusion comes from mixing them up:

| Credential | Where it lives | Scopes for GHCR | Use it for |
|---|---|---|---|
| **PAT (classic)** | You create it (Settings → Developer settings → Tokens (classic)) | `read:packages`, `write:packages`, `delete:packages` | Laptop push/pull, imagePullSecrets, cross-repo CI pushes |
| **Fine-grained PAT** | Same place, newer kind | Packages permissions are still limited for container registry use — check current docs before relying on one | Repo-scoped API work; classic remains the safe choice for GHCR specifically |
| **`GITHUB_TOKEN`** | Minted automatically per workflow run | Whatever the workflow's `permissions:` block grants, max `packages: write` | Pushing from the repo's own workflow — always prefer it there |

Practical notes, verified during the test run:

- The `gh` CLI's OAuth token does **not** carry package scopes by default (ours had `gist, read:org, repo, workflow`). Extend it once with `gh auth refresh -h github.com -s read:packages,write:packages` and `gh auth token` becomes a usable GHCR credential — convenient because it lives in the OS keyring rather than in a text file.
- `docker login` succeeds even with a scope-less token; the failure surfaces later at **push** time as `denied: permission_denied`. Login success ≠ permission proof.
- For an `imagePullSecret` used by a cluster, create a **dedicated PAT with `read:packages` only** and a short expiry. The secret's content is base64, not encrypted — anyone with namespace read access can recover it. Least privilege is not optional here.

## Part 2 — `GITHUB_TOKEN` in depth

What the workflow run gets: a token scoped **to the repository running the workflow**, valid for the duration of the job, with permissions declared in the `permissions:` block. Implications:

- **`permissions: packages: write` is mandatory** for a push. Without the block, the default token permissions (often read-only on newer repos/orgs) make `docker push` fail with 403. This is the single most common CI push failure.
- **It cannot push to another user's/org's packages.** Cross-owner pushes need a PAT stored as a repository secret — the only scenario where a PAT belongs in Actions.
- **First push from CI creates the package** owned by the repo owner, private, and linked to the repo (the link grants the repo's Actions access to keep pushing — visible under Package settings → Manage Actions access).
- The `${{ github.actor }}` username in `docker/login-action` is whoever triggered the run; any value works as username when the password is a `GITHUB_TOKEN`/PAT — GHCR authenticates on the token, but keeping `github.actor` makes audit logs readable.

**Action versions (verified 2026-06-11):** `actions/checkout@v6`, `docker/login-action@v4`, `docker/build-push-action@v7` run green with no deprecation annotations. The very common `checkout@v4` / `login-action@v3` / `build-push-action@v6` combination still works but triggers the "Node.js 20 actions are deprecated" annotation on GitHub runners (Node 24 becomes the forced default on June 16, 2026) — bump when you see it.

## Part 3 — Visibility, linking, and the package page

- **Private by default.** Every first push creates a private package — even from a public repo's workflow. Package visibility is independent of repo visibility.
- **Changing visibility is a UI action**: Package page → Package settings → Danger Zone → Change visibility. For user-owned container packages there is no supported API call for the flip — script everything else, but this click is manual.
- **Linking** (the `org.opencontainers.image.source` label, or pushing from a repo's workflow) puts the package on the repo's sidebar, shows the README on the package page, and lets the package inherit collaborator access. Linking is about *access management*; visibility is about *who can pull*. Two separate dials.
- **Public package pull needs no Docker Hub-style account or rate-limit dance** — anonymous pulls of public GHCR images are free and not subject to Docker Hub's pull limits, which matters when a classroom of 25 students pulls the same image at once.

## Part 4 — Pull secrets beyond the basics

The bootcamp flow creates the secret per namespace and references it per Deployment. Two upgrades for real use:

**Attach to a ServiceAccount** — every Pod using that SA pulls with the secret automatically, no per-Deployment field:

```bash
kubectl create secret docker-registry ghcr-cred -n hello \
  --docker-server=ghcr.io --docker-username=YOUR_USER --docker-password=$CR_PAT

kubectl patch serviceaccount default -n hello \
  -p '{"imagePullSecrets":[{"name":"ghcr-cred"}]}'
```

(On PowerShell, use a `--patch-file` — inline JSON gets mangled, same as the kind hands-on.)

**What the secret actually is** — a `.dockerconfigjson` blob, identical in shape to your laptop's `~/.docker/config.json`:

```bash
kubectl get secret ghcr-cred -n hello -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
```

Seeing the decoded JSON cures the "Kubernetes secrets are encrypted" misconception instantly: base64 is encoding, not encryption. RBAC on the namespace is the real protection; etcd encryption-at-rest and external secret stores are the production-grade answers.

**The namespace rule** — `imagePullSecrets` can only reference Secrets in the Pod's own namespace. Deploying the same app to three namespaces means the secret exists three times (or a controller like reflector replicates it). This is the #1 "works in default, fails in prod" surprise.

## Part 5 — Multi-architecture images

Classmates on Apple Silicon pull `arm64`; your laptop builds `amd64`. A single-arch image gives them `exec format error` at container start (the pull succeeds — the failure is at runtime, which makes it confusing). The fix is a multi-arch build, one flag away in CI:

```yaml
      - uses: docker/setup-qemu-action@v3
      - uses: docker/setup-buildx-action@v3
      - uses: docker/build-push-action@v7
        with:
          context: .
          push: true
          platforms: linux/amd64,linux/arm64
          tags: ghcr.io/${{ github.repository_owner }}/hello-ghcr:${{ github.sha }}
```

GHCR stores the result as a manifest list; each cluster pulls its native architecture under the same tag. Locally, `docker buildx build --platform linux/amd64,linux/arm64` does the same.

## Part 6 — Retention: packages accumulate

Every CI push adds a SHA-tagged version; a busy repo creates thousands. GHCR has no automatic expiry for user accounts, so prune in CI:

```yaml
  cleanup:
    runs-on: ubuntu-latest
    permissions:
      packages: write
    steps:
      - uses: actions/delete-package-versions@v5
        with:
          package-name: hello-ghcr
          package-type: container
          min-versions-to-keep: 10
          delete-only-untagged-versions: true
```

Keep tagged releases, drop untagged build intermediates, cap the total. Storage for public packages is free, but clutter has a cost in humans scrolling.

## Cleanup

```bash
kind delete cluster --name ghcr-test
docker image rm ghcr.io/YOUR_USER/hello-ghcr:1.0 ghcr.io/YOUR_USER/hello-ghcr-private:1.0
docker logout ghcr.io
# Optional: delete test packages in the UI (Package settings -> Delete this package)
```

## Discussion questions

1. Your workflow's push fails with 403 even though `docker login` succeeded in the previous step. List the three most likely causes in the order you would check them.
2. Why is `GITHUB_TOKEN` strictly better than a PAT for pushing to the same repo's packages? Name the one scenario where a PAT in Actions is unavoidable.
3. The Pod pulls fine in `default` but hits `ErrImagePull` in `staging` with the same manifest. What happened, and what are two fixes with different trade-offs?
4. A teammate stores their personal `write:packages` PAT in the cluster's pull secret. Walk through what an attacker with read access to that namespace could do, and design the minimal-privilege replacement.
5. Why does an Apple Silicon classmate's Pod crash with `exec format error` instead of failing to pull? Where in the image distribution model does architecture selection happen?
6. When would you deploy `:latest` deliberately? (Hint: think about what "deploy" means without an immutable reference — then defend any answer you give.)

## Troubleshooting

| Symptom | Root cause | Fix |
|---|---|---|
| `denied` on `docker push` (login was fine) | Token lacks `write:packages` | Recreate/extend the PAT; `gh auth refresh -s write:packages` |
| `denied` / 403 pushing from Actions | Missing `permissions: packages: write` | Add the permissions block to the workflow |
| `invalid reference format` on build/push | Uppercase letters in the owner path | Lowercase the owner: `ghcr.io/iscoct/...` |
| `ErrImagePull` + `failed to fetch anonymous token: 401 Unauthorized` | Package is private and the pull is anonymous (no/wrong `imagePullSecrets`) | Create the secret in the Pod's namespace; check the Deployment references it |
| `FailedToRetrieveImagePullSecret` warning in describe | Deployment references a Secret that doesn't exist (yet) in that namespace | Create `ghcr-cred` in the same namespace; the Pod recovers on the next retry |
| Pods `Pending` with "untolerated taint" right after cluster create | Transient `node.kubernetes.io/not-ready` taint while the node initializes | Wait a few seconds; they schedule on their own once the node is Ready |
| `ErrImagePull` in one namespace only | Secret exists in another namespace | Secrets are namespaced — create it where the Pod runs |
| Pull works for `latest`, fails for your tag | Tag never pushed (CI tags SHA only, or push failed) | Check the package's versions list on GitHub |
| Pod starts then crashes `exec format error` | Single-arch image on a different-arch node | Multi-arch build (Part 5) |
| CI green but no package visible | Looking at the repo, not the owner's Packages tab | Packages live under the user/org profile → Packages |
| `gh api user/packages` returns 403 | gh token lacks `read:packages` | `gh auth refresh -s read:packages` |

## References

- [GitHub — Working with the Container registry](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry) — the canonical GHCR guide: auth, push, pull, visibility
- [GitHub — About permissions for GitHub Packages](https://docs.github.com/en/packages/learn-github-packages/about-permissions-for-github-packages) — the scopes/permissions model behind every `denied`
- [GitHub — Publishing Docker images (Actions guide)](https://docs.github.com/en/actions/publishing-packages/publishing-docker-images) — the official workflow this hands-on's workflow is based on
- [docker/build-push-action](https://github.com/docker/build-push-action) — every input the build step accepts, including `platforms` for multi-arch
- [docker/login-action](https://github.com/docker/login-action) — registry login reference
- [actions/delete-package-versions](https://github.com/actions/delete-package-versions) — the retention automation from Part 6
- [Kubernetes — Pull an Image from a Private Registry](https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/) — the upstream imagePullSecrets task this hands-on mirrors
