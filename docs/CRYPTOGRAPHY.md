---
context_room:
  id: assurance.security.cryptography
---

# Cryptography and proof interpretation

## Summary

Goalong uses domain-separated SHA-256 commitments, fixed-order Merkle roots, hash chains and P-256 ECDSA signatures to make later rewriting detectable while supporting selective disclosure. These proofs establish consistency with locally signed data; they do not prove human identity, attention or provider authorship.

## Defines

Cryptographic purpose, primitive families, canonicalization boundary and proof interpretation.

## Does not define

Data collection semantics, network retention or the source-to-binary release chain.

## Construction

- event fields are divided into fixed groups and committed with random 256-bit salts;
- group commitments form a fixed-order event Merkle root;
- events carry a monotonic sequence and previous-event hash;
- each minute commits to time, event-root, event-count and coverage using separate salts;
- minute roots form an anchor chain signed by a P-256 device key;
- selective disclosure releases only the chosen field openings;
- AI analysis proofs bind canonical prompt/result hashes, source-count hash, context digest, model/provider observations and a run chain.

Canonical encodings are versioned and use explicit domain tags, field order and bounded byte representations. Existing schemas and offline verifiers remain the executable authority; [SECURITY.md](../SECURITY.md) describes the supported proof layers and known limitations.

## Interpretation

A successful offline verification means the disclosed values recompute the included commitments and the included local key signed the linked roots. It does not prove the official Goalong release produced the data, the model provider authored a recap, the computer clock was truthful, one human operated the device or the observed activity represented productive attention.

## Key handling

Goalong prefers a Secure Enclave-backed P-256 key and uses Keychain fallbacks where necessary. Development/ad-hoc identity and key rotation are surfaced as lower or changed trust states. Any future external witness, App Attest statement or provider receipt must remain an independently verified layer rather than being inferred from a local signature.
