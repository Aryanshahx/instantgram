"""Offline tests: Telegram is replaced by an in-memory fake."""
import asyncio
import datetime
import os
import random
import sys
import time
from contextlib import asynccontextmanager
from pathlib import Path

import httpx
import jwt
import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import app as srv  # noqa: E402

PROJECT = "demo-project"
SECRET = "unit-test-secret"


# ------------------------------------------------------------------ fakes
class FakeDoc:
    def __init__(self, data: bytes, mime: str):
        self.data, self.size, self.mime_type = data, len(data), mime


class FakeMsg:
    def __init__(self, id, doc, caption, thumb=b""):
        self.id, self.document, self.message, self.thumb = id, doc, caption, thumb


class FakeIter:
    def __init__(self, data, offset, request_size):
        assert offset % srv.CHUNK == 0 and request_size == srv.CHUNK
        self.data, self.pos, self.rs, self.closed = data, offset, request_size, False

    def __aiter__(self):
        return self

    async def __anext__(self):
        if self.pos >= len(self.data) or self.closed:
            raise StopAsyncIteration
        part = self.data[self.pos : self.pos + self.rs]
        self.pos += self.rs
        return part

    async def close(self):
        self.closed = True


class FakeClient:
    def iter_download(self, document, *, offset, request_size, chunk_size, file_size):
        return FakeIter(document.data, offset, request_size)


class FakeStore:
    def __init__(self):
        self.client = FakeClient()
        self.msgs = {}
        self.next = 100
        self.sent = []

    async def message(self, i):
        return self.msgs.get(i)

    async def thumb(self, i):
        m = self.msgs.get(i)
        return (m.thumb or None) if m else None

    async def send(self, path, caption, kind, duration, w, h, thumb_path):
        self.next += 1
        data = Path(path).read_bytes()
        self.sent.append((kind, duration, w, h, bool(thumb_path)))
        mime = "video/mp4" if kind == "video" else "image/jpeg"
        thumb = Path(thumb_path).read_bytes() if thumb_path else b""
        self.msgs[self.next] = FakeMsg(self.next, FakeDoc(data, mime), caption, thumb)
        return self.msgs[self.next]

    async def delete(self, i):
        self.msgs.pop(i, None)


# --------------------------------------------------------------- crypto
def make_cert():
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "test")])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (
        x509.CertificateBuilder().subject_name(name).issuer_name(name)
        .public_key(key.public_key()).serial_number(1)
        .not_valid_before(now - datetime.timedelta(days=1))
        .not_valid_after(now + datetime.timedelta(days=30))
        .sign(key, hashes.SHA256())
    )
    pem = cert.public_bytes(serialization.Encoding.PEM).decode()
    return key, pem


KEY, PEM = make_cert()


def token(uid="user1", **over):
    now = int(time.time())
    claims = {"iss": f"https://securetoken.google.com/{PROJECT}", "aud": PROJECT,
              "sub": uid, "iat": now - 5, "exp": now + 3600}
    claims.update(over)
    return jwt.encode(claims, KEY, algorithm="RS256", headers={"kid": "k1"})


@pytest.fixture(autouse=True)
def wired(monkeypatch):
    monkeypatch.setattr(srv.settings, "secret", SECRET)
    monkeypatch.setattr(srv.settings, "project", PROJECT)
    monkeypatch.setattr(srv.settings, "max_video", 5 * 1024 * 1024)
    monkeypatch.setattr(srv.settings, "max_image", 1024 * 1024)

    async def fake_certs():
        return {"k1": PEM}

    monkeypatch.setattr(srv, "get_certs", fake_certs)
    fake = FakeStore()
    monkeypatch.setattr(srv, "store", fake)
    monkeypatch.setattr(srv, "limiter", srv.RateLimiter(3))
    monkeypatch.setattr(srv.shutil, "which", lambda _n: None)  # no ffmpeg in tests
    return fake


def client():
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=srv.app), base_url="http://t")


def arun(coro):
    return asyncio.run(coro)


MP4 = b"\x00\x00\x00\x18ftypmp42" + os.urandom(1_300_000)
JPG = b"\xff\xd8\xff\xe0" + os.urandom(5000)


# ------------------------------------------------------------------ tests
def test_parse_range():
    p = srv.parse_range
    assert p(None, 100) is None
    assert p("bytes=0-", 100) == (0, 99)
    assert p("bytes=10-19", 100) == (10, 19)
    assert p("bytes=90-500", 100) == (90, 99)
    assert p("bytes=-10", 100) == (90, 99)
    assert p("bytes=0-1,5-9", 100) is None
    with pytest.raises(srv.RangeError):
        p("bytes=100-", 100)
    with pytest.raises(srv.RangeError):
        p("bytes=50-10", 100)


def test_handles_are_signed():
    h = srv.sign_handle(123, SECRET)
    assert srv.parse_handle(h, SECRET) == 123
    assert srv.parse_handle(h, "other") is None
    assert srv.parse_handle("124-" + h.split("-", 1)[1], SECRET) is None
    assert srv.parse_handle("../etc/passwd", SECRET) is None


