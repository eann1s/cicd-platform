# Development

Guide for working on the consumer services and adding new ones. For the broader picture see [Architecture](architecture.md) and [Operations](operations.md).

Two reference services live under `consumers/`:

- `consumers/go-service`: Go, listens on `:8080`
- `consumers/node-service`: NestJS (TypeScript), listens on `3000` (override with `PORT`)

Both expose the same operational contract: `/healthz`, `/readyz`, `/metrics`.

---

## Working on the Go service (`consumers/go-service`)

### Layout

```
consumers/go-service/
├── Dockerfile
├── Makefile
├── go.mod
├── cmd/go-service/main.go          # entrypoint, binds :8080, wires logger + readiness
└── internal/
    ├── app/app.go
    ├── transport/http/mux.go       # route table
    ├── transport/http/handlers.go  # /healthz, /readyz, /metrics
    ├── readiness/readiness.go      # in-memory ready flag (SetReady)
    ├── obs/metrics.go              # Prometheus collectors
    ├── middleware/metrics.go       # per-request metrics recording
    └── logger/logger.go            # zerolog setup
```

### Commands (Makefile)

| Target | Runs |
|--------|------|
| `make deps` | `go mod download` |
| `make tidy` | `go mod tidy` |
| `make test` | `go test -v ./...` |
| `make build` | `go build -o ./bin/go-service ./cmd/go-service` |
| `make run` | build and run locally |
| `make clean` | remove `./bin` |

Run from inside `consumers/go-service`:

```bash
make deps
make test
make build
make run        # serves on http://localhost:8080
```

Race detector (the CI test job also runs this):

```bash
go test -race ./...
```

### Behaviour notes

- Listen address `:8080` is hardcoded in `cmd/go-service/main.go`, there is no env var to change it.
- Logger is fixed to `info` level with a `service: go-service` field.
- Readiness is stateful: the service calls `SetReady(true)` once the listener binds, and `SetReady(false)` on shutdown before a 5-second graceful drain. So `/readyz` can return `503` during startup/shutdown.

---

## Working on the Node service (`consumers/node-service`)

### Layout

```
consumers/node-service/
├── Dockerfile
├── package.json
└── src/
    ├── main.ts                  # bootstrap, listens on PORT ?? 3000
    ├── app.module.ts            # wires PrometheusModule + interceptor
    ├── app.controller.ts        # GET /, /healthz, /readyz
    ├── app.service.ts
    └── metrics.interceptor.ts   # per-request metrics, excludes /metrics
```

### Commands (npm scripts)

| Script | Runs |
|--------|------|
| `npm run build` | `nest build` -> `dist/` |
| `npm start` | `nest start` |
| `npm run start:dev` | `nest start --watch` |
| `npm run start:prod` | `node dist/main` |
| `npm run lint` | `eslint "{src,apps,libs,test}/**/*.ts"` |
| `npm test` | `jest` |
| `npm run test:watch` | `jest --watch` |
| `npm run test:cov` | `jest --coverage` |
| `npm run test:e2e` | `jest --config ./test/jest-e2e.json` |
| `npm run format` | `prettier --write "src/**/*.ts" "test/**/*.ts"` |

Run from inside `consumers/node-service`:

```bash
npm ci
npm run lint
npm test
npm run build
npm run start:prod     # serves on http://localhost:3000 (or $PORT)
```

### Behaviour notes

- Port is `process.env.PORT ?? 3000`. The `EXPOSE 3000` in the Dockerfile is documentation only.
- `/healthz` and `/readyz` both return `200` with `{ "status": "ok" }`, readiness is not stateful (always OK), unlike the Go service.
- `GET /` returns the string `Hello World!`.
- The `MetricsInterceptor` records every request and explicitly skips the `/metrics` route to avoid self-recursion. Custom histogram buckets: `[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]`.

---

## Expected service contract

Any service that plugs into this platform must satisfy the items below.

### Dockerfile expectations

