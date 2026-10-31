#!/usr/bin/env bash
# =============================================================================
# Novatrix V44 - own network with defense in depth (builds on V43's IAM setup).
#
# NEW IN V44 - the network, defined as code in V44_network.yaml (CloudFormation):
#
#   VPC 10.0.0.0/16, three tiers in separate subnets:
#     mgmt-a  10.0.0.0/24   public   bastion (only SSH entry, only from your IP)
#     web-a/b 10.0.2.0/23   public   Apache web server (HTTP/HTTPS from everyone)
#     data-a/b 10.0.10.0/23 private  prepared for the database (no internet route)
#   Internet gateway + public route table, private route table WITHOUT internet,
#   security groups (stateful, per instance) AND network ACLs (stateless, per
#   subnet) - two independent firewalls, S3 gateway endpoint with an endpoint
#   policy, VPC flow logs that record accepted and rejected traffic.
#
#   On top of that: the default security group is emptied, the instance roles
#   only work through the VPC endpoint (bucket policy), SSH is hardened,
#   root disks are encrypted and the bastion has no IAM role at all.
#
# FROM V43 (unchanged) - the site's content lives in S3. Publishing is a chain:
#
#   people --PutObject--> S3 utkast/   (drafts; each group only its own prefix)
#   S3 event --invokes--> Lambda        (resource policy: only our bucket/account)
#   Lambda role --Get utkast/, Put web/--> S3 web/   (validates file types)
#   EC2 instance role --List/Get web/--> serves the site, also via plain curl
#
# Role chaining on the web server:
#   EC2 instance role (reader, can write NOTHING)
#     --sts:AssumeRole--> uploader role (trusts ONLY the reader role)
#       --PutObject--> S3 loggar/   (daily Apache log archive)
#
# Plus IAM groups + users for Novatrix roles: drift, utveckling, marknad.
#
# Requirements: AWS CLI v2 with admin credentials, existing key pair, zip OR
#               python OR powershell (to package the Lambda).
#               V43's instance must be gone (./V43_cleanup.sh) - V44 moves the
#               web server out of the default VPC.
# Run:          ./V44_novatrix.sh       (safe to re-run; re-run if your IP changes)
# Verify:       ./V44_verify.sh
# Clean up:     ./V44_cleanup.sh
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
source ./V44_config.sh

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
# 1. Policy documents
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

# ----- Permission policies: WHAT each service role may do --------------------
# EC2 (reader): read-only, and only the published site (web/). It writes NOTHING
# itself - to upload logs it must first assume the uploader role.
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
    }
  ]
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

