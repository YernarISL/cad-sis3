# CAD SIS3 — Orders system on ECS Fargate, built only from CloudFormation

A small event-driven system:

```
client ──HTTP──▶ ALB ──▶ API (ECS Fargate) ──publish OrderPlaced──▶ SNS topic
                                                                     │ (filter: event_type = OrderPlaced)
                                                                     ▼
                       DynamoDB ◀── worker (ECS Fargate, idempotent) ◀── SQS queue ──(5 failed receives)──▶ DLQ
```

Everything is created by two CloudFormation templates. Nothing is clicked in the console.

| Path | What it is |
|---|---|
| `app/` | FastAPI API (`src/api.py`), SQS worker (`src/worker.py`), Dockerfile, unit tests |
| `infra/ecr.yaml` | ECR repository: immutable tags, scan on push, lifecycle policy |
| `infra/app.yaml` | VPC, ALB, ECS cluster + 2 services, SNS, SQS + DLQ, DynamoDB, log groups, IAM roles |
| `deploy.sh` | The one deploy command |
| `destroy.sh` | Deletes everything for one copy |
| `scripts/smoke-test.sh` | Health + end-to-end check |
| `scripts/test-messaging.sh` | Duplicate-event test and dead-letter-queue test |

## Before the first deploy (manual, once per laptop/account)

1. AWS account with an IAM user or SSO login that can create these resources (not the root user).
2. Install: AWS CLI v2, Docker Desktop (running), git. On Windows use Git Bash or WSL.
3. `aws configure` (or `aws configure sso`) and `export AWS_REGION=eu-central-1`.

## Deploy — one command

```bash
./deploy.sh dev
```

It creates stack `cad-sis3-dev-ecr`, builds the image with the commit SHA as tag, pushes it,
creates stack `cad-sis3-dev-app`, and runs the smoke test. The ALB URL is printed at the end.

Other options:

```bash
PREVIEW=1 ./deploy.sh dev        # create a change set only - review it, then run without PREVIEW
USE_NAT=true ./deploy.sh dev     # tasks in private subnets behind one NAT gateway (+0.045 USD/h)
./deploy.sh defence              # a second, independent copy (reproducibility test)
```

## Test

```bash
cd app && pip install -r requirements.txt -r requirements-dev.txt && pytest -q    # unit tests, no AWS
./scripts/smoke-test.sh cad-sis3-dev-app                                          # live system
./scripts/test-messaging.sh duplicate cad-sis3-dev-app                            # idempotency
./scripts/test-messaging.sh poison cad-sis3-dev-app                               # DLQ
```

## Delete everything

```bash
./destroy.sh dev
```

## Design notes

* Image tag = git commit SHA, never `latest`. The template rejects any other tag (AllowedPattern).
* No resource has a hard-coded name, so two copies can live in one account.
* Two kinds of IAM role: one execution role (pull image, write logs) and one task role per service
  (API may only publish to SNS and read DynamoDB; worker may only read/delete from SQS and write DynamoDB).
* The worker is idempotent: a conditional write on `order_id` (the deduplication key) means a duplicate
  delivery does nothing.
* No secrets anywhere: the code gets temporary credentials from its task role.

## Practice 7 — CI/CD with GitHub Actions and OIDC (no access keys)

Every push to `main` runs `.github/workflows/deploy.yml`:

```
push ─▶ test job: ruff + pytest + cfn-lint ─▶ deploy job (environment: production)
          │                                     ├─ OIDC token ─▶ STS ─▶ 1-hour credentials (role cad-sis3-github-oidc-GitHubDeployRole-…)
          │                                     ├─ docker build + push  <ECR_REPO>:<commit SHA>
          │                                     ├─ aws cloudformation deploy ImageTag=<commit SHA> (as the CloudFormation execution role)
          ▼                                     └─ smoke test: /health shows the new SHA, an order is processed
   pull requests: test job only
```

One-time setup (laptop, admin credentials):

```bash
aws cloudformation deploy --stack-name cad-sis3-github-oidc --template-file infra/github-oidc.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides GitHubOwner=<owner> GitHubRepo=cad-sis3 SubjectFormat=immutable \
                        GitHubOwnerId=<owner id> GitHubRepoId=<repo id> CreateOidcProvider=true
```

GitHub → Settings → Environments → `production`; Settings → Secrets and variables → Actions → **Variables**:
`AWS_REGION`, `APP_STACK` (cad-sis3-dev-app), `ECR_REPO` (RepositoryUri output of cad-sis3-dev-ecr),
`DEPLOY_ROLE_ARN` and `CFN_EXEC_ROLE_ARN` (outputs of cad-sis3-github-oidc). No secrets are needed.

`.github/workflows/oidc-check.yml` (run by hand) prints the real OIDC `sub` claim and proves that a job
outside the `production` environment cannot get AWS credentials.

Teardown order: `./destroy.sh dev` first (the app stack uses the CloudFormation execution role to delete
itself), then `aws cloudformation delete-stack --stack-name cad-sis3-github-oidc`.
