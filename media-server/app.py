"""Instantgram media server.

Stores user videos and images in a PRIVATE Telegram channel (through MTProto, so
the 20 MB Bot-API limit does not apply) and streams them back to the app with
HTTP Range support, so the Flutter app can use its own native video player.

    POST   /upload        (Firebase login required)  -> {"handle": "...", "thumb": true}
    GET    /m/{handle}    media, supports Range (public, handle is HMAC-signed)
    GET    /t/{handle}    video thumbnail (jpeg)
    DELETE /m/{handle}    (Firebase login required, owner only)
    GET    /health

Run:   uvicorn app:app --host 127.0.0.1 --port 8000
Check: python app.py check
"""
from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import logging
import os
import re
import shutil
import sys
import tempfile
import time
from collections import OrderedDict
from contextlib import asynccontextmanager
from pathlib import Path
from typing import AsyncIterator, Optional, Tuple

log = logging.getLogger("media")
HERE = Path(__file__).resolve().parent


# --------------------------------------------------------------------- config
def load_env(path: Path = HERE / ".env") -> None:
    """Tiny .env loader (systemd also passes the same file)."""
    if not path.exists():
        return
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


load_env()


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


CHUNK = 512 * 1024  # download chunk; offset must be a multiple of this
SESSION = str(HERE / "media")


class Settings:
    def __init__(self) -> None:
        self.api_id = int(env("API_ID", "0") or 0)
        self.api_hash = env("API_HASH")
        self.bot_token = env("BOT_TOKEN")
        self.channel_id = int(env("CHANNEL_ID", "0") or 0)
        self.project = env("FIREBASE_PROJECT_ID")
        self.secret = env("SIGNING_SECRET")
        self.max_video = int(env("MAX_VIDEO_MB", "120")) * 1024 * 1024
        self.max_image = int(env("MAX_IMAGE_MB", "15")) * 1024 * 1024
        self.uploads_per_hour = int(env("UPLOADS_PER_HOUR", "40"))

    def missing(self) -> list[str]:
        need = {
            "API_ID": self.api_id,
            "API_HASH": self.api_hash,
            "BOT_TOKEN": self.bot_token,
            "CHANNEL_ID": self.channel_id,
            "FIREBASE_PROJECT_ID": self.project,
            "SIGNING_SECRET": self.secret,
        }
        return [k for k, v in need.items() if not v]


settings = Settings()


# ------------------------------------------------------------- pure helpers
def sign_handle(msg_id: int, secret: str) -> str:
    mac = hmac.new(secret.encode(), f"m{msg_id}".encode(), hashlib.sha256).digest()
    sig = base64.urlsafe_b64encode(mac)[:16].decode()
    return f"{msg_id}-{sig}"


def parse_handle(handle: str, secret: str) -> Optional[int]:
    m = re.fullmatch(r"(\d{1,12})-([A-Za-z0-9_-]{16})", handle or "")
    if not m:
        return None
    msg_id = int(m.group(1))
    expected = sign_handle(msg_id, secret)
    return msg_id if hmac.compare_digest(expected, handle) else None


class RangeError(Exception):
    pass


def parse_range(header: Optional[str], size: int) -> Optional[Tuple[int, int]]:
    """Return inclusive (start, end) for a single byte range, or None for 'whole file'."""
    if not header:
        return None
    m = re.fullmatch(r"\s*bytes\s*=\s*(\d*)\s*-\s*(\d*)\s*", header)
    if not m:  # multi-range or garbage: ignore and serve everything
        return None
    a, b = m.group(1), m.group(2)
    if a == "" and b == "":
        return None
    if a == "":  # suffix: last N bytes
        n = int(b)
        if n == 0:
            raise RangeError()
        start = max(0, size - n)
        end = size - 1
    else:
        start = int(a)
        end = int(b) if b != "" else size - 1
        end = min(end, size - 1)
    if start >= size or start > end:
        raise RangeError()
    return start, end


