---
context_room:
  id: assurance.security.threat-model
  depends_on:
    - assurance.security.guarantees
---

# Threat model and trust boundaries

## Summary

The highest current risk is broad Full Disk Access in the main process. The single app excludes the retired commitment uploader, App Attest transport and updater, gates protected sources behind separate consent, and confines optional process execution to the fixed Codex bridge. A separate explicit website sender discloses selected saved fields; a separately sandboxed reader is not yet shipped.

## Defines

Protected assets, adversaries, current controls, residual risks and the release-blocking target boundary.

## Does not define

Detailed cryptographic encodings or incident-response procedure.

## Protected assets

- provider-owned AI histories and Apple Screen Time databases;
- Goalong detailed events, semantic context, derived history, proofs and keys;
- user identity, browsing metadata, device names and daily routines;
- website upload tokens and the selected fields submitted to a site account;
- source-to-build-to-release integrity.

## Adversaries and failures

The model includes a malicious future update, compromised dependency or CI action, untrusted same-user process, path/symlink replacement, malformed provider database, accidental logging/export leakage, compromised verification server, replay, rollback and an unofficial binary. A compromised macOS kernel/hypervisor, colluding user-approved components, physical coercion and synthetic input hardware remain outside the achievable local-app boundary.

## Current controls

| Risk | Current control | Remaining gap |
| --- | --- | --- |
| Transcript duplication | Metadata-only Agent Activity index; direct provider reads | Transient in-memory text is still visible to the app process |
| Source mutation | `READONLY`, `NOFOLLOW`, inode validation, `query_only`, SQL authorizer | Apple stores may change concurrently and must fail clearly |
| Silent first-party transport | Retired transport exclusions; website send requires a separate explicit action; no scheduled sync | No App Sandbox network deny is enabled; website submission and Codex analysis are external paths |
| Website credential or destination substitution | Chosen owner-only regular token file, descriptor checks, HTTPS origin validation, redirect refusal and no ambient credentials | The chosen endpoint receives the bearer token; same-user compromise and a malicious endpoint remain risks |
| Unintended website audience or authenticity claim | Preview selected fields; omit transcripts/event bodies; native sender cannot grant audiences; receipt remains unverified | Existing site rules can share a new submission; server authorization and revocation need independent validation |
| Dependency drift | No remote Swift package dependency plus immutable GitHub Action commits | Independent action provenance verification is not yet automated |
| Release substitution | Exact commit manifest, artifact hashes and GitHub/Sigstore provenance | No Apple notarization or byte-for-byte independent reproduction |
| Data tampering | Salted commitments, chains and device signatures | Provider authorship and human identity are not proven |
| Keyboard overcollection | Key events are reduced before buffering to coarse typing, shortcut or navigation activity | Existing historical rows from older builds may still contain named shortcuts |
| Broad FDA process | Read-only conventions and audits | Separate authenticated XPC reader is not shipped |

## Release decision

The single app is the only supported artifact. It excludes retired emission/update paths and adds only the reviewed explicit website path described in [NETWORK.md](NETWORK.md); it is not the final FDA architecture. Public claims must stay within [GUARANTEES.md](GUARANTEES.md), and the reader-isolation target must satisfy its own acceptance matrix before being promoted to current truth.
