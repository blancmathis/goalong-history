from __future__ import annotations

import base64
import hashlib
import json
import os
import secrets
import sqlite3
import struct
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

from app_attest import verify_assertion, verify_registration

DB_PATH = Path(os.environ.get("LOCALHISTORY_DB", Path(__file__).with_name("localhistory.sqlite3")))
CHALLENGE_TTL_SECONDS = 120
ZERO_HASH = "0" * 64

app = FastAPI(title="LocalHistory verification reference server", version="0.3.2")


def db() -> sqlite3.Connection:
    connection = sqlite3.connect(DB_PATH)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("PRAGMA foreign_keys=ON")
    return connection


def init_db() -> None:
    with db() as con:
        con.executescript(
            """
            CREATE TABLE IF NOT EXISTS devices (
                device_id TEXT PRIMARY KEY,
                public_key_b64 TEXT NOT NULL,
                signature_algorithm TEXT NOT NULL,
                local_trust_tier TEXT NOT NULL,
                app_version TEXT NOT NULL,
                app_attest_key_id TEXT,
                app_attest_registered INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS challenges (
                challenge_id TEXT PRIMARY KEY,
                device_id TEXT NOT NULL,
                challenge_b64 TEXT NOT NULL,
                created_at REAL NOT NULL,
                expires_at REAL NOT NULL,
                used INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS anchors (
                device_id TEXT NOT NULL,
                anchor_sequence INTEGER NOT NULL,
                minute_root TEXT NOT NULL,
                previous_anchor_hash TEXT NOT NULL,
                anchor_hash TEXT NOT NULL,
                signature_b64 TEXT NOT NULL,
                app_version TEXT NOT NULL,
                app_attest_accepted INTEGER NOT NULL DEFAULT 0,
                received_at REAL NOT NULL,
                receipt_id TEXT NOT NULL,
                PRIMARY KEY (device_id, anchor_sequence),
                UNIQUE (receipt_id),
                FOREIGN KEY (device_id) REFERENCES devices(device_id)
            );
            """
        )


init_db()


class ChallengeRequest(BaseModel):
    deviceID: str


class ChallengeResponse(BaseModel):
    challengeID: str
    challengeBase64: str


class DeviceRegistrationRequest(BaseModel):
    challengeID: str
    deviceID: str
    publicKeyBase64: str
    signatureAlgorithm: str
    localTrustTier: str
    appVersion: str
    appAttestKeyID: str | None = None
    appAttestationObjectBase64: str | None = None


class AnchorUploadRequest(BaseModel):
    deviceID: str
    anchorSequence: int
    minuteRoot: str
    previousAnchorHash: str
    anchorHash: str
    signatureBase64: str
    signatureAlgorithm: str
    appVersion: str
    challengeID: str
    appAttestKeyID: str | None = None
    appAttestAssertionBase64: str | None = None


class AnchorReceiptResponse(BaseModel):
    schemaVersion: int = 1
    deviceID: str
    anchorSequence: int
    anchorHash: str
    receiptID: str
    receivedAt: datetime
    appAttestAccepted: bool
    serverSignature: str | None = None


class SimpleOK(BaseModel):
    ok: bool


def sha256(data: bytes) -> bytes:
    return hashlib.sha256(data).digest()


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical_fields(fields: dict[str, str]) -> bytes:
    out = bytearray(b"LH-CANONICAL-MAP-V1\n")
    for key in sorted(fields):
        for value in (key, fields[key]):
            encoded = value.encode("utf-8")
            out.extend(struct.pack(">Q", len(encoded)))
            out.extend(encoded)
    return bytes(out)


def commitment_hex(opening: dict[str, Any]) -> str:
    try:
        salt = base64.b64decode(opening["saltBase64"], validate=True)
        domain = opening["domain"]
        fields = {str(k): str(v) for k, v in opening["fields"].items()}
    except Exception as exc:
        raise ValueError(f"bad opening: {exc}") from exc
    material = b"LH-COMMITMENT-V1\0" + domain.encode() + b"\0" + canonical_fields(fields) + b"\0" + salt
    return sha256_hex(material)


def merkle_leaf(label: str, value_hex: str) -> str:
    return sha256_hex(f"LH-MERKLE-LEAF-V1\0{label}\0{value_hex}".encode())


def merkle_node(left: str, right: str) -> str:
    return sha256_hex(f"LH-MERKLE-NODE-V1\0{left}\0{right}".encode())


