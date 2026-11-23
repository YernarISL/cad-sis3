"""Order worker - an IDEMPOTENT consumer of the SQS queue. Runs as a second ECS service.

Why idempotent? SQS standard queues deliver every message AT LEAST once.
The same event can arrive twice (a retry, a duplicate publish, a crash before delete).
Processing it twice must give the same result as processing it once.

How: the worker writes the order to DynamoDB with a CONDITIONAL put
("only if order_id does not exist yet"). order_id is the DEDUPLICATION KEY.
The first delivery succeeds; a second delivery fails the condition and is skipped.
The check and the write are one atomic operation, so two workers can never both win.
"""
import json
import logging
import os
import signal
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

from events import ORDER_PLACED

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("worker")

_running = True


class PoisonMessageError(Exception):
    """Raised on purpose for item == "poison", to test retries and the dead-letter queue."""


def _stop(signum, _frame):
    # ECS sends SIGTERM before it stops a task. We finish the current batch, then exit.
    global _running
    log.info("signal %s received, stopping after this batch", signum)
    _running = False


def handle_event(event: dict, table) -> str:
    """Apply one event. Returns "processed" or "duplicate". Raises if the event is bad."""
    if event.get("event_type") != ORDER_PLACED:
        raise ValueError(f"unknown event_type: {event.get('event_type')!r}")

    data = event["data"]
    if data["item"] == "poison":
        raise PoisonMessageError("simulated processing failure (DLQ test)")

    try:
        table.put_item(
            Item={
                "order_id": data["order_id"],          # partition key = deduplication key
                "event_id": event["event_id"],
                "item": data["item"],
                "quantity": int(data["quantity"]),
                "status": "PROCESSED",
                "processed_at": datetime.now(timezone.utc).isoformat(),
            },
            ConditionExpression="attribute_not_exists(order_id)",
        )
    except ClientError as err:
        if err.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return "duplicate"
        raise  # any other error (throttling, network): let SQS retry the message
    return "processed"


def process_message(msg: dict, table, sqs, queue_url: str) -> None:
    receive_count = msg.get("Attributes", {}).get("ApproximateReceiveCount", "?")
    try:
        event = json.loads(msg["Body"])
        result = handle_event(event, table)
        if result == "duplicate":
            log.warning("DUPLICATE skipped order_id=%s event_id=%s",
                        event["data"]["order_id"], event["event_id"])
        else:
            log.info("PROCESSED order_id=%s event_id=%s", event["data"]["order_id"], event["event_id"])
        # Delete only after success (or after a safe duplicate). Not deleting = "retry later".
        sqs.delete_message(QueueUrl=queue_url, ReceiptHandle=msg["ReceiptHandle"])
    except Exception:
        log.exception(
            "FAILED message_id=%s receive_count=%s - it will come back after the visibility "
            "timeout and move to the DLQ after maxReceiveCount attempts",
            msg.get("MessageId"), receive_count,
        )


def main() -> None:
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    queue_url = os.environ["QUEUE_URL"]
    sqs = boto3.client("sqs")
    table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
    log.info("worker started, version=%s, queue=%s", os.environ.get("APP_VERSION", "local"), queue_url)

    while _running:
        resp = sqs.receive_message(
            QueueUrl=queue_url,
            MaxNumberOfMessages=10,     # up to 10 messages per call = fewer API calls
            WaitTimeSeconds=20,         # long polling: wait for messages instead of busy-looping
            AttributeNames=["ApproximateReceiveCount"],
        )
        for msg in resp.get("Messages", []):
            process_message(msg, table, sqs, queue_url)

    log.info("worker stopped")


if __name__ == "__main__":
    main()
