#!/usr/bin/env bash
# Provisions the enterprise VPC governance layer and deploys the Cloud Run
# service using plain `gcloud` commands -- no Terraform required.
#
# Mirrors the resources in infra/*.tf one for one (that Terraform stays in
# the repo as an alternative for anyone who prefers IaC, but nothing here
# depends on it): a private VPC, a Serverless VPC Access connector, Cloud
# NAT, deny-by-default firewall rules, a least-privilege runtime service
# account, a Secret Manager secret for the internal API key, and an
# internal-ingress-only Cloud Run service.
#
# Safe to re-run: every resource is created only if it doesn't already
# exist; `gcloud run deploy` and the IAM bindings are idempotent by nature.
#
# Required env vars: PROJECT_ID, REGION, SERVICE_NAME, IMAGE
# Optional env vars:
#   NETWORK_NAME         default adk-agents-vpc
#   SUBNET_CIDR          default 10.10.0.0/24
#   CONNECTOR_CIDR       default 10.10.8.0/28
#   RUNTIME_SA_NAME      default inventory-assistant-run
#   INTERNAL_API_KEY     value stored in Secret Manager; a random one is
#                        generated if unset and the secret doesn't exist yet
#   AUTHORIZED_INVOKERS  comma-separated IAM members allowed to invoke the
#                        service, e.g. "serviceAccount:gw@PROJECT.iam.gserviceaccount.com"
#                        (empty by default: nobody but project owners can invoke it)

set -euo pipefail

if ! command -v gcloud >/dev/null 2>&1; then
  echo "error: 'gcloud' is not installed or not on PATH." >&2
  echo "  Install: https://cloud.google.com/sdk/docs/install" >&2
  exit 1
fi

: "${PROJECT_ID:?Set PROJECT_ID}"
: "${REGION:?Set REGION}"
: "${SERVICE_NAME:?Set SERVICE_NAME}"
: "${IMAGE:?Set IMAGE}"

NETWORK_NAME="${NETWORK_NAME:-adk-agents-vpc}"
SUBNET_NAME="${NETWORK_NAME}-subnet"
CONNECTOR_NAME="${NETWORK_NAME}-conn"
ROUTER_NAME="${NETWORK_NAME}-router"
NAT_NAME="${NETWORK_NAME}-nat"
SUBNET_CIDR="${SUBNET_CIDR:-10.10.0.0/24}"
CONNECTOR_CIDR="${CONNECTOR_CIDR:-10.10.8.0/28}"
RUNTIME_SA_NAME="${RUNTIME_SA_NAME:-inventory-assistant-run}"
RUNTIME_SA_EMAIL="${RUNTIME_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
SECRET_NAME="inventory-assistant-internal-key"
AUTHORIZED_INVOKERS="${AUTHORIZED_INVOKERS:-}"

echo "==> VPC network '${NETWORK_NAME}'"
if ! gcloud compute networks describe "${NETWORK_NAME}" \
    --project "${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute networks create "${NETWORK_NAME}" \
    --project "${PROJECT_ID}" \
    --subnet-mode=custom
fi

echo "==> Subnet '${SUBNET_NAME}' (${SUBNET_CIDR}, private Google access)"
if ! gcloud compute networks subnets describe "${SUBNET_NAME}" \
    --project "${PROJECT_ID}" --region "${REGION}" >/dev/null 2>&1; then
  gcloud compute networks subnets create "${SUBNET_NAME}" \
    --project "${PROJECT_ID}" \
    --region "${REGION}" \
    --network "${NETWORK_NAME}" \
    --range "${SUBNET_CIDR}" \
    --enable-private-ip-google-access
fi

echo "==> Serverless VPC Access connector '${CONNECTOR_NAME}'"
if ! gcloud compute networks vpc-access connectors describe "${CONNECTOR_NAME}" \
    --project "${PROJECT_ID}" --region "${REGION}" >/dev/null 2>&1; then
  gcloud compute networks vpc-access connectors create "${CONNECTOR_NAME}" \
    --project "${PROJECT_ID}" \
    --region "${REGION}" \
    --network "${NETWORK_NAME}" \
    --range "${CONNECTOR_CIDR}" \
    --min-instances=2 \
    --max-instances=3
fi

echo "==> Cloud Router '${ROUTER_NAME}'"
if ! gcloud compute routers describe "${ROUTER_NAME}" \
    --project "${PROJECT_ID}" --region "${REGION}" >/dev/null 2>&1; then
  gcloud compute routers create "${ROUTER_NAME}" \
    --project "${PROJECT_ID}" \
    --region "${REGION}" \
    --network "${NETWORK_NAME}"
fi

echo "==> Cloud NAT '${NAT_NAME}'"
if ! gcloud compute routers nats describe "${NAT_NAME}" \
    --project "${PROJECT_ID}" --region "${REGION}" --router "${ROUTER_NAME}" >/dev/null 2>&1; then
  gcloud compute routers nats create "${NAT_NAME}" \
    --project "${PROJECT_ID}" \
    --region "${REGION}" \
    --router "${ROUTER_NAME}" \
    --nat-custom-subnet-ip-ranges="${SUBNET_NAME}" \
    --auto-allocate-nat-external-ips \
    --enable-logging \
    --log-filter=ERRORS_ONLY
