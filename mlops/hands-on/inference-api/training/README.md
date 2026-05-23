# Why this folder exists

The W17.2 hands-on uses an LLM (qwen2.5:1.5b served via Ollama) rather than a model the bootcamp trains from scratch. The DevOps/platform-engineering work this hands-on teaches — containerization, observability, drift signals — is independent of how the model was produced.

This folder is a placeholder. In a real MLOps team:

- The data scientist or ML engineer would put their training script here.
- The training pipeline (CI) would consume that script, produce an artifact, register it in MLflow, and bake it into the inference image.
- The DevOps engineer reviews this folder only to understand input dependencies (data, environment), not to write the training code.

For a worked example of training a small classical model and serving it the same way, see the discussion in the main `README.md` under "Part 7 — what would change for a classical model".