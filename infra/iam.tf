# Dedicated runtime identity for the agent -- never the default compute
# service account, and never broader than the roles it actually uses.
resource "google_service_account" "agent_runtime" {
  project      = var.project_id
  account_id   = "inventory-assistant-run"
  display_name = "Runtime identity for the Inventory Assistant ADK agent"
}

resource "google_project_iam_member" "vertex_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.agent_runtime.email}"
}

resource "google_project_iam_member" "secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.agent_runtime.email}"
}

# No allUsers / allAuthenticatedUsers binding anywhere: invokers are an
# explicit allow-list, empty by default.
resource "google_cloud_run_v2_service_iam_member" "invokers" {
  for_each = toset(var.authorized_invoker_members)

  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.agent.name
  role     = "roles/run.invoker"
  member   = each.value
}
