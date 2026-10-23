#!/usr/bin/env bash
# =============================================================================
# Novatrix V43 - removes everything V43_novatrix-iam.sh created.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")"
source ./V43_config.sh

read -r -p "This deletes ALL Novatrix V43 resources in account $ACCOUNT_ID. Type JA: " answer
[[ "$answer" == "JA" ]] || { echo "Aborted."; exit 1; }

quiet() { "$@" >/dev/null 2>&1 || true; }

echo "EC2 instance + security group..."
IDS=$(aws ec2 describe-instances --region "$REGION" \
  --filters Name=tag:Name,Values="$INSTANCE_NAME" Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [[ -n "$IDS" ]]; then
  quiet aws ec2 terminate-instances --region "$REGION" --instance-ids $IDS
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids $IDS
fi
quiet aws ec2 delete-security-group --region "$REGION" --group-name "$SG_NAME"

echo "Lambda and log group..."
quiet aws lambda delete-function --region "$REGION" --function-name "$FUNCTION_NAME"
quiet aws logs delete-log-group --region "$REGION" --log-group-name "$LOG_GROUP"

echo "S3 bucket..."
quiet aws s3 rm "s3://$SITE_BUCKET" --recursive --region "$REGION"
quiet aws s3api delete-bucket --bucket "$SITE_BUCKET" --region "$REGION"

echo "Service roles..."
quiet aws iam remove-role-from-instance-profile --instance-profile-name "$EC2_PROFILE" --role-name "$EC2_ROLE"
quiet aws iam delete-instance-profile --instance-profile-name "$EC2_PROFILE"
quiet aws iam delete-role-policy --role-name "$EC2_ROLE" --policy-name novatrix-web-ec2-access
quiet aws iam delete-role --role-name "$EC2_ROLE"
quiet aws iam delete-role-policy --role-name "$UPLOADER_ROLE" --policy-name novatrix-uppladdare-access
quiet aws iam delete-role --role-name "$UPLOADER_ROLE"
quiet aws iam delete-role-policy --role-name "$LAMBDA_ROLE" --policy-name novatrix-publicerare-access
quiet aws iam delete-role --role-name "$LAMBDA_ROLE"

echo "Users..."
for entry in "${USERS[@]}"; do
  user=${entry%%:*}
  group=${entry##*:}
  quiet aws iam remove-user-from-group --user-name "$user" --group-name "$group"
  quiet aws iam delete-login-profile --user-name "$user"
  for key in $(aws iam list-access-keys --user-name "$user" \
                 --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null); do
    quiet aws iam delete-access-key --user-name "$user" --access-key-id "$key"
  done
  quiet aws iam delete-user --user-name "$user"
done

echo "Groups and policies..."
for pair in "$DRIFT_GROUP:novatrix-drift-policy" "$DEV_GROUP:novatrix-utveckling-policy" \
            "$MARKNAD_GROUP:novatrix-marknad-policy"; do
  group=${pair%%:*}
  arn="arn:aws:iam::${ACCOUNT_ID}:policy/${pair##*:}"
  quiet aws iam detach-group-policy --group-name "$group" --policy-arn "$arn"
  quiet aws iam delete-group --group-name "$group"
  for v in $(aws iam list-policy-versions --policy-arn "$arn" \
               --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text 2>/dev/null); do
    quiet aws iam delete-policy-version --policy-arn "$arn" --version-id "$v"
  done
  quiet aws iam delete-policy --policy-arn "$arn"
done

rm -rf "$WORK_DIR"
echo "Done."
