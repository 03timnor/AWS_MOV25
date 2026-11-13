#!/usr/bin/env bash
# =============================================================================
# Novatrix V46 - removes everything V46_novatrix.sh created: the five stacks
# (in REVERSE order - CloudFormation refuses to delete a layer whose exports
# another layer still imports) and the secrets in SSM.
#
# NOTE: the database, its automated backups, the EFS file system and the S3
# backups are deleted too - nothing is kept (and nothing keeps costing money).
# The repo is untouched: ./V46_novatrix.sh recreates the whole stack from it.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")"
source ./V46_config.sh

read -r -p "This deletes ALL ${PROJECT} V46 resources (incl. the database and all backups) in account $ACCOUNT_ID. Type JA: " answer
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

echo "Layer 5: compute (web server + bastion)..."
delete_stack "$STACK_COMPUTE"

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

echo "Layer 2: data (RDS + EFS) - RDS takes 5-10 minutes..."
delete_stack "$STACK_DATA"

echo "Layer 1: network..."
delete_stack "$STACK_NETWORK"

echo "Secrets in SSM Parameter Store..."
for p in "${SECRET_PARAMS[@]}"; do
  quiet aws ssm delete-parameter --region "$REGION" --name "$p"
done

rm -rf "$WORK_DIR"
if (( FAILED > 0 )); then
  echo "Done, but $FAILED stack(s) remain - fix the cause above and run the script again."
  exit 1
fi
echo "Done. Recreate everything from the repo with: ./V46_novatrix.sh"
