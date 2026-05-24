#!/usr/bin/env bash
# ledger.sh — Pronoun ledger read/write/prune/recalc utilities
# Sourced by resolve.sh and detect-pronouns.sh, not run directly.

ledger_init() {
  local ledger_path="$1"
  mkdir -p "$(dirname "$ledger_path")"
  cat > "$ledger_path" << 'INITEOF'
{
  "version": 1,
  "adaptive_threshold": 0.8,
  "resolution_count": 0,
  "context_reliability": {
    "last_edited_file": 0.5,
    "last_tool_call": 0.5,
    "conversation_topic": 0.5,
    "recent_symbol": 0.5
  },
  "resolutions": []
}
INITEOF
}

ledger_get_threshold() {
  local ledger_path="$1"
  python3 -c "
import json
with open('${ledger_path}') as f:
    data = json.load(f)
print(data.get('adaptive_threshold', 0.8))
"
}

ledger_get_context_reliability() {
  local ledger_path="$1"
  python3 -c "
import json
with open('${ledger_path}') as f:
    data = json.load(f)
print(json.dumps(data.get('context_reliability', {})))
"
}

ledger_write_resolution() {
  local ledger_path="$1"
  local entry_json="$2"
  python3 << PYEOF
import json

with open('${ledger_path}') as f:
    data = json.load(f)

entry = json.loads('''${entry_json}''')
data['resolutions'].append(entry)
data['resolution_count'] = len(data['resolutions'])

with open('${ledger_path}', 'w') as f:
    json.dump(data, f, indent=2)
PYEOF
}

ledger_mark_corrected() {
  local ledger_path="$1"
  local pronoun="$2"
  python3 << PYEOF
import json

with open('${ledger_path}') as f:
    data = json.load(f)

for entry in reversed(data['resolutions']):
    if entry['pronoun'] == '${pronoun}' and not entry.get('was_corrected', False):
        entry['was_corrected'] = True
        break

with open('${ledger_path}', 'w') as f:
    json.dump(data, f, indent=2)
PYEOF
}

ledger_recalc_threshold() {
  local ledger_path="$1"
  python3 << PYEOF
import json

with open('${ledger_path}') as f:
    data = json.load(f)

resolutions = data['resolutions']
count = len(resolutions)

if count == 0 or count % 10 != 0:
    exit(0)

window = [r for r in resolutions[-10:] if r.get('tier_used') == 'self-check']
if not window:
    exit(0)

correct = sum(1 for r in window if not r.get('was_corrected', False))
accuracy = correct / len(window)

threshold = data['adaptive_threshold']
if accuracy > 0.9:
    threshold = max(0.6, threshold - 0.05)
elif accuracy < 0.75:
    threshold = min(0.95, threshold + 0.05)

data['adaptive_threshold'] = round(threshold, 2)

with open('${ledger_path}', 'w') as f:
    json.dump(data, f, indent=2)
PYEOF
}

ledger_update_context_reliability() {
  local ledger_path="$1"
  local context_signal="$2"
  local was_correct="$3"
  python3 << PYEOF
import json

with open('${ledger_path}') as f:
    data = json.load(f)

signal = '${context_signal}'
correct = '${was_correct}' == 'true'
reliability = data.get('context_reliability', {})

if signal in reliability:
    current = reliability[signal]
    update = 1.0 if correct else 0.0
    reliability[signal] = round(current * 0.8 + update * 0.2, 3)
    data['context_reliability'] = reliability

with open('${ledger_path}', 'w') as f:
    json.dump(data, f, indent=2)
PYEOF
}

ledger_prune() {
  local ledger_path="$1"
  python3 << PYEOF
import json
from datetime import datetime, timedelta, timezone

with open('${ledger_path}') as f:
    data = json.load(f)

cutoff = (datetime.now(timezone.utc) - timedelta(days=30)).isoformat()
before = len(data['resolutions'])
data['resolutions'] = [
    r for r in data['resolutions']
    if r.get('timestamp', '') >= cutoff
]
data['resolution_count'] = len(data['resolutions'])
after = len(data['resolutions'])

with open('${ledger_path}', 'w') as f:
    json.dump(data, f, indent=2)

if before > after:
    print(f'Pruned {before - after} entries older than 30 days')
PYEOF
}
