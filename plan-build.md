Build order for Assistant, folding in the dev/prod + destroy pattern from
Scanner from the start instead of bolting it on later. Same GCP project as
Scanner (fiona-464509). Firestore gets its own dedicated named databases
(`assistant-dev` / `assistant-prod`), not reused from Scanner.

## Lessons carried over from Scanner

- Terraform workspaces (`dev`/`prod`) + `locals` naming table, `-dev`/`-prod`
  suffix on every environment-scoped resource, driven by an `environment`
  variable with no default (forces explicit `-var-file` on every run).
- Anything genuinely shared across environments (Artifact Registry repo for
  the chat/cleanup images) lives in its own `shared/` Terraform root with
  independent state from day one — not added to the per-env config and
  migrated out later. That migration was the one real incident on Scanner;
  not repeating it here.
- `destroy.yaml` built alongside the main workflow from the start, not
  after the fact — environment-picker input + typed confirmation matching
  the selection, `terraform workspace select` (no auto-create) so it can't
  destroy a workspace that doesn't exist.
- `force_destroy = true` on the GCS bucket, `deletion_policy = "DELETE"` on
  the Firestore database, `deletion_protection = false` on the Cloud Run
  service — all set up front this time, not discovered one destroy-failure
  at a time.

## Steps

Same one-piece-at-a-time approach as before — stop after each for review.

1. **Terraform foundation + Firestore + GCS bucket.** `environment`
   variable, naming `locals`, `dev.tfvars`/`prod.tfvars`, `providers.tf`
   (workspaced backend, prefix `assistant/terraform/state` in `myzer-state`),
   plus the `shared/` root (Artifact Registry repo + its API enablement,
   applied once, independent of workspaces) — built now, even though images
   don't exist until step 10, so there's no later migration. Then the actual
   step 1 resources: `google_firestore_database` (named `assistant-dev`/
   `assistant-prod`) and the GCS knowledge bucket.

2. **Terraform: Secret Manager secret** for the Gemini API key — structure
   only (`google_secret_manager_secret`), with guidance on how you'll supply
   the actual key value (likely a manual `gcloud secrets versions add` or a
   GitHub Secret consumed by a `google_secret_manager_secret_version`
   resource — I'll lay out the tradeoff before we pick).

3. **App code: chat service skeleton** — `POST /chat`, `GET
   /chat/{session_id}`, Firestore read/write, Gemini call reading the key
   via env var pointing at the secret (Secret Manager API wiring comes
   later if simpler as a follow-up, per your plan). No knowledge base
   context yet — just chat history.

4. **App code: `POST /knowledge`** + wiring the knowledge file into the
   chat prompt.

5. **App code: `DELETE /chat/{session_id}`.**

6. **App code: cleanup job script** (plain Python, no FastAPI).

7. **Terraform: Cloud Run service (chat) + Cloud Run job (cleanup) +
   service accounts + IAM bindings**, all env-suffixed per the naming
   locals from step 1.

8. **Terraform: Cloud Scheduler job** triggering the cleanup job daily.

9. **Terraform: billing budget** — will ask for your billing account ID at
   this step, alert thresholds at $2/$5.

10. **Dockerfiles** for both chat and cleanup.

11. **GitHub Actions**: main deploy workflow (branch → environment mapping,
    build/push/deploy, matching Scanner's shape) + `destroy.yaml` (built
    now using the same environment-picker pattern, not retrofitted).

At each step: what was built, what needs your review, and (per your plan)
what environment variables or manual values I need from you before the
next step. Starting with step 1 now.
