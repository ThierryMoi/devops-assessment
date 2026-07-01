# Assessment App — DevOps Assessment

Angular 7 todo application with a full CI/CD pipeline: Jenkins (CI) → Harbor → GitOps → ArgoCD + Argo Rollouts (CD) on the [JaaLi platform](https://github.com/ThierryMoi/jaali-ai-platform).

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
│  ├── Rollout (canary)    └── ReferenceGrant    └── Helm (optional)  │
│  ├── HPA                                                            │
│  ├── Service                                                        │
│  └── HTTPRoute                                                      │
└──────────────────────────────────────────────────────────┬──────────┘
                                                           │
                                                  ArgoCD auto-sync
                                                           │
                                                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│                   Kubernetes — JaaLi production cluster                │
│                                                                     │
│  argo-rollouts              assessment-app-prod                     │
│  ┌─ controller ──────┐       ┌─ canary: 20→50→100%                  │
│  └───────────────────┘       │  HPA: 3→6 pods                      │
│  envoy-gateway-system          │  HTTPRoute: assessment.jaali.dev    │
│  ┌─ jaali-gateway ──┼───────▶│  Service → Rollout (nginx:8080)   │
│  └───────────────────┘       └────────────────────────────────────┘
└─────────────────────────────────────────────────────────────────────┘
```

## Design Decisions

### 1. Containerization

**Multi-stage Docker build** using `node:10-alpine` (Angular 7.2) + `nginx:1.27-alpine` (~25 MB final image).

The container runs as `nginx` user (non-root, UID 101). Custom `nginx-main.conf` + `nginx.conf` handle SPA routing, gzip, `/healthz` probes, and writable `/tmp/` paths for non-root operation.

### 2. CI/CD — Separation of Concerns

| Layer | Tool | Responsibility |
|-------|------|----------------|
| CI | Jenkins | Build, test, scan, push image |
| Registry | Harbor | Immutable `prod-<sha>` images |
| CD | ArgoCD | Sync Git → cluster |
| Progressive delivery | Argo Rollouts | Canary deployment (20→50→100 %) |
| GitOps | `devops-assessment-gitops` | Rollout, HPA, HTTPRoute, ReferenceGrant |

Jenkins never holds cluster credentials. The bridge between CI and CD is a `git push` to the GitOps repo.

### 3. CI Pipeline (Jenkins)

| Stage | Blocking? |
|-------|-----------|
| Checkout, Lint, Build & Push, Update GitOps | Yes |
| Unit Tests, SonarQube, Trivy | No (best-effort) |

**Image tag**: `prod-<8-char-commit-sha>` — never `latest` or `stable`.

### 4. Kubernetes Deployment

**Gateway API** — HTTPRoute on `jaali-gateway` + ReferenceGrant cross-namespace.

**Argo Rollouts canary** (replaces Deployment RollingUpdate):

```
new image → 20% → pause 2m → 50% → pause 2m → 100%
```

**HPA**: 3–6 replicas based on CPU (70 %) and memory (80 %).

**Probes**: `/healthz` on port 8080 — unhealthy pods are excluded from traffic automatically.

**Security**: non-root, dropped capabilities, no service account token.

### 5. Incident Response

| Situation | Automatic? | Action |
|-----------|------------|--------|
| Pod not ready | Yes | Excluded from traffic |
| Pod crash | Yes | Kubernetes restart |
| High load | Yes | HPA scales up |
| Bad image during canary | Partial | Limited exposure (20–50 %), then manual `abort`/`undo` |
| Bad image at 100 % | No | `rollouts undo`, `argocd rollback`, or `git revert` |

```bash
# Abort canary in progress
kubectl argo rollouts abort assessment-app -n assessment-app-prod

# Rollback to previous version
kubectl argo rollouts undo assessment-app -n assessment-app-prod
```

---

## Quick Start

### Build & test locally

```bash
docker build -t assessment-app:local .
docker run --rm -p 8080:8080 --user 101:101 assessment-app:local
curl http://localhost:8080/healthz   # → 200
```

### Deploy to Kubernetes

```bash
export KUBECONFIG=/path/to/jaali-platform/kubeconfig/jaali.yaml

kubectl apply -f ../devops-assessment-gitops/argocd/application-argo-rollouts.yaml
kubectl apply -f ../devops-assessment-gitops/argocd/application-prod.yaml

kubectl argo rollouts get rollout assessment-app -n assessment-app-prod
```

### Trigger CI

Push to `feature/devops-setup` (or `main` after merge) — Jenkins builds, pushes to Harbor, and updates the GitOps tag.

---

## Repository Structure

```
devops-assessment/              ← this repo (CI)
├── src/                        ← Angular 7 source
├── Dockerfile                  ← Multi-stage build (Node 10 → Nginx non-root)
├── nginx.conf / nginx-main.conf
├── Jenkinsfile                 ← CI pipeline (8 stages)
└── README.md

devops-assessment-gitops/       ← separate repo (CD)
├── base/rollout.yaml           ← Argo Rollout
├── overlays/prod/              ← canary, HPA, prod-<sha>
├── gateway/                    ← ReferenceGrant
├── argocd/                     ← ArgoCD Applications
└── chart/                      ← Helm chart v0.4.0 (optional)
```

## Related Repositories

| Repo | Role |
|------|------|
| [devops-assessment-gitops](https://github.com/ThierryMoi/devops-assessment-gitops) | Kubernetes manifests + ArgoCD Applications |
| [jaali-ai-platform](https://github.com/ThierryMoi/jaali-ai-platform) | Cluster platform (Gateway, ArgoCD, Harbor, DNS, TLS) |

## Future Improvements

- AnalysisRun (automatic canary abort via Prometheus)
- PodDisruptionBudget + NetworkPolicies
- Cosign image signing + SBOM
- Gateway API traffic splitting for precise canary routing
