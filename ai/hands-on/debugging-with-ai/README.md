# Hands-on 01: Debugging Infrastructure with AI

## Objective

Generating artifacts is only half the value of AI in DevOps work. The other
half is debugging — taking a broken config, a failing pipeline, or a
misconfigured infrastructure file and figuring out what is wrong.

AI assistants are surprisingly good at this, but only when you give them
the right information. The most common mistake is pasting broken code and
asking "what's wrong?" without providing the error message, the context, or
the expected behaviour. A vague input produces a vague answer.

This hands-on builds the habit of structured debugging prompts: error + context
+ what you have already tried.

By the end of this hands-on you will be able to:
- Write debugging prompts that give the AI enough context to find real problems
- Distinguish AI-found issues from issues that require your own domain knowledge
- Know which categories of error AI tends to miss and why
- Use AI as a second-pass reviewer, not a first-pass replacement

---

## Setup

No infrastructure to deploy. All exercises use the broken files in the
`broken/` directory. You need an LLM chat interface.

---

## Part 1 — Docker Compose: three types of error

Open `broken/docker-compose.yml`. This file has three distinct types of errors:
a typo, a port conflict, and a network misconfiguration.

### 1.1 Vague prompt (what not to do)

First, try the lazy approach to see what it produces:

```
Here is my docker-compose.yml. It does not work. What is wrong with it?

[paste the content of broken/docker-compose.yml]
```

Record what the AI found. Did it find all three issues? Did it miss any?
Did it suggest things that are wrong but actually not problems?

### 1.2 Structured debugging prompt (what to do instead)

Now provide the error output and context:

```
I have a Docker Compose file for a web application stack (Python/Flask + PostgreSQL + Nginx).
When I run `docker compose up`, I get this error:

Error response from daemon: driver failed programming external connectivity on endpoint
ironhack-nginx-1: Bind for 0.0.0.0:8080 failed: port is already allocated

After fixing that and retrying, the Nginx container starts but returns 502 Bad Gateway
when I access http://localhost.

I have not changed the Nginx configuration file.

Here is the docker-compose.yml:
[paste the content of broken/docker-compose.yml]

Identify all issues, not just the port conflict. For each issue, explain:
1. What the problem is
2. Why it causes the symptom
3. The exact fix
```

Compare the two outputs. How many of the three issues did each prompt surface?

### 1.3 The hidden issue

One issue in the file is difficult for an AI to detect without more context:
the database container has a typo in an environment variable name. The AI may
or may not catch this depending on how carefully it reads the file.

Even if it does catch it, the fix requires knowing the correct PostgreSQL
environment variable name. After the AI responds, verify the correct variable
name in the official `postgres` Docker Hub documentation yourself.

**Lesson:** AI can spot typos if it happens to compare against its training
knowledge of official APIs. But you should not rely on it — always verify
environment variables, flag names, and API arguments against official docs.

---

## Part 2 — GitHub Actions: context changes everything

Open `broken/github-actions.yml`. It has:
- A typo in a runner name (fails immediately)
- A logic error (deploy runs on PRs from forks — will fail silently due to
  missing secrets)
- A missing step (SSH key setup before the SSH command)

### 2.1 Paste only the YAML

```
This GitHub Actions workflow is failing. What is wrong?

[paste the content of broken/github-actions.yml]
```

### 2.2 Paste the YAML + the actual error

In a real scenario you would have the Actions log. Simulate it:

```
This GitHub Actions workflow is failing. Here is the error from the Actions log:

  Error: ##[error]The job was found to have an invalid runner: ubuntu-lastest

After fixing that, the pipeline runs but the deploy step fails on pull requests
from contributors with this error:

  Error: Process completed with exit code 255.

The pipeline is supposed to: run tests, build and push a Docker image, then
deploy to production only on pushes to main (not on PRs).

Here is the workflow:
[paste the content of broken/github-actions.yml]

Identify all issues in the file, including any that are not directly causing
the current errors but represent security risks or logic problems.
```

### 2.3 Ask for a diff, not a rewrite

When debugging, you want to understand what changed, not receive a full
replacement. After the AI identifies issues, ask:

```
Instead of rewriting the whole file, show me only the specific lines that need
to change, in unified diff format.
```

A rewrite buries the actual fix in a wall of unchanged code. A diff is
surgical and reviewable.

### 2.4 The security issue the AI may miss

The workflow runs the deploy step with `if: github.ref == 'refs/heads/main'`,
which correctly prevents deployment on PRs. But `build-and-push` runs on
all PRs — including PRs from forked repositories.

On forked repo PRs, `secrets` are not available. The `docker/login-action`
step will fail with a misleading error. The correct fix is to add a condition
to the entire `build-and-push` job:

```yaml
if: github.event_name == 'push'
```

Check whether the AI suggested this fix. If it did not, add it to your prompt
as a follow-up:

```
I also need the build-and-push job to skip entirely on pull requests from forks.
The current setup will fail because forked repos don't have access to Docker Hub
secrets. How should I handle this?
```

---

## Part 3 — Terraform: logic errors vs syntax errors

Open `broken/main.tf`. It has both syntax-level errors (Terraform will
refuse to plan) and logic errors (Terraform will plan and apply successfully
but produce wrong or insecure infrastructure).

