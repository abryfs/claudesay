---
name: Bug report
about: Something doesn't work as expected
title: ''
labels: bug
---

**What happened**

(One sentence — what claudesay did or didn't do.)

**Expected**

(What you thought would happen instead.)

**Repro**

Paste the output of these commands. They don't include any private content from your transcripts.

```bash
sw_vers                                                  # macOS version
claude --version                                         # Claude Code version
/bin/bash --version | head -1                            # bash version
jq --version                                             # jq version
~/.claude/hooks/claudesay.sh --version                   # claudesay version
ls -la ~/.claude/hooks/claudesay.sh                      # hook is present + executable
jq '.hooks.Stop' ~/.claude/settings.json                 # Stop hook is wired
say -v Samantha "test"                                   # `say` itself works
```

**Hook trace**

Run the hook against your most recent transcript with debug enabled. This shows exactly which guard the hook hit (filler / debounce / dedupe / ok speak):

```bash
LATEST=$(ls -t ~/.claude/projects/*/*.jsonl | head -1)
echo "{\"transcript_path\":\"$LATEST\",\"session_id\":\"debug\",\"stop_hook_active\":false}" \
  | CLAUDESAY_DEBUG=1 bash ~/.claude/hooks/claudesay.sh
```

(Paste the output here.)
