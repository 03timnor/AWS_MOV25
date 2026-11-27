#!/usr/bin/env bash
# =============================================================================
# Novatrix V48 - removes everything V48_novatrix.sh created: the six stacks
# (in REVERSE order - CloudFormation refuses to delete a layer whose exports
# another layer still imports), the secrets, and the self-signed certificate.
#
# NOTE: the database, its automated backups, the EFS file system and the S3
# backups are deleted too - nothing is kept (and nothing keeps costing money).
# Deleting the compute stack also deletes the load balancer and terminates
# EVERY web server in the Auto Scaling group (also ones it scaled out itself).
# Monitoring: the alarms, the alarm mails (the SNS subscription), the site
# check, the dashboard and ALL CloudWatch log groups go too. Metrics can't be
# deleted - CloudWatch drops them by itself (no cost once nothing is sent).
# The repo is untouched: ./V48_novatrix.sh recreates the whole stack from it.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")"
source ./V48_config.sh

read -r -p "This deletes ALL ${PROJECT} V48 resources (incl. the database and all backups) in account $ACCOUNT_ID. Type JA: " answer
[[ "$answer" == "JA" ]] || { echo "Aborted."; exit 1; }

quiet() { "$@" >/dev/null 2>&1 || true; }
FAILED=0

delete_stack() {   # stack
  local s=$1
  if ! stack_exists "$s"; then
    echo "  $s: does not exist"
    return
  fi
  aws cloudformation delete-stack --region "$REGION" --stack-name "$s"
  if aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$s"; then
    echo "  $s: deleted"
  else
    echo "  WARNING: $s could not be deleted - see its Events tab in the CloudFormation console."
    aws cloudformation describe-stack-events --region "$REGION" --stack-name "$s" \
      --query "StackEvents[?ResourceStatus=='DELETE_FAILED'] | [:3].[LogicalResourceId, ResourceStatusReason]" \
      --output text 2>/dev/null | sed 's/^/      /'
    FAILED=$((FAILED + 1))
  fi
}

# The certificate is in use by the HTTPS listener until the compute stack is
# gone, and ELB lets go of it a little after that - retry for a minute.
delete_certificate() {
  local arn i
  arn=$(cert_arn)
  [[ -z "$arn" ]] && { echo "  no certificate for $CERT_DOMAIN"; return; }
  for i in $(seq 1 12); do
    if aws acm delete-certificate --region "$REGION" --certificate-arn "$arn" >/dev/null 2>&1; then
      echo "  certificate $CERT_DOMAIN deleted"
      return
    fi
    sleep 5
  done
  echo "  WARNING: certificate $arn still in use - delete it later in the ACM console."
  FAILED=$((FAILED + 1))
}

# First: nothing may import from the compute layer any more - and no alarm
# should mail about servers that are being removed on purpose.
echo "Layer 6: monitoring (alarms, SNS e-mail, site check, dashboard)..."
delete_stack "$STACK_MONITORING"

echo "Layer 5: compute (load balancer, Auto Scaling group with all web servers, bastion, web log groups)..."
delete_stack "$STACK_COMPUTE"

echo "HTTPS certificate (ACM, imported by the deploy script)..."
if stack_exists "$STACK_COMPUTE"; then
  echo "  kept - the compute stack (and its HTTPS listener) still exists"
else
  delete_certificate
fi

# CloudFormation can't delete a bucket that still holds objects. The servers
# are gone now, so nothing writes new logs or backups while we empty it.
echo "Layer 4: storage - emptying the bucket first (static content, logs, backups)..."
quiet aws s3 rm "s3://$SITE_BUCKET" --recursive --region "$REGION"
delete_stack "$STACK_STORAGE"

# CloudFormation can't delete an IAM user that has things it didn't create
# (a console password or access keys added by hand for testing).
echo "Layer 3: security (IAM) - first removing passwords/keys added by hand..."
for entry in "${USERS[@]}"; do
  user=${entry%%:*}
  quiet aws iam delete-login-profile --user-name "$user"
  for key in $(aws iam list-access-keys --user-name "$user" \
                 --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null); do
    quiet aws iam delete-access-key --user-name "$user" --access-key-id "$key"
  done
done
delete_stack "$STACK_SECURITY"

# Deleting the database also deletes the master password secret RDS manages.
echo "Layer 2: data (RDS + EFS + secrets) - RDS takes 5-10 minutes..."
delete_stack "$STACK_DATA"

echo "Layer 1: network..."
delete_stack "$STACK_NETWORK"

# CloudFormation deletes its secrets without a recovery window. If the data
# stack was deleted some other way, a secret may be left SCHEDULED for deletion
# (7-30 days) - and would block its name at the next deploy. Delete for good.
echo "Secrets in Secrets Manager (anything left over, also if scheduled for deletion)..."
if stack_exists "$STACK_DATA"; then
  echo "  kept - the data stack still exists"
else
  for s in "${SECRET_NAMES[@]}"; do
    quiet aws secretsmanager delete-secret --region "$REGION" --secret-id "$s" --force-delete-without-recovery
  done
  echo "  done"
fi

# The stacks own every log group - but a service can recreate one while it is
# being deleted (RDS writes a last line when the database stops, the agent on
# a terminating server flushes its buffer). Delete such leftovers too.
echo "CloudWatch log groups left behind (if any)..."
for g in "${WEB_LOG_GROUPS[@]/#/$WEB_LOG_PREFIX/}" "$SITE_CHECK_LOG_GROUP" "$DB_LOG_GROUP" "$LOG_GROUP"; do
  if [[ "$(aws logs describe-log-groups --region "$REGION" --log-group-name-prefix "$g" \
           --query "logGroups[?logGroupName=='$g'] | [0].logGroupName" --output text 2>/dev/null)" == "$g" ]]; then
    if (( FAILED > 0 )); then
      echo "  kept $g - a stack that may own it was not deleted (see above)"
    else
      quiet aws logs delete-log-group --region "$REGION" --log-group-name "$g"
      echo "  deleted $g"
    fi
  fi
done

rm -rf -- "${WORK_DIR:?}"
if (( FAILED > 0 )); then
  echo "Done, but $FAILED item(s) remain - fix the cause above and run the script again."
  exit 1
fi
echo "Done. Recreate everything from the repo with: ./V48_novatrix.sh"
