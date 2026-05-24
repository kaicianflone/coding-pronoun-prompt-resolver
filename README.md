# Pronoun Resolver

A Claude Code skill that intercepts ambiguous pronouns in user prompts and resolves them to specific referents before Claude acts on them. Reduces hallucinations caused by vague input like "fix it", "update them", or "is it possible."

Works automatically via a `user-prompt-submit` hook. No manual invocation needed. Zero LLM cost on messages with no pronouns.

## The Problem

When you type "fix it", Claude has to guess what "it" refers to. Sometimes it guesses right. Sometimes it confidently refactors the wrong file. The ambiguity in your prompt becomes a hallucination in the output.

This skill eliminates that guesswork by resolving pronouns before Claude sees your message.

## How It Works

```
User types: "fix it"
                |
    +-----------v-----------+
    |  Regex pronoun scan   |
    |  (zero LLM cost if    |
    |   no pronouns found)  |
    +-----------+-----------+
                | pronouns detected
    +-----------v-----------+
    |  Tier 1: Self-Check   |
    |  Single haiku call    |
    |  Returns confidence   |
    +-----------+-----------+
                | confidence < threshold?
           yes  |           | no
    +-----------v---+   +---v-----------+
    |  Tier 2:      |   |  Substitute   |
    |  Council      |   |  silently     |
    |  3 haiku      |   +---------------+
    |  agents vote  |
    +-------+-------+
            |
       majority?
      yes   |     no
    +---v---+ +---v-----------+
    | Sub.  | | Ask the user  |
    +-------+ +---------------+
            |
    +-------v-----------+
    |  Claude receives:  |
    |  [Pronoun Resolution: "it" -> "auth middleware in src/server.ts"]  |
    |  fix it            |
    +--------------------+
```

The original message is never modified. Claude receives a disambiguation preamble alongside your prompt.

## Detection: What Gets Flagged

**Target pronouns:** `it`, `them`, `these`, `those`, `that`, `this`, `they`, `its`

The skill doesn't blindly flag every pronoun. It checks whether the prompt is **self-contained** -- whether it has enough nouns and specifics to resolve its own pronouns.

### Flagged (ambiguous -- needs resolution)

| Prompt | Why |
|--------|-----|
| `fix it` | "it" has no referent in the message |
| `is it possible` | standalone question, "it" refers to prior context |
| `that's correct` | standalone affirmation, "that" references something |
| `update them` | "them" could be anything |
| `take that and apply it to these` | three chained pronouns, all ambiguous |

### Not flagged (self-contained -- passes through)

| Prompt | Why |
|--------|-----|
| `fix it in the auth handler` | "it" is qualified by "in the auth handler" |
| `is it possible to add retry logic` | full context provided |
| `that's correct, now refactor the parser` | "that" is structural, real instruction is clear |
| `update these test files` | "these" immediately followed by "test files" |
| `refactor the auth handler in server.ts` | no pronouns at all |

### Edge cases

**Multiple pronouns:** `"Fix it and update them"` -- each resolved independently. If only one falls below the confidence threshold, only that one escalates to the council. The confident one substitutes immediately.

**Chained references:** `"Take that and apply it to these"` -- resolved left-to-right. "that" first, then "it" (which may now reference the resolved "that"), then "these."

**Idiomatic uses:** `"Let it crash"`, `"this is fine"` -- the self-check recognizes genuine idioms and skips them. The ledger tracks these patterns so false positive rates decrease over time.

## Tiered Resolution Engine

### Tier 1: Quick Self-Check

A single haiku-tier LLM call. Fast, cheap. Gets your message plus recent context and returns a structured resolution with a confidence score (0.0-1.0).

```json
{
  "pronoun": "it",
  "referent": "the auth middleware in src/server.ts",
  "confidence": 0.92,
  "context_signal_used": "last_edited_file",
  "idiomatic": false
}
```

If confidence >= the adaptive threshold (default 0.8), the resolution is accepted and injected silently.

### Tier 2: Council Vote

Triggered only when Tier 1 confidence is below threshold. Spawns 3 independent haiku subagents. Each resolves the pronoun independently -- they don't see each other's answers (prevents anchoring bias).

- **2/3 agree:** majority wins, substitute silently
- **All 3 disagree:** falls back to asking you directly via AskUserQuestion (the only time the skill breaks silence)

### Why tiered?

