# Assistant Chat API

Base URL: the GCP Assistant IAC ennvironment has variables dev_url and prod_url to be used`.

All responses are JSON. The `cleanup` job is not documented here — it's not
an HTTP service, it's triggered on a schedule by Cloud Scheduler.

---

## POST /chat

Send a message. If `session_id` is omitted, a new session is created.
The reply is generated from the last 10 messages of history plus the full
knowledge base text (if one has been uploaded).

**Request:** `application/json`

| Field | Type | Required | Description |
|---|---|---|---|
| `session_id` | string | no | Existing session to continue. Omit to start a new one. |
| `message` | string | yes | The user's message. Max 4000 characters, must not be empty/whitespace-only. |

```bash
curl -X POST "$CHAT_URL/chat" -H "Content-Type: application/json" \
  -d '{"message": "Hello!"}'
```

**Response:** `200 OK`

```json
{
  "session_id": "3f1b1e2a-6c2e-4b7f-9c1a-2f6e8a1d9b3c",
  "reply": "Hi there! How can I help you today?"
}
```

**Errors:**
- `400` — message is empty or exceeds the max length
- `503` — the Gemini API key hasn't been added to Secret Manager yet (see README)

---

## GET /chat/{session_id}

Fetch the full message history for a session.

```bash
curl "$CHAT_URL/chat/3f1b1e2a-6c2e-4b7f-9c1a-2f6e8a1d9b3c"
```

**Response:** `200 OK`

```json
{
  "session_id": "3f1b1e2a-6c2e-4b7f-9c1a-2f6e8a1d9b3c",
  "messages": [
    { "role": "user", "content": "Hello!", "timestamp": "2026-07-19T12:00:00Z" },
    { "role": "assistant", "content": "Hi there!", "timestamp": "2026-07-19T12:00:01Z" }
  ]
}
```

**Errors:** `404 Not Found` if `session_id` doesn't exist.

---

## DELETE /chat/{session_id}

Deletes the session's Firestore document.

```bash
curl -X DELETE "$CHAT_URL/chat/3f1b1e2a-6c2e-4b7f-9c1a-2f6e8a1d9b3c"
```

**Response:** `204 No Content`

**Errors:** `404 Not Found` if `session_id` doesn't exist.

---

## POST /knowledge

Uploads a text file as the knowledge base, **overwriting** any existing
file — single-file, no versioning. This file's full text gets prepended to
every subsequent `/chat` prompt.

**Request:** `multipart/form-data`

| Field | Type | Required | Description |
|---|---|---|---|
| `file` | file | yes | The knowledge base text file. Max size set by `KNOWLEDGE_MAX_FILE_SIZE` (default 5MB). |

```bash
curl -X POST "$CHAT_URL/knowledge" -F "file=@knowledge.txt"
```

**Response:** `204 No Content`

**Errors:** `400 Bad Request` if the file exceeds the max size.
