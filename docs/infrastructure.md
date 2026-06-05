# Infrastructure (Terraform)

All Terraform lives under `infra/terraform/`. The configuration is split into independent roots: local Kubernetes bootstrap (kind), GitOps resource bootstrap, the AWS dev environment, and a one-off bootstrap root that provisions the remote state backend.

See also: [Architecture](architecture.md), [Operations](operations.md), [Security](security.md).

## Terraform root layout

Each directory below is a separate Terraform root with its own state. They are applied independently.

| Root | Path | Backend | Providers | Provisions |
|------|------|---------|-----------|------------|
| Local platform | `infra/terraform/envs/local/platform` | Local | kubernetes ~> 2.36, helm ~> 3.1 | 4 namespaces, Helm releases for ArgoCD, ArgoCD Image Updater, kube-prometheus-stack |
| Local GitOps bootstrap | `infra/terraform/envs/local/gitops-bootstrap` | Local | kubernetes ~> 2.36 | ArgoCD AppProject, 3 Applications, Image Updater CR (applied from `gitops/argocd/`) |
| AWS dev | `infra/terraform/envs/aws/dev` | S3 (remote) | aws ~> 6.0 | ECR repo, GitHub OIDC provider + IAM role/policy, minimal VPC |
| AWS state bootstrap | `infra/terraform/bootstrap/aws-state` | Local | aws ~> 6.0 | S3 state bucket (versioned, encrypted), DynamoDB lock table |

Region for all AWS roots is `eu-north-1`, AWS profile `cicd-platform-dev`.

## Local platform roots

### infra/terraform/envs/local/platform

Bootstraps a local kind cluster into a working platform. Uses the `kubernetes` and `helm` providers, both reading `~/.kube/config`. No backend block, state is local.

Provisions:

- Namespaces: `argocd`, `go-service`, `node-service`, `monitoring`. The `argocd` namespace ignores annotation drift via a `lifecycle` block.
- Helm release `argocd`, chart `argo-cd` v9.5.14 from `https://argoproj.github.io/argo-helm`, into `argocd`. Default values.
- Helm release `argocd-image-updater`, chart `argocd-image-updater` v1.2.1 from the same repo, into `argocd`. Custom values: log level `debug`, git user `argocd-image-updater`, git email `argocd-image-updater@users.noreply.github.com`, and a GHCR registry entry referencing credentials at `pullsecret:argocd/ghcr-image-updater`.
- Helm release `kube-prometheus-stack`, chart `kube-prometheus-stack` v85.2.2 from `https://prometheus-community.github.io/helm-charts`, into `monitoring`. Default values.

Key variables (all `string`):

| Variable | Default |
|----------|---------|
| `argocd_namespace` | `argocd` |
| `go_service_namespace` | `go-service` |
| `node_service_namespace` | `node-service` |
| `monitoring_namespace` | `monitoring` |

Outputs: `argocd_namespace`, `go_namespace`, `node_namespace`.

