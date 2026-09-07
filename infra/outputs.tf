output "cloud_run_url" {
  description = "Internal URL of the deployed agent service"
  value       = google_cloud_run_v2_service.agent.uri
}

output "runtime_service_account" {
  description = "Service account the agent runs as"
  value       = google_service_account.agent_runtime.email
}

output "vpc_connector_id" {
  description = "Serverless VPC Access connector used for egress"
  value       = google_vpc_access_connector.connector.id
}
