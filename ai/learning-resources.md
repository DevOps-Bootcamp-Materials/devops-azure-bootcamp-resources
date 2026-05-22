# Learning Resources for AI in DevOps

A curated selection of resources ordered by type and level. Each entry explains what makes it valuable and when to use it.

The focus of this list is practical: how to use AI tools effectively as a DevOps engineer, not how to build AI systems. Resources on ML theory and model training are out of scope unless they directly inform how to work with models as a practitioner.

---

## Prompt Engineering Guides

### [Anthropic Prompt Engineering Guide](https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/overview)

**Why use it:** Anthropic's own documentation on how to get the best results from Claude — but the principles apply to any frontier model. It covers the techniques that actually move the needle in practice: being explicit about format, using XML tags to structure complex inputs, chain-of-thought prompting, and how to handle long contexts. It is written by the people who built the model and validated against real usage, which makes it more reliable than generic "prompt engineering tips" blog posts.

**When to use it:** As the primary reference when you want to understand *why* a prompting technique works, not just follow a recipe. The section on tool use and system prompts is particularly relevant for anyone building AI-assisted DevOps automation.

---

### [OpenAI Prompt Engineering Guide](https://platform.openai.com/docs/guides/prompt-engineering)

**Why use it:** Written for GPT-4, but the six main strategies (write clear instructions, provide reference text, split complex tasks, give the model time to think, use external tools, test systematically) apply to any model. The concrete examples are well chosen and directly reusable in DevOps contexts.

**When to use it:** As a complement to the Anthropic guide. Different models have slightly different optimal prompting patterns, and reading both gives you a more complete picture of what is model-specific vs universally applicable.

---

### [Prompting Guide — promptingguide.ai](https://www.promptingguide.ai/)

**Why use it:** The most comprehensive free resource on prompt engineering techniques. It covers everything from zero-shot and few-shot prompting through chain-of-thought, self-consistency, ReAct, and more advanced patterns. It also covers image generation models and code generation specifically. The site is actively maintained and references academic papers for each technique.

**When to use it:** As a reference when you encounter a prompting problem you do not know how to solve. The techniques page is particularly useful: if your current approach is not working, browsing it often surfaces a pattern that fits your case.

---

## Courses

### [ChatGPT Prompt Engineering for Developers — DeepLearning.AI](https://www.deeplearning.ai/short-courses/chatgpt-prompt-engineering-for-developers/)

**Why use it:** A free one-hour course by Andrew Ng and Isa Fulford (OpenAI). It is the most authoritative, concise, and practical introduction to prompt engineering that exists. It is aimed at developers (not data scientists) and uses Python notebooks, which means every technique is immediately executable. The coverage of iterative refinement, summarisation, and structured output extraction is directly applicable to DevOps automation tasks.

**When to use it:** Before writing any prompt for production use. Even if you feel comfortable with LLMs, this course will show you patterns you are not using. It takes one hour and the return is immediate.

---

### [Building Systems with the ChatGPT API — DeepLearning.AI](https://www.deeplearning.ai/short-courses/building-systems-with-chatgpt/)

**Why use it:** The follow-up to the course above. Covers chaining multiple LLM calls, evaluating outputs automatically, and building multi-step AI workflows. These are the skills you need when moving from ad-hoc prompts to reliable AI-assisted automation in a pipeline.

**When to use it:** After the prompt engineering fundamentals course, when you want to build something that runs automatically rather than interactively.

---

### [AI Python for Beginners — DeepLearning.AI](https://www.deeplearning.ai/short-courses/ai-python-for-beginners/)

**Why use it:** If you want to go beyond chat interfaces and call LLM APIs directly from scripts, this course covers the fundamentals. For a DevOps engineer this means: writing Python scripts that generate Terraform, analyse log files, or check deployment outputs using an LLM as a processing step — without building a full application.

**When to use it:** When you want to automate AI-assisted tasks in your pipelines rather than using a chat interface manually.

---

## Tools

### [Cursor](https://cursor.sh/)

**Why use it:** An AI-first code editor built on VS Code that understands your repository. Unlike GitHub Copilot, which suggests completions inline, Cursor lets you select a block of code and give it natural language instructions ("refactor this to use async/await", "add Prometheus instrumentation to this Flask app"). The `@codebase` context window allows it to reason across multiple files. For DevOps work — iterating on Terraform modules, debugging Helm charts, generating CI/CD pipelines — it significantly reduces the time between "I know what I want" and "I have working code".

