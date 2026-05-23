# AI — Agents, MCPs, and Skills for DevOps engineers

Deep-dive reference companion to [`week-16/ai/hands-on/02_agents_mcp_skills.md`](https://github.com/DevOps-Bootcamp-Materials/devops-azure-bootcamp/blob/main/week-16/ai/hands-on/02_agents_mcp_skills.md) in the bootcamp repo.

The bootcamp hands-on walks through the setup and gives you a working system. This README covers the internals: how the agent loop works, what MCP does at the protocol level, how to write your own MCP server, skill patterns and conventions, the broader ecosystem, and how to stay current. Come here when a student asks a follow-up question the hands-on did not answer, or when you want to go deeper after the class session.

## What this folder contains

- `README.md` — this file: the full reference walkthrough
- `github-mcp-config.json` — ready-to-paste MCP config block for the GitHub server
- `docker-mcp-config.json` — alternative config for the Docker MCP server
- `skills/ci-health.md` — the example skill written in the hands-on (CI run summary)
- `skills/deployment-health.md` — a second example skill (Kubernetes deployment status)
- `examples/minimal-mcp-server.py` — a 60-line Python MCP server that exposes two DevOps tools

## Prerequisites

- Claude Code installed and working
- Docker Desktop installed and running (for the GitHub MCP server)
- Python 3.10+ with `pip install mcp` if you want to run the example server
- A GitHub account with a PAT (for the GitHub MCP server walkthrough)

## How to use this folder

```bash
git clone https://github.com/DevOps-Bootcamp-Materials/devops-azure-bootcamp-resources.git
cd devops-azure-bootcamp-resources/ai/hands-on/agents-mcp-skills
```

This README mirrors the flow of the bootcamp hands-on but expands every section. You can read it straight through, or jump to the part that answers your current question.

---

## Part 1 — The agent loop in depth

### What an agent actually is

The word "agent" is used loosely in the industry. For this course, use the following precise definition:

> An **agent** is a system in which a language model iteratively selects and executes tools until it judges the task to be complete or determines it cannot proceed.

Three components:

1. **The model** — decides what to do next given the current context (system prompt + conversation history + tool results so far).
2. **The tools** — functions the model can invoke. Each tool has a name, a description, and a typed input schema. The model reads these descriptions to decide when a tool is relevant.
3. **The loop** — after each tool call, the result is appended to the context and the model decides: call another tool, ask the user a clarifying question, or produce a final answer.

This is the entirety of what "agentic" means in current practice. There is no separate "agent brain"; the model's reasoning about what to do next is part of its standard generation. What is different is that the output space includes function calls, not just text.

### The ReAct pattern

Most current agents follow a pattern originally described in the paper "ReAct: Synergizing Reasoning and Acting in Language Models" (Yao et al., 2023). The model alternates between:

- **Thought**: reasoning about the current state, what is known, what is still needed.
- **Action**: a tool call with specific arguments.
- **Observation**: the tool's return value, appended to context.

Repeat until done. Claude Code follows this pattern; you can see it in the "thinking" and tool-call steps in the UI.

### Why the loop is bounded

A common misconception is that agents "run forever" or "have agency". In practice:

- The loop terminates when the model produces a final text response rather than another tool call.
- Most implementations also impose a hard limit (max tool call steps) to prevent runaway loops.
- The model does not have persistent state between sessions. Each new session starts from scratch unless you provide prior context explicitly.
- The model cannot take actions outside the tools you have connected. It can only do what its tools allow.

### Memory types and why they matter

When people talk about "AI agents with memory", they usually mean one of these:

| Memory type | Where it lives | How long it lasts | Example |
|---|---|---|---|
| In-context | The current conversation window | Until session ends | Tool results appended to the thread |
| File-based | A file the agent can read/write | Persistent | `CLAUDE.md`, `memory/*.md` |
| External store | A vector DB or key-value store | Persistent | Embedding-indexed past runs |
| Human-readable state | Project files, git history | Persistent | The code itself is memory |

Claude Code's `CLAUDE.md` system is file-based memory: the agent reads it at session start and uses it to apply project-specific conventions. The skills system is a form of procedural memory: the skill file tells the agent *how* to do something, not just what the state is.

For most DevOps use cases, file-based memory (project `CLAUDE.md` + skills) is sufficient. External vector stores add complexity and cost; only reach for them if you need the agent to recall information from more sessions than fit in a reasonable context window.

### Context loss — the most common failure mode in long agent sessions

Recall from lesson L05: context loss happens when a constraint set early in a session falls out of the model's effective attention as the context grows. In an agent session this is more acute because tool results accumulate rapidly. A session that starts with "always use namespaced resource names" may produce non-namespaced names 15 tool calls later.

The defences:

1. **System prompt + CLAUDE.md**: constraints that must persist across the session go in the system prompt or in `CLAUDE.md`, not in a user message.
2. **Short sessions**: if the task can be split, split it. A fresh session has full attention for the early constraints.
3. **Structural verification**: instead of relying on the model to remember "use HTTPS always", add a step to the skill that explicitly checks the output for HTTP before completing.

---

## Part 2 — MCP architecture internals

### The protocol: JSON-RPC 2.0

MCP uses [JSON-RPC 2.0](https://www.jsonrpc.org/specification) as its message format. Every exchange is a request/response or a notification. Request messages look like:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "list_pull_requests",
    "arguments": {
      "owner": "octocat",
      "repo": "hello-world",
      "state": "closed",
      "per_page": 3
    }
  }
}
```

The response carries the tool's return value in `result.content`:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "content": [
      { "type": "text", "text": "[{\"number\": 42, \"title\": \"Fix auth bug\", ...}]" }
    ]
  }
}
```

