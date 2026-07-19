variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "region" {
  type        = string
  description = "GCP region for resources"
}

variable "artifact_repo" {
  type        = string
  description = "Name of the Artifact Registry repository that holds the chat/cleanup images, shared across all environments"
  default     = "assistant"
}
