#!/usr/bin/env bash
# =============================================================================
# Novatrix V45 - WordPress on RDS + EFS + S3 (builds on V44's network and V43's IAM).
#
# NEW IN V45 - added to the same CloudFormation stack (V45_infra.yaml):
#
#   RDS MariaDB     db.t4g.micro, 20 GiB gp2, encrypted, Single-AZ, private
#                   subnet data-a, NO public access, automated backup 1 day
#   EFS             encrypted shared storage for the WordPress files, mount
#                   targets in the private data tier, TLS + IAM + access point
#   Firewalls       db-sg / efs-sg accept ONLY web-sg; NACLs for 3306 and 2049
#
#   And in this script:
#   Secrets         DB and WordPress passwords generated here, kept in SSM
#                   Parameter Store (SecureString) - never in files or the repo
#   S3              backup/ prefix: daily DB dump + wp-content, lifecycle rule
#                   deletes backups after 14 days. web/ = static content,
#                   served under /statiskt/
#   Web server      WordPress (PHP-FPM) on EFS, own DB user that only reaches
#                   the wordpress database, installed with WP-CLI
#
# FROM V43/V44 (unchanged) - bastion as the only SSH entry, IAM groups/users,
# the publishing chain utkast/ -> Lambda -> web/, role chaining reader ->
# uploader, S3 only via the VPC endpoint, flow logs.
#
# Requirements: AWS CLI v2 with admin credentials, existing key pair, zip OR
#               python OR powershell (to package the Lambda).
# Run:          ./V45_novatrix.sh       (safe to re-run; re-run if your IP changes)
# Verify:       ./V45_verify.sh
# Clean up:     ./V45_cleanup.sh
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
source ./V45_config.sh

TAGS_IAM="Key=${TAG_KEY},Value=${TAG_VALUE}"

# ----- Helpers ---------------------------------------------------------------
step() { echo; echo "=== $* ==="; }

# Retry a command while IAM changes propagate (IAM is eventually consistent).
retry() {
  local n
  for n in $(seq 1 12); do
    if "$@" 2>"$WORK_DIR/retry.err"; then return 0; fi
    echo "  ...waiting for IAM to propagate ($n/12)" >&2
    sleep 5
  done
  cat "$WORK_DIR/retry.err" >&2
  return 1
}

# Create a customer managed policy, or publish a new default version if it exists.
ensure_policy() {
  local name=$1 doc=$2
  local arn="arn:aws:iam::${ACCOUNT_ID}:policy/${name}"
  if aws iam get-policy --policy-arn "$arn" >/dev/null 2>&1; then
    local v
    for v in $(aws iam list-policy-versions --policy-arn "$arn" \
                 --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text); do
      aws iam delete-policy-version --policy-arn "$arn" --version-id "$v"
    done
    aws iam create-policy-version --policy-arn "$arn" --policy-document "$doc" \
      --set-as-default >/dev/null
  else
    aws iam create-policy --policy-name "$name" --policy-document "$doc" \
      --tags "$TAGS_IAM" >/dev/null
  fi
  echo "$arn"
}

# Create a role, or refresh its trust policy if it exists.
ensure_role() {
  local name=$1 trust=$2 description=$3
  if aws iam get-role --role-name "$name" >/dev/null 2>&1; then
    aws iam update-assume-role-policy --role-name "$name" --policy-document "$trust"
  else
    aws iam create-role --role-name "$name" --assume-role-policy-document "$trust" \
      --description "$description" --tags "$TAGS_IAM" >/dev/null
  fi
}

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
      --tags "$TAGS_IAM" >/dev/null
    echo "Secret created: $name"
  fi
}

# Package the Lambda with whatever zip tool exists (Git Bash usually lacks zip).
make_lambda_zip() {
  rm -f "$WORK_DIR/lambda.zip"
  if command -v zip >/dev/null 2>&1; then
    (cd "$WORK_DIR" && zip -q lambda.zip lambda_function.py)
    return
  fi
  local py
  for py in python3 python; do
    if command -v "$py" >/dev/null 2>&1 && "$py" -c "import zipfile" >/dev/null 2>&1; then
      (cd "$WORK_DIR" && "$py" -c "import zipfile; z=zipfile.ZipFile('lambda.zip','w'); z.write('lambda_function.py'); z.close()")
      return
    fi
  done
  if command -v powershell.exe >/dev/null 2>&1; then
    (cd "$WORK_DIR" && powershell.exe -NoProfile -Command \
      "Compress-Archive -Force -Path lambda_function.py -DestinationPath lambda.zip")
    return
  fi
  echo "Found no zip, python or powershell to package the Lambda." >&2
  exit 1
}

# =============================================================================
# 1. Policy documents that don't depend on the stack
# =============================================================================

# ----- Trust policies: WHO may assume each service role ----------------------
EC2_TRUST=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
JSON
)

LAMBDA_TRUST=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "lambda.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
JSON
)

# Uploader trust: ONLY a session running with the EC2 reader role may assume it.
# Not the EC2 service, not users, not even administrators.
UPLOADER_TRUST=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "EndastLasarrollen",
    "Effect": "Allow",
    "Principal": { "AWS": "${EC2_ROLE_ARN}" },
    "Action": "sts:AssumeRole"
  }]
}
JSON
)

# Uploader: write-only, and only to the log archive and the backup prefix.
# Cannot read, list or delete anything - a hacked web server can add a backup
# but never read or destroy the old ones.
UPLOADER_ROLE_POLICY=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "LaddaUppLoggarOchBackup",
    "Effect": "Allow",
    "Action": "s3:PutObject",
    "Resource": ["${BUCKET_ARN}/loggar/*", "${BUCKET_ARN}/backup/*"]
  }]
}
JSON
)

# Lambda: read drafts, write published files, log to its own log group. Nothing else.
LAMBDA_ROLE_POLICY=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "LasUtkast",
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "${BUCKET_ARN}/utkast/*"
    },
    {
      "Sid": "Publicera",
      "Effect": "Allow",
      "Action": "s3:PutObject",
      "Resource": "${BUCKET_ARN}/web/*"
    },
    {
      "Sid": "SkrivEgnaLoggar",
      "Effect": "Allow",
      "Action": ["logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "${LOG_GROUP_ARN}:*"
    }
  ]
}
JSON
)