### Transport: stdio vs SSE

MCP supports two transports:

- **stdio** (standard input/output): the MCP client launches the server as a subprocess and communicates via stdin/stdout. This is the most common setup for local servers. The `command` + `args` fields in `settings.json` tell Claude Code how to start the subprocess.
- **SSE** (Server-Sent Events over HTTP): the server runs as a persistent HTTP service. Used for remote servers or servers that need to stay warm (e.g., a server that maintains a database connection). Configure with a `url` field instead of `command`.

For DevOps use, stdio is almost always the right choice for local tooling. SSE is worth knowing about when you need a server that serves a whole team rather than an individual developer.

### The lifecycle of a connection

When Claude Code starts with an MCP server configured:

1. **Launch**: Claude Code starts the subprocess (or connects to the SSE URL).
2. **Initialize**: client sends `initialize` with its capabilities; server responds with its capabilities and the protocol version.
3. **Tool discovery**: client sends `tools/list`; server responds with the full list of tool names, descriptions, and input schemas. This is what the model uses when deciding which tool to call.
4. **Session**: tool calls and results flow back and forth as the user works.
5. **Shutdown**: when Claude Code exits, it sends `shutdown` and the subprocess is terminated.

The model sees the tool descriptions from step 3 as part of its context. This is why the quality of a tool's description matters: a vague description leads to the model calling it at the wrong time or with wrong arguments. If a community MCP server is giving unexpected behavior, reading its `tools/list` output is often the first debugging step.

### Resources and Prompts (the other two capabilities)

Tools are the most commonly used capability, but MCP servers can also expose:

- **Resources**: addressable content (identified by a URI) that the model can read on demand. Examples: `file:///etc/prometheus/prometheus.yml`, `postgres://mydb/table/users`. Resources are useful when the data is large and should only be fetched when requested, rather than being pushed into the context upfront.
- **Prompts**: named, parameterised prompt templates stored server-side. A client can list available prompts and instantiate them by name, which is useful for building shared prompt libraries across a team.

