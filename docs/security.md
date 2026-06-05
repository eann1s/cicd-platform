# Security

This document describes the security controls implemented in the platform, where each lives, and what is explicitly not yet in place. It covers CI permissions, scanning, image signing, secret encryption, and the cloud trust model.

See also: [Architecture](architecture.md), [Operations](operations.md).

## Security controls overview

| Control | Where implemented |
|---------|-------------------|
| Least-privilege CI job permissions | `permissions:` blocks per job in all `.github/workflows/*.yml` |
| Secret scanning (source) | `.github/actions/security-pre-scan` (Gitleaks) |
| Filesystem vulnerability scan | `.github/actions/security-pre-scan` (Trivy `fs`) |
| Image vulnerability scan | `.github/actions/security-post-scan` (Trivy `image`) |
| SBOM generation | `.github/actions/security-post-scan` (anchore/sbom-action, CycloneDX) |
| Image signing | `.github/actions/image-sign` (Cosign keyless OIDC) |
| Signature verification | `.github/actions/image-verify` (Cosign) |
| Image tag promotion | `.github/actions/image-promote` |
| Registry authentication | `.github/actions/registry-login` (docker/login-action) |
| Secret encryption at rest in git | `.sops.yaml` + SOPS/age, `gitops/secrets/*.enc.yaml` |
| Image pull credentials in cluster | `ghcr-pull` secrets (go-service, node-service namespaces) |
| GitHub -> AWS federation | `aws_iam_openid_connect_provider.github_actions` (`infra/terraform/envs/aws/dev`) |
| ECR push IAM role | `aws_iam_role.github_actions_ecr_push` |
| Terraform state protection | S3 encryption + public-access-block + DynamoDB lock (`infra/terraform/bootstrap/aws-state`) |
| Pinned action SHAs | All third-party actions pinned to commit SHA across workflows/actions |

## GitHub Actions least-privilege permissions

Every job declares an explicit `permissions:` block. The workflow default is narrowed to read-only and widened only where a job needs to write packages or mint an OIDC token.

CI workflows (`ci-go-service.yml`, `ci-ts-service.yml`):

- `call_pr`, `ci_push`, `ci_release`: `contents: read`
- `release_push`: `contents: read`, `packages: write`, `id-token: write`

Reusable CI (`reusable-go-ci.yml`, `reusable-ts-ci.yml`):

- `lint`, `test`, `pre-scan`, `build`: `contents: read` (build does not publish in CI; it uses `publish: false`)

Reusable release (`reusable-release.yml`):

- `build`: `contents: read`, `packages: write`
- `post-scan`: `contents: read`, `packages: read`
- `sign`: `id-token: write`, `packages: write`, `contents: read`
- `verify`: `packages: read`, `contents: read`
- `publish`: `contents: read`, `packages: write`

Terraform (`ci-terraform.yml`):

- `static-checks`, `bootstrap-smoke`: `contents: read`

Dev publish (`dev-publish-go-service.yml`, `dev-publish-node-service.yml`):

- Workflow and `build` job: `contents: read`, `packages: write`

AWS ECR push (`aws-ecr-push.yml`, `reusable-aws-ecr-push.yml`):

- Workflow and `push` / `push_image` jobs: `contents: read`, `id-token: write` (`id-token` is required to assume the AWS role via OIDC)

The principle here: `id-token: write` appears only where keyless signing or AWS federation happens; `packages: write` appears only on build/sign/publish in the release path and the manual dev-publish flows. PR and test jobs never get write scopes.

## Secret scanning with Gitleaks

Source secret scanning runs in `.github/actions/security-pre-scan`, invoked by the `pre-scan` job in both `reusable-go-ci.yml` and `reusable-ts-ci.yml` (after `lint` and `test`, before `build`).

- Tool: Gitleaks, pinned image `ghcr.io/gitleaks/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f`
- Command: `gitleaks git --exit-code 1` (non-zero exit fails the job)
- Output: JSON

A detected secret fails the CI run and blocks the build.

## Vulnerability scanning with Trivy

Trivy runs at two stages with different scopes.

Pre-scan (`.github/actions/security-pre-scan`, in the `pre-scan` job of both reusable CI workflows):

- Scan type: `fs` (filesystem)
- Vuln type: `library` only
- Output: `fs-trivy-report.json`, uploaded as a workflow artifact

