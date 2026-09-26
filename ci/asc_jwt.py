"""An App Store Connect API token (ES256 JWT) signed with the system's openssl.

No third-party package: the job that holds the App Store Connect key installs
nothing it would have to trust (independent audit 2026-09-26, M3 — it used
to `pip install pyjwt cryptography` unpinned).
"""
import base64, json, os, subprocess, tempfile, time


def _b64(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def _der_to_raw(der: bytes) -> bytes:
    # ECDSA-Sig-Value ::= SEQUENCE { r INTEGER, s INTEGER } → r || s, 32 bytes each.
    assert der[0] == 0x30
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    out = b""
    for _ in range(2):
        assert der[i] == 0x02
        n = der[i + 1]
        v = der[i + 2 : i + 2 + n].lstrip(b"\x00")
        out += v.rjust(32, b"\x00")
        i += 2 + n
    return out


def token(claims: dict, key_pem: str, key_id: str) -> str:
    head = _b64(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}, separators=(",", ":")).encode())
    body = _b64(json.dumps(claims, separators=(",", ":")).encode())
    signing_input = f"{head}.{body}".encode()
    with tempfile.NamedTemporaryFile("w", delete=False, dir=os.environ.get("RUNNER_TEMP")) as f:
        os.chmod(f.name, 0o600)
        f.write(key_pem.strip() + "\n")
        path = f.name
    try:
        der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", path], input=signing_input, capture_output=True, check=True).stdout
    finally:
        os.unlink(path)
    return f"{head}.{body}.{_b64(_der_to_raw(der))}"


def team_token(key_pem: str, key_id: str, issuer: str) -> str:
    now = int(time.time())
    return token({"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}, key_pem, key_id)
