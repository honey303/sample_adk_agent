# From Prototype to Production: Deploying ADK Agents on Cloud Run with Enterprise VPC Governance

Building an agent with Google's [Agent Development Kit](https://google.github.io/adk-docs/) (ADK) takes an afternoon. Getting that agent in front of real users, inside an enterprise network, without punching a hole in the perimeter, takes a lot more care. This post walks through both halves using one concrete example — an "Inventory Assistant" agent — and the full, runnable code lives alongside it in this repository under `agent/` and `infra/`.

The gap between the two halves is usually where agent projects stall: a prototype that works great against a public Gemini endpoint on a laptop, and a security team that (correctly) won't let an unauthenticated, internet-facing container reach internal systems. Closing that gap is an infrastructure problem as much as an agent-design problem, so this post treats them together.

## The agent

The Inventory Assistant answers two kinds of questions for an internal team: "is this SKU in stock?" and "can we fulfill this order in this region?". Both answers come from an internal inventory API — `http://inventory-api.internal:8080` — that has no public IP. That detail is the whole reason this post exists: the moment an agent's tools need to reach something private, "deploy the container somewhere with a public URL" stops being a viable production plan.

```python
# agent/inventory_assistant/agent.py
import os

from google.adk.agents import Agent

from .tools import check_order_eligibility, get_inventory_status

MODEL = os.environ.get("ADK_MODEL", "gemini-2.5-flash")

root_agent = Agent(
    name="inventory_assistant",
    model=MODEL,
    description=(
        "Enterprise inventory assistant that answers stock and "
        "order-eligibility questions using internal systems reachable "
        "only over the corporate VPC."
    ),
    instruction=(
        "You are an inventory assistant for an internal enterprise team. "
        "Use the get_inventory_status tool to check stock for a SKU, and "
        "check_order_eligibility to confirm whether an order can be "
        "fulfilled in a given region. Always call a tool before answering "
        "a question about stock or order eligibility rather than guessing."
    ),
    tools=[get_inventory_status, check_order_eligibility],
)
```

ADK turns plain Python functions into tools automatically, as long as they have type hints and a docstring the model can read:

```python
# agent/inventory_assistant/tools.py (excerpt)
def get_inventory_status(sku: str) -> dict:
    """Look up current stock levels for a SKU from the internal inventory service."""
    resp = requests.get(
        f"{INTERNAL_API_BASE_URL}/v1/inventory/{sku}",
        timeout=REQUEST_TIMEOUT_SECONDS,
    )
    resp.raise_for_status()
    return resp.json()
```

`INTERNAL_API_BASE_URL` is an environment variable, not a hardcoded host — that's what lets the exact same code run against a stub locally and against the real internal service once it's on the VPC.

## Phase 1: prototype

No container, no cloud project, just a loop that exercises the agent through ADK's `Runner` and an in-memory session:

```python
# agent/local_run.py (excerpt)
session_service = InMemorySessionService()
runner = Runner(agent=root_agent, app_name=APP_NAME, session_service=session_service)

await session_service.create_session(app_name=APP_NAME, user_id=user_id, session_id=session_id)
content = types.Content(role="user", parts=[types.Part(text=query)])

async for event in runner.run_async(user_id=user_id, session_id=session_id, new_message=content):
    if event.is_final_response() and event.content and event.content.parts:
        print(event.content.parts[0].text)
```

```bash
cd agent
pip install -r requirements.txt
export GOOGLE_API_KEY=...
python local_run.py "Do we have SKU-10293 in stock, and can I ship 50 units to us-east?"
```

Off the corporate network, `inventory-api.internal` won't resolve — the tool catches the `requests.RequestException` and returns `{"status": "unavailable"}` instead of crashing the run. That graceful degradation is what makes phase 1 possible at all without VPC access, but it also means you won't see the agent reason over real data unless something is actually listening on the other end. `agent/mock_internal_api.py` is exactly that: a few in-memory routes standing in for the real internal service, so `INTERNAL_API_BASE_URL=http://localhost:8090 python local_run.py "..."` exercises the full tool-calling loop with genuine responses instead of `"unavailable"` placeholders. This is the whole point of phase 1: validate the agent's reasoning and tool-calling behavior cheaply, before infrastructure enters the picture at all.

