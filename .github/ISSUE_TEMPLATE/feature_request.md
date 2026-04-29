---
name: Feature request
about: Suggest a small, focused improvement
title: ''
labels: enhancement
---

**The use case**

(What are you trying to do that claudesay doesn't yet support?)

**Why it fits**

claudesay's design rules:

- Lightweight — pure macOS built-ins (`say` + `jq`), no daemon, no API key.
- Quiet by default — false positives are worse than false negatives.
- One file you can audit.

If your idea conflicts with one of these (e.g. needs an API key, or runs a server, or requires a heavy dependency), it's probably better as a fork or a separate project — but please open the issue anyway so we can link to it.

**Suggested behavior**

(Be concrete: what env var / flag / config field, what default, what edge cases.)
