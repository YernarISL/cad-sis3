#!/usr/bin/env bash
# Failure tests for the messaging part (week 9 requirements).
#
#   ./scripts/test-messaging.sh duplicate <app-stack>  -> same event published twice, processed once
#   ./scripts/test-messaging.sh poison    <app-stack>  -> a failing message ends up in the DLQ
#   ./scripts/test-messaging.sh dlq       <app-stack>  -> show how many messages are in the DLQ
set -euo pipefail
CMD="${1:?usage: test-messaging.sh duplicate|poison|dlq <app-stack>}"
STACK="${2:?usage: test-messaging.sh duplicate|poison|dlq <app-stack>}"
REGION="${AWS_REGION:-$(aws configure get region)}"

out() { aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
          --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }

dlq_count() {
  aws sqs get-queue-attributes --region "$REGION" --queue-url "$(out DeadLetterQueueUrl)" \
    --attribute-names ApproximateNumberOfMessages \
    --query 'Attributes.ApproximateNumberOfMessages' --output text
}

case "$CMD" in
  duplicate)
    TOPIC="$(out TopicArn)"; TABLE="$(out TableName)"; LOGS="$(out WorkerLogGroupName)"
    ORDER_ID="dup-test-$(date +%s)"
    EVENT="{\"event_id\":\"evt-$ORDER_ID\",\"event_type\":\"OrderPlaced\",\"event_version\":1,\"occurred_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"source\":\"manual-test\",\"data\":{\"order_id\":\"$ORDER_ID\",\"item\":\"duplicate-test\",\"quantity\":1}}"
    for i in 1 2; do
      echo "Publishing the SAME event (copy $i), order_id=$ORDER_ID"
      aws sns publish --region "$REGION" --topic-arn "$TOPIC" --message "$EVENT" \
        --message-attributes '{"event_type":{"DataType":"String","StringValue":"OrderPlaced"}}' \
        --query MessageId --output text
    done
    echo "Waiting 30 s for the worker..."; sleep 30
    echo "--- Worker log lines for $ORDER_ID (expect 1x PROCESSED and 1x DUPLICATE):"
    aws logs filter-log-events --region "$REGION" --log-group-name "$LOGS" \
      --filter-pattern "\"$ORDER_ID\"" --query 'events[].message' --output text
    echo "--- DynamoDB item (expect exactly one):"
    aws dynamodb get-item --region "$REGION" --table-name "$TABLE" \
      --key "{\"order_id\":{\"S\":\"$ORDER_ID\"}}" --output json
    ;;
  poison)
    URL="$(out AlbUrl)"
    echo "DLQ messages before: $(dlq_count)"
    curl -fsS -X POST "$URL/orders" -H 'Content-Type: application/json' -d '{"item":"poison","quantity":1}'
    echo
    echo "The worker will fail 5 times (once every visibility timeout, ~30 s), then SQS moves it to the DLQ."
    for i in $(seq 1 16); do
      sleep 20
      C="$(dlq_count)"
      echo "  after $((i*20)) s: DLQ messages = $C"
      [ "$C" != "0" ] && { echo "PASS: poison message is in the DLQ"; exit 0; }
    done
    echo "Not in the DLQ yet - check the worker logs (FAILED ... receive_count=N)"
    ;;
  dlq)
    echo "DLQ messages: $(dlq_count)"
    ;;
  *) echo "unknown command $CMD"; exit 1 ;;
esac
