"""
Limitless Cloud — Telegram Backend Server  (Production Build v4.0)

── What's new in v4.0 ──────────────────────────────────────────────────────────

  ASYNC FINALIZE + STATUS POLLING  (critical fix for 30–45 min uploads)
  ─────────────────────────────────────────────────────────────────────
  Problem: Railway drops HTTP connections that are idle for > 100 s.
           Uploading a 1.8 GB file to Telegram takes 20–45 minutes.
           Old /upload/finalize held the HTTP connection open during the
           entire Telegram send — Railway killed it every time.

  Fix:     /upload/finalize now returns IMMEDIATELY with {status:"finalizing"}.
           The actual send_file() runs in a background asyncio Task.
           Flutter polls GET /upload/status/{upload_id} every 5 s until
           status == "done" (or "error").  Each poll is a tiny request that
           completes in milliseconds — Railway never sees an idle connection.

  UPLOAD PROTOCOL OVERVIEW
  ────────────────────────
    POST /upload/init             allocate upload_id, validate session
    POST /upload/chunk  ×N       receive 16 MB slices (pure disk I/O, fast)
    POST /upload/finalize         kick off background Telegram upload, return now
    GET  /upload/status/{id}      Flutter polls until "done"

  TELEGRAM CHUNKING RULES  (unchanged)
  ─────────────────────────────────────
    Files < 2 GB  → 1 Telegram message
    Files ≥ 2 GB  → client splits into 1.95 GB Telegram messages,
                     each goes through the 4-step protocol above.

  DOWNLOAD  (unchanged)
  ───────────────────────
    Single file download: GET  /files/download/{message_id}
    Multi-chunk download: POST /files/download-chunked
    Both stream directly from Telegram in 512 KB blocks — never fully in RAM.
    Multi-chunk download returns one contiguous byte stream so the user
    receives a single file regardless of how many Telegram messages were used.

── Memory budget (Railway free plan: 512 MB) ───────────────────────────────────
  HEAVY_SEM=2: concurrent Telegram send_file tasks  (each ~50 MB peak)
  CHUNK_SEM=6: concurrent chunk writes              (each 16 MB peak)
  LIGHT_SEM=8: auth / list / meta                  (each ~2 MB peak)

── Session lifecycle ────────────────────────────────────────────────────────────
  Cleanup task runs every 30 min:
    'done' / 'error'   sessions → removed after 15 min
    any other status    sessions → removed after 2 h
"""

import asyncio
import gc
import os
import shutil
import tempfile
import time
import uuid
from contextlib import asynccontextmanager
from typing import AsyncIterator
from urllib.parse import urlparse, unquote

import aiohttp
import uvicorn
from fastapi import FastAPI, File, Form, Header, HTTPException, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
from telethon import TelegramClient
from telethon.errors import (
    FloodWaitError,
    PasswordHashInvalidError,
    PhoneCodeExpiredError,
    PhoneCodeInvalidError,
    PhoneNumberInvalidError,
    SessionPasswordNeededError,
)
from telethon.sessions import StringSession
from telethon.tl.types import (
    DocumentAttributeFilename,
    InputMessagesFilterDocument,
    Message,
)

# ── Telegram API credentials ──────────────────────────────────────────────────
API_ID   = 36148181
API_HASH = "cf8e8509b0ceaf5b229ad47f59b79e6e"

# ── Concurrency semaphores ────────────────────────────────────────────────────
_HEAVY_SEM = asyncio.Semaphore(2)   # concurrent Telegram send_file ops
_CHUNK_SEM = asyncio.Semaphore(6)   # concurrent chunk disk writes
_LIGHT_SEM = asyncio.Semaphore(8)   # auth / list / meta

# ── Constants ─────────────────────────────────────────────────────────────────
DOWNLOAD_CHUNK  = 512 * 1024   # 512 KB – iter_download block size
UPLOAD_BUF_SIZE = 64  * 1024   # 64 KB  – disk write buffer
LIST_LIMIT      = 500
META_LIMIT      = 200

