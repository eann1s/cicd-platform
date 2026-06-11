# Operations Runbook

Operational procedures for the cicd-platform clusters and the AWS foundation. For how the pieces fit
together, see [Architecture](architecture.md).

The **VPS k3s cluster is the real runtime target** and the runbooks below are written for it. It is a
single-node cluster, convenient and cheap, but **not highly available**: a node failure takes
everything down, and there is no production-grade redundancy. The local KinD cluster runs the same
GitOps content (minus Kyverno) and is for developing and testing the platform itself.

## Picking a kube context

| Target | Context | Notes |
|--------|---------|-------|
| VPS k3s | `do-k3s-dev` (default; whatever you configured) | Runtime target. Has Kyverno + Alertmanager/Telegram. |
| Local KinD | `kind-argocd` | Created by `scripts/kind-up.sh`. No Kyverno. |

Set it once, or pass `--context` per command:

```bash
kubectl config use-context do-k3s-dev      # VPS
# or
kubectl config use-context kind-argocd     # local
```

Namespaces: services run in `go-service` and `node-service`; ArgoCD in `argocd`; Prometheus, Grafana,
Alertmanager and the observability objects in `monitoring`; Kyverno in `kyverno`.

---

## Runbook: bootstrap the VPS platform

Prerequisites: a reachable single-node k3s cluster with a kube context (default `do-k3s-dev`), plus
kubectl, Terraform, SOPS, and the age private key at `~/.config/sops/age/keys.txt`. The k3s cluster
itself is created out of band. Terraform only installs platform components onto it.

```bash
# Override the context if yours is not do-k3s-dev:
#   add  -var="kube_context=<your-context>"  to the apply commands.
terraform -chdir=infra/terraform/envs/vps/platform init
terraform -chdir=infra/terraform/envs/vps/platform apply
```

This installs ArgoCD (v9.5.14), ArgoCD Image Updater (v1.2.1), kube-prometheus-stack (v85.2.2, with
the Alertmanager matcher-strategy value), and Kyverno (v3.8.1), and creates the `argocd`,
`go-service`, `node-service`, `monitoring`, `kyverno` namespaces.

Verify the controllers came up:

```bash
kubectl get pods -n argocd
kubectl get pods -n monitoring
kubectl get pods -n kyverno
```

Expected: ArgoCD server/repo/application-controller pods Running; the kube-prometheus-stack operator,
Prometheus, Grafana, Alertmanager Running; Kyverno admission/background controllers Running.

> Apply the secrets (next runbook) **before** the gitops-bootstrap. Otherwise the Applications the
> bootstrap creates deploy pods that sit in `ImagePullBackOff` until `ghcr-pull` exists.

---

## Runbook: apply secrets

Secrets are SOPS-encrypted in git and applied out of band (ArgoCD does not sync them). The age private
key must be present locally.

```bash
SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/keys.txt ./gitops/secrets/apply-secrets.sh
```

This decrypts and `kubectl apply`s five secrets:

| Secret | Namespace | Purpose |
|--------|-----------|---------|
| `ghcr-image-updater` | `argocd` | Image Updater reads GHCR manifests |
| `git-write-token` | `argocd` | Image Updater commits new tags to `master` |
| `ghcr-pull` | `go-service` | kubelet pulls go-service images |
| `ghcr-pull` | `node-service` | kubelet pulls node-service images |
| `alert-manager-telegram-bot-token` | `monitoring` | Alertmanager authenticates to the Telegram bot |

Confirm they exist:

```bash
kubectl -n argocd get secret ghcr-image-updater git-write-token
kubectl -n go-service get secret ghcr-pull
kubectl -n node-service get secret ghcr-pull
kubectl -n monitoring get secret alert-manager-telegram-bot-token
```

The script targets whatever context is current, so confirm with `kubectl config current-context`
first.

---

## Runbook: bootstrap the GitOps apps

After the platform is up and the secrets are applied, register the ArgoCD project and Applications:

