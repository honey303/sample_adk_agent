"""Local stand-in for the enterprise inventory-api.internal service.

In production this host only exists inside the corporate VPC (see
infra/vpc.tf) and the agent reaches it through the Serverless VPC Access
connector. It has no public DNS entry, so there is nothing for the agent's
tools to call when you're testing outside that network -- which is every
local run. This script is a tiny in-memory stand-in for that API so
local_run.py and server.py have something real to hit.

Usage:
    python mock_internal_api.py
    # in another terminal:
    export INTERNAL_API_BASE_URL=http://localhost:8090
    python local_run.py "Is SKU-10293 in stock?"
"""

from fastapi import FastAPI

app = FastAPI(title="Mock inventory-api.internal")

_INVENTORY = {
    "SKU-10293": {"quantity_on_hand": 420, "warehouse": "PDX-1"},
    "SKU-88213": {"quantity_on_hand": 0, "warehouse": "PDX-1"},
}


@app.get("/v1/inventory/{sku}")
def get_inventory(sku: str) -> dict:
    item = _INVENTORY.get(sku)
    if item is None:
        return {"sku": sku, "status": "unknown_sku", "quantity_on_hand": 0}
    return {
        "sku": sku,
        "quantity_on_hand": item["quantity_on_hand"],
        "warehouse": item["warehouse"],
        "status": "in_stock" if item["quantity_on_hand"] > 0 else "out_of_stock",
    }


@app.post("/v1/orders/eligibility")
def check_eligibility(payload: dict) -> dict:
    sku = payload.get("sku")
    quantity = payload.get("quantity", 0)
    region = payload.get("region", "unknown")
    on_hand = _INVENTORY.get(sku, {}).get("quantity_on_hand", 0)
    eligible = on_hand >= quantity
    return {
        "sku": sku,
        "quantity": quantity,
        "region": region,
        "eligible": eligible,
        "reason": "sufficient_stock" if eligible else "insufficient_stock",
    }


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8090)