def merkle_root(items: list[tuple[str, str]]) -> str:
    if not items:
        return sha256_hex(b"LH-MERKLE-EMPTY-V1")
    level = [merkle_leaf(label, value) for label, value in items]
    while len(level) > 1:
        nxt: list[str] = []
        for i in range(0, len(level), 2):
            left = level[i]
            right = level[i + 1] if i + 1 < len(level) else left
            nxt.append(merkle_node(left, right))
        level = nxt
    return level[0]


EVENT_FIELD_ORDER = ["time", "application", "context", "activity", "classification", "coverage", "trust", "raw_digest"]
MINUTE_FIELD_ORDER = ["time", "events_root", "event_count", "coverage"]


def anchor_hash(sequence: int, previous: str, minute_root: str) -> str:
    return sha256_hex(f"LH-ANCHOR-CHAIN-V1\0{sequence}\0{previous}\0{minute_root}".encode())


def signing_message(device_id: str, sequence: int, previous: str, minute_root: str) -> bytes:
    return f"LH-ANCHOR-SIGNATURE-V1\0{device_id}\0{sequence}\0{previous}\0{minute_root}".encode()


def consume_challenge(con: sqlite3.Connection, challenge_id: str, device_id: str) -> bytes:
    row = con.execute(
        "SELECT * FROM challenges WHERE challenge_id=? AND device_id=?",
        (challenge_id, device_id),
    ).fetchone()
    now = time.time()
    if not row or row["used"] or row["expires_at"] < now:
        raise HTTPException(400, "invalid, expired, or reused challenge")
    con.execute("UPDATE challenges SET used=1 WHERE challenge_id=?", (challenge_id,))
    return base64.b64decode(row["challenge_b64"])


@app.post("/v1/challenge", response_model=ChallengeResponse)
def issue_challenge(request: ChallengeRequest) -> ChallengeResponse:
    challenge_id = str(uuid.uuid4())
    value = secrets.token_bytes(32)
    now = time.time()
    with db() as con:
        con.execute(
            "INSERT INTO challenges(challenge_id,device_id,challenge_b64,created_at,expires_at,used) VALUES(?,?,?,?,?,0)",
            (challenge_id, request.deviceID, base64.b64encode(value).decode(), now, now + CHALLENGE_TTL_SECONDS),
        )
    return ChallengeResponse(challengeID=challenge_id, challengeBase64=base64.b64encode(value).decode())


@app.post("/v1/devices/register", response_model=SimpleOK)
def register_device(request: DeviceRegistrationRequest) -> SimpleOK:
    try:
        public_bytes = base64.b64decode(request.publicKeyBase64, validate=True)
    except Exception:
        raise HTTPException(400, "invalid public key")
    if sha256_hex(public_bytes) != request.deviceID:
        raise HTTPException(400, "device ID does not match public key")
    try:
        ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), public_bytes)
    except ValueError:
        raise HTTPException(400, "public key is not a P-256 encoded point")

    with db() as con:
        challenge = consume_challenge(con, request.challengeID, request.deviceID)
        client_hash = sha256(
            b"LH-APP-ATTEST-REGISTER-V1\0"
            + base64.b64encode(challenge)
            + b"\0"
            + request.deviceID.encode()
            + b"\0"
            + request.publicKeyBase64.encode()
        )
        attest_ok = verify_registration(
            key_id=request.appAttestKeyID,
            attestation_object_b64=request.appAttestationObjectBase64,
            client_data_hash=client_hash,
        )
        existing = con.execute("SELECT * FROM devices WHERE device_id=?", (request.deviceID,)).fetchone()
        if existing and existing["public_key_b64"] != request.publicKeyBase64:
            raise HTTPException(409, "device ID already registered with another key")
        con.execute(
            """
            INSERT INTO devices(device_id,public_key_b64,signature_algorithm,local_trust_tier,app_version,app_attest_key_id,app_attest_registered,created_at)
            VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(device_id) DO UPDATE SET
              app_version=excluded.app_version,
              app_attest_key_id=COALESCE(excluded.app_attest_key_id,devices.app_attest_key_id),
              app_attest_registered=MAX(devices.app_attest_registered,excluded.app_attest_registered)
            """,
            (
                request.deviceID,
                request.publicKeyBase64,
                request.signatureAlgorithm,
                request.localTrustTier,
                request.appVersion,
                request.appAttestKeyID,
                1 if attest_ok else 0,
                time.time(),
            ),
        )
    return SimpleOK(ok=True)


