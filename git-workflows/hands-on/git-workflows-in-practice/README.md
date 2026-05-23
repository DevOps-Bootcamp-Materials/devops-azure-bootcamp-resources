# Git Workflows — Full deep-dive reference

This is the deep-dive companion to `week-17/git-workflows/hands-on/01_git_workflows_in_practice.md` in the bootcamp repo. Read that file first to run the hands-on end-to-end; come here when you want the full depth on any concept, edge case, or tooling integration.

Both the `commit-msg` hook and the PR description template referenced in the hands-on live in this folder.

## What this folder contains

- `README.md` — this file: the complete reference
- `commit-msg` — shell script enforcing Conventional Commits at commit time
- `.github/PULL_REQUEST_TEMPLATE.md` — starter PR description template; copy to your repo's `.github/` folder

## Prerequisites

- git installed
- GitHub account with `gh` CLI authenticated
- On Windows: Git Bash for the hook installation; PowerShell for everything else

## How to use this folder

```bash
git clone https://github.com/DevOps-Bootcamp-Materials/devops-azure-bootcamp-resources.git
cd devops-azure-bootcamp-resources/git-workflows/hands-on/git-workflows-in-practice
```

---

## Part 1 — Trunk-based development: the full picture

### What "always releasable" actually means

The first rule of trunk-based development is that `main` is always in a releasable state. In practice this means three things must be true at every point in time:

1. The code on `main` compiles (or parses, for interpreted languages).
2. The automated test suite passes.
3. The application can be deployed to production without manual intervention.

Rule 3 is the one teams underestimate. It rules out: migrations that are not backward-compatible with the previous deployment, configuration changes that require manual steps before the new code works, and feature work that is half-finished and would visibly break the user experience if deployed.

The mechanism that enforces all three is CI: every commit pushed to any branch triggers the build and test suite, and the merge button is disabled until CI passes. This is not optional — without CI enforcement, the rule degrades to "main is usually releasable" which is a much weaker guarantee.

### Short-lived branches: what "short-lived" means in numbers

The Accelerate research defines high-performing teams as those where branches live less than one day before merging. In practice for most teams the target is under two days. A branch that lives a week has already accumulated enough divergence that the merge will require non-trivial conflict resolution.

The primary blocker to short-lived branches is not technical — it is the habit of building complete horizontal layers before merging. "I'll merge the backend changes once the frontend is done" is a recipe for long-lived branches. The alternative is vertical slices: each slice delivers one small increment of user-visible or system-visible value, is independently deployable, and merges to `main` on its own.

Examples of splitting horizontal → vertical:
- Instead of: "add the database schema, then the API layer, then the frontend in three separate weeks" — merge the schema migration (behind a feature flag if needed), then the API endpoint (behind the same flag), then the UI component, then flip the flag.
- Instead of: "refactor all logging across the service before adding the new endpoint" — add the endpoint with the existing logging style, then refactor logging in a follow-up PR scoped to one module.

### Feature flags: the mechanism behind short-lived branches

A feature flag (also called a feature toggle) is a conditional in code that routes users to either the old code path or the new one based on a configuration value. The flag allows you to merge unfinished features to `main` without exposing them to users.

Minimal Python example:

```python
import os

def get_handler():
    if os.getenv("ENABLE_NEW_RATE_LIMITER", "false") == "true":
        return new_rate_limiter()
    return legacy_rate_limiter()
```

The flag is toggled by changing an environment variable, a config value, or a feature flag service entry — not by a code change. The new code path is deployed to production but inactive. When the feature is complete and tested, the flag is flipped. When the feature has been stable for a release cycle, the old code path and the flag are removed ("flag cleanup" is its own PR).

Feature flag services (LaunchDarkly, Unleash, Azure App Configuration feature management) add targeting rules (roll out to 1% of users, then 10%, then 100%), kill switches, and audit trails.

**When not to use flags:** flags are infrastructure code and they accumulate debt. Do not add a flag for a change that can be made backward-compatible and deployed incrementally without hiding it. The rule of thumb: flags for user-facing features and major architectural changes; no flags for bug fixes, refactors, or changes that are safe to expose immediately.

### Squash vs merge vs rebase: which to use in trunk-based development

