#!/usr/bin/env bash
# Sets up a way to actually reach the deployed Cloud Run service.
#
# The service is deployed with --ingress=internal-and-cloud-load-balancing
# and --no-allow-unauthenticated (see setup_infra_gcloud.sh /
# infra/cloud_run.tf), so it is NOT reachable from your laptop, full stop
# -- the request has to originate inside the VPC, regardless of IAM roles.
# This script creates a minimal, no-external-IP Compute Engine VM in the
# same private subnet, opens just enough firewall (IAP-tunneled SSH only,
# nothing public) to reach it, and grants its service account
# roles/run.invoker so it can call the service.
#
# Safe to re-run. Delete the VM when you're done testing:
#   gcloud compute instances delete "${VM_NAME:-adk-test-vm}" --project "$PROJECT_ID" --zone "$ZONE"
#
# Required env vars: PROJECT_ID, REGION, SERVICE_NAME
# Optional env vars:
#   NETWORK_NAME  default adk-agents-vpc (must match setup_infra_gcloud.sh)
#   ZONE          default ${REGION}-a
#   VM_NAME       default adk-test-vm

set -euo pipefail

if ! command -v gcloud >/dev/null 2>&1; then
  echo "error: 'gcloud' is not installed or not on PATH." >&2
  echo "  Install: https://cloud.google.com/sdk/docs/install" >&2
  exit 1
fi

: "${PROJECT_ID:?Set PROJECT_ID}"
: "${REGION:?Set REGION}"
: "${SERVICE_NAME:?Set SERVICE_NAME}"

NETWORK_NAME="${NETWORK_NAME:-adk-agents-vpc}"
SUBNET_NAME="${NETWORK_NAME}-subnet"
ZONE="${ZONE:-${REGION}-a}"
VM_NAME="${VM_NAME:-adk-test-vm}"

echo "==> Firewall rule allowing IAP-tunneled SSH (35.235.240.0/20 only, no public ingress)"
if ! gcloud compute firewall-rules describe "${NETWORK_NAME}-allow-iap-ssh" \
    --project "${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute firewall-rules create "${NETWORK_NAME}-allow-iap-ssh" \
    --project "${PROJECT_ID}" \
    --network "${NETWORK_NAME}" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:22 \
    --source-ranges=35.235.240.0/20
fi

echo "==> Test VM '${VM_NAME}' (no external IP)"
if ! gcloud compute instances describe "${VM_NAME}" \
    --project "${PROJECT_ID}" --zone "${ZONE}" >/dev/null 2>&1; then
  gcloud compute instances create "${VM_NAME}" \
    --project "${PROJECT_ID}" \
    --zone "${ZONE}" \
    --network "${NETWORK_NAME}" \
    --subnet "${SUBNET_NAME}" \
    --no-address \
    --machine-type=e2-micro \
    --image-family=debian-12 \
    --image-project=debian-cloud

  echo "==> Waiting for the VM to be reachable over IAP"
  for i in $(seq 1 30); do
    if gcloud compute instances describe "${VM_NAME}" \
        --project "${PROJECT_ID}" --zone "${ZONE}" \
        --format='value(status)' 2>/dev/null | grep -q RUNNING; then
      break
    fi
    if [ "${i}" -eq 30 ]; then
      echo "error: '${VM_NAME}' never reached RUNNING after 60s." >&2
      exit 1
    fi
    sleep 2
  done
fi

VM_SA="$(gcloud compute instances describe "${VM_NAME}" \
  --project "${PROJECT_ID}" --zone "${ZONE}" \
  --format='value(serviceAccounts[0].email)')"

echo "==> Granting roles/run.invoker on '${SERVICE_NAME}' to the VM's service account (${VM_SA})"
gcloud run services add-iam-policy-binding "${SERVICE_NAME}" \
  --project "${PROJECT_ID}" \
  --region "${REGION}" \
  --member="serviceAccount:${VM_SA}" \
  --role="roles/run.invoker" >/dev/null

SERVICE_URL="$(gcloud run services describe "${SERVICE_NAME}" \
  --project "${PROJECT_ID}" --region "${REGION}" --format='value(status.url)')"

cat <<EOF

==> Ready. SSH in over IAP (no external IP, no open ports needed):

  gcloud compute ssh ${VM_NAME} --project ${PROJECT_ID} --zone ${ZONE} --tunnel-through-iap

Then, from inside the VM, fetch an identity token from the metadata
server (no gcloud install needed on the VM) and call the service:

  SERVICE_URL="${SERVICE_URL}"
  TOKEN=\$(curl -s -H "Metadata-Flavor: Google" \\
    "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=\${SERVICE_URL}")
  curl -H "Authorization: Bearer \${TOKEN}" "\${SERVICE_URL}/healthz"
  curl -X POST -H "Authorization: Bearer \${TOKEN}" -H 'content-type: application/json' \\
    -d '{"query": "Is SKU-10293 in stock?"}' "\${SERVICE_URL}/invoke"

/invoke will report the inventory tool as "unavailable" unless
INTERNAL_API_BASE_URL on the Cloud Run service points at something real --
see the README section on testing the deployed endpoint for how to point
it at a copy of mock_internal_api.py running on this same VM.

EOF
