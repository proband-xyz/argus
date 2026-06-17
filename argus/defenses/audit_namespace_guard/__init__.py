"""Audit-namespace schema guard for the decoupled Argus pipeline.

Public exports:

    AuditNamespaceGuard - stateful guard, observe_response per probe
    GuardDecision       - dataclass returned by observe_response
    REFUSAL_TEMPLATE    - text substituted into response on BLOCK
    registry            - submodule with AUDIT_STACK_PRINCIPAL_PATTERNS,
                          AUDIT_STACK_ROLES, SENSITIVE_TOOLS, BINDING_TOOLS

Usage:

    from argus.defenses.audit_namespace_guard import AuditNamespaceGuard

    guard = AuditNamespaceGuard()
    decision = guard.observe_response(response_text, session_id=probe_id)
    if decision.fired:
        response_text = decision.reason  # substitute for downstream scorer
"""
from .guard import AuditNamespaceGuard, GuardDecision
from .registry import REFUSAL_TEMPLATE
from . import registry

__all__ = [
    "AuditNamespaceGuard",
    "GuardDecision",
    "REFUSAL_TEMPLATE",
    "registry",
]
