#!/usr/bin/env bash
# Phase 3: production deploy.
#
# Builds the agent container, pushes it to Artifact Registry, then applies
# the Terraform in infra/ to (re)create the VPC, connector, NAT, firewall
# rules, IAM bindings, and the Cloud Run service itself.
#
# Required env vars:
#   PROJECT_ID   GCP project to deploy into
# Optional env vars:
#   REGION        default us-central1
#   REPO          Artifact Registry repo name, default adk-agents
#   SERVICE_NAME  Cloud Run service name, default inventory-assistant-agent
#   TAG           image tag, defaults to the current short git SHA

set -euo pipefail

for bin in gcloud terraform; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "error: '${bin}' is not installed or not on PATH." >&2
    case "${bin}" in
      gcloud)
        echo "  Install: https://cloud.google.com/sdk/docs/install" >&2
        ;;
      terraform)
        echo "  Install: https://developer.hashicorp.com/terraform/install" >&2
        echo "  macOS:   brew tap hashicorp/tap && brew install hashicorp/tap/terraform" >&2
        echo "  Linux:   see the apt/yum instructions at the link above" >&2
        ;;
    esac
    exit 1
  fi
done

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

echo "==> Applying Terraform"
pushd "${REPO_ROOT}/infra" >/dev/null
terraform init -upgrade
terraform apply \
  -var "project_id=${PROJECT_ID}" \
  -var "region=${REGION}" \
  -var "service_name=${SERVICE_NAME}" \
  -var "container_image=${IMAGE}"
popd >/dev/null

echo "==> Done. '${SERVICE_NAME}' is deployed with internal-only ingress and VPC egress."
