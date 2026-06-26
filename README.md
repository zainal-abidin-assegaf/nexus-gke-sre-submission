# Nexus on GKE with GCS Blob Store

## Architecture

```
Developer → Git Push
               ↓
          CI (Cloud Build / GitHub Actions)
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
# Set your project ID
export PROJECT_ID=your-gcp-project-id

# Build the custom Nexus image (with GCS plugin pre-installed)
docker build -t gcr.io/$PROJECT_ID/nexus-gcs:latest .

# Push to Google Container Registry
docker push gcr.io/$PROJECT_ID/nexus-gcs:latest
```

**What the Dockerfile does:**
- Starts from the official `sonatype/nexus3` base image
- Downloads the GCS Blob Store plugin `.kar` file into `/opt/sonatype/nexus/deploy/`
- Nexus automatically loads `.kar` files from that directory on startup
- Runs as the unprivileged `nexus` user

---

## Part 2: Kubernetes with Helm

The Helm chart creates three Kubernetes resources:

| Resource | Purpose |
|---|---|
| `ServiceAccount` | Identity for the pod; linked to GCP SA via Workload Identity |
| `PersistentVolumeClaim` | Local disk for Nexus metadata and config (not artifacts) |
| `Service` (LoadBalancer) | Exposes Nexus on port 8081 to the internet |
| `Deployment` | Runs 1 replica of the custom Nexus container |

**Why Helm?** Helm lets you template values (image tag, bucket name, etc.) so the same chart deploys to dev, staging, and prod with different `values.yaml` files.

---

## Part 3: Provision GCP Resources with Terraform

```bash
cd terraform/

# Initialize Terraform and download providers
terraform init

# Preview what will be created
terraform plan \
  -var="project_id=$PROJECT_ID" \
  -var="bucket_name=nexus-artifacts-$PROJECT_ID"

# Create the GKE cluster, GCS bucket, and service accounts
terraform apply \
  -var="project_id=$PROJECT_ID" \
  -var="bucket_name=nexus-artifacts-$PROJECT_ID"
```

**Resources created:**
- **GCS Bucket** — stores all Nexus artifacts; versioning enabled; lifecycle moves old objects to Nearline storage after 90 days
- **GKE Cluster** — zonal cluster (cheapest option)
- **Node Pool** — 1× `n1-standard-1` preemptible VM (~70% cheaper than on-demand)
- **GCP Service Account** — `nexus-gcs-sa` with `Storage Object Admin` on the bucket
- **Workload Identity binding** — links the K8s ServiceAccount to the GCP SA (no key files needed)

---

## Part 4: Deploy Nexus to GKE

```bash
# Get credentials for the cluster
gcloud container clusters get-credentials nexus-cluster \
  --zone europe-west1-b \
  --project $PROJECT_ID

# Create the namespace
kubectl create namespace nexus

# Update values.yaml with your project details, then deploy:
helm upgrade --install nexus ./helm/nexus \
  --namespace nexus \
  --set image.repository=gcr.io/$PROJECT_ID/nexus-gcs \
  --set gcs.bucketName=nexus-artifacts-$PROJECT_ID \
  --set serviceAccount.gcpServiceAccount=$(terraform -chdir=terraform output -raw nexus_gcs_sa_email)

# Watch the pod come up (Nexus takes ~2 minutes to start)
kubectl get pods -n nexus -w

# Get the external IP once the LoadBalancer is provisioned
kubectl get svc nexus-service -n nexus
```

**Post-deploy: Configure GCS Blob Store in Nexus UI**
1. Open `http://<EXTERNAL_IP>:8081`
2. Log in (default: `admin` / check `kubectl exec` into the pod for the initial password at `/nexus-data/admin.password`)
3. Go to **Administration → Blob Stores → Create Blob Store**
4. Select type **Google Cloud Storage**, enter the bucket name, save
5. Assign the new blob store to your repositories

---

## Part 5: Continuous Integration (Theory)

**Goal:** Any change pushed to Git (e.g. a new Nexus version in the `Dockerfile`) should automatically deploy to a test environment.

### Recommended Pipeline: GitHub Actions + Cloud Build

```
Git Push to feature/* or main
        ↓
GitHub Actions workflow triggers
        ↓
  ┌─────────────────────────────────┐
  │  1. Lint & validate             │
  │     - dockerfile lint (hadolint)│
  │     - helm lint ./helm/nexus    │
  │     - terraform validate        │
  ├─────────────────────────────────┤
  │  2. Build Docker image          │
  │     docker build + push to GCR  │
  │     tagged with git SHA         │
  ├─────────────────────────────────┤
  │  3. Deploy to TEST environment  │
  │     helm upgrade --install      │
  │     --set image.tag=$GIT_SHA    │
  │     namespace: nexus-test       │
  ├─────────────────────────────────┤
  │  4. Smoke test                  │
  │     curl /service/rest/v1/status│
  │     assert HTTP 200             │
  └─────────────────────────────────┘
        ↓ (on main branch only)
  Manual approval gate
        ↓
  Deploy to PRODUCTION
```

### Key principles:
- **Image tags** use the Git commit SHA (not `latest`) so every deployment is traceable and rollbacks are a single `helm upgrade` with the old SHA
- **Separate namespaces** (`nexus-test`, `nexus-prod`) on the same cluster, or separate clusters entirely for stronger isolation
- **Secrets** (GCP SA, any credentials) are stored in GitHub Actions Secrets or GCP Secret Manager, never in the repo
- **Terraform** for infrastructure changes can also be automated: `terraform plan` on PR, `terraform apply` on merge to main

### Example `.github/workflows/deploy.yaml` trigger:
```yaml
on:
  push:
    branches: [main, 'feature/**']
  pull_request:
    branches: [main]
```
