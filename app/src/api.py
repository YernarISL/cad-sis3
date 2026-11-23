"""Orders API - runs on ECS Fargate behind the Application Load Balancer.

Endpoints
  GET  /health            -> used by the ALB health check; also shows the running version (image tag)
  POST /orders            -> publishes an OrderPlaced event to SNS and returns 202 Accepted
  GET  /orders/{order_id} -> reads the result that the worker wrote to DynamoDB
"""
import json
import logging
import os
from functools import lru_cache

import boto3
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from events import build_order_placed

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("api")

# APP_VERSION is set by the CloudFormation task definition to the image tag (= git commit SHA).
APP_VERSION = os.environ.get("APP_VERSION", "local")

app = FastAPI(title="CAD SIS3 Orders API", version=APP_VERSION)


class OrderIn(BaseModel):
    item: str = Field(min_length=1, max_length=100)
    quantity: int = Field(ge=1, le=1000)


@lru_cache
def sns_client():
    # No access keys here: boto3 takes temporary credentials from the ECS task role.
    return boto3.client("sns")


@lru_cache
def orders_table():
    return boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])


@app.get("/health")
def health():
    return {"status": "ok", "version": APP_VERSION, "pipeline": "practice 7 pipeline"}


@app.post("/orders", status_code=202)
def place_order(order: OrderIn):
    event = build_order_placed(order.item, order.quantity)
    sns_client().publish(
        TopicArn=os.environ["TOPIC_ARN"],
        Message=json.dumps(event),
        MessageAttributes={
            "event_type": {"DataType": "String", "StringValue": event["event_type"]},
        },
    )
    log.info(
        "published %s order_id=%s event_id=%s",
        event["event_type"], event["data"]["order_id"], event["event_id"],
    )
    # 202 = "accepted, will be processed later" (the worker does the work asynchronously)
    return {"status": "ACCEPTED", "order_id": event["data"]["order_id"], "event_id": event["event_id"]}


@app.get("/orders/{order_id}")
def get_order(order_id: str):
    item = orders_table().get_item(Key={"order_id": order_id}).get("Item")
    if not item:
        raise HTTPException(status_code=404, detail="Order not processed yet, or unknown id")
    return item
