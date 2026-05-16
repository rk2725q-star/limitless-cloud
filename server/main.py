"""
Limitless Cloud - Telegram Backend Server
Uses Telethon (MTProto) to authenticate users and manage Saved Messages.

Run with:
    pip install -r requirements.txt
    python main.py

The server runs on http://localhost:8000
"""

import asyncio
import io
import os
import tempfile
from contextlib import asynccontextmanager
from typing import Optional

import uvicorn
from fastapi import FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
from telethon import TelegramClient, events
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
    InputMessagesFilterPhotos,
    InputMessagesFilterVideo,
    Message,
)

# ── Telegram API credentials ──────────────────────────────────────────────────
API_ID = 36148181
API_HASH = "cf8e8509b0ceaf5b229ad47f59b79e6e"

# ── FastAPI app ───────────────────────────────────────────────────────────────
app = FastAPI(
    title="Limitless Cloud API",
    description="Telegram-powered cloud storage backend",
    version="1.0.0",
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
    phone: str          # e.g. "+919876543210"

class VerifyCodeRequest(BaseModel):
    phone: str
    phone_code_hash: str
    code: str                       # 5-digit code from Telegram
    session_string: str = ""        # partial session from /send-code — MUST be passed back


class VerifyPasswordRequest(BaseModel):
    session_string: str
    password: str       # 2FA cloud password

class CheckSessionRequest(BaseModel):
    session_string: str

class DeleteFileRequest(BaseModel):
    session_string: str
    message_id: int

# ── Helper: build a short-lived client from session string ────────────────────

def make_client(session_string: str = "") -> TelegramClient:
    return TelegramClient(
        StringSession(session_string),
        API_ID,
        API_HASH,
        system_version="4.16.30-vxCUSTOM",
        app_version="1.0.0",
        device_model="Limitless Cloud",
    )

# ── Auth routes ───────────────────────────────────────────────────────────────

@app.post("/auth/send-code")
async def send_code(req: SendCodeRequest):
    """
    Step 1: Send OTP to the user's Telegram-linked phone number.
    Returns phone_code_hash needed for the next step.
    """
    client = make_client()
    try:
        await client.connect()
        result = await client.send_code_request(req.phone)
        # We return a temporary session so the client keeps the same MTProto
        # connection key for the subsequent sign-in call.
        session_string = client.session.save()
        return {
            "success": True,
            "phone_code_hash": result.phone_code_hash,
            "session_string": session_string,  # partial session – not yet authed
        }
    except PhoneNumberInvalidError:
        raise HTTPException(status_code=400, detail="Invalid phone number.")
    except FloodWaitError as e:
        raise HTTPException(status_code=429, detail=f"Too many requests. Wait {e.seconds}s.")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        await client.disconnect()


@app.post("/auth/verify-code")
async def verify_code(req: VerifyCodeRequest):
    """
    Step 2: Verify the OTP the user received on Telegram.
    IMPORTANT: Pass back the session_string returned by /send-code so Telethon
    reuses the same Telegram DC — otherwise the code is seen as expired.
    On success returns a full session_string. On 2FA returns needs_password=true.
    """
    # Reuse the partial session from send-code (same DC = same auth state)
    client = make_client(req.session_string)
    try:
        await client.connect()
        result = await client.sign_in(
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
        # 2FA is enabled — client must call /auth/verify-2fa next
        session_string = client.session.save()
        return {
            "success": True,
            "needs_password": True,
            "session_string": session_string,
        }
    except PhoneCodeInvalidError:
        raise HTTPException(status_code=400, detail="Invalid verification code.")
    except PhoneCodeExpiredError:
        raise HTTPException(status_code=400, detail="Code expired. Request a new one.")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        await client.disconnect()



@app.post("/auth/verify-2fa")
async def verify_2fa(req: VerifyPasswordRequest):
    """
    Step 3 (optional): Complete 2FA for accounts with cloud password set.
    """
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
        raise HTTPException(status_code=400, detail="Wrong 2FA password.")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        await client.disconnect()


@app.post("/auth/check-session")
async def check_session(req: CheckSessionRequest):
    """Check whether a stored session_string is still valid."""
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


@app.post("/auth/logout")
async def logout(req: CheckSessionRequest):
    """Revoke the session on Telegram's servers."""
    client = make_client(req.session_string)
    try:
        await client.connect()
        await client.log_out()
        return {"success": True}
    except Exception as e:
        return {"success": False, "error": str(e)}
    finally:
        await client.disconnect()


# ── File routes ───────────────────────────────────────────────────────────────

@app.post("/files/upload")
async def upload_file(
    session_string: str = Form(...),
    file: UploadFile = File(...),
    caption: str = Form(default=""),
):
    """
    Upload a file to the authenticated user's Saved Messages.
    Returns the Telegram message_id that acts as the file's unique ID.
    """
    client = make_client(session_string)
    try:
        await client.connect()
        if not await client.is_user_authorized():
            raise HTTPException(status_code=401, detail="Session expired.")

        file_bytes = await file.read()
        file_size = len(file_bytes)
        filename = file.filename or "upload"

        # Upload using in-memory BytesIO so no temp files needed on server
        file_io = io.BytesIO(file_bytes)
        file_io.name = filename  # Telethon reads .name for the filename attribute

        message = await client.send_file(
            "me",                    # "me" = Saved Messages
            file_io,
            caption=caption or filename,
            force_document=True,     # always send as document (not media-compressed)
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
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        await client.disconnect()


@app.get("/files/list")
async def list_files(session_string: str):
    """
    List all documents stored in the user's Saved Messages.
    Returns message id, filename, size, and date for each file.
    """
    client = make_client(session_string)
    try:
        await client.connect()
        if not await client.is_user_authorized():
            raise HTTPException(status_code=401, detail="Session expired.")

        files = []
        async for message in client.iter_messages(
            "me",
            filter=InputMessagesFilterDocument(),
            limit=200,
        ):
            if message.document:
                fname = "file"
                for attr in message.document.attributes:
                    if isinstance(attr, DocumentAttributeFilename):
                        fname = attr.file_name
                        break
                files.append({
                    "message_id": message.id,
                    "file_name": fname,
                    "file_size": message.document.size,
                    "mime_type": message.document.mime_type or "application/octet-stream",
                    "date": message.date.isoformat(),
                    "caption": message.message or "",
                })

        return {"success": True, "files": files}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        await client.disconnect()


@app.get("/files/download/{message_id}")
async def download_file(message_id: int, session_string: str):
    """
    Stream a file from Saved Messages back to the client.
    """
    client = make_client(session_string)
    try:
        await client.connect()
        if not await client.is_user_authorized():
            raise HTTPException(status_code=401, detail="Session expired.")

        message: Message = await client.get_messages("me", ids=message_id)
        if not message or not message.document:
            raise HTTPException(status_code=404, detail="File not found.")

        # Get filename and mime type
        fname = "download"
        for attr in message.document.attributes:
            if isinstance(attr, DocumentAttributeFilename):
                fname = attr.file_name
                break
        mime = message.document.mime_type or "application/octet-stream"

        # Download into memory buffer
        buf = io.BytesIO()
        await client.download_media(message, file=buf)
        buf.seek(0)

        await client.disconnect()

        return StreamingResponse(
            buf,
            media_type=mime,
            headers={"Content-Disposition": f'attachment; filename="{fname}"'},
        )
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.delete("/files/{message_id}")
async def delete_file(message_id: int, req: DeleteFileRequest):
    """Delete a file message from Saved Messages."""
    client = make_client(req.session_string)
    try:
        await client.connect()
        if not await client.is_user_authorized():
            raise HTTPException(status_code=401, detail="Session expired.")

        await client.delete_messages("me", [message_id])
        return {"success": True}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        await client.disconnect()


@app.get("/files/info/{message_id}")
async def file_info(message_id: int, session_string: str):
    """Get metadata for a single file."""
    client = make_client(session_string)
    try:
        await client.connect()
        if not await client.is_user_authorized():
            raise HTTPException(status_code=401, detail="Session expired.")

        message = await client.get_messages("me", ids=message_id)
        if not message or not message.document:
            raise HTTPException(status_code=404, detail="File not found.")

        fname = "file"
        for attr in message.document.attributes:
            if isinstance(attr, DocumentAttributeFilename):
                fname = attr.file_name
                break

        return {
            "success": True,
            "message_id": message.id,
            "file_name": fname,
            "file_size": message.document.size,
            "mime_type": message.document.mime_type or "application/octet-stream",
            "date": message.date.isoformat(),
        }
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        await client.disconnect()


# ── Health check ──────────────────────────────────────────────────────────────

@app.get("/health")
async def health():
    return {"status": "ok", "api_id": API_ID}


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
