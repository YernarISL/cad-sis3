#!/usr/bin/env bash
# Deletes BOTH stacks of one copy. The app stack first (it uses images from the registry),
# then the registry stack (EmptyOnDelete removes the images).
#   ./destroy.sh dev
#   ./destroy.sh defence
set -euo pipefail
NAME="${1:?usage: ./destroy.sh <name>}"
PROJECT="cad-sis3"
REGION="${AWS_REGION:-$(aws configure get region)}"

read -r -p "Delete stacks ${PROJECT}-${NAME}-app and ${PROJECT}-${NAME}-ecr in $REGION? Type yes: " OK
[ "$OK" = "yes" ] || { echo "Cancelled"; exit 1; }

for STACK in "${PROJECT}-${NAME}-app" "${PROJECT}-${NAME}-ecr"; do
  echo "==> deleting $STACK"
  aws cloudformation delete-stack --region "$REGION" --stack-name "$STACK"
  aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$STACK"
  echo "    deleted"
done
echo "Done. Now check: CloudFormation (no cad-sis3 stacks), ECS, EC2 -> Load balancers, VPC -> NAT gateways, Billing."
