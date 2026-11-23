import json

import pytest
from botocore.exceptions import ClientError

import worker
from events import build_order_placed


class FakeTable:
    """Behaves like DynamoDB put_item with ConditionExpression attribute_not_exists(order_id)."""

    def __init__(self):
        self.items = {}

    def put_item(self, Item, ConditionExpression=None):
        if ConditionExpression and Item["order_id"] in self.items:
            raise ClientError({"Error": {"Code": "ConditionalCheckFailedException"}}, "PutItem")
        self.items[Item["order_id"]] = Item


class FakeSQS:
    def __init__(self):
        self.deleted = []

    def delete_message(self, QueueUrl, ReceiptHandle):
        self.deleted.append(ReceiptHandle)


def test_same_event_twice_is_processed_once():
    table = FakeTable()
    event = build_order_placed("book", 1)
    assert worker.handle_event(event, table) == "processed"
    assert worker.handle_event(event, table) == "duplicate"
    assert len(table.items) == 1


def test_poison_message_is_not_deleted():
    table, sqs = FakeTable(), FakeSQS()
    msg = {"Body": json.dumps(build_order_placed("poison", 1)), "ReceiptHandle": "rh-1",
           "MessageId": "m-1", "Attributes": {"ApproximateReceiveCount": "1"}}
    worker.process_message(msg, table, sqs, "queue-url")
    assert sqs.deleted == []          # left in the queue -> retried -> DLQ after maxReceiveCount
    assert table.items == {}


def test_good_message_is_deleted():
    table, sqs = FakeTable(), FakeSQS()
    msg = {"Body": json.dumps(build_order_placed("book", 3)), "ReceiptHandle": "rh-2",
           "MessageId": "m-2", "Attributes": {"ApproximateReceiveCount": "1"}}
    worker.process_message(msg, table, sqs, "queue-url")
    assert sqs.deleted == ["rh-2"]


def test_unknown_event_type_raises():
    with pytest.raises(ValueError):
        worker.handle_event({"event_type": "Something", "data": {}}, FakeTable())
