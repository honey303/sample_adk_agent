variable "project_id" {
  description = "GCP project ID that hosts the agent"
  type        = string
}

variable "region" {
  description = "Region for Cloud Run, the VPC connector, and Cloud NAT"
  type        = string
  default     = "us-central1"
}

variable "network_name" {
  description = "Name of the VPC created for ADK agent workloads"
  type        = string
  default     = "adk-agents-vpc"
}

variable "subnet_cidr" {
  description = "Primary CIDR range for the private subnet"
  type        = string
  default     = "10.10.0.0/24"
}

variable "vpc_connector_cidr" {
  description = "/28 CIDR range reserved for the Serverless VPC Access connector"
  type        = string
  default     = "10.10.8.0/28"
}

variable "service_name" {
  description = "Cloud Run service name"
  type        = string
  default     = "inventory-assistant-agent"
}

variable "container_image" {
  description = "Fully qualified image reference, e.g. us-central1-docker.pkg.dev/PROJECT/adk-agents/inventory-assistant:TAG"
  type        = string
}

variable "authorized_invoker_members" {
  description = "IAM members allowed to invoke the Cloud Run service, e.g. [\"serviceAccount:gateway@PROJECT.iam.gserviceaccount.com\"]. Left empty, nobody but project owners can invoke it."
  type        = list(string)
  default     = []
}

variable "enable_vpc_sc" {
  description = "Whether to create a VPC Service Controls perimeter around the agent's dependencies. Requires an existing Access Context Manager policy at the org level."
  type        = bool
  default     = false
}

variable "access_policy_id" {
  description = "Numeric ID of an existing Access Context Manager policy (required only when enable_vpc_sc = true)"
  type        = string
  default     = ""
}
