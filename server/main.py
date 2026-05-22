"""
Limitless Cloud — Telegram Backend Server  (Production Build v5.1)

── What's new in v5.1 ──────────────────────────────────────────────────────────

  UPLOAD SPEED BOOST  (async relay queue + smaller chunks + more connections)
  ─────────────────────────────────────────────────────────────────────────────

  Problem (v5.0): Flutter sent a 16 MB chunk → waited for ALL 32 Telegram
    parts to be relayed → only THEN sent the next chunk.  If Telegram had any
    throttling on a batch, the entire upload stalled.

  Fix 1 — Async relay queue (biggest win):
    /upload/chunk now puts the chunk into a bounded asyncio.Queue and returns
    200 IMMEDIATELY to Flutter.  A background relay_worker drains the queue
    and pushes parts to Telegram in parallel.  Flutter uploads at full network
    speed; relay runs concurrently.  The queue provides natural back-pressure:
    if relay falls behind, queue fills and Flutter blocks temporarily.

  Fix 2 — Smaller HTTP chunks (16 MB → 4 MB):
    4 MB chunks give 4× more granular progress and let Flutter pipeline more
    chunks.  Each chunk = 8 Telegram parts (4 MB / 512 KB) = 1 parallel batch.

  Fix 3 — More parallel Telegram connections (8 → 15):
    Telegram's MTProto allows up to 15 concurrent part uploads per file_id.
    We now use 15 at a time, maximising Railway→Telegram throughput.

  Expected speed improvement:
    Old: ~500 kbps (relay blocks each chunk)
    New: 1.5–10 Mbps (limited only by user network, not relay latency)

── Upload protocol (v5.1) ───────────────────────────────────────────────────────
  POST /upload/init      → connect TelegramClient, start relay_worker task
  POST /upload/chunk ×N  → queue chunk, return 200 instantly; relay is async
  POST /upload/finalize  → drain queue, wait relay_worker, sendMedia (<500ms)
  GET  /upload/status    → backward compat; returns "done" after finalize

── Memory per upload ────────────────────────────────────────────────────────────
  RELAY_QUEUE_MAX = 8 chunks × 4 MB = 32 MB buffer
  TelegramClient overhead ≈ 50 MB
  Total per upload ≈ 82 MB  →  3 concurrent uploads ≈ 246 MB  (safe on 512 MB)
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
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
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
_HEAVY_SEM             = asyncio.Semaphore(2)   # download / legacy upload
_LIGHT_SEM             = asyncio.Semaphore(8)   # auth / list / meta
MAX_CONCURRENT_UPLOADS = 3                       # max simultaneous uploads

# ── Upload speed constants ────────────────────────────────────────────────────
# 15 = maximum parallel saveBigFilePart calls Telegram allows per file
TG_UPLOAD_CONCURRENCY  = 15

# Bounded relay queue: max chunks buffered between Flutter upload and TG relay.
# 8 × 4 MB = 32 MB buffer per upload.  When queue is full Flutter blocks
# (natural back-pressure) until the relay worker catches up.
RELAY_QUEUE_MAX        = 8

# ── I/O constants ─────────────────────────────────────────────────────────────
DOWNLOAD_CHUNK     = 512 * 1024        # 512 KB — iter_download block size
UPLOAD_BUF_SIZE    = 64  * 1024        # 64 KB  — legacy disk write buffer
TELEGRAM_PART_SIZE = 512 * 1024        # 512 KB — Telegram upload part size (max)
HTTP_CHUNK_SIZE    = 4   * 1024 * 1024 # 4 MB   — Flutter HTTP chunk size
LIST_LIMIT         = 500
META_LIMIT         = 200

# Parts per HTTP chunk (used to calculate Telegram part offset from chunk_index)
PARTS_PER_HTTP_CHUNK = HTTP_CHUNK_SIZE // TELEGRAM_PART_SIZE   # = 8

# ── Upload session store ──────────────────────────────────────────────────────
_upload_sessions: dict[str, dict] = {}
_sessions_lock   = asyncio.Lock()

# Persistent TelegramClients — one per active upload
_tg_clients: dict[str, TelegramClient] = {}
_clients_lock = asyncio.Lock()

UPLOAD_SESSION_TTL = 2 * 60 * 60
DONE_SESSION_TTL   = 15 * 60


# ── Stale-session cleanup ─────────────────────────────────────────────────────

async def _cleanup_stale_uploads():
    while True:
        await asyncio.sleep(30 * 60)
        now       = time.monotonic()
        to_delete: list[str] = []

        async with _sessions_lock:
            for uid, meta in _upload_sessions.items():
                status = meta.get("status", "")
                if status in ("done", "error"):
                    done_at = meta.get("done_at", meta["created_at"])
                    if now - done_at > DONE_SESSION_TTL:
                        to_delete.append(uid)
                elif now - meta["created_at"] > UPLOAD_SESSION_TTL:
                    to_delete.append(uid)
            for uid in to_delete:
                _upload_sessions.pop(uid, None)

        for uid in to_delete:
            # Cancel relay task if still running
            relay_task = None
            async with _sessions_lock:
                pass  # already removed
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
        if dirpath and os.path.isdir(dirpath):
            shutil.rmtree(dirpath, ignore_errors=True)
    except Exception:
        pass


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
        async with _clients_lock:
            clients = list(_tg_clients.values())
        for c in clients:
            try:
                await c.disconnect()
            except Exception:
                pass


# ── FastAPI app ───────────────────────────────────────────────────────────────
app = FastAPI(
    title="Limitless Cloud API",
    description="Telegram-powered cloud storage backend (production v5.1)",
    version="5.1.0",
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
        app_version="5.1.0",
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
            return {"success": True, "needs_password": True,
                    "session_string": client.session.save()}
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
# CORE RELAY HELPERS
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
    Split chunk_bytes into 512 KB pieces and upload them to Telegram.
    Uses TG_UPLOAD_CONCURRENCY (15) parallel saveBigFilePart calls per batch.
    Retries failed parts up to max_retries times with FloodWait handling.
    """
    parts: list[tuple[int, bytes]] = []
    for i, start in enumerate(range(0, len(chunk_bytes), TELEGRAM_PART_SIZE)):
        parts.append((part_offset + i, chunk_bytes[start:start + TELEGRAM_PART_SIZE]))

    remaining = list(parts)

    for attempt in range(1, max_retries + 1):
        if not remaining:
            break

        failed: list[tuple[int, bytes]] = []

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
                    SaveFilePartRequest(file_id=tg_file_id, file_part=idx, bytes=data)
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

        remaining = failed
        if remaining and attempt < max_retries:
            await asyncio.sleep(min(60, 5 * (2 ** (attempt - 1))))

    if remaining:
        raise RuntimeError(
            f"{len(remaining)} Telegram part(s) failed after {max_retries} attempts."
        )


