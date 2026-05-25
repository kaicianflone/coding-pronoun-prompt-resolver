#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Check for disable sentinel
if [ -f "$PROJECT_DIR/.claude/pronoun-resolver-disabled" ]; then
  exit 0
fi

# Read the user's message from stdin
USER_MSG=$(cat)

if [ -z "$USER_MSG" ]; then
  exit 0
fi

# Normalize: collapse newlines to spaces for pattern matching and output
USER_MSG_FLAT="${USER_MSG//$'\n'/ }"

# --- Detection Phase (no LLM calls, pure regex/heuristic) ---

FLAGS=()

# 1. Personal pronouns (always referential — always flag)
PERSONAL_REGEX='\b(it|them|they|its)\b'
PERSONAL_MATCHES=$(printf '%s\n' "$USER_MSG_FLAT" | grep -ioE "$PERSONAL_REGEX" || true)

if [ -n "$PERSONAL_MATCHES" ]; then
  PERSONAL_UNIQUE=$(printf '%s' "$PERSONAL_MATCHES" | tr '[:upper:]' '[:lower:]' | sort -u | tr '\n' ',' | sed 's/,$//')
  FLAGS+=("[AMBIGUOUS: pronouns=\"$PERSONAL_UNIQUE\" | type=pronoun]")
fi

# 2. Demonstratives (this/that/these/those) — only flag when used as standalone pronoun,
#    not as determiner ("this function", "that file" are self-contained)
DEMO_REGEX='\b(this|that|these|those)\b'
DEMO_MATCHES=$(printf '%s\n' "$USER_MSG_FLAT" | grep -ioE "$DEMO_REGEX" || true)

if [ -n "$DEMO_MATCHES" ]; then
  # Filter: only keep demonstratives NOT followed by a noun-like word
  AMBIGUOUS_DEMOS=$(python3 -c "
import re, sys
msg = sys.argv[1].lower()
demos = set(sys.argv[2].lower().split())
ambiguous = []
words = msg.split()
for i, w in enumerate(words):
    if w.rstrip('.,!?;:') in demos:
        # Ambiguous if: at end, or next word is a verb/conjunction/preposition
        if i == len(words) - 1:
            ambiguous.append(w.rstrip('.,!?;:'))
        else:
            next_w = words[i+1].rstrip('.,!?;:')
            verbs = {'is','are','was','were','has','have','had','do','does','did','will','would','should','could','can','may','might','shall','must','need','work','works','look','looks','seem','seems','feel','feels','go','goes','come','comes','run','runs','make','makes','break','breaks','fail','fails','pass','passes','take','takes','get','gets'}
            conj = {'and','or','but','yet','so','then','because','if','when','while','after','before','since','until','unless','although','though','however','instead','rather','anyway'}
            if next_w in verbs or next_w in conj:
                ambiguous.append(w.rstrip('.,!?;:'))
if ambiguous:
    print(','.join(sorted(set(ambiguous))))
" "$USER_MSG_FLAT" "$(printf '%s' "$DEMO_MATCHES" | tr '\n' ' ')" 2>/dev/null || true)

  if [ -n "$AMBIGUOUS_DEMOS" ]; then
    # Merge with personal pronouns if present
    if [ ${#FLAGS[@]} -gt 0 ]; then
      # Replace the existing pronoun flag with merged list
      MERGED="$PERSONAL_UNIQUE,$AMBIGUOUS_DEMOS"
      MERGED=$(printf '%s' "$MERGED" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//' | sed 's/^,//')
      FLAGS=("[AMBIGUOUS: pronouns=\"$MERGED\" | type=pronoun]")
    else
      FLAGS+=("[AMBIGUOUS: pronouns=\"$AMBIGUOUS_DEMOS\" | type=pronoun]")
    fi
  fi
fi

# 3. Vague referents (removed "thing" — too noisy on common English)
VAGUE_REGEX='\b(other|something|someone|somewhere|anything|everything|stuff)\b'
VAGUE_MATCHES=$(printf '%s\n' "$USER_MSG_FLAT" | grep -ioE "$VAGUE_REGEX" || true)

if [ -n "$VAGUE_MATCHES" ]; then
  VAGUE_UNIQUE=$(printf '%s' "$VAGUE_MATCHES" | tr '[:upper:]' '[:lower:]' | sort -u | tr '\n' ',' | sed 's/,$//')
  FLAGS+=("[AMBIGUOUS: vague=\"$VAGUE_UNIQUE\" | type=vague_referent]")
fi

# 4. Bare imperatives (only if no pronouns/vague found — those take priority)
if [ ${#FLAGS[@]} -eq 0 ]; then
  IMPLICIT_TYPE=$(python3 "$SCRIPT_DIR/detect-implicit.py" <<< "$USER_MSG_FLAT" 2>/dev/null || echo "none")
  if [ -n "$IMPLICIT_TYPE" ] && [ "$IMPLICIT_TYPE" != "none" ]; then
    # Extract just the verb for consistent flag format (not the full message)
    VERB=$(printf '%s' "$USER_MSG_FLAT" | awk '{print tolower($1)}')
    FLAGS+=("[AMBIGUOUS: implicit verb=\"$VERB\" | type=bare_imperative | subtype=$IMPLICIT_TYPE]")
  fi
fi

# --- Output Phase ---

if [ ${#FLAGS[@]} -gt 0 ]; then
  # Compact preamble so Claude knows how to handle flags without needing SKILL.md loaded
  echo "[PRONOUN-RESOLVER: Resolve these using conversation context. HIGH confidence=act silently. MEDIUM=state assumption then act. LOW/no context=ask user first.]"
  printf '%s\n' "${FLAGS[@]}"
fi
