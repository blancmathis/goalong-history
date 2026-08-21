# Goalong History reference verification server

This is a development/reference backend for the v0.3 anti-tamper protocol.

## Run locally

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app:app --host 127.0.0.1 --port 8787
```

Then set in Goalong History's `config.json`:

```json
{
  "verificationEnabled": true,
  "verificationServerURL": "http://127.0.0.1:8787"
}
```

`http://` is accepted by the client only for localhost. Real deployments must use HTTPS.

## Privacy boundary

The live anchor endpoint receives only:

- pseudonymous device ID (SHA-256 of its public key)
- monotonically increasing anchor sequence
- opaque minute Merkle root
- previous opaque anchor hash / current anchor hash
- P-256 signature
- app version
- one-time challenge identifier
- optional App Attest assertion/key identifier

It does **not** receive app names, window titles, URLs, clicks, keyboard activity, event roots, event counts, or local timestamps during live capture.

## App Attest

`app_attest.py` fails closed and returns `False` until a production Apple App Attest verifier is wired in. Do not advertise App Attest-verified status until that verifier is implemented and tested with your Apple Team ID / bundle ID / production signing setup.

The rest of the server still validates the P-256 device signature, anchor hash chain, anti-replay challenges, continuity, commitments, Merkle roots, and selective-disclosure packages.