### 3.1 First pass: syntax errors

```
This Terraform configuration fails on `terraform plan`. Identify the errors
that prevent it from being parsed and executed:

[paste the content of broken/main.tf]
```

Terraform's own error messages are usually more accurate than what an AI
produces for syntax errors. When you know `terraform plan` has a specific
error, always include the error output:

```
`terraform plan` fails with:

  Error: Duplicate resource "azurerm_resource_group" "main"
    on main.tf line 18: A resource with the address
    "azurerm_resource_group.main" already exists.

Here is the configuration:
[paste the content of broken/main.tf]

There may be additional issues beyond this error. Review the entire file.
```

### 3.2 Second pass: security and logic errors

After fixing the syntax errors, ask for a security review:

```
The Terraform syntax errors are now fixed. Please review the configuration
for security and correctness issues that Terraform would not reject but that
represent bad practices or misconfigurations. Focus on:

1. Resource naming constraints (Azure-specific rules)
2. Security posture (what should not be enabled by default)
3. References that should use resource attributes instead of hardcoded values
4. Anything that would cause problems at scale

[paste the content of broken/main.tf]
```

### 3.3 What AI catches vs what it misses

The ACR name `MyAppACR` is invalid in Azure because ACR names must be
lowercase alphanumeric. The AI trained on Azure documentation should catch
this. Verify this in the [official Azure ACR naming rules](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-best-practices#registry-name).

The hardcoded subscription ID in the role assignment scope is a logic error
that any decent code review should catch. Check whether the AI flagged it
without being prompted.

The duplicate resource + data source for the same resource group is a
Terraform-specific error. AI trained on Terraform documentation should
catch it easily. Check whether it explained *why* you cannot have both.

---

## Part 4 — Prometheus alert rules: domain knowledge required

Open `broken/prometheus-alert.yml`. This file has five issues — some are
syntax or type errors, others are logical mistakes that produce alert rules
that technically work but behave incorrectly in production.

### 4.1 First pass: ask for a review

```
Review these Prometheus alerting rules for correctness and best practices.
The target application is a web API instrumented with the standard
prometheus/client libraries.

[paste the content of broken/prometheus-alert.yml]
```

### 4.2 Domain knowledge test

The most subtle issues in the file require understanding of how Prometheus
metrics work:

- **Issue 1:** Alerting on a raw counter (`http_requests_total > 1000`) does
  not measure rate — it measures the total number of requests since the process
  started. This will always eventually trigger and never resolve. The AI should
  suggest wrapping it in `rate()`.

- **Issue 5:** `for: 0s` means the alert fires on the very first evaluation
  that returns a non-empty result. Any transient network spike triggers a
  critical alert. The AI should flag this as a noise generator.

Check whether the AI correctly identified both of these. If it missed either,
add a follow-up:

```
The first alert queries a counter directly. What is the problem with this
approach for an alerting expression, and what is the correct pattern?
```

### 4.3 The $value formatting issue

Issue 3 is subtle: `$value` in the annotation is the raw ratio (e.g., `0.07`)
but the annotation text says it is a percentage. This produces messages like
"Error rate is 0.07% on instance" when the actual error rate is 7%.

Ask the AI to fix the annotation template:

```
The error rate alert description says "{{ $value }}%" but $value is a ratio
between 0 and 1, not a percentage. Fix the annotation template so the message
displays the value correctly formatted as a percentage.
```

The correct template uses the `printf` function:
```
"{{ printf \"%.1f\" (mul $value 100) }}%"
```

---

## Part 5 — Build your own broken file

This is the reverse exercise. Working in pairs:

1. Take a working configuration (use any file from the monitoring hands-on)
2. Introduce three intentional errors: one obvious (typo), one subtle (logic),
   one domain-specific (requires knowledge of the tool)
3. Swap with another pair and debug each other's files using AI
4. After the AI session, manually verify the complete list of errors and compare
   with what the AI found

---

## Discussion questions

1. In Part 1, the vague prompt and the structured prompt found different sets
   of issues. What was the key difference in what you provided? What rule
   would you derive for debugging prompts?
2. The AI found most typos and obvious errors but may have missed the logic
   error about fork PR secrets in the GitHub Actions workflow. Why is this
   type of error harder for an AI to detect?
3. For the Prometheus alert rules, the AI needs domain knowledge about how
   counters and `rate()` work. If you are debugging a system you do not fully
   understand, can you trust AI debugging output? What is the risk?
4. In Part 3, you asked the AI to produce a diff instead of a rewrite. When
   is a rewrite acceptable? When is it dangerous?

---

## Key concepts

| Concept | Description |
|---------|-------------|
| Structured debugging prompt | Error message + file content + expected behaviour + what you've tried |
| Diff vs rewrite | Request a diff for surgical fixes; a rewrite makes it hard to review what changed |
| Syntax error vs logic error | Syntax errors are caught by tools; logic errors require domain knowledge |
| AI's knowledge boundary | AI knows common patterns but may miss organisation-specific logic or obscure edge cases |
| Self-review limitation | AI self-review finds some issues but not all — never a substitute for a human reviewer |
| The `rate()` rule | Never alert on a raw counter. Always use `rate()` or `increase()` to measure change. |