**When to use it:** For any DevOps task that involves writing or editing files. Particularly effective for Terraform, Dockerfiles, GitHub Actions workflows, and Kubernetes manifests — tasks where the pattern is known but the specifics require adapting boilerplate.

---

### [GitHub Copilot](https://github.com/features/copilot)

**Why use it:** The most widely deployed AI coding assistant, integrated directly into VS Code, JetBrains, and other editors. Its inline completion model is trained heavily on real GitHub code, which makes it particularly effective at completing patterns it has seen many times — standard Dockerfile stages, common Terraform resource blocks, typical CI/CD pipeline steps. Copilot Chat (the conversational interface) is useful for explaining unfamiliar code and generating tests.

**When to use it:** As your default AI assistant inside your editor if you are not using Cursor. The free tier (for individual developers) is sufficient for most DevOps tasks.

---

### [Claude.ai](https://claude.ai)

**Why use it:** Anthropic's Claude handles very long contexts (up to 200k tokens in Claude 3.x) better than most competitors, which makes it particularly useful for DevOps tasks that involve large inputs: pasting an entire Terraform plan to review, analysing a long CI log to find a root cause, or asking questions about a large codebase you have uploaded. It is also notably better at following complex multi-constraint instructions, which is relevant for IaC generation.

**When to use it:** When you have a large input (full log files, entire config files, complete codebases) that needs analysis, or when your prompt has many constraints that other models tend to partially ignore.

---

### [Anthropic API — Console and Workbench](https://console.anthropic.com/)

**Why use it:** The Anthropic Console includes a Workbench — an interactive environment for testing prompts with full control over system prompts, model version, temperature, and token limits. Unlike chat interfaces, the Workbench lets you iterate on prompts systematically: change one variable, run again, compare outputs. This is the right tool for developing prompts that will be used in automation rather than interactive chat.

**When to use it:** When you are building a prompt that will be used programmatically (in a script, a CI/CD step, or an internal tool) and need to validate it against multiple inputs before deploying it.

---

## Blogs and Written References

The blogs below are the backbone of the W16.7 lesson — *AI-assisted DevOps: responsible use, where it helps, where it bites*. The premise of the lesson is that the honest answer to "how should I use AI at work?" is not in a vendor announcement or a hype thread, but in the public notebooks of senior engineers who have integrated these tools into real production work and written carefully about what changed.

Three things to read for as you go through them:

- **Where it helps.** Which specific tasks the author now delegates to an LLM or an agent, and why those tasks fit. This is the part the bootcamp's hands-on (W16.8, W16.9) tries to reproduce in DevOps contexts.
- **Where it bites.** The failure modes the author has observed — context loss, hallucinated APIs, review-capacity bottlenecks, design erosion over time, prompt injection on logs and tickets. The shape of the failure matters more than the existence of it.
- **What stays the same.** What the engineer still does themselves, and what stays under human review. This is the line that separates "AI in the workflow" from "AI replaces the workflow", and it is the most useful thing to copy.

The first two entries (Simon Willison, Hamel Husain) are general-purpose anchors. The rest are first-person practitioner accounts — senior engineers, founders, and Thoughtworks contributors writing about their own daily use of AI tools on real engineering problems.

---

### [Simon Willison's Blog](https://simonwillison.net/)

**Why use it:** Simon Willison (co-creator of Django) writes the most consistently useful practical blog on LLMs for developers. He covers new model releases, prompting techniques, tool integrations, and security considerations (prompt injection, LLM-based attacks) with the pragmatism of a working engineer rather than the hype of marketing content. His posts on using LLMs for coding tasks and his "TIL" (Today I Learned) series are particularly worth following.

**When to use it:** Subscribe to his RSS feed or follow him on social media. New posts are frequent (multiple per week) and consistently high signal.

---

### [Hamel Husain's Blog — hamel.dev](https://hamel.dev/)

**Why use it:** Hamel focuses on the engineering side of LLM deployment — evaluation, fine-tuning, and building reliable AI-powered systems. His writing on LLM evaluation (how do you know your prompts are working?) is the best practical resource on that specific topic. For a DevOps engineer building AI-assisted automation, the ability to evaluate outputs systematically is what separates a reliable tool from an impressive demo.

