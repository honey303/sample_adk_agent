# Custom VPC dedicated to ADK agent workloads. No default network, no
# auto-created subnets: every range here is deliberate.
resource "google_compute_network" "adk_vpc" {
  name                    = var.network_name
  project                 = var.project_id
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "private_subnet" {
  name                     = "${var.network_name}-subnet"
  project                  = var.project_id
  region                   = var.region
  network                  = google_compute_network.adk_vpc.id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true
}

# Lets Cloud Run reach resources inside the VPC (private APIs, internal
# services, Cloud SQL private IP, etc). Without this the agent's
# container has no route into the private network at all.
resource "google_vpc_access_connector" "connector" {
  name          = "${var.network_name}-conn"
  project       = var.project_id
  region        = var.region
  network       = google_compute_network.adk_vpc.name
  ip_cidr_range = var.vpc_connector_cidr
  min_instances = 2
  max_instances = 3
}

# Cloud NAT gives the connector's traffic a controlled, loggable egress
# path to the public internet (e.g. the Vertex AI / Gemini API endpoint)
# without ever assigning a public IP to the agent itself.
resource "google_compute_router" "router" {
  name    = "${var.network_name}-router"
  project = var.project_id
  region  = var.region
  network = google_compute_network.adk_vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.network_name}-nat"
  project                            = var.project_id
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.private_subnet.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# Deny-by-default egress, then explicitly allow only what the agent needs.
resource "google_compute_firewall" "deny_all_egress" {
  name      = "${var.network_name}-deny-all-egress"
  project   = var.project_id
  network   = google_compute_network.adk_vpc.name
  direction = "EGRESS"
  priority  = 65534

  deny {
    protocol = "all"
  }

  destination_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "allow_internal_egress" {
  name      = "${var.network_name}-allow-internal-egress"
  project   = var.project_id
  network   = google_compute_network.adk_vpc.name
  direction = "EGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["443", "8080"]
  }

  destination_ranges = [var.subnet_cidr, var.vpc_connector_cidr]
}

# private.googleapis.com VIP: lets the connector reach Google APIs
# (Vertex AI, Secret Manager) over a private route instead of the public
# internet, so those calls never leave Google's network.
resource "google_compute_firewall" "allow_google_apis_egress" {
  name      = "${var.network_name}-allow-google-apis"
  project   = var.project_id
  network   = google_compute_network.adk_vpc.name
  direction = "EGRESS"
  priority  = 1001

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  destination_ranges = ["199.36.153.8/30"]
}
