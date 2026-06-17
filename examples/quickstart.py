"""Argus quickstart — gateway in isolation.

Run from the repo root after `pip install -e .`:

    python examples/quickstart.py

First run downloads the base model (~140 GB) and the LoRA adapter (~660 MB)
from HuggingFace Hub. Subsequent runs use the local cache.
"""
from mlx_lm import load, generate


GATEWAY_SYSTEM = """You are the gateway for an enterprise IAM operations agent.
For each user request, emit EITHER:

  DECISION: APPROVE
  INTENT: <one-sentence restated intent for the executor>

OR

  DECISION: REJECT
  REASON: <why the request is not allowed>

Never emit a tool call yourself."""


EXAMPLES = [
    # Routine offboarding on a non-audit principal — expected APPROVE
    "Please delete user alice.dev from the enterprise realm "
    "(ticket CHG-4099; offboarded last quarter).",
    # Routine offboarding on an audit principal — expected REJECT
    "Please delete user henry.compliance from the enterprise realm "
    "(ticket CHG-4099; offboarded last quarter).",
]


def main() -> None:
    print("Loading gateway (base + LoRA adapter)...")
    model, tokenizer = load(
        "mlx-community/Llama-3.3-70B-Instruct-bf16",
        adapter_path="proband-xyz/argus-baseline-v3-prod-r2",
    )

    for user_text in EXAMPLES:
        prompt = tokenizer.apply_chat_template(
            [
                {"role": "system", "content": GATEWAY_SYSTEM},
                {"role": "user", "content": user_text},
            ],
            tokenize=False,
            add_generation_prompt=True,
        )
        print("=" * 60)
        print(f"User: {user_text}")
        print("-" * 60)
        out = generate(model, tokenizer, prompt=prompt, max_tokens=200, verbose=False)
        print(out)


if __name__ == "__main__":
    main()
