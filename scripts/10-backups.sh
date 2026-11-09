#!/usr/bin/env bash
# Postgres backups (k8s/platform/60-backups.yaml) and their Pulse-page service (65-backup-ops.yaml).
# Usage: ./scripts/10-backups.sh <command>
#   install               apply the backup jobs, backup-ops and the data-namespace quota they need
#   offsite-setup         S3 bucket (terraform/backups) + write-only key as secret offsite-s3
#   offsite-now           copy the newest backup to S3 right away and show its log
#   admin-password        set the password for "Back up now" on the Pulse page
#   now                   take a backup right away and show its log
#   status                list the backups on the server and the last runs
#   test                  restore the newest backup into a throwaway Postgres and check it
#   download [DIR]        copy the newest backup (or STAMP=...) to DIR (default ./backups)
#   restore <env> <stamp> replace one environment's database with a backup (asks to confirm)
set -euo pipefail
cd "$(dirname "$0")/.."
NS=data
CMD="${1:-}"; shift || true

# Run a Job made from a CronJob (or given as YAML on stdin), wait for it, print its log.
run_job() {   # run_job <job-name>
  local name=$1 state=""
  for _ in $(seq 1 300); do
    state=$(kubectl -n $NS get job "$name" -o jsonpath='{.status.conditions[?(@.status=="True")].type}' 2>/dev/null || true)
    [[ $state == *Complete* || $state == *Failed* ]] && break
    sleep 2
  done
  kubectl -n $NS logs "job/$name" --tail=100 || true
  [[ $state == *Complete* ]] || { echo "!! job $name did not complete (${state:-timed out})"; return 1; }
}

# A short-lived pod that mounts the backup volume read-only (no network, no credentials).
BROWSER=postgres-backup-browser
browser_up() {
  kubectl -n $NS apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: { name: $BROWSER, namespace: $NS, labels: { app.kubernetes.io/name: $BROWSER } }
spec:
  serviceAccountName: postgres-backup
  automountServiceAccountToken: false
  restartPolicy: Never
  activeDeadlineSeconds: 600
  securityContext:
    runAsNonRoot: true
    runAsUser: 70
    runAsGroup: 70
    fsGroup: 70
    seccompProfile: { type: RuntimeDefault }
    appArmorProfile: { type: Localhost, localhostProfile: k8s-chatbot }
  containers:
    - name: browser
      image: postgres:16-alpine
      command: ["sleep", "600"]
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
      resources: { requests: { cpu: 10m, memory: 16Mi }, limits: { cpu: 100m, memory: 64Mi } }
      volumeMounts: [{ name: backups, mountPath: /backups, readOnly: true }]
  volumes: [{ name: backups, persistentVolumeClaim: { claimName: postgres-backups } }]
YAML
  kubectl -n $NS wait --for=condition=Ready "pod/$BROWSER" --timeout=90s >/dev/null
}
browser_down() { kubectl -n $NS delete pod "$BROWSER" --wait=false >/dev/null 2>&1 || true; }

case $CMD in
  install)
    echo "==> data-namespace quota (room for the backup and restore-test jobs)"
    # Apply only the data quota, so this doesn't also apply other pending quota changes.
    python3 -I -c '