def sniff_ok(head: bytes, kind: str) -> bool:
    if kind == "image":
        return head.startswith((b"\xff\xd8\xff", b"\x89PNG", b"GIF8")) or (
            head[:4] == b"RIFF" and head[8:12] == b"WEBP"
        )
    # video: mp4/mov ("ftyp" at byte 4), webm/mkv (EBML)
    return head[4:8] == b"ftyp" or head.startswith(b"\x1a\x45\xdf\xa3")


class RateLimiter:
    def __init__(self, per_hour: int) -> None:
        self.per_hour = per_hour
        self.hits: dict[str, list[float]] = {}

    def allow(self, key: str, now: Optional[float] = None) -> bool:
        now = time.time() if now is None else now
        recent = [t for t in self.hits.get(key, []) if now - t < 3600]
        if len(recent) >= self.per_hour:
            self.hits[key] = recent
            return False
        recent.append(now)
        self.hits[key] = recent
        return True


class TTLCache:
    def __init__(self, size: int, ttl: float) -> None:
        self.size, self.ttl = size, ttl
        self.data: "OrderedDict[object, tuple[float, object]]" = OrderedDict()

    def get(self, key):
        item = self.data.get(key)
        if not item:
            return None
        if time.time() - item[0] > self.ttl:
            self.data.pop(key, None)
            return None
        self.data.move_to_end(key)
        return item[1]

    def put(self, key, value) -> None:
        self.data[key] = (time.time(), value)
        self.data.move_to_end(key)
        while len(self.data) > self.size:
            self.data.popitem(last=False)

    def drop(self, key) -> None:
        self.data.pop(key, None)


async def iter_range(client, document, start: int, end: int) -> AsyncIterator[bytes]:
    """Yield exactly bytes[start..end] of a Telegram document."""
    size = document.size
    aligned = start - (start % CHUNK)
    skip = start - aligned
    remaining = end - start + 1
    it = client.iter_download(
        document, offset=aligned, request_size=CHUNK, chunk_size=CHUNK, file_size=size
    )
    try:
        async for chunk in it:
            chunk = bytes(chunk)
            if skip:
                chunk = chunk[skip:]
                skip = 0
            if len(chunk) > remaining:
                chunk = chunk[:remaining]
            if chunk:
                remaining -= len(chunk)
                yield chunk
            if remaining <= 0:
                break
    finally:
        try:
            await it.close()
        except Exception:  # already closed at EOF
            pass


# ------------------------------------------------------------ firebase auth
CERT_URL = (
    "https://www.googleapis.com/robot/v1/metadata/x509/"
    "securetoken@system.gserviceaccount.com"
)
_certs: dict = {"exp": 0.0, "keys": {}}


async def get_certs() -> dict:
    import httpx

    if time.time() < _certs["exp"] and _certs["keys"]:
        return _certs["keys"]
    async with httpx.AsyncClient(timeout=10) as http:
        r = await http.get(CERT_URL)
        r.raise_for_status()
    ttl = 3600
    m = re.search(r"max-age=(\d+)", r.headers.get("cache-control", ""))
    if m:
        ttl = int(m.group(1))
    _certs["keys"] = r.json()
    _certs["exp"] = time.time() + ttl
    return _certs["keys"]


class AuthError(Exception):
    pass


async def verify_firebase_token(token: str, project: str) -> str:
    """Validate a Firebase ID token and return the user's uid."""
    import jwt
    from cryptography import x509

    try:
        header = jwt.get_unverified_header(token)
        if header.get("alg") != "RS256" or not header.get("kid"):
            raise AuthError("bad token header")
        certs = await get_certs()
        pem = certs.get(header["kid"])
        if not pem:
            raise AuthError("unknown signing key")
        key = x509.load_pem_x509_certificate(pem.encode()).public_key()
        claims = jwt.decode(
            token,
            key,
            algorithms=["RS256"],
            audience=project,
            issuer=f"https://securetoken.google.com/{project}",
            leeway=30,
            options={"require": ["exp", "iat", "sub", "aud", "iss"]},
        )
    except AuthError:
        raise
    except Exception as e:  # jwt errors, network errors
        raise AuthError(str(e)) from e
    sub = claims.get("sub")
    if not isinstance(sub, str) or not sub:
        raise AuthError("no subject")
    return sub


