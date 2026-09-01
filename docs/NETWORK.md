---
context_room:
  id: assurance.security.network
---

# Network boundary

## One application

Goalong has one public build, not Local and Connected editions. The app target physically excludes
the retired commitment uploader, App Attest transport and Sparkle updater. It declares no network
client entitlement and embeds no framework.

## Intentional external path

When the user separately enables ChatGPT analysis, Goalong may launch the reviewed local Codex
binary with the fixed `app-server` argument. Codex owns its authenticated ChatGPT transport.
Goalong passes a bounded daily context and does not expose arbitrary commands, executables,
workspace roots or inherited cloud/API credentials to that child process.

Goalong may also open a reviewed HTTPS documentation or account-login URL after an explicit user
action. It does not perform that HTTP request itself.

## Honest limitation

The main app is not App-Sandboxed, so absence of reviewed network code is not an OS-enforced deny.
Verify the exact source and bundle with [`BUILD-VERIFICATION.md`](BUILD-VERIFICATION.md).
