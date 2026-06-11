# cicd-platform

A production-oriented platform foundation for building, scanning, signing, and shipping polyglot services to Kubernetes via GitOps. It covers the path from a service commit through container build, security gates, signed releases, and automated cluster delivery, with admission enforcement and observability on the cluster side and an AWS foundation for image publishing and Terraform state.

This is a **foundation**, not a fully production-ready system. The cluster runtime target is a **single-node VPS k3s cluster**. It is not highly available and is not a managed production cluster. What is production-*oriented* here are the practices: GitOps delivery, CI/CD with security gates, signed images, vulnerability scanning, SBOMs, observability with alerts, admission policy enforcement, remote Terraform state with locking, and keyless OIDC cloud auth.

The repository hosts two consumer services (a Go service and a Node/NestJS service) alongside the reusable GitHub Actions workflows, ArgoCD GitOps manifests, Terraform roots, Kyverno policies, and observability config that move them through the pipeline.

## Targets

The platform has three distinct targets, each with a clear responsibility. They are independent, you do not need all three to use the platform.

| Target | What it is | Used for |
|--------|-----------|----------|
| **Local** | KinD cluster (default name `argocd`), created by `scripts/kind-up.sh` | Development and testing of the platform itself: bootstrap, GitOps, observability, end to end. |
| **VPS / k3s** | A single-node k3s cluster on a VPS, reached through a kube context (default `do-k3s-dev`) | The real cluster runtime. Runs ArgoCD, Image Updater, kube-prometheus-stack, Kyverno, and the consumer apps. Single-node, **not HA**. |
| **AWS** | A `dev` account footprint provisioned by Terraform | Supporting cloud services: ECR, GitHub Actions OIDC/IAM, the S3 Terraform state backend with DynamoDB locking, and a minimal VPC. **AWS is not the application runtime today.** |

Terraform installs platform components **onto an existing cluster** (KinD or k3s). It does not provision the cluster machine or the k3s install itself. Create the cluster first, point your kubeconfig at it, then apply Terraform.

## Platform capabilities

- **Per-service CI**: language-specific lint, test, and build pipelines for the Go and Node services via reusable workflows.
- **Security scanning**: Gitleaks secret scanning and Trivy filesystem/image scanning, with stricter severity gates (`HIGH,CRITICAL`) on master and release tags vs. `CRITICAL` on PRs.
- **SBOM generation**: CycloneDX SBOMs produced for release images (Syft via the Anchore SBOM action).
- **Image signing**: Cosign keyless signing (GitHub OIDC) and verification against a pinned certificate identity on release.
- **GitOps delivery**: ArgoCD Applications with automated sync, prune, and self-heal deploy the services, the observability objects, and the Kyverno policies.
- **Image update write-back**: ArgoCD Image Updater detects new semver tags in GHCR and commits updated kustomization tags back to `master`.
- **Observability**: kube-prometheus-stack with ServiceMonitors scraping `/metrics`, a Grafana dashboard, PrometheusRule alerts, and Alertmanager routing to Telegram.
- **Admission enforcement**: Kyverno policies enforce resource requests/limits and block privileged containers, host namespaces, and hostPath volumes in the service namespaces.
- **AWS / ECR foundation**: a manual workflow pushes the Go service image to ECR using GitHub OIDC (no long-lived credentials).
- **Terraform IaC**: local and VPS platform + GitOps bootstrap roots, plus an AWS dev environment (ECR, OIDC, IAM, VPC) with an S3/DynamoDB remote state backend.
- **Repository governance**: CODEOWNERS plus GitHub branch protection / rulesets (PR required, code-owner review, passing CI, no force pushes or branch deletion).

## Architecture in one paragraph

A commit to a service triggers CI (lint, test, scan, build a candidate image). On a release tag the candidate is rebuilt multi-platform, post-scanned, SBOM'd, signed with Cosign, verified, and promoted to GHCR. ArgoCD Image Updater notices the new semver tag, writes it back into the relevant `gitops/apps/*/kustomization.yml`, and ArgoCD syncs the change into the cluster, where Kyverno admits the workload only if it satisfies the policies, and Prometheus/Grafana/Alertmanager observe it and route alerts to Telegram. See [Architecture](docs/architecture.md) for the full flow.

## Repository layout

| Path | Purpose |
|------|---------|
| `consumers/go-service/` | Go HTTP service (`:8080`, `/healthz` `/readyz` `/metrics`) |
| `consumers/node-service/` | Node/NestJS service (`:3000`, `/` `/healthz` `/readyz` `/metrics`) |
| `.github/workflows/` | CI, release, dev-publish, terraform, and ECR-push workflows |
| `.github/actions/` | Composite actions: build, sign, verify, promote, registry login, scans |
| `.github/CODEOWNERS` | Code ownership for required-review enforcement |
| `gitops/argocd/` | ArgoCD AppProject, Applications, and Image Updater resource |
| `gitops/apps/` | Kustomize deployments for go-service and node-service |
| `gitops/monitoring/observability/` | Grafana dashboard ConfigMap, PrometheusRule alerts, AlertmanagerConfig (Kustomize) |
| `gitops/policies/kyverno/` | Kyverno ClusterPolicies (Kustomize) |
| `gitops/secrets/` | SOPS-encrypted secrets + `apply-secrets.sh` |
| `infra/terraform/envs/local/platform/` | Local namespaces + Helm releases (ArgoCD, image-updater, kube-prometheus-stack) |
| `infra/terraform/envs/local/gitops-bootstrap/` | Applies ArgoCD project/apps/image-updater manifests (local) |
| `infra/terraform/envs/vps/platform/` | VPS k3s namespaces + Helm releases (ArgoCD, image-updater, kube-prometheus-stack, Kyverno) |
| `infra/terraform/envs/vps/gitops-bootstrap/` | Applies ArgoCD project/apps/policies/image-updater manifests (VPS) |
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