When merging a PR to `main`, GitHub offers three strategies. The choice affects what `git log` on `main` looks like:

**Merge commit** (`git merge --no-ff`): creates a merge commit with the full branch history as parents. The history on `main` shows every individual commit from the branch plus the merge commit.

```
*   abc1234 Merge pull request #42 from feat/add-version-endpoint
|\
| * def5678 test(api): add unit test for version endpoint
| * ghi9012 feat(api): add /version endpoint returning semver string
|/
* jkl3456 chore: initialize project
```

Good when: the individual commits on the branch are clean and meaningful; the team wants a detailed history that matches the PR.

**Squash and merge**: all commits on the branch are squashed into one commit on `main`, using the PR title as the commit message.

```
* mno7890 feat(api): add /version endpoint returning semver string
* jkl3456 chore: initialize project
```

Good when: individual commits on the branch are WIP checkpoints and the PR title is the meaningful unit. This is the most common choice in trunk-based teams because it keeps `main` history exactly one commit per PR. The PR title must therefore follow Conventional Commits precisely.

**Rebase and merge**: replays each commit from the branch onto `main` with no merge commit, as if the branch commits were made directly on `main`.

```
* def5678 test(api): add unit test for version endpoint
* ghi9012 feat(api): add /version endpoint returning semver string
* jkl3456 chore: initialize project
```

Good when: every commit on the branch is clean and meaningful, and the team wants a linear history without merge commits. Requires that every commit on the branch follows Conventional Commits individually.

**Recommendation for this course and most DevOps teams:** squash and merge, with a strict title convention enforced by the `commitlint` CI check described in Part 3.

---

## Part 2 — The Conventional Commits specification in full

### The full grammar

The complete EBNF grammar from the specification:

```
commit-message  ::= summary CRLF? (CRLF? body)? (CRLF? CRLF? footer-section)*
summary         ::= type ("(" scope ")")? breaking-mark? ":" SP description
type            ::= "feat" | "fix" | "docs" | "style" | "refactor"
                  | "perf" | "test" | "chore" | "ci" | "build" | "revert"
scope           ::= 1*(letter | digit | "-" | "_" | "/")
breaking-mark   ::= "!"
description     ::= 1*<any UTF-8 except CRLF>
body            ::= 1*<any UTF-8>
footer-section  ::= footer-token ":" SP footer-value
                  | footer-token " #" footer-value
footer-token    ::= "BREAKING CHANGE" | word
footer-value    ::= 1*<any UTF-8 except CRLF>
```

The key rules:

- There is exactly one space after the colon (`": "`, not `":"` or `":  "`).
- The description must not start with a capital letter (debated, but the angular preset used by most tooling enforces lowercase).
- The body is separated from the summary by exactly one blank line.
- Multiple footers are allowed, one per line.
- `BREAKING CHANGE` in a footer is equivalent to `!` in the summary line; tools recognise both.

### Breaking changes in detail

A breaking change is any change that requires callers, consumers, or downstream systems to modify their code or configuration in order to keep working. In a service: a removed endpoint, a changed response schema, a renamed environment variable. In a library: a removed function, a changed function signature, a renamed module.

Two equivalent ways to mark it:

```
# Method 1: ! in the summary
feat(api)!: remove deprecated /v1/users endpoint

# Method 2: BREAKING CHANGE footer
feat(api): remove deprecated /v1/users endpoint

BREAKING CHANGE: /v1/users has been removed. Use /v2/users instead.
Clients must update their base URL before upgrading to this version.
```

The footer form allows a longer explanation. Both cause `semantic-release` to bump the major version.

### Scope conventions

The scope is free-form but should be consistent within a project. Common conventions:

- **By module or package:** `feat(auth):`, `fix(storage):`, `refactor(queue):`
- **By service in a monorepo:** `feat(api-gateway):`, `fix(user-service):`, `chore(shared-lib):`
- **By layer:** `fix(db):`, `feat(ui):`, `perf(cache):`

The scope appears in the CHANGELOG under the corresponding section header, grouped with other commits of the same type. Inconsistent scopes produce inconsistent CHANGELOGs, so agreeing on the set of valid scopes in a project `CONTRIBUTING.md` is worthwhile.

