#!/usr/bin/env bash
# =============================================================================
# Novatrix V46 - the WHOLE stack from code: deploys the five CloudFormation
# templates in templates/ in order. Nothing is clicked in the console.
#
#   templates/01-network.yaml   VPC, subnets, routes, S3 endpoint, SG, NACL, flow logs
#   templates/02-data.yaml      RDS MariaDB + EFS (+ access point, mount targets)
#   templates/03-security.yaml  IAM: service roles, instance profile, groups, policies, users
#   templates/04-storage.yaml   S3 bucket (policy, lifecycle, trigger) + publisher Lambda
#   templates/05-compute.yaml   launch templates, web server (WordPress), bastion
#
# Each layer exports its ids (<namn>-<Key>) and the next layer imports them.
# Everything that varies (IP, names, sizes, CIDRs) is a parameter, set in
# V46_config.sh. Only two things are deliberately NOT in CloudFormation:
#   - the secrets (CloudFormation can't create SSM SecureStrings, and a password
#     must never be in a template or in Git) - created here, read by the stacks
#   - emptying the VPC's default security group (CloudFormation can't manage it)
#
# Requirements: AWS CLI v2 with admin credentials, existing key pair, git (optional).
# Run:          ./V46_novatrix.sh           create / update everything (safe to re-run;
#                                           re-run if your IP changes)
#               ./V46_novatrix.sh --plan    show what WOULD change (change sets), change nothing
#               NEW_AMI=1 ./V46_novatrix.sh  also move the servers to the latest Amazon Linux
# Verify:       ./V46_verify.sh
# Clean up:     ./V46_cleanup.sh
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
source ./V46_config.sh

PLAN=no
case "${1:-}" in
  --plan) PLAN=yes ;;
  "")     ;;
  *)      echo "Usage: $0 [--plan]" >&2; exit 2 ;;
esac

# ----- Helpers ---------------------------------------------------------------
step() { echo; echo "=== $* ==="; }