Most DevOps use cases work with Tools alone. Resources become relevant when you want the model to navigate large data sources (a big log file, a database schema) without preloading everything into context.

### Security model

MCP servers run with the permissions of the host process (Claude Code), which runs as your user account. This has two implications:

1. **A filesystem MCP server can read any file your user can read.** This includes secrets, private keys, and `.env` files. Scope it carefully; some filesystem servers support include/exclude path patterns.
2. **A tool that can write or execute has full write/execute permissions.** An MCP server that exposes `run_kubectl` can delete namespaces. Grant write-capable tools only to sessions that need them.

The recommended practice: configure read-only servers globally, and configure write-capable servers in per-project `.claude/settings.json` only for projects that genuinely need them. Never configure a server that can destroy production resources in a project that has no need for it.

Prompt injection (lesson L05, section 3.6) is the other risk: if an MCP server fetches content from an external source (a GitHub issue body, a log file from an API), an attacker can embed MCP tool call instructions in that content. Always treat the *output* of a tool as untrusted if the tool fetches external user-controlled content.

---

## Part 3 — Writing your own MCP server

Once you understand the protocol, writing a server is straightforward. Anthropic provides official SDKs for Python and TypeScript. Here is a 60-line Python server that exposes two DevOps-relevant tools: `get_pod_status` (wraps `kubectl get pods`) and `get_recent_events` (wraps `kubectl get events --sort-by`).

The full file is at `examples/minimal-mcp-server.py` in this folder.

```python
#!/usr/bin/env python3
"""
Minimal MCP server — exposes two kubectl tools.
Install: pip install mcp
Run: python minimal-mcp-server.py (Claude Code starts it automatically via settings.json)
"""

import subprocess
import sys
from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import Tool, TextContent

app = Server("kubectl-tools")


@app.list_tools()
async def list_tools() -> list[Tool]:
    return [
        Tool(
            name="get_pod_status",
            description=(
                "Run 'kubectl get pods' in a namespace and return the output. "
                "Use this to check if pods are Running, Pending, or CrashLoopBackOff."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "namespace": {
                        "type": "string",
                        "description": "Kubernetes namespace. Defaults to 'default'.",
                    }
                },
            },
        ),
        Tool(
            name="get_recent_events",
            description=(
                "Run 'kubectl get events --sort-by=.lastTimestamp' in a namespace "
                "and return the last 20 lines. Use this to investigate pod failures "
                "or unexpected restarts."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "namespace": {
                        "type": "string",
                        "description": "Kubernetes namespace. Defaults to 'default'.",
                    }
                },
            },
        ),
    ]


@app.call_tool()
async def call_tool(name: str, arguments: dict) -> list[TextContent]:
    ns = arguments.get("namespace", "default")
    if name == "get_pod_status":
        cmd = ["kubectl", "get", "pods", "-n", ns]
    elif name == "get_recent_events":
        cmd = ["kubectl", "get", "events", "-n", ns, "--sort-by=.lastTimestamp"]
    else:
        return [TextContent(type="text", text=f"Unknown tool: {name}")]

    result = subprocess.run(cmd, capture_output=True, text=True)
    output = result.stdout or result.stderr
    # Trim to last 20 lines for events, keep all for pods
    if name == "get_recent_events":
        output = "\n".join(output.splitlines()[-20:])
    return [TextContent(type="text", text=output)]


if __name__ == "__main__":
    import asyncio
    asyncio.run(stdio_server(app))
```

To connect it to Claude Code, add it to `settings.json`:

```json
{
  "mcpServers": {
    "kubectl": {
      "command": "python",
      "args": ["/absolute/path/to/minimal-mcp-server.py"]
    }
  }
}
```

Restart Claude Code, run `/mcp`, and you should see `kubectl — 2 tools available`.

Key observations from this example:

- `list_tools()` is where the model reads the tool descriptions. The quality of the `description` field directly affects when the model calls the tool. Write it the same way you would write a clear docstring: what the tool does, what input it expects, when to use it.
- `call_tool()` receives the name and arguments, runs the underlying command, and returns the result as `TextContent`. The model sees whatever string you put in `text`.
- Error handling: if the subprocess fails, `result.stderr` will carry the error. Return it rather than raising an exception — the model can then decide how to handle the error (retry with different arguments, report to the user, stop).

---

## Part 4 — Skills: patterns and conventions

### What makes a good skill

A skill is useful when a task has:

1. A consistent workflow (same steps in the same order every time).
2. Variable specifics (the actual content changes per invocation).
3. Enough steps that re-specifying them each time is friction.

A skill is not the right abstraction when:

- The task is a single tool call (just call it directly).
- The workflow changes significantly depending on context (put the variability in the task description, not in a skill).
- The skill would need to encode decisions that require human judgment (keep those in the review step, not in the automation).

### Structure conventions

A readable skill file has:

- **A short title** (the heading) that matches the invocation name.
- **A numbered step list**: one step = one distinct action or decision. Steps should be concrete enough that a model following them cannot reasonably misinterpret.
- **Explicit tool references** where relevant: "use the GitHub MCP `list_workflow_runs` tool" is clearer than "check CI status".
- **An output spec**: what the final response should look like (a structured report, a table, a verdict sentence). Without this, the model makes a reasonable but inconsistent formatting decision each time.
- **A scope statement** for destructive or write actions: "do not create or modify any resources; report only" or "create a draft pull request but do not merge".

### Example: ci-health skill annotated

```markdown
# CI Health Check                          ← Title = invocation name

When invoked, perform the following steps using the GitHub MCP tools:
                                           ↑ Tells the model which tools to use

1. Identify the GitHub repository. Use the `origin` remote of the current
   working directory, or accept a `<owner>/<repo>` argument if the user
   provides one.
                                           ↑ Handles both invocation styles

2. Fetch the last 10 workflow runs for the repository's default branch.

3. For each failed run, retrieve the failing job's name and the first
   meaningful error line from its log output.
                                           ↑ "meaningful error line" is intentionally vague here —
                                             the model can judge what "meaningful" means. Tighter
                                             skills would specify "first line that is not a timestamp
                                             or a debug prefix".

4. Produce a structured report:
   - Total runs inspected: N (X passing, Y failing).
   - For each failure: workflow name, failing job, first error line, commit SHA.

5. Conclude with a single sentence verdict: CI is healthy, unstable, or broken.
                                           ↑ Forces a concrete verdict rather than a long hedge
```

### Versioning skills in a team

Skills are files. Put them in source control. For team-wide skills, a `<project>/.claude/skills/` directory committed to the repo means every team member has the same workflows available. For individual skills, `~/.claude/skills/` keeps them local.

When a skill is updated, the change is visible in git diff. This makes skill evolution auditable — you can see when a team member added a step, tightened a constraint, or changed the output format. Treat skill files with the same review hygiene as any other automation script.

---

## Part 5 — The broader ecosystem: when you need more

Claude Code with MCP and skills covers the majority of DevOps use cases that benefit from agents. But the ecosystem is broader, and it is useful to know where to look when the built-in tooling is not enough.

### Frameworks: when to look at them

Frameworks like **LangChain**, **LlamaIndex**, **CrewAI**, and **AutoGen** exist to handle patterns that raw API calls make painful: multi-agent coordination (one agent instructs another), persistent long-term memory, complex routing logic between models, or structured output parsing for many models simultaneously.

For DevOps automation, reach for a framework when:

- You need multiple specialised agents working in parallel and coordinating (one for log triage, one for PR drafting, one for alert routing).
- You need to build a standalone service that handles agent requests independently of a human-in-the-loop session.
- You are integrating with many different LLMs (not just Claude) and need a common abstraction layer.

Most individual DevOps tasks do not need a framework. The overhead of learning and maintaining a framework is only worth paying when the built-in tooling genuinely cannot express what you need.