**When to use it:** When you move beyond using AI interactively and start building automated workflows. His post on "Your AI product needs evals" is essential reading before deploying any LLM-based automation.

---

### [Mitchell Hashimoto — mitchellh.com/writing](https://mitchellh.com/writing)

**Why use it:** Mitchell Hashimoto (HashiCorp co-founder, creator of Vagrant and Terraform, and now Ghostty) writes from the perspective of someone who built the tooling the DevOps profession runs on. His post "My AI Adoption Journey" is one of the more honest descriptions of how a senior infrastructure engineer integrated AI agents into their workflow — what worked, what did not, and how the workflow changed over months rather than days. Because his domain is exactly the one this bootcamp targets (infrastructure as code, low-level tooling), his lessons transfer cleanly.

**When to use it:** When you want a credible account of AI adoption from someone whose previous output is well-documented. Read his AI posts alongside his earlier writing on Terraform and Ghostty to see how the same engineer approaches problems with and without AI assistance.

---

### [Armin Ronacher — lucumr.pocoo.org](https://lucumr.pocoo.org/)

**Why use it:** Armin Ronacher (creator of Flask, CTO at Sentry) posts frequently and specifically on what AI changes in day-to-day engineering. Posts such as "AI And The Ship of Theseus" (what happens when a library gets rewritten with AI), "The Final Bottleneck" (AI speeds up writing code, but review capacity is now the limit), and "Pushing Local Models With Focus And Polish" treat AI as a tool to be measured, not a movement to be advocated for. The angle is consistently the angle a DevOps engineer cares about: throughput, reliability, accountability.

**When to use it:** When you want frequent, specific posts on practical AI use from someone running a production engineering team. Armin updates often, and the posts are short enough to read over coffee.

---

### [David Crawshaw — crawshaw.io](https://crawshaw.io/blog)

**Why use it:** David Crawshaw (Tailscale co-founder, ex-Google) writes the most detailed first-person engineering accounts of programming with LLMs and agents. "How I program with LLMs" and "How I program with Agents" are widely cited because they describe an actual workflow — what tasks to delegate, what to write yourself, what guardrails to put in — rather than a marketing pitch. The follow-ups ("Eight more months of agents", "The agent principal-agent problem") track how that workflow has evolved as the tools changed.

**When to use it:** When you want to compare your own AI workflow against the workflow of an engineer who reasons carefully and writes precisely about it. Read both "How I program with LLMs" and "How I program with Agents" in order — together they are about an hour and worth it.

---

### [Exploring Generative AI — Birgitta Böckeler and colleagues, martinfowler.com](https://martinfowler.com/articles/exploring-gen-ai.html)

**Why use it:** A long-running, episodic article series on martinfowler.com led by Birgitta Böckeler (Thoughtworks) with contributors including Kief Morris, Erik Doernenburg, and others. Unlike most AI commentary, each entry is a small, specific observation from real engagement work — coding assistant reliability, TDD with AI, codebase onboarding, multi-file edits, tech stack migration with agents, supply chain implications. The cumulative effect is a calibrated picture of where AI in software development actually helps and where it does not.

**When to use it:** When you want practitioner perspectives that are neither hype nor reflexive scepticism. The series is searchable by topic — go to the specific memo when you face a specific question (for example, the memos on context engineering when you start building prompts for agents).

---

### [Kent Beck — Tidy First? on Substack](https://tidyfirst.substack.com/)

**Why use it:** Kent Beck (Extreme Programming, Test-Driven Development) writes about what he calls "augmented coding" — programming with AI as a collaborator. The posts "Augmented Coding: Beyond the Vibes", "Genie Tarpit", and "Genie Lessons: Nobody Wants Agents" are valuable specifically because Beck has spent four decades thinking about software design practices and now applies that lens to AI-assisted work. His scepticism is technical, not cultural: when he says a workflow degrades over time, he can name the design property that breaks.

**When to use it:** When you want to integrate AI into your engineering practice without losing the design discipline that good engineering depends on. Particularly relevant if you are introducing AI tools into a team that already cares about clean code, testability, and refactoring.

---

### [Sean Goedecke — seangoedecke.com](https://www.seangoedecke.com/)

