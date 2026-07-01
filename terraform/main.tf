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

# GCS Bucket for Nexus artifacts
resource "google_storage_bucket" "nexus_artifacts" {
  name          = var.bucket_name
  location      = var.region
  force_destroy = false

  versioning {
    enabled = true
  }

  lifecycle_rule {
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
    condition {
      age = 90
    }
  }
}

# GKE Cluster
resource "google_container_cluster" "nexus_cluster" {
  name     = var.cluster_name
  location = var.zone

  remove_default_node_pool = true
  initial_node_count       = 1

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }
}

# Node Pool - 1 node, n1-standard-1, preemptible as required
resource "google_container_node_pool" "nexus_nodes" {
  name       = "nexus-node-pool"
  cluster    = google_container_cluster.nexus_cluster.name
  location   = var.zone
  node_count = 1

  node_config {
    machine_type = "n1-standard-1"
    preemptible  = true

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}

# GCP Service Account for Nexus to access GCS
resource "google_service_account" "nexus_gcs_sa" {
  account_id   = "nexus-gcs-sa"
  display_name = "Nexus GCS Blob Store Service Account"
}

# Grant Storage Object Admin on the bucket
resource "google_storage_bucket_iam_member" "nexus_gcs_access" {
  bucket = google_storage_bucket.nexus_artifacts.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.nexus_gcs_sa.email}"
}

# Workload Identity binding: K8s SA -> GCP SA
resource "google_service_account_iam_member" "workload_identity_binding" {
  service_account_id = google_service_account.nexus_gcs_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[nexus/nexus-sa]"
}
