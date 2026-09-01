---
context_room:
  id: change.security.fda-reader-isolation
  depends_on:
    - assurance.security.guarantees
    - assurance.security.data-flow
---

# Separate Full Disk Access reader

## Summary

Goalong History currently performs its read-only Apple Screen Time and local AI-provider reads inside the main application process. This active change describes the stronger target: a narrow reader service that can read only supported source locations, cannot access the network or launch processes, and exposes no generic file, SQL or command interface.

This document is a target and acceptance contract. It is not evidence that the reader service has shipped.

## Current state

- Full Disk Access, when granted, applies to the main Goalong application process.
- Provider adapters use reviewed read-only opens, no-follow checks, file-identity validation, bounded reads and SQLite `query_only` controls where applicable.
- The single Goalong app physically excludes the commitment uploader, App Attest transport and Sparkle updater; its optional Codex bridge is separately consented.
- The application is not App-Sandboxed and has no OS-enforced network deny.
- `security-capabilities.json` reports `fullDiskAccessIsolationService: not-shipped` and `authenticatedSensitiveReader: not-shipped`.

## Target boundary

The reader service must have all of these properties:

- a distinct executable, signing identity record and capability manifest entry;
- no network-client entitlement, socket transport, updater, browser opening, Apple Events or process-launch capability;
- no writable access to provider-owned stores;
- compiled provider roots and typed requests only;
- no caller-supplied path, SQL statement, shell command or executable name;
- bounded responses containing only normalized Screen Time records or Agent Activity metadata/content requested for an explicit transient read;
- authenticated, versioned IPC with strict size and time limits;
- no transcript body, Screen Time database copy or general-purpose cache written by either side;
- fail-closed behavior for missing, replaced, symlinked, inaccessible or changing sources.

The main application must not receive broader data than the user-facing feature requires. Agent Activity bodies may cross the boundary only for a transient direct read and must never be persisted in Goalong storage.

## Required acceptance evidence

The change is complete only when all evidence below is produced from the exact distributed artifact:

1. Recursive code-signature and entitlement inventory identifies the reader as a separate code object.
2. The reader has no network, process-launch, Apple Event, browser-opening or generic filesystem capability.
3. Tests prove that arbitrary paths, SQL, oversized replies, malformed messages and unauthenticated clients are rejected.
4. Fixtures for Codex, Claude, OpenCode and Apple Screen Time are read from their original locations without source writes or copied bodies.
5. Missing, inaccessible, replaced, symlinked and concurrently changing sources return explicit bounded states.
6. A runtime network-denial test shows the reader cannot establish IPv4, IPv6, Unix-socket exfiltration or browser-mediated output.
7. A filesystem test shows provider stores remain byte-for-byte unchanged and no body-like data appears under Goalong's application-support root.
8. The generated security manifest changes the isolation fields from `not-shipped` only after the artifact checks above pass.
9. Installation and upgrade tests confirm the intended macOS permission owner and document whether users must grant permission again.

## Explicit non-goals

- Claiming that Full Disk Access itself is narrow.
- Treating source-level `SQLITE_OPEN_READONLY` as an operating-system sandbox.
- Moving the same generic reader behind XPC without reducing its capabilities.
- Sending raw provider data to a verifier, updater or analysis service.
- Replacing direct reads with snapshots, blobs, complete versions or a second transcript vault.

## Rollout rule

Until every acceptance item is proven, public documentation and UI must continue to state that the isolated reader is not shipped and that Full Disk Access belongs to the main process.