```bash
terraform -chdir=infra/terraform/envs/vps/gitops-bootstrap init
terraform -chdir=infra/terraform/envs/vps/gitops-bootstrap apply
```

This applies the `platform` AppProject, the `go-service`, `node-service`, `monitoring-app`, and
`policies-app` Applications, and the `platform-image-updater` Image Updater CR. ArgoCD then reconciles
all of them automatically (auto-sync, prune, self-heal).

(On the local target use `infra/terraform/envs/local/gitops-bootstrap`, it registers the same set
minus `policies-app`.)

---

## Runbook: verify ArgoCD sync

Applications under the `platform` AppProject: `go-service`, `node-service`, `monitoring-app`, and (VPS)
`policies-app`. All sync from `master` with automated prune + self-heal.

List and check status via kubectl (no CLI needed):

```bash
kubectl get applications -n argocd
kubectl get appprojects -n argocd
kubectl get application go-service -n argocd \
  -o jsonpath='{.status.sync.status}{" / "}{.status.health.status}{"\n"}'
```

Healthy state: each app shows `Synced` / `Healthy`.

Via the ArgoCD CLI (after logging in):

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443 &
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
argocd login localhost:8080 --username admin --insecure
argocd app list
argocd app get go-service
```

Force a refresh/sync if needed:

```bash
argocd app sync go-service
# or, without the CLI:
kubectl -n argocd annotate application go-service argocd.argoproj.io/refresh=hard --overwrite
```

---

## Runbook: verify app rollouts

Both services run 3 replicas with RollingUpdate (`maxUnavailable: 0`, `maxSurge: 1`).

```bash
kubectl rollout status deployment/go-service -n go-service
kubectl rollout status deployment/node-service -n node-service
kubectl get deploy,pods -n go-service
kubectl get deploy,pods -n node-service
```

Expected: `deployment "<svc>" successfully rolled out`, 3/3 pods Ready.

Check what image is actually running vs what git wants:

```bash
# running
kubectl get deploy go-service -n go-service \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
# source of truth
grep -A2 'images:' gitops/apps/go-service/kustomization.yml
```

Probe paths: `go-service` liveness `GET /healthz`, readiness `GET /readyz` on port 8080;
`node-service` the same paths on port 3000.

ArgoCD self-heal is on, so a `kubectl rollout undo` is only temporary. Anything that diverges from
git is reverted on the next sync. For a durable rollback, revert the change in git.

---

## Runbook: checking Image Updater

The `platform-image-updater` CR (namespace `argocd`) polls GHCR, picks the newest semver build
matching `^v[0-9]+\.[0-9]+\.[0-9]+$`, and writes the new tag back into
`gitops/apps/<svc>/kustomization.yml` on `master` using the `git-write-token` secret. ArgoCD then
syncs the commit.

```bash
kubectl -n argocd logs -l app.kubernetes.io/name=argocd-image-updater -f
kubectl -n argocd get imageupdater platform-image-updater -o yaml
kubectl -n argocd get secret git-write-token ghcr-image-updater
```

Expected log signals: discovery of a newer tag, a git commit to `master`, the kustomization `newTag`
advancing. If nothing happens after a publish, verify the tag matches the semver regexp and the
secrets are present and valid.

---

## Runbook: access Grafana / Prometheus / Alertmanager

All three ship with kube-prometheus-stack in `monitoring`. Reach them with port-forwards.

```bash
# Grafana
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# -> http://localhost:3000

# Prometheus
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# -> http://localhost:9090/targets  and  /alerts

# Alertmanager
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
# -> http://localhost:9093
```

Grafana admin password (the secret is the source of truth):

```bash
kubectl -n monitoring get secret kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

The "Consumers" dashboard (UID `aae1205c-041d-4a88-8817-01dca5211ccd`) has four panels: request rate,
error rate, p95 latency, service targets up. If a panel is empty, check Prometheus targets first:

