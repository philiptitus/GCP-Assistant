I'm building a small backend project called "Assistant" — a serverless AI 
chat API on GCP using Gemini. You will build BOTH the application code AND 
the Terraform for it. I will review every Terraform change  myself — 
plan against real infra, or run 
gcloud deploy commands yourself. Just write the .tf files and let me review 
and apply them.

## What Assistant does
One Cloud Run chat service, one scheduled cleanup job, backed by Firestore, 
Cloud Storage, and Secret Manager.

1. **chat** service (public-facing HTTP API)
   - POST /chat — body: { "session_id": "optional", "message": "string" }. 
     If session_id is missing, create a new one. Append the user message to 
     the Firestore session doc. Build a prompt: last N messages (default 10) 
     from the session's history + the full text content of a knowledge base 
     file read from Cloud Storage (small text file, just read the whole thing, 
     no chunking or embeddings). Call the Gemini API (Flash-Lite model) with 
     that prompt. Append the assistant's reply to Firestore. Return 
     { "session_id", "reply" }.
   - GET /chat/{session_id} — returns the full message history for that session.
   - DELETE /chat/{session_id} — deletes the session doc.
   - POST /knowledge — accepts a small text file upload, saves it to the GCS 
     knowledge bucket, overwriting any existing file (single-file knowledge 
     base for now, no versioning).

2. **cleanup** job (Cloud Run job, not a service — no HTTP, triggered by 
   Cloud Scheduler)
   - Queries Firestore for chat sessions whose last-updated timestamp is 
     older than 30 days, deletes them. Log how many were deleted. Exit.

## Tech stack
- Python, FastAPI for the chat service; a plain Python script (no FastAPI 
  needed) for the cleanup job
- google-cloud-firestore, google-cloud-storage, google-cloud-secret-manager, 
  google-generativeai (or the Vertex AI SDK — use whichever pairs with a 
  plain Gemini Developer API key, not full Vertex AI provisioning, since I 
  want the free daily quota tier, not Vertex AI billing)
- The Gemini API key must be read from Secret Manager at startup/runtime — 
  never hardcoded, never passed as a plain env var containing the actual key
- Config via environment variables: GCP_PROJECT, FIRESTORE_COLLECTION, 
  GCS_KNOWLEDGE_BUCKET, GEMINI_SECRET_NAME
- Dockerfile for the chat service, ready for Cloud Run (listen on PORT env 
  var, default 8080). The cleanup job needs a Dockerfile too but doesn't 
  need to listen on any port — it just runs and exits.
- Structured JSON logging (Python logging module)
- Basic input validation (reject empty messages, cap message length, cap 
  uploaded knowledge file size)

## Terraform scope
- google_firestore_database (can reuse if I already have one from another 
  project — ask me before creating a second one)
- google_storage_bucket for the knowledge base file
- google_secret_manager_secret + google_secret_manager_secret_version for 
  the Gemini API key (I'll provide the actual key value manually, don't 
  generate or guess one)
- google_cloud_run_v2_service for the chat service
- google_cloud_run_v2_job for the cleanup job
- google_cloud_scheduler_job that triggers the cleanup job daily
- google_service_account x2 (chat-sa, cleanup-sa) with least-privilege 
  google_project_iam_member bindings — chat-sa needs firestore access, 
  storage read, and secret manager accessor; cleanup-sa needs firestore 
  access only
- google_billing_budget resource with an email alert threshold at $2 and $5 
  spend for the month — ask me for my billing account ID before writing this, 
  don't guess it
- Use variables.tf for project_id, region, bucket name, budget thresholds, 
  etc. — no hardcoded values in the resource files
- Follow the same structure/conventions as the earlier repo I showed you 
  (remote state in GCS, GitHub Actions workflow for plan/apply)

## Important cost guardrail
Do NOT provision Vertex AI Vector Search, Matching Engine, or any 
always-on/hourly-billed AI infrastructure. This project intentionally uses 
a single flat text file as context instead of a real vector database, to 
keep costs at effectively $0 for testing. If you think a step requires 
something with a non-trivial idle cost, stop and ask me first instead of 
provisioning it.

## How I want you to work
Build this ONE PIECE AT A TIME. Stop after each piece and wait for me to 
review/confirm before moving to the next:

1. Terraform: Firestore database (or confirm reuse) + Cloud Storage bucket 
   for the knowledge file.
2. Terraform: Secret Manager secret (you will advise how to handle this via terrafom maybe repo secret etc).
3. App code: chat service skeleton — POST /chat and GET /chat/{session_id}, 
   Firestore read/write working, Gemini call using the key pulled from Secret 
   Manager (via env var pointing at the secret for now, wire actual Secret 
   Manager API access in the next relevant step if simpler). Skip the 
   knowledge base context for now — just chat history in the prompt.
4. App code: POST /knowledge endpoint + wiring the knowledge file into the 
   chat prompt.
5. App code: DELETE /chat/{session_id}.
6. App code: cleanup job script.
7. Terraform: Cloud Run service (chat) + Cloud Run job (cleanup) + service 
   accounts + IAM bindings.
8. Terraform: Cloud Scheduler job wired to trigger the cleanup job.
9. Terraform: billing budget resource (ask me for billing account ID here).
10. Dockerfiles for both.
11. GitHub Actions workflow for Terraform plan/apply, matching the pattern 
    from the earlier repo.

At each step, tell me clearly what you built, what environment variables or 
manual values you need from me, and what I should review before we move to 
the next step.

Start with step 1 only.