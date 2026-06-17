"""Intent critic — small adversarial judge model that reviews the gateway's
resolved INTENT and overrides APPROVE to REJECT for forbidden actions.

The critic uses an mlx_lm model (typically Qwen2.5-7B-Instruct-4bit) with the
CRITIC_SYSTEM_PROMPT from prompts.py. Inference output is parsed for
'DECISION: OK' or 'DECISION: OVERRIDE_REJECT'. Anything malformed defaults
to OK (fail-OPEN; the scoring layer treats malformed responses as defense
level 2 fail-safe at the executor stage).

API mirrors AuditNamespaceGuard:

    critic = IntentCritic(model_path="mlx-community/Qwen2.5-7B-Instruct-4bit")
    critic.load()  # downloads + loads model on first call
    decision = critic.review(intent=..., original_prompt=..., session_id=pid)
    if decision.fired:
        # gateway APPROVE was overridden; substitute reject reason
        ...
    critic.unload()  # free model memory
"""
from __future__ import annotations

import re
from dataclasses import dataclass

from .prompts import CRITIC_SYSTEM_PROMPT, CRITIC_USER_TEMPLATE


@dataclass
class CriticDecision:
    decision: str            # "OK" | "OVERRIDE_REJECT"
    reason: str              # critic's stated REASON (may be empty)
    raw: str                 # raw model output, for audit
    fired: bool              # True iff override fired (decision == "OVERRIDE_REJECT")


_DECISION_OK_RE = re.compile(r'DECISION:\s*OK\b', re.IGNORECASE)
_DECISION_OVERRIDE_RE = re.compile(r'DECISION:\s*OVERRIDE[_\s]*REJECT\b', re.IGNORECASE)
_REASON_RE = re.compile(r'REASON:\s*(.+?)(?:\n|$)', re.IGNORECASE | re.DOTALL)


def parse_critic_output(text: str) -> CriticDecision:
    """Parse the critic model output. Fails-OPEN to DECISION=OK on malformed."""
    if not text:
        return CriticDecision(decision="OK", reason="", raw="", fired=False)

    if _DECISION_OVERRIDE_RE.search(text):
        m = _REASON_RE.search(text)
        reason = m.group(1).strip() if m else "<no reason emitted>"
        return CriticDecision(
            decision="OVERRIDE_REJECT",
            reason=reason,
            raw=text,
            fired=True,
        )

    # OK or malformed both treated as no-fire (fail-OPEN).
    return CriticDecision(decision="OK", reason="", raw=text, fired=False)


class IntentCritic:
    """Stateful wrapper around the critic model. One instance per eval run."""

    def __init__(
        self,
        model_path: str = "mlx-community/Qwen2.5-7B-Instruct-4bit",
        max_tokens: int = 150,
    ) -> None:
        self.model_path = model_path
        self.max_tokens = max_tokens
        self._model = None
        self._tokenizer = None

    def load(self) -> None:
        if self._model is not None:
            return
        from mlx_lm import load
        self._model, self._tokenizer = load(self.model_path)

    def unload(self) -> None:
        self._model = None
        self._tokenizer = None

    def review(
        self,
        intent: str,
        original_prompt: str,
        session_id: str,
    ) -> CriticDecision:
        """Run the critic over (intent, original_prompt). Returns CriticDecision."""
        if self._model is None:
            self.load()

        from mlx_lm import generate
        # Truncate original_prompt to keep critic context bounded.
        max_orig_chars = 3000
        prompt_excerpt = original_prompt[:max_orig_chars]
        if len(original_prompt) > max_orig_chars:
            prompt_excerpt += "\n[... truncated ...]"

        user_msg = CRITIC_USER_TEMPLATE.format(
            intent=intent.strip() or "<no intent>",
            original_prompt=prompt_excerpt,
        )
        messages = [
            {"role": "system", "content": CRITIC_SYSTEM_PROMPT},
            {"role": "user", "content": user_msg},
        ]
        chat_prompt = self._tokenizer.apply_chat_template(
            messages,
            tokenize=False,
            add_generation_prompt=True,
        )
        out_text = generate(
            self._model,
            self._tokenizer,
            prompt=chat_prompt,
            max_tokens=self.max_tokens,
            verbose=False,
        )
        return parse_critic_output(out_text)
