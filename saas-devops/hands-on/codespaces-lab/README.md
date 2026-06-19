# GitHub Codespaces as a DevOps lab — the deep dive

This is the deep-dive companion to the bootcamp hands-on `week-18/saas-devops/hands-on/01_codespaces_devops_lab.md`. The bootcamp file walks the happy path; this README explains the devcontainer model in depth, the billing mechanics, the port-forwarding/tunnel internals and security model, and — most usefully — the three real build failures we hit and fixed while making this lab reliable. Those failures are the actual content: anyone can write a devcontainer that works on their machine; making one that survives a flaky keyserver and a non-root user is the engineering.

## What this folder contains

- `README.md` — this file
- `devcontainer.json` — the environment definition (docker-in-docker + sshd features, forwardPorts, postCreate)
- `setup.sh` — installs kubectl/helm/kind from official binaries + sha256 (runs as postCreateCommand)
- `kind-config.yaml` — single-node kind cluster
- `manifests/deploy.yaml` — nginx Deployment + Service

The same files live in the runnable lab repo at [github.com/iscoct/codespaces-k8s-lab](https://github.com/iscoct/codespaces-k8s-lab).

## Prerequisites

- A GitHub account (free Codespaces tier)
- For the CLI flow: `gh` with the `codespace` scope
- The free-tier DevOps toolbox lesson

---

## Part 1 — The devcontainer model

A **dev container** is an environment described by a JSON file so that everyone who opens the project gets the identical setup. The spec lives at [containers.dev](https://containers.dev) and is not GitHub-specific (VS Code, IntelliJ and others implement it). The pieces we use:

- **`image`** — the base. `mcr.microsoft.com/devcontainers/base:ubuntu` is a maintained Ubuntu with common dev tooling.
- **`features`** — composable install units, each a published OCI artifact under `ghcr.io/devcontainers/features/*`. They run in sequence at build time. We use two:
  - **docker-in-docker** — installs a Docker daemon *inside* the container (`privileged: true` under the hood, Moby engine, a named volume for `/var/lib/docker`). This is what lets kind create node-containers inside the codespace.
  - **sshd** — runs an SSH server so `gh codespace ssh` and `gh codespace cp` can reach the container from outside the editor.
- **`hostRequirements`** — machine-shape constraints (`cpus`, `memory`, `storage`). `cpus: 2` pins the smallest (free-tier-friendly) machine.
- **`forwardPorts`** — ports to register with the forwarding service at startup (Part 4 explains why this is essential for the public-URL flow).
- **`postCreateCommand`** — a command that runs once after the container is built, as the `vscode` user. We point it at `setup.sh`.

**docker-in-docker vs docker-outside-of-docker.** The other common pattern mounts the *host's* Docker socket into the container ("outside of docker") so containers you start are siblings on the host daemon. We deliberately use docker-**in**-docker so the codespace has its *own* isolated daemon: kind's node containers, the images, everything stays inside the codespace and is destroyed with it. Cleaner isolation, and it matches how a student's local kind setup behaves.

---

## Part 2 — Three real build failures (the actual lesson)

### Failure 1 — the feature that fails on a keyserver (recovery container)

The first devcontainer used the `ghcr.io/devcontainers/features/kubectl-helm-minikube` feature. The build failed and the codespace came up in a **recovery container** — a bare `mcr.microsoft.com/devcontainers/base:alpine` with *none* of the declared tools. The symptom from `gh codespace ssh`:

```
bash: line 1: docker: command not found
bash: line 1: kind: command not found
```

The root cause, from `/workspaces/.codespaces/.persistedshare/creation.log`:

```
#13 0.348 Downloading kubectl...
#13 0.908 /usr/local/bin/kubectl: OK
#13 5.957 Downloading Helm...
#13 12.12 (*) Keyserver hkp://keyserver.pgp.com is not reachable.
#13 12.52 Verification failed!
#13 12.52 gpg: no valid OpenPGP data found.
ERROR: Feature "Kubectl, Helm, and Minikube" failed to install!
Container creation failed. → Creating recovery container.
```

kubectl installed fine; the Helm step tried to GPG-verify the download against a public keyserver, the keyserver was unreachable, the feature aborted, and because feature installs are atomic the **whole build failed**. Codespaces' fallback — a recovery container — is a usability trap: the codespace is "Available" but useless, and nothing on the surface says why.

**Fix:** drop the feature; install kubectl/helm/kind in `setup.sh` from official binaries verified by **sha256 checksum files** (downloaded over the same HTTPS as the binary — no third-party keyserver). See `setup.sh`.

**Lesson:** a convenience feature that adds an external runtime dependency (a keyserver) to your *build* is a reliability liability for a lab many people run at once. Prefer install methods whose only dependency is the artifact host itself.

### Failure 2 — no SSH server

With the flaky feature gone, the build succeeded — but `gh codespace ssh` failed:

```
error getting ssh server details: failed to start SSH server:
Please check if an SSH server is installed in the container.
```

The base image + docker-in-docker has no `sshd`. The browser editor reaches the container over the VS Code server channel (no sshd needed), but the **CLI** (`gh codespace ssh`) needs a real SSH server.

**Fix:** add `ghcr.io/devcontainers/features/sshd:1`. (If you only ever use the browser, you can skip it — but the CLI flow, and any automated testing, needs it.)

### Failure 3 — helm installed but not executable

After switching Helm to the official `get-helm-3` convenience script, `helm version` failed:

```
bash: /usr/local/bin/helm: Permission denied
$ ls -la /usr/local/bin/helm
-rwxr-xr--  1 root root ... /usr/local/bin/helm
```

Mode `0754`: executable for owner (`root`) and group, but the **other** class — which the non-root `vscode` user falls into — had `r--`, no execute bit. The script's install path left the wrong permissions for a non-root runtime user.

**Fix:** install Helm like the others — download the tarball + its `.sha256`, verify, and `sudo install -m 0755`. `install -m 0755` guarantees the execute bit for everyone.

**Lesson:** in a container the runtime user is often non-root (`vscode`). "Works when I test as root" hides permission bugs. Always install shared binaries `0755`.

---

## Part 3 — Billing mechanics (verified against the docs)

The free tier for personal accounts: **120 core-hours + 15 GB-month of storage per month**, no payment method required.

- **Core-hours = real hours × machine cores.** The 2-core machine (`basicLinux32gb`) burns 2 core-hours/hour → 120 ÷ 2 = **~60 real hours/month**. 4-core → ~30; 8-core → ~15. The `hostRequirements.cpus` and the `-m` flag pick the machine; smaller = more hours.
- **Stopped codespaces bill storage only**, not compute. A stopped codespace keeps its disk (counts against 15 GB-month) but the core-hour clock is paused.
- **Idle auto-stop** defaults to **30 minutes** (configurable 5–240 in your settings) — a forgotten codespace stops billing compute on its own.
- **Retention auto-delete:** unused codespaces are removed after **30 days** of inactivity (configurable), reclaiming the storage.
- **Prebuilds** (a paid/org feature) cache the built container image so create is near-instant; not needed for this lab, but the reason a team's codespaces open in seconds.

Practical budgeting: 60 real hours is plenty for a course, but the multiplier is the trap — a 4-core machine left running is 4× the burn of a stopped 2-core. Stop deliberately; rely on the 30-min auto-stop as a backstop, not a plan.

---

## Part 4 — Port forwarding and the public URL

### Why `forwardPorts` is required for the CLI flow (verified)

Without `forwardPorts`, after starting `kubectl port-forward --address 0.0.0.0 ... 8080:80`:

```
$ gh codespace ports          # empty
$ gh codespace ports visibility 8080:public
error getting tunnel port: ... 404 Not Found
```

The process *was* listening, but the forwarding **tunnel port** had not been registered, so there was nothing to make public. Port auto-detection is a function of the running VS Code server; over a pure SSH/CLI session it did not register the port. Declaring `"forwardPorts": [8080]` makes Codespaces create the tunnel port at startup, after which:

```
$ gh codespace ports
web-app  8080  private  https://<name>-8080.app.github.dev
$ gh codespace ports visibility 8080:public
$ gh codespace ports
web-app  8080  public   https://<name>-8080.app.github.dev
```

In the **browser**, auto-detection does work (the PORTS tab shows the port when something listens), so `forwardPorts` is belt-and-braces there — but it makes the label/visibility predictable and is mandatory for the CLI path.

### The tunnel and the URL

The public hostname is `https://<codespace-name>-<port>.app.github.dev`. GitHub runs a managed reverse tunnel from that hostname into the codespace — conceptually identical to ngrok/Cloudflare (outbound connection from the environment to an edge), but built in and free. The app must be listening on the forwarded port inside the codespace; `kubectl port-forward --address 0.0.0.0` is what bridges the in-cluster Service to that port.

### Visibility and the security model (verified)

| Visibility | Who can reach the URL | Verified behavior |
|---|---|---|
| **private** (default) | Only you, GitHub-authenticated | Anonymous `curl` → **HTTP 302** redirect to GitHub login |
| **org** | Anyone in your organization | Org-authenticated |
| **public** | Anyone with the URL | Anonymous `curl` → your app (verified: nginx page) |

The discipline is the same as any tunnel: **public means internet-reachable**, so never expose a service with secrets, debug endpoints, or no auth, and assume the URL will be discovered. Private is the safe default; make a port public only for as long as a demo needs it, then set it back.

---

## Part 5 — Codespaces vs local, and when to reach for it

| | Local (Docker Desktop + kind) | Codespaces |
|---|---|---|
| Setup | Install Docker, kind, kubectl yourself | Nothing — open a browser |
| Reproducibility | "Works on my machine" drift | Identical for everyone (devcontainer) |
| Cost | Free (your hardware) | Free tier, then core-hours |
| Power on weak laptops | Limited by your RAM/CPU | Cloud machine (2–32 cores) |
| Offline | Works | Needs internet |
| Public sharing | Needs a tunnel | Built-in `*.app.github.dev` |

Reach for Codespaces when: a laptop can't run Docker, you want every student on an identical environment, you need a throwaway cloud machine bigger than your laptop, or you want to share a running app without configuring a tunnel. Stick with local when: you are offline, you want zero quota worries, or you are iterating fast on something small. The skills are identical — it is the same kind, the same kubectl — so moving between them is free.

---

## Cleanup

```bash
gh codespace delete -c <name> --force
gh codespace list
```

The lab repo persists as the template. A deleted codespace stops all billing and its public URL dies immediately.

## Discussion questions

1. A classmate's codespace is "Available" but `docker` is not found. What single file would you read first, and what class of failure are you looking for?
2. Why does the browser editor reach the container without sshd while `gh codespace ssh` cannot? What does that tell you about how each connects?
3. `helm` installed successfully but won't run as the `vscode` user. Explain the permission math, and the one-flag fix.
4. You start a port-forward, the process is clearly listening, but `gh codespace ports visibility ... public` returns 404. What is missing and why?
5. Your free tier is 120 core-hours. You run a 4-core codespace 3 hours a day. How many days until you are out, and what two settings most cheaply extend that?
6. A public `*.app.github.dev` URL is convenient for a demo. List three things you must check before making a port public on a real project.

## Troubleshooting

| Symptom | Root cause | Fix |
|---|---|---|
| Codespace Available but `docker`/`kind` not found | Build failed → recovery container (often a feature's external dependency, e.g. a GPG keyserver) | Read `creation.log`; replace the flaky feature with binary+sha256 installs in `setup.sh`; rebuild |
| `gh codespace ssh` → "failed to start SSH server" | No sshd in the image | Add `ghcr.io/devcontainers/features/sshd:1` |
| `helm: Permission denied` | Binary installed mode 0754; non-root `vscode` is "other" | Reinstall with `sudo install -m 0755` |
| `gh codespace ssh` session exits 255 when backgrounding a process | The SSH session closes and takes the child with it | Run the long process in the foreground inside a held session (or a tmux/screen), not `nohup &` |
| `gh codespace ports` empty / `visibility` → 404 | Tunnel port not registered (no `forwardPorts`, CLI-only) | Add `"forwardPorts": [8080]`; recreate |
| Public URL → 302 / GitHub login | Port is private | `gh codespace ports visibility 8080:public` |
| Public URL → 502/503 | App/Pod not ready behind the forward | `kubectl get pods`; confirm `port-forward` is running |
| Burning core-hours fast | 4/8-core machine, or left running | Use 2-core; rely on idle auto-stop; `gh codespace stop` |
| First build very slow | Features + image pull, no prebuild | Expected once; `stop`/`start` reuses the build |

## References

- [GitHub — Introduction to dev containers](https://docs.github.com/en/codespaces/setting-up-your-project-for-codespaces/adding-a-dev-container-configuration/introduction-to-dev-containers) — the devcontainer.json model
- [containers.dev](https://containers.dev/) — the dev container spec and the features registry
- [GitHub — About billing for Codespaces](https://docs.github.com/en/billing/managing-billing-for-github-codespaces/about-billing-for-github-codespaces) — core-hours, storage, the free allowance
- [GitHub — Forwarding ports in your codespace](https://docs.github.com/en/codespaces/developing-in-a-codespace/forwarding-ports-in-your-codespace) — visibility, the URL scheme, the security model
- [GitHub — docker-in-docker feature](https://github.com/devcontainers/features/tree/main/src/docker-in-docker) — what the feature installs and its options
- [kind — Quick Start](https://kind.sigs.k8s.io/docs/user/quick-start/) — the cluster running inside the codespace