fi

echo "==> Firewall rules (deny-by-default egress)"
if ! gcloud compute firewall-rules describe "${NETWORK_NAME}-deny-all-egress" \
    --project "${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute firewall-rules create "${NETWORK_NAME}-deny-all-egress" \
    --project "${PROJECT_ID}" \
    --network "${NETWORK_NAME}" \
    --direction=EGRESS \
    --action=DENY \
    --rules=all \
    --destination-ranges=0.0.0.0/0 \
    --priority=65534
fi

if ! gcloud compute firewall-rules describe "${NETWORK_NAME}-allow-internal-egress" \
    --project "${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute firewall-rules create "${NETWORK_NAME}-allow-internal-egress" \
    --project "${PROJECT_ID}" \
    --network "${NETWORK_NAME}" \
    --direction=EGRESS \
    --action=ALLOW \
    --rules=tcp:443,tcp:8080 \
    --destination-ranges="${SUBNET_CIDR},${CONNECTOR_CIDR}" \
    --priority=1000
fi

# private.googleapis.com VIP: lets the connector reach Vertex AI / Secret
# Manager over Google's private network instead of the public internet.
if ! gcloud compute firewall-rules describe "${NETWORK_NAME}-allow-google-apis" \
    --project "${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute firewall-rules create "${NETWORK_NAME}-allow-google-apis" \
    --project "${PROJECT_ID}" \
    --network "${NETWORK_NAME}" \
    --direction=EGRESS \
    --action=ALLOW \
    --rules=tcp:443 \
    --destination-ranges=199.36.153.8/30 \
    --priority=1001
fi

echo "==> Runtime service account '${RUNTIME_SA_EMAIL}'"
if ! gcloud iam service-accounts describe "${RUNTIME_SA_EMAIL}" \
    --project "${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud iam service-accounts create "${RUNTIME_SA_NAME}" \
    --project "${PROJECT_ID}" \
    --display-name="Runtime identity for the Inventory Assistant ADK agent"
fi

echo "==> Least-privilege IAM roles for the runtime service account"
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${RUNTIME_SA_EMAIL}" \
  --role="roles/aiplatform.user" \
  --condition=None >/dev/null
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${RUNTIME_SA_EMAIL}" \
  --role="roles/secretmanager.secretAccessor" \
  --condition=None >/dev/null

echo "==> Secret '${SECRET_NAME}' for INTERNAL_API_KEY"
if ! gcloud secrets describe "${SECRET_NAME}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud secrets create "${SECRET_NAME}" \
    --project "${PROJECT_ID}" \
    --replication-policy=automatic
  SECRET_VALUE="${INTERNAL_API_KEY:-$(openssl rand -hex 32 2>/dev/null || head -c32 /dev/urandom | base64)}"
  printf '%s' "${SECRET_VALUE}" | gcloud secrets versions add "${SECRET_NAME}" \
    --project "${PROJECT_ID}" \
    --data-file=-
fi

echo "==> Deploying Cloud Run service '${SERVICE_NAME}'"
gcloud run deploy "${SERVICE_NAME}" \
  --project "${PROJECT_ID}" \
  --region "${REGION}" \
  --image "${IMAGE}" \
  --service-account "${RUNTIME_SA_EMAIL}" \
  --vpc-connector "${CONNECTOR_NAME}" \
  --vpc-egress=private-ranges-only \
  --ingress=internal-and-cloud-load-balancing \
  --no-allow-unauthenticated \
  --min-instances=0 \
  --max-instances=5 \
  --cpu=1 \
  --memory=512Mi \
  --port=8080 \
  --set-env-vars="INTERNAL_API_BASE_URL=http://inventory-api.internal:8080" \
  --set-secrets="INTERNAL_API_KEY=${SECRET_NAME}:latest" \
  --quiet

if [ -n "${AUTHORIZED_INVOKERS}" ]; then
  echo "==> Granting roles/run.invoker to: ${AUTHORIZED_INVOKERS}"
  IFS=',' read -ra MEMBERS <<< "${AUTHORIZED_INVOKERS}"
  for member in "${MEMBERS[@]}"; do
    gcloud run services add-iam-policy-binding "${SERVICE_NAME}" \
      --project "${PROJECT_ID}" \
      --region "${REGION}" \
      --member="${member}" \
      --role="roles/run.invoker"
  done
else
  echo "==> No AUTHORIZED_INVOKERS set: nobody but project owners can invoke this service."
fi

SERVICE_URL="$(gcloud run services describe "${SERVICE_NAME}" \
  --project "${PROJECT_ID}" --region "${REGION}" --format='value(status.url)')"
echo "==> Cloud Run URL: ${SERVICE_URL} (internal ingress only)"