@app.post("/v1/anchors", response_model=AnchorReceiptResponse)
def upload_anchor(request: AnchorUploadRequest) -> AnchorReceiptResponse:
    if request.anchorSequence < 1:
        raise HTTPException(400, "anchor sequence must be positive")
    expected_hash = anchor_hash(request.anchorSequence, request.previousAnchorHash, request.minuteRoot)
    if expected_hash != request.anchorHash:
        raise HTTPException(400, "anchor hash mismatch")

    with db() as con:
        device = con.execute("SELECT * FROM devices WHERE device_id=?", (request.deviceID,)).fetchone()
        if not device:
            raise HTTPException(404, "unknown device")

        # Idempotent retry support.
        existing = con.execute(
            "SELECT * FROM anchors WHERE device_id=? AND anchor_sequence=?",
            (request.deviceID, request.anchorSequence),
        ).fetchone()
        if existing:
            if existing["anchor_hash"] != request.anchorHash:
                raise HTTPException(409, "sequence already committed to another anchor")
            return AnchorReceiptResponse(
                deviceID=request.deviceID,
                anchorSequence=request.anchorSequence,
                anchorHash=request.anchorHash,
                receiptID=existing["receipt_id"],
                receivedAt=datetime.fromtimestamp(existing["received_at"], timezone.utc),
                appAttestAccepted=bool(existing["app_attest_accepted"]),
            )

        challenge = consume_challenge(con, request.challengeID, request.deviceID)

        last = con.execute(
            "SELECT * FROM anchors WHERE device_id=? ORDER BY anchor_sequence DESC LIMIT 1",
            (request.deviceID,),
        ).fetchone()
        if last:
            if request.anchorSequence != last["anchor_sequence"] + 1:
                raise HTTPException(409, "non-contiguous anchor sequence")
            if request.previousAnchorHash != last["anchor_hash"]:
                raise HTTPException(409, "previous anchor hash mismatch")
        else:
            if request.anchorSequence != 1 or request.previousAnchorHash != ZERO_HASH:
                raise HTTPException(409, "first anchor must start at sequence 1")

        public_bytes = base64.b64decode(device["public_key_b64"])
        public_key = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), public_bytes)
        try:
            public_key.verify(
                base64.b64decode(request.signatureBase64, validate=True),
                signing_message(request.deviceID, request.anchorSequence, request.previousAnchorHash, request.minuteRoot),
                ec.ECDSA(hashes.SHA256()),
            )
        except (InvalidSignature, ValueError):
            raise HTTPException(400, "invalid device signature")

        client_hash = sha256(
            b"LH-APP-ATTEST-ANCHOR-V1\0"
            + base64.b64encode(challenge)
            + b"\0"
            + request.anchorHash.encode()
            + b"\0"
            + str(request.anchorSequence).encode()
        )
        attest_ok = verify_assertion(
            key_id=request.appAttestKeyID,
            assertion_b64=request.appAttestAssertionBase64,
            client_data_hash=client_hash,
            device_id=request.deviceID,
        )

        received = time.time()
        receipt_id = str(uuid.uuid4())
        con.execute(
            """
            INSERT INTO anchors(device_id,anchor_sequence,minute_root,previous_anchor_hash,anchor_hash,signature_b64,app_version,app_attest_accepted,received_at,receipt_id)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            """,
            (
                request.deviceID,
                request.anchorSequence,
                request.minuteRoot,
                request.previousAnchorHash,
                request.anchorHash,
                request.signatureBase64,
                request.appVersion,
                1 if attest_ok else 0,
                received,
                receipt_id,
            ),
        )

    return AnchorReceiptResponse(
        deviceID=request.deviceID,
        anchorSequence=request.anchorSequence,
        anchorHash=request.anchorHash,
        receiptID=receipt_id,
        receivedAt=datetime.fromtimestamp(received, timezone.utc),
        appAttestAccepted=attest_ok,
    )


def verify_field_list(fields: list[dict[str, Any]], order: list[str]) -> tuple[bool, dict[str, dict[str, Any]]]:
    by_name = {item.get("name"): item for item in fields}
    if set(by_name) != set(order):
        return False, {}
    for item in fields:
        opening = item.get("opening")
        if opening is not None and commitment_hex(opening) != item.get("commitmentHex"):
            return False, {}
    return True, by_name


def opening_fields(item: dict[str, Any]) -> dict[str, str] | None:
    opening = item.get("opening")
    if opening is None:
        return None
    return {str(k): str(v) for k, v in opening.get("fields", {}).items()}