**Why use it:** Sean Goedecke writes as a staff engineer in an industry job, which makes the perspective unusually grounded — not a founder, not a researcher, just someone shipping software with AI in the loop. The post "How I use LLMs as a staff engineer" is a concrete catalogue of the tasks he delegates to LLMs and the tasks he keeps for himself, with the reasoning behind each. The companion posts on prompts as technical debt and on AI making weak engineers less harmful are the kind of honest, opinionated industry writing that is hard to find elsewhere.

**When to use it:** When you want a "what does this actually look like at work" view, written by someone whose job constraints are similar to yours. Pair it with David Crawshaw's posts for a senior-engineer-to-staff-engineer pair of perspectives.

---

### [Geoffrey Litt — geoffreylitt.com](https://www.geoffreylitt.com/)

**Why use it:** Geoffrey Litt (researcher, ex-Ink & Switch) writes about AI in software from the angle of tool design rather than productivity hacks. Posts like "Enough AI copilots! We need AI HUDs", "AI as teleportation", and "Code like a surgeon" reframe how the integration should work — what shape the UI should take, what the human should still be doing, what stays the same and what changes. For a DevOps engineer thinking about *building* internal AI-assisted tooling (not just consuming the public products), this angle is the one that matters.

**When to use it:** When you are designing the AI part of a workflow — a Slack bot for log triage, an agent that opens PRs, a runbook assistant. Litt's framing helps you avoid the most common shape mistake (a chat box that does not fit the task).

---

### [Thorsten Ball — Register Spill (Substack)](https://registerspill.thorstenball.com/)

**Why use it:** Thorsten Ball (Zed editor, previously Sourcegraph) writes a weekly newsletter, "Joy & Curiosity", with a recurring section on what he is learning about AI-assisted coding while building one of the editors that integrates it most aggressively. The signal-to-noise is high: he ships AI features inside Zed and reports back on what holds up. Worth subscribing as a steady drip rather than reading one-off.

**When to use it:** Weekly. The newsletter format makes it easy to keep a pulse on what is shifting in AI-assisted coding without committing to a deep dive every time.

---

## Security and Risk

### [OWASP Top 10 for LLM Applications](https://owasp.org/www-project-top-10-for-large-language-model-applications/)

**Why use it:** The standard reference for security risks in applications that use LLMs. The most relevant risk for DevOps engineers is **prompt injection** — an attacker embedding instructions in content that your system processes with an LLM, causing it to execute unintended actions (for example, injecting instructions into a log file that your AI-powered log analyser then follows). Understanding these risks before deploying AI-assisted automation is not optional.

**When to use it:** Before building any system where an LLM processes content from external sources (user input, log files, API responses, web content). The top 10 list takes 20 minutes to read and may save you from a serious security incident.

---

### [AI Snake Oil — Arvind Narayanan and Sayash Kapoor](https://www.aisnakeoil.com/)

**Why use it:** A blog (and book) by two Princeton researchers who apply rigorous scepticism to AI marketing claims. It is the antidote to hype: when a vendor claims their AI product "revolutionises" something you work with, Narayanan and Kapoor provide the framework to evaluate that claim critically. For a practitioner, knowing what AI cannot reliably do is as valuable as knowing what it can.

**When to use it:** When evaluating AI tools for your team or organisation, or when you want to maintain calibrated expectations about what LLMs will and will not solve reliably in production infrastructure contexts.

---

## Certifications (reference)

| Certification | Issuer | Level | Focus |
|--------------|--------|-------|-------|
| [AI-102: Designing and Implementing a Microsoft Azure AI Solution](https://learn.microsoft.com/en-us/credentials/certifications/azure-ai-engineer/) | Microsoft | Intermediate | Azure AI services, OpenAI on Azure, cognitive services |
| [AWS Certified AI Practitioner](https://aws.amazon.com/certification/certified-ai-practitioner/) | Amazon | Foundational | AWS AI/ML services, responsible AI, basic prompt engineering |
| [Google Cloud Professional ML Engineer](https://cloud.google.com/learn/certification/machine-learning-engineer) | Google | Advanced | ML on GCP, MLOps, model deployment and monitoring |

A note on AI certifications: the field moves faster than certification bodies can keep up. The cloud vendor certifications (Azure AI-102, AWS AI Practitioner) are primarily useful for demonstrating cloud-specific service knowledge. For practical prompt engineering and LLM usage, the DeepLearning.AI courses and the two official prompting guides listed above are more directly valuable than any current certification. Revisit this landscape in 12 months — it is evolving rapidly.

---