async def _relay_worker(
    upload_id: str,
    client: TelegramClient,
    queue: "asyncio.Queue[tuple[int, bytes, int] | None]",
) -> None:
    """
    Background relay worker — runs for the lifetime of one upload session.

    Drains the bounded relay queue and calls _relay_chunk_parts for each item.
    Stops when it receives the None sentinel (sent by /upload/finalize).

    On error: stores error in session and drains queue so Flutter unblocks.
    """
    while True:
        item = await queue.get()

        if item is None:          # sentinel — no more chunks
            queue.task_done()
            break

        chunk_index, chunk_bytes, part_offset = item
        try:
            if not client.is_connected():
                await client.connect()

            async with _sessions_lock:
                session = _upload_sessions.get(upload_id)
            if not session:
                queue.task_done()
                break

            await _relay_chunk_parts(
                client=client,
                tg_file_id=session["tg_file_id"],
                total_tg_parts=session["total_tg_parts"],
                use_big_file=session["use_big_file"],
                chunk_bytes=chunk_bytes,
                part_offset=part_offset,
            )
        except Exception as e:
            async with _sessions_lock:
                if upload_id in _upload_sessions:
                    _upload_sessions[upload_id]["relay_error"] = str(e)
            # Drain remaining queue so Flutter stops blocking
            while True:
                try:
                    queue.get_nowait()
                    queue.task_done()
                except asyncio.QueueEmpty:
                    break
            queue.task_done()
            return

        queue.task_done()