def test_iter_range_is_byte_exact():
    data = os.urandom(srv.CHUNK * 2 + 12345)
    doc = FakeDoc(data, "video/mp4")
    rnd = random.Random(1)
    cases = [(0, len(data) - 1), (0, 0), (len(data) - 1, len(data) - 1),
             (srv.CHUNK - 1, srv.CHUNK), (srv.CHUNK, srv.CHUNK * 2 - 1)]
    cases += [tuple(sorted((rnd.randrange(len(data)), rnd.randrange(len(data))))) for _ in range(40)]

    async def go():
        for s, e in cases:
            got = b"".join([c async for c in srv.iter_range(FakeClient(), doc, s, e)])
            assert got == data[s : e + 1], (s, e)

    arun(go())


def test_token_verification():
    async def go():
        assert await srv.verify_firebase_token(token("abc"), PROJECT) == "abc"
        for bad in (token(exp=int(time.time()) - 600), token(aud="other"),
                    token(iss="https://evil"), token(sub=""), "garbage"):
            with pytest.raises(srv.AuthError):
                await srv.verify_firebase_token(bad, PROJECT)
        # signed with a different key
        other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        forged = jwt.encode({"iss": f"https://securetoken.google.com/{PROJECT}", "aud": PROJECT,
                             "sub": "x", "iat": int(time.time()), "exp": int(time.time()) + 99},
                            other, algorithm="RS256", headers={"kid": "k1"})
        with pytest.raises(srv.AuthError):
            await srv.verify_firebase_token(forged, PROJECT)
        # alg=none / HS256 confusion
        with pytest.raises(srv.AuthError):
            await srv.verify_firebase_token(jwt.encode({"sub": "x"}, "k", algorithm="HS256", headers={"kid": "k1"}), PROJECT)

    arun(go())


def upload(c, who="user1", kind="video", data=MP4, thumb=True, tok=None):
    files = {"file": ("x.mp4", data)}
    if thumb:
        files["thumb"] = ("t.jpg", JPG)
    return c.post("/upload", files=files,
                  data={"kind": kind, "duration": "12", "width": "720", "height": "1280"},
                  headers={"Authorization": "Bearer " + (tok or token(who))})


def test_upload_stream_thumb_delete(wired):
    async def go():
        async with client() as c:
            r = await upload(c)
            assert r.status_code == 200, r.text
            handle = r.json()["handle"]
            assert r.json()["thumb"] is True
            assert wired.sent[-1] == ("video", 12, 720, 1280, True)

            full = await c.get(f"/m/{handle}")
            assert full.status_code == 200 and full.content == MP4
            assert full.headers["accept-ranges"] == "bytes"
            assert full.headers["content-type"].startswith("video/mp4")

            part = await c.get(f"/m/{handle}", headers={"Range": "bytes=600000-700000"})
            assert part.status_code == 206 and part.content == MP4[600000:700001]
            assert part.headers["content-range"] == f"bytes 600000-700000/{len(MP4)}"

            open_end = await c.get(f"/m/{handle}", headers={"Range": f"bytes={len(MP4)-100}-"})
            assert open_end.content == MP4[-100:]

            bad = await c.get(f"/m/{handle}", headers={"Range": f"bytes={len(MP4)+5}-"})
            assert bad.status_code == 416

            head = await c.head(f"/m/{handle}")
            assert head.status_code == 200 and head.headers["content-length"] == str(len(MP4))

            t = await c.get(f"/t/{handle}")
            assert t.status_code == 200 and t.content == JPG

            assert (await c.get("/m/101-AAAAAAAAAAAAAAAA")).status_code == 404  # forged
            assert (await c.get("/m/1")).status_code == 404

            other = await c.delete(f"/m/{handle}", headers={"Authorization": "Bearer " + token("someone-else")})
            assert other.status_code == 403
            noauth = await c.delete(f"/m/{handle}")
            assert noauth.status_code == 401
            ok = await c.delete(f"/m/{handle}", headers={"Authorization": "Bearer " + token("user1")})
            assert ok.status_code == 204
            assert (await c.get(f"/m/{handle}")).status_code == 404

    arun(go())


def test_upload_rejections():
    async def go():
        async with client() as c:
            assert (await c.post("/upload", files={"file": ("x", MP4)}, data={"kind": "video"})).status_code == 401
            r = await upload(c, tok="nonsense")
            assert r.status_code == 401
            r = await upload(c, data=b"not a video at all, just text")
            assert r.status_code == 400
            r = await upload(c, kind="image", data=JPG * 300)  # > 1 MB image limit
            assert r.status_code == 413
            r = await upload(c, kind="image", data=JPG, thumb=False)
            assert r.status_code == 200
            r = await upload(c, kind="doc")
            assert r.status_code == 400
            srv.limiter = srv.RateLimiter(3)  # attempts count, even rejected ones
            for _ in range(3):
                assert (await upload(c, thumb=False)).status_code == 200
            assert (await upload(c, thumb=False)).status_code == 429
            r = await c.get("/health")
            assert r.json()["ok"] is True

    arun(go())


def test_rate_limiter_window():
    rl = srv.RateLimiter(2)
    assert rl.allow("a", 0) and rl.allow("a", 1) and not rl.allow("a", 2)
    assert rl.allow("a", 4000)
    assert rl.allow("b", 2)