def bearer(header: Optional[str]) -> str:
    if header and header.lower().startswith("bearer "):
        return header[7:].strip()
    raise AuthError("missing bearer token")


# ------------------------------------------------------------------ telegram
class Store:
    """Thin wrapper around the Telethon client + the private channel."""

    def __init__(self, cfg: Settings) -> None:
        from telethon import TelegramClient

        self.cfg = cfg
        self.client = TelegramClient(SESSION, cfg.api_id, cfg.api_hash)
        self.peer = None
        self.messages = TTLCache(256, 600)
        self.thumbs = TTLCache(300, 3600)

    async def start(self) -> None:
        await self.client.start(bot_token=self.cfg.bot_token)
        try:
            self.peer = await self.client.get_input_entity(self.cfg.channel_id)
        except Exception as e:
            raise RuntimeError(
                "The bot cannot see the channel. Add the bot as an ADMIN of the "
                "private channel (permissions: post and delete messages) and check "
                f"CHANNEL_ID ({self.cfg.channel_id}). Details: {e}"
            ) from e

    async def stop(self) -> None:
        await self.client.disconnect()

    async def message(self, msg_id: int):
        cached = self.messages.get(msg_id)
        if cached is not None:
            return cached
        msg = await self.client.get_messages(self.peer, ids=msg_id)
        if not msg or not getattr(msg, "document", None):
            return None
        self.messages.put(msg_id, msg)
        return msg

    async def thumb(self, msg_id: int) -> Optional[bytes]:
        cached = self.thumbs.get(msg_id)
        if cached is not None:
            return cached or None
        msg = await self.message(msg_id)
        if msg is None:
            return None
        data = await self.client.download_media(msg, file=bytes, thumb=-1)
        self.thumbs.put(msg_id, data or b"")
        return data or None

    async def send(
        self, path: str, caption: str, kind: str, duration: int, w: int, h: int,
        thumb_path: Optional[str],
    ):
        from telethon.tl.types import DocumentAttributeVideo

        attrs = []
        if kind == "video":
            attrs = [
                DocumentAttributeVideo(
                    duration=max(0, duration), w=max(0, w), h=max(0, h),
                    supports_streaming=True,
                )
            ]
        return await self.client.send_file(
            self.peer,
            path,
            caption=caption,
            thumb=thumb_path if kind == "video" else None,
            attributes=attrs or None,
            force_document=(kind == "image"),
            supports_streaming=(kind == "video"),
        )

    async def delete(self, msg_id: int) -> None:
        await self.client.delete_messages(self.peer, [msg_id])
        self.messages.drop(msg_id)
        self.thumbs.drop(msg_id)


async def run(*cmd: str, timeout: float = 120) -> bool:
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL
        )
        await asyncio.wait_for(proc.wait(), timeout)
        return proc.returncode == 0
    except Exception:
        return False


async def optimise_video(src: str, thumb: Optional[str]) -> Tuple[str, Optional[str]]:
    """If ffmpeg exists: move the index to the front (fast start) and make a thumbnail."""
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        return src, thumb
    out = src + ".fast.mp4"
    if await run(ffmpeg, "-y", "-i", src, "-c", "copy", "-movflags", "+faststart", out):
        if os.path.getsize(out) > 0:
            os.replace(out, src)
    else:
        Path(out).unlink(missing_ok=True)
    if not thumb:
        t = src + ".thumb.jpg"
        if await run(ffmpeg, "-y", "-ss", "0.3", "-i", src, "-frames:v", "1",
                     "-vf", "scale=480:-2", t, timeout=30) and os.path.exists(t):
            thumb = t
    return src, thumb


