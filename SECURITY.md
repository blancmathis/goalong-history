---
context_room:
  id: assurance.security.integrity-model
---

# Security model — Goalong History v0.6

## Summary

Goalong combines all-off capability defaults, direct read-only provider access and layered local integrity proofs. The single app contains no first-party uploader or updater. Current binary capabilities and Full Disk Access limitations are defined separately in [GUARANTEES.md](docs/GUARANTEES.md) and [THREAT-MODEL.md](docs/THREAT-MODEL.md).

## Defines

The current integrity, selective-disclosure and local proof model.

## Does not define

Full Disk Access isolation or release reproducibility.

## Goals

1. Detailed activity remains local during continuous capture.
2. Opaque commitments can be verified locally without disclosing their contents.
3. Later modification/addition/removal of committed data is detectable.
4. Users can selectively disclose fields without rewriting the original history.
5. Private-browser content and raw typed characters are not collected.

## Cryptographic layers

- SHA-256 salted commitments per event field group.
- Fixed-order Merkle root per event.
- Event hash chain with monotonic sequence.
- Salted minute commitments for time, event-root, event-count, and coverage.
- Fixed-order minute Merkle root.
- Minute anchor hash chain.
- P-256 ECDSA signature using a Secure Enclave key when possible, Keychain fallback otherwise.
- Offline share verification recomputes commitments, local-day and boundary links,
  device identities, and every embedded P-256 signature before export and in the CLI.
- New AI recap runs bind the exact prompt hash, complete saved-result hash (both
  scores and all five lines), source-count hash, context digest and
  model/provider observations into a compact domain-separated P-256 device
  signature without storing the prompt body.
- Schema-v4 runs additionally sign an immutable definition and one complete run
  attestation as strict canonical integer-only JSON in compact ES256 JWS. The run
  links a random ID/nonce, monotonic sequence, previous run, UTC period, prompt
  descriptor, response descriptor, parsed result, salted source-commitment root,
  available activity-anchor hashes, build/key states and honest independent
  external-receipt/App-Attest statuses.
- The `.goalong-proof` offline verifier validates the strict uncompressed ZIP
  inventory, every byte count/hash, both JWS signatures, public-key ID, signed
  artifact links, execution/provider/day/source-root consistency and the source
  Merkle root. Exported source references are opaque and contain no local paths.
- Only the bounded generated response is retained temporarily: AES-256-GCM,
  random per-run DEK, authenticated execution metadata and a `ThisDeviceOnly`
  Keychain item. The complete prompt and source transcript bodies remain
  hash-only. Deletion removes the DEK before the ciphertext.
- The shipped app does not upload anchors or attach App Attest material. The retained reference protocol is not a current runtime capability.

## Selective disclosure

Hidden fields are represented only by salted commitments. The salt/opening is released only when the user chooses to disclose that field.

A `privateOnly` minute does not release the event-list root opening or event-count opening. Therefore it proves the committed minute exists without revealing event structure/count.

## Threats mitigated

- editing a JSON event after anchoring;
- swapping one app/category for another after anchoring;
- deleting/reordering an event inside a disclosed minute;
- adding a new event after anchoring;
- replaying an old anchor challenge;
- changing an anchored minute root;
- omitting an anchor in the middle of a disclosed range;
- hiding leading/trailing day anchors when valid adjacent day-boundary openings exist.

## Threats not fully solved

- a modified/unofficial client beyond what Developer ID, notarization and exact-artifact review can establish;
- synthetic HID hardware that appears to macOS as genuine keyboard/mouse input;
- another human using the device;
- compromised kernel/hypervisor/OS;
- deliberately changing system clock/timezone (server arrival times can be used as an anomaly signal but this repository does not yet score those anomalies);
- alteration of unsigned share metadata such as `createdAt`, classifier version,
  local trust-tier labels or opaque receipt IDs; the offline verifier reports
  these fields as unverified and does not promote them to App Attest evidence;
- provider authorship of an AI recap: the local attestation proves only what the
  local Goalong device key signed, not that OpenAI signed the response or model name.
- complete-source exhaustiveness when a provider file is missing, unreadable or
  changed before Goalong observes it; coverage states report this as partial or
  unknown rather than inferring inactivity;
- continuity across a future analysis-signing key replacement until a transition
  artifact signed by both old and new keys is implemented;
- an external timestamp, official-build attestation or provider receipt for an
  analysis run unless the corresponding independently signed artifact is actually
  present. Current analysis proofs report these states as absent/not requested.

## Retired server path

`AnchorUploadRequest` remains as a reference protocol model, but the uploader and App Attest
implementation are physically excluded from the single app target. Any future reintroduction must
add a new explicit consent, threat-model update and artifact-level verification before release.
