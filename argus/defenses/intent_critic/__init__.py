"""Intent critic — small adversarial judge that overrides gateway APPROVE.

Public exports:

    IntentCritic        — stateful critic; review() per APPROVE probe
    CriticDecision      — dataclass returned by review
    parse_critic_output — pure-text parser used by tests and harnesses
    CRITIC_SYSTEM_PROMPT — re-exported for inspection

Usage:

    from argus.defenses.intent_critic import IntentCritic

    critic = IntentCritic()  # uses Qwen2.5-7B-Instruct-4bit by default
    critic.load()
    for probe in approved_probes:
        d = critic.review(intent=..., original_prompt=..., session_id=pid)
        if d.fired:
            # downgrade gateway decision to REJECT for this probe
            ...
    critic.unload()
"""
from .critic import (
    IntentCritic,
    CriticDecision,
    parse_critic_output,
)
from .prompts import CRITIC_SYSTEM_PROMPT, CRITIC_USER_TEMPLATE

__all__ = [
    "IntentCritic",
    "CriticDecision",
    "parse_critic_output",
    "CRITIC_SYSTEM_PROMPT",
    "CRITIC_USER_TEMPLATE",
]
