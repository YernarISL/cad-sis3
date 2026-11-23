#!/usr/bin/env bash
# ONE command that builds the whole system from a clean checkout.
#
#   ./deploy.sh <name> [dev|prod]
#
#   ./deploy.sh dev              -> stacks cad-sis3-dev-ecr and cad-sis3-dev-app
#   ./deploy.sh defence          -> a second, independent copy (the reproducibility test)
#   PREVIEW=1 ./deploy.sh dev    -> only create the change set for the app stack, do not execute it
#   USE_NAT=true ./deploy.sh dev -> run tasks in private subnets behind a NAT gateway (costs more)
#
# Needs: AWS CLI v2 (logged in), Docker running, git. On Windows use Git Bash or WSL.
set -euo pipefail

NAME="${1:?usage: ./deploy.sh <name> [dev|prod]   example: ./deploy.sh dev}"
ENV="${2:-dev}"
PROJECT="cad-sis3"
ECR_STACK="${PROJECT}-${NAME}-ecr"
APP_STACK="${PROJECT}-${NAME}-app"
USE_NAT="${USE_NAT:-false}"
REGION="${AWS_REGION:-$(aws configure get region || true)}"
cd "$(dirname "$0")"

# ---- 0. Safety checks -------------------------------------------------------
for cmd in aws docker git; do
  command -v "$cmd" >/dev/null || { echo "ERROR: '$cmd' is not installed"; exit 1; }
done
[ -n "$REGION" ] || { echo "ERROR: no region. Run: export AWS_REGION=eu-central-1"; exit 1; }
if [ -n "$(git status --porcelain -- app infra)" ]; then
  echo "ERROR: uncommitted changes in app/ or infra/."
  echo "       Commit first - the image tag is the commit SHA, so every image must match a commit."
  exit 1
fi
TAG="$(git rev-parse HEAD)"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
echo "Account $ACCOUNT | region $REGION | env $ENV | commit $TAG"

# ---- 1. Registry stack ------------------------------------------------------
echo "==> 1/4 ECR stack: $ECR_STACK"
aws cloudformation deploy --region "$REGION" \
  --stack-name "$ECR_STACK" --template-file infra/ecr.yaml \
  --tags Project="$PROJECT" Name="$NAME" \
  --no-fail-on-empty-changeset
REPO_URI="$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$ECR_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='RepositoryUri'].OutputValue" --output text)"
echo "Repository: $REPO_URI"

# ---- 2. Build and push the image (only if this commit was never pushed) ------
echo "==> 2/4 Image $REPO_URI:$TAG"
if aws ecr describe-images --region "$REGION" --repository-name "${REPO_URI#*/}" \
     --image-ids imageTag="$TAG" >/dev/null 2>&1; then
  echo "Image for this commit already exists - skipping build (tags are immutable)."
else
  aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin "${REPO_URI%%/*}"
  docker build --platform linux/amd64 -t "$REPO_URI:$TAG" app/
  docker push "$REPO_URI:$TAG"
fi

# ---- 3. Application stack ---------------------------------------------------
echo "==> 3/4 App stack: $APP_STACK"
EXTRA=()
[ "${PREVIEW:-0}" = "1" ] && EXTRA+=(--no-execute-changeset)
aws cloudformation deploy --region "$REGION" \
  --stack-name "$APP_STACK" --template-file infra/app.yaml \
  --parameter-overrides Env="$ENV" RepositoryUri="$REPO_URI" ImageTag="$TAG" UseNatGateway="$USE_NAT" \
  --capabilities CAPABILITY_IAM \
  --tags Project="$PROJECT" Name="$NAME" Env="$ENV" \
  --no-fail-on-empty-changeset ${EXTRA[@]+"${EXTRA[@]}"}

if [ "${PREVIEW:-0}" = "1" ]; then
  echo "Preview only. Review the change set in the console (CloudFormation -> $APP_STACK -> Change sets),"
  echo "then run again without PREVIEW=1."
  exit 0
fi

# ---- 4. Smoke test ----------------------------------------------------------
echo "==> 4/4 Smoke test"
bash ./scripts/smoke-test.sh "$APP_STACK" "$TAG"