# ── Upload session store ──────────────────────────────────────────────────────
# Each session:
# {
#   "dir":          str              temp directory for chunk files
#   "filename":     str
#   "mime_type":    str
#   "total_size":   int              bytes
#   "total_chunks": int              number of 16 MB HTTP chunks
#   "created_at":   float            monotonic timestamp
#   "received":     set[int]         chunk indices received so far
#   "status":       str              chunks_pending | finalizing | done | error
#   "message_id":   int | None       filled when status == done
#   "error":        str | None       filled when status == error
#   "done_at":      float | None     monotonic timestamp when done/error
# }
_upload_sessions: dict[str, dict] = {}
_sessions_lock = asyncio.Lock()

UPLOAD_SESSION_TTL   = 2 * 60 * 60   # 2 h for in-progress sessions
DONE_SESSION_TTL     = 15 * 60       # 15 min keep after done/error


# ── Stale-session cleanup task ────────────────────────────────────────────────

async def _cleanup_stale_uploads():
    while True:
        await asyncio.sleep(30 * 60)  # run every 30 min
        now = time.monotonic()
        to_delete = []

        async with _sessions_lock:
            for uid, meta in _upload_sessions.items():
                status = meta.get("status", "")
                if status in ("done", "error"):
                    done_at = meta.get("done_at", meta["created_at"])
                    if now - done_at > DONE_SESSION_TTL:
                        to_delete.append(uid)
                else:
                    if now - meta["created_at"] > UPLOAD_SESSION_TTL:
                        to_delete.append(uid)

            for uid in to_delete:
                session = _upload_sessions.pop(uid, None)
                if session:
                    _remove_upload_dir(session["dir"])

        if to_delete:
            gc.collect()


def _remove_upload_dir(dirpath: str):
    try:
        if os.path.isdir(dirpath):
            shutil.rmtree(dirpath, ignore_errors=True)
    except Exception:
        pass


# ── App lifespan ──────────────────────────────────────────────────────────────

@asynccontextmanager
async def _lifespan(app: FastAPI):
    task = asyncio.create_task(_cleanup_stale_uploads())
    try:
        yield
    finally:
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass


# ── FastAPI app ───────────────────────────────────────────────────────────────
app = FastAPI(
    title="Limitless Cloud API",
    description="Telegram-powered cloud storage backend (production v4)",
    version="4.0.0",
    docs_url=None,
    redoc_url=None,
    lifespan=_lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ── Pydantic models ───────────────────────────────────────────────────────────

class SendCodeRequest(BaseModel):
    phone: str

class VerifyCodeRequest(BaseModel):
    phone: str
    phone_code_hash: str
    code: str
    session_string: str = ""

class VerifyPasswordRequest(BaseModel):
    session_string: str
    password: str

class CheckSessionRequest(BaseModel):
    session_string: str

class DeleteFileRequest(BaseModel):
    session_string: str
    message_id: int

class DownloadChunkedRequest(BaseModel):
    session_string: str
    message_ids: list[int]

class UploadFromUrlRequest(BaseModel):
    session_string: str
    url: str
    caption: str = ""


# ── Telethon client factory ───────────────────────────────────────────────────

def make_client(session_string: str = "", *, for_upload: bool = False) -> TelegramClient:
    """
    for_upload=True  → more retries + auto_reconnect for long Telegram uploads.
    for_upload=False → minimal retries for fast auth/list calls.
    """
    retries = 10 if for_upload else 1
    return TelegramClient(
        StringSession(session_string),
        API_ID,
        API_HASH,
        system_version="4.16.30-vxCUSTOM",
        app_version="4.0.0",
        device_model="Limitless Cloud",
        connection_retries=retries,
        request_retries=retries,
        flood_sleep_threshold=60,
        auto_reconnect=for_upload,
    )


# ══════════════════════════════════════════════════════════════════════════════
# AUTH ROUTES
# ══════════════════════════════════════════════════════════════════════════════

@app.post("/auth/send-code")
async def send_code(req: SendCodeRequest):
    async with _LIGHT_SEM:
        client = make_client()
        try:
            await client.connect()
            result = await client.send_code_request(req.phone)
            return {
                "success": True,
                "phone_code_hash": result.phone_code_hash,
                "session_string": client.session.save(),
            }
        except PhoneNumberInvalidError:
            raise HTTPException(400, "Invalid phone number.")
        except FloodWaitError as e:
            raise HTTPException(429, f"Too many requests. Wait {e.seconds}s.")
        except Exception as e:
            raise HTTPException(500, str(e))
        finally:
            await client.disconnect()
            gc.collect()


@app.post("/auth/verify-code")
async def verify_code(req: VerifyCodeRequest):
    async with _LIGHT_SEM:
        client = make_client(req.session_string)
        try:
            await client.connect()
            await client.sign_in(
                phone=req.phone,
                code=req.code,
                phone_code_hash=req.phone_code_hash,
            )
            me = await client.get_me()
            return {
                "success": True,
                "needs_password": False,
                "session_string": client.session.save(),
                "user_id": me.id,
                "first_name": me.first_name or "",
                "last_name": me.last_name or "",
                "phone": me.phone or req.phone,
                "username": me.username or "",
            }
        except SessionPasswordNeededError:
            return {"success": True, "needs_password": True, "session_string": client.session.save()}
        except PhoneCodeInvalidError:
            raise HTTPException(400, "Invalid verification code.")
        except PhoneCodeExpiredError:
            raise HTTPException(400, "Code expired. Request a new one.")
        except Exception as e:
            raise HTTPException(500, str(e))
        finally:
            await client.disconnect()
            gc.collect()


@app.post("/auth/verify-2fa")
async def verify_2fa(req: VerifyPasswordRequest):
    async with _LIGHT_SEM:
        client = make_client(req.session_string)
        try:
            await client.connect()
            await client.sign_in(password=req.password)
            me = await client.get_me()
            return {
                "success": True,
                "session_string": client.session.save(),
                "user_id": me.id,
                "first_name": me.first_name or "",
                "last_name": me.last_name or "",
                "phone": me.phone or "",
                "username": me.username or "",
            }
        except PasswordHashInvalidError:
            raise HTTPException(400, "Wrong 2FA password.")
        except Exception as e:
            raise HTTPException(500, str(e))
        finally:
            await client.disconnect()
            gc.collect()


@app.post("/auth/check-session")
async def check_session(req: CheckSessionRequest):
    async with _LIGHT_SEM:
        client = make_client(req.session_string)
        try:
            await client.connect()
            if not await client.is_user_authorized():
                return {"valid": False}
            me = await client.get_me()
            return {
                "valid": True,
                "user_id": me.id,
                "first_name": me.first_name or "",
                "last_name": me.last_name or "",
                "phone": me.phone or "",
                "username": me.username or "",
            }
        except Exception:
            return {"valid": False}
        finally:
            await client.disconnect()
            gc.collect()


@app.post("/auth/logout")
async def logout(req: CheckSessionRequest):
    async with _LIGHT_SEM:
        client = make_client(req.session_string)
        try:
            await client.connect()
            await client.log_out()
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}
        finally:
            await client.disconnect()
            gc.collect()


# ══════════════════════════════════════════════════════════════════════════════
# CHUNKED UPLOAD PROTOCOL  v4
# ══════════════════════════════════════════════════════════════════════════════
#
#  Step 1:  POST /upload/init
#           → validates session, allocates upload_id + tmp dir
#           → returns {upload_id}   (instant)
#
#  Step 2:  POST /upload/chunk  (repeat for each 16 MB slice)
#           → writes slice to tmp dir, marks chunk received
#           → returns {received: true}   (< 30 s per chunk on any connection)
#
#  Step 3:  POST /upload/finalize
#           → validates all chunks received
#           → spawns background asyncio.Task for assembly + Telegram send
#           → returns {status:"finalizing", upload_id}   (instant, < 1 s)
#
#  Step 4:  GET /upload/status/{upload_id}  (Flutter polls every 5 s)
#           → returns {status, message_id?, error?}
#           → status: "finalizing" | "done" | "error"
#
# ══════════════════════════════════════════════════════════════════════════════

