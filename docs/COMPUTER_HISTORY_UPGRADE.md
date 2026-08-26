# Goalong History — capture, memory and agent-access upgrade

This upgrade keeps the existing LocalHistory architecture and storage identity. It adds evidence-based capture health, separately retained semantic snapshots, deterministic local memories, a chronological source inspector, independent retention policies, and a read-only JSON query CLI.

## Safety boundary

The implementation intentionally does **not**:

- reconstruct ordinary characters from keycodes;
- store clipboard data, screenshots, video, microphone or system audio;
- store details from private browsing, excluded apps/domains, Secure Input or secure controls;
- execute instructions found in captured pages, conversations or documents;
- treat an application heartbeat as proof of user activity;
- treat a cryptographic commitment as proof of identity, attention or productivity;
- bypass macOS Transparency, Consent and Control (TCC).

Semantic text is untrusted local data. The deterministic summarizer never invokes tools and every important claim carries coverage and source-event provenance.

## Data layout

Existing paths remain compatible under `~/Library/Application Support/LocalHistory/`.

| Class | Path | Default role |
|---|---|---|
| Detailed events | `events/*.jsonl` | Exact observations and technical gaps |
| Semantic payloads | `semantic/*.semantic.jsonl` | Bounded Accessibility text after explicit consent |
| Memories | `memories/*.memory.json` and Markdown | Long-lived, readable summaries with provenance |
| Analysis cache | `analysis/*` | Regenerable day recap and agent brief |
| Capture health | `capture-health.json` | Permission, tap, callback and recent-counter evidence |
| Minute seals | `seals/*` | Existing integrity commitments |
| Receipts | `receipts/*` | Existing publication receipts |

Semantic plaintext is no longer written into schema-v4 event metadata. A `semanticSnapshot` event stores only a bounded reference and integrity hash; the plaintext has its own retention and deletion path.

Schema-v5 keeps that semantic separation and compacts only the integrity envelope: new
event rows store the original event once plus per-field salts and chain/root hashes. Full
commitment openings are reconstructed on read for local verification and selective
sharing. Existing schema-v2–v4 JSONL remains readable and is never rewritten merely to
adopt the smaller representation.

## Capture-health states

The recorder distinguishes:

- **Ready**: usable Accessibility context plus a real click/key/scroll callback in the current launch;
- **Permission required**: Accessibility is not trusted or direct Input Monitoring preflight is unavailable where needed;
- **Permission appears enabled but is stale for this build**: an ad-hoc build identity changed and the current process has no working callback/context proof;
- **Input tap unavailable**: creation failed or macOS disabled the tap;
- **Accessibility context unavailable**: the switch may exist, but the process cannot read foreground AX context;
- **Paused**;
- **Excluded, private or secure**;
- **Capture healthy but currently idle**;
- **Waiting for first real input event**.

Creating or enabling a `CGEventTap` does not prove that events arrive. Historical callback timestamps are retained for diagnosis but cannot make a newly launched process Ready.

## Read-only agent interface

Build the CLI:

```bash
swift build -c release --product goalong-history-query
```

Examples:

```bash
.build/release/goalong-history-query status
.build/release/goalong-history-query recent --minutes 60 --actions-only
.build/release/goalong-history-query summary 2026-08-19
.build/release/goalong-history-query search "goalong history"
.build/release/goalong-history-query app Xcode
.build/release/goalong-history-query site chatgpt.com
.build/release/goalong-history-query gaps --start 2026-08-19
.build/release/goalong-history-query memories
.build/release/goalong-history-query sources MEMORY_ID
```

SwiftPM may place the release binary in an architecture-specific directory. The portable command is:

```bash
"$(swift build -c release --show-bin-path)/goalong-history-query" status
```

Every command is read-only JSON and returns coverage, limitations, load issues and provenance. Suppressed periods never expose hidden app/window/URL/semantic detail.

## Applying the guarded patch

From the delivered upgrade bundle:

```bash
python3 apply_upgrade.py \
  --repo /Users/mathisblanc/Documents/ChatGPT/be-productive/localhistory
```

That is a dry run. It verifies exact source anchors and lists planned files without writing. Review the result, then apply:

```bash
python3 apply_upgrade.py \
  --repo /Users/mathisblanc/Documents/ChatGPT/be-productive/localhistory \
  --apply
```

The applier:

