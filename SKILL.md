---
name: pronoun-resolver
version: 0.1.0
description: |
  Intercepts ambiguous pronouns (it, them, these, those, that, this, they, its) in user
  prompts and resolves them to specific referents using a tiered LLM engine before Claude
  acts. Reduces hallucinations from vague input. Uses a self-learning ledger that adapts
  confidence thresholds per project. Always active when installed.
hooks:
  user-prompt-submit:
    - type: command
      command: "bash ${CLAUDE_SKILL_DIR}/bin/detect-pronouns.sh"
      statusMessage: "Scanning for ambiguous pronouns..."
---

# Pronoun Resolver

Automatically detects ambiguous pronouns in your prompts and resolves them to specific
referents before Claude acts on them.

## How It Works

1. Every message is scanned for pronouns: it, them, these, those, that, this, they, its
2. If the prompt is self-contained (pronoun + specific noun), it passes through untouched
3. If a pronoun is ambiguous, a quick LLM self-check resolves it with a confidence score
4. If confidence is low, 3 independent LLM agents vote on the resolution
5. The resolved referent is injected as context — your original message is never modified

## Ledger

Resolutions are logged to `.claude/pronoun-ledger.json` in the project directory.
The ledger tracks accuracy and adjusts the confidence threshold over time:
- High accuracy: trusts self-check more (fewer council escalations)
- Low accuracy: escalates to council more often

## Disable

Create `.claude/pronoun-resolver-disabled` in the project root to disable.
Delete the file to re-enable.

## Install

Symlink or copy this directory to `~/.claude/skills/pronoun-resolver`:

```bash
ln -s /path/to/coding-pronoun-prompt-resolver ~/.claude/skills/pronoun-resolver
```
