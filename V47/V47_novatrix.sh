#!/usr/bin/env bash
# =============================================================================
# Novatrix V47 - the WHOLE stack from code: deploys the five CloudFormation
# templates in templates/ in order. Nothing is clicked in the console.
#
#   templates/V47_01-network.yaml   VPC, subnets, routes, S3 endpoint, SGs (incl. ALB), NACL, flow logs
#   templates/V47_02-data.yaml      RDS MariaDB + EFS + secrets in Secrets Manager
#   templates/V47_03-security.yaml  IAM: service roles, instance profile, groups, policies, users
#   templates/V47_04-storage.yaml   S3 bucket (policy, lifecycle, trigger) + publisher Lambda
#   templates/V47_05-compute.yaml   launch template, ALB + target group, Auto Scaling group
#                                   (two AZs, target tracking, rolling updates), bastion
#
# Each layer exports its ids (<project>-<Key>) and the next layer imports them.
# Everything that varies (IP, names, sizes, CIDRs, scaling limits) is a
# parameter, set in V47_config.sh. Only two things are deliberately NOT in
# CloudFormation:
#   - the self-signed HTTPS certificate: CloudFormation can't import into ACM,
#     so it is created (openssl) and imported here - once, then reused
#   - emptying the VPC's default security group (CloudFormation can't manage it)
# The passwords ARE in CloudFormation now: Secrets Manager generates them.
#
# Requirements: AWS CLI v2 with admin credentials, existing key pair, openssl
#               (Git Bash has it), git (optional).
# Run:          ./V47_novatrix.sh           create / update everything (safe to re-run;
#                                           re-run if your IP changes)
#               ./V47_novatrix.sh --plan    show what WOULD change (change sets), change nothing
#               NEW_AMI=1 ./V47_novatrix.sh  roll all web servers over to the latest Amazon
#                                           Linux - one at a time, the site stays up
# Verify:       ./V47_verify.sh   [--failover] [--selfheal] [--load] [--all]
# Clean up:     ./V47_cleanup.sh
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
source ./V47_config.sh

PLAN=no
case "${1:-}" in
  --plan) PLAN=yes ;;
  "")     ;;
  *)      echo "Usage: $0 [--plan]" >&2; exit 2 ;;
esac

# ----- Helpers ---------------------------------------------------------------
step() { echo; echo "=== $* ==="; }

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
is_arn() { [[ "$1" == arn:* ]]; }

# =============================================================================
# 1. Which version of the code is being deployed
# =============================================================================
step "Version: what is being deployed"
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Commit: $(git log -1 --date=short --format='%h  %ad  %an  %s' 2>/dev/null || echo '(no commits yet)')"
  DIRTY=$(git status --porcelain -- templates "$CONTENT_DIR" V47_config.sh)
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
[[ -d "$CONTENT_DIR" ]] || { echo "Missing $CONTENT_DIR/ (the static site: index.html, style.css ...)" >&2; exit 1; }

# V45 kept network + RDS + EFS in the stack "<project>-natverk" and built the
# rest with the CLI. Its resources use the same names - remove V45 first.
V45_STACK="${PROJECT}-natverk"
if stack_exists "$V45_STACK"; then
  echo "The V45 stack $V45_STACK still exists." >&2
  echo "Run ./V45_cleanup.sh first, then this script again." >&2
  exit 1
fi
# V46 used the SAME five stack names, but with a single web server and the
# passwords in SSM Parameter Store. Updating it in place would change every
# password under a running WordPress - start from a clean account instead.
V46_FOUND=""
if stack_exists "$STACK_COMPUTE" && aws cloudformation describe-stack-resource --region "$REGION" \
     --stack-name "$STACK_COMPUTE" --logical-resource-id WebServer >/dev/null 2>&1; then
  V46_FOUND="the stack $STACK_COMPUTE has V46's single WebServer"
elif aws ssm get-parameter --region "$REGION" --name "/${PROJECT}/db/master-password" >/dev/null 2>&1; then
  V46_FOUND="V46's secrets are still in SSM Parameter Store (/${PROJECT}/...)"
fi
if [[ -n "$V46_FOUND" ]]; then
  echo "V46 is still deployed: $V46_FOUND." >&2
  echo "Run ./V46_cleanup.sh first (V47 creates everything again from the repo), then this script." >&2
  exit 1
fi

# Names CloudFormation must create: anything left over from earlier labs
# would make a stack fail halfway. Check up front, read-only.
must_be_free "S3 bucket"       "$SITE_BUCKET"   aws s3api head-bucket --bucket "$SITE_BUCKET"
must_be_free "RDS database"    "$DB_INSTANCE_ID" aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$DB_INSTANCE_ID"
must_be_free "DB subnet group" "${PROJECT}-db-subnets" aws rds describe-db-subnet-groups --region "$REGION" --db-subnet-group-name "${PROJECT}-db-subnets"
must_be_free "Lambda"          "$FUNCTION_NAME" aws lambda get-function --region "$REGION" --function-name "$FUNCTION_NAME"
must_be_free "log group"       "$LOG_GROUP"     log_group_exists "$LOG_GROUP"
must_be_free "log group"       "$FLOW_LOG_GROUP" log_group_exists "$FLOW_LOG_GROUP"
must_be_free "instance profile" "$EC2_PROFILE"  aws iam get-instance-profile --instance-profile-name "$EC2_PROFILE"
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
# Load balancer, target group, Auto Scaling group: CloudFormation knows them by
# ARN (ALB, TG) or name (ASG) - look the ARN up first.
a=$(aws elbv2 describe-load-balancers --region "$REGION" --names "$ALB_NAME" \
      --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)