### The Claude API directly

Claude Code is a high-level interface. For automated pipelines — a CI step that reviews Terraform plans, a Slack bot that triages alerts, a cron job that summarises deployment health — you want to call the API directly from a script or a service. The Anthropic Python SDK is the right starting point:

```python
import anthropic

client = anthropic.Anthropic()
response = client.messages.create(
    model="claude-sonnet-4-6",
    max_tokens=1024,
    messages=[{"role": "user", "content": "Summarise this Terraform plan: ..."}],
)
print(response.content[0].text)
```

Tools (function calling) work the same way at the API level. You pass a `tools` array with name, description, and input schema; when the model decides to call one, it returns a `tool_use` content block; you run the function and pass the result back as a `tool_result` message; continue until the model produces a final text response.

The [Anthropic Tool Use documentation](https://docs.anthropic.com/en/docs/tool-use) has the full reference with examples.

### Anthropic managed agents (agent SDK)

Anthropic has been investing in a higher-level agent SDK that handles tool loops, memory, and multi-turn orchestration at the SDK layer rather than requiring you to implement the loop yourself. Check the [Anthropic documentation](https://docs.anthropic.com) for the current state — this is an active area of development and the API surface changes faster than any course can track.

---

## Part 6 — How to stay current

This section is the honest answer to "how do I keep up with this space?". The answer is: selectively, by following the right signal sources, not by reading every announcement.

### What changes fast (and why you should not memorise it)

- **MCP server names and package paths**: servers are renamed, merged, deprecated. The `@modelcontextprotocol/server-github` path you used today may be different in six months. Always verify against [github.com/modelcontextprotocol/servers](https://github.com/modelcontextprotocol/servers) before setting up a new server.
- **Model names and capability tiers**: Opus, Sonnet, Haiku naming changes between generations. New context lengths, new tool use features, new pricing. Follow the Anthropic changelog, not this README.
- **Framework APIs**: LangChain, CrewAI, and others have broken their APIs repeatedly as they evolved. Code you write against a framework today will likely need updates within a year.
- **Benchmark scores**: "Model X beats Model Y on benchmark Z" — useful for choosing a model for a specific use case, not useful for general orientation. Treat benchmarks as one input, not as a conclusion.

### What stays stable (and is worth investing in)

- **The agent loop mental model**: model + tools + loop. This does not change when the model changes or the framework changes.
- **The verification principle**: every agent action with blast radius needs a human approval step. This does not change when the tooling gets better.
- **The economics of review**: Armin Ronacher's "final bottleneck" observation (AI removes the writing bottleneck, not the review bottleneck) will remain true for the foreseeable future. Plan your team's AI adoption around this.
- **The skill of writing good tool descriptions**: clear, specific descriptions of what a tool does and when to use it — this transfers across every framework and every model.

### Sources to follow actively

| Source | What it covers | Cadence |
|---|---|---|
| [Anthropic changelog](https://docs.anthropic.com/en/release-notes) | New model capabilities, API changes, MCP spec updates | Per-release |
| [modelcontextprotocol/servers](https://github.com/modelcontextprotocol/servers) | New official servers, server changes | Per-commit (watch the repo) |
| David Crawshaw — [crawshaw.io](https://crawshaw.io/blog) | First-person agent workflow reports ("Eight more months of agents") | Infrequent, high signal |
| Armin Ronacher — [lucumr.pocoo.org](https://lucumr.pocoo.org/) | Production engineering perspective, team dynamics | Frequent, high signal |
| Simon Willison — [simonwillison.net](https://simonwillison.net/) | New model capabilities, security, tool integrations | Multiple per week |

The key discipline: follow the sources, not the announcements. Product launch posts tell you what vendors want you to believe. Practitioner posts tell you what is actually working at production scale.

---

## Cleanup

The GitHub MCP server leaves no persistent state. If you ran `python minimal-mcp-server.py` directly (outside Claude Code), it will have exited when you closed the terminal.

Remove any PATs you created only for this hands-on: [github.com/settings/tokens](https://github.com/settings/tokens).

---

## Discussion questions

After this hands-on, a student should be able to answer:

1. What is the difference between calling an LLM with a single prompt and running an agent? What does the loop add?
2. You connect a filesystem MCP server that can read and write any file your user can access. What are the security implications? How would you mitigate them?
3. You write a skill that drafts a runbook from a pod's logs. The skill calls `get_pod_logs` and then produces markdown. Where would you add a verification step, and what would it check?
4. A colleague says "we should use LangChain for this". What questions would you ask before agreeing? What would make a framework the right choice vs. Claude Code + MCP + skills?
5. The GitHub MCP server is a year old and the package has been deprecated in favour of a new one. How do you find and migrate to the new one? Where would you look?

## Troubleshooting

| Symptom | Root cause | Fix |
|---|---|---|
| `/mcp` shows no servers | `settings.json` not saved, or syntax error in JSON | Validate the JSON (`jq . ~/.claude/settings.json`); restart Claude Code after saving |
| `/mcp` shows the server but "0 tools available" | Server started but handshake failed — usually a missing env var or a version mismatch | Check that `GITHUB_PERSONAL_ACCESS_TOKEN` is set; check the server's stderr in the Claude Code logs |
| `npx: command not found` | Node.js not installed or not on PATH | Install Node.js 18+ from nodejs.org; verify with `node --version` |
| First run of `npx -y @modelcontextprotocol/server-github` is slow | npm is downloading the package | Normal on first run; subsequent starts are fast. Add `-y` to skip the install confirmation |
| Tool calls return 401 errors | PAT expired or insufficient scope | Revoke the old token; create a new one with `repo` scope |
| Tool calls return unexpected results | Model is calling the wrong tool or passing wrong arguments | Add explicit tool name hints to your prompt ("use the `list_pull_requests` tool") or improve the skill's step descriptions |
| Python MCP server exits immediately | Import error or Python version mismatch | Run `python minimal-mcp-server.py` directly in a terminal to see the error; check `pip install mcp` succeeded |
| Context loss mid-session | Long tool call chain has pushed early constraints out of effective attention | Move the constraint to `CLAUDE.md` or the system prompt; break the session into shorter sub-tasks |

## References

- [Model Context Protocol specification](https://modelcontextprotocol.io/specification) — the authoritative spec; read when something behaves unexpectedly at the protocol level
- [MCP official servers repository](https://github.com/modelcontextprotocol/servers) — source of truth for which servers exist and their current package names
- [Anthropic MCP connector documentation](https://docs.anthropic.com/en/docs/agents-and-tools/mcp-connector) — how to use MCP servers via the Anthropic Messages API (for automated pipelines; Claude Code uses settings.json instead)
- [Anthropic tool use documentation](https://docs.anthropic.com/en/docs/tool-use) — using tools (function calling) directly via the API
- [ReAct: Synergizing Reasoning and Acting in Language Models](https://arxiv.org/abs/2210.03629) — the paper that named and formalised the Thought/Action/Observation loop most current agents follow
- [David Crawshaw — "How I program with Agents"](https://crawshaw.io/blog/programming-with-agents) — first-person account of a practical agent workflow by a senior infrastructure engineer
- [David Crawshaw — "Eight more months of agents"](https://crawshaw.io/blog/eight-more-months-of-agents) — follow-up tracking how the workflow evolved; where it held up and where it broke
- [OWASP Top 10 for LLM Applications — Prompt Injection](https://owasp.org/www-project-top-10-for-large-language-model-applications/) — the security risk that matters most when agents read external content
- [Armin Ronacher — "The Final Bottleneck"](https://lucumr.pocoo.org/2026/2/13/the-final-bottleneck/) — why review capacity, not generation speed, is now the constraint