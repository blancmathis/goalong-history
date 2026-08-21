# ChatGPT recap integration

Goalong History can use a user's ChatGPT plan through the official local `codex app-server` protocol to synthesize an evidence-aware daily recap. This is not an OpenAI API-key integration: API credentials are rejected and the app explicitly starts the Codex browser flow with `type: "chatgpt"`.

## Data flow

1. Goalong builds a bounded local context for one day from its deterministic activity analysis, semantic document context, Apple Screen Time summaries, captured Codex/Claude Code/Cursor/OpenCode sessions, and an optional normalized ChatGPT export.
2. Sensitive credential-like strings are redacted and each source is clipped before transmission.
3. Goalong starts the official Codex CLI as `codex app-server` over JSONL stdio using an app-owned `CODEX_HOME`.
4. Codex performs and refreshes the ChatGPT browser login. Goalong reads account metadata but never parses or copies OAuth token values.
5. A single ephemeral Codex thread receives the assembled context inline and returns structured Markdown.
6. The generated recap is written locally as JSON and Markdown. The temporary run directory is deleted.

## Existing ChatGPT conversations

Connecting a ChatGPT account does not expose the user's existing ChatGPT conversation history to Goalong. To include those chats, the user separately imports `conversations.json` from a ChatGPT data export. Goalong keeps only a normalized local copy of user and assistant text, dates, titles, and opaque identifiers; system messages and unsupported content are discarded, common credential patterns are redacted, and prompt inclusion remains bounded.

## Security boundary

The integration fails closed rather than falling back to broad Codex permissions:

- the Codex executable and argument vector are fixed; no shell is invoked;
- the child process gets a strict environment allow-list, excluding API keys, cloud credentials, proxy secrets, and SSH-agent sockets;
- `CODEX_HOME` is isolated under Goalong's private application-support directory;
- Goalong rewrites the app-managed Codex config before every session;
- web search, skills, MCP orchestration, login shells, and tool network access are disabled;
- a custom experimental permission profile grants read access only to Codex's platform-minimal runtime files and Goalong's empty per-run workspace;
- every thread is requested as ephemeral and Goalong verifies the returned `activePermissionProfile`, `runtimeWorkspaceRoots`, and `thread.ephemeral` values before sending the recap prompt;
- execution environments are disabled and approval policy is fixed to `never`;
- outputs and normalized imports use owner-only filesystem permissions.

The model request itself necessarily sends the selected, sanitized recap context to OpenAI through the user's ChatGPT/Codex account. Raw event logs, unrestricted files, and the full ChatGPT export are not sent.

## Product behavior

The AI recap page provides:

- ChatGPT connect, account-state refresh, and disconnect;
- manual recap generation for a selected day;
- optional automatic refresh for today, at most once every four hours while the app is running;
- local import and removal of ChatGPT history;
- source counts, streaming output, saved Markdown/JSON, and local file reveal.

## Packaging and compatibility

The development build locates an official Codex CLI installed on the Mac. A production release should bundle a reviewed, signed Codex helper or provide a first-party installer, then pin and test a minimum Codex version that supports experimental permission profiles, runtime workspace roots, and ephemeral app-server threads. The current bridge verifies those capabilities at runtime and refuses to generate a recap when the server does not enforce them.

For an enterprise distribution, register Goalong's app-server `clientInfo.name` with OpenAI so compliance-log attribution uses a known client identity.