### What tools read Conventional Commits

| Tool | What it does |
|---|---|
| `semantic-release` | Fully automated: reads commits since last tag, determines next version, publishes release, generates CHANGELOG, pushes tag — all in CI |
| `release-please` (Google) | Opens a PR that bumps the version and updates CHANGELOG; a human merges it to trigger the release |
| `conventional-changelog-cli` | Generates or updates `CHANGELOG.md` locally from commit history; useful for inspecting what the next release would contain |
| `git-cliff` | Single binary, highly configurable, generates CHANGELOG from commit history using a template; no Node.js required |
| `commitlint` | Validates commit messages in CI (and optionally locally via husky); the server-side counterpart to the `commit-msg` hook |
| `standard-version` (deprecated) | Predecessor to `semantic-release` — still seen in older repos; replaced by `semantic-release` or `release-please` |

---

## Part 3 — Server-side enforcement with GitHub Actions

The `commit-msg` hook is local to each developer's clone. A developer who clones the repository without copying the hook, or who uses `git commit --no-verify`, bypasses it. Server-side enforcement via CI catches everything that reaches the remote.

Add this workflow to your repository as `.github/workflows/commitlint.yml`:

```yaml
name: commitlint

on:
  pull_request:
    branches: [main]

jobs:
  commitlint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - uses: actions/setup-node@v4
        with:
          node-version: 20

      - name: Install commitlint
        run: npm install --save-dev @commitlint/cli @commitlint/config-conventional

      - name: Lint PR title
        run: echo "${{ github.event.pull_request.title }}" | npx commitlint

      - name: Lint all commits in PR
        run: npx commitlint --from ${{ github.event.pull_request.base.sha }} --to ${{ github.event.pull_request.head.sha }} --verbose
```

This checks two things:
1. The PR title itself (since squash-merge teams use it as the final commit message).
2. Every individual commit in the PR (catches commits that slipped through without the local hook).

The `fetch-depth: 0` is required so `git log` can traverse the full history back to the base SHA.

---

## Part 4 — CHANGELOG generation with git-cliff

`git-cliff` is a single binary that reads your commit history and generates a `CHANGELOG.md`. It does not require Node.js.

### Install git-cliff

On Linux/macOS:

```bash
curl -sSfL https://github.com/orhun/git-cliff/releases/latest/download/git-cliff-x86_64-unknown-linux-gnu.tar.gz | tar -xz
sudo mv git-cliff /usr/local/bin/
```

On macOS with Homebrew:

```bash
brew install git-cliff
```

On Windows (with Scoop):

```powershell
scoop install git-cliff
```

