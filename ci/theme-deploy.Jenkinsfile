// "Be a Dev" (Phase 8): a visitor picks a colour on the site, pipeline-events starts this job, and the
// Pipeline page shows it live. It changes only dev's colour (a Helm value) and checks the site serves it.
pipeline {
  agent { label 'docker' }
  options {
    timestamps()
    skipDefaultCheckout()
    disableConcurrentBuilds()
    timeout(time: 10, unit: 'MINUTES')
  }
  parameters {
    choice(name: 'COLOR', choices: ['teal', 'indigo', 'rose', 'amber', 'emerald', 'slate'], description: 'New colour for dev')
  }
  stages {
    stage('Checkout') {
      steps { checkout scm }
    }
    stage('Validate') {
      steps { sh './scripts/19-theme.sh validate "$COLOR"' }
    }
    stage('Deploy dev') {
      steps { sh './scripts/19-theme.sh deploy "$COLOR"' }
    }
    stage('Verify') {
      steps { sh './scripts/19-theme.sh verify "$COLOR"' }
    }
  }
}
