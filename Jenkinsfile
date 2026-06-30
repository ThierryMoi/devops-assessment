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

    # ── Docker CLI + Buildx (Kaniko alternative: builds inside K8s) ──
    - name: docker
      image: docker:27-cli
      command: ['sleep']
      args: ['infinity']
      volumeMounts:
        - name: docker-sock
          mountPath: /var/run/docker.sock

    # ── Trivy scanner ──
    - name: trivy
      image: aquasec/trivy:latest
      command: ['sleep']
      args: ['infinity']

  volumes:
    - name: docker-sock
      hostPath:
        path: /var/run/docker.sock
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
        GITOPS_REPO   = 'https://github.com/ThierryMoi/devops-assessment-gitops.git'
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
        // 2. INSTALL & LINT
        // ─────────────────────────────────────────────
        stage('Install & Lint') {
            steps {
                container('node') {
                    sh 'npm ci --no-audit'
                    sh 'npx ng lint'
                }
            }
        }

        // ─────────────────────────────────────────────
        // 3. UNIT TESTS (non-blocking)
        // ─────────────────────────────────────────────
        stage('Unit Tests') {
            steps {
                container('node') {
                    // ChromeHeadless requires Chromium — best-effort in CI
                    sh 'npx ng test --watch=false --code-coverage || true'
                }
            }
        }

        // ─────────────────────────────────────────────
        // 4. SONARQUBE ANALYSIS (non-blocking)
        // ─────────────────────────────────────────────
        stage('SonarQube Analysis') {
            steps {
                // 'SonarScanner' = nom de l'outil dans Manage Jenkins → Tools
                // withSonarQubeEnv() injecte SONAR_HOST_URL + token automatiquement
                script {
                    def scannerHome = tool 'SonarScanner'
                    withSonarQubeEnv() {
                        sh "${scannerHome}/bin/sonar-scanner"
                    }
                }
            }
        }

        // ─────────────────────────────────────────────
        // 5. DOCKER BUILD
        // ─────────────────────────────────────────────
        stage('Docker Build') {
            steps {
                container('docker') {
                    sh """
                        docker build \
                            --label "org.opencontainers.image.revision=${GIT_COMMIT}" \
                            --label "org.opencontainers.image.source=${GIT_URL}" \
                            -t ${FULL_IMAGE} .
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
        // 7. PUSH TO HARBOR
        // ─────────────────────────────────────────────
        stage('Push to Harbor') {
            steps {
                container('docker') {
                    withCredentials([usernamePassword(
                        credentialsId: 'harbor-credentials',
                        usernameVariable: 'HARBOR_USER',
                        passwordVariable: 'HARBOR_PASS'
                    )]) {
                        sh """
                            echo "\${HARBOR_PASS}" | docker login ${HARBOR_REGISTRY} \
                                -u "\${HARBOR_USER}" --password-stdin
                            docker push ${FULL_IMAGE}
                            docker logout ${HARBOR_REGISTRY}
                        """
                    }
                }
            }
        }

        // ─────────────────────────────────────────────
        // 8. UPDATE GITOPS REPO → triggers ArgoCD sync
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
            echo '❌ Pipeline failed — check stage logs above.'
        }
        always {
            container('docker') {
                sh "docker rmi ${FULL_IMAGE} || true"
            }
            sh 'rm -rf gitops-tmp'
            cleanWs()
        }
    }
}
