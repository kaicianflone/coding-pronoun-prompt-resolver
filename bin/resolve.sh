#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/ledger.sh"

PAYLOAD=$(cat)

USER_MSG=$(printf '%s' "$PAYLOAD" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['user_message'])")
PRONOUNS=$(printf '%s' "$PAYLOAD" | python3 -c "import json,sys; print(','.join(json.loads(sys.stdin.read())['pronouns']))")
PROJECT_DIR=$(printf '%s' "$PAYLOAD" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['project_dir'])")

LEDGER_PATH="$PROJECT_DIR/.claude/pronoun-ledger.json"

if [ ! -f "$LEDGER_PATH" ]; then
  ledger_init "$LEDGER_PATH"
fi

THRESHOLD=$(ledger_get_threshold "$LEDGER_PATH")
CONTEXT_RELIABILITY=$(ledger_get_context_reliability "$LEDGER_PATH")

SELF_CHECK_TEMPLATE=$(cat "$SKILL_DIR/prompts/self-check.md")

CONVERSATION_CONTEXT="(Previous conversation context is not available in hook scope. Resolve based on the user message and general project context at $PROJECT_DIR)"

# Escape user message for sed substitution
USER_MSG_ESCAPED=$(printf '%s' "$USER_MSG" | sed 's/[&/\]/\\&/g')

SELF_CHECK_PROMPT=$(printf '%s' "$SELF_CHECK_TEMPLATE" \
  | sed "s|{{USER_MESSAGE}}|$USER_MSG_ESCAPED|g" \
  | sed "s|{{PRONOUNS}}|$PRONOUNS|g" \
  | sed "s|{{CONVERSATION_CONTEXT}}|$CONVERSATION_CONTEXT|g" \
  | sed "s|{{CONTEXT_RELIABILITY}}|$CONTEXT_RELIABILITY|g"
)

TIER1_RESULT=$(printf '%s' "$SELF_CHECK_PROMPT" | claude -p --model haiku --output-format json 2>/dev/null || echo '{"result":"{}"}')

# Parse tier 1 result — handle claude JSON wrapper and markdown fences
TIER1_PARSED=$(python3 << 'PYEOF'
import json, sys

raw = sys.argv[1] if len(sys.argv) > 1 else sys.stdin.read()
raw = raw.strip()

try:
    wrapper = json.loads(raw)
    if 'result' in wrapper:
        inner = str(wrapper['result'])
    else:
        inner = raw
except:
    inner = raw

inner = inner.strip()
if inner.startswith('```'):
    lines = inner.split('\n')
    inner = '\n'.join(lines[1:-1])

try:
    data = json.loads(inner)
    print(json.dumps(data))
except:
    print(json.dumps({"resolutions": []}))
PYEOF
 <<< "$TIER1_RESULT")

# Process resolutions: tier 1 pass, escalate low-confidence to tier 2
python3 << PYEOF
import json, sys, subprocess, os
from datetime import datetime, timezone
from collections import Counter

tier1_raw = '''$TIER1_PARSED'''
threshold = float('$THRESHOLD')
user_msg = '''$(printf '%s' "$USER_MSG" | sed "s/'/'\\\\''/g")'''
ledger_path = '$LEDGER_PATH'
skill_dir = '$SKILL_DIR'
project_dir = '$PROJECT_DIR'

try:
    tier1 = json.loads(tier1_raw)
except:
    tier1 = {"resolutions": []}

resolutions = tier1.get('resolutions', [])
preamble_parts = []

def write_ledger_entry(entry):
    entry_json = json.dumps(entry)
    try:
        subprocess.run(
            ['python3', '-c', f"""
import json
with open('{ledger_path}') as f:
    data = json.load(f)
data['resolutions'].append(json.loads('''{entry_json}'''))
data['resolution_count'] = len(data['resolutions'])
with open('{ledger_path}', 'w') as f:
    json.dump(data, f, indent=2)
"""],
            capture_output=True, timeout=5
        )
    except:
        pass

def parse_claude_json(raw):
    raw = raw.strip()
    try:
        wrapper = json.loads(raw)
        inner = str(wrapper.get('result', raw))
    except:
        inner = raw
    inner = inner.strip()
    if inner.startswith('`' * 3):
        lines = inner.split('\n')
        inner = '\n'.join(lines[1:-1])
    return json.loads(inner)