## Phase 2: containerize

Prototype code and production code should be the same code. The only thing that changes is how it's invoked: instead of a Python script driving the `Runner` directly, a small FastAPI app does, so Cloud Run has a standard HTTP surface to route to.

```python
# agent/server.py (excerpt)
@app.post("/invoke", response_model=InvokeResponse)
async def invoke(req: InvokeRequest, request: Request) -> InvokeResponse:
    _enforce_internal_auth(request)
    session_id = req.session_id or str(uuid.uuid4())
    ...
    content = types.Content(role="user", parts=[types.Part(text=req.query)])
    async for event in runner.run_async(user_id=req.user_id, session_id=session_id, new_message=content):
        if event.is_final_response() and event.content and event.content.parts:
            final_text = event.content.parts[0].text or ""
    return InvokeResponse(session_id=session_id, response=final_text)
```

`_enforce_internal_auth` checks a shared-secret header sourced from Secret Manager. It's not the primary access control — Cloud Run's own IAM and ingress settings are (more on that below) — it's a second, independent check so that a misconfigured IAM binding doesn't silently become the only thing standing between the internet and this agent's tools.

The `Dockerfile` is a standard non-root, slim-Python build; Cloud Run injects `PORT` at runtime, which `uvicorn` picks up:

```dockerfile
# agent/Dockerfile
FROM python:3.12-slim
WORKDIR /app
RUN useradd --create-home --uid 1000 appuser
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
USER appuser
ENV PORT=8080
EXPOSE 8080
CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8080"]
```

```bash
docker build -t inventory-assistant agent/
docker run -p 8080:8080 -e GOOGLE_API_KEY=... inventory-assistant
curl -X POST localhost:8080/invoke -d '{"query": "Is SKU-10293 in stock?"}'
```

This runs and answers exactly like phase 1 — it just does it behind a URL now, which is what makes phase 3 possible.

## Phase 3: production, with enterprise VPC governance

This is where most of the real engineering happens, and it's expressed entirely as Terraform in `infra/` so it's reviewable and repeatable rather than a sequence of `gcloud` commands someone ran once. Four pieces do the work.

### 1. A private VPC and a route in