import sys
docs = open("k8s/platform/10-quotas.yaml").read().split("\n---\n")
quota = [d for d in docs if "kind: ResourceQuota" in d and "namespace: data" in d]
assert len(quota) == 1, "data quota not found"
print(quota[0])' | kubectl apply -f -
    echo "==> backup jobs"
    kubectl apply -f k8s/platform/60-backups.yaml
    echo "==> backup-ops (status, logs and 'Back up now' on the Pulse page)"
    kubectl -n $NS create configmap backup-ops-code --from-file=k8s/platform/backup-ops/backup_ops.py \
      --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -f k8s/platform/65-backup-ops.yaml
    kubectl -n $NS rollout restart deployment/backup-ops >/dev/null   # pick up code changes
    kubectl -n $NS rollout status deployment/backup-ops --timeout=120s
    kubectl -n $NS get secret offsite-s3 >/dev/null 2>&1 || echo "Off-site copy not set up yet: make backup-offsite-setup"
    kubectl -n $NS get secret backup-admin >/dev/null 2>&1 || echo "'Back up now' is off until: make backup-admin-password"
    echo "Installed. Nightly 02:30 UTC, off-site every 3 days 04:15 UTC, restore test Sundays 03:30 UTC."
    ;;

  offsite-setup)
    export AWS_PROFILE="${AWS_PROFILE:-chatbot}"
    TF="terraform -chdir=terraform/backups"
    $TF init -input=false >/dev/null
    $TF apply -input=false -auto-approve
    bucket=$($TF output -raw bucket); user=$($TF output -raw uploader_user)
    # A new key each time, straight into the cluster: it never touches the disk or Terraform state.
    old=$(aws iam list-access-keys --user-name "$user" --query 'AccessKeyMetadata[].AccessKeyId' --output text)
    key=$(aws iam create-access-key --user-name "$user" --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)
    kubectl -n $NS create secret generic offsite-s3 \
      --from-literal=AWS_ACCESS_KEY_ID="${key%%$'\t'*}" --from-literal=AWS_SECRET_ACCESS_KEY="${key##*$'\t'}" \
      --from-literal=BUCKET="$bucket" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    unset key
    for k in $old; do aws iam delete-access-key --user-name "$user" --access-key-id "$k"; done
    echo "Off-site copies go to s3://$bucket/postgres/ (write-only key in secret offsite-s3; old keys removed)."
    echo "Test it now: make backup-offsite-now"
    ;;

  offsite-now)
    kubectl -n $NS get secret offsite-s3 >/dev/null 2>&1 || { echo "run 'make backup-offsite-setup' first"; exit 1; }
    name="postgres-offsite-manual-$(date -u +%Y%m%d%H%M%S)"
    kubectl -n $NS create job "$name" --from=cronjob/postgres-offsite >/dev/null
    echo "==> $name"
    run_job "$name"
    ;;

  admin-password)
    if [[ -t 0 ]]; then
      read -r -s -p "Admin password for 'Back up now' (empty = generate one): " pw; echo
    else
      read -r pw || true
    fi
    if [[ -z $pw ]]; then pw=$(openssl rand -base64 18 | tr -d '/+=' | head -c 20); echo "Generated password: $pw"; fi
    [[ ${#pw} -ge 8 ]] || { echo "use at least 8 characters"; exit 1; }
    kubectl -n $NS create secret generic backup-admin --from-literal=password="$pw" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    unset pw
    kubectl -n $NS rollout restart deployment/backup-ops >/dev/null 2>&1 || true
    echo "Saved (secret backup-admin in namespace $NS). The Pulse page asks for it on 'Back up now'."
    ;;

  now)
    name="backup-manual-$(date -u +%Y%m%d%H%M%S)"
    kubectl -n $NS create job "$name" --from=cronjob/postgres-backup >/dev/null
    echo "==> $name"
    run_job "$name"
    ;;

  test)
    name="restore-test-manual-$(date -u +%Y%m%d%H%M%S)"
    kubectl -n $NS create job "$name" --from=cronjob/postgres-restore-test >/dev/null
    echo "==> $name"
    run_job "$name"
    ;;

  status)
    echo "==> schedules"
    kubectl -n $NS get cronjob postgres-backup postgres-offsite postgres-restore-test
    echo; echo "==> recent runs"
    kubectl -n $NS get jobs --sort-by=.metadata.creationTimestamp | tail -8
    echo; echo "==> backups on the server"
    trap browser_down EXIT; browser_up
    kubectl -n $NS exec "$BROWSER" -- sh -c '
      [ -s /backups/LATEST ] || { echo "no backups yet"; exit 0; }
      echo "newest: $(cat /backups/LATEST)"
      for d in /backups/20*; do printf "%s  %s\n" "$(du -sh "$d" | cut -f1)" "$(basename "$d")"; done
      df -h /backups | tail -1 | awk "{print \"free on the server disk (shared): \" \$4}"'
    ;;

  download)
    dest="${1:-backups}"
    trap browser_down EXIT; browser_up
    stamp="${STAMP:-$(kubectl -n $NS exec "$BROWSER" -- cat /backups/LATEST)}"
    [[ $stamp =~ ^20[0-9-]+T[0-9]{4}Z$ ]] || { echo "bad backup name: $stamp"; exit 1; }
    mkdir -p "$dest/$stamp"; chmod 700 "$dest"
    kubectl -n $NS cp "$BROWSER:/backups/$stamp" "$dest/$stamp" >/dev/null
    (cd "$dest/$stamp" && sha256sum -c --quiet SHA256SUMS) && echo "copied and checked: $dest/$stamp"
    echo "These files contain your chat data and password hashes: keep them private."
    ;;

  restore)
    env="${1:-}"; stamp="${2:-}"
    [[ $env =~ ^(dev|qa|prod)$ && $stamp =~ ^20[0-9-]+T[0-9]{4}Z$ ]] \
      || { echo "usage: $0 restore <dev|qa|prod> <stamp>   (see: make backup-status)"; exit 1; }
    app="chatbot-$env"
    echo "This REPLACES everything in database chat_$env with backup $stamp."
    echo "chat-api in $app is stopped during the restore (a minute or so) and started again after."
    if [[ -t 0 ]]; then
      read -r -p "Type '$env' to continue: " answer
      [[ $answer == "$env" ]] || { echo "cancelled"; exit 1; }
    else
      [[ ${CONFIRM:-} == "$env" ]] || { echo "not a terminal: set CONFIRM=$env to confirm"; exit 1; }
    fi

    echo "==> safety backup of the current data first"
    "$0" now

    replicas=$(kubectl -n "$app" get deployment chat-api -o jsonpath='{.spec.replicas}')
    restart() { echo "==> starting chat-api again ($replicas)"; kubectl -n "$app" scale deployment chat-api --replicas="$replicas" >/dev/null; }
    trap restart EXIT
    echo "==> stopping chat-api in $app (was $replicas)"
    kubectl -n "$app" scale deployment chat-api --replicas=0 >/dev/null
    kubectl -n "$app" wait --for=delete pod -l app.kubernetes.io/component=api --timeout=120s >/dev/null 2>&1 || true

    name="restore-$env-$(date -u +%Y%m%d%H%M%S)"
    echo "==> $name"
    kubectl -n $NS apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata: { name: $name, namespace: $NS }
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 600
  ttlSecondsAfterFinished: 604800
  template:
    metadata:
      labels: { app.kubernetes.io/name: postgres-backup }   # the label allowed to reach Postgres
    spec:
      serviceAccountName: postgres-backup
      automountServiceAccountToken: false
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 70
        runAsGroup: 70
        fsGroup: 70
        seccompProfile: { type: RuntimeDefault }
        appArmorProfile: { type: Localhost, localhostProfile: k8s-chatbot }
      containers:
        - name: restore
          image: postgres:16-alpine
          command: ["/bin/sh", "-c"]
          args:
            - set -eu; cd /backups/$stamp; sha256sum -c SHA256SUMS;
              i=0; until pg_isready -q; do i=\$((i + 1)); [ \$i -lt 30 ] || exit 1; sleep 2; done;
              pg_restore --clean --if-exists --single-transaction --exit-on-error --dbname=chat_$env chat_$env.dump;
              echo "chat_$env restored from $stamp"
          env:
            - { name: PGHOST, value: postgres.data.svc.cluster.local }
            - { name: PGUSER, value: postgres }
            - name: PGPASSWORD
              valueFrom: { secretKeyRef: { name: postgres-secrets, key: POSTGRES_PASSWORD } }
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
          resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { cpu: 500m, memory: 256Mi } }
          volumeMounts: [{ name: backups, mountPath: /backups, readOnly: true }]
      volumes: [{ name: backups, persistentVolumeClaim: { claimName: postgres-backups } }]
YAML
    run_job "$name"
    ;;

  *)
    sed -n '2,13p' "$0"; exit 1 ;;
esac
