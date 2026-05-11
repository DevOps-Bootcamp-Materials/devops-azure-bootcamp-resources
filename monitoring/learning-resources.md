# Learning Resources for Monitoring and Observability

A curated selection of resources ordered by type and level. Each entry explains what makes it valuable and when to use it.

---

## Official Documentation

### [Prometheus — Official Docs](https://prometheus.io/docs/introduction/overview/)

**Why use it:** The canonical reference for everything Prometheus: data model, configuration, PromQL functions, alerting rules, and the exporter ecosystem. The documentation is written by the Prometheus maintainers and kept in sync with each release. It is dense but precise — if you want to know exactly what `histogram_quantile()` does at bucket boundaries, this is the only source that will not mislead you.

**When to use it:** Whenever you write a PromQL query you have not written before, configure a scrape target, or define an alerting rule. Also the right place to look up every available `prometheus.yml` field before relying on examples copied from the internet.

**Highlighted sections:**
- [Data model](https://prometheus.io/docs/concepts/data_model/) — time series, labels, samples
- [Metric types](https://prometheus.io/docs/concepts/metric_types/) — Counter, Gauge, Histogram, Summary
- [Querying basics](https://prometheus.io/docs/prometheus/latest/querying/basics/) — PromQL syntax reference
- [Configuration reference](https://prometheus.io/docs/prometheus/latest/configuration/configuration/) — every field explained

---

### [Grafana — Official Docs](https://grafana.com/docs/grafana/latest/)

**Why use it:** Grafana's documentation covers everything from datasource setup to provisioning, alerting, and the full panel editor. The section on provisioning (how to deliver datasources and dashboards as code) is particularly well written and directly applicable to what you do in these hands-on sessions.

**When to use it:** When configuring a datasource programmatically, writing provisioning YAML, setting up Grafana alerts, or understanding how the dashboard JSON schema is structured. Also useful when something that worked manually does not work in a provisioned setup.

**Highlighted sections:**
- [Provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/) — datasources and dashboards as code
- [Transformations](https://grafana.com/docs/grafana/latest/panels-visualizations/query-transform-data/transform-data/) — reshape query results before visualization
- [Alerting](https://grafana.com/docs/grafana/latest/alerting/) — native Grafana alerting (Grafana 9+)

---

### [Alertmanager — Configuration Reference](https://prometheus.io/docs/alerting/latest/configuration/)

**Why use it:** Alertmanager configuration can be tricky — routing trees, inhibition rules, receiver templates, and timing parameters all interact in non-obvious ways. The official config reference is the authoritative source for every field. Reading it once carefully saves hours of trial and error.

**When to use it:** When writing or debugging an `alertmanager.yml` — especially routing rules, `group_wait`/`group_interval` tuning, and receiver template syntax.

---

## Interactive Learning

### [Killercoda — Prometheus and Grafana scenarios](https://killercoda.com/prometheus)

**Why use it:** A real Linux environment in the browser where you can run Prometheus, Grafana, and Node Exporter without installing anything locally. Scenarios include guided steps with automatic validation. The feedback loop (type a command, see if it worked) is faster than any video.

**When to use it:** As a companion to theory — after reading about a concept, open Killercoda and practice it immediately. Particularly useful for PromQL exercises and alert rule configuration.

---

### [Play with Grafana](https://play.grafana.org)

**Why use it:** A live, publicly accessible Grafana instance with real datasources and a library of production-quality dashboards already loaded. You can explore any panel, click Edit, and read the PromQL queries behind it — no setup, no account required. It is the fastest way to understand how experienced teams structure their dashboards.

**When to use it:** Early in your Grafana learning to calibrate what a good dashboard looks like. Also useful for discovering visualization types and query patterns you would not think to try from scratch.

---

## Video and YouTube

### [TechWorld with Nana — Complete Prometheus Monitoring Tutorial](https://www.youtube.com/watch?v=h4Sl21AKiDg)

**Why use it:** Nana's monitoring series is the best free end-to-end introduction on YouTube. She covers Prometheus architecture, exporters, PromQL, Grafana, and Alertmanager in a logical sequence. Like her Kubernetes content, she explains the problem each tool solves before showing the solution — which is what makes the knowledge stick.

**When to use it:** As your first structured exposure to the full stack before the hands-on sessions. Watching it beforehand means the hands-on reinforces concepts you have already encountered, rather than introducing everything at once.

---

### [Grafana YouTube Channel — Grafana for Beginners series](https://www.youtube.com/playlist?list=PLDGkOdUX1Ujo3wHw9-z5Vo12YLqXRjzg2)

**Why use it:** Produced by Grafana Labs itself. The "Grafana for Beginners" playlist covers the full product — datasources, dashboards, panels, alerting, and Loki (log aggregation). Each video is focused and short (10-20 minutes). The production quality is high and the content is kept current.

**When to use it:** After the hands-on sessions, to fill in the gaps and explore features beyond what the labs cover (Grafana alerting, Loki, Tempo).

---

### [Fireship — Prometheus in 100 Seconds](https://www.youtube.com/watch?v=h4Sl21AKiDg)

**Why use it:** Dense visual summary of what Prometheus is and where it fits. Like all Fireship content, it does not teach you the tool — it locks in the vocabulary and mental model so that everything else you read lands faster.

**When to use it:** The very first video, before anything else. Then revisit it after the hands-on sessions to see how much more it contains than it seemed at first.

---

## Blogs and Written Guides

### [Robust Perception — Brian Brazil's Blog](https://www.robustperception.io/blog)

**Why use it:** Brian Brazil is one of the original Prometheus authors. His blog is the most technically precise writing on PromQL and Prometheus internals available anywhere. Every post is grounded in how the system actually works, not how people assume it works. Posts like *"How does a Prometheus Counter work?"* and *"Why are Prometheus histograms cumulative?"* resolve confusions that trip up even experienced engineers.

**When to use it:** When you encounter a PromQL result that does not make sense, or when you want to move from "using Prometheus" to "understanding Prometheus". Start with the PromQL category.

---

### [Prometheus Monitoring Mixins](https://monitoring.mixins.dev/)

**Why use it:** A community-maintained library of pre-built alerting rules, recording rules, and Grafana dashboards for common infrastructure and applications (Kubernetes, PostgreSQL, Redis, nginx, etc.). Each mixin is generated from a consistent codebase and follows production-tested conventions. Studying a well-built mixin is one of the fastest ways to understand how professional teams structure their observability.

**When to use it:** When you are building alerting for a known technology and want to understand what signals matter in production, without starting from a blank file. Also useful as a reference for naming conventions and annotation templates.

---

## Books

### [Prometheus: Up & Running — Brian Brazil (O'Reilly)](https://www.oreilly.com/library/view/prometheus-up/9781492034131/)

**Why use it:** The definitive book on Prometheus. Brian Brazil explains not just how to use the tool but why it works the way it does — the pull model, the staleness handling, the histogram design trade-offs. Every chapter is dense with information that is not easily found elsewhere. After reading this book you will understand Prometheus at a level that lets you debug any problem.

**When to use it:** Once you have practical experience from the hands-on sessions and want to go deep. This is not a starting point — it rewards readers who already know the basics. The PromQL chapter alone is worth the price.

---

### [The Art of Monitoring — James Turnbull](https://artofmonitoring.com/)

**Why use it:** Covers monitoring philosophy and practice beyond any single tool. Turnbull builds the mental model for why monitoring exists, what the four golden signals are, and how to think about alerting as a reliability practice — not just a technical configuration exercise. The tool coverage includes Prometheus, Graphite, and others.

**When to use it:** If you want to understand the principles behind monitoring before specialising in a specific stack. Particularly valuable for engineers who will be responsible for defining monitoring strategy, not just implementing it.

---

## Reference Cheatsheets

### [PromQL Cheat Sheet — promlabs.com](https://promlabs.com/promql-cheat-sheet/)

**Why use it:** A well-organised one-page reference for PromQL syntax, operators, and functions with concise examples. PromLabs is maintained by Julius Volz, one of the Prometheus co-founders. More reliable than random Stack Overflow answers.

**When to use it:** Keep it open during the hands-on sessions and whenever you write PromQL. The functions table and the label selector operators are the most-referenced sections.

---

### [Awesome Prometheus (GitHub)](https://github.com/roaldnefs/awesome-prometheus)

**Why use it:** A curated list of Prometheus exporters, dashboards, tools, and integrations maintained by the community. Useful when you need to find the right exporter for a technology you are instrumenting.

**When to use it:** When you need to monitor something not covered in the hands-on sessions (MySQL, Redis, JVM, AWS CloudWatch, etc.) and want to find the standard exporter before writing your own.

---

## Certifications (reference)

| Certification | Issuer | Level | Focus |
|--------------|--------|-------|-------|
| [Prometheus Certified Associate (PCA)](https://training.linuxfoundation.org/certification/prometheus-certified-associate/) | CNCF / Linux Foundation | Intermediate | Prometheus instrumentation, PromQL, alerting, Grafana basics |
| [Grafana Certified Professional](https://grafana.com/training/certification/) | Grafana Labs | Intermediate | Full Grafana product suite including Loki, Tempo, Mimir |

The PCA is a 90-minute multiple-choice exam. Unlike the Kubernetes certifications it is not hands-on, but studying for it is a structured way to ensure you cover all of Prometheus's surface area. The Grafana certification is newer and less widely recognised but relevant if you work primarily in the Grafana stack.

---