- Multi-stage build with a minimal, non-root final image.
  - Go service: builder `golang:1.26.3-alpine3.22` -> final `gcr.io/distroless/static-debian12:nonroot`, entrypoint `/bin/app`.
  - Node service: builder `node:24-bookworm-slim` -> final `gcr.io/distroless/nodejs24-debian13:nonroot`, `CMD ["dist/main.js"]`.
- Base images are pinned by SHA digest.
- The container serves HTTP on a fixed port (`8080` for go-service, `3000` for node-service).
- The build is invoked by the `build-candidate` composite action (`.github/actions/build-candidate`) via Docker Buildx, with multi-platform support through QEMU and GitHub Actions layer cache (`type=gha,mode=max`).

### Health / readiness endpoints

| Endpoint | Used as | Go service | Node service |
|----------|---------|-----------|--------------|
| `GET /healthz` | liveness probe | `200`, no body | `200` `{ "status": "ok" }` |
| `GET /readyz` | readiness probe | `200` ready / `503` not ready | `200` `{ "status": "ok" }` |

Kubernetes probe config (from the deployments):

- Readiness: `initialDelaySeconds 5`, `periodSeconds 10`, `timeoutSeconds 3`, `failureThreshold 3`, path `/readyz`.
- Liveness: `initialDelaySeconds 30`, `periodSeconds 20`, `timeoutSeconds 3`, `failureThreshold 3`, path `/healthz`.

### `/metrics` endpoint

- `GET /metrics` exposes Prometheus metrics. The route is excluded from its own request metrics.
- Both services emit at minimum:
  - `http_requests_total` (counter), labels `route`/`method`/`status_class` (go-service) and `method`/`route`/`status_class` (node-service).
  - `http_request_duration_seconds` (histogram), same labels.
  - Default Go runtime / process collectors (go-service) and `prom-client` default metrics (node-service).
- The Grafana "Consumers" dashboard ([gitops/monitoring/grafana-dashboards/consumer-services-dashboard.yml](../gitops/monitoring/grafana-dashboards/consumer-services-dashboard.yml)) queries `http_requests_total`, `http_request_duration_seconds_bucket`, and `up{job=~"go-service|node-service"}`, so the metric names above are load-bearing.

### Kubernetes manifests (`gitops/apps/<svc>/`)

Each service has a Kustomize app at `gitops/apps/<svc>/` with these files:

- `namespace.yml`: namespace named after the service.
- `deployment.yml`: 3 replicas, `RollingUpdate` (`maxUnavailable: 0`, `maxSurge: 1`), `imagePullSecrets: ghcr-pull`, the probes above, resource requests/limits, container port (`8080` / `3000`).
- `service.yml`: `ClusterIP`, port `80` named `http` -> targetPort `8080` (go) / `3000` (node).
- `servicemonitor.yml`: in the `monitoring` namespace, label `release: kube-prometheus-stack`, selects `app: <svc>` via `namespaceSelector`, scrapes port `http` at path `/metrics`, `interval 30s`, `scrapeTimeout 10s`.
- `kustomization.yml`: lists the resources and pins the image:
  ```yaml
  images:
    - name: <svc>
      newName: ghcr.io/eann1s/cicd-platform/<svc>
      newTag: v1.0.3
  ```
  The `newTag` field is what ArgoCD Image Updater rewrites on each release (see [Operations](operations.md)).

Resource sizing differs per service:

| | go-service | node-service |
|--|-----------|--------------|
| CPU request / limit | 100m / 500m | 250m / 1000m |
| Memory request / limit | 256Mi / 512Mi | 512Mi / 1024Mi |

### CI workflow caller

Each service has a thin top-level workflow that delegates to a reusable workflow. For go-service, `.github/workflows/ci-go-service.yml`:

- Triggers on PRs and pushes to `master` filtered to `consumers/go-service/**` (plus workflow/action files), and on tags `go-service-v*`.
- `call_pr` / `ci_push` / `ci_release` call `reusable-go-ci.yml` with:
  ```yaml
  with:
    service_path: consumers/go-service
    image_name: go-service
    platforms: linux/amd64
  ```
