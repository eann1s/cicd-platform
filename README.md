# cicd-platform

Internal CI/CD platform for building, scanning, signing, and shipping polyglot services to Kubernetes via GitOps. It covers the path from a service commit through container build, security gates, signed releases, and automated cluster delivery, with a local KinD-based environment and an AWS thin slice for ECR publishing.

The repository hosts two consumer services (a Go service and a Node/NestJS service) alongside the reusable GitHub Actions workflows, ArgoCD GitOps manifests, Terraform infrastructure, and observability config that move them through the pipeline.

## Platform capabilities

- Per-service CI: language-specific lint, test, and build pipelines for the Go and Node services via reusable workflows.
- Security scanning: Gitleaks secret scanning and Trivy filesystem/image scanning, with stricter severity gates (`HIGH,CRITICAL`) on master and release tags vs. `CRITICAL` on PRs.
- SBOM generation: CycloneDX SBOMs produced for release images via the Anchore SBOM action.
- Image signing: Cosign keyless signing (GitHub OIDC) and verification against a pinned certificate identity on release.
- GitOps delivery: ArgoCD Applications with automated sync, prune, and self-heal deploy both services and the monitoring dashboards.
- Image update write-back: ArgoCD Image Updater detects new semver tags in GHCR and commits updated kustomization tags back to `master`.
- Observability: kube-prometheus-stack with ServiceMonitors scraping `/metrics` and a Grafana dashboard for request rate, error rate, p95 latency, and target health.
- AWS/ECR thin slice: manual workflow pushes the Go service image to ECR using GitHub OIDC (no long-lived credentials).
- Terraform IaC: local platform + GitOps bootstrap, and an AWS dev environment (ECR, OIDC, IAM, VPC) with an S3/DynamoDB remote state backend.

## Architecture

A commit to a service triggers CI (lint, test, scan, build a candidate image). On a release tag the candidate is rebuilt multi-platform, post-scanned, SBOM'd, signed with Cosign, verified, and promoted to GHCR. ArgoCD Image Updater notices the new semver tag, writes it back into the relevant `gitops/apps/*/kustomization.yml`, and ArgoCD syncs the change into the cluster. Prometheus discovers each service through its ServiceMonitor and Grafana renders the consumer dashboard. See [Architecture](docs/architecture.md) for the full flow.

## Repository layout

| Path | Purpose |
|------|---------|
| `consumers/go-service/` | Go HTTP service (`:8080`, `/healthz` `/readyz` `/metrics`) |
| `consumers/node-service/` | Node/NestJS service (`:3000`, `/` `/healthz` `/readyz` `/metrics`) |
| `.github/workflows/` | CI, release, dev-publish, terraform, and ECR-push workflows |
| `.github/actions/` | Composite actions: build, sign, verify, promote, registry login, scans |
| `gitops/argocd/` | ArgoCD AppProject, Applications, and Image Updater resource |
| `gitops/apps/` | Kustomize deployments for go-service and node-service |
| `gitops/monitoring/grafana-dashboards/` | Grafana dashboard ConfigMap (Kustomize) |
| `gitops/secrets/` | SOPS-encrypted secrets + `apply-secrets.sh` |
| `infra/terraform/envs/local/platform/` | Local namespaces + Helm releases (ArgoCD, image-updater, kube-prometheus-stack) |
| `infra/terraform/envs/local/gitops-bootstrap/` | Applies ArgoCD project/apps/image-updater manifests |
| `infra/terraform/envs/aws/dev/` | AWS dev: ECR, GitHub OIDC, IAM role, VPC |
| `infra/terraform/bootstrap/aws-state/` | S3 state bucket + DynamoDB lock table |
| `obs/grafana/dashboards/` | Source Grafana dashboard JSON |
| `scripts/` | `kind-up.sh`, `kind-down.sh` local cluster helpers |