> The `pullsecret:argocd/ghcr-image-updater` secret is created outside Terraform (see [Security](security.md#sops--age-secrets)). The Helm release references it but does not create it.

### infra/terraform/envs/local/gitops-bootstrap

Applies the ArgoCD GitOps resources after the platform root is up. Uses only the `kubernetes` provider (`~/.kube/config`). Local state, no separate variables or outputs.

It loads YAML directly from the repo (repo root resolved as `${path.module}/../../../../..`) and applies each as a `kubernetes_manifest`:

| Resource | Source file |
|----------|-------------|
| `platform_project` | `gitops/argocd/projects/platform-project.yml` |
| `go_service_app` | `gitops/argocd/applications/go-service-app.yml` |
| `node_service_app` | `gitops/argocd/applications/node-service-app.yml` |
| `monitoring_app` | `gitops/argocd/applications/monitoring-app.yml` |
| `image_updater_cr` | `gitops/argocd/image-updater/custom-resource.yml` |

Once applied, ArgoCD reconciles the Applications automatically (auto-sync with prune + self-heal).

## AWS roots

### infra/terraform/bootstrap/aws-state

Run this first. It provisions the remote state backend that the AWS dev root consumes. Provider `aws` ~> 6.0 (locked 6.48.0), region `eu-north-1`, profile `cicd-platform-dev`. Local state (a backend cannot store its own creation).

Provisions:

- `aws_s3_bucket.state_storage`: name `cicd-platform-dev-tfstate-980481493011` (`${project_name}-${environment}-${state_bucket_name}`).
  - Versioning enabled (`aws_s3_bucket_versioning`).
  - Server-side encryption AES256 (`aws_s3_bucket_server_side_encryption_configuration`).
  - Public access fully blocked (`aws_s3_bucket_public_access_block`: all four flags true).
- `aws_dynamodb_table.lock_table`: name `cicd-platform-dev-tflock` (`${project_name}-${environment}-${lock_table_name}`), billing `PAY_PER_REQUEST`, hash key `LockID` (string).

Variables: `aws_region` (`eu-north-1`), `aws_profile` (`cicd-platform-dev`), `project_name` (`cicd-platform`), `environment` (`dev`), `state_bucket_name` (`tfstate-980481493011`), `lock_table_name` (`tflock`).

Outputs: `state_bucket_name`, `lock_table_name`, `aws_region`.

### infra/terraform/envs/aws/dev

The AWS dev environment. Provider `aws` ~> 6.0 (locked 6.47.0), region `eu-north-1`, profile `cicd-platform-dev`. Uses the S3 backend (see below).

Provisions ECR, GitHub OIDC + IAM, and a minimal VPC, detailed in [AWS resources](#aws-resources).

Variables:

| Variable | Type | Default |
|----------|------|---------|
| `aws_region` | string | `eu-north-1` |
| `aws_profile` | string | `cicd-platform-dev` |
| `project_name` | string | `cicd-platform` |
| `environment` | string | `dev` |
| `github_owner` | string | `eann1s` |
| `github_repo` | string | `cicd-platform` |
| `vpc_cidr` | string | `10.20.0.0/16` |
| `public_subnet_cidrs` | list(string) | `["10.20.1.0/24", "10.20.2.0/24"]` |
| `availability_zones` | list(string) | `["eu-north-1a", "eu-north-1b"]` |

Outputs: `go_service_repository_name`, `go_service_repository_url`, `go_service_repository_arn`, `github_actions_ecr_push_role_arn`, `vpc_id`, `public_subnet_ids`, `internet_gateway_id`, `public_route_table_id`.

Common tags: `Project=cicd-platform`, `Environment=dev`, `ManagedBy=terraform`, `Repository=eann1s/cicd-platform`.

## Remote state

The AWS dev root stores state remotely in S3 with DynamoDB locking. Backend block in `infra/terraform/envs/aws/dev`:

```hcl
backend "s3" {
  bucket         = "cicd-platform-dev-tfstate-980481493011"
  key            = "envs/aws/dev/terraform.tfstate"
  region         = "eu-north-1"
  dynamodb_table = "cicd-platform-dev-tflock"
  profile        = "cicd-platform-dev"
  encrypt        = true
}
```

- S3 bucket holds state objects; versioning lets you recover prior state.
- DynamoDB table `cicd-platform-dev-tflock` (hash key `LockID`) prevents concurrent operations.
- Both are created by the `bootstrap/aws-state` root, which itself uses local state.

### Backend migration (local -> S3)

The bucket and lock table must exist before the dev root can use them. Order:

```bash
# 1. Provision the backend with local state
terraform -chdir=infra/terraform/bootstrap/aws-state init
terraform -chdir=infra/terraform/bootstrap/aws-state apply

# 2. Initialize the dev root against the S3 backend
terraform -chdir=infra/terraform/envs/aws/dev init
#    Terraform prompts: "Do you want to copy existing state to the new backend?"
#    Answer yes to migrate any pre-existing local state into S3.

# 3. Normal workflow
terraform -chdir=infra/terraform/envs/aws/dev plan
terraform -chdir=infra/terraform/envs/aws/dev apply
```

If you re-point or change the backend later, `terraform init -migrate-state` performs the move.

## AWS resources

### ECR

- `aws_ecr_repository.go_service`: name `cicd-platform-dev-go-service` (`${local.name_prefix}-go-service`).
  - Image tag mutability: `IMMUTABLE`.
  - Scan on push: enabled.
  - Registry: `980481493011.dkr.ecr.eu-north-1.amazonaws.com`.

This repository is the target of the manual `aws-ecr-push.yml` workflow (see [Architecture](architecture.md#aws-integration-flow)).

### GitHub OIDC IAM role

Lets GitHub Actions push to ECR without long-lived AWS keys.

- `aws_iam_openid_connect_provider.github_actions`
  - URL: `https://token.actions.githubusercontent.com`
  - Client ID list: `["sts.amazonaws.com"]`
  - Thumbprint: `6938fd4d98bab03faadb97b34396831e3780aea1`
- `aws_iam_role.github_actions_ecr_push`: name `cicd-platform-dev-github-actions-ecr-push`.

Trust policy (`aws_iam_policy_document.github_actions_assume_role`):

- Action `sts:AssumeRoleWithWebIdentity`, principal is the federated OIDC provider.
- Audience condition: `token.actions.githubusercontent.com:aud == sts.amazonaws.com`.
- Subject condition restricts to:
  - `repo:eann1s/cicd-platform:ref:refs/heads/master`
  - `repo:eann1s/cicd-platform:ref:refs/tags/go-service-v*`

ECR push policy (`aws_iam_policy_document.github_actions_ecr_push`), scoped for least privilege:

- Statement 1: `ecr:GetAuthorizationToken` on `*` (required to be account-wide).
- Statement 2, on the go-service repository ARN only:
  - `ecr:BatchCheckLayerAvailability`
  - `ecr:InitiateLayerUpload`
  - `ecr:UploadLayerPart`
  - `ecr:CompleteLayerUpload`
  - `ecr:PutImage`
  - `ecr:DescribeRepositories`
  - `ecr:BatchGetImage`

The role ARN is consumed by `aws-ecr-push.yml`: `arn:aws:iam::980481493011:role/cicd-platform-dev-github-actions-ecr-push`.

### Minimal VPC

- `aws_vpc.main`: CIDR `10.20.0.0/16`, DNS support and DNS hostnames enabled.
- `aws_subnet.public` (count 2), CIDRs `10.20.1.0/24`, `10.20.2.0/24` in AZs `eu-north-1a`, `eu-north-1b`; `map_public_ip_on_launch = true`.
- `aws_internet_gateway.main`: attached to the VPC.
- `aws_route_table.public`: default route `0.0.0.0/0` -> IGW; associated to both public subnets via `aws_route_table_association.public`.

Public subnets only, no private subnets or NAT gateway in this configuration. This VPC is provisioned but not yet wired to the consumer services (workloads run on the local kind cluster). Connecting workloads to AWS networking is a future extension.

## Common Terraform commands

Run from the repository root using `-chdir` (preferred, avoids `cd` permission prompts), or `cd` into the root first.

```bash
# Local platform
terraform -chdir=infra/terraform/envs/local/platform init
terraform -chdir=infra/terraform/envs/local/platform plan
terraform -chdir=infra/terraform/envs/local/platform apply

# Local GitOps bootstrap (run after platform)
terraform -chdir=infra/terraform/envs/local/gitops-bootstrap init
terraform -chdir=infra/terraform/envs/local/gitops-bootstrap apply

# AWS state bootstrap (run first for AWS)
terraform -chdir=infra/terraform/bootstrap/aws-state init
terraform -chdir=infra/terraform/bootstrap/aws-state apply

# AWS dev
terraform -chdir=infra/terraform/envs/aws/dev init
terraform -chdir=infra/terraform/envs/aws/dev plan
terraform -chdir=infra/terraform/envs/aws/dev apply
```

Format and validate (matching the checks in `ci-terraform.yml`):

```bash
# Format check, recursive, across all roots
terraform fmt -check -recursive infra/terraform

# Validate without contacting a backend
terraform -chdir=infra/terraform/envs/local/platform init -backend=false
terraform -chdir=infra/terraform/envs/local/platform validate

terraform -chdir=infra/terraform/envs/local/gitops-bootstrap init -backend=false
terraform -chdir=infra/terraform/envs/local/gitops-bootstrap validate
```

`-backend=false` lets you init and validate without S3 credentials or a configured backend, this is what CI uses.

## State files and what not to commit

State and provider caches must stay out of version control. The root `.gitignore` already excludes:

```
.terraform/
**/.terraform/
**/terraform.tfstate
**/terraform.tfstate.backup
.env
.env.prod
```

Rules:

- Never commit `*.tfstate` or `*.tfstate.backup`, they may contain resource attributes and secrets in plaintext. The AWS dev root keeps state in S3; the local roots keep it on disk where you ran them.
- Never commit `.terraform/` (provider plugins and backend config cache).
- Never commit `*.tfvars` files that carry secrets. None are tracked today; if you add one with sensitive values, add it to `.gitignore` first.
- Lock files (`.terraform.lock.hcl`) are safe and intended to be committed.

Before declaring infra work done, check `git status` for an accidentally staged `.tfstate` or `.terraform/` entry.