@app.post("/v1/share/verify")
def verify_share(package: dict[str, Any]) -> dict[str, Any]:
    device_id = package.get("deviceID")
    local_day = package.get("localDay")
    minutes = package.get("minutes")
    if not isinstance(device_id, str) or not isinstance(local_day, str) or not isinstance(minutes, list) or not minutes:
        raise HTTPException(400, "invalid share package")

    sequences: list[int] = []
    disclosure_counts = {"everything": 0, "applicationOnly": 0, "categoryOnly": 0, "privateOnly": 0}
    app_attest_count = 0

    with db() as con:
        for minute in minutes:
            sequence = int(minute["anchorSequence"])
            sequences.append(sequence)
            if minute.get("deviceID") != device_id:
                raise HTTPException(400, f"device mismatch in sequence {sequence}")

            anchor = con.execute(
                "SELECT * FROM anchors WHERE device_id=? AND anchor_sequence=?",
                (device_id, sequence),
            ).fetchone()
            if not anchor:
                raise HTTPException(409, f"anchor {sequence} was never received live by this server")
            for key, db_key in [
                ("minuteRoot", "minute_root"),
                ("previousAnchorHash", "previous_anchor_hash"),
                ("anchorHash", "anchor_hash"),
            ]:
                if minute.get(key) != anchor[db_key]:
                    raise HTTPException(400, f"anchored value mismatch at sequence {sequence}")
            if bool(anchor["app_attest_accepted"]):
                app_attest_count += 1

            fields_ok, minute_by_name = verify_field_list(minute.get("minuteFields", []), MINUTE_FIELD_ORDER)
            if not fields_ok:
                raise HTTPException(400, f"bad minute commitments at sequence {sequence}")
            calculated_root = merkle_root([(name, minute_by_name[name]["commitmentHex"]) for name in MINUTE_FIELD_ORDER])
            if calculated_root != minute["minuteRoot"]:
                raise HTTPException(400, f"minute root mismatch at sequence {sequence}")
            if anchor_hash(sequence, minute["previousAnchorHash"], minute["minuteRoot"]) != minute["anchorHash"]:
                raise HTTPException(400, f"anchor-chain mismatch at sequence {sequence}")

            # Time and coverage are always disclosed; they do not reveal the private activity itself.
            for always in ("time", "coverage"):
                if minute_by_name[always].get("opening") is None:
                    raise HTTPException(400, f"{always} must be disclosed at sequence {sequence}")
            time_fields = opening_fields(minute_by_name["time"])
            if not time_fields or time_fields.get("local_day") != local_day:
                raise HTTPException(400, f"minute {sequence} is not committed to local day {local_day}")

            level = minute.get("shareLevel")
            if level not in disclosure_counts:
                raise HTTPException(400, f"unknown share level at sequence {sequence}")
            disclosure_counts[level] += 1

            event_roots = minute.get("eventRoots")
            events = minute.get("events")
            if level == "privateOnly":
                if event_roots is not None or events is not None:
                    raise HTTPException(400, f"private minute leaked event structure at sequence {sequence}")
                if minute_by_name["events_root"].get("opening") is not None or minute_by_name["event_count"].get("opening") is not None:
                    raise HTTPException(400, f"private minute opened hidden event commitments at sequence {sequence}")
                continue

            if not isinstance(event_roots, list) or not isinstance(events, list) or len(event_roots) != len(events):
                raise HTTPException(400, f"missing event list at sequence {sequence}")
            events_root = merkle_root([(f"event:{i}", root) for i, root in enumerate(event_roots)])
            root_fields = opening_fields(minute_by_name["events_root"])
            count_fields = opening_fields(minute_by_name["event_count"])
            if not root_fields or root_fields.get("events_root") != events_root:
                raise HTTPException(400, f"events-root opening mismatch at sequence {sequence}")
            if not count_fields or count_fields.get("count") != str(len(event_roots)):
                raise HTTPException(400, f"event-count opening mismatch at sequence {sequence}")

            for root, event in zip(event_roots, events):
                if event.get("eventRoot") != root:
                    raise HTTPException(400, f"event root list mismatch at sequence {sequence}")
                ok, event_by_name = verify_field_list(event.get("fieldCommitments", []), EVENT_FIELD_ORDER)
                if not ok:
                    raise HTTPException(400, f"bad event field commitment at sequence {sequence}")
                calculated_event_root = merkle_root([(name, event_by_name[name]["commitmentHex"]) for name in EVENT_FIELD_ORDER])
                if calculated_event_root != root:
                    raise HTTPException(400, f"event root mismatch at sequence {sequence}")

                opened = {name for name, item in event_by_name.items() if item.get("opening") is not None}
                required_common = {"time", "coverage", "trust"}
                if not required_common.issubset(opened):
                    raise HTTPException(400, f"required verification fields hidden at sequence {sequence}")
                if level == "applicationOnly":
                    if "application" not in opened or opened.intersection({"context", "activity", "classification", "raw_digest"}):
                        raise HTTPException(400, f"application-only disclosure policy violated at sequence {sequence}")
                elif level == "categoryOnly":
                    if "classification" not in opened or opened.intersection({"application", "context", "activity", "raw_digest"}):
                        raise HTTPException(400, f"category-only disclosure policy violated at sequence {sequence}")
                elif level == "everything":
                    if set(EVENT_FIELD_ORDER) != opened:
                        raise HTTPException(400, f"everything disclosure is incomplete at sequence {sequence}")

        if sequences != sorted(sequences) or len(sequences) != len(set(sequences)):
            raise HTTPException(400, "share sequences must be unique and ordered")
        if any(b != a + 1 for a, b in zip(sequences, sequences[1:])):
            raise HTTPException(409, "share package omitted one or more anchors inside its disclosed range")

        def verify_boundary(boundary: dict[str, Any] | None, expected_sequence: int, relation: str) -> bool:
            if boundary is None:
                return False
            sequence = int(boundary.get("anchorSequence", -1))
            if sequence != expected_sequence or boundary.get("deviceID") != device_id:
                raise HTTPException(409, f"invalid {relation} day-boundary sequence")
            anchor = con.execute(
                "SELECT * FROM anchors WHERE device_id=? AND anchor_sequence=?",
                (device_id, sequence),
            ).fetchone()
            if not anchor:
                raise HTTPException(409, f"{relation} boundary anchor was never received live")
            if boundary.get("minuteRoot") != anchor["minute_root"] or boundary.get("anchorHash") != anchor["anchor_hash"] or boundary.get("previousAnchorHash") != anchor["previous_anchor_hash"]:
                raise HTTPException(400, f"{relation} boundary does not match the live anchor")
            ok, by_name = verify_field_list(boundary.get("minuteFields", []), MINUTE_FIELD_ORDER)
            if not ok:
                raise HTTPException(400, f"bad {relation} boundary commitments")
            root = merkle_root([(name, by_name[name]["commitmentHex"]) for name in MINUTE_FIELD_ORDER])
            if root != boundary.get("minuteRoot"):
                raise HTTPException(400, f"bad {relation} boundary root")
            if boundary.get("shareLevel") != "privateOnly" or boundary.get("eventRoots") is not None or boundary.get("events") is not None:
                raise HTTPException(400, f"{relation} boundary must be private-only")
            if by_name["time"].get("opening") is None or by_name["coverage"].get("opening") is None:
                raise HTTPException(400, f"{relation} boundary must reveal time and coverage")
            if by_name["events_root"].get("opening") is not None or by_name["event_count"].get("opening") is not None:
                raise HTTPException(400, f"{relation} boundary leaked event structure")
            time_fields = opening_fields(by_name["time"])
            boundary_day = time_fields.get("local_day") if time_fields else None
            if not boundary_day or boundary_day == local_day:
                raise HTTPException(409, f"{relation} boundary is still inside the shared local day")
            return True

        before_ok = False
        if min(sequences) == 1:
            before_ok = package.get("boundaryBefore") is None
        else:
            before_ok = verify_boundary(package.get("boundaryBefore"), min(sequences) - 1, "before")
        after_ok = verify_boundary(package.get("boundaryAfter"), max(sequences) + 1, "after") if package.get("boundaryAfter") is not None else False
        calendar_day_complete = before_ok and after_ok

    return {
        "verified": True,
        "calendarDayComplete": calendar_day_complete,
        "deviceID": device_id,
        "localDay": local_day,
        "anchorFrom": min(sequences),
        "anchorTo": max(sequences),
        "minutes": len(minutes),
        "disclosureCounts": disclosure_counts,
        "appAttestAcceptedMinutes": app_attest_count,
        "appAttestCoverage": app_attest_count / len(minutes),
        "note": "verified=true means the disclosed range matches live anchors. calendarDayComplete=true additionally requires adjacent boundary proofs (or sequence genesis before the day).",
    }