Cloud Run services don't sit inside a VPC by default — they're fully managed and, by default, egress straight to the internet. A [Serverless VPC Access connector](https://cloud.google.com/vpc/docs/serverless-vpc-access) is what bridges the two, giving the agent's container a path into the private subnet where `inventory-api.internal` lives:

```hcl
# infra/vpc.tf (excerpt)
resource "google_compute_network" "adk_vpc" {
  name                    = var.network_name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "private_subnet" {
  name                     = "${var.network_name}-subnet"
  ip_cidr_range            = var.subnet_cidr
  network                  = google_compute_network.adk_vpc.id
  private_ip_google_access = true
}

resource "google_vpc_access_connector" "connector" {
  name          = "${var.network_name}-conn"
  network       = google_compute_network.adk_vpc.name
  ip_cidr_range = var.vpc_connector_cidr
  min_instances = 2
  max_instances = 3
}
```

Cloud NAT sits alongside it so that any traffic that does need to leave the VPC (nothing in this example does, since Gemini calls take Cloud Run's normal direct path, not the connector) has a controlled, logged egress point rather than a public IP on the connector itself.

### 2. Deny-by-default egress

The firewall posture is inverted from what's typical: nothing leaves the VPC unless a rule says so.

```hcl
# infra/vpc.tf (excerpt)
resource "google_compute_firewall" "deny_all_egress" {
  name      = "${var.network_name}-deny-all-egress"
  network   = google_compute_network.adk_vpc.name
  direction = "EGRESS"
  priority  = 65534
  deny { protocol = "all" }
  destination_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "allow_internal_egress" {
  name      = "${var.network_name}-allow-internal-egress"
  network   = google_compute_network.adk_vpc.name
  direction = "EGRESS"
  priority  = 1000
  allow {
    protocol = "tcp"
    ports    = ["443", "8080"]
  }
  destination_ranges = [var.subnet_cidr, var.vpc_connector_cidr]
}
```

A separate, narrow rule allows HTTPS to `199.36.153.8/30` — the `private.googleapis.com` VIP — so calls to Vertex AI and Secret Manager stay on Google's private network path instead of the public internet, even from inside a VPC that otherwise denies everything by default.

### 3. Least-privilege identity, internal-only ingress

The Cloud Run service runs as its own service account — never the default compute service account — with exactly two roles: invoke Vertex AI, read secrets.

```hcl
# infra/iam.tf (excerpt)
resource "google_service_account" "agent_runtime" {
  account_id   = "inventory-assistant-run"
  display_name = "Runtime identity for the Inventory Assistant ADK agent"
}

resource "google_project_iam_member" "vertex_user" {
  role   = "roles/aiplatform.user"
  member = "serviceAccount:${google_service_account.agent_runtime.email}"
}
```

Nobody can invoke the service by default — `authorized_invoker_members` is an empty list unless a caller is explicitly added — and ingress is locked to internal traffic only, so even a leaked URL is useless from outside the network:

```hcl
# infra/cloud_run.tf (excerpt)
resource "google_cloud_run_v2_service" "agent" {
  ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  template {
    service_account = google_service_account.agent_runtime.email

    vpc_access {
      connector = google_vpc_access_connector.connector.id
      egress    = "PRIVATE_RANGES_ONLY"
    }

    containers {
      image = var.container_image
      env {
        name = "INTERNAL_API_KEY"
        value_source {
          secret_key_ref {
            secret  = "inventory-assistant-internal-key"
            version = "latest"
          }
        }
      }
    }
  }
}
```

`egress = "PRIVATE_RANGES_ONLY"` means only RFC1918 traffic (the internal inventory API) is forced through the connector; the agent's calls to Gemini still take Cloud Run's direct, faster path to Google's APIs rather than being routed through the connector and NAT unnecessarily.

### 4. An optional org-wide backstop: VPC Service Controls

Everything above governs *this project's* network path. VPC Service Controls governs data exfiltration risk at the org level: even a caller with valid IAM credentials for Vertex AI or Secret Manager can't use them from outside an approved perimeter — for example, if a service account key were copied out and used from an unauthorized project. This is genuinely optional (it requires an org-level Access Context Manager policy that's usually managed by a platform team, not per-project), so it's gated behind a variable:

```hcl
# infra/vpc_sc.tf (excerpt)
resource "google_access_context_manager_service_perimeter" "agent_perimeter" {
  count  = var.enable_vpc_sc ? 1 : 0
  parent = "accessPolicies/${var.access_policy_id}"
  status {
    resources            = ["projects/${data.google_project.current[0].number}"]
    restricted_services   = ["aiplatform.googleapis.com", "run.googleapis.com", "secretmanager.googleapis.com"]
    vpc_accessible_services {
      enable_restriction = true
      allowed_services    = ["aiplatform.googleapis.com", "run.googleapis.com", "secretmanager.googleapis.com"]
    }
  }
}
```

## Shipping it

`scripts/deploy.sh` chains the two halves: build and push the image, then apply the Terraform.

```bash
export PROJECT_ID=your-gcp-project
./scripts/deploy.sh
```

Under the hood it enables the required APIs, builds `agent/` with Cloud Build, pushes to Artifact Registry, and runs `terraform apply` against `infra/`, passing the freshly built image reference through as `container_image`. The result is a Cloud Run revision that:

- is unreachable from the public internet (`ingress = INTERNAL_LOAD_BALANCER`),
- has nobody authorized to invoke it until you add them to `authorized_invoker_members`,
- can reach the internal inventory API through the VPC connector and nothing else outbound by default,
- runs as a service account with two IAM roles, not the project-wide default,
- and reads its shared secret from Secret Manager rather than a baked-in env var.

## What actually changed between phase 1 and phase 3

Notably: none of the agent code did. `root_agent`, `get_inventory_status`, and `check_order_eligibility` are byte-for-byte the same in the local prototype and the Cloud Run deployment. What changed is everything around the agent — how it's invoked, how it's authenticated, and how its outbound calls are routed and restricted. That separation is the actual goal of treating "prototype to production" as two different concerns: agent behavior gets validated once, cheaply, and the infrastructure hardening it needs to be trusted with real internal data gets built and reviewed independently, as code, in `infra/`.
