#########################################################################
## Environment-Scoped Naming
##
## Every environment-scoped resource name is built here so the -dev/-prod
## suffix lives in exactly one place.
#########################################################################
locals {
  app_name = "assistant"

  firestore_database_name = "${local.app_name}-${var.environment}"
  knowledge_bucket_name   = "${var.knowledge_bucket}-${var.environment}"
  gemini_secret_name      = "gemini-api-key-${var.environment}"
  chat_service_name       = "${local.app_name}-chat-${var.environment}"
  cleanup_job_name        = "${local.app_name}-cleanup-${var.environment}"
  chat_sa_account_id      = "${local.app_name}-chat-sa-${var.environment}"
  cleanup_sa_account_id   = "${local.app_name}-cleanup-sa-${var.environment}"

  # Testing-friendly default (30 min) for dev; a real 30-day window for prod.
  cleanup_retention_minutes = var.environment == "prod" ? "43200" : "30"

  # Matches the retention split above — dev fires often enough to actually
  # observe cleanup during testing; prod only needs to run daily given its
  # 30-day window.
  cleanup_schedule = var.environment == "prod" ? "0 3 * * *" : "*/30 * * * *"
}

#########################################################################
## Required APIs
##
## Extended in later steps as Cloud Run / Scheduler resources are added —
## adding a new key to this set is non-destructive.
#########################################################################
resource "google_project_service" "required_apis" {
  for_each = toset([
    "firestore.googleapis.com",
    "secretmanager.googleapis.com",
    "run.googleapis.com",
    "cloudscheduler.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

#########################################################################
## Firestore Database
#########################################################################
resource "google_firestore_database" "database" {
  name            = local.firestore_database_name
  location_id     = var.firestore_location
  type            = "FIRESTORE_NATIVE"
  deletion_policy = "DELETE"

  depends_on = [google_project_service.required_apis]
}

#########################################################################
## Knowledge Base Bucket
#########################################################################
resource "google_storage_bucket" "knowledge" {
  name          = local.knowledge_bucket_name
  location      = var.region
  force_destroy = true
}

#########################################################################
## Gemini API Key Secret
##
## Terraform manages only the secret container, never a version — the
## actual key value is added out-of-band (gcloud secrets versions add),
## so it never touches Terraform state, git, or CI logs. See README for
## the exact command.
#########################################################################
resource "google_secret_manager_secret" "gemini_api_key" {
  secret_id = local.gemini_secret_name

  replication {
    auto {}
  }

  depends_on = [google_project_service.required_apis]
}

data "google_project" "current" {
  project_id = var.project_id
}

#########################################################################
## Service Accounts
#########################################################################
resource "google_service_account" "chat_sa" {
  account_id   = local.chat_sa_account_id
  display_name = "Assistant Chat service account"
}

resource "google_service_account" "cleanup_sa" {
  account_id   = local.cleanup_sa_account_id
  display_name = "Assistant Cleanup service account"
}

# chat-sa: firestore read/write, secret manager accessor (Gemini key), and
# storage read+write on the knowledge bucket — the plan calls this "storage
# read" but POST /knowledge actually overwrites the file, so objectAdmin is
# the correct scope for the code as built, not objectViewer.
resource "google_project_iam_member" "chat_sa_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.chat_sa.email}"
}

resource "google_project_iam_member" "chat_sa_storage" {
  project = var.project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.chat_sa.email}"
}

resource "google_project_iam_member" "chat_sa_secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.chat_sa.email}"
}

# cleanup-sa: firestore access only.
resource "google_project_iam_member" "cleanup_sa_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.cleanup_sa.email}"
}

