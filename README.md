# Assistant

A small serverless AI chat API on GCP, backed by Gemini (Flash-Lite), with a
single-file knowledge base and automatic session cleanup.

## How it works

One public Cloud Run service (`chat`) plus one scheduled Cloud Run job
(`cleanup`), both backed by Firestore, Cloud Storage, and Secret Manager:

```
client --> [chat service] --> Firestore (session history)
                |
                +--> Cloud Storage (knowledge.txt, read-only per request)
                |
                +--> Secret Manager (Gemini API key, fetched lazily)
                |
                +--> Gemini API (Flash-Lite)

Cloud Scheduler --> [cleanup job] --> Firestore (deletes stale sessions)
```

- `POST /chat` appends the message to the session's Firestore doc, builds a
  prompt from the last 10 messages plus the full knowledge base text (no
  chunking/embeddings — just a flat text file), calls Gemini, appends the
  reply, and returns it.
- `POST /knowledge` overwrites the single knowledge base file in GCS.
- The `cleanup` job deletes Firestore sessions past a retention window and
  exits. It's not an HTTP service — Cloud Scheduler triggers it directly via
  the Cloud Run Jobs REST API.

## Infrastructure

Provisioned via Terraform, environment-scoped (`dev`/`prod`) via Terraform
workspaces, in the same GCP project as Scanner (`fiona-464509`):

- Firestore (Native mode), its own named database per environment
  (`assistant-dev` / `assistant-prod`) — fully isolated from Scanner's
  Firestore databases
- GCS bucket for the knowledge base file
- Secret Manager secret container for the Gemini API key (Terraform manages
  only the container — the actual key value is added manually, see below)
- Two service accounts (`chat-sa`, `cleanup-sa`), least-privilege
- Cloud Run service (`chat`) — public
- Cloud Run job (`cleanup`) — triggered only by Cloud Scheduler, via an
  OAuth token minted as `cleanup-sa`
- Cloud Scheduler job — `dev` runs every 30 minutes (matches dev's 30-minute
  retention window, so cleanup is actually observable during testing);
  `prod` runs once daily (matches its real 30-day retention window)

The Artifact Registry repo (`assistant`) is shared across both environments
and lives in its own independent Terraform root, [shared/](shared/) — this
avoids the state-ownership issue we hit on Scanner, where a shared resource
declared inside a per-environment, per-workspace config caused a destroy of
one environment to take out infrastructure the other depended on.

Remote state lives in the shared `myzer-state` GCS bucket, under the
`assistant/` prefix (`assistant/terraform/state` per-environment,
`assistant/shared/terraform/state` for the shared root).

## Config

All config is environment variables, set by Terraform on the Cloud Run
resources:

| Var | chat | cleanup |
|---|---|---|
| `GCP_PROJECT` | ✓ | ✓ |
| `FIRESTORE_COLLECTION` | ✓ | ✓ |
| `FIRESTORE_DATABASE` | ✓ | ✓ |
| `GCS_KNOWLEDGE_BUCKET` | ✓ | — |
| `GEMINI_SECRET_NAME` | ✓ | — |
| `GEMINI_MODEL` | ✓ | — |
| `CHAT_HISTORY_LIMIT` | ✓ | — |
| `CHAT_MAX_MESSAGE_LENGTH` | ✓ | — |
| `KNOWLEDGE_MAX_FILE_SIZE` | ✓ | — |
| `CLEANUP_RETENTION_MINUTES` | — | ✓ |

## The Gemini API key

Terraform creates the Secret Manager secret container only — never the
value, so the key never touches Terraform state, git, or CI logs. Add it
manually, once per environment, after that environment's first successful
deploy:

```bash
echo -n "your-actual-gemini-key" | gcloud secrets versions add gemini-api-key-dev --data-file=- --project=fiona-464509
echo -n "your-actual-gemini-key" | gcloud secrets versions add gemini-api-key-prod --data-file=- --project=fiona-464509
```

The chat service fetches the key lazily, on the first `/chat` call, not at
container startup — so a deploy never fails just because the key hasn't
been added yet. Before the key exists, `/chat` returns `503 Gemini API key
is not configured yet` rather than crashing.

## Deploying

Push to `develop` for a dev deploy, `main` for prod — the GitHub Actions
workflow ([.github/workflows/workflow.yaml](.github/workflows/workflow.yaml))
maps the branch to an environment, runs `terraform plan`/`apply`, builds and
pushes the `chat`/`cleanup` images (tagged `<env>-<sha>`), then applies again
to point Cloud Run at the new images.

Before the very first deploy, run the **"One-off: Apply shared Artifact
Registry"** workflow manually once — it provisions the shared image repo
that the main workflow needs to push into.

To tear an environment down, run the **"Terraform Destroy"** workflow
manually — pick `dev` or `prod` from the dropdown, then type the
environment name again to confirm. This also destroys that environment's
Secret Manager secret (and the key inside it) — re-adding the key is
required after any environment is rebuilt from a destroy.

## Testing it

Get the chat service URL:

```bash
gcloud run services describe assistant-chat-dev --region=us-east1 --format='value(status.url)'
```

Start a conversation:

```bash
curl -X POST "$CHAT_URL/chat" -H "Content-Type: application/json" -d '{"message": "Hello!"}'
# -> { "session_id": "...", "reply": "..." }
```

Continue it (reuse the session_id):

```bash
curl -X POST "$CHAT_URL/chat" -H "Content-Type: application/json" \
  -d '{"session_id": "<session_id>", "message": "What did I just say?"}'
```

Upload a knowledge base file:

```bash
curl -X POST "$CHAT_URL/knowledge" -F "file=@knowledge.txt"
```

View full history:

```bash
curl "$CHAT_URL/chat/<session_id>"
```

Delete a session:

```bash
curl -X DELETE "$CHAT_URL/chat/<session_id>"
```

Manually trigger the cleanup job (rather than waiting for the schedule):

```bash
gcloud run jobs execute assistant-cleanup-dev --region=us-east1
```
