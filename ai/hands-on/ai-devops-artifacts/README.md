# Hands-on 00: AI-Assisted DevOps Artifact Generation

## Objective

A large fraction of DevOps work involves writing configuration files,
infrastructure code, and CI/CD pipelines — artifacts that follow known
patterns and conventions. LLMs are highly effective at generating first
drafts of these artifacts, but the quality of the output depends entirely
on the quality of the input prompt.

This hands-on is a structured workout in prompt engineering for DevOps.
You will write the same artifact four times, using four different prompting
strategies, and compare the outputs systematically.

By the end of this hands-on you will be able to:
- Apply zero-shot, few-shot, and chain-of-thought prompting to DevOps tasks
- Add constraints, context, and negative examples to a prompt to improve output quality
- Evaluate AI-generated infrastructure code critically — not just accept it
- Know when a task is a good candidate for AI assistance and when it is not

---

## Setup

No tools to install. You need:
- An LLM chat interface (Claude, ChatGPT, Cursor, GitHub Copilot Chat — your choice)
- A text editor to keep notes

**How to use this hands-on:** Each exercise gives you a scenario and a sequence
of prompts. After each prompt, paste the AI output into your editor. After all
variations, answer the comparison questions at the end of each exercise.

The application we are building infrastructure for is a Python/Flask web API
that connects to a PostgreSQL database. Its full source is in `reference/app.py`.

---

## Exercise 1 — Dockerfile: Zero-shot to Expert-level prompt

You need a production-ready Dockerfile for the Flask application.

### 1.1 Zero-shot (just state the task)

Paste this prompt into your AI tool:

```
Write a Dockerfile for a Python Flask application.
```

Record the output. Now evaluate it:
- Does it use a specific Python version, or just `python:latest`?
- Does it use a non-root user?
- Does it use `gunicorn` or the Flask development server?
- Is there a multi-stage build?
- Are there any obvious security problems?

### 1.2 Add context (describe the application)

```
Write a Dockerfile for a Python Flask web application with these characteristics:
- Python 3.11
- Dependencies: flask==3.0.0, psycopg2-binary==2.9.9, gunicorn==21.2.0
- The app listens on port 8080
- It reads DATABASE_URL from an environment variable
- It is started with: gunicorn --bind 0.0.0.0:8080 app:app

The Dockerfile will be used in production.
```

Compare the output with 1.1. What improved? What is still missing?

### 1.3 Add constraints (tell it what NOT to do)

```
Write a production-ready Dockerfile for a Python Flask web application with these characteristics:
- Python 3.11
- Dependencies: flask==3.0.0, psycopg2-binary==2.9.9, gunicorn==21.2.0
- The app listens on port 8080, started with: gunicorn --bind 0.0.0.0:8080 app:app

Requirements:
- Use a multi-stage build to keep the final image small
- Run the application as a non-root user
- Do NOT copy the entire project directory — only copy what is needed to run
- Do NOT install development dependencies in the final stage
- Pin the base image to a specific digest or version tag — never use "latest"
- Add a HEALTHCHECK instruction
```

Compare with 1.2. What changed?

### 1.4 Few-shot (show an example of what "good" looks like)

Few-shot prompting works by providing one or more examples before the actual
request. This anchors the model to a specific style and quality bar.

```
Here is an example of a Dockerfile I consider well-written:

--- EXAMPLE START ---
FROM node:20.11-alpine3.19 AS builder
WORKDIR /build
COPY package*.json ./
RUN npm ci --only=production

FROM node:20.11-alpine3.19
RUN addgroup -S app && adduser -S app -G app
WORKDIR /app
COPY --from=builder /build/node_modules ./node_modules
COPY --chown=app:app src/ ./src/
USER app
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s CMD wget -qO- http://localhost:3000/health || exit 1
CMD ["node", "src/index.js"]
--- EXAMPLE END ---

Following the same style and quality bar, write a Dockerfile for a Python Flask application:
- Python 3.11
- Dependencies: flask==3.0.0, psycopg2-binary==2.9.9, gunicorn==21.2.0
- App listens on port 8080, started with: gunicorn --bind 0.0.0.0:8080 app:app
- The dependency file is requirements.txt
```