#########################################################################
## Cloud Run: chat service
#########################################################################
resource "google_cloud_run_v2_service" "chat" {
  name                = local.chat_service_name
  location            = var.region
  deletion_protection = false

  template {
    service_account = google_service_account.chat_sa.email

    containers {
      image = var.chat_image

      env {
        name  = "GCP_PROJECT"
        value = var.project_id
      }
      env {
        name  = "FIRESTORE_COLLECTION"
        value = "chat_sessions"
      }
      env {
        name  = "FIRESTORE_DATABASE"
        value = google_firestore_database.database.name
      }
      env {
        name  = "GCS_KNOWLEDGE_BUCKET"
        value = google_storage_bucket.knowledge.name
      }
      env {
        name  = "GEMINI_SECRET_NAME"
        value = google_secret_manager_secret.gemini_api_key.secret_id
      }
      env {
        name  = "GEMINI_MODEL"
        value = "gemini-flash-lite-latest"
      }
      env {
        name  = "CHAT_HISTORY_LIMIT"
        value = "10"
      }
      env {
        name  = "CHAT_MAX_MESSAGE_LENGTH"
        value = "4000"
      }
      env {
        name  = "KNOWLEDGE_MAX_FILE_SIZE"
        value = "5242880"
      }
    }
  }

  depends_on = [google_project_service.required_apis]
}

# Public-facing per the plan's "chat service (public-facing HTTP API)".
resource "google_cloud_run_v2_service_iam_member" "chat_public" {
  name     = google_cloud_run_v2_service.chat.name
  location = google_cloud_run_v2_service.chat.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}

#########################################################################
## Cloud Run: cleanup job
##
## Not a service — no HTTP, no public/private invoker distinction needed
## here. Cloud Scheduler's invoker permission on this job is wired in the
## next step, once the scheduler resource exists.
#########################################################################
resource "google_cloud_run_v2_job" "cleanup" {
  name                = local.cleanup_job_name
  location            = var.region
  deletion_protection = false

  template {
    template {
      service_account = google_service_account.cleanup_sa.email

      containers {
        image = var.cleanup_image

        env {
          name  = "GCP_PROJECT"
          value = var.project_id
        }
        env {
          name  = "FIRESTORE_COLLECTION"
          value = "chat_sessions"
        }
        env {
          name  = "FIRESTORE_DATABASE"
          value = google_firestore_database.database.name
        }
        env {
          name  = "CLEANUP_RETENTION_MINUTES"
          value = local.cleanup_retention_minutes
        }
      }
    }
  }

  depends_on = [google_project_service.required_apis]
}

#########################################################################
## Cloud Scheduler: trigger the cleanup job daily
##
## Scheduler calls the Cloud Run Jobs REST API directly (there's no native
## "Cloud Run job" target type), authenticated via an OAuth token minted as
## cleanup-sa. That reuses cleanup-sa as the invoking identity rather than
## adding a third service account — it already exists and already has the
## permissions the job itself needs, so granting it run.invoker on its own
## job isn't circular, just one more role on an account we already made.
#########################################################################
resource "google_cloud_run_v2_job_iam_member" "cleanup_scheduler_invoker" {
  name     = google_cloud_run_v2_job.cleanup.name
  location = google_cloud_run_v2_job.cleanup.location
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.cleanup_sa.email}"
}

# Cloud Scheduler's service agent needs permission to mint OAuth tokens as
# cleanup-sa in order to authenticate its trigger requests.
resource "google_service_account_iam_member" "scheduler_token_creator" {
  service_account_id = google_service_account.cleanup_sa.name
  role                = "roles/iam.serviceAccountTokenCreator"
  member              = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-cloudscheduler.iam.gserviceaccount.com"
}

resource "google_cloud_scheduler_job" "cleanup_daily" {
  name      = "${local.app_name}-cleanup-trigger-${var.environment}"
  region    = var.region
  schedule  = local.cleanup_schedule
  time_zone = "UTC"

  http_target {
    http_method = "POST"
    uri         = "https://${var.region}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${var.project_id}/jobs/${google_cloud_run_v2_job.cleanup.name}:run"

    oauth_token {
      service_account_email = google_service_account.cleanup_sa.email
    }
  }

  depends_on = [
    google_project_service.required_apis,
    google_cloud_run_v2_job_iam_member.cleanup_scheduler_invoker,
    google_service_account_iam_member.scheduler_token_creator,
  ]
}
