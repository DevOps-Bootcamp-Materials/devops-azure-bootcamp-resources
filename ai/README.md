# AI for DevOps — IronHack DevOps Bootcamp Module

> **Language policy:** All documentation in this module is written in English.
> This applies to READMEs, any code, and supporting material.

This module covers practical AI skills for DevOps engineers: how to use
large language models as a productivity multiplier in your daily work —
generating infrastructure code, writing and debugging pipelines, reviewing
configurations, and using prompt engineering to get reliable, high-quality
outputs consistently.

The goal is not to learn AI in the abstract. It is to become a better
DevOps engineer by knowing *when* and *how* to involve an LLM, and — equally
important — when not to trust it.

## Structure

```
ai/
├── README.md                              ← This file
└── hands-on/
    ├── ai-devops-artifacts/            ← Generate and iterate on DevOps artifacts using AI
    └── debugging-with-ai/             ← Diagnose and fix broken infrastructure configs
```

## Tool requirements

These hands-on are **tool-agnostic**: any LLM with a chat interface works.
The techniques apply equally to ChatGPT, GitHub Copilot Chat, Claude,
Gemini, Cursor, or any other model.

If your organisation has a preferred tool, use that. If not, the recommended
setup for these hands-on is:
- **Cursor** (free tier available) for exercises that involve editing files
- **Claude.ai** or **ChatGPT** for chat-based exercises

## Recommended order

| Hands-on | Key concept | Estimated time |
|----------|-------------|----------------|
| 00 | Prompt engineering fundamentals: zero-shot, few-shot, chain-of-thought | 60 min |
| 01 | AI-assisted debugging: giving the model the right context to find real problems | 45 min |