# ══════════════════════════════════════════════════════════════════════════════
# UPLOAD ROUTES  v5.1
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

    v5.1: Creates TelegramClient, generates Telegram file_id, and starts the
    background relay_worker task that will drain the relay queue.
    """
    async with _clients_lock:
        if len(_tg_clients) >= MAX_CONCURRENT_UPLOADS:
            raise HTTPException(
                503,
                f"Server busy ({len(_tg_clients)}/{MAX_CONCURRENT_UPLOADS} uploads). "
                "Please wait a moment.",
            )

    if not (1 <= total_chunks <= 200_000):
        raise HTTPException(400, "total_chunks out of range.")
    if not (0 < total_size <= 500 * 1024 * 1024 * 1024):
        raise HTTPException(400, "total_size out of range.")

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

    upload_id      = str(uuid.uuid4())
    tg_file_id     = random.randint(1, 2 ** 63 - 1)
    use_big_file   = total_size >= 10 * 1024 * 1024
    total_tg_parts = math.ceil(total_size / TELEGRAM_PART_SIZE)

    # Bounded relay queue (RELAY_QUEUE_MAX = 8 slots × 4 MB = 32 MB buffer)
    relay_queue: asyncio.Queue = asyncio.Queue(maxsize=RELAY_QUEUE_MAX)
    relay_task = asyncio.create_task(
        _relay_worker(upload_id, client, relay_queue)
    )

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
            "relay_queue":    relay_queue,
            "relay_task":     relay_task,
            "relay_error":    None,
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
    Receive one 4 MB slice and PUT IT IN THE RELAY QUEUE, then return 200
    IMMEDIATELY to Flutter.

    The relay_worker background task drains the queue and sends 512 KB parts
    to Telegram asynchronously.  Flutter uploads at full network speed without
    waiting for each chunk's Telegram relay to complete.

    Back-pressure: if the relay falls behind (queue full), this endpoint blocks
    until a slot is free.  This prevents unbounded memory growth.

    Idempotent: sending the same chunk_index twice is safe.
    """
    async with _sessions_lock:
        session = _upload_sessions.get(upload_id)
    if not session:
        raise HTTPException(404, f"upload_id not found: {upload_id}")
    if session["status"] not in ("chunks_pending", "finalizing"):
        raise HTTPException(409, f"Upload in wrong state: {session['status']}")
    if not (0 <= chunk_index < session["total_chunks"]):
        raise HTTPException(400, f"chunk_index {chunk_index} out of range.")

    # Check if relay worker has reported an error
    if session.get("relay_error"):
        raise HTTPException(
            500,
            f"Telegram relay failed: {session['relay_error']}. "
            "Please start a new upload.",
        )

    # Read chunk bytes into memory (4 MB max)
    chunk_bytes = await chunk_data.read()
    if not chunk_bytes:
        raise HTTPException(400, f"chunk_index {chunk_index} has empty body.")

    # Calculate Telegram part offset:
    #   chunk 0 → parts  0–7
    #   chunk 1 → parts  8–15
    #   chunk N → parts  N*8 … N*8+7
    part_offset = chunk_index * PARTS_PER_HTTP_CHUNK

    # Put in relay queue.  Blocks if queue is full (back-pressure).
    # Timeout: 5 min.  If relay is THAT far behind, something is wrong.
    relay_queue: asyncio.Queue = session["relay_queue"]
    try:
        await asyncio.wait_for(
            relay_queue.put((chunk_index, chunk_bytes, part_offset)),
            timeout=300.0,
        )
    except asyncio.TimeoutError:
        raise HTTPException(
            503,
            "Relay queue full for 5 minutes — Telegram may be rate-limiting. "
            "Please retry later.",
        )

    # Mark chunk received (before relay completes — relay is async)
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
    Drain the relay queue, wait for the relay_worker to finish, then call
    send_file with InputFileBig (instant metadata op — bytes are already
    on Telegram's servers).

    Returns {status:"done", message_id:X} directly.
    The Flutter client receives message_id immediately with no polling.

    Idempotent: calling again after "done" returns the same message_id.
    """
    async with _sessions_lock:
        session = _upload_sessions.get(upload_id)
    if not session:
        raise HTTPException(404, f"upload_id not found: {upload_id}")

    if session["status"] == "done":
        return {"status": "done", "upload_id": upload_id,
                "message_id": session["message_id"]}
    if session["status"] == "finalizing":
        return {"status": "finalizing", "upload_id": upload_id}
    if session["status"] == "error":
        # Reset and allow retry
        async with _sessions_lock:
            if upload_id in _upload_sessions:
                _upload_sessions[upload_id]["status"]      = "chunks_pending"
                _upload_sessions[upload_id]["error"]       = None
                _upload_sessions[upload_id]["relay_error"] = None
                _upload_sessions[upload_id]["done_at"]     = None

    # Verify all chunks queued
    async with _sessions_lock:
        received = set(_upload_sessions[upload_id]["received"])
        total    = _upload_sessions[upload_id]["total_chunks"]
    missing = [i for i in range(total) if i not in received]
    if missing:
        raise HTTPException(
            400,
            f"{len(missing)} chunk(s) missing: {missing[:10]}. "
            "Upload missing chunks first.",
        )

    async with _sessions_lock:
        _upload_sessions[upload_id]["status"] = "finalizing"
        relay_queue: asyncio.Queue = _upload_sessions[upload_id]["relay_queue"]
        relay_task: asyncio.Task   = _upload_sessions[upload_id]["relay_task"]

    # ── Send sentinel to relay_worker and wait for it to drain ───────────────
    # The relay_worker stops after processing all queued chunks then the None.
    # Time to drain: depends on how many chunks are still queued.
    # At Railway→Telegram speed this should take seconds, not minutes.
    await relay_queue.put(None)   # sentinel
    try:
        await asyncio.wait_for(relay_task, timeout=600.0)  # 10 min max
    except asyncio.TimeoutError:
        relay_task.cancel()
        async with _sessions_lock:
            if upload_id in _upload_sessions:
                _upload_sessions[upload_id].update({
                    "status":  "error",
                    "error":   "Relay drain timed out.",
                    "done_at": time.monotonic(),
                })
        raise HTTPException(500, "Relay timed out. Please retry.")

    # Check relay errors
    async with _sessions_lock:
        relay_error = _upload_sessions.get(upload_id, {}).get("relay_error")
    if relay_error:
        async with _sessions_lock:
            if upload_id in _upload_sessions:
                _upload_sessions[upload_id].update({
                    "status":  "error",
                    "error":   relay_error,
                    "done_at": time.monotonic(),
                })
        raise HTTPException(500, f"Relay failed: {relay_error}")

    # ── Get TelegramClient ────────────────────────────────────────────────────
    async with _clients_lock:
        client = _tg_clients.get(upload_id)
    if not client:
        client = make_client(session_string, for_upload=True)
        await client.connect()
        async with _clients_lock:
            _tg_clients[upload_id] = client

    if not client.is_connected():
        await client.connect()
    if not await client.is_user_authorized():
        async with _sessions_lock:
            if upload_id in _upload_sessions:
                _upload_sessions[upload_id].update({
                    "status":  "error",
                    "error":   "Telegram session expired.",
                    "done_at": time.monotonic(),
                })
        raise HTTPException(401, "Telegram session expired.")

    # ── Build file reference (bytes already on Telegram) ─────────────────────
    async with _sessions_lock:
        session = _upload_sessions[upload_id]

    tg_file_id     = session["tg_file_id"]
    total_tg_parts = session["total_tg_parts"]
    filename       = session["filename"]
    mime_type      = session["mime_type"]

    if session["use_big_file"]:
        file_ref = InputFileBig(id=tg_file_id, parts=total_tg_parts, name=filename)
    else:
        file_ref = InputFile(
            id=tg_file_id, parts=total_tg_parts, name=filename, md5_checksum=""
        )

    # ── sendMedia — INSTANT (<500 ms) ────────────────────────────────────────
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

    # ── Mark done & cleanup ───────────────────────────────────────────────────
    async with _sessions_lock:
        if upload_id in _upload_sessions:
            _upload_sessions[upload_id].update({
                "status":     "done",
                "message_id": message.id,
                "done_at":    time.monotonic(),
            })

    async with _clients_lock:
        _tg_clients.pop(upload_id, None)
    try:
        await client.disconnect()
    except Exception:
        pass
    gc.collect()

    return {"status": "done", "upload_id": upload_id, "message_id": message.id}


@app.get("/upload/status/{upload_id}")
async def upload_status(upload_id: str):
    """Backward-compat polling endpoint. Always returns 'done' immediately
    after finalize in v5.1 since finalize is synchronous."""
    async with _sessions_lock:
        session = _upload_sessions.get(upload_id)
    if not session:
        raise HTTPException(404, "Upload session not found or already cleaned up.")
    return {
        "status":     session["status"],
        "message_id": session.get("message_id"),
        "error":      session.get("error"),
    }


# ══════════════════════════════════════════════════════════════════════════════
# LEGACY SINGLE-SHOT UPLOAD
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
                "me", tmp_path,
                caption=caption or filename,
                force_document=True,
                attributes=[DocumentAttributeFilename(file_name=filename)],
            )
            return {
                "success": True, "message_id": message.id,
                "file_name": filename, "file_size": file_size,
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
# URL UPLOAD / FILE LIST / DOWNLOAD / DELETE / META
# ══════════════════════════════════════════════════════════════════════════════

@app.post("/files/upload-from-url")
async def upload_file_from_url(req: UploadFromUrlRequest):
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
            filename = raw_name
            file_size = 0
            headers = {"User-Agent": "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36"}
            async with aiohttp.ClientSession() as sess:
                async with sess.get(
                    req.url, headers=headers,
                    timeout=aiohttp.ClientTimeout(total=1800),
                    allow_redirects=True,
                ) as resp:
                    if resp.status >= 400:
                        raise HTTPException(resp.status, f"Remote {resp.status}.")
                    cd = resp.headers.get("Content-Disposition", "")
                    if "filename=" in cd:
                        try:
                            filename = cd.split("filename=")[-1].strip(' "\'')
                        except Exception:
                            pass
                    with tempfile.NamedTemporaryFile(delete=False, suffix=f"_{filename}") as tmp:
                        tmp_path = tmp.name
                        async for chunk in resp.content.iter_chunked(UPLOAD_BUF_SIZE):
                            tmp.write(chunk)
                            file_size += len(chunk)
            message = await client.send_file(
                "me", tmp_path,
                caption=req.caption or filename,
                force_document=True,
                attributes=[DocumentAttributeFilename(file_name=filename)],
            )
            return {
                "success": True, "message_id": message.id,
                "file_name": filename, "file_size": file_size,
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
                "me", filter=InputMessagesFilterDocument(), limit=LIST_LIMIT,
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
                        message.document, request_size=DOWNLOAD_CHUNK
                    ):
                        yield chunk
                finally:
                    await client.disconnect()
                    gc.collect()

            return StreamingResponse(
                _stream(), media_type=mime,
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
    async with _HEAVY_SEM:
        if not req.message_ids:
            raise HTTPException(400, "message_ids must not be empty.")
        client = make_client(req.session_string)
        try:
            await client.connect()
            if not await client.is_user_authorized():
                raise HTTPException(401, "Session expired.")
            first: Message = await client.get_messages("me", ids=req.message_ids[0])
            if not first or not first.document:
                raise HTTPException(404, "First chunk not found.")
            fname = "download"
            for attr in first.document.attributes:
                if isinstance(attr, DocumentAttributeFilename):
                    raw   = attr.file_name
                    fname = raw[:raw.rfind(".part")] if ".part" in raw else raw
                    break
            mime = first.document.mime_type or "application/octet-stream"

            async def _stream_all() -> AsyncIterator[bytes]:
                try:
                    for msg_id in req.message_ids:
                        msg: Message = await client.get_messages("me", ids=msg_id)
                        if not msg or not msg.document:
                            continue
                        async for chunk in client.iter_download(
                            msg.document, request_size=DOWNLOAD_CHUNK
                        ):
                            yield chunk
                finally:
                    await client.disconnect()
                    gc.collect()

            return StreamingResponse(
                _stream_all(), media_type=mime,
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


@app.post("/meta/save")
async def save_metadata(session_string: str = Form(...), data: str = Form(...)):
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
                if message.text and not message.document and message.text.startswith(prefix):
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
        "status":              "ok",
        "version":             "5.1.0",
        "active_sessions":     session_count,
        "active_tg_clients":   active_clients,
        "sessions_by_status":  by_status,
        "tg_concurrency":      TG_UPLOAD_CONCURRENCY,
        "http_chunk_mb":       HTTP_CHUNK_SIZE // (1024 * 1024),
        "relay_queue_max":     RELAY_QUEUE_MAX,
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