@app.post("/upload/init")
async def upload_init(
    session_string: str = Form(...),
    filename: str = Form(...),
    total_size: int = Form(...),
    total_chunks: int = Form(...),
    mime_type: str = Form(default="application/octet-stream"),
):
    """
    Allocate an upload session.

    Validates the Telegram session up-front so the client gets an immediate
    401 instead of finding out after uploading gigabytes of data.
    """
    # Validate session
    client = make_client(session_string)
    try:
        await client.connect()
        if not await client.is_user_authorized():
            raise HTTPException(401, "Session expired.")
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(500, f"Session check failed: {e}")
    finally:
        await client.disconnect()

    if not (1 <= total_chunks <= 50_000):
        raise HTTPException(400, "total_chunks out of range (1–50000).")
    if not (0 <= total_size <= 500 * 1024 * 1024 * 1024):  # 500 GB ceiling
        raise HTTPException(400, "total_size out of range.")

    upload_id = str(uuid.uuid4())
    tmp_dir   = os.path.join(tempfile.gettempdir(), f"lc_upload_{upload_id}")
    os.makedirs(tmp_dir, exist_ok=True)

    async with _sessions_lock:
        _upload_sessions[upload_id] = {
            "dir":          tmp_dir,
            "filename":     filename,
            "mime_type":    mime_type,
            "total_size":   total_size,
            "total_chunks": total_chunks,
            "created_at":   time.monotonic(),
            "received":     set(),
            "status":       "chunks_pending",
            "message_id":   None,
            "error":        None,
            "done_at":      None,
        }

    return {"upload_id": upload_id, "total_chunks": total_chunks}


@app.post("/upload/chunk")
async def upload_chunk(
    upload_id: str = Form(...),
    chunk_index: int = Form(...),
    chunk_data: UploadFile = File(...),
):
    """
    Receive one 16 MB slice and write it to disk.

    This is pure I/O — no Telegram involved.  Each call completes in < 30 s
    on any realistic connection, well within Railway's 100 s idle timeout.

    Sending the same chunk_index twice is safe (idempotent retry).
    """
    async with _CHUNK_SEM:
        async with _sessions_lock:
            session = _upload_sessions.get(upload_id)
        if not session:
            raise HTTPException(404, f"upload_id not found or expired: {upload_id}")
        if session["status"] not in ("chunks_pending", "finalizing"):
            raise HTTPException(409, f"Upload in wrong state: {session['status']}")
        if not (0 <= chunk_index < session["total_chunks"]):
            raise HTTPException(400, f"chunk_index {chunk_index} out of range.")

        chunk_path = os.path.join(session["dir"], f"chunk_{chunk_index:06d}")

        # Stream chunk body to disk in 64 KB blocks — never buffers full chunk in RAM
        try:
            with open(chunk_path, "wb") as f:
                while True:
                    piece = await chunk_data.read(UPLOAD_BUF_SIZE)
                    if not piece:
                        break
                    f.write(piece)
        except Exception as e:
            # Clean up partial file so client can retry the chunk cleanly
            try:
                os.unlink(chunk_path)
            except OSError:
                pass
            raise HTTPException(500, f"Failed to write chunk {chunk_index}: {e}")

        async with _sessions_lock:
            if upload_id in _upload_sessions:
                _upload_sessions[upload_id]["received"].add(chunk_index)

        return {"received": True, "chunk_index": chunk_index}


