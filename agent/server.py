"""Phase 3: production entrypoint.

Wraps the ADK agent in a small FastAPI app so it can run as a standard
Cloud Run HTTP service. Cloud Run itself enforces the network boundary
(internal-only ingress, IAM-authenticated invokers, VPC egress for
outbound calls) -- see infra/cloud_run.tf. The header check below is
defense-in-depth on top of that, not a replacement for it.
"""

import logging
import os
import uuid
from typing import Optional

from fastapi import FastAPI, HTTPException, Request
from pydantic import BaseModel

from google.adk.runners import Runner
from google.adk.sessions import InMemorySessionService
from google.genai import types

from inventory_assistant.agent import root_agent

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("inventory_assistant.server")

APP_NAME = "inventory_assistant"
INTERNAL_API_KEY = os.environ.get("INTERNAL_API_KEY")

session_service = InMemorySessionService()
runner = Runner(agent=root_agent, app_name=APP_NAME, session_service=session_service)

app = FastAPI(title="Inventory Assistant Agent")


class InvokeRequest(BaseModel):
    query: str
    user_id: str = "default-user"
    session_id: Optional[str] = None


class InvokeResponse(BaseModel):
    session_id: str
    response: str


@app.get("/healthz")
async def healthz() -> dict:
    return {"status": "ok"}


@app.post("/invoke", response_model=InvokeResponse)
async def invoke(req: InvokeRequest, request: Request) -> InvokeResponse:
    _enforce_internal_auth(request)

    session_id = req.session_id or str(uuid.uuid4())
    session = await session_service.get_session(
        app_name=APP_NAME, user_id=req.user_id, session_id=session_id
    )
    if session is None:
        await session_service.create_session(
            app_name=APP_NAME, user_id=req.user_id, session_id=session_id
        )

    content = types.Content(role="user", parts=[types.Part(text=req.query)])

    final_text = ""
    async for event in runner.run_async(
        user_id=req.user_id, session_id=session_id, new_message=content
    ):
        if event.is_final_response() and event.content and event.content.parts:
            final_text = event.content.parts[0].text or ""

    if not final_text:
        raise HTTPException(status_code=502, detail="Agent produced no response")

    return InvokeResponse(session_id=session_id, response=final_text)


def _enforce_internal_auth(request: Request) -> None:
    """Reject requests missing the internal shared secret, if one is configured.

    Cloud Run is deployed with ingress=internal and no unauthenticated
    invokers, so this only runs for callers that already hold a valid
    identity token. It stops a request from reaching agent tools (and
    therefore the internal VPC) if INTERNAL_API_KEY is unset or rotated
    out from under a caller.
    """
    if INTERNAL_API_KEY and request.headers.get("x-internal-api-key") != INTERNAL_API_KEY:
        raise HTTPException(status_code=403, detail="Forbidden")
