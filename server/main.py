"""
Limitless Cloud — Telegram Backend Server  (Production Build v5.0)

── What's new in v5.0 ──────────────────────────────────────────────────────────

  STREAMING RELAY UPLOAD  (permanently eliminates the 91%→restart loop)
  ──────────────────────────────────────────────────────────────────────
  OLD (v4.x):
    Flutter ──16MB chunks──▶ Railway DISK ──assemble 1.5GB──▶ Telegram
    Problem: Railway spends 30-45 min re-uploading the assembled file to
             Telegram.  Any FloodWait, timeout, or OOM during that window
             causes the session to fail and Flutter restarts from 91%.

  NEW (v5.0):
    Flutter ──16MB chunk──▶ Railway RAM ──512KB parts×8 parallel──▶ Telegram
    Fix:     Each 16MB chunk is split into 512KB Telegram parts and uploaded
             in parallel (8 at a time) DURING the same HTTP request that
             Flutter uses to send the chunk.  When /upload/chunk returns 200,
             Telegram already has those bytes.

  UPLOAD PROTOCOL (v5.0)
  ──────────────────────
    POST /upload/init      → allocate upload_id, create TelegramClient,
                             generate Telegram file_id, connect.  Instant.
    POST /upload/chunk ×N  → relay 512KB parts to Telegram in parallel.
                             No disk assembly.  When this returns, Telegram
                             already has the data.
    POST /upload/finalize  → call messages.sendMedia with InputFileBig
                             (parts already on Telegram).  INSTANT (<500ms).
                             Returns {status:"done", message_id:X} directly.
                             NO background task.  NO 30-min Telegram upload.
    GET  /upload/status    → still exists; first poll always returns "done"
                             because finalize is synchronous and fast.

  TELEGRAM CHUNKING RULES  (unchanged)
  ─────────────────────────────────────
    Files < 2 GB  → 1 Telegram message
    Files ≥ 2 GB  → client splits into 1.95 GB segments,
                     each goes through the 4-step protocol above.

  DOWNLOAD  (unchanged)
  ───────────────────────
    GET  /files/download/{message_id}     stream from Telegram in 512 KB blocks
    POST /files/download-chunked          stream N messages as one byte stream

── Memory budget (Railway free plan: 512 MB) ───────────────────────────────────
  MAX_CONCURRENT_UPLOADS = 3  → 3 persistent TelegramClient connections
  Each upload peak RAM    ≈ 16 MB chunk in RAM + client overhead (~50 MB)
  Total upload RAM        ≈ 3 × 66 MB = ~200 MB
  TG_UPLOAD_CONCURRENCY  = 8  → 8 parallel saveBigFilePart per chunk relay
"""

import asyncio
import gc
import math
import os
import random
import shutil
import tempfile
import time
import uuid
from contextlib import asynccontextmanager
from typing import AsyncIterator
from urllib.parse import urlparse, unquote

import aiohttp
import uvicorn
from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
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
from telethon.tl.functions.upload import SaveBigFilePartRequest, SaveFilePartRequest
from telethon.tl.types import (
    DocumentAttributeFilename,
    InputFile,
    InputFileBig,
    InputMessagesFilterDocument,
    Message,
)

# ── Telegram API credentials ──────────────────────────────────────────────────
API_ID   = 36148181
API_HASH = "cf8e8509b0ceaf5b229ad47f59b79e6e"

# ── Concurrency limits ────────────────────────────────────────────────────────
_HEAVY_SEM            = asyncio.Semaphore(2)   # download / legacy upload
_LIGHT_SEM            = asyncio.Semaphore(8)   # auth / list / meta
MAX_CONCURRENT_UPLOADS = 3                      # max simultaneous upload sessions
TG_UPLOAD_CONCURRENCY  = 8                      # parallel saveBigFilePart per chunk

# ── Constants ─────────────────────────────────────────────────────────────────
DOWNLOAD_CHUNK     = 512 * 1024        # 512 KB — iter_download block size
UPLOAD_BUF_SIZE    = 64  * 1024        # 64 KB  — disk write buffer (legacy)
TELEGRAM_PART_SIZE = 512 * 1024        # 512 KB — Telegram upload part size
HTTP_CHUNK_SIZE    = 16  * 1024 * 1024 # 16 MB  — Flutter HTTP chunk size
LIST_LIMIT         = 500
META_LIMIT         = 200