### 1.5 Comparison questions

After generating all four versions, answer:
1. Which version produced the best Dockerfile? What made it better?
2. The zero-shot prompt almost certainly used `python:latest` or `python:3.11`
   without a specific tag. Why is this a problem in production?
3. The few-shot prompt used a Node.js example for a Python task. Did the model
   transfer the pattern correctly? What does this tell you about how few-shot
   prompting works?
4. Is any of the four Dockerfiles production-ready as-is? What would you still
   need to verify or change before using it in a real pipeline?

---

## Exercise 2 — GitHub Actions workflow: Chain-of-thought prompting

Chain-of-thought prompting asks the model to reason step by step before
producing an answer. It is particularly effective for tasks with multiple
interdependent requirements, like CI/CD pipelines.

### 2.1 Direct request (no reasoning)

```
Write a GitHub Actions workflow that builds and pushes a Docker image to
Docker Hub when code is pushed to the main branch.
```

Record the output.

### 2.2 Chain-of-thought prompt

```
I need a GitHub Actions workflow for a Python Flask application. Before writing the YAML,
think through the requirements step by step:

1. What triggers should this workflow have? (Consider: main branch pushes, pull requests,
   and whether the PR trigger should build but not push.)
2. What environment variables and secrets will be needed?
3. What steps are required in order? Think about caching, security scanning,
   and image tagging strategies.
4. What is a good image tagging strategy for production? (Consider: latest,
   git SHA, semantic version.)
5. Should this workflow run on pull requests as well as pushes? What is the
   difference in behaviour?

After reasoning through these questions, write the complete workflow YAML.

Context:
- The application is a Python Flask API
- The Docker image should be pushed to Docker Hub (username: mycompany)
- The image name should be mycompany/flask-api
- Production deployments happen from the main branch only
- On pull requests, the workflow should build and test but NOT push
```

### 2.3 Add a specific requirement mid-conversation

After the model responds to 2.2, send this follow-up in the same conversation:

```
Good. Now add these requirements to the workflow:
1. Run the existing unit tests (pytest tests/) before building the Docker image.
   If tests fail, the build should not run.
2. Add a step that scans the Docker image for known CVEs using Trivy.
   The pipeline should fail if any CRITICAL vulnerabilities are found.
3. Add a step that sends a Slack notification if the main branch build fails.
   Use a webhook secret called SLACK_WEBHOOK_URL.
```

### 2.4 Comparison questions

1. Compare the direct request (2.1) with the chain-of-thought result (2.2).
   How many of these elements were in 2.1: separate triggers for PR vs push,
   image tagging with git SHA, caching Docker layers, not pushing on PRs?
2. The follow-up message in 2.3 added requirements to an existing answer. This
   is called **iterative refinement**. What are the risks of this approach
   versus putting all requirements in the first prompt?
3. The workflow includes secrets for Docker Hub credentials. How should a
   team manage these secrets? What should NOT appear in the YAML file?
4. Would you merge the workflow produced by 2.2 + 2.3 into your codebase
   without modification? List the things you would check first.

---

## Exercise 3 — Terraform: Context-rich prompting for IaC

Infrastructure as Code is where prompt quality matters most — a generated
Terraform resource that looks correct but uses deprecated arguments or has
insecure defaults will pass review and cause problems in production.

### 3.1 Minimal prompt

```
Write Terraform to create an Azure Container Registry.
```

### 3.2 Context + constraints prompt

