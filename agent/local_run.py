"""Phase 1: prototype loop.

Runs the agent locally with an in-memory session, no container and no
Cloud Run involved. Use this to iterate on prompts and tool logic before
promoting the agent to a real deployment.

Usage:
    python local_run.py "Do we have SKU-10293 in stock, and can I ship 50 units to us-east?"
"""

import asyncio
import sys
import uuid

from google.adk.runners import Runner
from google.adk.sessions import InMemorySessionService
from google.genai import types

from inventory_assistant.agent import root_agent

APP_NAME = "inventory_assistant"


async def main(query: str) -> None:
    session_service = InMemorySessionService()
    runner = Runner(agent=root_agent, app_name=APP_NAME, session_service=session_service)

    user_id = "local-dev"
    session_id = str(uuid.uuid4())
    await session_service.create_session(
        app_name=APP_NAME, user_id=user_id, session_id=session_id
    )

    content = types.Content(role="user", parts=[types.Part(text=query)])

    async for event in runner.run_async(
        user_id=user_id, session_id=session_id, new_message=content
    ):
        if event.is_final_response() and event.content and event.content.parts:
            print(event.content.parts[0].text)


if __name__ == "__main__":
    default_query = (
        "Do we have SKU-10293 in stock, and can I ship 50 units to us-east?"
    )
    query = sys.argv[1] if len(sys.argv) > 1 else default_query
    asyncio.run(main(query))
