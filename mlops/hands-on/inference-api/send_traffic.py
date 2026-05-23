"""Synthetic traffic generator for the inference-api hands-on.

Usage:
    python send_traffic.py --mode normal --duration 120
    python send_traffic.py --mode drift  --duration 120
    python send_traffic.py --mode mixed  --duration 180 --rps 1.0

The --drift mode sends open-ended generative prompts whose responses are
much longer than the normal short-factual prompts. Watch the
inference_response_tokens distribution in Grafana shift to the right.
"""

import argparse
import random
import time
import sys

import requests

DEFAULT_URL = "http://localhost:8080/predict"

NORMAL_PROMPTS = [
    "What is the capital of France?",
    "What is 2 + 2?",
    "Name three primary colors.",
    "What year did World War II end?",
    "Define photosynthesis in one short sentence.",
    "Who wrote Hamlet?",
    "What is the chemical symbol for gold?",
    "How many continents are there?",
    "Name the closest planet to the Sun.",
    "What language is spoken in Brazil?",
]

DRIFT_PROMPTS = [
    "Write a short story about a robot discovering emotions.",
    "Explain the theory of general relativity in detail with examples.",
    "Describe the rise and fall of the Roman Empire across its major periods.",
    "Write a poem about autumn and then explain its main symbols.",
    "Compose a step-by-step tutorial on baking sourdough bread.",
    "Write a dialogue between two philosophers debating free will.",
    "Describe in depth how a transformer neural network works.",
    "Tell the full plot of Moby Dick chapter by chapter.",
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default=DEFAULT_URL)
    parser.add_argument("--mode", choices=["normal", "drift", "mixed"], default="normal")
    parser.add_argument("--rps", type=float, default=0.5, help="requests per second")
    parser.add_argument("--duration", type=int, default=120, help="seconds")
    parser.add_argument("--max-tokens", type=int, default=512)
    args = parser.parse_args()

    end = time.time() + args.duration
    total = 0
    errors = 0
    while time.time() < end:
        if args.mode == "normal":
            prompt = random.choice(NORMAL_PROMPTS)
        elif args.mode == "drift":
            prompt = random.choice(DRIFT_PROMPTS)
        else:
            prompt = random.choice(NORMAL_PROMPTS + DRIFT_PROMPTS)

        try:
            r = requests.post(
                args.url,
                json={"prompt": prompt, "max_tokens": args.max_tokens},
                timeout=180,
            )
            r.raise_for_status()
            data = r.json()
            total += 1
            print(
                f"[{total:4d}] {prompt[:48]:50s} -> "
                f"{data.get('tokens', '?'):>4} tokens, "
                f"{data.get('duration_seconds', 0):.2f}s"
            )
        except Exception as exc:
            errors += 1
            print(f"[err {errors}] {exc}", file=sys.stderr)

        time.sleep(1.0 / max(args.rps, 0.01))

    print(f"\nSent {total} requests, {errors} errors, mode={args.mode}.")


if __name__ == "__main__":
    main()