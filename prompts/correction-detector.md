You are checking whether a user's follow-up message indicates they are correcting a previous pronoun resolution.

## Input

Previous resolution: "{{PRONOUN}}" was resolved to "{{RESOLVED_TO}}"

User's follow-up message: {{USER_MESSAGE}}

## Instructions

Does this follow-up message indicate the user is correcting the resolution? Look for:
- Explicit corrections: "no not that", "I meant X", "wrong file", "not that one"
- Redirections: "the other one", "I was talking about X", "no, the Y"
- Frustration with wrong target: "why are you looking at X", "that's not what I said"

Do NOT flag as correction:
- New instructions unrelated to the resolution
- Agreement or continuation ("yes", "good", "now do X")
- Questions about the resolved target

## Output

Return ONLY valid JSON, no markdown fences:

If correction: {"is_correction": true, "corrected_referent": "what the user actually meant"}

If not: {"is_correction": false}
