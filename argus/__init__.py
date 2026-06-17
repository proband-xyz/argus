"""Argus — enterprise-IAM agentic-safety substrate for LLM safety research.

The Argus framework provides:

- A family of hardened gateway-adapter variants for Llama-3.3-70B-Instruct
  (published on HuggingFace Hub under proband-xyz/argus-*).
- Runtime defense layers (audit-namespace schema guard, intent critic)
  that compose with any gateway variant.
- Probe sets for evaluation against broad agentic-safety axes and
  MITRE-mapped IAM attack patterns.

See https://proband.xyz/argus for documentation.
"""

__version__ = "0.1.0"
