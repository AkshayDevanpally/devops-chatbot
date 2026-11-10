// "Be a Dev" (Phase 8): a visitor picks a colour on the site, pipeline-events starts this job, and the
// Pipeline page shows it live. It changes only the colour (a Helm value) of the environment whose page
// the colour was picked on (ENV, set by chat-api, never by the browser) and checks that site serves it.
pipeline {
  agent { label 'docker' }
  options {
    timestamps()
    skipDefaultCheckout()
    disableConcurrentBuilds()
    timeout(time: 10, unit: 'MINUTES')
  }
  parameters {
    choice(name: 'COLOR', choices: ['teal', 'indigo', 'rose', 'amber', 'emerald', 'slate'], description: 'New colour')
    choice(name: 'ENV', choices: ['dev', 'qa', 'prod'], description: 'Environment whose colour changes')
  }
  stages {
    stage('Checkout') {
      steps { checkout scm }
    }
    stage('Validate') {
      steps { sh './scripts/19-theme.sh validate "$COLOR" "$ENV"' }
    }
    stage('Deploy') {
      steps { sh './scripts/19-theme.sh deploy "$COLOR" "$ENV"' }
    }
    stage('Verify') {
      steps { sh './scripts/19-theme.sh verify "$COLOR" "$ENV"' }
    }
  }
}
