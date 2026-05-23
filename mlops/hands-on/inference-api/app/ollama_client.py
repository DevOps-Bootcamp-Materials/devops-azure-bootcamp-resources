import requests


class OllamaClient:
    def __init__(self, host: str):
        self.host = host.rstrip("/")

    def generate(self, model: str, prompt: str, max_tokens: int) -> dict:
        resp = requests.post(
            f"{self.host}/api/generate",
            json={
                "model": model,
                "prompt": prompt,
                "stream": False,
                "options": {"num_predict": max_tokens},
            },
            timeout=180,
        )
        resp.raise_for_status()
        return resp.json()

    def health(self) -> bool:
        try:
            r = requests.get(f"{self.host}/api/tags", timeout=5)
            return r.status_code == 200
        except Exception:
            return False