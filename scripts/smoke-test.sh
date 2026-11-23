#!/usr/bin/env bash
# Checks that a deployed stack really works:
#   1) /health answers 200 and shows the expected version (commit SHA)
#   2) POST /orders -> SNS -> SQS -> worker -> DynamoDB works end to end
# Usage: ./scripts/smoke-test.sh <app-stack-name> [expected-image-tag]
set -euo pipefail
STACK="${1:?usage: smoke-test.sh <app-stack-name> [expected-tag]}"
EXPECTED="${2:-}"
REGION="${AWS_REGION:-$(aws configure get region)}"

out() { aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
          --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
URL="$(out AlbUrl)"
echo "ALB: $URL"

# 1) Health + version. Retry: a new ALB needs a minute before its DNS name resolves.
for i in $(seq 1 30); do
  BODY="$(curl -fsS --max-time 5 "$URL/health" 2>/dev/null || true)"
  if [ -n "$BODY" ]; then
    echo "Health: $BODY"
    if [ -z "$EXPECTED" ] || echo "$BODY" | grep -q "$EXPECTED"; then break; fi
    echo "  (old version still answering, waiting...)"
  else
    echo "  attempt $i: no answer yet, waiting 10 s"
  fi
  sleep 10
  [ "$i" = 30 ] && { echo "FAIL: service not healthy / wrong version"; exit 1; }
done

# 2) End-to-end messaging test.
RESP="$(curl -fsS -X POST "$URL/orders" -H 'Content-Type: application/json' \
         -d '{"item":"smoke-test","quantity":1}')"
echo "POST /orders: $RESP"
ORDER_ID="$(echo "$RESP" | sed -E 's/.*"order_id":"([^"]+)".*/\1/')"
for i in $(seq 1 12); do
  if RESULT="$(curl -fsS "$URL/orders/$ORDER_ID" 2>/dev/null)"; then
    echo "GET /orders/$ORDER_ID: $RESULT"
    echo "PASS: smoke test OK"
    exit 0
  fi
  echo "  worker has not processed it yet, waiting 5 s"
  sleep 5
done
echo "FAIL: order was not processed in 60 s - check the worker logs"
exit 1
