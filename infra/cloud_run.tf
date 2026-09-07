resource "google_cloud_run_v2_service" "agent" {
  name     = var.service_name
  project  = var.project_id
  location = var.region

  # Only reachable from inside the VPC / via an internal load balancer --
  # never from the public internet, regardless of IAM bindings.
  ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  template {
    service_account = google_service_account.agent_runtime.email

    vpc_access {
      connector = google_vpc_access_connector.connector.id
      # PRIVATE_RANGES_ONLY: only RFC1918 traffic goes through the
      # connector (reaching internal-api.internal, Cloud SQL, etc).
      # Calls to Vertex AI / Gemini still take the direct Google path,
      # not the connector + NAT, which keeps egress cheaper and faster.
      egress = "PRIVATE_RANGES_ONLY"
    }

    scaling {
      min_instance_count = 0
      max_instance_count = 5
    }

    containers {
      image = var.container_image

      ports {
        container_port = 8080
      }

      env {
        name  = "INTERNAL_API_BASE_URL"
        value = "http://inventory-api.internal:8080"
      }

      env {
        name = "INTERNAL_API_KEY"
        value_source {
          secret_key_ref {
            secret  = "inventory-assistant-internal-key"
            version = "latest"
          }
        }
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }

      startup_probe {
        http_get {
          path = "/healthz"
        }
        initial_delay_seconds = 5
        period_seconds        = 5
        failure_threshold     = 3
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }
}