@app.post("/upload/finalize")
async def upload_finalize(
    upload_id: str = Form(...),
    session_string: str = Form(...),
    caption: str = Form(default=""),
):
    """
    Trigger the background Telegram upload and return IMMEDIATELY.

    This endpoint does NOT wait for Telegram.  It verifies that all chunks
    are present, marks the session as 'finalizing', spawns an asyncio.Task
    for the actual assembly + send_file(), and returns at once.

    The client then polls GET /upload/status/{upload_id} every 5 s.
    This design bypasses Railway's 100 s HTTP idle timeout entirely because:
      - This request returns in < 1 s
      - Each status poll returns in < 1 s
      - The actual Telegram upload (which can take 45 min) runs in the
        background without holding any HTTP connection open.
    """
    async with _sessions_lock:
        session = _upload_sessions.get(upload_id)
    if not session:
        raise HTTPException(404, f"upload_id not found or expired: {upload_id}")

    # Idempotency: if already finalizing/done, return current state
    if session["status"] == "done":
        return {
            "status": "done",
            "upload_id": upload_id,
            "message_id": session["message_id"],
        }
    if session["status"] == "finalizing":
        return {"status": "finalizing", "upload_id": upload_id}
    if session["status"] == "error":
        raise HTTPException(500, session.get("error", "Upload failed."))

    # Verify all chunks are present
    async with _sessions_lock:
        received = set(_upload_sessions[upload_id]["received"])
        total    = _upload_sessions[upload_id]["total_chunks"]
    missing = [i for i in range(total) if i not in received]
    if missing:
        raise HTTPException(
            400,
            f"{len(missing)} chunk(s) missing (first few: {missing[:10]}). "
            "Re-upload missing chunks before finalizing."
        )

    # Mark as finalizing and fire background task
    async with _sessions_lock:
        _upload_sessions[upload_id]["status"] = "finalizing"

    asyncio.create_task(
        _finalize_background(
            upload_id=upload_id,
            session_string=session_string,
            caption=caption,
        )
    )

    return {"status": "finalizing", "upload_id": upload_id}


@app.get("/upload/status/{upload_id}")
async def upload_status(upload_id: str):
    """
    Poll the status of a background finalize task.

    Returns immediately (< 1 s).  Flutter calls this every 5 s after
    POST /upload/finalize until status == 'done' or 'error'.

    Response shape:
      {status: "finalizing" | "done" | "error",
       message_id: int | null,
       error: str | null}
    """
    async with _sessions_lock:
        session = _upload_sessions.get(upload_id)
    if not session:
        raise HTTPException(
            404,
            "Upload session not found. It may have completed and been cleaned up, "
            "or the session ID is invalid."
        )
    return {
        "status":     session["status"],
        "message_id": session.get("message_id"),
        "error":      session.get("error"),
    }


async def _finalize_background(
    upload_id: str,
    session_string: str,
    caption: str,
):
    """
    Background task: assembles chunks → send_file() to Telegram.

    Runs under _HEAVY_SEM to cap concurrent Telegram uploads at 2.
    Updates _upload_sessions[upload_id] with 'done' or 'error' when finished.
    May run for 30–45 minutes for very large files — that is expected and fine
    because it holds no HTTP connection open.
    """
    async with _HEAVY_SEM:
        async with _sessions_lock:
            session = _upload_sessions.get(upload_id)
        if not session:
            return  # session was cleaned up between finalize call and task start

        filename     = session["filename"]
        total_chunks = session["total_chunks"]
        tmp_dir      = session["dir"]

        assembled_path = None
        client = make_client(session_string, for_upload=True)
        try:
            await client.connect()
            if not await client.is_user_authorized():
                raise RuntimeError("Telegram session expired.")

            # ── Assemble all chunk files into one temp file ────────────────────
            # Reads one 64 KB block at a time — peak RAM is O(UPLOAD_BUF_SIZE)
            with tempfile.NamedTemporaryFile(
                delete=False, suffix=f"_{filename}", dir=tmp_dir
            ) as assembled:
                assembled_path = assembled.name
                for i in range(total_chunks):
                    chunk_path = os.path.join(tmp_dir, f"chunk_{i:06d}")
                    with open(chunk_path, "rb") as cf:
                        while True:
                            block = cf.read(UPLOAD_BUF_SIZE)
                            if not block:
                                break
                            assembled.write(block)

            file_size = os.path.getsize(assembled_path)

            # ── Send to Telegram ───────────────────────────────────────────────
            # This is where the time goes: 5 min for 300 MB, 45 min for 1.8 GB.
            # With connection_retries=10 and auto_reconnect=True Telethon will
            # survive brief network drops and retry internally.
            message = await client.send_file(
                "me",
                assembled_path,
                caption=caption or filename,
                force_document=True,
                attributes=[DocumentAttributeFilename(file_name=filename)],
            )

            # ── Mark done ─────────────────────────────────────────────────────
            async with _sessions_lock:
                if upload_id in _upload_sessions:
                    _upload_sessions[upload_id].update({
                        "status":     "done",
                        "message_id": message.id,
                        "done_at":    time.monotonic(),
                    })

            # Clean up assembled file and chunk files now that Telegram has them
            _remove_upload_dir(tmp_dir)

        except Exception as e:
            async with _sessions_lock:
                if upload_id in _upload_sessions:
                    _upload_sessions[upload_id].update({
                        "status":  "error",
                        "error":   str(e),
                        "done_at": time.monotonic(),
                    })
        finally:
            try:
                await client.disconnect()
            except Exception:
                pass
            gc.collect()


