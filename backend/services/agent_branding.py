"""Default accent colors for well-known agents.

Agents may set their own `accent_color` (any hex). When unset, we look up
their `name` against a curated table of common agents the user explicitly
called out (claude code, codex, hermes, openclaw) and fall back to a stable
hash-based color so two agents with the same generic name still differ.
"""
from __future__ import annotations
import hashlib
import re

# Hex colors chosen to feel at home alongside the editorial cream/aubergine
# theme — moderate saturation, good contrast on cream and on ink.
_KNOWN: dict[str, str] = {
    "claude code":     "#D97757",   # Anthropic clay
    "claude-code":     "#D97757",
    "claude":          "#D97757",
    "codex":           "#10A37F",   # OpenAI emerald
    "openai codex":    "#10A37F",
    "hermes":          "#5B8DEE",   # winged-shoe blue
    "hermes agent":    "#5B8DEE",
    "openclaw":        "#E8A33D",   # amber claw
    "open claw":       "#E8A33D",
    "gpt":             "#10A37F",
    "gemini":          "#4C8DF6",
    "gpt-5":           "#10A37F",
    "kimi":            "#7C5CFC",
}

# Stable hashed-fallback palette — deterministic per agent name.
_FALLBACK = [
    "#6B60A8",  # default accent
    "#D97757",
    "#10A37F",
    "#5B8DEE",
    "#E8A33D",
    "#7C5CFC",
    "#C04E7E",
    "#3FA9A1",
    "#B68D40",
    "#4F6FBE",
]


def _normalize(name: str) -> str:
    return re.sub(r"\s+", " ", name.strip().lower())


def default_accent_for(name: str | None) -> str:
    """Return a hex color for an agent name (used when agent has no override)."""
    if not name:
        return _FALLBACK[0]
    norm = _normalize(name)
    if norm in _KNOWN:
        return _KNOWN[norm]
    # Substring match — "Claude Code (prod)" should still pick up the Claude clay.
    for key, color in _KNOWN.items():
        if key in norm:
            return color
    h = hashlib.sha1(norm.encode("utf-8")).hexdigest()
    return _FALLBACK[int(h[:8], 16) % len(_FALLBACK)]


def resolve_accent(agent) -> str:
    """An agent's `accent_color` if set, otherwise the default for its name."""
    explicit = getattr(agent, "accent_color", None)
    if explicit:
        return explicit
    return default_accent_for(getattr(agent, "name", None))