Post-scan (`.github/actions/security-post-scan`, in the `post-scan` job of `reusable-release.yml`, against the built image by digest):

- Scan type: `image`
- Vuln types: `os,library`
- Output: `image-trivy-report.json`, uploaded as a workflow artifact
- Exit code 1 on findings (fails the release)

Severity threshold (`SCAN_SEVERITY`) is set by branch context:

- `master` and release tags: `HIGH,CRITICAL` fail the build
- Pull requests: only `CRITICAL` fails the build

Trivy is run via `aquasecurity/trivy-action@57a97c7e7821a5776cebc9bb87c984fa69cba8f1`.

## SBOM generation

The SBOM is produced in `.github/actions/security-post-scan` (release path only, after the image is built):

- Tool: `anchore/sbom-action@e22c389904149dbc22b58101806040fa8d37a610` (Syft)
- Format: CycloneDX JSON
- Output file: `image-sbom.cdx.json`

Storage: the SBOM is uploaded as a GitHub Actions workflow artifact alongside `image-trivy-report.json`. It is not currently attached to the image or pushed to an external attestation store.

## Cosign signing and verification

Signing and verification happen in the release path (`reusable-release.yml`), keyless via the GitHub Actions OIDC provider. No long-lived signing key is stored.

Signing (`sign` job -> `.github/actions/image-sign`):

- Tool: `sigstore/cosign-installer@cad07c2e89fa2edd6e2d7bab4c1aa38e53f76003` (Cosign v3.0.6)
- Command: `cosign sign --yes <image@digest>`
- Requires `id-token: write` to obtain the OIDC token

Verification (`verify` job -> `.github/actions/image-verify`, runs after `sign` and before `publish`):

- Command: `cosign verify --certificate-identity <identity> --certificate-oidc-issuer <issuer> <image@digest>`
- OIDC issuer: `https://token.actions.githubusercontent.com`
- Certificate identity: `https://github.com/<repo>/.github/workflows/reusable-release.yml@<ref>`

The image is signed and verified by digest. Only after a successful `verify` does the `publish` job promote tags (`latest`, `<github.sha>`, `<release-tag>`).

Note: verification runs inside the same release pipeline that produced the signature. There is no admission-time signature enforcement in the cluster (see Known limitations).

## SOPS + age secrets

Kubernetes secrets are committed encrypted, using SOPS with an age recipient.

Rules (`.sops.yaml`):

```yaml
creation_rules:
  - path_regex: gitops/secrets/.*\.ya?ml$
    encrypted_regex: "^(data|stringData)$"
    age: "age1p6ljghzq69qywmsx9j55d3q8ydnxgw34y3vkrs646cjm5357e48q25uqdv"
```

Only `data` and `stringData` fields are encrypted; metadata stays in plaintext for readability and diffs.

Encrypted files under `gitops/secrets/`:

- `argocd/ghcr-image-updater.enc.yaml`: `dockerconfigjson` for ArgoCD Image Updater to read GHCR manifests (namespace `argocd`)
- `argocd/git-write-token.enc.yaml`: GitHub `username`/`password` for Image Updater git write-back (namespace `argocd`)
- `go-service/ghcr-pull.enc.yaml`: `dockerconfigjson` pull secret (namespace `go-service`)
- `node-service/ghcr-pull.enc.yaml`: `dockerconfigjson` pull secret (namespace `node-service`)

Apply flow (`gitops/secrets/apply-secrets.sh`):

```bash
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
sops -d gitops/secrets/argocd/ghcr-image-updater.enc.yaml | kubectl apply -f -
sops -d gitops/secrets/argocd/git-write-token.enc.yaml     | kubectl apply -f -
sops -d gitops/secrets/go-service/ghcr-pull.enc.yaml        | kubectl apply -f -
sops -d gitops/secrets/node-service/ghcr-pull.enc.yaml      | kubectl apply -f -
```

The age private key must be present locally at `SOPS_AGE_KEY_FILE`. Secrets are decrypted and applied out-of-band, not synced by ArgoCD.

## GHCR/ECR credential model

Image pull (in cluster):

- Both deployments reference an `imagePullSecret` named `ghcr-pull` in their own namespace (`go-service`, `node-service`).
- These secrets are `kubernetes.io/dockerconfigjson` credentials for GHCR, applied via `apply-secrets.sh` from the SOPS-encrypted files above.

Image Updater (in cluster):