- `release_meta` strips the `go-service-` prefix from the tag to get the version.
- `release_push` (needs `release_meta` + `ci_release`) calls `reusable-release.yml` with `tag: <version>` and `platforms: linux/amd64,linux/arm64`; permissions `contents: read, packages: write, id-token: write`.

`reusable-go-ci.yml` runs `lint -> test -> pre-scan -> build` (build is `candidate-<sha>`, not published). The Node side is identical with `reusable-ts-ci.yml`, `service_path: consumers/node-service`, `image_name: node-service`, and tags `node-service-v*`.

`reusable-release.yml` runs `build -> post-scan -> sign -> verify -> publish` and is shared by both services.

---

## How to add a new service

Replace `<svc>` with the service name (used as the image name and namespace) throughout. The patterns below mirror the existing two services exactly, copy one and adjust.

1. **Create the service directory and code** under `consumers/<svc>/`:
   - HTTP server on a fixed port.
   - `GET /healthz` (liveness), `GET /readyz` (readiness), `GET /metrics` (Prometheus).
   - Emit `http_requests_total` and `http_request_duration_seconds` with `route`/`method`/`status_class` labels.
   - A multi-stage `Dockerfile` ending in a pinned, non-root distroless image.

2. **Add GitOps manifests** at `gitops/apps/<svc>/`:
   - `namespace.yml` (namespace `<svc>`).
   - `deployment.yml`: `imagePullSecrets: ghcr-pull`, image ref `<svc>`, container port, probes (`/healthz`, `/readyz`).
   - `service.yml`: `ClusterIP`, port `80` named `http` -> your container port.
   - `servicemonitor.yml`: namespace `monitoring`, label `release: kube-prometheus-stack`, selector `app: <svc>`, `namespaceSelector` -> `<svc>`, path `/metrics`.
   - `kustomization.yml`: resources list plus the `images` block pointing at `ghcr.io/eann1s/cicd-platform/<svc>` with an initial `newTag`.

3. **Add CI workflows** under `.github/workflows/`:
   - `ci-<svc>.yml`: copy `ci-go-service.yml` (Go) or `ci-ts-service.yml` (TS), set the path filters to `consumers/<svc>/**`, tags to `<svc>-v*`, `service_path: consumers/<svc>`, `image_name: <svc>`, and the prefix stripped in `release_meta` to `<svc>-`.
   - `dev-publish-<svc>.yml`: copy `dev-publish-go-service.yml`; set `SERVICE_PATH: consumers/<svc>` and `IMAGE: ghcr.io/${{ github.repository }}/<svc>`. This is a manual (`workflow_dispatch`) GHCR push of `dev-<sha>`.

4. **Register the ArgoCD Application** at `gitops/argocd/applications/<svc>-app.yml`:
   - `project: platform`, `repoURL: https://github.com/eann1s/cicd-platform.git`, `targetRevision: master`, `path: gitops/apps/<svc>`, destination namespace `<svc>`, automated sync with `prune: true`, `selfHeal: true`, `CreateNamespace=true`.
   - Add the `<svc>` namespace to the destinations list in `gitops/argocd/projects/platform-project.yml` (the AppProject whitelists destination namespaces).
   - Register the manifest in `infra/terraform/envs/local/gitops-bootstrap/main.tf` if you want the local bootstrap to apply it (the existing apps are each a `kubernetes_manifest` resource there).
   - Add an `applicationRefs` entry in `gitops/argocd/image-updater/custom-resource.yml` if Image Updater should track the new image (alias + `imageName: ghcr.io/eann1s/cicd-platform/<svc>` + kustomize target `<svc>`).

