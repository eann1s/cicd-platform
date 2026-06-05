# Operations Runbook

Operational procedures for the cicd-platform local cluster and AWS dev environment. For how the pieces fit together, see [Architecture](architecture.md).

All `kubectl` commands assume the `kind-argocd` context. Set it once:

```bash
kubectl config use-context kind-argocd
```

The deployed services are `go-service` and `node-service`. Each runs in its own namespace (`go-service`, `node-service`); ArgoCD runs in `argocd`; Prometheus, Grafana and the dashboards live in `monitoring`.

---

## Verifying ArgoCD apps

Three Applications are managed under the `platform` AppProject: `go-service`, `node-service`, `monitoring-app`. All sync from `master` on `https://github.com/eann1s/cicd-platform.git` with automated prune + self-heal.

List via kubectl (works without the CLI):

```bash
kubectl get applications -n argocd
kubectl get appprojects -n argocd
```

Inspect one app's sync/health status and conditions:

```bash
kubectl get application go-service -n argocd -o jsonpath='{.status.sync.status}{" / "}{.status.health.status}{"\n"}'
kubectl describe application node-service -n argocd
```

Via the ArgoCD CLI (after logging in, see below):

```bash
argocd app list
argocd app get go-service
argocd app get monitoring-app
```

To log in to the CLI you need the API server reachable and the initial admin password:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443 &
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
argocd login localhost:8080 --username admin --insecure
```

Healthy state: each app shows `Synced` / `Healthy`. Force a refresh/sync if needed:

```bash
argocd app sync go-service
# or, without the CLI, annotate to trigger a refresh:
kubectl -n argocd annotate application go-service argocd.argoproj.io/refresh=hard --overwrite
```

---

## Verifying Kubernetes rollouts

Both services run 3 replicas with a RollingUpdate strategy (`maxUnavailable: 0`, `maxSurge: 1`).

```bash
kubectl rollout status deployment/go-service -n go-service
kubectl rollout status deployment/node-service -n node-service

kubectl get deploy,pods -n go-service
kubectl get deploy,pods -n node-service
```

Check readiness/liveness directly if a pod is flapping:

```bash
kubectl describe pod -n go-service -l app=go-service
kubectl logs -n go-service -l app=go-service --tail=100
```

Probe endpoints (real paths): `go-service` liveness `GET /healthz` and readiness `GET /readyz` on container port 8080; `node-service` the same paths on container port 3000.

Roll back a bad rollout:

```bash
kubectl rollout undo deployment/go-service -n go-service
```

Note: ArgoCD self-heal is enabled. A `kubectl rollout undo` or `argocd app rollback` is only temporary. Anything that diverges from Git gets reverted on the next sync. For a durable rollback, revert the change in Git.

---

## Checking deployed image tags

Images come from GHCR: `ghcr.io/eann1s/cicd-platform/go-service` and `ghcr.io/eann1s/cicd-platform/node-service`. The desired tag is pinned in the kustomization (`gitops/apps/<service>/kustomization.yml`, currently `v1.0.3`); the running tag is on the Deployment.

What is actually running:

```bash
kubectl get deploy go-service -n go-service \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl get deploy node-service -n node-service \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Per-pod resolved image (includes the digest once pulled):

```bash
kubectl get pods -n go-service -l app=go-service \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].image}{"\t"}{.status.containerStatuses[0].imageID}{"\n"}{end}'
```

What Git wants (source of truth):

```bash
grep -A2 'images:' gitops/apps/go-service/kustomization.yml
grep -A2 'images:' gitops/apps/node-service/kustomization.yml
```

If the running image lags the kustomization tag, the rollout is in progress or stuck, check rollout status above. If the kustomization tag lags a newly published GHCR tag, that is Image Updater's job (next section).

---

## Checking Image Updater status

The `platform-image-updater` custom resource (in `argocd`) polls GHCR, picks the newest semver build matching `^v[0-9]+\.[0-9]+\.[0-9]+$`, and writes the new tag back into `gitops/apps/<service>/kustomization.yml` on `master` using the `git-write-token` secret. ArgoCD then syncs the commit.

Tail the controller logs (Helm release `argocd-image-updater`, log level `debug`):

```bash
# Label selector is name-agnostic (the controller Deployment is argocd-image-updater-controller):
kubectl -n argocd logs -l app.kubernetes.io/name=argocd-image-updater -f
kubectl -n argocd logs deploy/argocd-image-updater-controller --tail=200 | grep -i -E 'go-service|node-service|error|updated'
```

