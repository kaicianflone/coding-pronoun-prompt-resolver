#!/usr/bin/env python3
"""Tiered pronoun resolution engine.
Called by resolve.sh with JSON payload on stdin and env vars for paths."""

import json
import sys
import subprocess
import os
from datetime import datetime, timezone
from collections import Counter


def parse_claude_json(raw):
    """Parse JSON from claude CLI output, handling wrapper and markdown fences."""
    raw = raw.strip()
    try:
        wrapper = json.loads(raw)
        inner = str(wrapper.get("result", raw))
    except (json.JSONDecodeError, TypeError):
        inner = raw

    inner = inner.strip()
    if inner.startswith("```"):
        lines = inner.split("\n")
        end_idx = len(lines) - 1
        for i in range(1, len(lines)):
            if lines[i].strip().startswith("```"):
                end_idx = i
                break
        inner = "\n".join(lines[1:end_idx])

    try:
        return json.loads(inner)
    except (json.JSONDecodeError, TypeError):
        return {}


def write_ledger_entry(ledger_path, entry):
    """Append a resolution entry to the ledger."""
    try:
        with open(ledger_path) as f:
            data = json.load(f)
        data["resolutions"].append(entry)
        data["resolution_count"] = len(data["resolutions"])
        with open(ledger_path, "w") as f:
            json.dump(data, f, indent=2)
    except Exception:
        pass


def recalc_threshold(ledger_path):
    """Recalculate adaptive threshold every 10 resolutions."""
    try:
        with open(ledger_path) as f:
            data = json.load(f)
        resolutions = data["resolutions"]
        count = len(resolutions)
        if count == 0 or count % 10 != 0:
            return
        window = [r for r in resolutions[-10:] if r.get("tier_used") == "self-check"]
        if not window:
            return
        correct = sum(1 for r in window if not r.get("was_corrected", False))
        accuracy = correct / len(window)
        threshold = data["adaptive_threshold"]
        if accuracy > 0.9:
            threshold = max(0.6, threshold - 0.05)
        elif accuracy < 0.75:
            threshold = min(0.95, threshold + 0.05)
        data["adaptive_threshold"] = round(threshold, 2)
        with open(ledger_path, "w") as f:
            json.dump(data, f, indent=2)
    except Exception:
        pass


def run_tier1(user_msg, pronouns, conversation_context, context_reliability, skill_dir):
    """Run Tier 1 self-check via claude CLI."""
    try:
        with open(os.path.join(skill_dir, "prompts", "self-check.md")) as f:
            template = f.read()
    except FileNotFoundError:
        return {"resolutions": []}

    prompt = template
    prompt = prompt.replace("{{USER_MESSAGE}}", user_msg)
    prompt = prompt.replace("{{PRONOUNS}}", pronouns)
    prompt = prompt.replace("{{CONVERSATION_CONTEXT}}", conversation_context)
    prompt = prompt.replace("{{CONTEXT_RELIABILITY}}", context_reliability)

    try:
        result = subprocess.run(
            ["claude", "-p", "--model", "haiku", "--output-format", "json"],
            input=prompt,
            capture_output=True,
            text=True,
            timeout=30,
        )
        parsed = parse_claude_json(result.stdout)
        if "resolutions" in parsed:
            return parsed
        return {"resolutions": []}
    except Exception:
        return {"resolutions": []}


def run_council(user_msg, pronoun, project_dir, skill_dir):
    """Run Tier 2 council vote for a single pronoun."""
    try:
        with open(os.path.join(skill_dir, "prompts", "council-agent.md")) as f:
            template = f.read()
    except FileNotFoundError:
        return []

    prompt = template
    prompt = prompt.replace("{{USER_MESSAGE}}", user_msg)
    prompt = prompt.replace("{{PRONOUN}}", pronoun)
    prompt = prompt.replace(
        "{{CONVERSATION_CONTEXT}}",
        f"(Resolve based on the user message and project context at {project_dir})",
    )

    votes = []
    for _ in range(3):
        try:
            result = subprocess.run(
                ["claude", "-p", "--model", "haiku", "--output-format", "json"],
                input=prompt,
                capture_output=True,
                text=True,
                timeout=30,
            )
            vote = parse_claude_json(result.stdout)
            referent = vote.get("referent", "")
            if referent and referent != "N/A":
                votes.append(referent)
        except Exception:
            continue
    return votes


