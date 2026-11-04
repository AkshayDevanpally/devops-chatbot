// QwenOps pipeline. Stage names match the stations on the Pipeline page (app-ui/public/pipeline),
// which Phase 8 connects to live build events.
//
// One image per commit, tagged with the short Git SHA, promoted unchanged dev -> qa -> prod.
// Every stage runs on the host agent (label "docker"); the prod approval waits WITHOUT holding it.
pipeline {
  agent none

  options {
    timestamps()
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '30', artifactNumToKeepStr: '10'))
    skipDefaultCheckout()
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
        checkout scm
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
        sh './scripts/06-deploy.sh dev "$TAG"'
        sh './scripts/07-verify.sh dev'
      }
    }

    stage('Deploy qa') {
      agent { label 'docker' }
      options { timeout(time: 15, unit: 'MINUTES') }
      steps {
        sh './scripts/06-deploy.sh qa "$TAG"'
        sh './scripts/07-verify.sh qa'
      }
    }

    stage('Ship to prod') {
      // Waits up to a day for a person to approve; the agent is free meanwhile.
      options { timeout(time: 1, unit: 'DAYS') }
      input {
        message 'Ship this build to prod?'
        ok 'Ship it'
      }
      agent { label 'docker' }
      environment { PROD_APPROVED = 'yes' }
      steps {
        sh './scripts/06-deploy.sh prod "$TAG"'
        sh './scripts/07-verify.sh prod'
      }
    }
  }
}
