import asyncio
import json
import logging
import os
import sys
import uuid
from datetime import datetime, timezone
from typing import Optional

import google.generativeai as genai
from fastapi import FastAPI, File, HTTPException, Response, UploadFile
from google.cloud import firestore, secretmanager, storage
from pydantic import BaseModel

GCP_PROJECT = os.environ["GCP_PROJECT"]
FIRESTORE_COLLECTION = os.environ["FIRESTORE_COLLECTION"]
FIRESTORE_DATABASE = os.environ["FIRESTORE_DATABASE"]
GCS_KNOWLEDGE_BUCKET = os.environ["GCS_KNOWLEDGE_BUCKET"]
GEMINI_SECRET_NAME = os.environ["GEMINI_SECRET_NAME"]

MODEL_NAME = os.environ.get("GEMINI_MODEL", "gemini-flash-lite-latest")
HISTORY_LIMIT = int(os.environ.get("CHAT_HISTORY_LIMIT", "10"))
MAX_MESSAGE_LENGTH = int(os.environ.get("CHAT_MAX_MESSAGE_LENGTH", "4000"))
MAX_KNOWLEDGE_FILE_SIZE = int(os.environ.get("KNOWLEDGE_MAX_FILE_SIZE", "5242880"))
KNOWLEDGE_OBJECT_NAME = "knowledge.txt"

_RESERVED_LOG_ATTRS = set(vars(logging.LogRecord("", 0, "", 0, "", (), None)).keys())


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "severity": record.levelname,
            "message": record.getMessage(),
            "logger": record.name,
        }
        for key, value in record.__dict__.items():
            if key not in _RESERVED_LOG_ATTRS and key != "message":
                payload[key] = value
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, default=str)


def configure_logging() -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(logging.INFO)


configure_logging()
logger = logging.getLogger("assistant.chat")

app = FastAPI(title="Assistant Chat API")

firestore_client = firestore.Client(project=GCP_PROJECT, database=FIRESTORE_DATABASE)
storage_client = storage.Client(project=GCP_PROJECT)


def load_gemini_api_key() -> str:
    client = secretmanager.SecretManagerServiceClient()
    name = f"projects/{GCP_PROJECT}/secrets/{GEMINI_SECRET_NAME}/versions/latest"
    response = client.access_secret_version(name=name)
    return response.payload.data.decode("utf-8")


# Lazily initialized on first use, not at import time — Cloud Run's startup
# health check just needs the HTTP server listening, and it shouldn't fail
# to boot just because the Gemini secret doesn't have a version yet (e.g.
# on the very first deploy, before the key has been added).
_model = None


def get_model():
    global _model
    if _model is None:
        try:
            genai.configure(api_key=load_gemini_api_key())
        except Exception as exc:
            raise HTTPException(
                status_code=503,
                detail="Gemini API key is not configured yet",
            ) from exc
        _model = genai.GenerativeModel(MODEL_NAME)
    return _model


class ChatRequest(BaseModel):
    session_id: Optional[str] = None
    message: str


def generate_reply(prompt: str) -> str:
    response = get_model().generate_content(prompt)
    return response.text


def load_knowledge_text() -> str:
    blob = storage_client.bucket(GCS_KNOWLEDGE_BUCKET).blob(KNOWLEDGE_OBJECT_NAME)
    if not blob.exists():
        return ""
    return blob.download_as_text()


@app.post("/chat")
async def chat(payload: ChatRequest):
    message = payload.message.strip()
    if not message:
        raise HTTPException(status_code=400, detail="message must not be empty")
    if len(message) > MAX_MESSAGE_LENGTH:
        raise HTTPException(
            status_code=400,
            detail=f"message must be at most {MAX_MESSAGE_LENGTH} characters",
        )

    session_id = payload.session_id or str(uuid.uuid4())
    doc_ref = firestore_client.collection(FIRESTORE_COLLECTION).document(session_id)
    doc = doc_ref.get()
    history = doc.to_dict().get("messages", []) if doc.exists else []

    history.append({"role": "user", "content": message, "timestamp": datetime.now(timezone.utc)})

    knowledge_text = await asyncio.to_thread(load_knowledge_text)
    conversation = "\n".join(f"{m['role']}: {m['content']}" for m in history[-HISTORY_LIMIT:])
    if knowledge_text:
        prompt = f"Knowledge base:\n{knowledge_text}\n\nConversation:\n{conversation}"
    else:
        prompt = conversation

    reply = await asyncio.to_thread(generate_reply, prompt)

    history.append({"role": "assistant", "content": reply, "timestamp": datetime.now(timezone.utc)})

    doc_ref.set(
        {
            "session_id": session_id,
            "messages": history,
            "updated_at": datetime.now(timezone.utc),
        }
    )

    logger.info("chat reply generated", extra={"session_id": session_id})
    return {"session_id": session_id, "reply": reply}


@app.post("/knowledge", status_code=204)
async def upload_knowledge(file: UploadFile = File(...)):
    contents = await file.read()
    if len(contents) > MAX_KNOWLEDGE_FILE_SIZE:
        raise HTTPException(
            status_code=400,
            detail=f"knowledge file must be at most {MAX_KNOWLEDGE_FILE_SIZE} bytes",
        )

    blob = storage_client.bucket(GCS_KNOWLEDGE_BUCKET).blob(KNOWLEDGE_OBJECT_NAME)
    blob.upload_from_string(contents, content_type=file.content_type or "text/plain")

    logger.info("knowledge file updated", extra={"size_bytes": len(contents)})
    return Response(status_code=204)


@app.get("/chat/{session_id}")
async def get_chat(session_id: str):
    doc = firestore_client.collection(FIRESTORE_COLLECTION).document(session_id).get()
    if not doc.exists:
        raise HTTPException(status_code=404, detail="session not found")

    session = doc.to_dict()
    return {"session_id": session_id, "messages": session.get("messages", [])}



@app.delete("/chat/{session_id}", status_code=204)
async def delete_chat(session_id: str):
    doc_ref = firestore_client.collection(FIRESTORE_COLLECTION).document(session_id)
    doc = doc_ref.get()
    if not doc.exists:
        raise HTTPException(status_code=404, detail="session not found")

    doc_ref.delete()
    logger.info("session deleted", extra={"session_id": session_id})
    return Response(status_code=204)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