Or download a pre-built binary from [github.com/orhun/git-cliff/releases](https://github.com/orhun/git-cliff/releases).

### Generate a CHANGELOG

In the practice repository from the hands-on:

```bash
git cliff --output CHANGELOG.md
```

**What you should see in CHANGELOG.md:**

```markdown
# Changelog

## [unreleased]

### Features

- **(api)** add /version endpoint returning semver and api revision

### Documentation

- add internal notes section to README

### Chores

- initialize project with health endpoint stub
```

The three bad commits from step 2 of the hands-on (`add stuff`, `readme`, `wip`) appear nowhere in this CHANGELOG. They were invisible to the parser. This is the concrete cost of unstructured commit messages: the information they contain is permanently inaccessible to tooling.

### Customise the output

`git-cliff` uses a `cliff.toml` configuration file. A minimal one for the Angular preset:

```toml
[changelog]
header = "# Changelog\n\n"
body = """
{% for group, commits in commits | group_by(attribute="group") %}
### {{ group | upper_first }}
{% for commit in commits %}
- {% if commit.scope %}**({{ commit.scope }})** {% endif %}{{ commit.message }}\
{% endfor %}
{% endfor %}
"""
trim = true

[git]
conventional_commits = true
filter_unconventional = true
commit_parsers = [
  { message = "^feat", group = "Features" },
  { message = "^fix", group = "Bug Fixes" },
  { message = "^docs", group = "Documentation" },
  { message = "^perf", group = "Performance" },
  { message = "^refactor", group = "Refactoring" },
  { message = "^style", group = "Styling" },
  { message = "^test", group = "Testing" },
  { message = "^chore", group = "Chores" },
  { message = "^ci", group = "CI/CD" },
]
```

---

## Part 5 — PR hygiene: the reasoning behind each rule

### Why the title format matters beyond readability

In a squash-merge workflow, the PR title is the commit message on `main`. If `semantic-release` runs on every merge, it reads that commit and decides the next version. A PR title of `Update stuff` produces no version bump. A title of `feat(api): add paginated results endpoint` produces a minor version bump. The release automation is only as good as the PR titles that feed it.

### Why diff size matters

Review time is not linear in diff size — it is superlinear. A reviewer who can process a 200-line diff in 10 minutes will take 40+ minutes for an 800-line diff and will miss more. More importantly, a large diff implies large blast radius: if a 2000-line PR introduces a regression, identifying which of the 30 changed files caused it is an order of magnitude harder than in a 150-line PR.

The empirical finding from the SmartBear "Best Practices for Code Review" study: optimal review depth drops sharply above 400 lines of changed code. The reviewer's ability to find defects per 100 lines peaks between 200 and 400 lines and degrades significantly beyond that.

### The self-review habit

Self-review catches a category of issues that automated tools cannot: logical errors that are syntactically correct, business logic that is technically valid but wrong for the domain, and scope creep that crept in during development. The cognitive mode of "author writing code" and "reviewer reading diff" are different. Switching from one to the other before requesting review is what makes the author–reviewer interaction efficient.

A useful heuristic: if you find something in your own diff that you would comment on in someone else's PR, fix it before requesting review. Do not leave it for the reviewer to catch.

---

## Discussion questions

1. A team ships every two weeks with a manual QA sprint. A colleague proposes switching to trunk-based development with continuous deployment. What would need to change about their testing strategy, deployment pipeline, and feature development process before the switch is safe?
2. Your project has been using unstructured commit messages for two years. Management wants automated changelogs. What is the least disruptive path forward?
3. The `commit-msg` hook can be bypassed with `git commit --no-verify`. When is it legitimate for an engineer to use `--no-verify`, and what guardrail prevents abuse?
4. A PR has 1200 lines changed across 18 files. Describe how you would split it. What would be your first PR?

## Troubleshooting

| Symptom | Root cause | Fix |
|---|---|---|
| Hook is installed but commits are not rejected | The hook file is not executable | `chmod +x .git/hooks/commit-msg` |
| Hook works in Git Bash but not in PowerShell | PowerShell invokes git without the bash wrapper for hooks | Run git commands from Git Bash, or use `wsl` to call git |
| `git cliff` produces an empty CHANGELOG | No commits match the parser patterns | Check that commit messages follow Conventional Commits; run `git log --oneline` to verify |
| `gh pr create` fails with authentication error | `gh` is not authenticated | Run `gh auth login` |
| Squash merge drops the Conventional Commits title | The PR title was not set to match Conventional Commits format | Edit the PR title before merging; it is editable on the PR page |
| `commitlint` in CI fails with `Could not get commits` | `fetch-depth: 0` missing from the checkout action | Add `fetch-depth: 0` to the `actions/checkout` step |

## References

- [Conventional Commits specification v1.0.0](https://www.conventionalcommits.org/en/v1.0.0/) — the authoritative spec
- [A successful Git branching model — Vincent Driessen, 2010](https://nvie.com/posts/a-successful-git-branching-model/) — the original Gitflow post, including Driessen's 2020 note recommending trunk-based for CD teams
- [Trunk-based development — trunkbaseddevelopment.com](https://trunkbaseddevelopment.com/) — the definitive reference site for TBD patterns and tooling
- [Accelerate — Forsgren, Humble, Kim](https://itrevolution.com/product/accelerate/) — the research behind why TBD correlates with delivery performance
- [git-cliff documentation](https://git-cliff.org/) — configuration reference and template examples
- [semantic-release documentation](https://semantic-release.gitbook.io/) — full automation pipeline for versioning and release
- [SmartBear Best Practices for Code Review](https://smartbear.com/learn/code-review/best-practices-for-peer-code-review/) — empirical data on optimal diff size and review depth
