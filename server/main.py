"""
Limitless Cloud - Telegram Backend Server  (Memory-Optimised Build)
Uses Telethon (MTProto) to authenticate users and manage Saved Messages.

Memory budget target: ≤ 450 MB peak on Railway free plan (512 MB limit).

Key optimisations
─────────────────
• Upload  : chunked streaming read (64 KB blocks) → temp file → Telethon reads
            directly from disk; no double-copy in RAM.
• Download: async generator yields 512 KB chunks directly from Telethon's
            download_media iter_download — file never fully in RAM.
• Lists   : hard caps (files=100, meta=200) to bound list size.
• Concurrency: asyncio.Semaphore(4) per heavy endpoint; Semaphore(8) overall.
• Telethon: connection_retries=1, request_retries=1, flood_sleep_threshold=0
            — avoids retry storms that spike RAM.
• GC      : gc.collect() after each request in cleanup path.
• uvicorn : 1 worker, no reload, no hot-reloader threads.
"""

import asyncio
import gc
import os
import tempfile
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

# ── Memory-safety semaphores ──────────────────────────────────────────────────
# Heavy I/O ops (upload / download) are capped at 3 concurrent requests.
# Light ops (auth, list, meta) share a wider pool of 8.
_HEAVY_SEM = asyncio.Semaphore(3)
_LIGHT_SEM = asyncio.Semaphore(8)

CHUNK_SIZE      = 512 * 1024   # 512 KB – stream chunk for downloads
UPLOAD_BUF_SIZE = 64  * 1024   # 64 KB  – read chunk for uploads
LIST_LIMIT      = 200          # max files returned by /files/list
META_LIMIT      = 200          # max messages scanned by /meta/list