council_pronouns = []

for r in resolutions:
    pronoun = r.get('pronoun', '')
    referent = r.get('referent', '')
    confidence = float(r.get('confidence', 0))
    idiomatic = r.get('idiomatic', False)
    context_signal = r.get('context_signal_used', 'none')

    if idiomatic:
        continue

    if confidence >= threshold:
        preamble_parts.append(f'[Pronoun Resolution: "{pronoun}" -> "{referent}"]')
        write_ledger_entry({
            'timestamp': datetime.now(timezone.utc).isoformat(),
            'pronoun': pronoun,
            'original_prompt': user_msg[:200],
            'resolved_to': referent,
            'tier_used': 'self-check',
            'confidence': confidence,
            'context_signal_used': context_signal,
            'was_corrected': False
        })
    else:
        council_pronouns.append(pronoun)

# Tier 2: council vote for low-confidence pronouns
for pronoun in council_pronouns:
    council_template_path = f'{skill_dir}/prompts/council-agent.md'
    with open(council_template_path) as f:
        council_template = f.read()

    council_prompt = council_template.replace('{{USER_MESSAGE}}', user_msg)
    council_prompt = council_prompt.replace('{{PRONOUN}}', pronoun)
    council_prompt = council_prompt.replace('{{CONVERSATION_CONTEXT}}',
        f'(Resolve based on the user message and project context at {project_dir})')

    votes = []
    for i in range(3):
        try:
            result = subprocess.run(
                ['claude', '-p', '--model', 'haiku', '--output-format', 'json'],
                input=council_prompt, capture_output=True, text=True, timeout=30
            )
            vote = parse_claude_json(result.stdout)
            referent = vote.get('referent', '')
            if referent:
                votes.append(referent)
        except:
            continue

    if len(votes) >= 2:
        counts = Counter(votes)
        winner, count = counts.most_common(1)[0]
        if count >= 2:
            preamble_parts.append(f'[Pronoun Resolution: "{pronoun}" -> "{winner}"]')
            write_ledger_entry({
                'timestamp': datetime.now(timezone.utc).isoformat(),
                'pronoun': pronoun,
                'original_prompt': user_msg[:200],
                'resolved_to': winner,
                'tier_used': 'council',
                'confidence': count / len(votes),
                'context_signal_used': 'council_vote',
                'was_corrected': False
            })
        else:
            preamble_parts.append(f'[Pronoun Resolution: "{pronoun}" -> UNRESOLVED. Ask the user what they mean by "{pronoun}"]')
    elif len(votes) == 1:
        preamble_parts.append(f'[Pronoun Resolution: "{pronoun}" -> "{votes[0]}" (single council response)]')
        write_ledger_entry({
            'timestamp': datetime.now(timezone.utc).isoformat(),
            'pronoun': pronoun,
            'original_prompt': user_msg[:200],
            'resolved_to': votes[0],
            'tier_used': 'council',
            'confidence': 0.5,
            'context_signal_used': 'council_vote',
            'was_corrected': False
        })
    else:
        preamble_parts.append(f'[Pronoun Resolution: "{pronoun}" -> UNRESOLVED. Ask the user what they mean by "{pronoun}"]')

# Recalculate threshold
try:
    subprocess.run(
        ['python3', '-c', f"""
import json
with open('{ledger_path}') as f:
    data = json.load(f)
resolutions = data['resolutions']
count = len(resolutions)
if count > 0 and count % 10 == 0:
    window = [r for r in resolutions[-10:] if r.get('tier_used') == 'self-check']
    if window:
        correct = sum(1 for r in window if not r.get('was_corrected', False))
        accuracy = correct / len(window)
        threshold = data['adaptive_threshold']
        if accuracy > 0.9:
            threshold = max(0.6, threshold - 0.05)
        elif accuracy < 0.75:
            threshold = min(0.95, threshold + 0.05)
        data['adaptive_threshold'] = round(threshold, 2)
        with open('{ledger_path}', 'w') as f:
            json.dump(data, f, indent=2)
"""],
        capture_output=True, timeout=5
    )
except:
    pass

if preamble_parts:
    print('\n'.join(preamble_parts))
PYEOF