# ── Upload session store ──────────────────────────────────────────────────────
# {
#   "filename":       str
#   "mime_type":      str
#   "total_size":     int    total file bytes
#   "total_chunks":   int    number of 16 MB HTTP chunks expected
#   "total_tg_parts": int    total 512 KB Telegram parts for the whole file
#   "use_big_file":   bool   True if total_size >= 10 MB
#   "tg_file_id":     int    random int64 (Telegram file_id)
#   "created_at":     float  monotonic timestamp
#   "received":       set    chunk indices received + relayed successfully
#   "status":         str    "chunks_pending"|"finalizing"|"done"|"error"
#   "message_id":     int|None
#   "error":          str|None
#   "done_at":        float|None
# }
_upload_sessions: dict[str, dict] = {}
_sessions_lock = asyncio.Lock()

# Persistent TelegramClients — one per active upload session
_tg_clients: dict[str, TelegramClient] = {}
_clients_lock = asyncio.Lock()

UPLOAD_SESSION_TTL = 2 * 60 * 60   # 2 h for in-progress sessions
DONE_SESSION_TTL   = 15 * 60       # 15 min after done/error


# ── Stale-session cleanup ─────────────────────────────────────────────────────

async def _cleanup_stale_uploads():
    """Runs every 30 min. Removes expired sessions and disconnects their clients."""
    while True:
        await asyncio.sleep(30 * 60)
        now = time.monotonic()
        to_delete: list[str] = []

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
                _upload_sessions.pop(uid, None)

        # Disconnect stale TelegramClients outside the sessions lock
        for uid in to_delete:
            async with _clients_lock:
                client = _tg_clients.pop(uid, None)
            if client:
                try:
                    await client.disconnect()
                except Exception:
                    pass

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
async def _lifespan(app):
    task = asyncio.create_task(_cleanup_stale_uploads())
    try:
        yield
    finally:
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        # Disconnect all upload clients on shutdown
        async with _clients_lock:
            clients = dict(_tg_clients)
        for client in clients.values():
            try:
                await client.disconnect()
            except Exception:
                pass