# Uploader: write-only, and only to the log archive. Cannot read anything.
UPLOADER_ROLE_POLICY=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "LaddaUppLoggar",
    "Effect": "Allow",
    "Action": "s3:PutObject",
    "Resource": "${BUCKET_ARN}/loggar/*"
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
# Drift: operate the Novatrix servers (also start/stop the bastion) and read
# logs/metrics/network setup. No content, no code, and NO network changes:
# opening a port takes an administrator and a change in V44_network.yaml.
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
      "Sid": "ListaWebbserverloggar",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "${BUCKET_ARN}",
      "Condition": { "StringLike": { "s3:prefix": ["loggar/*"] } }
    },
    {
      "Sid": "LasWebbserverloggar",
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "${BUCKET_ARN}/loggar/*"
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
# 2. Network - deployed from V44_network.yaml (infrastructure as code)
# =============================================================================
step "Network: VPC, subnets, route tables, security groups, NACLs ($STACK_NAME)"

# V44 moves the web server out of the default VPC. A V43 instance with the
# same name would be mistaken for ours, so it has to go first.
OLD=$(aws ec2 describe-instances --region "$REGION" \
  --filters Name=tag:Name,Values="$INSTANCE_NAME" Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[?VpcId!=`null`].[InstanceId,VpcId]' --output text)
STACK_VPC=$(stack_output VpcId)
while read -r old_id old_vpc; do
  [[ -z "${old_id:-}" || "$old_vpc" == "$STACK_VPC" ]] && continue
  echo "Found V43 instance $old_id in $old_vpc (not the Novatrix VPC)." >&2
  echo "Run ./V43_cleanup.sh (or terminate it) first, then run this script again." >&2
  exit 1
done <<<"$OLD"

MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')
[[ "$MY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Could not read your public IP." >&2; exit 1; }
echo "Admin access (SSH to the bastion) only from: ${MY_IP}/32"

# deploy = create the stack the first time, apply only the differences later.
# Re-running with a new IP updates the bastion's security group AND NACL.
aws cloudformation deploy --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --template-file "$NETWORK_TEMPLATE" \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
      AdminCidr="${MY_IP}/32" \
      DbPort="$DB_PORT" \
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
echo "VPC: $VPC_ID   S3 endpoint: $S3_ENDPOINT"
echo "Subnets: mgmt $MGMT_SUBNET, web $WEB_SUBNET   SG: bastion $BASTION_SG, web $WEB_SG"

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

# =============================================================================
# 3. Storage
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
#  2. NEW V44: the web server's roles only work from inside the Novatrix VPC,
#     through the S3 endpoint. If an attacker steals the instance credentials
#     (e.g. via SSRF against the metadata service) they are useless elsewhere.
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
# Keep storage (and cost) small: archived web server logs expire automatically.
aws s3api put-bucket-lifecycle-configuration --bucket "$SITE_BUCKET" \
  --lifecycle-configuration "$(cat <<JSON
{
  "Rules": [{
    "ID": "rensa-gamla-loggar",
    "Status": "Enabled",
    "Filter": { "Prefix": "loggar/" },
    "Expiration": { "Days": ${LOG_RETENTION_DAYS} }
  }]
}
JSON
)"

# Created here (not by Lambda) so the Lambda role needs no logs:CreateLogGroup.
aws logs create-log-group --region "$REGION" --log-group-name "$LOG_GROUP" 2>/dev/null || true
aws logs put-retention-policy --region "$REGION" --log-group-name "$LOG_GROUP" --retention-in-days 7

# =============================================================================
# 4. Service roles
# =============================================================================
step "Service roles"
ensure_role "$EC2_ROLE" "$EC2_TRUST" "Novatrix web server: read the published site in S3"
aws iam put-role-policy --role-name "$EC2_ROLE" --policy-name "novatrix-web-ec2-access" \
  --policy-document "$EC2_ROLE_POLICY"
echo "Role ready: $EC2_ROLE"

if ! aws iam get-instance-profile --instance-profile-name "$EC2_PROFILE" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "$EC2_PROFILE" --tags "$TAGS_IAM" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$EC2_PROFILE" --role-name "$EC2_ROLE"
fi
echo "Instance profile ready: $EC2_PROFILE"

# Retry: IAM rejects a trust policy naming a role that has not propagated yet.
retry ensure_role "$UPLOADER_ROLE" "$UPLOADER_TRUST" "Novatrix: upload web server logs, assumable only by the EC2 role"
aws iam put-role-policy --role-name "$UPLOADER_ROLE" --policy-name "novatrix-uppladdare-access" \
  --policy-document "$UPLOADER_ROLE_POLICY"
echo "Role ready: $UPLOADER_ROLE (assumable only by $EC2_ROLE)"

ensure_role "$LAMBDA_ROLE" "$LAMBDA_TRUST" "Novatrix publisher: S3 utkast/ -> web/"
aws iam put-role-policy --role-name "$LAMBDA_ROLE" --policy-name "novatrix-publicerare-access" \
  --policy-document "$LAMBDA_ROLE_POLICY"
echo "Role ready: $LAMBDA_ROLE"

# =============================================================================
# 5. Publisher Lambda + S3 trigger
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
# 6. Human access: groups, policies, users
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
# 7. Website: uploaded as drafts, published by the Lambda (the chain in action)
# =============================================================================
step "Website drafts to s3://$SITE_BUCKET/utkast/"
mkdir -p "$WORK_DIR/site/bilder"

cat > "$WORK_DIR/site/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="sv">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Novatrix – webbplatsen byggs om</title>
  <meta name="description" content="Novatrix nya webbplats är under konstruktion.">
  <link rel="icon" href="/bilder/kran.svg" type="image/svg+xml">
  <link rel="stylesheet" href="/style.css">
</head>
<body>
  <header class="topp">
    <span class="logo">Novatrix</span>
  </header>

  <main class="hero">
    <img src="/bilder/kran.svg" alt="" class="illustration" width="160" height="160">
    <p class="etikett">Under konstruktion</p>
    <h1>Välkommen till Novatrix</h1>
    <p class="ingress">Vi bygger en ny webbplats just nu. Snart hittar du allt om oss,
      våra tjänster och hur du kommer i kontakt med oss här.</p>

    <div class="framsteg" role="progressbar" aria-valuenow="40" aria-valuemin="0" aria-valuemax="100">
      <span style="width: 40%"></span>
    </div>
    <p class="liten">Tack för ditt tålamod – välkommen tillbaka snart!</p>
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
  text-transform: uppercase; letter-spacing: .08em; background: #fef3c7; color: #92400e;
}
h1 { margin: 16px 0 8px; font-size: clamp(1.8rem, 5vw, 2.6rem); line-height: 1.2; }
.ingress { margin: 0 0 28px; font-size: 1.1rem; color: var(--dampad); }
.framsteg { width: 100%; max-width: 360px; height: 10px; border-radius: 999px; background: #e2e8f0; overflow: hidden; }
.framsteg span {
  display: block; height: 100%; border-radius: 999px;
  background: repeating-linear-gradient(45deg, var(--varning) 0 10px, #fbbf24 10px 20px);
}
.liten { margin-top: 12px; font-size: .9rem; color: var(--dampad); }
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
# 8. EC2: web server (public subnet) + bastion (management subnet)
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

# User data: Apache (HTTP + HTTPS) + a timer that pulls web/ from S3 + a pure-curl S3 client.
USER_DATA=$(cat <<'USERDATA'
#!/bin/bash
set -e
dnf install -y httpd mod_ssl

# --- SSH hardening: reachable only from the bastion, and may not be used as a
#     tunnel itself (no forwarding from the web server).
cat > /etc/ssh/sshd_config.d/10-novatrix.conf <<'SSHD'
__SSHD_COMMON__
AllowTcpForwarding no
SSHD
# Validate before reloading: a typo must never lock us out of the server.
if sshd -t; then systemctl reload sshd
else echo "sshd rejected 10-novatrix.conf - removed it" >&2; rm -f /etc/ssh/sshd_config.d/10-novatrix.conf; fi

# --- HTTPS: self-signed certificate (no domain yet - see the documentation).
# Created before Apache starts, so mod_ssl uses it instead of generating one.
openssl req -x509 -nodes -newkey rsa:2048 -days 365 -subj "/CN=novatrix-webb" \
  -keyout /etc/pki/tls/private/localhost.key -out /etc/pki/tls/certs/localhost.crt
chmod 600 /etc/pki/tls/private/localhost.key

# --- Apache hardening: reveal nothing about versions, no TRACE, security headers.
cat > /etc/httpd/conf.d/10-novatrix-sakerhet.conf <<'CONF'
ServerTokens Prod
ServerSignature Off
TraceEnable Off
Header always set X-Content-Type-Options "nosniff"
Header always set X-Frame-Options "DENY"
Header always set Referrer-Policy "strict-origin-when-cross-origin"
Header always set Content-Security-Policy "default-src 'self'; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'"
CONF

# --- s3-curl: reach S3 with nothing but curl and the instance role ----------
# Usage: s3-curl <key>          GET  s3://<bucket>/<key>
#        s3-curl <key> <file>   PUT  <file> to s3://<bucket>/<key>  (role denies it)
cat > /usr/local/bin/s3-curl <<'SH'
#!/bin/bash
set -euo pipefail
BUCKET="__BUCKET__"
REGION="__REGION__"
IMDS="http://169.254.169.254/latest"
# IMDSv2: get a session token, then the role's temporary credentials
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

# --- novatrix-sync: copy the published site from S3 to Apache --------------
cat > /usr/local/bin/novatrix-sync <<'SH'
#!/bin/bash
aws s3 sync "s3://__BUCKET__/web/" /var/www/html/ --region __REGION__ --only-show-errors
SH
chmod 755 /usr/local/bin/novatrix-sync

cat > /etc/systemd/system/novatrix-sync.service <<'UNIT'
[Unit]
Description=Pull the published Novatrix site from S3
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/novatrix-sync
UNIT

cat > /etc/systemd/system/novatrix-sync.timer <<'UNIT'
[Unit]
Description=Pull the Novatrix site from S3 periodically
[Timer]
OnBootSec=2min
OnUnitActiveSec=__INTERVAL__
[Install]
WantedBy=timers.target
UNIT

# --- som-uppladdare: role chaining -------------------------------------------
# Runs a command as the uploader role. Only works because the instance is
# running with the reader role - that is the only principal the uploader trusts.
# Usage: som-uppladdare aws s3 cp fil.txt s3://<bucket>/loggar/fil.txt
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

cat > /etc/systemd/system/novatrix-loggar.service <<'UNIT'
[Unit]
Description=Archive Apache logs to S3 via the uploader role
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/novatrix-loggar
UNIT

cat > /etc/systemd/system/novatrix-loggar.timer <<'UNIT'
[Unit]
Description=Archive Apache logs to S3 once a day
[Timer]
OnCalendar=daily
Persistent=true
[Install]
WantedBy=timers.target
UNIT

# First sync (retry while the role's credentials become available)
for i in $(seq 1 12); do
  /usr/local/bin/novatrix-sync && [[ -f /var/www/html/index.html ]] && break
  sleep 5
done

systemctl daemon-reload
systemctl enable --now httpd novatrix-sync.timer novatrix-loggar.timer
USERDATA
)
USER_DATA=${USER_DATA//__BUCKET__/$SITE_BUCKET}
USER_DATA=${USER_DATA//__UPLOADER_ARN__/$UPLOADER_ROLE_ARN}
USER_DATA=${USER_DATA//__REGION__/$REGION}
USER_DATA=${USER_DATA//__INTERVAL__/$SYNC_INTERVAL}
USER_DATA=${USER_DATA//__SSHD_COMMON__/$SSHD_COMMON}

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
  echo "Web server already running: $INSTANCE_ID (run V44_cleanup.sh first to relaunch it)"
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
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=Roll,Value=webb},{Key=${TAG_KEY},Value=${TAG_VALUE}}]" \
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
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$BASTION_NAME},{Key=Roll,Value=bastion},{Key=${TAG_KEY},Value=${TAG_VALUE}}]" \
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
echo "Done! The website is up in 1-2 minutes (user data runs at boot)."
echo "  Website:  http://$PUBLIC_IP   and   https://$PUBLIC_IP  (self-signed certificate)"
echo "  Bastion:  ssh -i $KEY_FILE ec2-user@$BASTION_IP"
echo "  Web (only via the bastion):"
echo "            ssh -i $KEY_FILE -o ProxyCommand=\"ssh -i $KEY_FILE -W %h:%p ec2-user@$BASTION_IP\" ec2-user@$PRIVATE_IP"
echo "  On EC2:   s3-curl web/index.html      (read S3 with plain curl + the role)"
echo "            sudo systemctl start novatrix-sync   (pull changes now instead of every $SYNC_INTERVAL)"
echo "            som-uppladdare aws sts get-caller-identity   (role chaining: reader -> uploader)"
echo "            sudo systemctl start novatrix-loggar (archive Apache logs now instead of daily)"
echo
echo "Tip:      stop the bastion when you are not administering - nothing else needs it:"
echo "            aws ec2 stop-instances --instance-ids $BASTION_ID --region $REGION"
echo "Next:     ./V44_verify.sh     (tests every permission, the chain AND the network)"
echo "Clean up: ./V44_cleanup.sh"