5. **Add the `ghcr-pull` secret** for the new namespace:
   - Create `gitops/secrets/<svc>/ghcr-pull.enc.yaml`, a `kubernetes.io/dockerconfigjson` Secret named `ghcr-pull` in namespace `<svc>`, encrypted with SOPS per `.sops.yaml` (only `data`/`stringData` are encrypted).
   - Add a line to `gitops/secrets/apply-secrets.sh`:
     ```bash
     sops -d gitops/secrets/<svc>/ghcr-pull.enc.yaml | kubectl apply -f -
     ```

6. **First image:** tag `<svc>-v0.1.0` (or run `dev-publish-<svc>.yml`) to produce the initial image, then set the matching `newTag` in `gitops/apps/<svc>/kustomization.yml`.

> Note: the AWS dev environment currently provisions an ECR repo and OIDC trust only for go-service (`cicd-platform-dev-go-service`, tags `go-service-v*`). Wiring a new service into ECR is a future extension, see [infra/terraform/envs/aws/dev](../infra/terraform/envs/aws/dev).

---

## How release tags work

Releases are driven by git tags, one scheme per service:

- go-service: `go-service-v<VERSION>` (e.g. `go-service-v1.0.0`)
- node-service: `node-service-v<VERSION>` (e.g. `node-service-v1.0.0`)

Pushing such a tag triggers the service's `ci-<svc>.yml`:

1. `release_meta` extracts `<VERSION>` by stripping the `<svc>-` prefix.
2. `ci_release` runs the full lint/test/scan/build pipeline.
3. `release_push` calls `reusable-release.yml`, which:
   - builds and pushes a `candidate-<sha>` image to GHCR (multi-arch `linux/amd64,linux/arm64`),
   - runs `post-scan` (Trivy image scan + CycloneDX SBOM),
   - signs the image by digest with Cosign keyless OIDC (`cosign sign --yes`),
   - verifies the signature against issuer `https://token.actions.githubusercontent.com` and identity `https://github.com/<repo>/.github/workflows/reusable-release.yml@<ref>`,
   - promotes the digest with three tags via `docker buildx imagetools`: `latest`, `<sha>`, and `<VERSION>`.

The promoted `<VERSION>` tag (e.g. `v1.0.4`) is what ArgoCD Image Updater picks up, it only accepts tags matching `^v[0-9]+\.[0-9]+\.[0-9]+$` and writes the new tag back into the kustomization. See [Operations](operations.md) for the promotion/rollout flow.

Scan severity gating: `HIGH,CRITICAL` fail the build on `master` and tags; only `CRITICAL` fails on PRs.

---

## Local validation

Run these before opening a PR, they mirror what CI executes.

### Go service

```bash
# from consumers/go-service
go test -v ./...
go test -race ./...
make build
golangci-lint run        # CI uses golangci-lint-action
```

### Node service

```bash
# from consumers/node-service
npm ci
npm run lint
npm test
npm run build
```

### Terraform

CI (`ci-terraform.yml`) runs `fmt -check -recursive` across the whole Terraform tree, but `validate` only on the two local roots (`local/platform`, `local/gitops-bootstrap`). The AWS roots (`envs/aws/dev`, `bootstrap/aws-state`) are format-checked but not validated in CI:

```bash
terraform fmt -check -recursive infra/terraform

terraform -chdir=infra/terraform/envs/local/platform init -backend=false
terraform -chdir=infra/terraform/envs/local/platform validate

terraform -chdir=infra/terraform/envs/local/gitops-bootstrap init -backend=false
terraform -chdir=infra/terraform/envs/local/gitops-bootstrap validate
```

The `bootstrap-smoke` CI job goes further: it spins up a KinD cluster, applies the `local/platform` and `local/gitops-bootstrap` modules, and asserts the argocd pods, the `platform` AppProject, the `go-service`/`node-service` Applications, and the `platform-image-updater` resource all exist. To reproduce locally see the bootstrap order in [Operations](operations.md).

### Container build (optional, local)

The composite action drives the real build; locally you can approximate it with Buildx:

```bash
docker buildx build \
  --platform linux/amd64 \
  -f consumers/go-service/Dockerfile \
  consumers/go-service
```
