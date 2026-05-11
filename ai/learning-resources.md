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

### [Simon Willison's Blog](https://simonwillison.net/)

**Why use it:** Simon Willison (co-creator of Django) writes the most consistently useful practical blog on LLMs for developers. He covers new model releases, prompting techniques, tool integrations, and security considerations (prompt injection, LLM-based attacks) with the pragmatism of a working engineer rather than the hype of marketing content. His posts on using LLMs for coding tasks and his "TIL" (Today I Learned) series are particularly worth following.

**When to use it:** Subscribe to his RSS feed or follow him on social media. New posts are frequent (multiple per week) and consistently high signal.

---

### [Hamel Husain's Blog — hamel.dev](https://hamel.dev/)

**Why use it:** Hamel focuses on the engineering side of LLM deployment — evaluation, fine-tuning, and building reliable AI-powered systems. His writing on LLM evaluation (how do you know your prompts are working?) is the best practical resource on that specific topic. For a DevOps engineer building AI-assisted automation, the ability to evaluate outputs systematically is what separates a reliable tool from an impressive demo.

**When to use it:** When you move beyond using AI interactively and start building automated workflows. His post on "Your AI product needs evals" is essential reading before deploying any LLM-based automation.

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