## Main workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `.github/workflows/ci-go-service.yml` | PR/push to `consumers/go-service/**`, tag `go-service-v*` | Go CI; release on tag |
| `.github/workflows/ci-ts-service.yml` | PR/push to `consumers/node-service/**`, tag `node-service-v*` | Node CI; release on tag |
| `.github/workflows/ci-terraform.yml` | PR/push to `infra/terraform/**`, `gitops/argocd/**` | fmt/validate + KinD bootstrap smoke test |
| `.github/workflows/dev-publish-go-service.yml` | `workflow_dispatch` | Build/push Go dev image `dev-<sha>` to GHCR |
| `.github/workflows/dev-publish-node-service.yml` | `workflow_dispatch` | Build/push Node dev image `dev-<sha>` to GHCR |
| `.github/workflows/aws-ecr-push.yml` | `workflow_dispatch` | Push Go service image to ECR via OIDC |
| `.github/workflows/reusable-go-ci.yml` | `workflow_call` | Go lint -> test -> pre-scan -> build candidate |
| `.github/workflows/reusable-ts-ci.yml` | `workflow_call` | Node lint -> test -> pre-scan -> build candidate |
| `.github/workflows/reusable-release.yml` | `workflow_call` | Build -> post-scan/SBOM -> sign -> verify -> promote |
| `.github/workflows/reusable-aws-ecr-push.yml` | `workflow_call` | OIDC auth + build/push to ECR |

## Quick start (local platform)

Requires Docker, KinD, kubectl, Terraform, SOPS, and an age key.

```bash
# 1. Create (or recover) the local KinD cluster, defaults to cluster name "argocd"
scripts/kind-up.sh

# 2. Bootstrap platform: namespaces + Helm releases (ArgoCD, image-updater, kube-prometheus-stack)
terraform -chdir=infra/terraform/envs/local/platform init
terraform -chdir=infra/terraform/envs/local/platform apply

# 3. Apply encrypted secrets (GHCR pull creds, image-updater creds, git write-back token)
#    Expects an age key at ~/.config/sops/age/keys.txt (override via SOPS_AGE_KEY_FILE)
gitops/secrets/apply-secrets.sh

# 4. Register the ArgoCD project, applications, and image-updater resource
terraform -chdir=infra/terraform/envs/local/gitops-bootstrap init
terraform -chdir=infra/terraform/envs/local/gitops-bootstrap apply
```

ArgoCD then syncs `go-service`, `node-service`, and the monitoring dashboards automatically (prune + self-heal enabled). To reach the UIs (KinD does not expose them by default):

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

Tear down with `scripts/kind-down.sh`. See [Operations](docs/operations.md) for bootstrap order and recovery details.

## Release flow

Push a tag `go-service-v<version>` or `node-service-v<version>`. The version is extracted by stripping the service prefix, then `reusable-release.yml` builds a multi-platform candidate (`linux/amd64,linux/arm64`), runs the Trivy image post-scan and SBOM generation, signs the image with Cosign keyless OIDC, verifies the signature against the expected certificate identity, and promotes it to GHCR with `latest`, `<sha>`, and the release tag. ArgoCD Image Updater picks up the new semver tag and writes it back into the service's kustomization.

## AWS integration

A thin slice publishes the Go service image to ECR. `aws-ecr-push.yml` (manual) assumes the IAM role `cicd-platform-dev-github-actions-ecr-push` in account `980481493011` (region `eu-north-1`) via GitHub OIDC, no static keys, and pushes to `cicd-platform-dev-go-service`. The role's trust policy is scoped to `master` and `go-service-v*` tags; ECR push permissions follow least privilege. Terraform manages the ECR repo, OIDC provider, IAM role, and VPC, with remote state in an encrypted S3 bucket plus a DynamoDB lock table. See [Infrastructure](docs/infrastructure.md).

## Documentation

- [Architecture](docs/architecture.md)
- [Development](docs/development.md)
- [Infrastructure](docs/infrastructure.md)
- [Operations](docs/operations.md)
- [Security](docs/security.md)