# ----------------------------------------------------------------------- app
from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile  # noqa: E402
from fastapi.responses import JSONResponse, Response, StreamingResponse  # noqa: E402

store: Optional[Store] = None
limiter = RateLimiter(settings.uploads_per_hour)


@asynccontextmanager
async def lifespan(app: FastAPI):
    global store
    logging.basicConfig(level=logging.INFO)
    gaps = settings.missing()
    if gaps:
        raise RuntimeError("Missing settings in .env: " + ", ".join(gaps))
    store = Store(settings)
    await store.start()
    log.info("Media server ready (channel %s)", settings.channel_id)
    yield
    await store.stop()


app = FastAPI(title="Instantgram media server", lifespan=lifespan)


@app.middleware("http")
async def guard_uploads(request: Request, call_next):
    """Authenticate and size-check BEFORE the body is read."""
    if request.method in ("POST", "DELETE") and (
        request.url.path == "/upload" or request.url.path.startswith("/m/")
    ):
        try:
            request.state.uid = await verify_firebase_token(
                bearer(request.headers.get("authorization")), settings.project
            )
        except AuthError as e:
            log.info("auth rejected: %s", e)
            return JSONResponse({"detail": "Please log in again."}, status_code=401)
        if request.url.path == "/upload":
            try:
                length = int(request.headers.get("content-length", "0"))
            except ValueError:
                length = 0
            if length <= 0:
                return JSONResponse({"detail": "Content-Length required."}, status_code=411)
            if length > settings.max_video + 2 * 1024 * 1024:
                return JSONResponse({"detail": "File is too large."}, status_code=413)
    return await call_next(request)


@app.get("/health")
async def health():
    return {"ok": True, "ffmpeg": bool(shutil.which("ffmpeg"))}


@app.post("/upload")
async def upload(
    request: Request,
    file: UploadFile = File(...),
    thumb: Optional[UploadFile] = File(None),
    kind: str = Form(...),
    duration: int = Form(0),
    width: int = Form(0),
    height: int = Form(0),
):
    assert store is not None
    uid: str = request.state.uid
    if kind not in ("video", "image"):
        raise HTTPException(400, "kind must be video or image")
    if not limiter.allow(uid):
        raise HTTPException(429, "Too many uploads. Try again later.")

    limit = settings.max_video if kind == "video" else settings.max_image
    tmpdir = tempfile.mkdtemp(prefix="igmedia_")
    try:
        ext = ".mp4" if kind == "video" else ".jpg"
        path = os.path.join(tmpdir, "media" + ext)
        with open(path, "wb") as out:
            shutil.copyfileobj(file.file, out, 1024 * 1024)
        size = os.path.getsize(path)
        if size == 0:
            raise HTTPException(400, "Empty file.")
        if size > limit:
            raise HTTPException(413, "File is too large.")
        with open(path, "rb") as f:
            if not sniff_ok(f.read(16), kind):
                raise HTTPException(400, "Unsupported file type.")

        thumb_path = None
        if kind == "video":
            if thumb is not None:
                thumb_path = os.path.join(tmpdir, "thumb.jpg")
                with open(thumb_path, "wb") as out:
                    shutil.copyfileobj(thumb.file, out, 1024 * 1024)
                if os.path.getsize(thumb_path) == 0:
                    thumb_path = None
            path, thumb_path = await optimise_video(path, thumb_path)

        try:
            msg = await store.send(
                path, f"uid:{uid} kind:{kind}", kind, duration, width, height, thumb_path
            )
        except Exception as e:
            log.exception("telegram upload failed")
            raise HTTPException(502, f"Telegram upload failed: {type(e).__name__}") from e
        return {
            "handle": sign_handle(msg.id, settings.secret),
            "thumb": bool(thumb_path),
        }
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