# ── FastAPI app ───────────────────────────────────────────────────────────────
app = FastAPI(
    title="Limitless Cloud API",
    description="Telegram-powered cloud storage backend (memory-optimised)",
    version="2.0.0",
    docs_url=None,   # disable Swagger UI in production to save a bit of RAM
    redoc_url=None,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Request / Response models ─────────────────────────────────────────────────

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


# ── Helper: build a short-lived, lean Telethon client ────────────────────────

def make_client(session_string: str = "") -> TelegramClient:
    """
    Build a Telethon client tuned for low memory:
    - connection_retries / request_retries = 1  → no retry loops holding sockets
    - flood_sleep_threshold = 0                 → raise immediately, don't sleep
    - auto_reconnect = False                    → we manage lifecycle manually
    """
    return TelegramClient(
        StringSession(session_string),
        API_ID,
        API_HASH,
        system_version="4.16.30-vxCUSTOM",
        app_version="2.0.0",
        device_model="Limitless Cloud",
        connection_retries=1,
        request_retries=1,
        flood_sleep_threshold=0,
        auto_reconnect=False,
    )


# ── Auth routes ───────────────────────────────────────────────────────────────

@app.post("/auth/send-code")
async def send_code(req: SendCodeRequest):
    """Step 1: Send OTP."""
    async with _LIGHT_SEM:
        client = make_client()
        try:
            await client.connect()
            result = await client.send_code_request(req.phone)
            session_string = client.session.save()
            return {
                "success": True,
                "phone_code_hash": result.phone_code_hash,
                "session_string": session_string,
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
    """Step 2: Verify OTP."""
    async with _LIGHT_SEM:
        client = make_client(req.session_string)
        try:
            await client.connect()
            await client.sign_in(
                phone=req.phone,
                code=req.code,
                phone_code_hash=req.phone_code_hash,
            )
            session_string = client.session.save()
            me = await client.get_me()
            return {
                "success": True,
                "needs_password": False,
                "session_string": session_string,
                "user_id": me.id,
                "first_name": me.first_name or "",
                "last_name": me.last_name or "",
                "phone": me.phone or req.phone,
                "username": me.username or "",
            }
        except SessionPasswordNeededError:
            session_string = client.session.save()
            return {"success": True, "needs_password": True, "session_string": session_string}
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
    """Step 3 (optional): 2FA cloud password."""
    async with _LIGHT_SEM:
        client = make_client(req.session_string)
        try:
            await client.connect()
            await client.sign_in(password=req.password)
            session_string = client.session.save()
            me = await client.get_me()
            return {
                "success": True,
                "session_string": session_string,
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
    """Check if a stored session_string is still valid."""
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
    """Revoke the session on Telegram's servers."""
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


# ── File routes ───────────────────────────────────────────────────────────────

@app.post("/files/upload")
async def upload_file(
    session_string: str = Form(...),
    file: UploadFile = File(...),
    caption: str = Form(default=""),
):
    """
    Upload a file to the user's Saved Messages.

    Memory strategy: stream the incoming multipart body in 64 KB chunks into a
    NamedTemporaryFile on disk. Telethon then reads directly from that file
    handle — the full file content is NEVER in RAM at once.
    """
    async with _HEAVY_SEM:
        client = make_client(session_string)
        tmp_path = None
        try:
            await client.connect()
            if not await client.is_user_authorized():
                raise HTTPException(401, "Session expired.")

            filename  = file.filename or "upload"
            file_size = 0

            # Stream multipart → temp file (no full file in RAM)
            with tempfile.NamedTemporaryFile(delete=False, suffix=f"_{filename}") as tmp:
                tmp_path = tmp.name
                while True:
                    chunk = await file.read(UPLOAD_BUF_SIZE)
                    if not chunk:
                        break
                    tmp.write(chunk)
                    file_size += len(chunk)

            # Telethon reads from disk – peak RAM = one internal Telethon chunk
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


class UploadFromUrlRequest(BaseModel):
    session_string: str
    url: str
    caption: str = ""


@app.post("/files/upload-from-url")
async def upload_file_from_url(req: UploadFromUrlRequest):
    """
    Fetch a remote URL server-side and upload the bytes to the user's
    Telegram Saved Messages — the file NEVER touches the phone.

    Memory strategy: stream the HTTP response in UPLOAD_BUF_SIZE (64 KB)
    chunks into a NamedTemporaryFile, then let Telethon read from disk.
    """
    async with _HEAVY_SEM:
        client = make_client(req.session_string)
        tmp_path = None
        try:
            await client.connect()
            if not await client.is_user_authorized():
                raise HTTPException(401, "Session expired.")

            # Derive a clean filename from the URL path
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
                    timeout=aiohttp.ClientTimeout(total=1800),  # 30 min cap
                    allow_redirects=True,
                ) as resp:
                    if resp.status >= 400:
                        raise HTTPException(
                            resp.status,
                            f"Remote server returned {resp.status} for URL."
                        )
                    # Try to get a real filename from Content-Disposition
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
    """
    List up to LIST_LIMIT (100) documents in Saved Messages.
    Iterates lazily — objects are appended one by one, not all pre-fetched.
    """
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
    Stream a file from Saved Messages to the client.

    Memory strategy: use Telethon's iter_download to yield CHUNK_SIZE (512 KB)
    blocks. The full file is NEVER in RAM; FastAPI streams each chunk directly
    to the HTTP response as it arrives from Telegram.
    The client must stay connected until the generator is exhausted, so we
    pass a reference and disconnect only inside the generator's finally block.
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
                        request_size=CHUNK_SIZE,
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
        # NOTE: do NOT disconnect here for the happy path — _stream() owns it.


@app.delete("/files/{message_id}")
async def delete_file(message_id: int, req: DeleteFileRequest):
    """Delete a file message from Saved Messages."""
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
    """Get metadata for a single file."""
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

LIMITLESS_PREFIX = "LIMITLESS_"


@app.post("/meta/save")
async def save_metadata(
    session_string: str = Form(...),
    data: str = Form(...),
):
    """Send a text message to Saved Messages containing app metadata."""
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
    """
    Return text messages in Saved Messages starting with `prefix`.
    Scans at most META_LIMIT (200) messages to bound memory.
    """
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
    """Delete a metadata text message from Saved Messages."""
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
    return {"status": "ok", "api_id": API_ID}


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=int(os.environ.get("PORT", 8000)),
        reload=False,        # NEVER use reload=True in production
        workers=1,           # single worker = predictable RAM ceiling
        loop="asyncio",
        http="h11",          # lighter than httptools
        log_level="warning", # reduce log-string allocations
    )
