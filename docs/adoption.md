# Adoption

This guide is for a team that wants to **fork this repository and run its own instance** of the
platform, rather than read about how the original one works. The other docs describe the system as the
original owner runs it; this one walks through everything that is tied to that owner and has to become
yours before a fresh clone will build, sign, and deploy.

There are three things a fork has to do that the rest of the docs assume are already done:

1. Replace the owner-specific identifiers (`eann1s/cicd-platform`, the AWS account, region, profile, kube context).
2. Generate your own age key and re-encrypt every secret to it. The committed secrets are encrypted to the **original owner's** age recipient, so you cannot decrypt or use them.
3. Create the five secret values from scratch (GHCR tokens, a git write-back token, a Telegram bot token).

Work through the steps in order. By the end you can follow the normal [quick starts](../README.md#quick-start-local-target) and they will work against your own GitHub org, registry, and cluster.

See also: [Architecture](architecture.md), [Infrastructure](infrastructure.md), [Operations](operations.md), [Security](security.md), [Development](development.md).

---

## Step 0: Prerequisites

Install the tooling the platform drives. Versions below are what the repo has been exercised with; newer patch releases are normally fine.

| Tool | Used for | Notes |
|------|----------|-------|
| Docker | Local builds, KinD | Buildx is used for multi-platform builds |
| KinD | Local cluster target | `scripts/kind-up.sh` creates it |
| kubectl | All cluster operations | |
| Terraform | All infra roots | No `required_version` is pinned in the repo; a recent Terraform works. Providers pin kubernetes `~> 2.36`, helm `~> 3.1`, aws `~> 6.0` |
| SOPS | Encrypt/decrypt secrets | v3.x (committed files were written with 3.13.x) |
| age | Secret encryption key | `age-keygen` ships with the `age` package |
| gh | GitHub repo settings, manual workflow runs | optional but convenient |
| AWS CLI | AWS foundation only | with SSO or keys for your account |

A reachable cluster is **not** provided by this repo. For the local target KinD creates one; for the VPS target you bring an existing single-node k3s cluster reachable through a kube context. Terraform installs platform components onto a cluster that already exists.

---

## Step 1: Make the identifiers yours

The repo hardcodes the original owner in several places. Some references **auto-derive** from
`${{ github.repository }}` at CI time and need no edit on a fork; the rest are static and must be
changed. The table is the full list.

### Auto-derives on a fork (no edit needed)

These are computed from `github.repository` when CI runs, so once the code lives under your org they
point at your org automatically:

- The GHCR image path in the release pipeline: `ghcr.io/${{ github.repository }}/<svc>` (`reusable-release.yml`).
- The Cosign certificate identity it verifies against: `https://github.com/${{ github.repository }}/.github/workflows/reusable-release.yml@<ref>` (`reusable-release.yml`).

### Must be changed

| What | Current value | Where | Change to |
|------|---------------|-------|-----------|
| GitOps image ref (`newName`) | `ghcr.io/eann1s/cicd-platform/<svc>` | `gitops/apps/go-service/kustomization.yml`, `gitops/apps/node-service/kustomization.yml` | Your GHCR org path |
| Image Updater tracked image | `ghcr.io/eann1s/cicd-platform/<svc>` | `gitops/argocd/image-updater/custom-resource.yml` | Your GHCR org path |
| ArgoCD app source repo | `https://github.com/eann1s/cicd-platform.git` | `gitops/argocd/applications/*.yml` | Your repo URL |
| Git write-back repo | `https://github.com/eann1s/cicd-platform.git` | `gitops/argocd/image-updater/custom-resource.yml` | Your repo URL |
| AppProject allowed source repo | `https://github.com/eann1s/cicd-platform.git` | `gitops/argocd/projects/platform-project.yml` | Your repo URL |
| Code owners | `@eann1s` | `.github/CODEOWNERS` | Your GitHub handle / team |
| age recipient | `age1p6ljghz…` | `.sops.yaml` (and every `gitops/secrets/*.enc.yaml`) | Your age public key — see [Step 2](#step-2-generate-your-own-age-key) |
| Telegram chat ID | `111111111` (already a placeholder) | `gitops/monitoring/observability/consumer-services-alertmanagerconfig.yml` | Your Telegram chat ID |

### Must be changed only if you use the AWS foundation

The AWS account, region, and profile are baked into the Terraform roots and the ECR-push workflow. Skip this block entirely if you are not standing up the AWS foundation (it is independent of the cluster targets).

| What | Current value | Where |
|------|---------------|-------|
| AWS account ID | `980481493011` | `.github/workflows/aws-ecr-push.yml` (`image_uri`, `role_arn`), `infra/terraform/envs/aws/dev/providers.tf` (backend bucket), `infra/terraform/bootstrap/aws-state/variables.tf` (`state_bucket_name` suffix) |
| AWS region | `eu-north-1` | the two AWS roots' `variables.tf` / `providers.tf`, `aws-ecr-push.yml` |
| AWS profile | `cicd-platform-dev` | the two AWS roots' `variables.tf` / `providers.tf` |
| GitHub owner for OIDC trust | `eann1s` (var `github_owner` default) | `infra/terraform/envs/aws/dev/variables.tf` — drives the OIDC subject the IAM role trusts |
| State bucket name | `cicd-platform-dev-tfstate-980481493011` | `aws-state/variables.tf` and the `aws/dev` backend block |

The S3 bucket name embeds the account ID so it stays globally unique; pick your own unique suffix and use the same string in both the `aws-state` root that creates the bucket and the `aws/dev` backend block that consumes it.

### Optional / cosmetic

- The Go module path `github.com/eann1s/cicd-platform/...` in `consumers/go-service` (`go.mod` and imports). Changing it is a clean-up, not a requirement — it does not affect the image build or deploy. Rename with `go mod edit -module <new>` plus an import rewrite if you want it to read as yours.

After this step, grep the tree to confirm nothing owner-specific is left where you didn't expect it:

```bash
grep -rI 'eann1s\|980481493011\|do-k3s-dev\|age1p6ljghz' \
  --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.terraform .
```

The VPS roots also default `kube_context` to `do-k3s-dev`; either change the default in
`infra/terraform/envs/vps/*/variables.tf` or pass `-var="kube_context=<your-context>"` on every apply.

---

## Step 2: Generate your own age key

The committed secrets are encrypted to the original owner's age recipient. You cannot decrypt them, and you do not need to — you will re-create the values yourself in [Step 3](#step-3-create-the-secret-values). First, generate your own key and point `.sops.yaml` at it.

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
# prints: Public key: age1<your-recipient>
```

Keep `keys.txt` private and out of git (it is the decryption key for every secret). Then set the public
key as the recipient in `.sops.yaml`:

```yaml
creation_rules:
  - path_regex: gitops/secrets/.*\.ya?ml$
    encrypted_regex: "^(data|stringData)$"
    age: "age1<your-recipient>"
```

`encrypted_regex` keeps metadata (name, namespace, type) in plaintext and encrypts only `data` /
`stringData`, which is what keeps the secret files readable in diffs. Leave it as is.

`apply-secrets.sh` reads the private key from `SOPS_AGE_KEY_FILE` (default
`~/.config/sops/age/keys.txt`). Override the path with that env var if you keep the key elsewhere.

---

## Step 3: Create the secret values

The platform needs five Kubernetes secrets. They are applied out of band by
`gitops/secrets/apply-secrets.sh` (ArgoCD does not sync them). The original encrypted files are no use
to you, so write fresh plaintext, then encrypt each in place with SOPS.

### What each secret is

| File | Namespace / name | Type | Holds |
|------|------------------|------|-------|
| `gitops/secrets/argocd/ghcr-image-updater.enc.yaml` | `argocd` / `ghcr-image-updater` | `dockerconfigjson` | GHCR creds so Image Updater can **read** image manifests |
| `gitops/secrets/argocd/git-write-token.enc.yaml` | `argocd` / `git-write-token` | Opaque (`username`, `password`) | A token Image Updater uses to **commit** new tags back to your repo |
| `gitops/secrets/go-service/ghcr-pull.enc.yaml` | `go-service` / `ghcr-pull` | `dockerconfigjson` | Pull creds for kubelet (go-service namespace) |
| `gitops/secrets/node-service/ghcr-pull.enc.yaml` | `node-service` / `ghcr-pull` | `dockerconfigjson` | Pull creds for kubelet (node-service namespace) |
| `gitops/secrets/monitoring/alert-manager-telegram-bot-token.enc.yaml` | `monitoring` / `alert-manager-telegram-bot-token` | Opaque (`bot-token`) | Telegram bot token for Alertmanager |

### Where the values come from

- **GHCR pull / read creds (three `dockerconfigjson` secrets).** Create a GitHub Personal Access Token (classic) with `read:packages`. All three GHCR secrets can use the same read token; they differ only in namespace and name. The reliable way to produce the secret (don't copy `~/.docker/config.json` — with a credential helper, e.g. Docker Desktop's `credsStore`, it holds no inline auth) is to let `kubectl` generate it:

  ```bash
  kubectl create secret docker-registry ghcr-pull \
    --namespace=go-service \
    --docker-server=ghcr.io \
    --docker-username=<your-github-username> \
    --docker-password=<PAT-with-read:packages> \
    --dry-run=client -o yaml > gitops/secrets/go-service/ghcr-pull.enc.yaml
  ```

  This writes a `kubernetes.io/dockerconfigjson` Secret with the credential under `data.dockerconfigjson` (base64). `.sops.yaml` encrypts `data` as well as `stringData`, so it encrypts cleanly in the next step. Repeat with `--namespace=node-service` (name `ghcr-pull`) and `--namespace=argocd --docker-username`/etc. for `ghcr-image-updater`.

- **Git write-back token (`git-write-token`).** A token that can **push to your repo's default branch**, because Image Updater commits the new image tag back to git. A PAT with `repo` scope (classic) or a fine-grained token with `Contents: write` on the fork works. `username` is the GitHub user the token belongs to; `password` is the token.

  > Branch protection interacts with this: the write-back commits land on your default branch. Either allow this bot/user to bypass required PRs, or scope protection so the automated tag bump is permitted. See [Step 4](#step-4-github-repository-settings).

- **Telegram bot token (`bot-token`) and chat ID.** Create a bot with [@BotFather](https://t.me/BotFather) to get the token. Get the destination chat ID (your chat with the bot, or a group's ID) — e.g. send the bot a message and read `chat.id` from `https://api.telegram.org/bot<token>/getUpdates`. The token goes in this secret; the **chat ID is not a secret** and lives in `consumer-services-alertmanagerconfig.yml` (`chatID:`), which you set in [Step 1](#step-1-make-the-identifiers-yours).

### Write and encrypt each file

The three `dockerconfigjson` secrets are already on disk from the `kubectl … --dry-run` command above.
The two Opaque secrets (`git-write-token`, the Telegram token) you write by hand. Example for the git
write-back token:

```yaml
# gitops/secrets/argocd/git-write-token.enc.yaml  (plaintext, before encrypting)
apiVersion: v1
kind: Secret
metadata:
  name: git-write-token
  namespace: argocd
type: Opaque
stringData:
  username: <github-user>
  password: <token>
```

The Telegram secret is the same shape with `type: Opaque` and a single `stringData.bot-token`.

Then encrypt each of the five files in place:

```bash
sops --encrypt --in-place gitops/secrets/argocd/git-write-token.enc.yaml
# ...and the same for the other four files
```

`.sops.yaml` matches the path and encrypts only the `data` / `stringData` fields, leaving the metadata
(name, namespace, type) readable in diffs.

Verify a round-trip before applying:

```bash
sops -d gitops/secrets/argocd/git-write-token.enc.yaml   # should print your plaintext
```

Then apply them to the current cluster (the namespaces must exist first — they are created by the
platform Terraform root):

```bash
SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/keys.txt ./gitops/secrets/apply-secrets.sh
```

For the full bootstrap ordering (platform → secrets → gitops-bootstrap) see
[Operations](operations.md#runbook-bootstrap-the-vps-platform). Applying secrets before the
gitops-bootstrap is what keeps the service pods out of `ImagePullBackOff`.

---

## Step 4: GitHub repository settings

CI relies on settings that live in GitHub, not in the repo tree. Configure them on your fork.

- **Actions → Workflow permissions.** The release path needs `packages: write` and `id-token: write`. Individual jobs already declare least-privilege `permissions:` blocks, but the repository/org policy must allow those scopes. Ensure GitHub Actions is enabled and that workflow token permissions are not globally forced to read-only in a way that blocks the per-job grants.
- **GHCR package visibility.** The first release publishes `ghcr.io/<owner>/<repo>/<svc>`. Confirm the package is created and that your cluster's pull token can read it (private packages need the `ghcr-pull` secret, which you created in Step 3).
- **Branch protection / rulesets on the default branch.** The [Security](security.md#repository-governance) doc expects: require PRs, require code-owner review, require passing CI checks, block force-push and deletion. Set these to match. Reconcile them with the Image Updater write-back (Step 3) so the automated tag-bump commit is allowed.
- **OIDC to AWS (only if using the AWS foundation).** The IAM trust policy restricts the OIDC subject to `repo:<owner>/<repo>:ref:refs/heads/master` and `…:ref:refs/tags/go-service-v*`. Update `github_owner` / `github_repo` in `infra/terraform/envs/aws/dev/variables.tf` so the trust matches your repo before applying that root.

---

## Step 5: AWS foundation (optional)

The AWS roots are independent of the cluster targets — skip this entirely if you only want the local or VPS cluster. If you do want ECR + OIDC + remote Terraform state, after the edits in Step 1:

1. Pick a globally-unique state bucket name (the default embeds the account ID) and set it in both `infra/terraform/bootstrap/aws-state/variables.tf` and the `infra/terraform/envs/aws/dev` backend block.
2. Set your account ID, region, and profile across the AWS files listed in Step 1.
3. Follow the [Infrastructure backend migration](infrastructure.md#backend-migration-local---s3) order: bootstrap the state backend first, then init the dev root against S3.

The dev environment provisions ECR + OIDC trust for **go-service only** today; wiring a second service into ECR is a known extension (see [Architecture: future extensions](architecture.md#future-extensions)).

---

## Step 6: First deploy

With identifiers, the age key, and secrets in place, follow the normal quick starts:

- Local target: [README → Quick start: local target](../README.md#quick-start-local-target).
- VPS target: [README → Quick start: VPS / k3s target](../README.md#quick-start-vps--k3s-target) and the [Operations runbook](operations.md#runbook-bootstrap-the-vps-platform).

There is a chicken-and-egg on the very first deploy: the GitOps `kustomization.yml` pins an image tag
that does not exist in your registry yet. Produce a first image before (or right after) the bootstrap:

- Run the manual dev-publish workflow (`dev-publish-go-service.yml` / `dev-publish-node-service.yml`, `workflow_dispatch`) to push a `dev-<sha>` image, or
- Push a release tag `go-service-v0.1.0` / `node-service-v0.1.0` to run the full signed release pipeline.

Then set the matching `newTag` in `gitops/apps/<svc>/kustomization.yml`. From the next release onward,
Image Updater advances the tag for you. Adding a third service follows
[Development → How to add a new service](development.md#how-to-add-a-new-service).

---

## Adoption checklist

- [ ] Owner identifiers replaced (Step 1 grep is clean except intended matches).
- [ ] Your age key generated; `.sops.yaml` recipient is yours.
- [ ] All five secrets re-created, encrypted, and round-trip-decryptable.
- [ ] Telegram chat ID set in the AlertmanagerConfig; bot token in its secret.
- [ ] GitHub Actions permissions, GHCR visibility, and branch protection configured.
- [ ] (If using AWS) account/region/profile/bucket/owner updated; state backend bootstrapped.
- [ ] Platform Terraform applied, secrets applied, gitops-bootstrap applied — in that order.
- [ ] A first image published and the kustomization `newTag` points at it.
- [ ] `kubectl get applications -n argocd` shows the apps `Synced` / `Healthy`.
</content>
</invoke>
