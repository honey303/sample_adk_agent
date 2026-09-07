#!/usr/bin/env bash
# Phase 3: production deploy, gcloud CLI only (no Terraform required).
#
# Builds the agent container, pushes it to Artifact Registry, then hands
# off to setup_infra_gcloud.sh to provision the VPC governance layer
# (private VPC, Serverless VPC Access connector, Cloud NAT, deny-by-default
# firewall, least-privilege IAM, a Secret Manager secret) and deploy the
# Cloud Run service -- all with plain `gcloud` commands. See infra/*.tf for
# an equivalent Terraform version, kept as an alternative for anyone who
# prefers IaC; nothing here depends on it.
#
# Required env vars:
#   PROJECT_ID   GCP project to deploy into
# Optional env vars:
#   REGION        default us-central1
#   REPO          Artifact Registry repo name, default adk-agents
#   SERVICE_NAME  Cloud Run service name, default inventory-assistant-agent
#   TAG           image tag, defaults to the current short git SHA
#   AUTHORIZED_INVOKERS  comma-separated IAM members allowed to invoke the
#                        service (see setup_infra_gcloud.sh)

set -euo pipefail

if ! command -v gcloud >/dev/null 2>&1; then
  echo "error: 'gcloud' is not installed or not on PATH." >&2
  echo "  Install: https://cloud.google.com/sdk/docs/install" >&2
  exit 1
fi

: "${PROJECT_ID:?Set PROJECT_ID to your GCP project id}"
REGION="${REGION:-us-central1}"
REPO="${REPO:-adk-agents}"
SERVICE_NAME="${SERVICE_NAME:-inventory-assistant-agent}"
TAG="${TAG:-$(git rev-parse --short HEAD 2>/dev/null || date +%s)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/${SERVICE_NAME}:${TAG}"

echo "==> Enabling required APIs"
gcloud services enable \
  run.googleapis.com \
  vpcaccess.googleapis.com \
  aiplatform.googleapis.com \
  secretmanager.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  compute.googleapis.com \
  --project "${PROJECT_ID}"

echo "==> Ensuring Artifact Registry repo '${REPO}' exists"
if ! gcloud artifacts repositories describe "${REPO}" \
    --location "${REGION}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud artifacts repositories create "${REPO}" \
    --repository-format=docker \
    --location "${REGION}" \
    --project "${PROJECT_ID}"
fi

echo "==> Building and pushing ${IMAGE}"
gcloud builds submit "${REPO_ROOT}/agent" \
  --tag "${IMAGE}" \
  --project "${PROJECT_ID}"

echo "==> Provisioning VPC governance and deploying Cloud Run"
PROJECT_ID="${PROJECT_ID}" \
  REGION="${REGION}" \
  SERVICE_NAME="${SERVICE_NAME}" \
  IMAGE="${IMAGE}" \
  AUTHORIZED_INVOKERS="${AUTHORIZED_INVOKERS:-}" \
  "${SCRIPT_DIR}/setup_infra_gcloud.sh"

echo "==> Done. '${SERVICE_NAME}' is deployed with internal-only ingress and VPC egress."
