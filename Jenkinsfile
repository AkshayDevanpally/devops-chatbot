// QwenOps pipeline. Stage names match the stations on the Pipeline page (app-ui/public/pipeline),
// which Phase 8 connects to live build events.
//
// One image per commit, tagged with the short Git SHA, promoted unchanged dev -> qa -> prod.
// Every stage runs on the host agent (label "docker"); the prod approval waits WITHOUT holding it.
//
// Builds may overlap, so a build waiting for prod approval never blocks newer pushes:
// - each stage checks out this build's own commit (overlapping builds can't share files);
// - milestones keep deploys in commit order: once a newer build passes one, older builds that
//   haven't reached it yet are cancelled. Approving a newer build cancels older ones still waiting.
// Deploys go through scripts/promote.sh: deploy, verify, and roll back automatically on failure.
pipeline {
  agent none

  options {
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '30', artifactNumToKeepStr: '10'))
  }

  environment {
    CI = 'true'                 // build script refuses to skip the vulnerability scan
    REGISTRY = 'localhost:5000'
  }

  stages {
    stage('Checkout') {
      agent { label 'docker' }
      options { timeout(time: 5, unit: 'MINUTES') }
      steps {
        sh 'git clean -ffdx'    // the agent keeps its workspace between builds
        script {
          env.TAG = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
          currentBuild.displayName = "#${env.BUILD_NUMBER} ${env.TAG}"
        }
      }
    }

    stage('Build') {
      agent { label 'docker' }
      options { timeout(time: 20, unit: 'MINUTES') }
      steps { sh './scripts/03-build-push.sh build' }   // docker build + hadolint
    }

    stage('Test') {
      agent { label 'docker' }
      options { timeout(time: 15, unit: 'MINUTES') }
      steps {
        sh './scripts/test.sh'                         // ruff + pytest against a throwaway Postgres
        sh '''
          for env in dev qa prod; do
            helm lint helm/chatbot -f "helm/chatbot/values-$env.yaml" --set image.tag="$TAG"
          done
        '''
      }
    }

    stage('Security scan') {
      agent { label 'docker' }
      options { timeout(time: 15, unit: 'MINUTES') }
      steps { sh './scripts/03-build-push.sh scan' }    // Trivy: fails on fixable HIGH/CRITICAL
    }

    stage('Sign & box') {
      agent { label 'docker' }
      options { timeout(time: 10, unit: 'MINUTES') }
      steps {
        sh './scripts/03-build-push.sh sbom'            // SPDX bill of materials per image
        sh './scripts/03-build-push.sh push'
        archiveArtifacts artifacts: 'sbom/*.spdx.json', fingerprint: true
      }
    }

    stage('Deploy dev') {
      agent { label 'docker' }
      options { timeout(time: 15, unit: 'MINUTES') }
      steps {
        milestone(ordinal: 10, label: 'deploy-dev')
        sh './scripts/promote.sh dev "$TAG"'
      }
    }

    stage('Deploy qa') {
      agent { label 'docker' }
      options { timeout(time: 15, unit: 'MINUTES') }
      steps {
        milestone(ordinal: 20, label: 'deploy-qa')
        sh './scripts/promote.sh qa "$TAG"'
      }
    }

    stage('Ship to prod') {
      // Waits up to a day for a person to approve; no agent is held while waiting.
      agent none
      options { timeout(time: 1, unit: 'DAYS') }
      steps {
        milestone(ordinal: 30, label: 'awaiting-prod')
        // Only admin may approve: the Pipeline page's Jenkins account (pipeline-viewer) can start jobs
        // but must never be able to ship to prod.
        input message: "Ship ${env.TAG} to prod?", ok: 'Ship it', submitter: 'admin'
        milestone(ordinal: 40, label: 'deploy-prod')       // cancels older builds still waiting for approval
        script {
          node('docker') {
            checkout scm
            withEnv(['PROD_APPROVED=yes']) { sh './scripts/promote.sh prod "$TAG"' }
          }
        }
      }
    }
  }
}
