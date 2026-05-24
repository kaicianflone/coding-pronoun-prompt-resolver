# Pronoun Resolver for Claude Code

A Claude Code skill that intercepts ambiguous pronouns in your prompts (it, them, these, those, that, this, they, its) and resolves them to specific referents before Claude acts — reducing hallucinations caused by vague input.

## How It Works

```
User types: "fix it"
                │
    ┌───────────▼───────────┐
    │  Regex pronoun scan   │
    │  (zero LLM cost if    │
    │   no pronouns found)  │
    └───────────┬───────────┘
                │ pronouns detected
    ┌───────────▼───────────┐
    │  Tier 1: Self-Check   │
    │  Single haiku call    │
    │  Returns confidence   │
    └───────────┬───────────┘
                │ confidence < threshold?
    ┌───────────▼───────────┐
    │  Tier 2: Council      │
    │  3 independent haiku  │
    │  agents majority-vote │
    └───────────┬───────────┘
                │
    ┌───────────▼───────────┐
    │  Silent substitution  │
    │  Claude sees:         │
    │  [Pronoun Resolution: │
    │   "it" → "auth.ts"]  │
    └───────────────────────┘
```

## Self-Learning Ledger

Every resolution is logged to `.claude/pronoun-ledger.json` in your project. The ledger tracks:

- **Resolution accuracy** — did the user correct the resolution?
- **Context reliability** — which signals (last edited file, last tool call, etc.) produce the best resolutions?
- **Adaptive threshold** — starts at 0.8, adjusts every 10 resolutions based on accuracy

High accuracy → threshold drops → fewer council escalations → faster.
Low accuracy → threshold rises → more council votes → more accurate.

## Install

```bash
# Clone the repo
git clone https://github.com/kaicianflone/coding-pronoun-prompt-resolver.git

# Symlink into Claude Code skills directory
ln -s "$(pwd)/coding-pronoun-prompt-resolver" ~/.claude/skills/pronoun-resolver
```

The skill activates automatically via `user-prompt-submit` hook. No manual invocation needed.

## Disable/Enable

```bash
# Disable for a project
touch .claude/pronoun-resolver-disabled

# Re-enable
rm .claude/pronoun-resolver-disabled
```

## Requirements

- Claude Code CLI (`claude` command available in PATH)
- Python 3
- Bash

## License

MIT
