# Learning Resources for Kubernetes

A curated selection of resources ordered by type and level. Each entry explains what makes it valuable and when to use it.

---

## Official Documentation

### [Kubernetes.io — Official Docs](https://kubernetes.io/docs/home/)

**Why use it:** This is the source of truth. Any other resource can become outdated; the official docs are updated with every project release. They include browser-based interactive tutorials (no installation needed), well-explained conceptual guides, and a complete API reference.

**When to use it:** Whenever you need to understand the exact behavior of an object, a manifest field, or a recent feature. Always check here before going to Stack Overflow.

**Highlighted sections:**
- [Concepts](https://kubernetes.io/docs/concepts/) — architecture, workloads, networking, storage
- [Tasks](https://kubernetes.io/docs/tasks/) — step-by-step guides for specific operations
- [Reference](https://kubernetes.io/docs/reference/) — complete API spec

---

## Interactive Courses and Platforms

### [Killercoda](https://killercoda.com/kubernetes)

**Why use it:** A real Kubernetes environment in the browser with no local installation required. Offers interactive scenarios with automatic validation. Great for practicing `kubectl` commands and manifests without risking anything on your own machine.

**When to use it:** As a companion to any theory course — right after reading about a concept, jump into Killercoda and practice it in 10 minutes. Also has scenarios targeted at the CKA/CKAD exams.

---

### [KodeKloud — Kubernetes for Beginners](https://kodekloud.com/courses/kubernetes-for-beginners/)

**Why use it:** Produces the best preparatory courses for official CNCF certifications (CKA, CKAD, CKS). Combines video with integrated hands-on labs. Mumshad Mannambeth (the main author) is exceptionally clear at explaining complex concepts.

**When to use it:** If you want a structured learning path from zero to advanced, or if you're planning to get certified. The KodeKloud CKA course is the de facto industry standard.

---

### [Linux Foundation — LFS158x: Introduction to Kubernetes](https://training.linuxfoundation.org/training/introduction-to-kubernetes/)

**Why use it:** Free on edX, delivered by the Linux Foundation itself (which maintains Kubernetes alongside the CNCF). Covers architecture, control plane components, workloads, and networking with academic rigor.

**When to use it:** When you need a solid, formal foundation before moving to more hands-on platforms. Particularly useful if you'll be working with infrastructure teams that require understanding the "why" behind each component.

---

## Video and YouTube

### [TechWorld with Nana — Kubernetes Tutorial for Beginners](https://www.youtube.com/watch?v=X48VuDVv0do)

**Why use it:** The most-watched Kubernetes introduction video on YouTube (over 5 hours, free). Nana has a gift for building the right mental model: she explains the problem each concept solves before teaching the command. Production quality is excellent.

**When to use it:** As your first exposure to the topic, before any interactive course. Watch at 1.5x speed and pause on manifests to replicate them yourself.

---

### [Fireship — Kubernetes in 100 Seconds](https://www.youtube.com/watch?v=PziYflu8cB8)

**Why use it:** A visually dense summary in 100 seconds. It won't teach you Kubernetes, but it locks in the vocabulary and big picture so that everything else you study lands faster.

**When to use it:** As the very first video (before anything else), or as a quick refresher before an interview.

---

## Books

### [Kubernetes in Action — Marko Lukša (Manning)](https://www.manning.com/books/kubernetes-in-action-second-edition)

**Why use it:** The most complete technical book on Kubernetes. It doesn't just teach the tool — it explains the design principles behind every decision. If you understand why Kubernetes works the way it does, you can debug any problem even if you've never seen it before.

**When to use it:** Once you have basic practical experience and want to go deep. Not a starting point, but the reference book that pays off the most long-term.

---

### [The Kubernetes Book — Nigel Poulton](https://nigelpoulton.com/books/)

**Why use it:** Concise, frequently updated, and very accessible. Nigel writes directly for professionals who need to get up to speed fast, with no filler. Low price point and an excellent quality-to-time-invested ratio.

**When to use it:** When you want a book you can read cover-to-cover over a weekend and come out with operational knowledge. A good primer before tackling *Kubernetes in Action*.

---

## Real-World Enterprise Use Cases

Knowing `kubectl` is not the same as knowing how Kubernetes is operated in a real company. The resources in this section show **what problems Kubernetes actually solves at scale, what architectures are built around it, and what numbers a business cares about** (release frequency, page-load time, cost per cluster, time-to-onboard a new service). Use them to connect the technology you are learning with the way you will encounter it in your first job.

### [CNCF Case Studies](https://www.cncf.io/case-studies/)

**Why use it:** The canonical source of "who runs Kubernetes in production, and why." The Cloud Native Computing Foundation curates hundreds of case studies from end-user organizations (Adobe, Adidas, Booking.com, CERN, Spotify, Pinterest, Zalando, OVHcloud and many more). Each one follows the same structure: business challenge, cloud-native solution, and **quantifiable outcomes** (number of pods, release frequency, cost reduction, latency improvement). It is the best way to build a mental catalogue of "what Kubernetes is used for" beyond the toy examples.

**When to use it:** Whenever you read about a new concept and want to see it applied for real — search the portal by company or by technology (Argo, Cilium, Prometheus…). Also useful when preparing for interviews: being able to cite "Adidas went from a 4-week release cycle to several deploys a day after moving to Kubernetes" carries far more weight than reciting definitions.

**Recommended starting point:** the [Adidas case study](https://www.cncf.io/case-study/adidas/) — a clean example of bureaucracy and slow VMs as the *real* problem, with containerization as the answer.

---

### [Keynote: How Spotify Accidentally Deleted All its Kube Clusters with No User Impact — David Xia, KubeCon Europe 2019](https://www.youtube.com/watch?v=ix0Tw8uinWs)

**Why use it:** A 25-minute keynote that does more for your operational maturity than most blog posts. David Xia (Spotify infrastructure engineer) walks through how Spotify deleted its production Kubernetes clusters by mistake — and why nobody noticed. The talk is a masterclass on the principles that make a cluster *recoverable*: declarative infrastructure (Terraform), regular backup/restore exercises (Ark/Velero), and running many smaller clusters instead of one big one. It also reframes "incidents" as a normal part of operating distributed systems rather than as failures to be hidden.

**When to use it:** Right after you finish the Kubernetes module. By that point you know what a cluster *is*; this talk shows you what it means to *operate* one in production with hundreds of services.

---

### [The Journey of Adidas to a Global Kubernetes Rollout — Daniel Eichten & Oliver Thylmann](https://www.youtube.com/watch?v=dwDhHt1Llb8)

**Why use it:** The companion video to the Adidas CNCF case study. Daniel Eichten (platform engineer at Adidas) and Oliver Thylmann (Giant Swarm) tell the story behind the numbers: how a retail company with a strong non-tech culture rolled out Kubernetes globally in six months, what they outsourced (cluster operations) and what they kept in-house (the developer-facing platform), and the cultural friction they hit on the way. It is one of the cleanest end-to-end "from monolith to cloud-native platform" stories on YouTube.

**When to use it:** When you want to understand **platform engineering** as a discipline — not as "I install Kubernetes," but as "I build the paved road my developers use to ship." Watch it together with the Adidas case study above; one gives you the numbers, the other gives you the story.

---

## Engineering Blogs Worth Following

Tech blogs from companies that run Kubernetes at scale are some of the best free learning material there is. Pick one or two and add them to your RSS reader or LinkedIn feed.

### [Spotify Engineering](https://engineering.atspotify.com/)

**Why use it:** Spotify is the company behind [Backstage](https://backstage.io/), the de facto open-source standard for internal developer portals — and most of the thinking that led to Backstage was published here first. The blog covers fleet management of clusters, developer-experience tooling, golden paths and platform-as-product thinking. Less raw infrastructure than Pinterest, more "how do we make 1000+ engineers productive on top of Kubernetes."

**When to use it:** When you want to understand the **platform** angle: what an internal developer platform looks like, what services it exposes, and how a large engineering org structures the contract between platform team and product teams.

---

### [Pinterest Engineering](https://medium.com/pinterest-engineering)

**Why use it:** Pinterest publishes some of the most detailed posts on the *scaling* edges of Kubernetes — cluster federation, controlling pod churn, etcd limits, autoscaler runaways, multi-tenant fairness. Their "Scaling Kubernetes with Assurance" series is particularly valuable: it documents real incidents (a single pod-creation spike that triggered 900 nodes coming up) and the controls they built to prevent recurrence.

**When to use it:** When the basics start feeling small and you want to see what happens to Kubernetes at thousands of nodes. Good preparation for senior SRE/platform roles.

---

### [Airbnb Tech Blog](https://medium.com/airbnb-engineering)

**Why use it:** Airbnb's blog mixes infrastructure with data and ML platform content, which mirrors the way most companies actually use Kubernetes today (as the substrate underneath data pipelines, ML training, and online services — not just stateless web apps). Good for seeing how the cluster is one layer of a much wider platform.

**When to use it:** When you want a more *product-shaped* view of platform engineering — how infrastructure decisions are justified in terms of developer velocity and business outcomes, not just technical elegance.

---

## Patterns and Reference Architectures

### [Kubernetes Patterns — Bilgin Ibryam & Roland Huß (O'Reilly)](https://developers.redhat.com/e-books/kubernetes-patterns)

**Why use it:** After you have seen enough real-world case studies, the same shapes start to repeat: sidecar containers for cross-cutting concerns, init containers for setup, controllers/operators for domain logic, leader election for singletons, predictable demands for the scheduler. This book — by two Red Hat engineers — catalogues those recurring shapes as named **patterns**, with the problem each one solves and a Kubernetes-native solution. It is the closest thing to a "Design Patterns" book for cloud-native systems.

**Free download:** Red Hat Developer makes the PDF available for free with a free Red Hat Developer account (no payment required). The same book is also on [O'Reilly](https://www.oreilly.com/library/view/kubernetes-patterns-2nd/9781098131678/) for paid access.

**When to use it:** After your first hands-on experience with Deployments, Services and ConfigMaps. The book stops being abstract once you have already wrestled with these primitives, and it pays off the most when you are about to design (not just deploy) your first non-trivial workload.

---

## Local Practice Environments

### [minikube](https://minikube.sigs.k8s.io/docs/start/)

**Why use it:** The standard for local Kubernetes development. Runs a single-node cluster in a VM or container on your machine. Supports addons (Ingress, Dashboard, metrics) and multiple drivers (Docker, VirtualBox, Hyper-V).

**When to use it:** For all labs in this module and for day-to-day development. The most stable option with the best documentation support.

```bash
minikube start
minikube addons enable ingress
minikube dashboard
```

---

### [kind (Kubernetes IN Docker)](https://kind.sigs.k8s.io/)

**Why use it:** Creates real multi-node clusters inside Docker containers. It's the tool used by Kubernetes maintainers themselves for testing. Starts faster than minikube and lets you simulate topologies with multiple control-plane and worker nodes.

**When to use it:** When you need to test multi-node cluster behavior (scheduling, node affinity, taints/tolerations) without spending money on cloud.

```bash
kind create cluster --config kind-config.yaml
kubectl get nodes
```

---

### [Docker Desktop](https://www.docker.com/products/docker-desktop/)

**Why use it:** If you already have Docker Desktop installed (Windows or macOS), enabling Kubernetes is a single checkbox in Settings → Kubernetes → Enable Kubernetes. No extra tooling needed. It provisions a single-node cluster using the same Docker daemon you already use for containers, so resource overhead is minimal.

**When to use it:** The lowest-friction option if you are on Windows or macOS and Docker Desktop is your daily driver. The trade-off is less flexibility than minikube (no addon system, no multi-node) and it ties your Kubernetes version to the Docker Desktop release cycle. Good enough for all the labs in this module.

```bash
# Enable in Docker Desktop UI, then verify:
kubectl config use-context docker-desktop
kubectl get nodes
```

---

### [MicroK8s](https://microk8s.io/)

**Why use it:** A lightweight, production-grade Kubernetes distribution by Canonical (Ubuntu). Installs as a single snap package directly on Linux — no VM, no Docker wrapper. Extremely low resource footprint, ships with its own `microk8s kubectl` wrapper, and has a rich addon system (DNS, Ingress, Prometheus, GPU support). Also runs on Raspberry Pi and ARM hardware.

**When to use it:** When you are on Linux and want the closest thing to a real production cluster without cloud costs. Also the go-to choice for edge computing, IoT, or CI runners on bare-metal Linux. Less common on macOS/Windows (requires a VM via Multipass).

```bash
# Install (Ubuntu/Linux)
sudo snap install microk8s --classic

# Enable core addons
microk8s enable dns ingress

# Alias kubectl for convenience
alias kubectl='microk8s kubectl'
kubectl get nodes
```

---

## Official Certifications (reference)

| Certification | Level | Focus |
|--------------|-------|-------|
| [CKAD](https://training.linuxfoundation.org/certification/certified-kubernetes-application-developer-ckad/) | Intermediate | Deploy and debug applications on K8s |
| [CKA](https://training.linuxfoundation.org/certification/certified-kubernetes-administrator-cka/) | Intermediate–Advanced | Administer and maintain clusters |
| [CKS](https://training.linuxfoundation.org/certification/certified-kubernetes-security-specialist-cks/) | Advanced | Cluster and workload security |

All three are hands-on exams (real terminal, 2 hours), not multiple choice. KodeKloud is the most community-recommended prep resource for all three.

---

## Local Kubernetes — going deeper

References for running real Kubernetes on your own machine and feeding it images — the official documentation behind the minikube, kind and k3d tooling, plus the ingress transition every cluster operator needs to understand. The minikube/kind/k3d decision matrix (when to pick which) lives in the **Local Kubernetes landscape lesson** in the course repository; the entries here are the primary sources to go deeper on whichever tool you picked.

### [k3d Documentation](https://k3d.io/)

**Why use it:** The official docs for k3d — K3s clusters inside Docker. Covers the pieces that make k3d the fastest "complete" local cluster: the built-in registry (`k3d registry create`), the klipper service load balancer, Traefik as default ingress, and multi-cluster/multi-node configuration via `k3d.yaml` config files.

**When to use it:** Whenever a k3d flag or default surprises you — especially the port-mapping (`--port`) and registry sections, which are where most first-time friction lives. The "Usage" guides are short and example-driven; read them before resorting to GitHub issues.

---

### [kind Documentation](https://kind.sigs.k8s.io/)

**Why use it:** The official site for kind (Kubernetes IN Docker), the tool the Kubernetes project itself uses to test Kubernetes. The "User Guide" documents the cluster config format (multi-node topologies, `extraPortMappings`, feature gates) and `kind load docker-image` — the canonical answer to "how do I get my local image into the cluster".

**When to use it:** When you need a disposable multi-node cluster for testing scheduling, affinity or taints, or when wiring kind into CI. The "Known Issues" page is genuinely useful — check it before debugging anything Docker-network-related.

---

### [K3s Documentation](https://docs.k3s.io/)

**Why use it:** K3s is the CNCF-certified lightweight Kubernetes distribution that k3d wraps — a single binary that runs a conformant cluster on anything from a Raspberry Pi to a free ARM cloud VM. The docs explain what K3s changes versus upstream (SQLite instead of etcd by default, bundled Traefik and klipper-lb, the agent/server split) and how to install it on bare Linux in one command.

**When to use it:** When you graduate from "K3s inside Docker via k3d" to "K3s directly on a Linux box" — a home server, an edge device, or an always-free cloud instance. Also the reference for understanding what k3d's defaults (Traefik, klipper) actually are underneath.

---

### [minikube Handbook](https://minikube.sigs.k8s.io/docs/handbook/)

**Why use it:** The handbook is the part of the minikube docs that goes beyond `minikube start`: drivers, profiles (multiple clusters side by side), the addon system, `minikube tunnel` for LoadBalancer services, image loading and registry options, mounting host folders and resource tuning. Most "minikube can't do X" complaints are answered by a handbook page.

**When to use it:** As the reference companion while minikube is your daily-driver cluster. The "Pushing images" page is worth reading even if you use kind or k3d — it catalogs every approach to the image-into-cluster problem in one place.

---

### [cloud-provider-kind](https://github.com/kubernetes-sigs/cloud-provider-kind)

**Why use it:** An official kubernetes-sigs project that fills kind's biggest gap: `Service` of type `LoadBalancer`. Run one binary on your host and every LoadBalancer Service in your kind clusters gets a real working external IP (it also implements Gateway API support) — no MetalLB configuration, no `<pending>` forever. It is the closest a local cluster gets to cloud load-balancer ergonomics.

**When to use it:** When re-running cloud-targeted labs (which assume LoadBalancer "just works") on kind, or when you want to practice the LoadBalancer/Gateway flow locally without the MetalLB setup detour.

---

### [Ingress NGINX Retirement Announcement (Kubernetes Blog, Nov 2025)](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/) and [Follow-up Statement (Jan 2026)](https://kubernetes.io/blog/2026/01/29/ingress-nginx-statement/)

**Why use it:** Required reading on why ingress is changing. ingress-nginx — for years the default ingress controller in roughly half of all clusters — was retired by the Kubernetes project, with maintenance ending in March 2026: no more releases, bug fixes or security patches. The first post explains the why (unsustainable maintainership, accumulated security debt) and the migration options; the second, from the Steering and Security Response Committees, escalates the urgency and is unambiguous that staying put means accumulating unpatched vulnerabilities. Together they are also a case study in how open-source infrastructure actually fails: not with an outage, but with maintainers running out.

**When to use it:** Before choosing an ingress controller for anything new (the answer is no longer "nginx by default" — Gateway API implementations and alternative controllers are the recommended paths), and before any interview that touches cluster operations: "what would you do about ingress-nginx?" is now a real question with a real answer.

---

### [Traefik Documentation](https://doc.traefik.io/traefik/)

**Why use it:** Traefik is the most natural successor path after ingress-nginx for local and small-cluster work: it is the default ingress controller shipped by K3s/k3d, it supports the standard `Ingress` resource, its own CRDs, *and* the Gateway API, and its docs are organized around concepts (entrypoints, routers, services, middlewares) that transfer across all three. Dynamic configuration discovery — watching Kubernetes resources and reconfiguring live — is the core idea to take away.

**When to use it:** When the ingress-nginx retirement posts leave you asking "so what do I run instead?", and as the reference whenever you touch the Traefik that k3d already installed for you. Start with the Kubernetes provider pages and the routing concepts.

---

### [Working with the GitHub Container Registry](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)

**Why use it:** The official reference for GHCR (`ghcr.io`) — the free OCI registry that gives any local cluster a realistic image workflow: authenticate with a personal access token, push with the full `ghcr.io/<user>/<image>:<tag>` name, control visibility, and link images to repositories with the `org.opencontainers.image.source` label. Public images pull anonymously, which is what makes GHCR the zero-friction registry for labs and personal platforms.

**When to use it:** Every time the image-pull workflow is the thing you are practicing — and any time a Pod sits in `ImagePullBackOff` against GHCR, since the authentication and visibility rules causing it are documented here, not in the error message.

---