```bash
curl -s 'http://localhost:9090/api/v1/query?query=up{job=~"go-service|node-service"}' \
  | jq '.data.result[] | {job:.metric.job, value:.value[1]}'
```

Expected: a `value` of `1` for both `go-service` and `node-service`.

---

## Runbook: verify Telegram alerts

The alert path is PrometheusRule (`consumer-services-alerts`) → Alertmanager
(`consumer-services-alertmanagerconfig`, route `team = platform` → `telegram` receiver) → Telegram.

Confirm the objects exist and loaded:

```bash
kubectl -n monitoring get prometheusrule consumer-services-alerts
kubectl -n monitoring get alertmanagerconfig consumer-services-alertmanagerconfig
kubectl -n monitoring get secret alert-manager-telegram-bot-token
```

Check the rules are loaded in Prometheus (port-forward 9090) at `/alerts`, and current alert state
via the API:

```bash
curl -s http://localhost:9090/api/v1/rules \
  | jq '.data.groups[] | select(.name=="consumer-services.rules") | .rules[] | {alert:.name, state:.state}'
```

To trigger an end-to-end test, make a target go down, e.g. scale a service to zero, and wait for
`ConsumerServiceTargetDown` (`up == 0` for 2m) to fire:

```bash
kubectl -n go-service scale deployment/go-service --replicas=0
# wait ~2-3 min, expect a Telegram message; then restore:
kubectl -n go-service scale deployment/go-service --replicas=3
# with sendResolved: true you also get a resolved message once it recovers
```

> Doing this against a self-healing app: ArgoCD will revert the replica count on its next sync, which
> is fine for a short test. To hold the state longer, scale via a temporary git change instead.