# ----- Group policies: humans --------------------------------------------------
# Drift: operate the Novatrix servers, read logs/metrics/network/database/EFS
# setup and download backups (to restore). No content, no code, no network or
# database changes, no secrets.
DRIFT_POLICY=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "OversiktUtanResursniva",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances", "ec2:DescribeInstanceStatus", "ec2:DescribeSecurityGroups",
        "ec2:DescribeSecurityGroupRules", "ec2:DescribeNetworkAcls", "ec2:DescribeVpcs",
        "ec2:DescribeSubnets", "ec2:DescribeRouteTables", "ec2:DescribeVpcEndpoints",
        "ec2:DescribeFlowLogs",
        "rds:DescribeDBInstances", "rds:DescribeDBSnapshots", "rds:DescribeDBSubnetGroups",
        "elasticfilesystem:DescribeFileSystems", "elasticfilesystem:DescribeMountTargets",
        "elasticfilesystem:DescribeAccessPoints",
        "cloudwatch:GetMetricData", "cloudwatch:GetMetricStatistics", "cloudwatch:ListMetrics",
        "logs:DescribeLogGroups"
      ],
      "Resource": "*"
    },
    {
      "Sid": "LasFlodesloggar",
      "Effect": "Allow",
      "Action": ["logs:DescribeLogStreams", "logs:GetLogEvents", "logs:FilterLogEvents"],
      "Resource": "${FLOW_LOG_GROUP_ARN}:*"
    },
    {
      "Sid": "StyrEndastNovatrixInstanser",
      "Effect": "Allow",
      "Action": ["ec2:StartInstances", "ec2:StopInstances", "ec2:RebootInstances"],
      "Resource": "arn:aws:ec2:${REGION}:${ACCOUNT_ID}:instance/*",
      "Condition": { "StringEquals": { "aws:ResourceTag/${TAG_KEY}": "${TAG_VALUE}" } }
    },
    {
      "Sid": "LasPubliceringsloggar",
      "Effect": "Allow",
      "Action": ["logs:DescribeLogStreams", "logs:GetLogEvents", "logs:FilterLogEvents"],
      "Resource": "${LOG_GROUP_ARN}:*"
    },
    {
      "Sid": "ListaLoggarOchBackuper",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "${BUCKET_ARN}",
      "Condition": { "StringLike": { "s3:prefix": ["loggar/*", "backup/*"] } }
    },
    {
      "Sid": "LasLoggarOchBackuper",
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": ["${BUCKET_ARN}/loggar/*", "${BUCKET_ARN}/backup/*"]
    }
  ]
}
JSON
)

# Utveckling: upload any draft, read the published site, deploy publisher code.
# Can NOT write web/ directly - everything goes through the publisher's checks.
DEV_POLICY=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListaSajten",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "${BUCKET_ARN}",
      "Condition": { "StringLike": { "s3:prefix": ["utkast/*", "web/*"] } }
    },
    {
      "Sid": "HanteraUtkast",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "${BUCKET_ARN}/utkast/*"
    },
    {
      "Sid": "LasPubliceradSajt",
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "${BUCKET_ARN}/web/*"
    },
    {
      "Sid": "DriftsattPublicerarkod",
      "Effect": "Allow",
      "Action": ["lambda:GetFunction", "lambda:UpdateFunctionCode"],
      "Resource": "${FUNCTION_ARN}"
    },
    {
      "Sid": "LasPubliceringsloggar",
      "Effect": "Allow",
      "Action": ["logs:DescribeLogStreams", "logs:GetLogEvents", "logs:FilterLogEvents"],
      "Resource": "${LOG_GROUP_ARN}:*"
    },
    {
      "Sid": "ListaLoggrupper",
      "Effect": "Allow",
      "Action": "logs:DescribeLogGroups",
      "Resource": "*"
    }
  ]
}
JSON
)

# Marknad: upload images to utkast/bilder/ only. Cannot delete, cannot touch pages.
MARKNAD_POLICY=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListaEgnaBilder",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "${BUCKET_ARN}",
      "Condition": { "StringLike": { "s3:prefix": ["utkast/bilder/*"] } }
    },
    {
      "Sid": "LaddaUppBilder",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject"],
      "Resource": "${BUCKET_ARN}/utkast/bilder/*"
    }
  ]
}
JSON
)

# =============================================================================
# 2. Pre-checks and secrets
# =============================================================================
step "Pre-checks"
# The web server must be a V45 server (WordPress on EFS). An older one (V43 in
# the default VPC, V44 serving the static site) would be mistaken for ours.
# Web servers are stateless - content lives in S3, EFS and RDS - so replacing
# one loses nothing.
OLD=$(aws ec2 describe-instances --region "$REGION" \
  --filters Name=tag:Name,Values="$INSTANCE_NAME" Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query "Reservations[].Instances[].[InstanceId, Tags[?Key=='Version'].Value | [0]]" --output text)
while read -r old_id old_version; do
  [[ -z "${old_id:-}" || "$old_version" == "$VERSION_TAG" ]] && continue
  echo "Found an older web server $old_id (not a $VERSION_TAG WordPress server)." >&2
  echo "Terminate it first, then run this script again:" >&2
  echo "  aws ec2 terminate-instances --region $REGION --instance-ids $old_id" >&2
  echo "(a V43 server in the default VPC: ./V43_cleanup.sh)" >&2
  exit 1
done <<<"$OLD"
echo "No older web server in the way."

MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')
[[ "$MY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Could not read your public IP." >&2; exit 1; }
echo "Admin access (SSH to the bastion) only from: ${MY_IP}/32"

step "Secrets in SSM Parameter Store (SecureString)"
ensure_secret "$DB_MASTER_PW_PARAM" "Novatrix RDS master password (only used to create the WordPress DB user)"
ensure_secret "$DB_APP_PW_PARAM"    "Novatrix WordPress database user password"
ensure_secret "$WP_ADMIN_PW_PARAM"  "Novatrix WordPress admin password"

# =============================================================================
# 3. Network, database and shared storage - V45_infra.yaml (infrastructure as code)
# =============================================================================
step "Infrastructure: network + RDS + EFS ($STACK_NAME)"
echo "The first time, RDS takes 5-15 minutes to create - the script waits."

# deploy = create the stack the first time, apply only the differences later.
# Re-running with a new IP updates the bastion's security group AND NACL.
aws cloudformation deploy --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --template-file "$INFRA_TEMPLATE" \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
      AdminCidr="${MY_IP}/32" \
      DbPort="$DB_PORT" \
      DbInstanceClass="$DB_INSTANCE_CLASS" \
      DbAllocatedStorage="$DB_STORAGE_GB" \
      DbBackupRetentionDays="$DB_BACKUP_RETENTION_DAYS" \
      DbName="$DB_NAME" \
      DbMasterUsername="$DB_MASTER_USER" \
      WebRoleName="$EC2_ROLE" \
      SiteBucket="$SITE_BUCKET" \
      FlowLogGroupName="$FLOW_LOG_GROUP" \
      ProjectTag="$TAG_VALUE" \
  --tags "${TAG_KEY}=${TAG_VALUE}"

VPC_ID=$(stack_output VpcId)
MGMT_SUBNET=$(stack_output MgmtSubnetAId)
WEB_SUBNET=$(stack_output WebSubnetAId)
BASTION_SG=$(stack_output BastionSgId)
WEB_SG=$(stack_output WebSgId)
S3_ENDPOINT=$(stack_output S3EndpointId)
DEFAULT_SG=$(stack_output DefaultSecurityGroupId)
DB_HOST=$(stack_output DbEndpoint)
FS_ID=$(stack_output FileSystemId)
AP_ID=$(stack_output AccessPointId)
AP_ARN=$(stack_output AccessPointArn)
FS_ARN="arn:aws:elasticfilesystem:${REGION}:${ACCOUNT_ID}:file-system/${FS_ID}"
echo "VPC: $VPC_ID   S3 endpoint: $S3_ENDPOINT"
echo "Subnets: mgmt $MGMT_SUBNET, web $WEB_SUBNET   SG: bastion $BASTION_SG, web $WEB_SG"
echo "Database: $DB_HOST:$DB_PORT   EFS: $FS_ID (access point $AP_ID)"

# Every VPC gets a "default" security group that lets its members talk to each
# other freely. CloudFormation can't manage it, so empty it here: anything
# launched by mistake without our groups ends up with no access at all.
default_sg_rules() {   # false = inbound rules, true = outbound rules
  aws ec2 describe-security-group-rules --region "$REGION" \
    --filters Name=group-id,Values="$DEFAULT_SG" \
    --query "SecurityGroupRules[?IsEgress==\`$1\`].SecurityGroupRuleId" --output text
}
IN_RULES=$(default_sg_rules false)
OUT_RULES=$(default_sg_rules true)
if [[ -n "$IN_RULES" ]]; then
  aws ec2 revoke-security-group-ingress --region "$REGION" --group-id "$DEFAULT_SG" \
    --security-group-rule-ids $IN_RULES >/dev/null
fi
if [[ -n "$OUT_RULES" ]]; then
  aws ec2 revoke-security-group-egress --region "$REGION" --group-id "$DEFAULT_SG" \
    --security-group-rule-ids $OUT_RULES >/dev/null
fi
echo "Default security group $DEFAULT_SG emptied (no rules in, no rules out)"

# EC2 (reader) role policy - needs the stack's EFS ids.
#   S3:   read-only, and only the published static content (web/). It writes
#         NOTHING to S3 itself - logs and backups go through the uploader role.
#   SSM:  read exactly the three Novatrix secrets (the master password is
#         needed once, at first boot, to create the WordPress DB user).
#   EFS:  mount and write - only through the WordPress access point.
EC2_ROLE_POLICY=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListaPubliceradSajt",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "${BUCKET_ARN}",
      "Condition": { "StringLike": { "s3:prefix": ["web/*"] } }
    },
    {
      "Sid": "LasPubliceradSajt",
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "${BUCKET_ARN}/web/*"
    },
    {
      "Sid": "BegarUppladdarroll",
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "${UPLOADER_ROLE_ARN}"
    },
    {
      "Sid": "LasNovatrixHemligheter",
      "Effect": "Allow",
      "Action": "ssm:GetParameter",
      "Resource": [
        "${SSM_ARN_PREFIX}${DB_MASTER_PW_PARAM}",
        "${SSM_ARN_PREFIX}${DB_APP_PW_PARAM}",
        "${SSM_ARN_PREFIX}${WP_ADMIN_PW_PARAM}"
      ]
    },
    {
      "Sid": "MonteraWordpressViaAccessPoint",
      "Effect": "Allow",
      "Action": ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"],
      "Resource": "${FS_ARN}",
      "Condition": { "StringEquals": { "elasticfilesystem:AccessPointArn": "${AP_ARN}" } }
    }
  ]
}
JSON
)

# =============================================================================
# 4. Storage: S3 (static content + backups) and log group
# =============================================================================
step "Storage: S3 bucket and log group"
if aws s3api head-bucket --bucket "$SITE_BUCKET" 2>/dev/null; then
  echo "Bucket already exists: $SITE_BUCKET"
else
  aws s3api create-bucket --bucket "$SITE_BUCKET" --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
  echo "Bucket created: $SITE_BUCKET"
fi
# The bucket is private: visitors reach the site through EC2, never S3 directly.
aws s3api put-public-access-block --bucket "$SITE_BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-tagging --bucket "$SITE_BUCKET" \
  --tagging "TagSet=[{Key=${TAG_KEY},Value=${TAG_VALUE}}]"
# Resource policy:
#  1. refuse every request that is not encrypted in transit (TLS)
#  2. the web server's roles only work from inside the Novatrix VPC, through
#     the S3 endpoint. Stolen instance credentials are useless elsewhere.
aws s3api put-bucket-policy --bucket "$SITE_BUCKET" --policy "$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EndastTLS",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": ["${BUCKET_ARN}", "${BUCKET_ARN}/*"],
      "Condition": { "Bool": { "aws:SecureTransport": "false" } }
    },
    {
      "Sid": "InstansrollerEndastViaVpcEndpoint",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": ["${BUCKET_ARN}", "${BUCKET_ARN}/*"],
      "Condition": {
        "ArnEquals": { "aws:PrincipalArn": ["${EC2_ROLE_ARN}", "${UPLOADER_ROLE_ARN}"] },
        "StringNotEquals": { "aws:SourceVpce": "${S3_ENDPOINT}" }
      }
    }
  ]
}
JSON
)"
# Lifecycle rules - storage (and cost) never grows without limit:
#   backup/  database dumps and wp-content archives: deleted after 14 days
#   loggar/  Apache logs: deleted after 30 days
#   all      half-finished multipart uploads (e.g. an interrupted backup): 1 day
aws s3api put-bucket-lifecycle-configuration --bucket "$SITE_BUCKET" \
  --lifecycle-configuration "$(cat <<JSON
{
  "Rules": [
    {
      "ID": "rensa-gamla-backuper",
      "Status": "Enabled",
      "Filter": { "Prefix": "backup/" },
      "Expiration": { "Days": ${BACKUP_RETENTION_DAYS} }
    },
    {
      "ID": "rensa-gamla-loggar",
      "Status": "Enabled",
      "Filter": { "Prefix": "loggar/" },
      "Expiration": { "Days": ${LOG_RETENTION_DAYS} }
    },
    {
      "ID": "rensa-avbrutna-uppladdningar",
      "Status": "Enabled",
      "Filter": { "Prefix": "" },
      "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 1 }
    }
  ]
}
JSON
)"
echo "Lifecycle: backup/ ${BACKUP_RETENTION_DAYS} days, loggar/ ${LOG_RETENTION_DAYS} days"

# Created here (not by Lambda) so the Lambda role needs no logs:CreateLogGroup.
aws logs create-log-group --region "$REGION" --log-group-name "$LOG_GROUP" 2>/dev/null || true
aws logs put-retention-policy --region "$REGION" --log-group-name "$LOG_GROUP" --retention-in-days 7

# =============================================================================
# 5. Service roles
# =============================================================================
step "Service roles"
ensure_role "$EC2_ROLE" "$EC2_TRUST" "Novatrix web server: WordPress on EFS, read static content in S3"
aws iam put-role-policy --role-name "$EC2_ROLE" --policy-name "novatrix-web-ec2-access" \
  --policy-document "$EC2_ROLE_POLICY"
echo "Role ready: $EC2_ROLE"

if ! aws iam get-instance-profile --instance-profile-name "$EC2_PROFILE" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "$EC2_PROFILE" --tags "$TAGS_IAM" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$EC2_PROFILE" --role-name "$EC2_ROLE"
fi
echo "Instance profile ready: $EC2_PROFILE"

# Retry: IAM rejects a trust policy naming a role that has not propagated yet.
retry ensure_role "$UPLOADER_ROLE" "$UPLOADER_TRUST" "Novatrix: upload logs and backups, assumable only by the EC2 role"
aws iam put-role-policy --role-name "$UPLOADER_ROLE" --policy-name "novatrix-uppladdare-access" \
  --policy-document "$UPLOADER_ROLE_POLICY"
echo "Role ready: $UPLOADER_ROLE (assumable only by $EC2_ROLE)"

ensure_role "$LAMBDA_ROLE" "$LAMBDA_TRUST" "Novatrix publisher: S3 utkast/ -> web/"
aws iam put-role-policy --role-name "$LAMBDA_ROLE" --policy-name "novatrix-publicerare-access" \
  --policy-document "$LAMBDA_ROLE_POLICY"
echo "Role ready: $LAMBDA_ROLE"

# =============================================================================
# 6. Publisher Lambda + S3 trigger
# =============================================================================
step "Publisher Lambda and S3 event trigger"
cat > "$WORK_DIR/lambda_function.py" <<'PY'
"""Novatrix publisher: copies approved drafts from utkast/ to web/.

Only web file types are published, and with a correct Content-Type, so a
draft can never put e.g. a script or an executable on the website.
"""
import json
import os
import urllib.parse

import boto3

s3 = boto3.client("s3")

ALLOWED = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".txt": "text/plain; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".webp": "image/webp",
    ".ico": "image/x-icon",
}
MAX_BYTES = 5 * 1024 * 1024


def log(**fields):
    print(json.dumps(fields, ensure_ascii=False))


def lambda_handler(event, context):
    for record in event["Records"]:
        bucket = record["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
        size = record["s3"]["object"].get("size", 0)
        rel = key[len("utkast/"):] if key.startswith("utkast/") else ""
        ext = os.path.splitext(rel)[1].lower()

        if not rel or ".." in rel or rel.endswith("/"):
            log(nekad=key, orsak="ogiltig sökväg")
        elif ext not in ALLOWED:
            log(nekad=key, orsak=f"filtypen {ext or '(ingen)'} publiceras inte")
        elif size > MAX_BYTES:
            log(nekad=key, orsak="filen är större än 5 MB")
        else:
            body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
            s3.put_object(Bucket=bucket, Key=f"web/{rel}", Body=body,
                          ContentType=ALLOWED[ext], CacheControl="max-age=300")
            log(publicerad=f"web/{rel}", bytes=len(body))
    return {"ok": True}
PY
make_lambda_zip

if aws lambda get-function --region "$REGION" --function-name "$FUNCTION_NAME" >/dev/null 2>&1; then
  aws lambda update-function-code --region "$REGION" --function-name "$FUNCTION_NAME" \
    --zip-file "fileb://$WORK_DIR/lambda.zip" >/dev/null
  aws lambda wait function-updated-v2 --region "$REGION" --function-name "$FUNCTION_NAME"
  echo "Lambda code updated: $FUNCTION_NAME"
else
  # Retry: a brand new role can take a few seconds before Lambda may assume it.
  retry aws lambda create-function --region "$REGION" --function-name "$FUNCTION_NAME" \
    --runtime python3.12 --handler lambda_function.lambda_handler \
    --role "$LAMBDA_ROLE_ARN" --zip-file "fileb://$WORK_DIR/lambda.zip" \
    --timeout 15 --memory-size 128 \
    --tags "${TAG_KEY}=${TAG_VALUE}" >/dev/null
  aws lambda wait function-active-v2 --region "$REGION" --function-name "$FUNCTION_NAME"
  echo "Lambda created: $FUNCTION_NAME"
fi

# Resource-based policy on the Lambda: only S3, only from OUR bucket and OUR
# account may invoke it (protects against the confused deputy problem).
aws lambda add-permission --region "$REGION" --function-name "$FUNCTION_NAME" \
  --statement-id s3-utkast --action lambda:InvokeFunction \
  --principal s3.amazonaws.com \
  --source-arn "$BUCKET_ARN" \
  --source-account "$ACCOUNT_ID" >/dev/null 2>&1 || true

# Trigger only on utkast/ - the Lambda writes to web/, so it can never trigger itself.
retry aws s3api put-bucket-notification-configuration --bucket "$SITE_BUCKET" \
  --notification-configuration "$(cat <<JSON
{
  "LambdaFunctionConfigurations": [{
    "Id": "publicera-utkast",
    "LambdaFunctionArn": "${FUNCTION_ARN}",
    "Events": ["s3:ObjectCreated:*"],
    "Filter": { "Key": { "FilterRules": [ { "Name": "prefix", "Value": "utkast/" } ] } }
  }]
}
JSON
)"
echo "S3 -> Lambda trigger ready (utkast/*)"

# =============================================================================
# 7. Human access: groups, policies, users
# =============================================================================
step "IAM groups, policies and users"
for group in "$DRIFT_GROUP" "$DEV_GROUP" "$MARKNAD_GROUP"; do
  aws iam get-group --group-name "$group" >/dev/null 2>&1 \
    || aws iam create-group --group-name "$group" >/dev/null
done

DRIFT_POLICY_ARN=$(ensure_policy "novatrix-drift-policy" "$DRIFT_POLICY")
DEV_POLICY_ARN=$(ensure_policy "novatrix-utveckling-policy" "$DEV_POLICY")
MARKNAD_POLICY_ARN=$(ensure_policy "novatrix-marknad-policy" "$MARKNAD_POLICY")

aws iam attach-group-policy --group-name "$DRIFT_GROUP"   --policy-arn "$DRIFT_POLICY_ARN"
aws iam attach-group-policy --group-name "$DEV_GROUP"     --policy-arn "$DEV_POLICY_ARN"
aws iam attach-group-policy --group-name "$MARKNAD_GROUP" --policy-arn "$MARKNAD_POLICY_ARN"
echo "Groups ready: $DRIFT_GROUP, $DEV_GROUP, $MARKNAD_GROUP"

# Users get permissions ONLY through their group - never directly.
# No passwords or access keys are created here.
for entry in "${USERS[@]}"; do
  user=${entry%%:*}
  group=${entry##*:}
  aws iam get-user --user-name "$user" >/dev/null 2>&1 \
    || aws iam create-user --user-name "$user" --tags "$TAGS_IAM" >/dev/null
  aws iam add-user-to-group --user-name "$user" --group-name "$group"
  echo "User ready: $user -> $group"
done

# =============================================================================
# 8. Static content: uploaded as drafts, published by the Lambda, served by
#    the web server under /statiskt/ (WordPress owns the rest of the site)
# =============================================================================
step "Static content drafts to s3://$SITE_BUCKET/utkast/"
mkdir -p "$WORK_DIR/site/bilder"

# Relative links: the page lives under /statiskt/ on the web server.
cat > "$WORK_DIR/site/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="sv">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Novatrix – statisk sida</title>
  <meta name="description" content="Statiskt innehåll som publiceras från S3.">
  <link rel="icon" href="bilder/kran.svg" type="image/svg+xml">
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <header class="topp">
    <span class="logo">Novatrix</span>
  </header>

  <main class="hero">
    <img src="bilder/kran.svg" alt="" class="illustration" width="160" height="160">
    <p class="etikett">Statisk sida</p>
    <h1>Statiskt innehåll från S3</h1>
    <p class="ingress">Den här sidan laddas upp som utkast, kontrolleras av publiceraren
      (Lambda) och hämtas av webbservern från S3. Själva webbplatsen är WordPress.</p>
    <p><a href="/">Till Novatrix webbplats</a></p>
  </main>

  <footer class="fot">
    <p>&copy; 2026 Novatrix</p>
  </footer>
</body>
</html>
HTML

cat > "$WORK_DIR/site/style.css" <<'CSS'
:root {
  --bg: #f1f5f9; --kort: #ffffff; --text: #1e293b; --dampad: #64748b;
  --accent: #0369a1; --varning: #f59e0b;
}
* { box-sizing: border-box; }
html, body { height: 100%; }
body {
  margin: 0; font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
  background: var(--bg); color: var(--text); line-height: 1.6;
  display: flex; flex-direction: column;
}
.topp { padding: 20px 24px; }
.logo { font-weight: 800; font-size: 1.25rem; letter-spacing: .02em; color: var(--accent); }
.hero {
  flex: 1; width: 100%; max-width: 640px; margin: 0 auto; padding: 24px 24px 48px;
  display: flex; flex-direction: column; align-items: center; text-align: center;
}
.illustration { margin: 12px 0 20px; }
.etikett {
  margin: 0; padding: 4px 12px; border-radius: 999px; font-size: .8rem; font-weight: 700;
  text-transform: uppercase; letter-spacing: .08em; background: #e0f2fe; color: #075985;
}
h1 { margin: 16px 0 8px; font-size: clamp(1.8rem, 5vw, 2.6rem); line-height: 1.2; }
.ingress { margin: 0 0 20px; font-size: 1.1rem; color: var(--dampad); }
a { color: var(--accent); font-weight: 600; }
.fot { padding: 20px 24px; text-align: center; font-size: .85rem; color: var(--dampad); }
.fot p { margin: 0; }
CSS

cat > "$WORK_DIR/site/bilder/kran.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 160 160" fill="none">
  <rect x="10" y="140" width="140" height="8" rx="4" fill="#cbd5e1"/>
  <rect x="44" y="40" width="10" height="100" fill="#0369a1"/>
  <rect x="20" y="32" width="120" height="10" rx="2" fill="#0369a1"/>
  <rect x="20" y="42" width="18" height="14" rx="2" fill="#475569"/>
  <path d="M49 32 L49 18 L60 32" stroke="#0369a1" stroke-width="4" stroke-linejoin="round"/>
  <line x1="118" y1="42" x2="118" y2="88" stroke="#475569" stroke-width="2"/>
  <path d="M112 88 h12 v6 a6 6 0 0 1 -12 0 z" fill="#475569"/>
  <rect x="98" y="100" width="40" height="40" rx="3" fill="#f59e0b"/>
  <rect x="104" y="106" width="28" height="6" rx="2" fill="#fbbf24"/>
</svg>
SVG

for f in index.html style.css bilder/kran.svg; do
  aws s3 cp "$WORK_DIR/site/$f" "s3://${SITE_BUCKET}/utkast/$f" --region "$REGION" --only-show-errors
done
echo "Drafts uploaded - waiting for the publisher to copy them to web/ ..."
PUBLISHED=no
for i in $(seq 1 24); do
  if aws s3api head-object --bucket "$SITE_BUCKET" --key web/index.html --region "$REGION" >/dev/null 2>&1; then
    PUBLISHED=yes; break
  fi
  sleep 5
done
[[ "$PUBLISHED" == yes ]] && echo "Published: web/index.html" \
  || echo "WARNING: web/index.html not published yet - check: aws logs tail $LOG_GROUP --region $REGION"

# =============================================================================
# 9. EC2: web server with WordPress (public subnet) + bastion (management subnet)
# =============================================================================
step "EC2: web server in $WEB_SUBNET, bastion in $MGMT_SUBNET"
AMI_ID=$(aws ssm get-parameter --region "$REGION" \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value --output text)
echo "AMI: $AMI_ID"

# Shared by both instances: IMDSv2 only (blocks SSRF-style credential theft
# with a plain GET), and an encrypted root disk.
METADATA_OPTS="HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=1"
DISK_OPTS="DeviceName=/dev/xvda,Ebs={Encrypted=true,VolumeType=gp3,DeleteOnTermination=true}"

# Find a running/pending instance by Name tag, inside the Novatrix VPC only.
find_instance() {
  aws ec2 describe-instances --region "$REGION" \
    --filters Name=tag:Name,Values="$1" Name=vpc-id,Values="$VPC_ID" \
              Name=instance-state-name,Values=pending,running \
    --query 'Reservations[0].Instances[0].InstanceId' --output text
}

# SSH hardening shared by web server and bastion (sshd uses the FIRST value it
# reads, and 10-* is read before Amazon Linux's own 50-redhat.conf).
SSHD_COMMON='PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
AllowAgentForwarding no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2'

# User data: Apache + PHP-FPM, EFS mount, WordPress (DB user + install), static
# content from S3, log archive and daily backup via the uploader role.
# Everything that touches EFS or the database is idempotent: a second web
# server (or a replacement) finds WordPress already installed and just mounts it.
USER_DATA=$(cat <<'USERDATA'
#!/bin/bash
set -euo pipefail

# --- Settings for this server (also read by the timers' scripts) -----------
mkdir -p /etc/novatrix
cat > /etc/novatrix/wordpress.env <<'ENV'
REGION=__REGION__
BUCKET=__BUCKET__
FS_ID=__FS_ID__
AP_ID=__AP_ID__
DB_HOST=__DB_HOST__
DB_PORT=__DB_PORT__
DB_NAME=__DB_NAME__
DB_MASTER_USER=__DB_MASTER_USER__
DB_APP_USER=__DB_APP_USER__
DB_MASTER_PW_PARAM=__DB_MASTER_PW_PARAM__
DB_APP_PW_PARAM=__DB_APP_PW_PARAM__
WP_ADMIN_PW_PARAM=__WP_ADMIN_PW_PARAM__
WP_ROOT=__WP_ROOT__
ENV
chmod 644 /etc/novatrix/wordpress.env
source /etc/novatrix/wordpress.env

# --- Packages: required ones must install, extras are best effort ----------
dnf install -y httpd mod_ssl php php-fpm php-mysqlnd mariadb105 amazon-efs-utils
dnf install -y --setopt=strict=0 php-gd php-mbstring php-xml php-opcache php-intl || true

# --- SSH hardening: reachable only from the bastion, no forwarding ---------
cat > /etc/ssh/sshd_config.d/10-novatrix.conf <<'SSHD'
__SSHD_COMMON__
AllowTcpForwarding no
SSHD
# Validate before reloading: a typo must never lock us out of the server.
if sshd -t; then systemctl reload sshd
else echo "sshd rejected 10-novatrix.conf - removed it" >&2; rm -f /etc/ssh/sshd_config.d/10-novatrix.conf; fi

# --- HTTPS: self-signed certificate (no domain yet - see the documentation).
openssl req -x509 -nodes -newkey rsa:2048 -days 365 -subj "/CN=novatrix-webb" \
  -keyout /etc/pki/tls/private/localhost.key -out /etc/pki/tls/certs/localhost.crt
chmod 600 /etc/pki/tls/private/localhost.key

# --- Apache + PHP hardening -------------------------------------------------
# CSP/X-Frame-Options allow same-origin framing: WordPress's own editor needs it.
cat > /etc/httpd/conf.d/10-novatrix-sakerhet.conf <<'CONF'
ServerTokens Prod
ServerSignature Off
TraceEnable Off
Header always set X-Content-Type-Options "nosniff"
Header always set X-Frame-Options "SAMEORIGIN"
Header always set Referrer-Policy "strict-origin-when-cross-origin"
Header always set Content-Security-Policy "frame-ancestors 'self'"

<Directory "/var/www/html">
    Options -Indexes +FollowSymLinks
    AllowOverride All
    Require all granted
</Directory>
# XML-RPC: old remote API, a favourite for password guessing. Not used here.
<Files "xmlrpc.php">
    Require all denied
</Files>
# Uploaded files are data, never code: no PHP runs from the uploads folder.
<Directory "/var/www/html/wp-content/uploads">
    <FilesMatch "\.(php|phtml|phar)$">
        Require all denied
    </FilesMatch>
</Directory>

# Static content published from S3 web/ (the Lambda chain)
Alias /statiskt/ /var/www/statiskt/
<Directory "/var/www/statiskt">
    Options -Indexes
    AllowOverride None
    Require all granted
</Directory>
CONF
cat > /etc/php.d/90-novatrix.ini <<'INI'
expose_php = Off
upload_max_filesize = 16M
post_max_size = 16M
INI

# --- EFS: WordPress files on shared storage --------------------------------
# tls = encrypted NFS, iam = the instance role authenticates, accesspoint =
# forced to uid/gid 48 (apache) under /wordpress. nofail: a missing EFS must
# never stop the server from booting (we would lose SSH).
mkdir -p "$WP_ROOT"
echo "$FS_ID:/ $WP_ROOT efs _netdev,nofail,tls,iam,accesspoint=$AP_ID 0 0" >> /etc/fstab
for i in $(seq 1 18); do
  mount "$WP_ROOT" 2>/dev/null && break
  echo "waiting for EFS / the instance role ($i/18)"; sleep 10
done
mountpoint -q "$WP_ROOT"
# Apache and PHP must never start on the empty local folder underneath.
for svc in httpd php-fpm; do
  mkdir -p /etc/systemd/system/$svc.service.d
  printf '[Unit]\nRequiresMountsFor=%s\n' "$WP_ROOT" > /etc/systemd/system/$svc.service.d/10-novatrix-efs.conf
done

# --- s3-curl: reach S3 with nothing but curl and the instance role ----------
cat > /usr/local/bin/s3-curl <<'SH'
#!/bin/bash
set -euo pipefail
BUCKET="__BUCKET__"
REGION="__REGION__"
IMDS="http://169.254.169.254/latest"
TOKEN=$(curl -sf -X PUT "$IMDS/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
ROLE=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" "$IMDS/meta-data/iam/security-credentials/")
CREDS=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" "$IMDS/meta-data/iam/security-credentials/$ROLE")
field() { python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])" <<<"$CREDS"; }
URL="https://${BUCKET}.s3.${REGION}.amazonaws.com/$1"
ARGS=(--silent --show-error --fail-with-body
      --aws-sigv4 "aws:amz:${REGION}:s3"
      --user "$(field AccessKeyId):$(field SecretAccessKey)"
      -H "x-amz-security-token: $(field Token)"
      -H "x-amz-content-sha256: UNSIGNED-PAYLOAD")
if [[ $# -ge 2 ]]; then curl "${ARGS[@]}" -T "$2" "$URL"; else curl "${ARGS[@]}" "$URL"; fi
SH
chmod 755 /usr/local/bin/s3-curl

# --- novatrix-sync: static content S3 web/ -> /var/www/statiskt -------------
mkdir -p /var/www/statiskt
cat > /usr/local/bin/novatrix-sync <<'SH'
#!/bin/bash
aws s3 sync "s3://__BUCKET__/web/" /var/www/statiskt/ --region __REGION__ --only-show-errors
SH
chmod 755 /usr/local/bin/novatrix-sync

# --- som-uppladdare: role chaining (reader -> uploader) ---------------------
cat > /usr/local/bin/som-uppladdare <<'SH'
#!/bin/bash
set -euo pipefail
CREDS=$(aws sts assume-role --region __REGION__ \
  --role-arn "__UPLOADER_ARN__" \
  --role-session-name "uppladdare-$(hostname -s)" \
  --duration-seconds 900 \
  --query '[Credentials.AccessKeyId,Credentials.SecretAccessKey,Credentials.SessionToken]' \
  --output text)
read -r AK SK ST <<<"$CREDS"
AWS_ACCESS_KEY_ID=$AK AWS_SECRET_ACCESS_KEY=$SK AWS_SESSION_TOKEN=$ST exec "$@"
SH
chmod 755 /usr/local/bin/som-uppladdare

# --- novatrix-loggar: archive Apache logs via the uploader role ------------
cat > /usr/local/bin/novatrix-loggar <<'SH'
#!/bin/bash
set -euo pipefail
IMDS="http://169.254.169.254/latest"
TOKEN=$(curl -sf -X PUT "$IMDS/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
IID=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" "$IMDS/meta-data/instance-id")
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
for f in access_log error_log; do
  [[ -s "/var/log/httpd/$f" ]] || continue
  gzip -c "/var/log/httpd/$f" > "/tmp/$f.gz"
  /usr/local/bin/som-uppladdare aws s3 cp "/tmp/$f.gz" \
    "s3://__BUCKET__/loggar/$IID/$STAMP-$f.gz" --region __REGION__ --only-show-errors
  rm -f "/tmp/$f.gz"
  echo "Uploaded $f -> loggar/$IID/$STAMP-$f.gz"
done
SH
chmod 755 /usr/local/bin/novatrix-loggar

# --- novatrix-db: mysql client with a password from SSM (never on disk) ----
# Usage: novatrix-db app|master [mysql/mysqldump args]   (NOVATRIX_DUMP=1 -> mysqldump)
cat > /usr/local/bin/novatrix-db <<'SH'
#!/bin/bash
set -euo pipefail
source /etc/novatrix/wordpress.env
case "${1:-}" in
  app)    user=$DB_APP_USER;    param=$DB_APP_PW_PARAM ;;
  master) user=$DB_MASTER_USER; param=$DB_MASTER_PW_PARAM ;;
  *) echo "usage: novatrix-db app|master [args]" >&2; exit 2 ;;
esac
shift
pw=$(aws ssm get-parameter --region "$REGION" --name "$param" --with-decryption \
       --query Parameter.Value --output text)
cnf=$(mktemp); trap 'rm -f "$cnf"' EXIT
printf '[client]\nhost=%s\nport=%s\nuser=%s\npassword=%s\n' "$DB_HOST" "$DB_PORT" "$user" "$pw" > "$cnf"
if [[ -n "${NOVATRIX_DUMP:-}" ]]; then mysqldump --defaults-extra-file="$cnf" "$@"
else mysql --defaults-extra-file="$cnf" "$@"; fi
SH
chmod 750 /usr/local/bin/novatrix-db

# --- novatrix-backup: DB dump + wp-content -> S3 backup/ (uploader role) ---
# The lifecycle rule on backup/ deletes these after 14 days.
cat > /usr/local/bin/novatrix-backup <<'SH'
#!/bin/bash
set -euo pipefail
source /etc/novatrix/wordpress.env
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
NOVATRIX_DUMP=1 /usr/local/bin/novatrix-db app --single-transaction --no-tablespaces "$DB_NAME" \
  | gzip | /usr/local/bin/som-uppladdare aws s3 cp - \
      "s3://$BUCKET/backup/db/$STAMP-$DB_NAME.sql.gz" --region "$REGION" --only-show-errors
echo "Uploaded backup/db/$STAMP-$DB_NAME.sql.gz"
tar -czf - -C "$WP_ROOT" wp-content | /usr/local/bin/som-uppladdare aws s3 cp - \
  "s3://$BUCKET/backup/filer/$STAMP-wp-content.tar.gz" --region "$REGION" --only-show-errors
echo "Uploaded backup/filer/$STAMP-wp-content.tar.gz"
SH
chmod 750 /usr/local/bin/novatrix-backup

# --- systemd units: sync (30 min), logs + backup (daily), wp-cron (5 min) --
unit() {   # name description exec-start [user]
  printf '[Unit]\nDescription=%s\nAfter=network-online.target\nWants=network-online.target\n[Service]\nType=oneshot\nExecStart=%s\n' \
    "$2" "$3" > /etc/systemd/system/$1.service
  [[ -n "${4:-}" ]] && echo "User=$4" >> /etc/systemd/system/$1.service
  return 0
}
timer() {  # name description timer-lines
  printf '[Unit]\nDescription=%s\n[Timer]\n%s\n[Install]\nWantedBy=timers.target\n' "$2" "$3" \
    > /etc/systemd/system/$1.timer
}
unit  novatrix-sync   "Pull the published static content from S3" /usr/local/bin/novatrix-sync
timer novatrix-sync   "Pull static content periodically" "OnBootSec=2min
OnUnitActiveSec=__INTERVAL__"
unit  novatrix-loggar "Archive Apache logs to S3 via the uploader role" /usr/local/bin/novatrix-loggar
timer novatrix-loggar "Archive Apache logs daily" "OnCalendar=daily
Persistent=true"
unit  novatrix-backup "Back up WordPress (database + wp-content) to S3" /usr/local/bin/novatrix-backup
timer novatrix-backup "Back up WordPress daily" "OnCalendar=*-*-* 00:00:00
Persistent=true"
# WordPress's own cron is triggered by visitors through an HTTP call to the
# site itself - the web security group (correctly) doesn't allow that, so it
# runs from systemd instead.
unit  novatrix-wpcron "WordPress scheduled tasks" "/usr/bin/php $WP_ROOT/wp-cron.php" apache
timer novatrix-wpcron "WordPress scheduled tasks every 5 minutes" "OnBootSec=5min
OnUnitActiveSec=5min"

# --- Database: WordPress's own user (master password only used here) -------
for i in $(seq 1 30); do
  /usr/local/bin/novatrix-db master -e "SELECT 1" >/dev/null 2>&1 && break
  echo "waiting for the database ($i/30)"; sleep 10
done
APP_PW=$(aws ssm get-parameter --region "$REGION" --name "$DB_APP_PW_PARAM" --with-decryption \
           --query Parameter.Value --output text)
# Host part = the web tier 10.0.2.0/23: the user can't log in from anywhere else.
/usr/local/bin/novatrix-db master <<SQL
CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_APP_USER'@'10.0.2.0/255.255.254.0' IDENTIFIED BY '$APP_PW';
ALTER USER '$DB_APP_USER'@'10.0.2.0/255.255.254.0' IDENTIFIED BY '$APP_PW';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_APP_USER'@'10.0.2.0/255.255.254.0';
SQL

# --- WordPress on EFS (WP-CLI) ----------------------------------------------
curl -fsSL -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod 755 /usr/local/bin/wp
WP=(/usr/local/bin/wp --path="$WP_ROOT" --allow-root)
[[ -f "$WP_ROOT/wp-includes/version.php" ]] || "${WP[@]}" core download --locale=__WP_LOCALE__
if [[ ! -f "$WP_ROOT/wp-config.php" ]]; then
  "${WP[@]}" config create --dbname="$DB_NAME" --dbuser="$DB_APP_USER" --dbpass="$APP_PW" \
    --dbhost="$DB_HOST:$DB_PORT" --locale=__WP_LOCALE__ --skip-check --extra-php <<'PHP'
// Novatrix: the site address follows the address the visitor used, because the
// public IP changes when the instance is stopped/started (no domain yet).
if (isset($_SERVER['HTTP_HOST'])) {
    $novatrix_scheme = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ? 'https' : 'http';
    define('WP_HOME', $novatrix_scheme . '://' . $_SERVER['HTTP_HOST']);
    define('WP_SITEURL', WP_HOME);
}
define('DISABLE_WP_CRON', true);      // runs from systemd (novatrix-wpcron.timer)
define('DISALLOW_FILE_EDIT', true);   // no PHP editing from the admin panel
define('FS_METHOD', 'direct');
define('WP_AUTO_UPDATE_CORE', 'minor');
PHP
fi
if ! "${WP[@]}" core is-installed 2>/dev/null; then
  TOKEN=$(curl -sf -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
  PUBLIC_IP=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)
  ADMIN_PW=$(aws ssm get-parameter --region "$REGION" --name "$WP_ADMIN_PW_PARAM" --with-decryption \
               --query Parameter.Value --output text)
  "${WP[@]}" core install --url="http://$PUBLIC_IP" --title="__WP_TITLE__" \
    --admin_user="__WP_ADMIN_USER__" --admin_password="$ADMIN_PW" \
    --admin_email="__WP_ADMIN_EMAIL__" --skip-email
  "${WP[@]}" option update blogdescription "WordPress på RDS och EFS"
  "${WP[@]}" post create --post_type=page --post_status=publish --post_title="Om Novatrix" \
    --post_content="Den här sidan ligger i databasen (RDS). Bilder och filer ligger på delad lagring (EFS)."
fi
mkdir -p "$WP_ROOT/wp-content/uploads"

# --- First static sync (retry while the role's credentials become available)
for i in $(seq 1 12); do
  /usr/local/bin/novatrix-sync && [[ -f /var/www/statiskt/index.html ]] && break
  sleep 5
done

systemctl daemon-reload
systemctl enable --now php-fpm httpd novatrix-sync.timer novatrix-loggar.timer \
  novatrix-backup.timer novatrix-wpcron.timer
echo "Novatrix WordPress ready"
USERDATA
)
USER_DATA=${USER_DATA//__BUCKET__/$SITE_BUCKET}
USER_DATA=${USER_DATA//__UPLOADER_ARN__/$UPLOADER_ROLE_ARN}
USER_DATA=${USER_DATA//__REGION__/$REGION}
USER_DATA=${USER_DATA//__INTERVAL__/$SYNC_INTERVAL}
USER_DATA=${USER_DATA//__SSHD_COMMON__/$SSHD_COMMON}
USER_DATA=${USER_DATA//__FS_ID__/$FS_ID}
USER_DATA=${USER_DATA//__AP_ID__/$AP_ID}
USER_DATA=${USER_DATA//__DB_HOST__/$DB_HOST}
USER_DATA=${USER_DATA//__DB_PORT__/$DB_PORT}
USER_DATA=${USER_DATA//__DB_NAME__/$DB_NAME}
USER_DATA=${USER_DATA//__DB_MASTER_USER__/$DB_MASTER_USER}
USER_DATA=${USER_DATA//__DB_APP_USER__/$DB_APP_USER}
USER_DATA=${USER_DATA//__DB_MASTER_PW_PARAM__/$DB_MASTER_PW_PARAM}
USER_DATA=${USER_DATA//__DB_APP_PW_PARAM__/$DB_APP_PW_PARAM}
USER_DATA=${USER_DATA//__WP_ADMIN_PW_PARAM__/$WP_ADMIN_PW_PARAM}
USER_DATA=${USER_DATA//__WP_ROOT__/$WP_ROOT}
USER_DATA=${USER_DATA//__WP_LOCALE__/$WP_LOCALE}
USER_DATA=${USER_DATA//__WP_TITLE__/$WP_TITLE}
USER_DATA=${USER_DATA//__WP_ADMIN_USER__/$WP_ADMIN_USER}
USER_DATA=${USER_DATA//__WP_ADMIN_EMAIL__/$WP_ADMIN_EMAIL}
if (( ${#USER_DATA} > 16000 )); then
  echo "User data is ${#USER_DATA} bytes - EC2 allows 16 KB." >&2; exit 1
fi

# Bastion user data: installs NOTHING (its security group doesn't even allow
# it to reach the internet). Only hardens SSH: it may forward SSH connections
# (port 22) and nothing else, so it can't be used as a tunnel to the database.
BASTION_USER_DATA=$(cat <<'USERDATA'
#!/bin/bash
set -e
cat > /etc/ssh/sshd_config.d/10-novatrix.conf <<'SSHD'
__SSHD_COMMON__
AllowTcpForwarding local
PermitOpen *:22
SSHD
# Validate before reloading: a typo must never lock us out of the server.
if sshd -t; then systemctl reload sshd
else echo "sshd rejected 10-novatrix.conf - removed it" >&2; rm -f /etc/ssh/sshd_config.d/10-novatrix.conf; fi
USERDATA
)
BASTION_USER_DATA=${BASTION_USER_DATA//__SSHD_COMMON__/$SSHD_COMMON}

# --- Web server: public subnet web-a, web security group, reader role --------
INSTANCE_ID=$(find_instance "$INSTANCE_NAME")
if [[ "$INSTANCE_ID" != "None" ]]; then
  echo "Web server already running: $INSTANCE_ID (terminate it to relaunch - WordPress lives on EFS/RDS)"
else
  # Retry: a new instance profile is not usable by EC2 for a few seconds.
  INSTANCE_ID=$(retry aws ec2 run-instances --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --subnet-id "$WEB_SUBNET" \
    --security-group-ids "$WEB_SG" \
    --associate-public-ip-address \
    --iam-instance-profile Name="$EC2_PROFILE" \
    --credit-specification CpuCredits=standard \
    --metadata-options "$METADATA_OPTS" \
    --block-device-mappings "$DISK_OPTS" \
    --user-data "$USER_DATA" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=Roll,Value=webb},{Key=Version,Value=$VERSION_TAG},{Key=${TAG_KEY},Value=${TAG_VALUE}}]" \
    --query 'Instances[0].InstanceId' --output text)
  echo "Web server launched: $INSTANCE_ID"
fi

# --- Bastion: public subnet mgmt-a, bastion security group, NO IAM role -----
BASTION_ID=$(find_instance "$BASTION_NAME")
if [[ "$BASTION_ID" != "None" ]]; then
  echo "Bastion already running: $BASTION_ID"
else
  BASTION_ID=$(aws ec2 run-instances --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --subnet-id "$MGMT_SUBNET" \
    --security-group-ids "$BASTION_SG" \
    --associate-public-ip-address \
    --credit-specification CpuCredits=standard \
    --metadata-options "$METADATA_OPTS" \
    --block-device-mappings "$DISK_OPTS" \
    --user-data "$BASTION_USER_DATA" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$BASTION_NAME},{Key=Roll,Value=bastion},{Key=Version,Value=$VERSION_TAG},{Key=${TAG_KEY},Value=${TAG_VALUE}}]" \
    --query 'Instances[0].InstanceId' --output text)
  echo "Bastion launched: $BASTION_ID"
fi

echo "Waiting for both instances to be 'running'..."
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID" "$BASTION_ID"

read -r PUBLIC_IP PRIVATE_IP < <(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].[PublicIpAddress,PrivateIpAddress]' --output text)
BASTION_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$BASTION_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

echo
echo "Done! WordPress is up in 3-5 minutes (user data installs it at first boot)."
echo "  WordPress:  http://$PUBLIC_IP   and   https://$PUBLIC_IP  (self-signed certificate)"
echo "  Admin:      http://$PUBLIC_IP/wp-admin   user: $WP_ADMIN_USER"
echo "              password: aws ssm get-parameter --region $REGION --name $WP_ADMIN_PW_PARAM --with-decryption --query Parameter.Value --output text"
echo "  Static:     http://$PUBLIC_IP$STATIC_URL_PATH/   (published from S3 web/)"
echo "  Bastion:    ssh -i $KEY_FILE ec2-user@$BASTION_IP"
echo "  Web (only via the bastion):"
echo "              ssh -i $KEY_FILE -o ProxyCommand=\"ssh -i $KEY_FILE -W %h:%p ec2-user@$BASTION_IP\" ec2-user@$PRIVATE_IP"
echo "  On EC2:     sudo cat /var/log/cloud-init-output.log   (the WordPress installation)"
echo "              sudo /usr/local/bin/novatrix-db app -e 'SHOW TABLES' $DB_NAME   (as WordPress's DB user)"
echo "              df -h $WP_ROOT                             (the shared storage, EFS)"
echo "              sudo systemctl start novatrix-backup       (back up now instead of at 00:00 UTC)"
echo
echo "Tip:      stop the bastion when you are not administering - nothing else needs it:"
echo "            aws ec2 stop-instances --instance-ids $BASTION_ID --region $REGION"
echo "Next:     ./V45_verify.sh     (tests permissions, WordPress on RDS + EFS, backups AND the network)"
echo "Clean up: ./V45_cleanup.sh"