1. requires a Git checkout and the expected architecture;
2. computes every edit before writing anything;
3. refuses ambiguous or conflicting anchors atomically;
4. preserves unrelated user changes;
5. backs up every replaced file under `.goalong-history-backup/<UTC-like timestamp>/`;
6. writes a manifest containing the pre-existing Git status and HEAD;
7. never commits, pushes, installs, launches the app or changes TCC.

After applying, inspect before building:

```bash
git status --short
git diff --stat
git diff
```

Rollback a replaced file by copying it from the backup directory named by the applier. New files can be removed after confirming they did not exist before; the backup manifest records the exact applied set.

## Automated validation on the Mac

The repository receives two read-only validation utilities:

```bash
./scripts/inspect_capture.py --help
./scripts/validate_computer_history_upgrade.sh --help
```

Run the full build/test/signature pass without installing, launching or changing permissions:

```bash
./scripts/validate_computer_history_upgrade.sh \
  --repo "$PWD" \
  --data-root "$HOME/Library/Application Support/LocalHistory"
```

It executes:

```text
swift test
./scripts/audit_privacy_boundaries.sh
./scripts/build_app.sh
swift build -c release --product goalong-history-query
```

It then records the built and installed app signatures/designated requirements, queries persisted capture health, inspects the selected JSONL day and writes validation artifacts to `/tmp/goalong-history-validation-<timestamp>` unless `--output` is supplied.

## Controlled real-input validation

Permission changes require the user. Do not reset TCC or toggle a permission merely to make a test pass.

1. Launch the app manually.
2. Read its evidence-based health state.
3. Only when it reports a missing/stale permission, use the guided macOS settings link and approve the current app copy.
4. In non-private, non-sensitive apps:
   - activate an app;
   - change window;
   - click several controls;
   - scroll;
   - use a shortcut;
   - type and correct a harmless sentence;
   - change page/URL;
   - explicitly enable Rich Context and wait for a snapshot.
5. In a secure field, excluded app/domain and private browser window, verify that no detail is recorded.
6. Re-run:

```bash
./scripts/validate_computer_history_upgrade.sh \
  --repo "$PWD" \
  --day YYYY-MM-DD \
  --require-real-events
```

The strict inspection fails unless these observed event types are non-zero: `mouseClick`, `scrollBurst`, `keyboardShortcut`, `typingBurst`, `windowChanged`, `focusChanged`, `urlChanged`, and `semanticSnapshot`. It also fails on privacy-boundary or semantic-integrity violations.

Finally inspect the rendered Timeline visually. Confirm that the default view emphasizes understood activity, an expanded entry shows chronological source events, gaps remain explicit, and semantic text is marked untrusted.

## Ad-hoc update validation

The build scripts support ad-hoc signing when no Developer ID identity is supplied. An ad-hoc build has no stable certificate-backed identity, so a changed build may require reauthorization. The app now records the exact signature mode, CDHash/designated requirement and prior working identity, then reports a stale-build state instead of claiming that TCC persisted.

For a local N → N+1 test:

1. Save the signature logs for N with the validation script.
2. Build N+1 from a source change using the official build script.
3. Compare `built-app-codesign-details.log` and `built-app-designated-requirement.log`.
4. Replace/install only with explicit user authorization.
5. Launch N+1 and perform one controlled input.
6. Confirm either immediate callback evidence or the stale-build guidance followed by reauthorization.

A Developer ID persistence claim must not be made until the same replacement test is performed with a real Developer ID Application certificate and the same bundle/team/signing identity.

## Retention and deletion

The retention model separates detailed events, semantic payloads, memories, analysis caches, seals and receipts. Existing data is migrated non-destructively. On the first migrated launch, cleanup is deliberately disabled; it is activated only after the user explicitly saves the retention setting. Whole-day cleanup then avoids rewriting past integrity journals and preserves the current day. Proof files are preserved unless an explicit proof-deletion operation is chosen.

Deleting raw details does not erase already published commitments or receipts. The period remains cryptographically anchored but cannot later reveal deleted details. The cryptographic layer proves consistency of recorded data, not completeness, identity or honest attention.

## Remaining proof boundary

Automated unit tests can validate serialization, grouping, memory/provenance, privacy validation, retention planning and query behavior. Only a real macOS foreground session can validate TCC, AX availability, event-tap callbacks, browser URLs, Secure Input behavior, visual SwiftUI rendering and update identity behavior.
