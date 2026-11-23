"""Domain events used by the API (producer) and the worker (consumer).

An event is a fact that already happened ("an order was placed").
The API publishes it to SNS; SNS copies it into the SQS queue; the worker reads it.
"""
import uuid
from datetime import datetime, timezone

ORDER_PLACED = "OrderPlaced"


def build_order_placed(item: str, quantity: int) -> dict:
    """Create a new OrderPlaced event with a fresh order_id and event_id."""
    return {
        "event_id": str(uuid.uuid4()),      # unique id of this event (for tracing)
        "event_type": ORDER_PLACED,
        "event_version": 1,                 # lets us change the format later without breaking old consumers
        "occurred_at": datetime.now(timezone.utc).isoformat(),
        "source": "orders-api",
        "data": {
            "order_id": str(uuid.uuid4()),  # the DEDUPLICATION KEY used by the worker
            "item": item,
            "quantity": quantity,
        },
    }
