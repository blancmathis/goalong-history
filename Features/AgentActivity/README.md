# Agent Activity

Agent Activity is the local-first Goalong History layer for delegated AI work. It watches provider histories and user-selected folders, receives live hook events, preserves every changed version, extracts provider-independent metadata, and exposes the result in the **Agentic work** dashboard tab.

## Sources

The runtime automatically detects existing local folders for:

- Codex (`~/.codex`);
- Claude Code (`~/.claude`);
- Cursor (`~/.cursor` plus Cursor workspace/global state);
- OpenCode (`~/.local/share/opencode`).

Users can add, remove, rename, pause, recursively scan, reclassify, or broaden any other folder from **Agentic work → Folders monitored**.

Live integrations can be installed from the same page:

- Codex user hooks in `~/.codex/hooks.json`;
- Claude Code user hooks in `~/.claude/settings.json`;
- Cursor user hooks in `~/.cursor/hooks.json`;
- an OpenCode global plugin in `~/.config/opencode/plugins/goalong-history.js`.

All four invoke the already-signed Goalong History executable with `--agent-hook-ingest`. The hook process reads JSON from stdin, appends one immutable event envelope to the local inbox, prints `{}`, and exits. It has no network path and never controls the agent.

## Local layout

```text
~/Library/Application Support/LocalHistory/agent-activity/
├── configuration.json
├── state.json
├── manifests/
│   └── YYYY-MM-DD.captures.jsonl
├── blobs/
│   └── <sha-prefix>/<sha>.blob
├── hook-inbox/
│   ├── codex/YYYY-MM-DD/*.agent-event.json
│   ├── claudeCode/YYYY-MM-DD/*.agent-event.json
│   ├── cursor/YYYY-MM-DD/*.agent-event.json
│   └── openCode/YYYY-MM-DD/*.agent-event.json
└── materialized/
```

Directories are mode `0700`; files are mode `0600`.

## Exact version retention

Each changed source receives:

- a complete SHA-256 over the source bytes;
- a content-addressed immutable blob;
- a parsed summary for local search and analysis;
- a manifest linked to the previous manifest hash;
- an `agentArtifactCaptured` event in Goalong History’s normal signed minute chain.

Growing JSONL and log files are stored as append-only deltas when their previous bytes are an exact prefix. A full checkpoint is forced after a bounded delta depth. Materialization reconstructs the original bytes and verifies the complete SHA-256 before opening them.

## Privacy boundary

The full bytes of captured sources stay local. The normal Goalong History verification uploader still receives only opaque minute commitments.

The scanner always excludes common standalone credential and browser-secret files, including authentication JSON, tokens, cookies, `.env` files, private-key formats, SSH/AWS/GPG directories, caches and Goalong History’s own vault. These exclusions remain active even when a user selects **Every file**. Raw transcript and hook payloads are otherwise preserved as-is, so a secret printed inside a prompt, response or tool result remains in the local vault and must be reviewed before sharing.

The event committed into the main Goalong History chain contains only the provider, capture identifiers, byte counts, version, storage kind, manifest hash and content SHA-256. It does not contain the transcript, prompt, response, command, project path, source path, title or excerpt.

## Tests

```bash
swift test --filter AgentActivityTests
```

The 11 tests cover flexible transcript parsing, configuration normalization, exact append-delta reconstruction, incremental metrics, edited/malformed/deleted manifest detection, credential exclusion, default source discovery, raw hook preservation, and non-destructive hook/plugin installation and removal.

## Codex hook trust

Codex keeps user hooks under `~/.codex/hooks.json`. Goalong installs additive command hooks and preserves existing entries. Codex may require the user to trust newly discovered non-managed hooks from its `/hooks` interface before they run. Folder monitoring under `~/.codex` remains available independently.