# ══════════════════════════════════════════════════════════════════════════════
# LEGACY single-shot upload  (kept for backward compat)
# ══════════════════════════════════════════════════════════════════════════════

@app.post("/files/upload")
async def upload_file(
    session_string: str = Form(...),
    file: UploadFile = File(...),
    caption: str = Form(default=""),
):
    """Legacy single-shot upload — old app builds use this."""
    async with _HEAVY_SEM:
        client = make_client(session_string, for_upload=True)
        tmp_path = None
        try:
            await client.connect()
            if not await client.is_user_authorized():
                raise HTTPException(401, "Session expired.")

            filename  = file.filename or "upload"
            file_size = 0

            with tempfile.NamedTemporaryFile(delete=False, suffix=f"_{filename}") as tmp:
                tmp_path = tmp.name
                while True:
                    chunk = await file.read(UPLOAD_BUF_SIZE)
                    if not chunk:
                        break
                    tmp.write(chunk)
                    file_size += len(chunk)

            message = await client.send_file(
                "me",
                tmp_path,
                caption=caption or filename,
                force_document=True,
                attributes=[DocumentAttributeFilename(file_name=filename)],
            )
            return {
                "success": True,
                "message_id": message.id,
                "file_name": filename,
                "file_size": file_size,
                "date": message.date.isoformat(),
            }
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(500, str(e))
        finally:
            await client.disconnect()
            if tmp_path and os.path.exists(tmp_path):
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass
            gc.collect()


# ══════════════════════════════════════════════════════════════════════════════
# DOWNLOAD ROUTES
# ══════════════════════════════════════════════════════════════════════════════

@app.post("/files/upload-from-url")
async def upload_file_from_url(req: UploadFromUrlRequest):
    """Server-side URL → Telegram upload."""
    async with _HEAVY_SEM:
        client = make_client(req.session_string, for_upload=True)
        tmp_path = None
        try:
            await client.connect()
            if not await client.is_user_authorized():
                raise HTTPException(401, "Session expired.")

            parsed   = urlparse(req.url)
            raw_name = unquote(parsed.path.split("/")[-1]) or "download"
            if "." not in raw_name:
                raw_name += ".bin"
            filename  = raw_name
            file_size = 0

            headers = {
                "User-Agent": (
                    "Mozilla/5.0 (Linux; Android 13) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/120.0 Mobile Safari/537.36"
                )
            }

            async with aiohttp.ClientSession() as session:
                async with session.get(
                    req.url,
                    headers=headers,
                    timeout=aiohttp.ClientTimeout(total=1800),
                    allow_redirects=True,
                ) as resp:
                    if resp.status >= 400:
                        raise HTTPException(resp.status, f"Remote returned {resp.status}.")
                    cd = resp.headers.get("Content-Disposition", "")
                    if "filename=" in cd:
                        try:
                            filename = cd.split("filename=")[-1].strip(' "\'')
                        except Exception:
                            pass
                    with tempfile.NamedTemporaryFile(
                        delete=False, suffix=f"_{filename}"
                    ) as tmp:
                        tmp_path = tmp.name
                        async for chunk in resp.content.iter_chunked(UPLOAD_BUF_SIZE):
                            tmp.write(chunk)
                            file_size += len(chunk)

            caption = req.caption or filename
            message = await client.send_file(
                "me",
                tmp_path,
                caption=caption,
                force_document=True,
                attributes=[DocumentAttributeFilename(file_name=filename)],
            )
            return {
                "success":    True,
                "message_id": message.id,
                "file_name":  filename,
                "file_size":  file_size,
                "date":       message.date.isoformat(),
            }
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(500, str(e))
        finally:
            await client.disconnect()
            if tmp_path and os.path.exists(tmp_path):
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass
            gc.collect()


