variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "region" {
  type        = string
  description = "GCP region for resources"
}

variable "firestore_location" {
  type        = string
  description = "Location for the Firestore database (e.g. nam5, us-east1)"
}

variable "knowledge_bucket" {
  type        = string
  description = "Base name of the GCS bucket that stores the knowledge base file (gets an env suffix)"
}

variable "chat_image" {
  type        = string
  description = "Full image URI for the chat Cloud Run service"
  default     = "us-docker.pkg.dev/cloudrun/container/hello:latest"
}

variable "cleanup_image" {
  type        = string
  description = "Full image URI for the cleanup Cloud Run job"
  default     = "us-docker.pkg.dev/cloudrun/container/hello:latest"
}

variable "environment" {
  type        = string
  description = "Deployment environment. Drives the name suffix on every environment-scoped resource."

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be either \"dev\" or \"prod\"."
  }
}
