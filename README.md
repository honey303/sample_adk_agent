# sample_adk_agent

A worked example for the blog post
[*From Prototype to Production: Deploying ADK Agents on Cloud Run with Enterprise VPC Governance*](blog/from-prototype-to-production.md).

It contains one agent (an "Inventory Assistant" built with Google's
[Agent Development Kit](https://google.github.io/adk-docs/)) taken through
three stages:

1. **Prototype** — run locally with an in-memory session, no infrastructure.
2. **Containerize** — the same agent behind a FastAPI server, in a Docker image.
3. **Production** — deployed to Cloud Run behind enterprise VPC governance:
   a private VPC, a Serverless VPC Access connector, Cloud NAT, deny-by-default
   firewall rules, least-privilege IAM, Secret Manager-backed config, and an
   optional VPC Service Controls perimeter.

## Layout

```
agent/
  inventory_assistant/   # the ADK agent: agent.py (root_agent) + tools.py
  local_run.py           # phase 1: run the agent locally
  server.py              # phase 3: FastAPI wrapper for Cloud Run
  Dockerfile
  requirements.txt
infra/                   # Terraform: VPC, connector, NAT, firewall, IAM, Cloud Run, VPC-SC
scripts/deploy.sh        # build image -> push -> terraform apply
blog/from-prototype-to-production.md
```

## Run it locally (phase 1)

```bash
cd agent
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
export GOOGLE_API_KEY=...      # or configure Vertex AI application-default credentials
python local_run.py "Do we have SKU-10293 in stock, and can I ship 50 units to us-east?"
```

The `get_inventory_status` / `check_order_eligibility` tools call
`INTERNAL_API_BASE_URL` (default `http://inventory-api.internal:8080`), which
won't resolve outside a real enterprise network — that's expected locally;
the tools degrade to an `"unavailable"` response instead of crashing.

## Run the container locally (phase 2)

```bash
cd agent
docker build -t inventory-assistant .
docker run -p 8080:8080 -e GOOGLE_API_KEY=... inventory-assistant
curl -X POST localhost:8080/invoke -H 'content-type: application/json' \
  -d '{"query": "Is SKU-10293 in stock?"}'
```

## Deploy to production (phase 3)

```bash
export PROJECT_ID=your-gcp-project
./scripts/deploy.sh
```

This builds and pushes the image with Cloud Build, then applies the
Terraform in `infra/` to stand up the VPC, connector, NAT, firewall rules,
runtime service account, and the Cloud Run service itself (internal ingress
only, no public invoker). See the blog post for the full walkthrough,
including the optional VPC Service Controls perimeter.