@app.get("/files/list")
async def list_files(session_string: str):
    async with _LIGHT_SEM:
        client = make_client(session_string)
        try:
            await client.connect()
            if not await client.is_user_authorized():
                raise HTTPException(401, "Session expired.")
            files = []
            async for message in client.iter_messages(
                "me",
                filter=InputMessagesFilterDocument(),
                limit=LIST_LIMIT,
            ):
                if message.document:
                    fname = "file"
                    for attr in message.document.attributes:
                        if isinstance(attr, DocumentAttributeFilename):
                            fname = attr.file_name
                            break
                    files.append({
                        "message_id": message.id,
                        "file_name":  fname,
                        "file_size":  message.document.size,
                        "mime_type":  message.document.mime_type or "application/octet-stream",
                        "date":       message.date.isoformat(),
                        "caption":    message.message or "",
                    })
            return {"success": True, "files": files}
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(500, str(e))
        finally:
            await client.disconnect()
            gc.collect()


@app.get("/files/download/{message_id}")
async def download_file(message_id: int, session_string: str):
    """
    Stream a single Telegram message to the client in 512 KB blocks.
    The file is NEVER fully in RAM.
    """
    async with _HEAVY_SEM:
        client = make_client(session_string)
        try:
            await client.connect()
            if not await client.is_user_authorized():
                raise HTTPException(401, "Session expired.")

            message: Message = await client.get_messages("me", ids=message_id)
            if not message or not message.document:
                raise HTTPException(404, "File not found.")

            fname = "download"
            for attr in message.document.attributes:
                if isinstance(attr, DocumentAttributeFilename):
                    fname = attr.file_name
                    break
            mime = message.document.mime_type or "application/octet-stream"

            async def _stream() -> AsyncIterator[bytes]:
                try:
                    async for chunk in client.iter_download(
                        message.document,
                        request_size=DOWNLOAD_CHUNK,
                    ):
                        yield chunk
                finally:
                    await client.disconnect()
                    gc.collect()

            return StreamingResponse(
                _stream(),
                media_type=mime,
                headers={"Content-Disposition": f'attachment; filename="{fname}"'},
            )
        except HTTPException:
            await client.disconnect()
            raise
        except Exception as e:
            await client.disconnect()
            raise HTTPException(500, str(e))


@app.post("/files/download-chunked")
async def download_chunked_file(req: DownloadChunkedRequest):
    """
    Stream multiple Telegram messages as ONE contiguous response.

    Even if the original file was uploaded as several 1.95 GB Telegram
    messages, the client receives a single byte stream that exactly
    reconstructs the original file — no post-processing needed.
    """
    async with _HEAVY_SEM:
        if not req.message_ids:
            raise HTTPException(400, "message_ids must not be empty.")

        client = make_client(req.session_string)
        try:
            await client.connect()
            if not await client.is_user_authorized():
                raise HTTPException(401, "Session expired.")

            first_message: Message = await client.get_messages("me", ids=req.message_ids[0])
            if not first_message or not first_message.document:
                raise HTTPException(404, "First chunk not found.")

            fname = "download"
            for attr in first_message.document.attributes:
                if isinstance(attr, DocumentAttributeFilename):
                    raw = attr.file_name
                    # Strip .part1ofN suffix if present
                    fname = raw[:raw.rfind(".part")] if ".part" in raw else raw
                    break
            mime = first_message.document.mime_type or "application/octet-stream"

            async def _stream_all() -> AsyncIterator[bytes]:
                try:
                    for msg_id in req.message_ids:
                        message: Message = await client.get_messages("me", ids=msg_id)
                        if not message or not message.document:
                            continue
                        async for chunk in client.iter_download(
                            message.document,
                            request_size=DOWNLOAD_CHUNK,
                        ):
                            yield chunk
                finally:
                    await client.disconnect()
                    gc.collect()

            return StreamingResponse(
                _stream_all(),
                media_type=mime,
                headers={"Content-Disposition": f'attachment; filename="{fname}"'},
            )
        except HTTPException:
            await client.disconnect()
            raise
        except Exception as e:
            await client.disconnect()
            raise HTTPException(500, str(e))