is_arn "$a" && must_be_free "load balancer" "$a" true
a=$(aws elbv2 describe-target-groups --region "$REGION" --names "$TG_NAME" \
      --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)
is_arn "$a" && must_be_free "target group" "$a" true
n=$(aws autoscaling describe-auto-scaling-groups --region "$REGION" --auto-scaling-group-names "$ASG_NAME" \
      --query 'length(AutoScalingGroups)' --output text 2>/dev/null || echo 0)
[[ "$n" == 1 ]] && must_be_free "Auto Scaling group" "$ASG_NAME" true
# Secrets: CloudFormation's physical id is the ARN. A secret that is only
# SCHEDULED for deletion still blocks its name (7-30 days) - say how to free it.
for s in "${SECRET_NAMES[@]}"; do
  read -r a deleted <<<"$(aws secretsmanager describe-secret --region "$REGION" --secret-id "$s" \
                           --query '[ARN, DeletedDate]' --output text 2>/dev/null || true)"
  is_arn "${a:-}" || continue
  if [[ -n "${deleted:-}" && "$deleted" != None ]]; then
    echo "  secret $s is scheduled for deletion and blocks the name - free it with:" >&2
    echo "    aws secretsmanager delete-secret --region $REGION --secret-id $s --force-delete-without-recovery" >&2
    BLOCKERS=$((BLOCKERS + 1))
  else
    must_be_free "secret" "$a" true
  fi
done
if (( BLOCKERS > 0 )); then
  echo "$BLOCKERS resource(s) in the way - remove them (earlier labs: their cleanup script) and run again." >&2
  exit 1
fi
echo "No leftovers from earlier labs in the way."

MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')
[[ "$MY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Could not read your public IP." >&2; exit 1; }
echo "Admin access (SSH to the bastion) only from: ${MY_IP}/32"

# =============================================================================
# 3. HTTPS certificate for the load balancer (self-signed, no domain yet)
# =============================================================================
step "HTTPS certificate for the load balancer (ACM)"
CERT_ARN=$(cert_arn)
if [[ -n "$CERT_ARN" ]]; then
  echo "Certificate exists: $CERT_ARN ($CERT_DOMAIN)"
elif [[ "$PLAN" == yes ]]; then
  echo "  (no certificate - a real run creates a self-signed one for $CERT_DOMAIN)"
elif ! command -v openssl >/dev/null 2>&1; then
  echo "WARNING: openssl not found - the load balancer gets HTTP only (no HTTPS listener)."
else
  # The private key exists only for the import and is deleted right after.
  openssl req -x509 -nodes -newkey rsa:2048 -days 365 -subj "/CN=${CERT_DOMAIN}" \
    -addext "subjectAltName=DNS:${CERT_DOMAIN}" \
    -keyout "$WORK_DIR/alb.key" -out "$WORK_DIR/alb.crt" 2>"$WORK_DIR/openssl.log" \
    || { cat "$WORK_DIR/openssl.log" >&2; echo "openssl could not create the certificate." >&2; exit 1; }
  CERT_ARN=$(aws acm import-certificate --region "$REGION" \
    --certificate "fileb://$WORK_DIR/alb.crt" --private-key "fileb://$WORK_DIR/alb.key" \
    --tags "Key=${TAG_KEY},Value=${TAG_VALUE}" --query CertificateArn --output text)
  rm -f "$WORK_DIR/alb.key" "$WORK_DIR/alb.crt"
  echo "Certificate imported: $CERT_ARN (self-signed, valid 365 days)"
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
# 5. Layer 2: database + shared storage + secrets
# =============================================================================
step "Layer 2/5: data (RDS + EFS + Secrets Manager)"
stack_exists "$STACK_DATA" || [[ "$PLAN" == yes ]] || echo "The first time, RDS takes 5-15 minutes - the script waits."
deploy "$STACK_DATA" "${TEMPLATES[1]}" \
  ProjectName="$PROJECT" DbInstanceClass="$DB_INSTANCE_CLASS" DbAllocatedStorage="$DB_STORAGE_GB" \
  DbBackupRetentionDays="$DB_BACKUP_RETENTION_DAYS" DbMultiAz="$DB_MULTI_AZ" DbName="$DB_NAME" \
  DbMasterUsername="$DB_MASTER_USER" DbAppSecretName="$DB_APP_SECRET" WpAdminSecretName="$WP_ADMIN_SECRET" \
  WebRoleName="$EC2_ROLE"

# =============================================================================
# 6. Layer 3: IAM
# =============================================================================
step "Layer 3/5: security (IAM)"
deploy "$STACK_SECURITY" "${TEMPLATES[2]}" \
  ProjectName="$PROJECT" SiteBucket="$SITE_BUCKET" \
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
# 8. Layer 5: load balancer + Auto Scaling group + bastion
# =============================================================================
step "Layer 5/5: compute (ALB + Auto Scaling group + bastion)"
# The AMI is chosen ONCE and then kept: a routine re-deploy never replaces the
# servers behind your back. NEW_AMI=1 moves them to the latest Amazon Linux -
# a new launch template version, rolled out one server at a time while the
# load balancer keeps serving from the others (WordPress lives on EFS/RDS).
AMI_ARGS=()
if [[ "${NEW_AMI:-0}" == 1 ]] || ! stack_exists "$STACK_COMPUTE"; then
  AMI_ID=$(aws ssm get-parameter --region "$REGION" --name "$AMI_SSM_PATH" --query Parameter.Value --output text)
  AMI_ARGS=(AmiId="$AMI_ID")
  echo "AMI: $AMI_ID (latest Amazon Linux 2023)"
else
  echo "AMI: $(stack_output AmiId) (kept - NEW_AMI=1 to roll out a new one)"
fi
if [[ "$PLAN" == no ]]; then
  if stack_exists "$STACK_COMPUTE"; then
    echo "A changed launch template is rolled out one server at a time (a few minutes per server)."
  else
    echo "$ASG_MIN web servers start in two AZs; the first installs WordPress on EFS, the others"
    echo "wait for it. The stack waits for every server's signal (5-10 min)."
  fi
fi
deploy "$STACK_COMPUTE" "${TEMPLATES[4]}" \
  ProjectName="$PROJECT" "${AMI_ARGS[@]}" InstanceType="$INSTANCE_TYPE" KeyName="$KEY_NAME" \
  SyncInterval="$SYNC_INTERVAL" AsgMinSize="$ASG_MIN" AsgMaxSize="$ASG_MAX" \
  CpuTargetPercent="$CPU_TARGET" RequestsPerTargetPerMinute="$REQUESTS_PER_TARGET" \
  HealthCheckPath="$HEALTH_CHECK_PATH" CertificateArn="${CERT_ARN:-}" \
  DbName="$DB_NAME" DbAppUsername="$DB_APP_USER" \
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

ALB_DNS=$(stack_output AlbDnsName)
ASG=$(stack_output AsgName)
TG_ARN=$(stack_output WebTargetGroupArn)
BASTION_ID=$(stack_output BastionId)
BASTION_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$BASTION_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

step "Web servers (Auto Scaling group $ASG) and the load balancer's view of them"
IDS=$(aws autoscaling describe-auto-scaling-groups --region "$REGION" --auto-scaling-group-names "$ASG" \
        --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text)
printf '  %-20s %-12s %-14s %s\n' INSTANCE AZ "PRIVATE IP" "ALB HEALTH"
for id in $IDS; do
  read -r az ip <<<"$(aws ec2 describe-instances --region "$REGION" --instance-ids "$id" \
    --query 'Reservations[0].Instances[0].[Placement.AvailabilityZone, PrivateIpAddress]' --output text)"
  h=$(aws elbv2 describe-target-health --region "$REGION" --target-group-arn "$TG_ARN" \
        --targets Id="$id" --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text)
  printf '  %-20s %-12s %-14s %s\n' "$id" "$az" "$ip" "$h"
done
FIRST_PRIV=$(aws ec2 describe-instances --region "$REGION" --instance-ids $IDS \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

echo
echo "Done! WordPress runs on $(wc -w <<<"$IDS") servers in two AZs behind the load balancer."
echo "  WordPress:  http://$ALB_DNS"
[[ -n "${CERT_ARN:-}" ]] && echo "              https://$ALB_DNS  (self-signed certificate - the browser warns)"
echo "  Admin:      http://$ALB_DNS/wp-admin   user: $WP_ADMIN_USER"
echo "              password (copy into Git Bash):"
echo "              aws secretsmanager get-secret-value --region $REGION --secret-id $WP_ADMIN_SECRET --query SecretString --output text"
echo "  Static:     http://$ALB_DNS$STATIC_URL_PATH/   (from $CONTENT_DIR/ in the repo, published via S3)"
echo "  Bastion:    ssh -i $KEY_FILE ec2-user@$BASTION_IP"
echo "  A web server (only via the bastion; private IPs in the table above):"
echo "              ssh -i $KEY_FILE -o ProxyCommand=\"ssh -i $KEY_FILE -W %h:%p ec2-user@$BASTION_IP\" ec2-user@$FIRST_PRIV"
echo
echo "Change something: edit a template, ./V47_novatrix.sh --plan, commit, ./V47_novatrix.sh"
echo "Tip:      stop the bastion when you are not administering - nothing else needs it:"
echo "            aws ec2 stop-instances --instance-ids $BASTION_ID --region $REGION"
echo "Next:     ./V47_verify.sh          (stacks vs repo, drift, permissions, WordPress, backups, network, HA)"
echo "          ./V47_verify.sh --all    (also: kill a server, break a server, load test -> scaling)"
echo "Clean up: ./V47_cleanup.sh"