# ── FastAPI app ───────────────────────────────────────────────────────────────
app = FastAPI(
    title="Limitless Cloud API",
    description="Telegram-powered cloud storage backend (production v5.0)",
    version="5.0.0",
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
    retries = 10 if for_upload else 1
    return TelegramClient(
        StringSession(session_string),
        API_ID,
        API_HASH,
        system_version="4.16.30-vxCUSTOM",
        app_version="5.0.0",
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
# STREAMING RELAY UPLOAD v5.0
#
#  The key insight: Telegram stores uploaded parts for ~24 hours after the
#  last saveBigFilePart call.  We upload parts DURING the chunk transfer from
#  Flutter so that by the time all chunks are received, Telegram already has
#  all the bytes.  /upload/finalize just calls sendMedia (instant metadata op).
#
#  Part-index mapping:
#    HTTP chunk 0 (16MB) → Telegram parts 0–31   (32 × 512KB)
#    HTTP chunk 1 (16MB) → Telegram parts 32–63
#    HTTP chunk N        → Telegram parts N×32 … N×32+31
#    Last chunk (≤16MB)  → Telegram parts correctly placed at N×32 …
#
#  total_tg_parts = ceil(total_size / 512KB)   — calculated at init time
# ══════════════════════════════════════════════════════════════════════════════

async def _relay_chunk_parts(
    client: TelegramClient,
    tg_file_id: int,
    total_tg_parts: int,
    use_big_file: bool,
    chunk_bytes: bytes,
    part_offset: int,
    max_retries: int = 5,
) -> None:
    """
    Split chunk_bytes into 512 KB pieces and upload them to Telegram in parallel.

    - use_big_file=True  → SaveBigFilePartRequest (files >= 10 MB)
    - use_big_file=False → SaveFilePartRequest    (files <  10 MB)

    Failed parts are retried up to max_retries times with FloodWait handling
    and exponential back-off.  Duplicate uploads (on retry) are idempotent —
    Telegram silently overwrites the part.
    """
    # Build (part_index, part_bytes) list
    parts: list[tuple[int, bytes]] = []
    for i, start in enumerate(range(0, len(chunk_bytes), TELEGRAM_PART_SIZE)):
        parts.append((part_offset + i, chunk_bytes[start:start + TELEGRAM_PART_SIZE]))

    remaining = list(parts)

    for attempt in range(1, max_retries + 1):
        if not remaining:
            break

        failed: list[tuple[int, bytes]] = []

        # Upload in batches of TG_UPLOAD_CONCURRENCY (8 parallel calls)
        for batch_start in range(0, len(remaining), TG_UPLOAD_CONCURRENCY):
            batch = remaining[batch_start:batch_start + TG_UPLOAD_CONCURRENCY]

            if use_big_file:
                reqs = [
                    SaveBigFilePartRequest(
                        file_id=tg_file_id,
                        file_part=idx,
                        file_total_parts=total_tg_parts,
                        bytes=data,
                    )
                    for idx, data in batch
                ]
            else:
                reqs = [
                    SaveFilePartRequest(
                        file_id=tg_file_id,
                        file_part=idx,
                        bytes=data,
                    )
                    for idx, data in batch
                ]

            results = await asyncio.gather(
                *[client(r) for r in reqs],
                return_exceptions=True,
            )

            for (idx, data), result in zip(batch, results):
                if isinstance(result, FloodWaitError):
                    await asyncio.sleep(result.seconds + 5)
                    failed.append((idx, data))
                elif isinstance(result, Exception):
                    failed.append((idx, data))
                # True → success, do nothing

        remaining = failed
        if remaining and attempt < max_retries:
            backoff = min(60, 5 * (2 ** (attempt - 1)))  # 5, 10, 20, 40, 60 s
            await asyncio.sleep(backoff)

    if remaining:
        raise RuntimeError(
            f"{len(remaining)} Telegram part(s) failed after {max_retries} attempts. "
            f"First failed indices: {[idx for idx, _ in remaining[:5]]}"
        )


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

    v5.0: Also creates a persistent TelegramClient, connects to Telegram,
    and generates a Telegram file_id.  The client stays alive for the whole
    upload so each /upload/chunk can relay parts without reconnecting.
    """
    # ── Check upload concurrency limit ────────────────────────────────────────
    async with _clients_lock:
        active = len(_tg_clients)
    if active >= MAX_CONCURRENT_UPLOADS:
        raise HTTPException(
            503,
            f"Server is busy ({active}/{MAX_CONCURRENT_UPLOADS} uploads). "
            "Please wait a moment and try again.",
        )

    if not (1 <= total_chunks <= 50_000):
        raise HTTPException(400, "total_chunks out of range (1–50000).")
    if not (0 < total_size <= 500 * 1024 * 1024 * 1024):
        raise HTTPException(400, "total_size out of range.")

    # ── Create and connect TelegramClient ────────────────────────────────────
    client = make_client(session_string, for_upload=True)
    try:
        await client.connect()
        if not await client.is_user_authorized():
            await client.disconnect()
            raise HTTPException(401, "Telegram session expired.")
    except HTTPException:
        raise
    except Exception as e:
        try:
            await client.disconnect()
        except Exception:
            pass
        raise HTTPException(500, f"Telegram connection failed: {e}")

    # ── Allocate session ──────────────────────────────────────────────────────
    upload_id      = str(uuid.uuid4())
    # Telegram file_id must be a positive random int64
    tg_file_id     = random.randint(1, 2 ** 63 - 1)
    # >= 10 MB → saveBigFilePart + InputFileBig
    # <  10 MB → saveFilePart   + InputFile
    use_big_file   = total_size >= 10 * 1024 * 1024
    total_tg_parts = math.ceil(total_size / TELEGRAM_PART_SIZE)

    async with _sessions_lock:
        _upload_sessions[upload_id] = {
            "filename":       filename,
            "mime_type":      mime_type,
            "total_size":     total_size,
            "total_chunks":   total_chunks,
            "total_tg_parts": total_tg_parts,
            "use_big_file":   use_big_file,
            "tg_file_id":     tg_file_id,
            "created_at":     time.monotonic(),
            "received":       set(),
            "status":         "chunks_pending",
            "message_id":     None,
            "error":          None,
            "done_at":        None,
        }

    async with _clients_lock:
        _tg_clients[upload_id] = client

    return {"upload_id": upload_id, "total_chunks": total_chunks}


@app.post("/upload/chunk")
async def upload_chunk(
    upload_id: str = Form(...),
    chunk_index: int = Form(...),
    chunk_data: UploadFile = File(...),
):
    """
    Receive one 16 MB slice and IMMEDIATELY relay all 512 KB parts to Telegram
    in parallel (8 at a time).

    When this endpoint returns 200, Telegram already has those bytes.
    No disk assembly.  No background task.  No 91% problem.

    Sending the same chunk_index twice is safe — saveBigFilePart is idempotent.
    """
    async with _sessions_lock:
        session = _upload_sessions.get(upload_id)
    if not session:
        raise HTTPException(404, f"upload_id not found or expired: {upload_id}")
    if session["status"] not in ("chunks_pending", "finalizing"):
        raise HTTPException(409, f"Upload in wrong state: {session['status']}")
    if not (0 <= chunk_index < session["total_chunks"]):
        raise HTTPException(400, f"chunk_index {chunk_index} out of range.")

    # ── Read chunk into memory ────────────────────────────────────────────────
    # 16 MB max.  We need it all in RAM to split into 512 KB Telegram parts.
    chunk_bytes = await chunk_data.read()
    if not chunk_bytes:
        raise HTTPException(400, f"chunk_index {chunk_index} has empty body.")

    # ── Get the persistent TelegramClient for this upload ────────────────────
    async with _clients_lock:
        client = _tg_clients.get(upload_id)

    if not client:
        raise HTTPException(
            500,
            "Upload client not found. The server may have restarted. "
            "Please start a new upload.",
        )

    # ── Reconnect if needed (auto_reconnect handles most cases) ───────────────
    try:
        if not client.is_connected():
            await client.connect()
            if not await client.is_user_authorized():
                raise HTTPException(401, "Telegram session expired during upload.")
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(500, f"Telegram reconnect failed: {e}")

    # ── Calculate Telegram part offset for this HTTP chunk ────────────────────
    # Each 16 MB HTTP chunk = HTTP_CHUNK_SIZE / TELEGRAM_PART_SIZE = 32 parts.
    # Chunk 0 → parts  0–31
    # Chunk 1 → parts 32–63
    # Chunk N → parts N*32 … N*32+31   (last chunk may have fewer parts)
    parts_per_http_chunk = HTTP_CHUNK_SIZE // TELEGRAM_PART_SIZE  # = 32
    part_offset = chunk_index * parts_per_http_chunk

    # ── Relay parts to Telegram ───────────────────────────────────────────────
    try:
        await _relay_chunk_parts(
            client=client,
            tg_file_id=session["tg_file_id"],
            total_tg_parts=session["total_tg_parts"],
            use_big_file=session["use_big_file"],
            chunk_bytes=chunk_bytes,
            part_offset=part_offset,
        )
    except Exception as e:
        raise HTTPException(500, f"Telegram relay failed for chunk {chunk_index}: {e}")

    # ── Mark chunk as received ────────────────────────────────────────────────
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
    All parts are already on Telegram's servers (uploaded during /upload/chunk).
    This endpoint calls send_file with the pre-uploaded InputFileBig reference.

    This is INSTANT (<500 ms) because:
      - The file bytes are already in Telegram's data center.
      - send_file with an InputFileBig/InputFile just creates the message
        metadata — no byte transfer happens.

    Returns {status:"done", message_id:X} directly.
    No background task.  No polling needed (but /upload/status still works).

    Idempotent: calling again after "done" returns the same message_id.
    On "error": resets and retries the sendMedia call (parts persist ~24h).
    """
    async with _sessions_lock:
        session = _upload_sessions.get(upload_id)
    if not session:
        raise HTTPException(404, f"upload_id not found or expired: {upload_id}")

    # ── Idempotency ───────────────────────────────────────────────────────────
    if session["status"] == "done":
        return {
            "status":     "done",
            "upload_id":  upload_id,
            "message_id": session["message_id"],
        }
    if session["status"] == "finalizing":
        # Another request is already finalizing — return current state
        return {"status": "finalizing", "upload_id": upload_id}

    # ── On error: reset so we can retry sendMedia ─────────────────────────────
    # The Telegram parts are still valid for ~24 h — no re-upload needed.
    if session["status"] == "error":
        async with _sessions_lock:
            if upload_id in _upload_sessions:
                _upload_sessions[upload_id]["status"]  = "chunks_pending"
                _upload_sessions[upload_id]["error"]   = None
                _upload_sessions[upload_id]["done_at"] = None

    # ── Verify all chunks were received and relayed ───────────────────────────
    async with _sessions_lock:
        received = set(_upload_sessions[upload_id]["received"])
        total    = _upload_sessions[upload_id]["total_chunks"]
    missing = [i for i in range(total) if i not in received]
    if missing:
        raise HTTPException(
            400,
            f"{len(missing)} chunk(s) missing (first few: {missing[:10]}). "
            "Re-upload missing chunks before finalizing.",
        )

    # ── Mark finalizing ───────────────────────────────────────────────────────
    async with _sessions_lock:
        _upload_sessions[upload_id]["status"] = "finalizing"

    # ── Get the persistent TelegramClient ─────────────────────────────────────
    async with _clients_lock:
        client = _tg_clients.get(upload_id)

    if not client:
        # Client was lost (e.g. server restart between chunks and finalize).
        # Recreate it — the parts are still on Telegram's servers.
        client = make_client(session_string, for_upload=True)
        try:
            await client.connect()
        except Exception as e:
            async with _sessions_lock:
                if upload_id in _upload_sessions:
                    _upload_sessions[upload_id].update({
                        "status":  "error",
                        "error":   f"Reconnect failed: {e}",
                        "done_at": time.monotonic(),
                    })
            raise HTTPException(500, f"Could not reconnect to Telegram: {e}")
        async with _clients_lock:
            _tg_clients[upload_id] = client

    # Ensure connected
    try:
        if not client.is_connected():
            await client.connect()
        if not await client.is_user_authorized():
            raise RuntimeError("Telegram session expired.")
    except Exception as e:
        async with _sessions_lock:
            if upload_id in _upload_sessions:
                _upload_sessions[upload_id].update({
                    "status":  "error",
                    "error":   str(e),
                    "done_at": time.monotonic(),
                })
        raise HTTPException(401, f"Telegram session error: {e}")

    # ── Build the file reference (NO upload — parts already on Telegram) ──────
    tg_file_id     = session["tg_file_id"]
    total_tg_parts = session["total_tg_parts"]
    filename       = session["filename"]
    mime_type      = session["mime_type"]

    if session["use_big_file"]:
        file_ref = InputFileBig(
            id=tg_file_id,
            parts=total_tg_parts,
            name=filename,
        )
    else:
        file_ref = InputFile(
            id=tg_file_id,
            parts=total_tg_parts,
            name=filename,
            md5_checksum="",
        )

    # ── Call send_file with the pre-uploaded reference (INSTANT) ─────────────
    # Telethon detects InputFileBig/InputFile and skips the upload step.
    # It only creates the Telegram message — completes in <500 ms.
    try:
        message = await client.send_file(
            "me",
            file=file_ref,
            caption=caption or filename,
            force_document=True,
            attributes=[DocumentAttributeFilename(file_name=filename)],
        )
    except Exception as e:
        async with _sessions_lock:
            if upload_id in _upload_sessions:
                _upload_sessions[upload_id].update({
                    "status":  "error",
                    "error":   str(e),
                    "done_at": time.monotonic(),
                })
        raise HTTPException(500, f"sendMedia failed: {e}")

    # ── Mark done ─────────────────────────────────────────────────────────────
    async with _sessions_lock:
        if upload_id in _upload_sessions:
            _upload_sessions[upload_id].update({
                "status":     "done",
                "message_id": message.id,
                "done_at":    time.monotonic(),
            })

    # ── Cleanup ───────────────────────────────────────────────────────────────
    async with _clients_lock:
        _tg_clients.pop(upload_id, None)
    try:
        await client.disconnect()
    except Exception:
        pass
    gc.collect()

    return {
        "status":     "done",
        "upload_id":  upload_id,
        "message_id": message.id,
    }


@app.get("/upload/status/{upload_id}")
async def upload_status(upload_id: str):
    """
    Poll the status of an upload.

    In v5.0, finalize is synchronous so the first poll after finalize
    always returns "done".  This endpoint exists for backward compatibility
    with Flutter clients that still poll after finalize.

    Response:
      {status: "chunks_pending"|"finalizing"|"done"|"error",
       message_id: int|null,
       error: str|null}
    """
    async with _sessions_lock:
        session = _upload_sessions.get(upload_id)
    if not session:
        raise HTTPException(
            404,
            "Upload session not found. It may have completed and been cleaned up, "
            "or the session ID is invalid.",
        )
    return {
        "status":     session["status"],
        "message_id": session.get("message_id"),
        "error":      session.get("error"),
    }


# ══════════════════════════════════════════════════════════════════════════════
# LEGACY single-shot upload  (kept for backward compat with old app builds)
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


# ══════════════════════════════════════════════════════════════════════════════
# URL UPLOAD
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
            raw_name = (parsed.path.split("/")[-1]) or "download"
            from urllib.parse import unquote as _unq
            raw_name = _unq(raw_name)
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


# ══════════════════════════════════════════════════════════════════════════════
# FILE LIST / DOWNLOAD / DELETE
# ══════════════════════════════════════════════════════════════════════════════

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
    """Stream a single Telegram message in 512 KB blocks — never fully in RAM."""
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
    Stream multiple Telegram messages as ONE contiguous byte stream.
    Reconstructs files that were uploaded as multiple 1.95 GB segments.
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
    async with _clients_lock:
        active_clients = len(_tg_clients)
    return {
        "status":             "ok",
        "version":            "5.0.0",
        "api_id":             API_ID,
        "active_sessions":    session_count,
        "active_tg_clients":  active_clients,
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
        timeout_keep_alive=300,
    )
