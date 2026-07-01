output "cluster_name" {
  description = "GKE cluster name"
  value       = google_container_cluster.nexus_cluster.name
}

output "bucket_name" {
  description = "GCS bucket name"
  value       = google_storage_bucket.nexus_artifacts.name
}

output "nexus_gcs_sa_email" {
  description = "GCP Service Account email — paste into helm/nexus/values.yaml"
  value       = google_service_account.nexus_gcs_sa.email
}
