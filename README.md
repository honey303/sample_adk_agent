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
docker run -d -p 8080:8080 -e GOOGLE_API_KEY=... --name inventory-assistant inventory-assistant
curl localhost:8080/healthz    # expect {"status":"ok"} once the container is up
curl -X POST localhost:8080/invoke -H 'content-type: application/json' \
  -d '{"query": "Is SKU-10293 in stock?"}'
```

`-d` runs the container in the background so the `curl` commands actually get
to run afterward in the same shell; `docker stop inventory-assistant` when
you're done.

**Getting "can't reach the server" / "server not found"?**

- Use `http://localhost:8080` (or `127.0.0.1:8080`), not the
  `http://0.0.0.0:8080` address `uvicorn` prints in its startup log —
  `0.0.0.0` is a bind address, not something a browser can connect to.
  `curl` and most browsers will refuse to resolve it.
- Confirm the container is actually running and listening:
  `docker ps` should list it, and `docker logs inventory-assistant` should
  show `Uvicorn running on http://0.0.0.0:8080`. If the container isn't in
  `docker ps`, it exited — the logs will show why (commonly a missing
  `GOOGLE_API_KEY` isn't fatal here since the model client is created lazily
  per-request, so look for an import error or bad `requirements.txt`
  install instead).
- Make sure `-p 8080:8080` was actually passed to `docker run` — without it,
  the port inside the container is never published to the host and
  `localhost:8080` will refuse the connection.
- `/invoke` only accepts `POST`. Opening `http://localhost:8080/invoke`
  directly in a browser sends a `GET` and returns `405 Method Not Allowed`,
  not a "server not found" error — a different symptom worth distinguishing
  from an actual connectivity problem.

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
