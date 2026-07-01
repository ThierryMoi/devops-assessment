pipeline {
    agent {
        kubernetes {
            yaml """
apiVersion: v1
kind: Pod
metadata:
  labels:
    jenkins: agent
spec:
  containers:
    # ── Node 10 pour build Angular 7 ──
    - name: node
      image: node:10-alpine
      command: ['sleep']
      args: ['infinity']

    # ── Kaniko: build & push image sans Docker daemon ──
    - name: kaniko
      image: gcr.io/kaniko-project/executor:debug
      command: ['sleep']
      args: ['infinity']
      volumeMounts:
        - name: kaniko-secret
          mountPath: /kaniko/.docker

    # ── Trivy scanner ──
    # FIX: ajout du secret Harbor pour permettre le pull de l'image privee
    # en mode remote, via le fichier config.json du registre
    - name: trivy
      image: aquasec/trivy:latest
      command: ['sleep']
      args: ['infinity']
      env:
        - name: DOCKER_CONFIG
          value: /kaniko/.docker
      volumeMounts:
        - name: kaniko-secret
          mountPath: /kaniko/.docker

  volumes:
    - name: kaniko-secret
      secret:
        secretName: harbor-registry-secret
        items:
          - key: .dockerconfigjson
            path: config.json
"""
        }
    }

    environment {
        // ── Registry Harbor ──
        HARBOR_REGISTRY = 'harbor.jaali.dev'
        HARBOR_PROJECT  = 'assessment'
        IMAGE_NAME      = 'todo-app'
        IMAGE_TAG       = "${GIT_COMMIT.take(8)}"
        FULL_IMAGE      = "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${IMAGE_NAME}:${IMAGE_TAG}"

        // ── GitOps repo (CD via ArgoCD) ──
        GITOPS_REPO   = 'github.com/ThierryMoi/todo-app-gitops.git'
        GITOPS_BRANCH = 'main'
    }

    options {
        timeout(time: 20, unit: 'MINUTES')
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '10'))
        timestamps()
    }

    stages {

        // ─────────────────────────────────────────────
        // 1. CHECKOUT
        // ─────────────────────────────────────────────
        stage('Checkout') {
            steps {
                checkout scm
                sh 'echo "Building commit: ${GIT_COMMIT}"'
            }
        }

        // ─────────────────────────────────────────────
        // 2. INSTALL & LINT (non-blocking)
        // ─────────────────────────────────────────────
        stage('Install & Lint') {
            steps {
                container('node') {
                    sh 'npm ci --no-audit'
                    sh 'npx ng lint || true'
                }
            }
        }

        // ─────────────────────────────────────────────
        // 3. UNIT TESTS (non-blocking)
        // ─────────────────────────────────────────────
        stage('Unit Tests') {
            steps {
                container('node') {
                    sh 'npx ng test --watch=false --code-coverage || true'
                }
            }
        }

        // ─────────────────────────────────────────────
        // 4. SONARQUBE ANALYSIS (non-blocking)
        // FIX: le sonar-scanner CLI 8.1.0 lit "sonar.token" / SONAR_TOKEN,
        // pas SONAR_AUTH_TOKEN (variable historique injectée par le plugin
        // Jenkins). On passe donc le token explicitement en propriété -D.
        // ─────────────────────────────────────────────
        stage('SonarQube Analysis - DEBUG') {
            steps {
                script {
                    try {
                        def scannerHome = tool 'SonarScanner'
                        withSonarQubeEnv('sonar') {
                            sh '''
                                echo "=== Variables SONAR_* injectees par Jenkins ==="
                                printenv | grep -i SONAR | sed -E 's/=(.{0,4}).*/=\\1***MASKED***/'
                                echo "=== Fin liste ==="
                                echo ""
                                echo "SONAR_HOST_URL brut: ${SONAR_HOST_URL}"
                                echo "SONAR_AUTH_TOKEN est vide ? : $([ -z "${SONAR_AUTH_TOKEN}" ] && echo OUI-VIDE || echo NON-rempli)"
                                echo "Longueur SONAR_AUTH_TOKEN: ${#SONAR_AUTH_TOKEN}"
                            '''
                        }
                    } catch (Exception e) {
                        echo "Debug stage failed: ${e.message}"
                    }
                }
            }
        }
        // ─────────────────────────────────────────────
        // 5. BUILD & PUSH (Kaniko — no Docker daemon needed)
        // ─────────────────────────────────────────────
        stage('Build & Push') {
            steps {
                container('kaniko') {
                    sh """
                        /kaniko/executor \
                            --context=\$(pwd) \
                            --dockerfile=\$(pwd)/Dockerfile \
                            --destination=${FULL_IMAGE} \
                            --cache=true \
                            --cache-repo=${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${IMAGE_NAME}-cache
                    """
                }
            }
        }

        // ─────────────────────────────────────────────
        // 6. TRIVY SECURITY SCAN (non-blocking)
        // ─────────────────────────────────────────────
        stage('Trivy Scan') {
            steps {
                container('trivy') {
                    sh """
                        trivy image \
                            --exit-code 0 \
                            --severity HIGH,CRITICAL \
                            --no-progress \
                            --format table \
                            ${FULL_IMAGE} | tee trivy-report.txt
                    """
                }
            }
            post {
                always {
                    archiveArtifacts artifacts: 'trivy-report.txt', allowEmptyArchive: true
                }
            }
        }

        // ─────────────────────────────────────────────
        // 7. UPDATE GITOPS REPO → triggers ArgoCD sync
        // ─────────────────────────────────────────────
        stage('Update GitOps') {
            steps {
                withCredentials([string(
                    credentialsId: 'github-token',
                    variable: 'GH_TOKEN'
                )]) {
                    sh """
                        rm -rf gitops-tmp
                        git clone --depth 1 --branch ${GITOPS_BRANCH} \
                            https://\${GH_TOKEN}@${GITOPS_REPO} gitops-tmp

                        cd gitops-tmp/overlays/dev
                        sed -i 's|newTag:.*|newTag: "${IMAGE_TAG}"|' kustomization.yaml

                        git config user.email "jenkins@jaali.dev"
                        git config user.name "Jenkins CI"
                        git add .
                        git diff --cached --quiet || git commit -m "ci: deploy todo-app ${IMAGE_TAG}"
                        git push origin ${GITOPS_BRANCH}
                    """
                }
            }
        }
    }

    post {
        success {
            echo """
            CI Pipeline completed successfully
            Image: ${FULL_IMAGE}
            ArgoCD will auto-sync the deployment
            """
        }
        failure {
            echo 'Pipeline failed — check stage logs above.'
        }
        always {
            sh 'rm -rf gitops-tmp'
        }
    }
}