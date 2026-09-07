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
        "a question about stock or order eligibility rather than guessing. "
        "If a tool reports 'unavailable', tell the user the internal "
        "inventory system could not be reached rather than making up data."
    ),
    tools=[get_inventory_status, check_order_eligibility],
)
