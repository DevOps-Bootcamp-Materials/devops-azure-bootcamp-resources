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