async def _doc(handle: str):
    assert store is not None
    msg_id = parse_handle(handle, settings.secret)
    if msg_id is None:
        raise HTTPException(404, "Not found")
    try:
        msg = await store.message(msg_id)
    except Exception:
        log.exception("telegram lookup failed")
        raise HTTPException(502, "Storage unavailable")
    if msg is None:
        raise HTTPException(404, "Not found")
    return msg_id, msg


@app.api_route("/m/{handle}", methods=["GET", "HEAD"])
async def media(handle: str, request: Request):
    assert store is not None
    _, msg = await _doc(handle)
    doc = msg.document
    size = int(doc.size)
    headers = {
        "Accept-Ranges": "bytes",
        "Cache-Control": "public, max-age=31536000, immutable",
        "ETag": f'"{handle}"',
    }
    mime = doc.mime_type or "application/octet-stream"
    try:
        rng = parse_range(request.headers.get("range"), size)
    except RangeError:
        return Response(status_code=416, headers={"Content-Range": f"bytes */{size}"})
    start, end = rng if rng else (0, size - 1)
    status = 206 if rng else 200
    if rng:
        headers["Content-Range"] = f"bytes {start}-{end}/{size}"
    headers["Content-Length"] = str(end - start + 1)
    if request.method == "HEAD":
        return Response(status_code=status, headers=headers, media_type=mime)
    return StreamingResponse(
        iter_range(store.client, doc, start, end),
        status_code=status, headers=headers, media_type=mime,
    )


@app.get("/t/{handle}")
async def thumbnail(handle: str):
    assert store is not None
    msg_id, _ = await _doc(handle)
    try:
        data = await store.thumb(msg_id)
    except Exception:
        log.exception("thumbnail failed")
        raise HTTPException(502, "Storage unavailable")
    if not data:
        raise HTTPException(404, "No thumbnail")
    return Response(
        data, media_type="image/jpeg",
        headers={"Cache-Control": "public, max-age=31536000, immutable"},
    )


@app.delete("/m/{handle}", status_code=204)
async def delete_media(handle: str, request: Request):
    assert store is not None
    msg_id, msg = await _doc(handle)
    owner = re.match(r"uid:(\S+)", msg.message or "")
    if not owner or owner.group(1) != request.state.uid:
        raise HTTPException(403, "Not your file.")
    await store.delete(msg_id)
    return Response(status_code=204)


# ---------------------------------------------------------------- self check
async def self_check() -> int:
    gaps = settings.missing()
    if gaps:
        print("FAIL  missing in .env:", ", ".join(gaps))
        return 1
    st = Store(settings)
    try:
        print("1/5 logging in as the bot ...")
        await st.start()
        print("2/5 channel found. Sending a 1.5 MB test file ...")
        blob = os.urandom(1_500_000)
        tmp = tempfile.mkdtemp(prefix="igcheck_")
        p = os.path.join(tmp, "check.bin")
        Path(p).write_bytes(blob)
        from telethon.tl.types import DocumentAttributeFilename

        msg = await st.client.send_file(
            st.peer, p, caption="uid:selfcheck", force_document=True,
            attributes=[DocumentAttributeFilename("check.bin")],
        )
        print("3/5 reading it back with a Range request ...")
        m = await st.client.get_messages(st.peer, ids=msg.id)
        got = b"".join([c async for c in iter_range(st.client, m.document, 700_001, 1_300_000)])
        if got != blob[700_001:1_300_001]:
            print("FAIL  downloaded bytes do not match")
            return 1
        print("4/5 range streaming is byte-exact. Cleaning up ...")
        await st.client.delete_messages(st.peer, [msg.id])
        shutil.rmtree(tmp, ignore_errors=True)
        print("5/5 OK  Telegram storage works. ffmpeg:",
              "yes (fast-start + auto thumbnails)" if shutil.which("ffmpeg") else "no (optional)")
        return 0
    except Exception as e:
        print("FAIL ", type(e).__name__, "-", e)
        return 1
    finally:
        await st.stop()


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "check":
        sys.exit(asyncio.run(self_check()))
    print(__doc__)