@app.delete("/files/{message_id}")
async def delete_file(message_id: int, req: DeleteFileRequest):
    async with _LIGHT_SEM:
        client = make_client(req.session_string)
        try:
            await client.connect()
            if not await client.is_user_authorized():
                raise HTTPException(401, "Session expired.")
            await client.delete_messages("me", [message_id])
            return {"success": True}
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(500, str(e))
        finally:
            await client.disconnect()
            gc.collect()


@app.get("/files/info/{message_id}")
async def file_info(message_id: int, session_string: str):
    async with _LIGHT_SEM:
        client = make_client(session_string)
        try:
            await client.connect()
            if not await client.is_user_authorized():
                raise HTTPException(401, "Session expired.")
            message = await client.get_messages("me", ids=message_id)
            if not message or not message.document:
                raise HTTPException(404, "File not found.")
            fname = "file"
            for attr in message.document.attributes:
                if isinstance(attr, DocumentAttributeFilename):
                    fname = attr.file_name
                    break
            return {
                "success":    True,
                "message_id": message.id,
                "file_name":  fname,
                "file_size":  message.document.size,
                "mime_type":  message.document.mime_type or "application/octet-stream",
                "date":       message.date.isoformat(),
            }
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(500, str(e))
        finally:
            await client.disconnect()
            gc.collect()


# ── Metadata routes ───────────────────────────────────────────────────────────

@app.post("/meta/save")
async def save_metadata(
    session_string: str = Form(...),
    data: str = Form(...),
):
    async with _LIGHT_SEM:
        client = make_client(session_string)
        try:
            await client.connect()
            if not await client.is_user_authorized():
                raise HTTPException(401, "Session expired.")
            message = await client.send_message("me", data)
            return {"success": True, "message_id": message.id}
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(500, str(e))
        finally:
            await client.disconnect()
            gc.collect()


@app.get("/meta/list")
async def list_metadata(session_string: str, prefix: str = "LIMITLESS_"):
    async with _LIGHT_SEM:
        client = make_client(session_string)
        try:
            await client.connect()
            if not await client.is_user_authorized():
                raise HTTPException(401, "Session expired.")
            results = []
            async for message in client.iter_messages("me", limit=META_LIMIT):
                if (
                    message.text
                    and not message.document
                    and message.text.startswith(prefix)
                ):
                    results.append({
                        "message_id": message.id,
                        "text":       message.text,
                        "date":       message.date.isoformat(),
                    })
            return {"success": True, "metadata": results}
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(500, str(e))
        finally:
            await client.disconnect()
            gc.collect()


@app.delete("/meta/{message_id}")
async def delete_metadata(message_id: int, req: DeleteFileRequest):
    async with _LIGHT_SEM:
        client = make_client(req.session_string)
        try:
            await client.connect()
            if not await client.is_user_authorized():
                raise HTTPException(401, "Session expired.")
            await client.delete_messages("me", [message_id])
            return {"success": True}
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(500, str(e))
        finally:
            await client.disconnect()
            gc.collect()


# ── Health check ──────────────────────────────────────────────────────────────

@app.get("/health")
async def health():
    async with _sessions_lock:
        session_count = len(_upload_sessions)
        by_status: dict[str, int] = {}
        for s in _upload_sessions.values():
            st = s.get("status", "unknown")
            by_status[st] = by_status.get(st, 0) + 1
    return {
        "status":          "ok",
        "version":         "4.0.0",
        "api_id":          API_ID,
        "active_sessions": session_count,
        "sessions_by_status": by_status,
    }


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=int(os.environ.get("PORT", 8000)),
        reload=False,
        workers=1,
        loop="asyncio",
        http="h11",
        log_level="warning",
        timeout_keep_alive=300,    # keep TCP alive 5 min between chunk uploads
    )