# 32 random letters/digits. Only [A-Za-z0-9]: valid for RDS (which forbids
# / @ " and spaces) and safe inside SQL and PHP strings.
random_password() {
  local pw
  pw=$(head -c 600 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-32)
  [[ ${#pw} -eq 32 ]] || { echo "Could not generate a password." >&2; exit 1; }
  echo "$pw"
}

# Create an SSM SecureString with a random password - only if it doesn't exist,
# so a re-run never changes a password the database already uses.
ensure_secret() {
  local name=$1 description=$2
  if aws ssm get-parameter --region "$REGION" --name "$name" >/dev/null 2>&1; then
    echo "Secret exists:  $name"
  else
    aws ssm put-parameter --region "$REGION" --name "$name" --type SecureString \
      --value "$(random_password)" --description "$description" \
      --tags "Key=${TAG_KEY},Value=${TAG_VALUE}" >/dev/null
    echo "Secret created: $name"
  fi
}

# deploy <stack> <template> Key=Value...
#   normal: create the stack, or apply ONLY the differences (a change set)
#   --plan: create the change set, print it, delete it - nothing changes.
#           "Replacement True" = that resource is deleted and recreated.
deploy() {
  local stack=$1 template=$2; shift 2
  local args=(--region "$REGION" --stack-name "$stack" --template-file "$template"
              --capabilities CAPABILITY_NAMED_IAM --no-fail-on-empty-changeset
              --parameter-overrides "$@" --tags "${TAG_KEY}=${TAG_VALUE}")
  echo "Stack $stack  <-  $template"
  if [[ "$PLAN" == no ]]; then
    aws cloudformation deploy "${args[@]}"
    load_outputs
    return
  fi
  if ! stack_exists "$stack"; then
    echo "  (does not exist - created with everything in it on a real run)"
    return
  fi
  local out arn
  out=$(aws cloudformation deploy "${args[@]}" --no-execute-changeset 2>&1) || { echo "$out" >&2; return 1; }
  arn=$(grep -oE 'arn:aws:cloudformation:[^ ]+:changeSet/[^ ]+' <<<"$out" | head -n 1 || true)
  if [[ -z "$arn" ]]; then
    echo "  No changes."
    return
  fi
  aws cloudformation describe-change-set --region "$REGION" --change-set-name "$arn" \
    --query 'Changes[].ResourceChange.[Action, LogicalResourceId, ResourceType, Replacement]' \
    --output table
  aws cloudformation delete-change-set --region "$REGION" --change-set-name "$arn"
}

# Which stack (if any) owns a resource? Empty = created outside CloudFormation.
owner_of() {
  local s
  s=$(aws cloudformation describe-stack-resources --region "$REGION" --physical-resource-id "$1" \
        --query 'StackResources[0].StackName' --output text 2>/dev/null) || s=""
  [[ "$s" == None ]] && s=""
  echo "$s"
}
BLOCKERS=0
must_be_free() {   # description physical-id command-that-succeeds-if-it-exists...
  local what=$1 id=$2; shift 2
  "$@" >/dev/null 2>&1 || return 0          # doesn't exist: fine
  [[ -n "$(owner_of "$id")" ]] && return 0  # exists, but belongs to a stack (ours): fine
  echo "  already exists, created outside CloudFormation: $what $id" >&2
  BLOCKERS=$((BLOCKERS + 1))
}
log_group_exists() {
  [[ "$(aws logs describe-log-groups --region "$REGION" --log-group-name-prefix "$1" \
          --query "logGroups[?logGroupName=='$1'] | [0].logGroupName" --output text)" == "$1" ]]
}

# =============================================================================
# 1. Which version of the code is being deployed
# =============================================================================
step "Version: what is being deployed"
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Commit: $(git log -1 --date=short --format='%h  %ad  %an  %s' 2>/dev/null || echo '(no commits yet)')"
  DIRTY=$(git status --porcelain -- templates "$CONTENT_DIR" V46_config.sh)
  if [[ -n "$DIRTY" ]]; then
    echo "NOTE: uncommitted changes - what is deployed is not in the history yet:"
    sed 's/^/    /' <<<"$DIRTY"
  else
    echo "Working tree is clean: AWS gets exactly what is in this commit."
  fi
else
  echo "(not a Git repo - put the folder in the course repo to get version history)"
fi
[[ "$PLAN" == yes ]] && echo "PLAN mode: shows the changes, changes nothing."

# =============================================================================
# 2. Pre-checks
# =============================================================================
step "Pre-checks"
for t in "${TEMPLATES[@]}"; do
  [[ -f "$t" ]] || { echo "Missing $t" >&2; exit 1; }
  (( $(wc -c < "$t") <= 51200 )) || { echo "$t is larger than 51,200 bytes (the limit without S3)" >&2; exit 1; }
  aws cloudformation validate-template --region "$REGION" --template-body "file://$t" >/dev/null
  echo "Valid template: $t"
done

# V45 kept network + RDS + EFS in the stack "<project>-natverk" and built the
# rest with the CLI. Its resources use the same names as V46 - remove V45 first.
V45_STACK="${PROJECT}-natverk"
if stack_exists "$V45_STACK"; then
  echo "The V45 stack $V45_STACK still exists." >&2
  echo "Run ./V45_cleanup.sh first, then this script again." >&2
  exit 1
fi

# Names CloudFormation must create: anything left over from the CLI-built V45
# would make a stack fail halfway. Check up front, read-only.
must_be_free "S3 bucket"       "$SITE_BUCKET"   aws s3api head-bucket --bucket "$SITE_BUCKET"
must_be_free "RDS database"     "$DB_INSTANCE_ID" aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$DB_INSTANCE_ID"
must_be_free "DB subnet group" "${PROJECT}-db-subnets" aws rds describe-db-subnet-groups --region "$REGION" --db-subnet-group-name "${PROJECT}-db-subnets"
must_be_free "Lambda"          "$FUNCTION_NAME" aws lambda get-function --region "$REGION" --function-name "$FUNCTION_NAME"
must_be_free "log group"       "$LOG_GROUP"     log_group_exists "$LOG_GROUP"
must_be_free "log group"       "$FLOW_LOG_GROUP" log_group_exists "$FLOW_LOG_GROUP"
must_be_free "instance profile"   "$EC2_PROFILE"   aws iam get-instance-profile --instance-profile-name "$EC2_PROFILE"
for r in "$EC2_ROLE" "$UPLOADER_ROLE" "$LAMBDA_ROLE" "$FLOW_LOG_ROLE"; do
  must_be_free "IAM role" "$r" aws iam get-role --role-name "$r"
done
for g in "$OPS_GROUP" "$DEV_GROUP" "$MARKETING_GROUP"; do
  must_be_free "IAM group" "$g" aws iam get-group --group-name "$g"
done
for p in operations development marketing; do
  arn="arn:aws:iam::${ACCOUNT_ID}:policy/${PROJECT}-${p}-policy"
  must_be_free "IAM policy" "$arn" aws iam get-policy --policy-arn "$arn"
done
for entry in "${USERS[@]}"; do
  must_be_free "IAM user" "${entry%%:*}" aws iam get-user --user-name "${entry%%:*}"
done
if (( BLOCKERS > 0 )); then
  echo "$BLOCKERS resource(s) in the way - remove them (V45: ./V45_cleanup.sh) and run again." >&2
  exit 1
fi
echo "No leftovers from earlier labs in the way."

MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')
[[ "$MY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Could not read your public IP." >&2; exit 1; }
echo "Admin access (SSH to the bastion) only from: ${MY_IP}/32"

# =============================================================================
# 3. Secrets - the only values that never touch a template or the repo
# =============================================================================
if [[ "$PLAN" == no ]]; then
  step "Secrets in SSM Parameter Store (SecureString)"
  ensure_secret "$DB_MASTER_PW_PARAM" "${PROJECT} RDS master password (only used to create the WordPress DB user)"
  ensure_secret "$DB_APP_PW_PARAM"    "${PROJECT} WordPress database user password"
  ensure_secret "$WP_ADMIN_PW_PARAM"  "${PROJECT} WordPress admin password"
fi

# =============================================================================
# 4. Layer 1: network
# =============================================================================
step "Layer 1/5: network"
deploy "$STACK_NETWORK" "${TEMPLATES[0]}" \
  ProjectName="$PROJECT" AdminCidr="${MY_IP}/32" SiteBucket="$SITE_BUCKET" DbPort="$DB_PORT" \
  VpcCidr="$VPC_CIDR" MgmtACidr="$MGMT_A_CIDR" WebACidr="$WEB_A_CIDR" WebBCidr="$WEB_B_CIDR" \
  WebTierCidr="$WEB_TIER_CIDR" DataACidr="$DATA_A_CIDR" DataBCidr="$DATA_B_CIDR" \
  DataTierCidr="$DATA_TIER_CIDR"

if [[ "$PLAN" == no ]]; then
  # Every VPC gets a "default" security group that lets its members talk to
  # each other freely. CloudFormation can't manage it, so empty it here:
  # anything launched by mistake without our groups gets no access at all.
  DEFAULT_SG=$(stack_output DefaultSecurityGroupId)
  default_sg_rules() {   # false = inbound rules, true = outbound rules
    aws ec2 describe-security-group-rules --region "$REGION" \
      --filters Name=group-id,Values="$DEFAULT_SG" \
      --query "SecurityGroupRules[?IsEgress==\`$1\`].SecurityGroupRuleId" --output text
  }
  IN_RULES=$(default_sg_rules false)
  OUT_RULES=$(default_sg_rules true)
  [[ -n "$IN_RULES" ]] && aws ec2 revoke-security-group-ingress --region "$REGION" --group-id "$DEFAULT_SG" \
    --security-group-rule-ids $IN_RULES >/dev/null
  [[ -n "$OUT_RULES" ]] && aws ec2 revoke-security-group-egress --region "$REGION" --group-id "$DEFAULT_SG" \
    --security-group-rule-ids $OUT_RULES >/dev/null
  echo "Default security group $DEFAULT_SG emptied (no rules in, no rules out)"
fi

# =============================================================================
# 5. Layer 2: database + shared storage
# =============================================================================
step "Layer 2/5: data (RDS + EFS)"
stack_exists "$STACK_DATA" || [[ "$PLAN" == yes ]] || echo "The first time, RDS takes 5-15 minutes - the script waits."
deploy "$STACK_DATA" "${TEMPLATES[1]}" \
  ProjectName="$PROJECT" DbInstanceClass="$DB_INSTANCE_CLASS" DbAllocatedStorage="$DB_STORAGE_GB" \
  DbBackupRetentionDays="$DB_BACKUP_RETENTION_DAYS" DbName="$DB_NAME" \
  DbMasterUsername="$DB_MASTER_USER" DbMasterPasswordParam="$DB_MASTER_PW_PARAM" \
  WebRoleName="$EC2_ROLE"

# =============================================================================
# 6. Layer 3: IAM
# =============================================================================
step "Layer 3/5: security (IAM)"
deploy "$STACK_SECURITY" "${TEMPLATES[2]}" \
  ProjectName="$PROJECT" SiteBucket="$SITE_BUCKET" \
  DbMasterPasswordParam="$DB_MASTER_PW_PARAM" DbAppPasswordParam="$DB_APP_PW_PARAM" \
  WpAdminPasswordParam="$WP_ADMIN_PW_PARAM" \
  OpsUserName="${USERS[0]%%:*}" DevUserName="${USERS[1]%%:*}" MarketingUserName="${USERS[2]%%:*}"

# =============================================================================
# 7. Layer 4: S3 + publisher, then the static content (from the repo)
# =============================================================================
step "Layer 4/5: storage (S3 + publisher)"
deploy "$STACK_STORAGE" "${TEMPLATES[3]}" \
  ProjectName="$PROJECT" SiteBucket="$SITE_BUCKET" \
  BackupRetentionDays="$BACKUP_RETENTION_DAYS" LogRetentionDays="$LOG_RETENTION_DAYS"

if [[ "$PLAN" == no ]]; then
  step "Static content: $CONTENT_DIR/ -> s3://$SITE_BUCKET/drafts/ -> (Lambda) -> web/"
  # sync uploads only new/changed files; each upload triggers the publisher.
  aws s3 sync "$CONTENT_DIR/" "s3://${SITE_BUCKET}/drafts/" --region "$REGION" --only-show-errors
  PUBLISHED=no
  for i in $(seq 1 24); do
    if aws s3api head-object --bucket "$SITE_BUCKET" --key web/index.html --region "$REGION" >/dev/null 2>&1; then
      PUBLISHED=yes; break
    fi
    sleep 5
  done
  [[ "$PUBLISHED" == yes ]] && echo "Published: web/index.html" \
    || echo "WARNING: web/index.html not published yet - check: aws logs tail $LOG_GROUP --region $REGION"
fi

# =============================================================================
# 8. Layer 5: servers
# =============================================================================
step "Layer 5/5: compute (web server + bastion)"
# The AMI is chosen ONCE and then kept: a routine re-deploy never replaces the
# servers behind your back. NEW_AMI=1 moves them to the latest Amazon Linux
# (the web server is replaced - WordPress lives on EFS/RDS, so nothing is lost).
AMI_ARGS=()
if [[ "${NEW_AMI:-0}" == 1 ]] || ! stack_exists "$STACK_COMPUTE"; then
  AMI_ID=$(aws ssm get-parameter --region "$REGION" --name "$AMI_SSM_PATH" --query Parameter.Value --output text)
  AMI_ARGS=(AmiId="$AMI_ID")
  echo "AMI: $AMI_ID (latest Amazon Linux 2023)"
else
  echo "AMI: $(stack_output AmiId) (kept - NEW_AMI=1 to update)"
fi
[[ "$PLAN" == no ]] && ! stack_exists "$STACK_COMPUTE" \
  && echo "The web server installs WordPress at first boot - the stack waits for its signal (3-6 min)."
deploy "$STACK_COMPUTE" "${TEMPLATES[4]}" \
  ProjectName="$PROJECT" "${AMI_ARGS[@]}" InstanceType="$INSTANCE_TYPE" KeyName="$KEY_NAME" \
  SyncInterval="$SYNC_INTERVAL" DbName="$DB_NAME" DbMasterUsername="$DB_MASTER_USER" \
  DbAppUsername="$DB_APP_USER" DbMasterPasswordParam="$DB_MASTER_PW_PARAM" \
  DbAppPasswordParam="$DB_APP_PW_PARAM" WpAdminPasswordParam="$WP_ADMIN_PW_PARAM" \
  WpTitle="$WP_TITLE" WpAdminUser="$WP_ADMIN_USER" WpAdminEmail="$WP_ADMIN_EMAIL" WpLocale="$WP_LOCALE"

if [[ "$PLAN" == yes ]]; then
  echo
  echo "Plan done - nothing was changed. Run without --plan to apply."
  exit 0
fi

# =============================================================================
# 9. Summary
# =============================================================================
step "The stacks"
for s in "${STACKS[@]}"; do
  printf '  %-20s %s\n' "$s" "$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$s" \
                                 --query 'Stacks[0].StackStatus' --output text)"
done

INSTANCE_ID=$(stack_output WebServerId)
BASTION_ID=$(stack_output BastionId)
read -r PUBLIC_IP PRIVATE_IP < <(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].[PublicIpAddress,PrivateIpAddress]' --output text)
BASTION_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$BASTION_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

echo
echo "Done! WordPress is installed (the web server signalled CloudFormation)."
echo "  WordPress:  http://$PUBLIC_IP   and   https://$PUBLIC_IP  (self-signed certificate)"
echo "  Admin:      http://$PUBLIC_IP/wp-admin   user: $WP_ADMIN_USER"
echo "              password (copy into Git Bash):"
echo "              MSYS_NO_PATHCONV=1 aws ssm get-parameter --region $REGION --name $WP_ADMIN_PW_PARAM --with-decryption --query Parameter.Value --output text"
echo "  Static:     http://$PUBLIC_IP$STATIC_URL_PATH/   (from $CONTENT_DIR/ in the repo, published via S3)"
echo "  Bastion:    ssh -i $KEY_FILE ec2-user@$BASTION_IP"
echo "  Web (only via the bastion):"
echo "              ssh -i $KEY_FILE -o ProxyCommand=\"ssh -i $KEY_FILE -W %h:%p ec2-user@$BASTION_IP\" ec2-user@$PRIVATE_IP"
echo
echo "Change something: edit a template, ./V46_novatrix.sh --plan, commit, ./V46_novatrix.sh"
echo "Tip:      stop the bastion when you are not administering - nothing else needs it:"
echo "            aws ec2 stop-instances --instance-ids $BASTION_ID --region $REGION"
echo "Next:     ./V46_verify.sh     (stacks vs repo, drift, permissions, WordPress, backups, network)"
echo "Clean up: ./V46_cleanup.sh"
