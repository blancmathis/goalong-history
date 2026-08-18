# Security model — LocalHistory v0.3

## Goals

1. Detailed activity remains local during continuous capture.
2. A server can timestamp opaque commitments without seeing their contents.
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
- One-time server challenges prevent simple replay of uploads.
- Server receipt time provides external anchoring.
- Optional App Attest material is attached when supported; production server verification is intentionally not faked in this repository.

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

- a modified/unofficial client until production Developer ID + notarization + real App Attest policy are deployed;
- synthetic HID hardware that appears to macOS as genuine keyboard/mouse input;
- another human using the device;
- compromised kernel/hypervisor/OS;
- deliberately changing system clock/timezone (server arrival times can be used as an anomaly signal but this repository does not yet score those anomalies);
- privacy leakage from metadata such as the fact that a device sends a fixed-size-ish request every minute.

## Server privacy

`AnchorUploadRequest` intentionally has no app/window/URL/event/event-count/local-time fields. The source audit fails if obvious detailed-activity names are added to that request model.

A production server will still see transport metadata such as IP address, TLS connection timing, device pseudonym and request cadence. If those matter, add appropriate proxying/log-retention policies.
