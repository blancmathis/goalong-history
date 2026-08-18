"""App Attest verification boundary.

The macOS client can attach App Attest attestation/assertion blobs, but this reference
server deliberately does NOT pretend they are valid without a production verifier.
Wire your production Apple App Attest verifier here and return True only after checking:
- Apple certificate chain / attestation format
- expected Team ID + bundle identifier
- clientDataHash / challenge binding
- assertion counter monotonicity
- supported macOS integrity properties your policy requires

Failing closed is intentional: cryptographic anchors still work, but the receipt reports
appAttestAccepted=false until this function is replaced by a real verifier.
"""

from __future__ import annotations


def verify_registration(*, key_id: str | None, attestation_object_b64: str | None, client_data_hash: bytes) -> bool:
    return False


def verify_assertion(*, key_id: str | None, assertion_b64: str | None, client_data_hash: bytes, device_id: str) -> bool:
    return False
