# Todo App — DevOps Assessment

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         CI (Jenkins)                                │
│                                                                     │
│  Checkout → Lint → Tests → SonarQube → Docker Build → Trivy → Push │
│                                                          │          │
│                                                    Harbor Registry  │
└──────────────────────────────────────────────────────────┬──────────┘
                                                           │
                                              git push (image tag)
                                                           │
                                                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      GitOps Repo (CD)                               │
│                                                                     │
│  base/           overlays/dev/        overlays/prod/    chart/      │
│  ├── deployment  └── kustomization    └── kustomization ├── Chart   │
│  ├── service                                            ├── values  │
│  └── httproute                                          └── tpl/    │
└──────────────────────────────────────────────────────────┬──────────┘
                                                           │
                                                    ArgoCD auto-sync
                                                           │
                                                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      Kubernetes Cluster                              │
│                                                                     │
│  ┌─ Gateway (Envoy) ─ TLS (cert-manager/Let's Encrypt) ┐           │
│  │                                                      │           │
│  │  HTTPRoute: todo.jaali.dev                           │           │
│  │       │                                              │           │
│  │       ▼                                              │           │
│  │  Service (ClusterIP:80)                              │           │
│  │       │                                              │           │
│  │       ├── Pod (nginx:8080) ── replica 1              │           │
│  │       └── Pod (nginx:8080) ── replica 2              │           │
│  └──────────────────────────────────────────────────────┘           │
└─────────────────────────────────────────────────────────────────────┘
```

## Design Decisions

### 1. Containerization

**Multi-stage Docker build** using `node:10-alpine` (Angular 7.2 requires Node 10) for the build stage and `nginx:1.27-alpine` for serving. This approach reduces the final image from ~400MB to ~25MB by excluding node_modules, TypeScript source, and build tooling.

The container runs as `nginx` user (non-root, UID 101) for security. A custom `nginx.conf` handles SPA routing (`try_files`), gzip compression, cache headers for hashed assets, and a `/healthz` endpoint for Kubernetes probes.

### 2. CI/CD Architecture — Separation of Concerns

The pipeline follows a **strict CI/CD separation**:

- **CI (Jenkins)**: build, test, scan, push — no cluster access needed
- **CD (ArgoCD)**: deployment, sync, rollback — pull-based GitOps

This is more secure than a monolithic pipeline where Jenkins runs `kubectl apply`, because:
- Jenkins never holds a kubeconfig or cluster credentials
- The only bridge between CI and CD is a `git push` to the GitOps repo
- ArgoCD pulls the desired state; no inbound network access to the cluster required
- Drift detection and self-healing are handled natively by ArgoCD

### 3. CI Pipeline Stages (Jenkins)

| Stage | Purpose | Blocking? |
|-------|---------|-----------|
| Checkout | Clone source | Yes |
| Install & Lint | `npm ci` + `ng lint` (tslint) | Yes |
| Unit Tests | `ng test --watch=false` | No (best-effort) |
| SonarQube | Static analysis + quality gate | No (informational) |
| Docker Build | Multi-stage build | Yes |
| Trivy Scan | Container vulnerability scan | No (report archived) |
| Push to Harbor | Push image tagged with commit SHA | Yes |
| Update GitOps | Update image tag in GitOps repo | Yes |

**Non-blocking scans rationale**: During initial integration, blocking on SonarQube quality gates or Trivy findings would stall delivery. Scans run and report results; the team reviews and progressively hardens thresholds. In a mature pipeline, both would become blocking (`abortPipeline: true`, `--exit-code 1`).

**Image tagging**: Images are tagged with the first 8 characters of the git commit SHA — never `latest`. This ensures traceability, reproducibility, and safe rollbacks.

### 4. Kubernetes Deployment

**Gateway API (HTTPRoute)** instead of Ingress because:
- Gateway API is the official successor to Ingress (GA since Kubernetes 1.26)
- It provides a cleaner separation between infrastructure (Gateway, managed by platform team) and application routing (HTTPRoute, managed by app team)
- Compatible with Envoy Gateway deployed on the cluster

**TLS** is automated via cert-manager with Let's Encrypt ClusterIssuer, attached to the Gateway.

**Deployment strategy**: `RollingUpdate` with `maxUnavailable: 0` ensures zero-downtime deployments. Combined with readiness probes, new pods must be healthy before old ones are terminated.

**Security hardening**:
- `runAsNonRoot: true` — pod-level enforcement
- `allowPrivilegeEscalation: false`
- `capabilities.drop: ["ALL"]`
- `automountServiceAccountToken: false` — the app doesn't need K8s API access

### 5. Helm Chart

The Helm chart in `chart/` parameterizes all environment-specific values:

| Parameter | Purpose |
|-----------|---------|
| `image.repository` / `image.tag` | Registry and version |
| `replicaCount` | Scale per environment |
| `resources.requests/limits` | Right-sizing |
| `gateway.hostname` | DNS per environment |
| `gateway.tlsSecretName` | TLS certificate |

**Why Helm is useful here**:
- **Environment templating**: one chart, different `values-dev.yaml` / `values-prod.yaml`
- **Release management**: `helm history`, `helm rollback` for auditable deployments
- **Packaging**: chart can be pushed to Harbor as an OCI artifact for versioned distribution
- **Ecosystem**: well-understood by teams, integrates natively with ArgoCD

### 6. Trade-offs and Assumptions

- **Angular 7.2 is EOL**: in production, the first priority would be upgrading the framework. Node 10 is also EOL. The Dockerfile pins these versions to make the existing code work.
- **Single cluster**: dev and prod share the same cluster, isolated by namespaces. In production, separate clusters would be preferred.
- **Jenkins not deployed in-scope**: the Jenkinsfile is ready to execute on any Jenkins instance with Docker Pipeline, SonarQube Scanner, and SSH Agent plugins.
- **Tests may not run in CI**: Angular 7 tests require Chrome/Chromium. The test stage is best-effort (`|| true`) to avoid blocking on environment issues.

### 7. Production Improvements

If this were a real production deployment, I would add:

- **Horizontal Pod Autoscaler (HPA)** based on CPU/request metrics
- **PodDisruptionBudget** to guarantee availability during node maintenance
- **NetworkPolicies** to restrict pod-to-pod communication
- **Prometheus ServiceMonitor** on nginx for request metrics + Grafana dashboard
- **Image signing** with Cosign for supply chain security
- **SBOM generation** alongside Trivy scans
- **Rate limiting and WAF rules** at the Gateway level
- **Progressive delivery** with Argo Rollouts (canary/blue-green)

---

## Quick Start

### Build locally

```bash
docker build -t todo-app:local .
docker run -p 8080:8080 todo-app:local
# Open http://localhost:8080
```

### Deploy to Kubernetes

```bash
# Prerequisites: ArgoCD deployed, cert-manager configured
kubectl apply -f ../todo-app-gitops/argocd/application-dev.yaml
# ArgoCD syncs automatically from the GitOps repo
```

### Trigger CI

Push to `main` branch — Jenkins picks up the Jenkinsfile and runs the pipeline.

---

## Repository Structure

```
todo-app/                    ← this repo (fork of akieni-tech/devops-assessment)
├── src/                     ← Angular 7 source (unchanged)
├── Dockerfile               ← Multi-stage build (Node 10 → Nginx)
├── Jenkinsfile              ← CI pipeline (8 stages)
├── nginx.conf               ← SPA routing + security headers
├── sonar-project.properties ← SonarQube configuration
├── .dockerignore            ← Excludes from Docker context
└── README.md                ← This file

todo-app-gitops/             ← separate repo
├── base/                    ← Base K8s manifests (Kustomize)
├── overlays/dev/            ← Dev overrides (1 replica, dev DNS)
├── overlays/prod/           ← Prod overrides (3 replicas, TLS)
├── argocd/                  ← ArgoCD Application CRs
└── chart/                   ← Helm chart
```
