# Assessment App — DevOps Assessment

Angular 7 todo application with a full CI/CD pipeline: Jenkins (CI) → Harbor → GitOps → ArgoCD (CD) on the [JaaLi platform](https://github.com/ThierryMoi/jaali-ai-platform).

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                    CI — Jenkins (namespace ci-cd)                    │
│                                                                     │
│  Checkout → Lint → Tests → SonarQube → Build → Trivy → Push Harbor │
└──────────────────────────────────────────────────────────┬──────────┘
                                                           │
                                    prod-<commit-sha> tag  │
                                                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│              GitOps — devops-assessment-gitops (GitHub)              │
│                                                                     │
│  overlays/prod/          gateway/              chart/               │
│  ├── namespace           └── ReferenceGrant    └── Helm (optional)  │
│  ├── deployment                                                     │
│  ├── service                                                        │
│  └── HTTPRoute                                                      │
└──────────────────────────────────────────────────────────┬──────────┘
                                                           │
                                                  ArgoCD auto-sync
                                                           │
                                                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│                   Kubernetes — JaaLi production cluster                │
│                                                                     │
│  envoy-gateway-system          assessment-app-prod                  │
│  ┌─ jaali-gateway ─────┐      ┌─ HTTPRoute: assessment.jaali.dev   │
│  │  (TLS / cert-manager)│────▶│  Service → Deployment (3 pods)    │
│  └──────────────────────┘      └───────────────────────────────────┘
└─────────────────────────────────────────────────────────────────────┘
```

## Design Decisions

### 1. Containerization

**Multi-stage Docker build** using `node:10-alpine` (Angular 7.2 requires Node 10) for the build stage and `nginx:1.27-alpine` for serving (~25 MB final image vs ~400 MB with Node).

The container runs as `nginx` user (non-root, UID 101). A custom `nginx.conf` handles SPA routing, gzip, cache headers, and `/healthz` probes. The pid file and temp directories are under `/tmp/` to avoid permission errors in non-root mode.

### 2. CI/CD — Separation of Concerns

| Layer | Tool | Responsibility |
|-------|------|----------------|
| CI | Jenkins | Build, test, scan, push image |
| Registry | Harbor (`harbor.jaali.dev/assessment`) | Store immutable images |
| CD | ArgoCD (`ci-cd` namespace) | Deploy from Git, drift detection, rollback |
| GitOps | `devops-assessment-gitops` | Desired state (Kustomize + ReferenceGrant) |

Jenkins never holds cluster credentials. The only bridge between CI and CD is a `git push` to the GitOps repo.

### 3. CI Pipeline Stages (Jenkins)

| Stage | Purpose | Blocking? |
|-------|---------|-----------|
| Checkout | Clone source | Yes |
| Install & Lint | `npm ci` + `ng lint` | Yes |
| Unit Tests | `ng test --watch=false` | No (best-effort) |
| SonarQube | Static analysis | No (informational) |
| Build & Push | Kaniko multi-stage build | Yes |
| Trivy Scan | Container vulnerability scan | No (report archived) |
| Update GitOps | Bump `prod-<sha>` tag in GitOps repo | Yes |

**Image tagging**: `prod-<8-char-commit-sha>` — never `latest` or `stable`.

**Jenkins environment variables**:

| Variable | Value |
|----------|-------|
| `HARBOR_REGISTRY` | `harbor.jaali.dev` |
| `HARBOR_PROJECT` | `assessment` |
| `IMAGE_NAME` | `assessment-app` |
| `IMAGE_TAG` | `prod-${GIT_COMMIT.take(8)}` |
| `GITOPS_REPO` | `github.com/ThierryMoi/devops-assessment-gitops.git` |

### 4. Kubernetes Deployment

**Gateway API (HTTPRoute)** attached to `jaali-gateway` in `envoy-gateway-system` — not Ingress. A **ReferenceGrant** authorizes the cross-namespace route (managed in the GitOps `gateway/` path).

**Production settings** (via Kustomize overlay):

| Setting | Value |
|---------|-------|
| Namespace | `assessment-app-prod` |
| Replicas | 3 |
| Hostname | `assessment.jaali.dev` |
| Rolling update | `maxUnavailable: 0` |
| Probes | `/healthz` on port 8080 |

**Security**: non-root pod, dropped capabilities, no service account token, read-only root filesystem disabled (nginx needs write to `/tmp`).

### 5. Helm Chart

An optional Helm chart lives in the GitOps repo (`chart/` v0.2.0). ArgoCD uses Kustomize; Helm is available for manual installs or Harbor OCI packaging.

### 6. Trade-offs

- **Angular 7 / Node 10 are EOL** — pinned for compatibility with the original assessment codebase.
- **Single production cluster** — no dev environment; Jenkins deploys directly to prod.
- **Private GitOps repo** — requires a GitHub PAT registered in ArgoCD.
- **Tests best-effort in CI** — Angular 7 tests need Chromium; stage is non-blocking.

---

## Quick Start

### Build locally

```bash
docker build -t assessment-app:local .
docker run -p 8080:8080 assessment-app:local
# → http://localhost:8080
```

### Deploy to Kubernetes

```bash
export KUBECONFIG=/path/to/jaali-platform/kubeconfig/jaali.yaml

# Prerequisites: ArgoCD, jaali-gateway, Harbor, GitHub repo registered in ArgoCD
kubectl apply -f ../devops-assessment-gitops/argocd/application-prod.yaml

# Verify
kubectl get application assessment-app-prod -n ci-cd
kubectl get pods -n assessment-app-prod
```

### Trigger CI

Push to the Jenkins-tracked branch (`feature/devops-setup` or `main` after merge) — Jenkins runs the pipeline and updates the GitOps repo.

---

## Repository Structure

```
devops-assessment/              ← this repo (CI)
├── src/                        ← Angular 7 source
├── Dockerfile                  ← Multi-stage build (Node 10 → Nginx non-root)
├── Jenkinsfile                 ← CI pipeline (8 stages)
├── nginx.conf                  ← SPA routing + /healthz + security headers
├── sonar-project.properties
├── .dockerignore
└── README.md

devops-assessment-gitops/       ← separate repo (CD)
├── base/                       ← Kustomize base manifests
├── overlays/prod/              ← Prod: namespace, 3 replicas, prod-<sha>
├── gateway/                    ← ReferenceGrant → jaali-gateway
├── argocd/                     ← ArgoCD Application (multi-source)
└── chart/                      ← Helm chart (optional)
```

## Related Repositories

| Repo | Role |
|------|------|
| [devops-assessment-gitops](https://github.com/ThierryMoi/devops-assessment-gitops) | Kubernetes manifests + ArgoCD Application |
| [jaali-ai-platform](https://github.com/ThierryMoi/jaali-ai-platform) | Cluster platform (Gateway, ArgoCD, Jenkins, Harbor, DNS) |

## Production Improvements

- Horizontal Pod Autoscaler (HPA)
- PodDisruptionBudget
- NetworkPolicies
- Prometheus ServiceMonitor + Grafana dashboard
- Image signing (Cosign) + SBOM
- Rate limiting / WAF at Gateway level
- Progressive delivery (Argo Rollouts)