```
Write Terraform (azurerm provider ~> 4.0) to create an Azure Container Registry
with the following requirements:

Infrastructure context:
- This ACR will store Docker images for a production Flask application
- It will be used by an AKS cluster in the same resource group
- The resource group already exists; use a data source to reference it
- The resource group name will be provided via a variable

ACR requirements:
- SKU: Basic (sufficient for our scale)
- Geo-redundancy: disabled (cost saving for non-critical use case)
- Admin account: disabled (we use managed identities, not username/password)
- Retention policy: delete untagged manifests after 7 days

Variables required:
- resource_group_name (string)
- location (string, default: "westeurope")
- acr_name (string)

Outputs:
- acr_login_server (the FQDN used to push/pull images)
- acr_id (used to assign role-based access from AKS)

Do not include provider configuration or backend configuration — just the
resource definitions, variables, and outputs.
```

### 3.3 Evaluate and critique

After receiving the output from 3.2, ask the model to critique its own output:

```
Review the Terraform code you just wrote. Identify:
1. Any arguments that are deprecated or have changed in azurerm ~> 4.0
2. Any security concerns with the current configuration
3. Any missing tags or naming convention practices that a mature infrastructure
   team would typically require
4. Anything that should be parameterized but is currently hardcoded

Be direct — if there are no issues with a category, say so.
```

### 3.4 Comparison questions

1. The minimal prompt (3.1) almost certainly produced Terraform that works but
   is not production-ready. What specific differences did the context + constraints
   prompt introduce?
2. Asking the model to critique its own output (3.3) is called **self-review prompting**.
   Did the model find real issues? Were there issues it missed? What does this
   tell you about using AI for security reviews?
3. Generated Terraform often uses argument names that are correct for an older
   provider version. How would you verify whether the generated code is
   compatible with the provider version you are actually using?
4. The context prompt says "do not include provider configuration". Why is this
   a useful constraint when generating IaC modules?

---

## Exercise 4 — Prompt anti-patterns: What to avoid

This exercise is different — you are given bad prompts and must identify and
fix the problems.

### 4.1 Identify the problems in each prompt

For each of the following prompts, explain what is wrong and write an improved
version. Do NOT submit them to an AI yet.

**Prompt A:**
```
Make my Dockerfile better
```

**Prompt B:**
```
Write a GitHub Actions pipeline that does everything we need for our project
```

**Prompt C:**
```
Is this Kubernetes manifest correct?
```
*(No manifest is attached.)*

**Prompt D:**
```
Write Terraform for our entire cloud infrastructure on Azure including networking,
compute, databases, monitoring, and security. Make it production-ready and follow
all best practices.
```

### 4.2 The "trust but verify" rule

After you have improved the four prompts above and received outputs, apply
this verification checklist to the generated code:

- [ ] Does it reference specific versions (base images, provider versions, action versions)?
- [ ] Are there hardcoded values that should be variables or secrets?
- [ ] Does it contain any instructions that would fail silently (e.g., `|| true` in bash)?
- [ ] Are there security configurations that are disabled "for simplicity"?
- [ ] Does it use deprecated APIs or arguments (check official docs)?

### 4.3 When NOT to use AI

Discuss in pairs: for which of these tasks would you NOT use an AI to generate
the first draft, and why?

- Writing a Kubernetes NetworkPolicy that restricts pod-to-pod traffic
- Writing a Terraform module for a new Azure resource you have never used
- Debugging a CI/CD pipeline that has been working for 6 months and suddenly fails
- Writing a Prometheus alerting rule for a metric you do not fully understand
- Generating a `README.md` for a Terraform module

---

## Key concepts

| Concept | Description |
|---------|-------------|
| Zero-shot | Ask the task directly with no examples or reasoning guidance |
| Few-shot | Provide one or more examples before the actual request |
| Chain-of-thought | Ask the model to reason step by step before producing the answer |
| Iterative refinement | Continue in the same conversation to add or change requirements |
| Self-review | Ask the model to critique its own output — finds some but not all issues |
| Context richness | The more relevant context you provide, the less the model has to guess |
| Negative constraints | Telling the model what NOT to do is often as important as what to do |
| Trust but verify | Always review AI output against official documentation before using in production |