If the alert fires in Prometheus/Alertmanager but no Telegram message arrives, see
[Troubleshooting: alerts not routing](#troubleshooting-alerts-not-routing).

---

## Runbook: verify Kyverno policies (VPS)

Kyverno (namespace `kyverno`) enforces two ClusterPolicies in `Enforce` mode against Pods in
`go-service` and `node-service`.

```bash
kubectl get clusterpolicy
kubectl get clusterpolicy require-resources disallow-privileged-containers \
  -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.validationFailureAction}{"\n"}{end}'
```

Expected: both present, action `Enforce`.

Prove enforcement by trying to create a non-compliant Pod (should be **rejected** at admission):

```bash
# Missing resource requests/limits -> blocked by require-resources
kubectl -n go-service run policy-test --image=nginx --restart=Never
# Expected: admission webhook denies it, citing
# "Pods must define CPU and memory requests and limits for every container."
```

A privileged Pod, a Pod with `hostNetwork: true`, or a `hostPath` volume in those namespaces is
likewise rejected. The real consumer deployments already satisfy the policies, so a normal sync is
admitted; a regression that drops limits or adds a privileged container is what gets blocked.

---

## Runbook: run the AWS ECR push workflow

`aws-ecr-push.yml` is a manual (`workflow_dispatch`) workflow. It assumes the OIDC role
`arn:aws:iam::980481493011:role/cicd-platform-dev-github-actions-ecr-push` in `eu-north-1` and pushes
`consumers/go-service` to `…/cicd-platform-dev-go-service:<sha>` for `linux/amd64`.

```bash
gh workflow run aws-ecr-push.yml --ref master
gh run list --workflow aws-ecr-push.yml --limit 5
gh run watch
```

Confirm the image landed (requires the `cicd-platform-dev` AWS profile):

```bash
aws ecr describe-images \
  --repository-name cicd-platform-dev-go-service \
  --region eu-north-1 --profile cicd-platform-dev \
  --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags'
```

The OIDC trust policy only permits `refs/heads/master` and `refs/tags/go-service-v*`. Dispatching from
another branch fails the AssumeRole step.

---

## Troubleshooting

### ImagePullBackOff

**Symptom:** pods stuck in `ImagePullBackOff` / `ErrImagePull`.

```bash
kubectl get pods -n go-service
kubectl describe pod -n go-service -l app=go-service | grep -A5 -i events
kubectl get secret ghcr-pull -n go-service
```

**Fix:** the `ghcr-pull` secret is missing or stale, or the requested tag does not exist in GHCR.
Re-apply secrets, then confirm the tag in `gitops/apps/<svc>/kustomization.yml` exists in
`ghcr.io/eann1s/cicd-platform/<svc>`:

```bash
SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/keys.txt ./gitops/secrets/apply-secrets.sh
```

### ArgoCD OutOfSync

**Symptom:** an app shows `OutOfSync` or `Degraded`.

```bash
kubectl get applications -n argocd
argocd app get go-service
argocd app diff go-service
```

**Fix:** if live state drifted, sync (`argocd app sync go-service`, or annotate
`argocd.argoproj.io/refresh=hard`). If it stays `OutOfSync` right after syncing, something is mutating
the resource, Image Updater (check its logs), or **Kyverno rejecting the Pod** at admission so the
Deployment never reaches its desired ReplicaSet. Check the app's `status.conditions` and:

```bash
kubectl -n go-service describe replicaset -l app=go-service | grep -A5 -i events
```

A Kyverno denial shows up here as a failed pod creation citing the policy message, fix the manifest
to satisfy the policy (resources/limits, non-privileged) and re-sync.

### Failed rollout

**Symptom:** `kubectl rollout status` hangs; the new ReplicaSet never reaches the desired count.

```bash
kubectl rollout status deployment/node-service -n node-service --timeout=60s
kubectl describe deploy node-service -n node-service
kubectl get pods -n node-service -o wide
kubectl logs -n node-service -l app=node-service --tail=100
```

**Fix:** common causes are a crashing container (check logs), a failing readiness probe (`/readyz`),
resource pressure, or a Kyverno admission denial (see above). Persist the real fix in git, since
self-heal reverts in-cluster-only changes.

### Troubleshooting: alerts not routing

**Symptom:** an alert is firing in Prometheus/Alertmanager but no Telegram message arrives.

Walk the path stage by stage:

1. **Rule firing?** Port-forward Prometheus (9090), open `/alerts`, confirm the alert is in `firing`
   state and carries `team: platform`.
2. **Alertmanager received it?** Port-forward Alertmanager (9093), check the alert appears and is not
   silenced/inhibited.
3. **Config loaded?** Confirm the AlertmanagerConfig exists and the bot-token secret is present:
   ```bash
   kubectl -n monitoring get alertmanagerconfig consumer-services-alertmanagerconfig -o yaml
   kubectl -n monitoring get secret alert-manager-telegram-bot-token
   ```
4. **Matcher mismatch?** The route matches `team = platform`. On the VPS target the Helm value
   `alertmanagerConfigMatcherStrategy.type: None` keeps Alertmanager from auto-adding a namespace
   matcher; if that value is missing (e.g. you applied the local platform root by mistake), the route
   may never match. Confirm the merged config:
   ```bash
   kubectl -n monitoring logs -l app.kubernetes.io/name=alertmanager --tail=200
   ```
5. **Bad token / chat ID?** A wrong `bot-token` or `chatID` fails silently at send time, Alertmanager
   logs the Telegram API error. Rotate the token (re-encrypt the secret, re-run `apply-secrets.sh`)
   and verify the chat ID in `consumer-services-alertmanagerconfig.yml`.

### Expired AWS SSO session

**Symptom:** local `aws`/`terraform` with the `cicd-platform-dev` profile returns `ExpiredToken`. This
affects local tooling only; the GitHub Actions ECR push federates via OIDC, not SSO.

```bash
aws sts get-caller-identity --profile cicd-platform-dev   # diagnose
aws sso login --profile cicd-platform-dev                 # fix
```

For the GitHub Actions path, failures are the OIDC trust policy (wrong branch/tag) or a missing role,
not an expired session:

```bash
aws iam get-role --role-name cicd-platform-dev-github-actions-ecr-push --profile cicd-platform-dev
```

### Terraform backend / state issues

**Symptom:** `terraform init` errors on the S3 backend, or `Error acquiring the state lock`.

Backend for `envs/aws/dev`: bucket `cicd-platform-dev-tfstate-980481493011`, key
`envs/aws/dev/terraform.tfstate`, lock table `cicd-platform-dev-tflock`, region `eu-north-1`, profile
`cicd-platform-dev`.

```bash
aws s3 ls s3://cicd-platform-dev-tfstate-980481493011/ --profile cicd-platform-dev
aws dynamodb describe-table --table-name cicd-platform-dev-tflock \
  --region eu-north-1 --profile cicd-platform-dev
```

**Fix:**
- Bucket/table missing -> `terraform -chdir=infra/terraform/bootstrap/aws-state apply` first.
- Backend init prompts to migrate -> answer yes to copy local state to S3.
- Stuck lock from a killed run -> `terraform -chdir=infra/terraform/envs/aws/dev force-unlock <LOCK_ID>`
  (only when you are certain no other apply is running).

### Failed vulnerability scan

**Symptom:** a CI run fails in `security-pre-scan` (gitleaks/trivy fs) or `security-post-scan` (trivy
image/SBOM). Thresholds: `HIGH,CRITICAL` on `master`/tags, only `CRITICAL` on PRs.

```bash
gh run view <run-id> --log-failed
gh run download <run-id>   # fs-trivy-report.json, image-trivy-report.json, image-sbom.cdx.json
```

**Fix:**
- Gitleaks hit -> remove the secret, rotate it, rewrite history if committed.
- Trivy filesystem (`library`) -> bump the offending dependency (`go.mod` / `package.json`).
- Trivy image (`os,library`) -> update the digest-pinned base image (go-service
  `gcr.io/distroless/static-debian12:nonroot`, node-service
  `gcr.io/distroless/nodejs24-debian13:nonroot`).

---

## Runbook: clean up paid resources

To stop incurring cost, tear down in this order. The two cost sources are the **VPS** (the k3s host)
and the **AWS dev footprint**.

### VPS k3s

The k3s host is provisioned outside this repository, so Terraform here cannot destroy it. Remove the
platform components if you only want to free the cluster, then delete the VPS where it was created
(its provider console / its own tooling):

```bash
terraform -chdir=infra/terraform/envs/vps/gitops-bootstrap destroy
terraform -chdir=infra/terraform/envs/vps/platform destroy
# then delete the VPS/droplet itself in the provider that hosts it
```

Deleting the VPS is what actually stops the bill. The Terraform destroy only removes the in-cluster
objects.

### AWS dev footprint

Destroy the dev environment first, then the state backend last (the dev root's state lives in it):

```bash
terraform -chdir=infra/terraform/envs/aws/dev destroy
terraform -chdir=infra/terraform/bootstrap/aws-state destroy
```

Notes:
- ECR stores images (storage cost) and S3 stores versioned state; both are emptied by the destroys
  above. If a versioned S3 bucket refuses to delete while non-empty, empty it first.
- The VPC, subnets, IGW, OIDC provider, and IAM role carry little or no standing cost but are removed
  by the `aws/dev` destroy for cleanliness.
- DynamoDB is `PAY_PER_REQUEST` (no idle cost) but is removed with the state-bootstrap destroy.

### Local KinD

No cloud cost, but to reclaim the local machine:

```bash
scripts/kind-down.sh argocd
```

---

## Notes / current limitations

- The clusters do not expose Ingress for Grafana/Prometheus/ArgoCD/Alertmanager, reach them via
  `kubectl port-forward`.
- AWS ECR push covers `go-service` only; `node-service` has no ECR repo or push workflow.
- The VPS runtime is single-node k3s: no HA, no node redundancy. Treat it as a foundation, not a
  production cluster.
