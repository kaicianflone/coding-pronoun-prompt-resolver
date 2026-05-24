#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
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

LEDGER_PATH="$PROJECT_DIR/.claude/pronoun-ledger.json"

# Prune stale ledger entries on first run of the session
if [ -f "$LEDGER_PATH" ]; then
  PRUNE_SENTINEL="/tmp/.pronoun-resolver-pruned-$(date +%Y%m%d)"
  if [ ! -f "$PRUNE_SENTINEL" ]; then
    source "$SCRIPT_DIR/ledger.sh"
    ledger_prune "$LEDGER_PATH" 2>/dev/null || true
    touch "$PRUNE_SENTINEL"
  fi
fi

# Correction detection — check if previous resolution was wrong
if [ -f "$LEDGER_PATH" ]; then
  LAST_RESOLUTION=$(python3 -c "
import json
with open('$LEDGER_PATH') as f:
    data = json.load(f)
resolutions = data.get('resolutions', [])
if resolutions:
    last = resolutions[-1]
    if not last.get('was_corrected', False):
        print(json.dumps(last))
" 2>/dev/null || true)

  if [ -n "$LAST_RESOLUTION" ]; then
    LAST_PRONOUN=$(printf '%s' "$LAST_RESOLUTION" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['pronoun'])")
    LAST_RESOLVED=$(printf '%s' "$LAST_RESOLUTION" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['resolved_to'])")

    CORRECTION_TEMPLATE=$(cat "$SKILL_DIR/prompts/correction-detector.md")
    CORRECTION_PROMPT=$(printf '%s' "$CORRECTION_TEMPLATE" \
      | sed "s|{{PRONOUN}}|$LAST_PRONOUN|g" \
      | sed "s|{{RESOLVED_TO}}|$LAST_RESOLVED|g" \
      | sed "s|{{USER_MESSAGE}}|$(printf '%s' "$USER_MSG" | sed 's/[&/\]/\\&/g')|g"
    )

    CORRECTION_RESULT=$(printf '%s' "$CORRECTION_PROMPT" | claude -p --model haiku --output-format json 2>/dev/null || echo '{}')

    IS_CORRECTION=$(python3 -c "
import json, sys
raw = sys.stdin.read().strip()
try:
    wrapper = json.loads(raw)
    inner = wrapper.get('result', raw)
except:
    inner = raw
inner = str(inner).strip()
if inner.startswith('\`\`\`'):
    lines = inner.split('\n')
    inner = '\n'.join(lines[1:-1])
try:
    data = json.loads(inner)
    if data.get('is_correction', False):
        print('yes')
    else:
        print('no')
except:
    print('no')
" <<< "$CORRECTION_RESULT")

    if [ "$IS_CORRECTION" = "yes" ]; then
      source "$SCRIPT_DIR/ledger.sh"
      ledger_mark_corrected "$LEDGER_PATH" "$LAST_PRONOUN"
      CONTEXT_SIGNAL=$(printf '%s' "$LAST_RESOLUTION" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('context_signal_used','none'))")
      ledger_update_context_reliability "$LEDGER_PATH" "$CONTEXT_SIGNAL" "false"
    fi
  fi
fi

# Target pronouns — word-boundary matched
PRONOUNS_REGEX='\b(it|them|these|those|that|this|they|its)\b'

# Case-insensitive scan
MATCHES=$(printf '%s' "$USER_MSG" | grep -ioE "$PRONOUNS_REGEX" || true)

if [ -z "$MATCHES" ]; then
  exit 0
fi

# Deduplicate and lowercase
UNIQUE_PRONOUNS=$(printf '%s' "$MATCHES" | tr '[:upper:]' '[:lower:]' | sort -u | tr '\n' ',' | sed 's/,$//')

# Build JSON payload for the resolver
PAYLOAD=$(python3 -c "
import json, sys
msg = sys.stdin.read()
pronouns = '${UNIQUE_PRONOUNS}'.split(',')
print(json.dumps({
    'user_message': msg,
    'pronouns': pronouns,
    'project_dir': '${PROJECT_DIR}'
}))
" <<< "$USER_MSG")

RESULT=$("$SCRIPT_DIR/resolve.sh" <<< "$PAYLOAD")

if [ -n "$RESULT" ]; then
  printf '%s\n' "$RESULT"
fi
