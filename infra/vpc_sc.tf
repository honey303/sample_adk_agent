# Optional, org-level control: wraps the project's Vertex AI, Cloud Run
# and Secret Manager APIs in a VPC Service Controls perimeter so that
# even a caller with valid IAM credentials cannot exfiltrate data to
# those APIs from outside the perimeter (e.g. a stolen key used from a
# personal Google Cloud project). Requires an Access Context Manager
# policy to already exist for the organization -- set enable_vpc_sc =
# true and access_policy_id once that policy exists.
data "google_project" "current" {
  count      = var.enable_vpc_sc ? 1 : 0
  project_id = var.project_id
}

resource "google_access_context_manager_service_perimeter" "agent_perimeter" {
  count  = var.enable_vpc_sc ? 1 : 0
  parent = "accessPolicies/${var.access_policy_id}"
  name   = "accessPolicies/${var.access_policy_id}/servicePerimeters/adk_agents_perimeter"
  title  = "adk_agents_perimeter"

  status {
    resources = ["projects/${data.google_project.current[0].number}"]

    restricted_services = [
      "aiplatform.googleapis.com",
      "run.googleapis.com",
      "secretmanager.googleapis.com",
    ]

    vpc_accessible_services {
      enable_restriction = true
      allowed_services = [
        "aiplatform.googleapis.com",
        "run.googleapis.com",
        "secretmanager.googleapis.com",
      ]
    }

    ingress_policies {
      ingress_from {
        sources {
          access_level = "*"
        }
        identity_type = "ANY_IDENTITY"
      }
      ingress_to {
        resources = ["*"]
        operations {
          service_name = "run.googleapis.com"
          method_selectors {
            method = "*"
          }
        }
      }
    }
  }
}