Confirm the CR and the write-back / pull secrets exist:

```bash
kubectl -n argocd get imageupdater platform-image-updater -o yaml
kubectl -n argocd get secret git-write-token ghcr-image-updater
```

Expected log signals: discovery of a newer tag, a Git commit to `master`, then the kustomization `newTag` advancing. If nothing happens after a new publish, verify the tag matches the semver regexp and that the secrets are present and valid.

---

## Checking Prometheus targets

Prometheus (from `kube-prometheus-stack`) discovers targets via the `go-service` and `node-service` ServiceMonitors (in `monitoring`, label `release: kube-prometheus-stack`), scraping `/metrics` on the `http` service port every 30s.

Port-forward and open the targets page:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# then open http://localhost:9090/targets
```

Confirm both services report up via the API:

```bash
curl -s 'http://localhost:9090/api/v1/query?query=up{job=~"go-service|node-service"}' | jq '.data.result[] | {job:.metric.job, value:.value[1]}'
```

Check the ServiceMonitors and that services expose a named `http` port:

```bash
kubectl get servicemonitor -n monitoring
kubectl get svc go-service -n go-service -o jsonpath='{.spec.ports[*].name}{"\n"}'
kubectl get svc node-service -n node-service -o jsonpath='{.spec.ports[*].name}{"\n"}'
```

Metrics emitted by both services: `http_requests_total`, `http_request_duration_seconds` (histogram), plus default Go/process and Node/prom-client metrics.

---

## Accessing Grafana

Grafana ships with `kube-prometheus-stack`. The "Consumers" dashboard (UID `aae1205c-041d-4a88-8817-01dca5211ccd`) is provisioned from the `consumer-services-dashboard` ConfigMap in `monitoring` (label `grafana_dashboard: "1"`), via the `monitoring-app` ArgoCD Application.

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# then open http://localhost:3000
```