def main():
    raw_input = sys.stdin.read().strip()
    if not raw_input:
        return
    try:
        payload = json.loads(raw_input)
    except (json.JSONDecodeError, TypeError):
        return
    user_msg = payload.get("user_message", "")
    if not user_msg:
        return
    pronouns = ",".join(payload.get("pronouns", []))
    project_dir = payload.get("project_dir", ".")
    skill_dir = os.environ.get("SKILL_DIR", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ledger_path = os.path.join(project_dir, ".claude", "pronoun-ledger.json")

    # Read threshold and context reliability
    try:
        with open(ledger_path) as f:
            ledger = json.load(f)
        threshold = ledger.get("adaptive_threshold", 0.8)
        context_reliability = json.dumps(ledger.get("context_reliability", {}))
    except (FileNotFoundError, json.JSONDecodeError):
        threshold = 0.8
        context_reliability = "{}"

    conversation_context = (
        "(Previous conversation context is not available in hook scope. "
        f"Resolve based on the user message and general project context at {project_dir})"
    )

    # Tier 1: self-check
    tier1 = run_tier1(user_msg, pronouns, conversation_context, context_reliability, skill_dir)
    resolutions = tier1.get("resolutions", [])

    preamble_parts = []
    council_pronouns = []

    for r in resolutions:
        pronoun = r.get("pronoun", "")
        referent = r.get("referent", "")
        confidence = float(r.get("confidence", 0))
        idiomatic = r.get("idiomatic", False)
        context_signal = r.get("context_signal_used", "none")

        if idiomatic:
            continue

        if confidence >= threshold:
            preamble_parts.append(f'[Pronoun Resolution: "{pronoun}" -> "{referent}"]')
            write_ledger_entry(ledger_path, {
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "pronoun": pronoun,
                "original_prompt": user_msg[:200],
                "resolved_to": referent,
                "tier_used": "self-check",
                "confidence": confidence,
                "context_signal_used": context_signal,
                "was_corrected": False,
            })
        else:
            council_pronouns.append(pronoun)

    # Tier 2: council for low-confidence pronouns
    for pronoun in council_pronouns:
        votes = run_council(user_msg, pronoun, project_dir, skill_dir)

        if len(votes) >= 2:
            counts = Counter(votes)
            winner, count = counts.most_common(1)[0]
            if count >= 2:
                preamble_parts.append(f'[Pronoun Resolution: "{pronoun}" -> "{winner}"]')
                write_ledger_entry(ledger_path, {
                    "timestamp": datetime.now(timezone.utc).isoformat(),
                    "pronoun": pronoun,
                    "original_prompt": user_msg[:200],
                    "resolved_to": winner,
                    "tier_used": "council",
                    "confidence": count / len(votes),
                    "context_signal_used": "council_vote",
                    "was_corrected": False,
                })
            else:
                preamble_parts.append(
                    f'[Pronoun Resolution: "{pronoun}" -> UNRESOLVED. '
                    f'Ask the user what they mean by "{pronoun}"]'
                )
        elif len(votes) == 1:
            preamble_parts.append(f'[Pronoun Resolution: "{pronoun}" -> "{votes[0]}" (single council response)]')
            write_ledger_entry(ledger_path, {
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "pronoun": pronoun,
                "original_prompt": user_msg[:200],
                "resolved_to": votes[0],
                "tier_used": "council",
                "confidence": 0.5,
                "context_signal_used": "council_vote",
                "was_corrected": False,
            })
        else:
            preamble_parts.append(
                f'[Pronoun Resolution: "{pronoun}" -> UNRESOLVED. '
                f'Ask the user what they mean by "{pronoun}"]'
            )

    recalc_threshold(ledger_path)

    if preamble_parts:
        print("\n".join(preamble_parts))


if __name__ == "__main__":
    main()
