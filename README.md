# Nexus on GKE with GCS Blob Store

## Repository Structure

```
nexus-gke-sre-submission/
├── Dockerfile
├── README.md
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
└── helm/
    └── nexus/
        ├── Chart.yaml
        ├── values.yaml
        └── templates/
            └── nexus.yaml
```

## Architecture

```
Developer → Git Push
               ↓
          CI (GitHub Actions)
               ↓
     Build & push Docker image to GCR
               ↓
     Helm upgrade → GKE Cluster
               ↓
      Nexus Pod ──→ GCS Bucket (artifacts)
                └──→ PVC (local metadata/config)
```

---

## Prerequisites

- `gcloud` CLI authenticated
- `terraform` >= 1.5
- `helm` >= 3.x
- `kubectl` configured for your cluster
- A GCP project with billing enabled

---

## Part 1: Build & Push the Docker Image

```bash
export PROJECT_ID=your-gcp-project-id

docker build -t gcr.io/$PROJECT_ID/nexus-gcs:latest .
docker push gcr.io/$PROJECT_ID/nexus-gcs:latest
```

**What the Dockerfile does:**
- Extends the official `sonatype/nexus3` base image
- Downloads the GCS Blob Store plugin `.kar` into `/opt/sonatype/nexus/deploy/`
- Nexus auto-loads `.kar` files from that directory on startup
- Runs as the unprivileged `nexus` user

---

## Part 2: Kubernetes with Helm

The chart lives in `helm/nexus/` and generates four resources:

| Resource | Purpose |
|---|---|
| `ServiceAccount` | Pod identity linked to GCP SA via Workload Identity |
| `PersistentVolumeClaim` | Local disk for Nexus metadata and config |
| `Service` (LoadBalancer) | Exposes Nexus on port 8081 |
| `Deployment` | Runs 1 replica of the custom Nexus container |

---

## Part 3: Provision GCP Resources with Terraform

```bash
cd terraform/

terraform init

terraform plan \
  -var="project_id=$PROJECT_ID" \
  -var="bucket_name=nexus-artifacts-$PROJECT_ID"

terraform apply \
  -var="project_id=$PROJECT_ID" \
  -var="bucket_name=nexus-artifacts-$PROJECT_ID"
```

**Resources created:**
- **GCS Bucket** — stores Nexus artifacts; versioning enabled
- **GKE Cluster** — zonal cluster (cheapest option)
- **Node Pool** — 1× `n1-standard-1` preemptible VM
- **GCP Service Account** — `nexus-gcs-sa` with `Storage Object Admin` on the bucket
- **Workload Identity binding** — links K8s SA to GCP SA (no key files needed)

---

## Part 4: Deploy Nexus to GKE

```bash
# Get cluster credentials
gcloud container clusters get-credentials nexus-cluster \
  --zone europe-west1-b \
  --project $PROJECT_ID

# Create namespace
kubectl create namespace nexus

# Deploy with Helm (update values first with your project details)
helm upgrade --install nexus ./helm/nexus \
  --namespace nexus \
  --set image.repository=gcr.io/$PROJECT_ID/nexus-gcs \
  --set gcs.bucketName=nexus-artifacts-$PROJECT_ID \
  --set serviceAccount.gcpServiceAccount=$(cd terraform && terraform output -raw nexus_gcs_sa_email)

# Watch the pod start (Nexus takes ~2 minutes)
kubectl get pods -n nexus -w

# Get external IP
kubectl get svc nexus-service -n nexus
```

**Post-deploy: Configure GCS Blob Store in Nexus UI**
1. Open `http://<EXTERNAL_IP>:8081`
2. Log in — get the initial password with:
   ```bash
   kubectl exec -n nexus deployment/nexus -- cat /nexus-data/admin.password
   ```
3. Go to **Administration → Blob Stores → Create Blob Store**
4. Select **Google Cloud Storage**, enter bucket name, save
5. Assign the blob store to your repositories

---

## Part 5: Continuous Integration

**Goal:** Any Git change (e.g. new Nexus version in Dockerfile) triggers an automatic deploy to a test environment.

### Pipeline: GitHub Actions

```
Git Push to any branch
        ↓
GitHub Actions triggers
        ↓
  1. Lint & validate
     - hadolint (Dockerfile)
     - helm lint ./helm/nexus
     - terraform validate
        ↓
  2. Build & push Docker image
     - Tagged with git commit SHA (not "latest")
        ↓
  3. Deploy to TEST namespace
     - helm upgrade --install
     - namespace: nexus-test
        ↓
  4. Smoke test
     - curl /service/rest/v1/status → assert HTTP 200
        ↓ (main branch only)
  Manual approval gate
        ↓
  Deploy to PRODUCTION namespace
```

**Key principles:**
- Image tags use the **git commit SHA** — every deploy is traceable, rollbacks are one `helm upgrade` away
- Separate namespaces (`nexus-test`, `nexus-prod`) for environment isolation
- Secrets stored in GitHub Actions Secrets or GCP Secret Manager — never in the repo
- `terraform plan` runs on every PR; `terraform apply` only on merge to main