The secret is the source of truth for the admin password (the kube-prometheus-stack chart default is usually `admin` / `prom-operator`, but don't rely on it):

```bash
kubectl -n monitoring get secret kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

The dashboard has four panels: request rate (`sum by (service, route, method) (rate(http_requests_total[5m]))`), error rate (4xx/5xx), p95 latency (`histogram_quantile(0.95, ...)`), and service targets up. Datasource is `prometheus`. If a panel is empty, check Prometheus targets first.

---

## Running the AWS ECR push workflow

`aws-ecr-push.yml` is a manual (`workflow_dispatch`) workflow. It assumes the OIDC role `arn:aws:iam::980481493011:role/cicd-platform-dev-github-actions-ecr-push` in `eu-north-1` and pushes `consumers/go-service` to `980481493011.dkr.ecr.eu-north-1.amazonaws.com/cicd-platform-dev-go-service:<sha>` for `linux/amd64`. Inputs are baked into the workflow; a plain dispatch is enough.

```bash
gh workflow run aws-ecr-push.yml --ref master
gh run list --workflow aws-ecr-push.yml --limit 5
gh run watch
```

Confirm the image landed in ECR (requires the `cicd-platform-dev` AWS profile):

```bash
aws ecr describe-images \
  --repository-name cicd-platform-dev-go-service \
  --region eu-north-1 --profile cicd-platform-dev \
  --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags'
```

Note: the OIDC trust policy only permits `repo:eann1s/cicd-platform:ref:refs/heads/master` and `refs/tags/go-service-v*`. Dispatching from another branch fails the AssumeRole step.

---

## Troubleshooting

### ImagePullBackOff

**Symptom:** pods stuck in `ImagePullBackOff` / `ErrImagePull`.

**Diagnose:**

```bash
kubectl get pods -n go-service
kubectl describe pod -n go-service -l app=go-service | grep -A5 -i events
kubectl get secret ghcr-pull -n go-service
```

**Fix:** the `ghcr-pull` dockerconfigjson secret is missing or stale, or the requested tag does not exist in GHCR. Re-apply secrets:

```bash
SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/keys.txt ./gitops/secrets/apply-secrets.sh
```

Then confirm the tag in `gitops/apps/<service>/kustomization.yml` actually exists in `ghcr.io/eann1s/cicd-platform/<service>`.

### Failed rollout

**Symptom:** `kubectl rollout status` hangs; new ReplicaSet never reaches the desired count.

**Diagnose:**

```bash
kubectl rollout status deployment/node-service -n node-service --timeout=60s
kubectl describe deploy node-service -n node-service
kubectl get pods -n node-service -o wide
kubectl logs -n node-service -l app=node-service --tail=100
```

**Fix:** common causes are a crashing container (check logs), failing readiness probe (`/readyz` on 3000 for node-service, 8080 for go-service), or resource pressure (node-service requests 250m/512Mi, limits 1000m/1024Mi). After fixing the underlying cause via Git, sync; or for an immediate revert:

```bash
kubectl rollout undo deployment/node-service -n node-service
```

Because self-heal is on, persist the real fix in Git, not just in-cluster.

### ArgoCD OutOfSync

**Symptom:** an app shows `OutOfSync` or `Degraded`.

**Diagnose:**

```bash
kubectl get applications -n argocd
argocd app get go-service
argocd app diff go-service
```

**Fix:** if the live state drifted, sync:

```bash
argocd app sync go-service
# or trigger a refresh without the CLI:
kubectl -n argocd annotate application go-service argocd.argoproj.io/refresh=hard --overwrite
```

If it stays `OutOfSync` right after syncing, a controller (e.g. Image Updater) or a webhook may be mutating the resource, check the app's `status.conditions` and the Image Updater logs.

### Expired AWS SSO session

**Symptom:** local `aws` or `terraform` commands using the `cicd-platform-dev` profile return `ExpiredToken` / `The security token included in the request is expired`. This affects local tooling only. The GitHub Actions ECR push does not use SSO (it federates via GitHub OIDC, see below).

**Diagnose:**

```bash
aws sts get-caller-identity --profile cicd-platform-dev
```

**Fix (local):**

```bash
aws sso login --profile cicd-platform-dev
```

For the GitHub Actions path there is no SSO, failures there are the OIDC trust policy (wrong branch/tag) or a missing/renamed role, not an expired session. Verify the role exists:

```bash
aws iam get-role --role-name cicd-platform-dev-github-actions-ecr-push --profile cicd-platform-dev
```

### Terraform backend / state issues

**Symptom:** `terraform init` errors on the S3 backend; or `Error acquiring the state lock`.

Backend for `envs/aws/dev`: bucket `cicd-platform-dev-tfstate-980481493011`, key `envs/aws/dev/terraform.tfstate`, lock table `cicd-platform-dev-tflock`, region `eu-north-1`, profile `cicd-platform-dev`.

**Diagnose:**

```bash
aws s3 ls s3://cicd-platform-dev-tfstate-980481493011/ --profile cicd-platform-dev
aws dynamodb describe-table --table-name cicd-platform-dev-tflock \
  --region eu-north-1 --profile cicd-platform-dev
```

**Fix:**
- Bucket/table missing -> run the bootstrap first: `terraform -chdir=infra/terraform/bootstrap/aws-state apply`, then `terraform -chdir=infra/terraform/envs/aws/dev init`.
- Backend init prompts to migrate -> answer yes to copy local state to S3.
- Stuck lock from a killed run -> identify and release it:

```bash
terraform -chdir=infra/terraform/envs/aws/dev force-unlock <LOCK_ID>
```

Only force-unlock when you are certain no other apply is running.

### Failed vulnerability scan

**Symptom:** a CI run fails in `security-pre-scan` (gitleaks/trivy fs) or `security-post-scan` (trivy image/SBOM).

Thresholds: `HIGH,CRITICAL` fail on `master` and release tags; only `CRITICAL` fails on PRs.

**Diagnose:** open the failing run and download the scan artifacts:

```bash
gh run view <run-id> --log-failed
gh run download <run-id>   # fs-trivy-report.json, image-trivy-report.json, image-sbom.cdx.json
```

**Fix:**
- Gitleaks hit -> remove the secret, rotate it, and rewrite history if it was committed. The scan runs `gitleaks git --exit-code 1`.
- Trivy filesystem (`library` vulns) -> bump the offending dependency (`go.mod` / `package.json`) and re-run.
- Trivy image (`os,library` vulns) -> update the base image. Bases are pinned by digest: go-service `gcr.io/distroless/static-debian12:nonroot`, node-service `gcr.io/distroless/nodejs24-debian13:nonroot`.

---

## Future extensions

- KinD does not publish ports; Grafana/Prometheus/ArgoCD are reachable only via `kubectl port-forward`. Ingress / KinD port mappings are not configured yet.
- AWS ECR push covers `go-service` only; `node-service` has no ECR repo or push workflow.
- The AWS dev VPC has public subnets only (no private subnets, no NAT, no workload cluster), it is not yet a deploy target.
