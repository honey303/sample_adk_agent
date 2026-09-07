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
  mock_internal_api.py   # local stand-in for inventory-api.internal (see below)
  Dockerfile
  requirements.txt
infra/                        # Terraform equivalent of the same infra (optional, see below)
scripts/deploy.sh             # build image -> push -> setup_infra_gcloud.sh
scripts/setup_infra_gcloud.sh # VPC, connector, NAT, firewall, IAM, Cloud Run -- plain gcloud, no Terraform
blog/from-prototype-to-production.md
```

## Run it locally (phase 1)

The agent's tools call `inventory-api.internal` — a hostname that, by
design, only resolves inside the real enterprise VPC (see `infra/vpc.tf`).
There's nothing to actually call by default, so `agent/mock_internal_api.py`
is a tiny stand-in for it: run that first so the demo has a real backend to
talk to, then point the agent at it with `INTERNAL_API_BASE_URL`.

```bash
cd agent
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# terminal 1: the mock internal API, listening on :8090
python mock_internal_api.py
```

```bash
# terminal 2: the agent, pointed at the mock
cd agent && source .venv/bin/activate
export GOOGLE_API_KEY=...      # or configure Vertex AI application-default credentials
export INTERNAL_API_BASE_URL=http://localhost:8090
python local_run.py "Do we have SKU-10293 in stock, and can I ship 50 units to us-east?"
```

Without `INTERNAL_API_BASE_URL` set (or without the mock server running),
the tools call the real `inventory-api.internal` default, can't resolve it,
and degrade to an `"unavailable"` response instead of crashing — that's the
intended behavior for an actual outage, not something to debug around, but
it does mean you'll only see the agent's real reasoning over live data once
the mock server above is running and wired up.

## Run the container locally (phase 2)

Optional — this is a local sanity check that the Dockerfile and `server.py`
work together before deploying, not a requirement. If you don't have Docker
installed (`docker: command not found`) and don't want to install it, skip
straight to phase 3: `scripts/deploy.sh` builds the image with `gcloud
builds submit`, which runs on Cloud Build rather than your machine, so it
never touches a local `docker` binary. It does need the `gcloud` CLI
installed and authenticated instead.

If you do want to test the container locally, install Docker first
(Docker Desktop on Mac/Windows, or `curl -fsSL https://get.docker.com | sh`
on Linux). Then keep `mock_internal_api.py` running from phase 1 (still on
`:8090` on the host) and point the container at the host's network:

```bash
cd agent
docker build -t inventory-assistant .
docker run -d -p 8080:8080 \
  -e GOOGLE_API_KEY=... \
  -e INTERNAL_API_BASE_URL=http://host.docker.internal:8090 \
  --add-host=host.docker.internal:host-gateway \
  --name inventory-assistant inventory-assistant
curl localhost:8080/healthz    # expect {"status":"ok"} once the container is up
curl -X POST localhost:8080/invoke -H 'content-type: application/json' \
  -d '{"query": "Is SKU-10293 in stock?"}'
```

`--add-host=host.docker.internal:host-gateway` is what lets the container
reach the mock API running on your host; it's required on Linux and a
harmless no-op on Docker Desktop for Mac/Windows, which already provides
that mapping. `-d` runs the container in the background so the `curl`
commands actually get to run afterward in the same shell; `docker stop
inventory-assistant` when you're done.

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

This builds and pushes the image with Cloud Build, then runs
`scripts/setup_infra_gcloud.sh` to stand up the VPC, Serverless VPC Access
connector, Cloud NAT, deny-by-default firewall rules, the runtime service
account, a Secret Manager secret for the internal API key, and the Cloud
Run service itself (internal ingress only, no public invoker) — all with
plain `gcloud` commands. The only tool it needs beyond what phase 2 already
required is the [`gcloud` CLI](https://cloud.google.com/sdk/docs/install),
authenticated (`gcloud auth login` and `gcloud config set project
$PROJECT_ID`); no Terraform install required. It's safe to re-run —
`setup_infra_gcloud.sh` checks whether each resource already exists before
creating it.

By default nobody can invoke the deployed service (it's internal-ingress
only, with no `run.invoker` binding beyond project owners). To authorize
specific callers, set `AUTHORIZED_INVOKERS` to a comma-separated list of
IAM members before running the script, e.g.
`AUTHORIZED_INVOKERS="serviceAccount:gateway@${PROJECT_ID}.iam.gserviceaccount.com" ./scripts/deploy.sh`.

**Prefer Terraform?** `infra/*.tf` describes the identical set of resources
as IaC — it's kept in the repo as an alternative, not used by
`deploy.sh`. See the blog post for the full walkthrough of each resource,
including the optional VPC Service Controls perimeter (`infra/vpc_sc.tf`,
which currently has no `gcloud`-only equivalent in this repo since it
depends on an org-level Access Context Manager policy).
