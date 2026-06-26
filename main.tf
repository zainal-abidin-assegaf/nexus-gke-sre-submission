terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ─── GCS Bucket for Nexus artifacts ───────────────────────────────────────────

resource "google_storage_bucket" "nexus_artifacts" {
  name          = var.bucket_name
  location      = var.region
  force_destroy = false   # Prevents accidental deletion of artifacts

  # Versioning keeps old artifact versions recoverable
  versioning {
    enabled = true
  }

  # Lifecycle: move objects to cheaper storage after 90 days
  lifecycle_rule {
    action { type = "SetStorageClass"; storage_class = "NEARLINE" }
    condition { age = 90 }
  }
}

# ─── GKE Cluster ──────────────────────────────────────────────────────────────

resource "google_container_cluster" "nexus_cluster" {
  name     = var.cluster_name
  location = var.zone   # Zonal cluster = cheaper than regional

  # We manage the node pool separately so we can use preemptible VMs
  remove_default_node_pool = true
  initial_node_count       = 1

  # Workload Identity lets pods access GCS without key files
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }
}

resource "google_container_node_pool" "nexus_nodes" {
  name       = "nexus-node-pool"
  cluster    = google_container_cluster.nexus_cluster.name
  location   = var.zone
  node_count = 1   # Keep costs low: 1 node as required

  node_config {
    machine_type = "n1-standard-1"   # As specified in the task
    preemptible  = true              # ~70% cheaper; acceptable for dev/test

    # Required OAuth scopes for GCS access
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    # Attach the K8s service account to Workload Identity
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}

# ─── GCP Service Account for Nexus → GCS access ───────────────────────────────

resource "google_service_account" "nexus_gcs_sa" {
  account_id   = "nexus-gcs-sa"
  display_name = "Nexus GCS Blob Store Service Account"
}

# Grant the SA permission to read/write objects in the bucket
resource "google_storage_bucket_iam_member" "nexus_gcs_access" {
  bucket = google_storage_bucket.nexus_artifacts.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.nexus_gcs_sa.email}"
}

# Workload Identity binding: K8s SA in "nexus" namespace → GCP SA
resource "google_service_account_iam_member" "workload_identity_binding" {
  service_account_id = google_service_account.nexus_gcs_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[nexus/nexus-sa]"
}
