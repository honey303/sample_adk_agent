import logging
import os

import requests

logger = logging.getLogger(__name__)

# Resolves to a private DNS / internal load balancer name that only exists
# inside the enterprise VPC. There is no public route to this host, which is
# the whole point: the agent can only do its job when it is running with a
# Serverless VPC Access connector attached.
INTERNAL_API_BASE_URL = os.environ.get(
    "INTERNAL_API_BASE_URL", "http://inventory-api.internal:8080"
)
REQUEST_TIMEOUT_SECONDS = 5


def get_inventory_status(sku: str) -> dict:
    """Look up current stock levels for a SKU from the internal inventory service.

    Args:
        sku: The stock keeping unit to look up, e.g. "SKU-10293".

    Returns:
        A dict with keys: sku, quantity_on_hand, warehouse, status.
    """
    try:
        resp = requests.get(
            f"{INTERNAL_API_BASE_URL}/v1/inventory/{sku}",
            timeout=REQUEST_TIMEOUT_SECONDS,
        )
        resp.raise_for_status()
        return resp.json()
    except requests.RequestException as exc:
        logger.warning("Inventory lookup failed for %s: %s", sku, exc)
        return {"sku": sku, "status": "unavailable", "error": str(exc)}


def check_order_eligibility(sku: str, quantity: int, region: str) -> dict:
    """Check whether an order for a SKU/quantity can be fulfilled in a region.

    Args:
        sku: The stock keeping unit being ordered.
        quantity: Number of units requested.
        region: Fulfillment region code, e.g. "us-east" or "eu-west".

    Returns:
        A dict with keys: sku, eligible, reason.
    """
    try:
        resp = requests.post(
            f"{INTERNAL_API_BASE_URL}/v1/orders/eligibility",
            json={"sku": sku, "quantity": quantity, "region": region},
            timeout=REQUEST_TIMEOUT_SECONDS,
        )
        resp.raise_for_status()
        return resp.json()
    except requests.RequestException as exc:
        logger.warning("Eligibility check failed for %s: %s", sku, exc)
        return {"sku": sku, "eligible": False, "error": str(exc)}