Most pronouns are easy. "fix it" after you just edited one file? Haiku resolves that at 0.95 confidence in under a second. The council only fires for genuinely ambiguous cases, saving tokens and latency.

## Self-Learning Ledger

Every resolution is logged to `.claude/pronoun-ledger.json` in your project directory. The ledger tracks three things:

### 1. Resolution History

```json
{
  "timestamp": "2026-05-24T14:30:00Z",
  "pronoun": "it",
  "original_prompt": "fix it",
  "resolved_to": "the auth middleware in src/server.ts",
  "tier_used": "self-check",
  "confidence": 0.92,
  "context_signal_used": "last_edited_file",
  "was_corrected": false
}
```

If you correct the resolution (e.g., "no not that, I meant the database migration"), `was_corrected` flips to `true` and the ledger learns from the mistake.

### 2. Context Reliability Scores

Tracks which context signals produce accurate resolutions for your project:

```json
{
  "last_edited_file": 0.85,
  "last_tool_call": 0.72,
  "conversation_topic": 0.45,
  "recent_symbol": 0.63
}
```

Scores update via exponential moving average (alpha=0.2). The self-check prompt receives these scores and weights more reliable signals higher.

### 3. Adaptive Threshold

Starts at 0.8. Recalculates every 10 resolutions:

| Self-check accuracy | Threshold change | Effect |
|---------------------|------------------|--------|
| > 90% | drops 0.05 (min 0.6) | Trusts self-check more, fewer council calls |
| 75-90% | no change | Stays the course |
| < 75% | rises 0.05 (max 0.95) | Escalates to council more often |

A project where you always mean "the last file I edited" will quickly learn to resolve confidently without the council. A project with ambiguous naming conventions will stay conservative.

### Correction Detection

The skill watches your follow-up messages for correction signals:

- Explicit: "no not that", "I meant X", "wrong file"
- Redirections: "the other one", "I was talking about Y"
- Frustration: "why are you looking at X"

When detected, the most recent resolution is marked as corrected and the context reliability score for the signal that was used gets downgraded.

### Maintenance

Entries older than 30 days are pruned automatically on session startup. The ledger stays small -- a few hundred entries max for an active project.

## File Structure

```
pronoun-resolver/
  SKILL.md                       # Skill definition + hook wiring
  bin/
    detect-pronouns.sh           # Hook entry point -- regex scan + orchestration
    resolve.sh                   # Tiered resolution engine
    ledger.sh                    # Ledger read/write/prune/threshold utilities
  prompts/
    self-check.md                # Tier 1 prompt template
    council-agent.md             # Tier 2 prompt template (per subagent)
    correction-detector.md       # Post-resolution correction detection prompt
```

## Install

### From ClaWHub (recommended)

```bash
clawhub install pronoun-resolver
```

### From GitHub

```bash
git clone https://github.com/kaicianflone/coding-pronoun-prompt-resolver.git
ln -s "$(pwd)/coding-pronoun-prompt-resolver" ~/.claude/skills/pronoun-resolver
```

### Manual

Copy the entire directory to `~/.claude/skills/pronoun-resolver`.

The skill activates immediately. The `user-prompt-submit` hook fires on every message automatically.

## Configuration

### Disable for a project

```bash
mkdir -p .claude
touch .claude/pronoun-resolver-disabled
```

### Re-enable

```bash
rm .claude/pronoun-resolver-disabled
```

### Reset the ledger

```bash
rm .claude/pronoun-ledger.json
```

The ledger will be re-created on the next resolution with default settings (threshold 0.8, all context signals at 0.5).

### Gitignore

Add to your project's `.gitignore`:

```
.claude/pronoun-ledger.json
.claude/pronoun-resolver-disabled
```

The ledger is per-developer, per-project. It should not be committed.

## Requirements

- Claude Code CLI v2.0+ (`claude` command in PATH)
- Python 3.6+
- Bash 4+

## How It Differs From System Prompt Instructions

You could add "don't use pronouns" to your system prompt. But that:
- Only works if Claude follows the instruction (it often doesn't for short prompts)
- Doesn't resolve what the pronoun actually means
- Doesn't learn from your patterns over time
- Adds to every prompt's token cost whether or not pronouns are present

This skill intercepts at the input layer, resolves concretely, costs nothing when there are no pronouns, and gets better over time.

## License

MIT