## Prerequisites

- **Local target**: Docker, KinD, kubectl, Terraform, SOPS, and an age private key at `~/.config/sops/age/keys.txt` (override with `SOPS_AGE_KEY_FILE`).
- **VPS target**: a reachable single-node k3s cluster with a kubeconfig context (default `do-k3s-dev`), plus kubectl, Terraform, SOPS, and the age key. The k3s cluster itself is created out of band, Terraform only installs platform components onto it.
- **AWS foundation**: an AWS account with the `cicd-platform-dev` profile configured (SSO or keys), Terraform, and the AWS CLI.

## Quick start: local target

```bash
# 1. Create (or recover) the local KinD cluster, defaults to cluster name "argocd"
scripts/kind-up.sh

# 2. Bootstrap platform: namespaces + Helm releases (ArgoCD, image-updater, kube-prometheus-stack)
terraform -chdir=infra/terraform/envs/local/platform init
terraform -chdir=infra/terraform/envs/local/platform apply

# 3. Apply encrypted secrets (GHCR pull creds, image-updater creds, git write-back token, Telegram token)
gitops/secrets/apply-secrets.sh

# 4. Register the ArgoCD project, applications, and image-updater resource
terraform -chdir=infra/terraform/envs/local/gitops-bootstrap init
terraform -chdir=infra/terraform/envs/local/gitops-bootstrap apply
```

The local platform root does **not** install Kyverno and the local gitops-bootstrap does **not** register the policies app, admission enforcement is a VPS-target concern. Tear down with `scripts/kind-down.sh`.

## Quick start: VPS / k3s target

The k3s cluster must already exist and be reachable through a kube context (the roots default to `do-k3s-dev`; override with `-var="kube_context=<your-context>"`).

```bash
# 1. Install platform components onto the k3s cluster
#    (ArgoCD, image-updater, kube-prometheus-stack with Alertmanager, Kyverno)
terraform -chdir=infra/terraform/envs/vps/platform init
terraform -chdir=infra/terraform/envs/vps/platform apply

# 2. Apply encrypted secrets onto the cluster
gitops/secrets/apply-secrets.sh

# 3. Register the ArgoCD project, apps, Kyverno policies app, and image-updater
terraform -chdir=infra/terraform/envs/vps/gitops-bootstrap init
terraform -chdir=infra/terraform/envs/vps/gitops-bootstrap apply
```

ArgoCD then syncs `go-service`, `node-service`, `monitoring-app` (dashboard + alerts + Telegram routing), and `policies-app` (Kyverno) automatically. See [Operations](docs/operations.md) for the full VPS runbook, secret apply order, alert verification, and policy checks.

## Quick start: AWS foundation

AWS provides ECR, GitHub OIDC, the Terraform state backend, and a minimal VPC, not the app runtime.

```bash
# 1. Provision the remote state backend (S3 bucket + DynamoDB lock table). Local state.
terraform -chdir=infra/terraform/bootstrap/aws-state init
terraform -chdir=infra/terraform/bootstrap/aws-state apply

# 2. Provision the dev environment (ECR, OIDC provider, IAM role, VPC) against the S3 backend
terraform -chdir=infra/terraform/envs/aws/dev init
terraform -chdir=infra/terraform/envs/aws/dev apply
```

See [Infrastructure](docs/infrastructure.md) for the backend migration and resource detail.

## Release flow

Push a tag `go-service-v<version>` or `node-service-v<version>`. The version is extracted by stripping the service prefix, then `reusable-release.yml` builds a multi-platform candidate (`linux/amd64,linux/arm64`), runs the Trivy image post-scan and SBOM generation, signs the image with Cosign keyless OIDC, verifies the signature against the expected certificate identity, and promotes it to GHCR with `latest`, `<sha>`, and the release tag. ArgoCD Image Updater picks up the new semver tag and writes it back into the service's kustomization. See [Development](docs/development.md) for the service contract and release detail.

## Documentation

- [Architecture](docs/architecture.md): how the pieces fit together, local/VPS/AWS responsibilities, end-to-end flow, bootstrap order.
- [Development](docs/development.md): working on the services, the service contract, adding a new service, release tags.
- [Infrastructure](docs/infrastructure.md): every Terraform root, state backend, safe apply order.
- [Operations](docs/operations.md): VPS bootstrap, secrets, GitOps, alerts, Kyverno, troubleshooting, cleanup runbooks.
- [Security](docs/security.md): controls in place and honest limitations.