- `ghcr-image-updater` (namespace `argocd`) lets ArgoCD Image Updater read GHCR manifests.
- `git-write-token` (namespace `argocd`) lets it commit updated tags back to `master` (`git:secret:argocd/git-write-token`).

Registry login (in CI):

- `.github/actions/registry-login` wraps `docker/login-action@c94ce9fb468520275223c153574b00df6fe4bcc9`.
- GHCR: username `${{ github.actor }}`, password `${{ secrets.GITHUB_TOKEN }}`, the ephemeral job token, scoped by the job's `packages` permission.
- ECR: login uses `aws-actions/amazon-ecr-login@fa648b43de3d4d023bcb3f89ed6940096949c419` after assuming the AWS role via OIDC (no static registry password).

## GitHub OIDC to AWS

Defined in `infra/terraform/envs/aws/dev`. GitHub Actions authenticates to AWS via OIDC; no long-lived AWS access keys exist in the repo or CI.

OIDC provider (`aws_iam_openid_connect_provider.github_actions`):

- URL: `https://token.actions.githubusercontent.com`
- Client ID list: `["sts.amazonaws.com"]`
- Thumbprint: `6938fd4d98bab03faadb97b34396831e3780aea1`

Trust policy (`aws_iam_policy_document.github_actions_assume_role`), `sts:AssumeRoleWithWebIdentity`, conditions:

- Audience: `token.actions.githubusercontent.com:aud` == `sts.amazonaws.com`
- Subject: `token.actions.githubusercontent.com:sub` matches one of:
  - `repo:eann1s/cicd-platform:ref:refs/heads/master`
  - `repo:eann1s/cicd-platform:ref:refs/tags/go-service-v*`

So only runs from `master` or `go-service-v*` tags in `eann1s/cicd-platform` can assume the role.

Role: `aws_iam_role.github_actions_ecr_push` (name `cicd-platform-dev-github-actions-ecr-push`, account `980481493011`, region `eu-north-1`). Consumed by `aws-ecr-push.yml` via `reusable-aws-ecr-push.yml`.

## IAM least privilege for ECR push

The role policy (`aws_iam_policy_document.github_actions_ecr_push`) is scoped to the minimum needed to push the go-service image:

Statement 1, authorization (must be `*` per ECR API):

```
Action:   ecr:GetAuthorizationToken
Resource: *
```

Statement 2, image operations, scoped to the go-service repository ARN:

```
Actions:
  ecr:BatchCheckLayerAvailability
  ecr:InitiateLayerUpload
  ecr:UploadLayerPart
  ecr:CompleteLayerUpload
  ecr:PutImage
  ecr:DescribeRepositories
  ecr:BatchGetImage
Resource: arn of cicd-platform-dev-go-service ECR repository
```

The ECR repository (`aws_ecr_repository.go_service`, `cicd-platform-dev-go-service`) is created with `IMMUTABLE` tags and scan-on-push enabled.

## Known limitations / future hardening

The following are NOT yet implemented. They are listed so the gaps are explicit.

- **No admission-time signature enforcement.** Cosign verification runs only inside the release pipeline. There is no admission controller (e.g. Kyverno, Gatekeeper, or Sigstore policy-controller) blocking unsigned or unverified images at deploy time. The cluster does not re-verify signatures.
- **No full environment separation.** Only a `dev` AWS environment and a local KinD environment exist. There is no staging/prod split, no separate AWS accounts, and no per-environment state isolation beyond the single `dev` backend.
- **Secrets not KMS-backed.** SOPS uses a single age recipient. There is no AWS KMS (or other cloud KMS) key, no key rotation policy, and the age private key is managed manually on the operator's machine.
- **No EKS / IRSA / External Secrets.** Workloads run on local KinD. There is no EKS cluster, no IAM Roles for Service Accounts (IRSA), and no External Secrets Operator pulling from a secrets manager. In-cluster secrets are static, manually applied dockerconfigjson values.
- **Limited branch/environment protections in CI.** OIDC trust is restricted to `master` and `go-service-v*` tags, but there are no GitHub Environments with required reviewers, no deployment gates, and no documented branch protection rules enforcing review/status checks before merge.
- **SBOM and scan reports are artifacts only.** They are uploaded to the workflow run but not signed, attested to the image, or stored in a durable/queryable location.
- **AWS network is public-subnet only.** The dev VPC has public subnets with an Internet Gateway and no private subnets or NAT; not intended for hosting workloads as-is.
