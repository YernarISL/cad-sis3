import json

from fastapi.testclient import TestClient

import api


class FakeSNS:
    def __init__(self):
        self.published = []

    def publish(self, **kwargs):
        self.published.append(kwargs)
        return {"MessageId": "test"}


def make_client(monkeypatch):
    fake = FakeSNS()
    monkeypatch.setenv("TOPIC_ARN", "arn:aws:sns:eu-central-1:000000000000:test")
    monkeypatch.setattr(api, "sns_client", lambda: fake)
    return TestClient(api.app), fake


def test_health_returns_ok_and_version(monkeypatch):
    client, _ = make_client(monkeypatch)
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"
    assert "version" in resp.json()


def test_post_order_publishes_one_event(monkeypatch):
    client, fake = make_client(monkeypatch)
    resp = client.post("/orders", json={"item": "book", "quantity": 2})
    assert resp.status_code == 202
    assert len(fake.published) == 1
    event = json.loads(fake.published[0]["Message"])
    assert event["event_type"] == "OrderPlaced"
    assert event["data"]["order_id"] == resp.json()["order_id"]


def test_invalid_order_is_rejected_and_nothing_is_published(monkeypatch):
    client, fake = make_client(monkeypatch)
    resp = client.post("/orders", json={"item": "", "quantity": 0})
    assert resp.status_code == 422
    assert fake.published == []
