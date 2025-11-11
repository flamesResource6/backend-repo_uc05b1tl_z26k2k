#!/usr/bin/env bash
set -euo pipefail

# ==== Config ====
PROJECT_ID=${PROJECT_ID:-"YOUR_GCP_PROJECT"}
REGION=${REGION:-"us-central1"}
CLUSTER_NAME=${CLUSTER_NAME:-"a2eg-gke"}
REPO_NAME=${REPO_NAME:-"a2eg"}
BACKEND_IMAGE=${BACKEND_IMAGE:-"${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/a2eg-backend:latest"}
FRONTEND_IMAGE=${FRONTEND_IMAGE:-"${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/a2eg-frontend:latest"}
NAMESPACE=${NAMESPACE:-"a2eg"}

SQL_INSTANCE=${SQL_INSTANCE:-"a2eg-sql"}
SQL_TIER=${SQL_TIER:-"db-custom-1-3840"}
SQL_REGION=${SQL_REGION:-"${REGION}"}
DB_NAME=${DB_NAME:-"a2eg_dsa"}
DB_USER=${DB_USER:-"a2eg_user"}
DB_PASS=${DB_PASS:-"CHANGEME_STRONG_PASS"}
FRONTEND_URL_PROD=${FRONTEND_URL_PROD:-"https://CHANGE_ME_DOMAIN"}
STATIC_IP_NAME=${STATIC_IP_NAME:-"a2eg-static-ip"}

# ==== Pre-flight ====
command -v gcloud >/dev/null || { echo "Install Google Cloud SDK"; exit 1; }
command -v docker >/dev/null || { echo "Install Docker"; exit 1; }
command -v kubectl >/dev/null || { echo "Install kubectl"; exit 1; }

# ==== Enable APIs ====
APIS=(container.googleapis.com artifactregistry.googleapis.com sqladmin.googleapis.com compute.googleapis.com)
for api in "${APIS[@]}"; do
  gcloud services enable "$api" --project "$PROJECT_ID"
done

# ==== Artifact Registry ====
if ! gcloud artifacts repositories describe "$REPO_NAME" --location="$REGION" --project "$PROJECT_ID" >/dev/null 2>&1; then
  gcloud artifacts repositories create "$REPO_NAME" \
    --repository-format=docker \
    --location="$REGION" \
    --description="A2EG images"
fi

gcloud auth configure-docker "${REGION}-docker.pkg.dev" -q

# ==== Build & Push Images ====
( cd backend && docker build -t "$BACKEND_IMAGE" . && docker push "$BACKEND_IMAGE" )
( cd frontend && docker build -t "$FRONTEND_IMAGE" . && docker push "$FRONTEND_IMAGE" )

# ==== GKE Cluster ====
if ! gcloud container clusters describe "$CLUSTER_NAME" --region "$REGION" --project "$PROJECT_ID" >/dev/null 2>&1; then
  gcloud container clusters create "$CLUSTER_NAME" \
    --project "$PROJECT_ID" \
    --region "$REGION" \
    --num-nodes 2 \
    --machine-type e2-standard-2 \
    --enable-autoscaling --min-nodes 2 --max-nodes 10
fi

gcloud container clusters get-credentials "$CLUSTER_NAME" --region "$REGION" --project "$PROJECT_ID"

# ==== Cloud SQL (Postgres) ====
if ! gcloud sql instances describe "$SQL_INSTANCE" --project "$PROJECT_ID" >/dev/null 2>&1; then
  gcloud sql instances create "$SQL_INSTANCE" \
    --database-version=POSTGRES_15 \
    --region="$SQL_REGION" \
    --tier="$SQL_TIER"
fi

if ! gcloud sql databases describe "$DB_NAME" --instance="$SQL_INSTANCE" --project "$PROJECT_ID" >/dev/null 2>&1; then
  gcloud sql databases create "$DB_NAME" --instance="$SQL_INSTANCE" --project "$PROJECT_ID"
fi

echo "Ensure DB user exists and set password"
gcloud sql users set-password "$DB_USER" --instance="$SQL_INSTANCE" --password="$DB_PASS" --project "$PROJECT_ID" || \
  gcloud sql users create "$DB_USER" --instance="$SQL_INSTANCE" --password="$DB_PASS" --project "$PROJECT_ID"

# ==== Namespace ====
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE"

# ==== Secrets ====
DB_CONN_STRING="postgresql://${DB_USER}:${DB_PASS}@127.0.0.1:5432/${DB_NAME}"

kubectl -n "$NAMESPACE" delete secret db-secrets >/dev/null 2>&1 || true
kubectl -n "$NAMESPACE" create secret generic db-secrets \
  --from-literal=DATABASE_URL="$DB_CONN_STRING"

kubectl -n "$NAMESPACE" delete secret app-secrets >/dev/null 2>&1 || true
kubectl -n "$NAMESPACE" create secret generic app-secrets \
  --from-literal=FRONTEND_URL="$FRONTEND_URL_PROD" \
  --from-literal=LLM_API_KEY="CHANGE_ME"

# Optional: SA key for Cloud SQL Auth Proxy (prefer Workload Identity in prod)
# kubectl -n "$NAMESPACE" create secret generic cloudsql-sa-key --from-file=key.json=./gcp-sa.json

# ==== Static IP for Ingress ====
if ! gcloud compute addresses describe "$STATIC_IP_NAME" --global --project "$PROJECT_ID" >/dev/null 2>&1; then
  gcloud compute addresses create "$STATIC_IP_NAME" --global --project "$PROJECT_ID"
fi

# ==== Apply Manifests ====
sed "s|REGION-docker.pkg.dev/PROJECT_ID/a2eg/a2eg-backend:latest|${BACKEND_IMAGE}|g" backend_deployment.yaml | kubectl -n "$NAMESPACE" apply -f -
sed "s|REGION-docker.pkg.dev/PROJECT_ID/a2eg/a2eg-frontend:latest|${FRONTEND_IMAGE}|g" frontend_deployment.yaml | kubectl -n "$NAMESPACE" apply -f -
kubectl -n "$NAMESPACE" apply -f service_ingress.yaml

# ==== Wait for Ingress IP ====
echo "Waiting for Ingress external IP..."
for i in {1..30}; do
  IP=$(kubectl -n "$NAMESPACE" get ingress a2eg-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -n "$IP" ]]; then
    echo "Ingress available at: http://$IP"
    exit 0
  fi
  sleep 10
  echo "...still waiting ($i)"
done

echo "Timed out waiting for Ingress IP" >&2
exit 1
