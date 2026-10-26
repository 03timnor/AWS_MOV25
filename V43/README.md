# IAM och identitet

Repository: https://github.com/03timnor/AWS_MOV25

*Tim Noreliusson Lingestedt, 2026-10-26*

Veckans uppgift går ut på att konfigurera *IAM*, grupper och policies i *AWS* enligt *Least privilege*.

För att uppnå nivån Väl Godkänt skall detta göras automatiserat med kod, använda flera samverkande *IAM*-roller, använda genomtänkt *Least privilege* och motivera designen.

## *__1. Provisionera miljön, användare, grupper och policies__*

*V43_novatrix-iam.sh* bygger hela miljön, består av följande kod:

```bash
#!/usr/bin/env bash
# =============================================================================
# Novatrix V43 - IAM with least privilege.
#
# Builds on V42 (Apache on EC2). The site is now Novatrix's general website
# ("under construction") and its content lives in S3. Publishing is a chain:
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
# Run:          ./V43_novatrix-iam.sh       (safe to re-run)
# Verify:       ./V43_verify.sh
# Clean up:     ./V43_cleanup.sh
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
source ./V43_config.sh

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
# Drift: operate the Novatrix server and read logs/metrics. No content, no code.
DRIFT_POLICY=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "OversiktUtanResursniva",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances", "ec2:DescribeInstanceStatus", "ec2:DescribeSecurityGroups",
        "cloudwatch:GetMetricData", "cloudwatch:GetMetricStatistics", "cloudwatch:ListMetrics",
        "logs:DescribeLogGroups"
      ],
      "Resource": "*"
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
# 2. Storage
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
# Resource policy: refuse every request that is not encrypted in transit (TLS).
aws s3api put-bucket-policy --bucket "$SITE_BUCKET" --policy "$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "EndastTLS",
    "Effect": "Deny",
    "Principal": "*",
    "Action": "s3:*",
    "Resource": ["${BUCKET_ARN}", "${BUCKET_ARN}/*"],
    "Condition": { "Bool": { "aws:SecureTransport": "false" } }
  }]
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
# 3. Service roles
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
# 4. Publisher Lambda + S3 trigger
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
# 5. Human access: groups, policies, users
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
# 6. Website: uploaded as drafts, published by the Lambda (the chain in action)
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
# 7. Security group + EC2 instance with the instance profile
# =============================================================================
step "Security group and EC2 instance"
AMI_ID=$(aws ssm get-parameter --region "$REGION" \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value --output text)
MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')
echo "AMI: $AMI_ID   Your IP: $MY_IP"

VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters Name=group-name,Values="$SG_NAME" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text)

if [[ "$SG_ID" == "None" ]]; then
  SG_ID=$(aws ec2 create-security-group --region "$REGION" \
    --group-name "$SG_NAME" --description "Novatrix: HTTP from anywhere, SSH from my IP" \
    --vpc-id "$VPC_ID" --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$SG_ID" --protocol tcp --port 80 --cidr 0.0.0.0/0 > /dev/null
  aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$SG_ID" --protocol tcp --port 22 --cidr "${MY_IP}/32" > /dev/null
  echo "Security group created: $SG_ID"
else
  echo "Security group already exists: $SG_ID"
fi

# User data: Apache + a timer that pulls web/ from S3 + a pure-curl S3 client.
USER_DATA=$(cat <<'USERDATA'
#!/bin/bash
set -e
dnf install -y httpd

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

INSTANCE_ID=$(aws ec2 describe-instances --region "$REGION" \
  --filters Name=tag:Name,Values="$INSTANCE_NAME" Name=instance-state-name,Values=pending,running \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

if [[ "$INSTANCE_ID" != "None" ]]; then
  echo "Instance already running: $INSTANCE_ID (run V43_cleanup.sh first to relaunch it)"
else
  # Retry: a new instance profile is not usable by EC2 for a few seconds.
  INSTANCE_ID=$(retry aws ec2 run-instances --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --associate-public-ip-address \
    --iam-instance-profile Name="$EC2_PROFILE" \
    --credit-specification CpuCredits=standard \
    --metadata-options "HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=1" \
    --user-data "$USER_DATA" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=${TAG_KEY},Value=${TAG_VALUE}}]" \
    --query 'Instances[0].InstanceId' --output text)
  echo "Instance launched: $INSTANCE_ID - waiting for 'running'..."
  aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
fi

PUBLIC_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

echo
echo "Done! The website is up in 1-2 minutes (user data runs at boot)."
echo "  Website:  http://$PUBLIC_IP"
echo "  SSH:      ssh -i $KEY_FILE ec2-user@$PUBLIC_IP"
echo "  On EC2:   s3-curl web/index.html      (read S3 with plain curl + the role)"
echo "            sudo systemctl start novatrix-sync   (pull changes now instead of every $SYNC_INTERVAL)"
echo "            som-uppladdare aws sts get-caller-identity   (role chaining: reader -> uploader)"
echo "            sudo systemctl start novatrix-loggar (archive Apache logs now instead of daily)"
echo
echo "Next:     ./V43_verify.sh     (tests every permission and the whole chain)"
echo "Clean up: ./V43_cleanup.sh"
```

*V43_config.sh* innehåller gemensamma inställningar, består av följande kod:

```bash
# =============================================================================
# Novatrix V43 - shared settings. Sourced by the other V43 scripts, not run.
# =============================================================================

# Stop Git Bash on Windows from rewriting paths like /aws/lambda/... into C:\...
export MSYS_NO_PATHCONV=1

REGION="eu-north-1"                        # Stockholm
TAG_KEY="Projekt"
TAG_VALUE="novatrix"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if [[ -z "$ACCOUNT_ID" ]]; then
  echo "Could not read account id - is the AWS CLI configured (aws configure)?" >&2
  exit 1
fi

# ----- Storage: ONE bucket, three prefixes ----------------------------------
#   utkast/  drafts uploaded by people    (writes trigger the publisher Lambda)
#   web/     published site               (written only by the Lambda, read by EC2)
#   loggar/  Apache log archive           (written only via the uploader role, read by drift)
SITE_BUCKET="novatrix-webb-${ACCOUNT_ID}"
FUNCTION_NAME="novatrix-publicerare"
LOG_GROUP="/aws/lambda/${FUNCTION_NAME}"

# ----- Service roles (machines) ---------------------------------------------
EC2_ROLE="novatrix-web-ec2-role"
EC2_PROFILE="novatrix-web-ec2-profile"
UPLOADER_ROLE="novatrix-uppladdare-role"   # may ONLY be assumed by the EC2 role (role chaining)
LAMBDA_ROLE="novatrix-publicerare-role"
LOG_RETENTION_DAYS=30                      # loggar/ objects are deleted after this many days

# ----- Human access: groups and users (user:group) --------------------------
DRIFT_GROUP="novatrix-drift"
DEV_GROUP="novatrix-utveckling"
MARKNAD_GROUP="novatrix-marknad"
USERS=(
  "anna.drift:${DRIFT_GROUP}"
  "erik.utveckling:${DEV_GROUP}"
  "maja.marknad:${MARKNAD_GROUP}"
)

# ----- EC2 --------------------------------------------------------------------
INSTANCE_TYPE="t3.micro"                   # free tier eligible in eu-north-1
                                           # (launched with CpuCredits=standard: no surplus CPU charges)
KEY_NAME="AWS_MOV25"
KEY_FILE="$HOME/.ssh/${KEY_NAME}.pem"
SG_NAME="novatrix-web-sg"
INSTANCE_NAME="novatrix-webb"
SYNC_INTERVAL="30min"                      # how often EC2 pulls web/ (keeps S3 requests in free tier)

# ----- Derived ARNs -------------------------------------------------------------
BUCKET_ARN="arn:aws:s3:::${SITE_BUCKET}"
FUNCTION_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${FUNCTION_NAME}"
LOG_GROUP_ARN="arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:${LOG_GROUP}"
EC2_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${EC2_ROLE}"
UPLOADER_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${UPLOADER_ROLE}"
LAMBDA_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE}"

# Local scratch folder (relative, so it also works with aws.exe on Windows)
WORK_DIR=".v43_build"
mkdir -p "$WORK_DIR"
```

*V43_verify.sh* verifierar att behörigheterna fungerar, består av följande kod:

```bash
#!/usr/bin/env bash
# =============================================================================
# Novatrix V43 - verifies that the IAM setup works as intended.
#
#   Part 1: IAM policy simulator - every user and role, allowed AND denied cases
#   Part 2: the publishing chain for real - draft -> Lambda -> web/ -> website
#   Part 3: from inside the EC2 instance - S3 with plain curl and the role,
#           and role chaining: reader role -> uploader role -> loggar/
#
# All output is also saved to V43_verifiering_<date>.txt for the report.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")"
source ./V43_config.sh

OUT="V43_verifiering_$(date +%Y%m%d-%H%M).txt"
exec > >(tee "$OUT") 2>&1

PASS=0
FAIL=0
U="arn:aws:iam::${ACCOUNT_ID}:user"

record() {   # expected got description
  if [[ "$1" == "$2" ]]; then PASS=$((PASS + 1)); printf 'OK   '; else FAIL=$((FAIL + 1)); printf 'FEL  '; fi
  printf 'förväntat %-5s fick %-5s %s\n' "$1" "$2" "$3"
}

# check <principal-arn> <action> <resource-arn> <ALLOW|DENY> <description> [context-json]
check() {
  local args=(iam simulate-principal-policy --policy-source-arn "$1" --action-names "$2"
              --resource-arns "$3" --query 'EvaluationResults[0].EvalDecision' --output text)
  [[ -n "${6:-}" ]] && args+=(--context-entries "$6")
  local decision got
  decision=$(aws "${args[@]}" 2>&1)
  case "$decision" in
    allowed)                   got=ALLOW ;;
    implicitDeny|explicitDeny) got=DENY ;;
    *)                         got=ERROR; echo "     $decision" ;;
  esac
  record "$4" "$got" "$2  -  $5"
}

tag_ctx()    { echo "[{\"ContextKeyName\":\"aws:ResourceTag/${TAG_KEY}\",\"ContextKeyValues\":[\"$1\"],\"ContextKeyType\":\"string\"}]"; }
prefix_ctx() { echo "[{\"ContextKeyName\":\"s3:prefix\",\"ContextKeyValues\":[\"$1\"],\"ContextKeyType\":\"string\"}]"; }

INSTANCE_ARN="arn:aws:ec2:${REGION}:${ACCOUNT_ID}:instance/i-0123456789abcdef0"
DRAFT="${BUCKET_ARN}/utkast/index.html"
DRAFT_IMG="${BUCKET_ARN}/utkast/bilder/logo.png"
WEB="${BUCKET_ARN}/web/index.html"
WEB_IMG="${BUCKET_ARN}/web/bilder/logo.png"
LOGG="${BUCKET_ARN}/loggar/i-0123456789abcdef0/access_log.gz"

echo "Novatrix V43 - verifiering $(date '+%Y-%m-%d %H:%M')   konto $ACCOUNT_ID   region $REGION"

# =============================================================================
echo; echo "=== Del 1: IAM policy simulator ==="
# =============================================================================
echo; echo "--- anna.drift (grupp $DRIFT_GROUP) ---"
check "$U/anna.drift" ec2:DescribeInstances "*" ALLOW "se alla instanser"
check "$U/anna.drift" ec2:StopInstances "$INSTANCE_ARN" ALLOW "stoppa instans taggad ${TAG_KEY}=${TAG_VALUE}" "$(tag_ctx "$TAG_VALUE")"
check "$U/anna.drift" ec2:StopInstances "$INSTANCE_ARN" DENY  "stoppa instans från annat projekt" "$(tag_ctx annat)"
check "$U/anna.drift" ec2:TerminateInstances "$INSTANCE_ARN" DENY "terminera Novatrix-instansen" "$(tag_ctx "$TAG_VALUE")"
check "$U/anna.drift" logs:FilterLogEvents "${LOG_GROUP_ARN}:*" ALLOW "läsa publiceringsloggen"
check "$U/anna.drift" s3:GetObject "$LOGG" ALLOW "läsa arkiverad Apache-logg"
check "$U/anna.drift" s3:PutObject "$LOGG" DENY "skriva i loggarkivet"
check "$U/anna.drift" sts:AssumeRole "$UPLOADER_ROLE_ARN" DENY "anta uppladdarrollen"
check "$U/anna.drift" s3:PutObject "$DRAFT" DENY "ändra webbplatsens innehåll"
check "$U/anna.drift" lambda:UpdateFunctionCode "$FUNCTION_ARN" DENY "ändra publicerarens kod"
check "$U/anna.drift" iam:CreateUser "*" DENY "skapa IAM-användare"

echo; echo "--- erik.utveckling (grupp $DEV_GROUP) ---"
check "$U/erik.utveckling" s3:PutObject "$DRAFT" ALLOW "ladda upp utkast"
check "$U/erik.utveckling" s3:GetObject "$WEB" ALLOW "läsa publicerad sida"
check "$U/erik.utveckling" s3:PutObject "$WEB" DENY "publicera förbi publiceraren"
check "$U/erik.utveckling" lambda:UpdateFunctionCode "$FUNCTION_ARN" ALLOW "driftsätta ny publicerarkod"
check "$U/erik.utveckling" lambda:UpdateFunctionConfiguration "$FUNCTION_ARN" DENY "byta roll/inställningar på Lambda"
check "$U/erik.utveckling" iam:PassRole "$LAMBDA_ROLE_ARN" DENY "skicka vidare Lambdarollen"
check "$U/erik.utveckling" ec2:StopInstances "$INSTANCE_ARN" DENY "stoppa servern" "$(tag_ctx "$TAG_VALUE")"
check "$U/erik.utveckling" s3:GetObject "$LOGG" DENY "läsa besökarloggar"

echo; echo "--- maja.marknad (grupp $MARKNAD_GROUP) ---"
check "$U/maja.marknad" s3:PutObject "$DRAFT_IMG" ALLOW "ladda upp bild"
check "$U/maja.marknad" s3:ListBucket "$BUCKET_ARN" ALLOW "lista sina bilder" "$(prefix_ctx utkast/bilder/)"
check "$U/maja.marknad" s3:ListBucket "$BUCKET_ARN" DENY  "lista hela bucketen" "$(prefix_ctx utkast/)"
check "$U/maja.marknad" s3:PutObject "$DRAFT" DENY "ändra sidans HTML"
check "$U/maja.marknad" s3:PutObject "$WEB_IMG" DENY "publicera förbi publiceraren"
check "$U/maja.marknad" s3:DeleteObject "$DRAFT_IMG" DENY "radera bilder"
check "$U/maja.marknad" lambda:UpdateFunctionCode "$FUNCTION_ARN" DENY "ändra publicerarens kod"

echo; echo "--- roll $EC2_ROLE (EC2-instansen) ---"
check "$EC2_ROLE_ARN" s3:GetObject "$WEB" ALLOW "läsa publicerad sajt"
check "$EC2_ROLE_ARN" s3:ListBucket "$BUCKET_ARN" ALLOW "lista web/" "$(prefix_ctx web/)"
check "$EC2_ROLE_ARN" s3:ListBucket "$BUCKET_ARN" DENY  "lista utkast/" "$(prefix_ctx utkast/)"
check "$EC2_ROLE_ARN" s3:GetObject "$DRAFT" DENY "läsa opublicerade utkast"
check "$EC2_ROLE_ARN" s3:PutObject "$WEB" DENY "skriva över sajten"
check "$EC2_ROLE_ARN" s3:ListAllMyBuckets "*" DENY "lista kontots buckets"
check "$EC2_ROLE_ARN" s3:PutObject "$LOGG" DENY "skriva loggar själv (utan att byta roll)"
check "$EC2_ROLE_ARN" sts:AssumeRole "$UPLOADER_ROLE_ARN" ALLOW "begära uppladdarrollen"
check "$EC2_ROLE_ARN" sts:AssumeRole "$LAMBDA_ROLE_ARN" DENY "begära publicerarrollen"

echo; echo "--- roll $UPLOADER_ROLE (antas av EC2-rollen) ---"
check "$UPLOADER_ROLE_ARN" s3:PutObject "$LOGG" ALLOW "ladda upp logg"
check "$UPLOADER_ROLE_ARN" s3:GetObject "$LOGG" DENY "läsa loggar"
check "$UPLOADER_ROLE_ARN" s3:GetObject "$WEB" DENY "läsa publicerad sajt"
check "$UPLOADER_ROLE_ARN" s3:PutObject "$WEB" DENY "skriva över sajten"
check "$UPLOADER_ROLE_ARN" s3:PutObject "$DRAFT" DENY "lägga utkast (starta publicering)"
check "$UPLOADER_ROLE_ARN" s3:ListBucket "$BUCKET_ARN" DENY "lista bucketen" "$(prefix_ctx loggar/)"
check "$UPLOADER_ROLE_ARN" s3:DeleteObject "$LOGG" DENY "radera loggar"

echo; echo "--- roll $LAMBDA_ROLE (publiceraren) ---"
check "$LAMBDA_ROLE_ARN" s3:GetObject "$DRAFT" ALLOW "läsa utkast"
check "$LAMBDA_ROLE_ARN" s3:PutObject "$WEB" ALLOW "publicera till web/"
check "$LAMBDA_ROLE_ARN" logs:PutLogEvents "${LOG_GROUP_ARN}:*" ALLOW "skriva till egen logggrupp"
check "$LAMBDA_ROLE_ARN" logs:PutLogEvents "arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:annan-grupp:*" DENY "skriva till annan logggrupp"
check "$LAMBDA_ROLE_ARN" s3:PutObject "$DRAFT" DENY "skriva utkast (kan inte trigga sig själv)"
check "$LAMBDA_ROLE_ARN" s3:GetObject "$WEB" DENY "läsa publicerad sajt"
check "$LAMBDA_ROLE_ARN" s3:DeleteObject "$WEB" DENY "radera publicerade filer"
check "$LAMBDA_ROLE_ARN" s3:ListBucket "$BUCKET_ARN" DENY "lista bucketen" "$(prefix_ctx web/)"
check "$LAMBDA_ROLE_ARN" ec2:DescribeInstances "*" DENY "se EC2-instanser"

# =============================================================================
echo; echo "=== Del 2: publiceringskedjan (utkast -> Lambda -> web/ -> webbplats) ==="
# =============================================================================
IP=$(aws ec2 describe-instances --region "$REGION" \
  --filters Name=tag:Name,Values="$INSTANCE_NAME" Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

if [[ -z "$IP" || "$IP" == "None" ]]; then
  echo "Ingen körande instans hittades - hoppar över webbplatstesterna."
  IP=""
else
  echo "Webbplats: http://$IP"
  PAGE=$(curl -s -w '\n%{http_code}' "http://$IP/")
  record 200 "$(tail -n1 <<<"$PAGE")" "startsidan svarar (HTTP-status)"
  grep -qi "under konstruktion" <<<"$PAGE" && got=ALLOW || got=DENY
  record ALLOW "$got" "startsidan är välkomstsidan från S3"
fi

STAMP=$(date +%H%M%S)
TEST_OK="v43-test-${STAMP}.html"
TEST_BAD="v43-test-${STAMP}.php"
echo "<p>Publicerad av V43-verifieringen ${STAMP}</p>" > "$WORK_DIR/$TEST_OK"
echo "<?php echo 'ska aldrig publiceras'; ?>" > "$WORK_DIR/$TEST_BAD"
aws s3 cp "$WORK_DIR/$TEST_OK"  "s3://$SITE_BUCKET/utkast/$TEST_OK"  --region "$REGION" --only-show-errors
aws s3 cp "$WORK_DIR/$TEST_BAD" "s3://$SITE_BUCKET/utkast/$TEST_BAD" --region "$REGION" --only-show-errors

published() { aws s3api head-object --bucket "$SITE_BUCKET" --key "web/$1" --region "$REGION" >/dev/null 2>&1; }
got=DENY
for i in $(seq 1 12); do published "$TEST_OK" && { got=ALLOW; break; }; sleep 5; done
record ALLOW "$got" "utkast/$TEST_OK publiceras till web/ av Lambdan"
published "$TEST_BAD" && got=ALLOW || got=DENY
record DENY "$got" "utkast/$TEST_BAD (otillåten filtyp) publiceras inte"

echo; echo "Senaste publiceringsloggen (väntar tills testets rader har levererats till CloudWatch):"
# CloudWatch Logs delivers log lines a few seconds after the Lambda wrote them,
# so poll until both test files show up (max ~60 s).
for i in $(seq 1 12); do
  LAMBDA_LOG=$(aws logs tail "$LOG_GROUP" --region "$REGION" --since 10m 2>&1 | grep -E "publicerad|nekad")
  grep -q "web/$TEST_OK" <<<"$LAMBDA_LOG" && grep -q "$TEST_BAD" <<<"$LAMBDA_LOG" && break
  sleep 5
done
tail -n 6 <<<"$LAMBDA_LOG"
# Real proof of the log permission: these lines were written by the Lambda itself, with its role.
grep -q "web/$TEST_OK" <<<"$LAMBDA_LOG" && got=ALLOW || got=DENY
record ALLOW "$got" "Lambdan skriver sin logg med sin egen roll (raden ovan)"

# Trust policy test for real: even an administrator may NOT assume the uploader
# role, because its trust policy only names the EC2 reader role.
echo
if out=$(aws sts assume-role --role-arn "$UPLOADER_ROLE_ARN" --role-session-name v43-admin-test 2>&1); then
  got=ALLOW
elif grep -qiE "AccessDenied|not authorized" <<<"$out"; then
  got=DENY
else
  got=ERROR; echo "     $out" | head -n 2
fi
record DENY "$got" "du själv (admin, utan läsarrollen) antar uppladdarrollen"

# =============================================================================
echo; echo "=== Del 3: inifrån EC2-instansen (S3 med curl och instansrollen) ==="
# =============================================================================
# LogLevel=ERROR hides the SSH client's own notices (known_hosts, key exchange warnings)
# so they don't mix with the results.
SSH_OPTS=(-i "$KEY_FILE" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o LogLevel=ERROR)
remote()     { ssh "${SSH_OPTS[@]}" ec2-user@"$IP" "$1" 2>&1; }          # stdout+stderr (for checks)
remote_out() { ssh "${SSH_OPTS[@]}" ec2-user@"$IP" "$1" 2>/dev/null; }   # stdout only (for printing)
remote_check() {   # expected description command
  local output got
  if output=$(remote "$3"); then
    got=ALLOW
  elif grep -qiE "AccessDenied|not authorized|Forbidden|\(403\)| 403" <<<"$output"; then
    got=DENY
  else
    got=ERROR; echo "     $output" | head -n 3
  fi
  record "$1" "$got" "$2"
}

if [[ -z "$IP" ]]; then
  echo "Hoppar över (ingen instans)."
elif [[ ! -f "$KEY_FILE" ]]; then
  echo "Hittar inte $KEY_FILE - hoppar över SSH-testerna."
else
  echo "Instansen kör som: $(remote_out "aws sts get-caller-identity --query Arn --output text")"
  R="--region $REGION"
  remote_check ALLOW "curl: läsa web/index.html"      "s3-curl web/index.html | grep -qi konstruktion"
  remote_check DENY  "curl: läsa utkast/index.html"   "s3-curl utkast/index.html"
  remote_check DENY  "curl: skriva till web/"         "echo hack > /tmp/h.html && s3-curl web/hack.html /tmp/h.html"
  remote_check DENY  "cli: lista kontots buckets"     "aws s3 ls $R"
  remote_check DENY  "cli: lista IAM-användare"       "aws iam list-users"
  remote_check ALLOW "ny publicering syns på sajten"  \
    "sudo systemctl start novatrix-sync && curl -sf http://localhost/$TEST_OK | grep -q V43"

  echo; echo "--- Role chaining: läsarrollen -> uppladdarrollen ---"
  echo "Identitet före rollbytet:  $(remote_out "aws sts get-caller-identity --query Arn --output text")"
  echo "Identitet efter rollbytet: $(remote_out "som-uppladdare aws sts get-caller-identity --query Arn --output text")"
  echo
  LT="loggar/verifiering-${STAMP}"
  remote_check DENY  "läsarrollen: skriva logg själv" \
    "echo test | aws s3 cp - s3://$SITE_BUCKET/$LT/direkt.txt $R"
  remote_check ALLOW "läsarrollen antar uppladdarrollen" \
    "som-uppladdare aws sts get-caller-identity --query Arn --output text | grep -q assumed-role/$UPLOADER_ROLE/"
  remote_check ALLOW "uppladdaren: skriva till loggar/" \
    "echo test | som-uppladdare aws s3 cp - s3://$SITE_BUCKET/$LT/via-roll.txt $R"
  remote_check DENY  "uppladdaren: läsa web/" \
    "som-uppladdare aws s3 cp s3://$SITE_BUCKET/web/index.html - $R"
  remote_check DENY  "uppladdaren: skriva till web/" \
    "echo hack | som-uppladdare aws s3 cp - s3://$SITE_BUCKET/web/hack.html $R"
  remote_check DENY  "uppladdaren: lägga utkast" \
    "echo hack | som-uppladdare aws s3 cp - s3://$SITE_BUCKET/utkast/hack.html $R"
  remote_check ALLOW "loggjobbet arkiverar Apache-loggarna" \
    "curl -s -o /dev/null http://localhost/ && sudo systemctl start novatrix-loggar"
  n=$(aws s3api list-objects-v2 --bucket "$SITE_BUCKET" --prefix loggar/i- --region "$REGION" \
        --query 'length(Contents || `[]`)' --output text 2>/dev/null)
  [[ "${n:-0}" =~ ^[0-9]+$ && "${n:-0}" -gt 0 ]] && got=ALLOW || got=DENY
  record ALLOW "$got" "arkiverade loggar finns i s3://$SITE_BUCKET/loggar/ ($n st)"
  aws s3 rm "s3://$SITE_BUCKET/$LT/" --recursive --region "$REGION" --only-show-errors 2>/dev/null
fi

# Remove the test files again (admin credentials)
for k in "utkast/$TEST_OK" "utkast/$TEST_BAD" "web/$TEST_OK"; do
  aws s3 rm "s3://$SITE_BUCKET/$k" --region "$REGION" --only-show-errors 2>/dev/null
done
rm -f "$WORK_DIR/$TEST_OK" "$WORK_DIR/$TEST_BAD"
[[ -n "$IP" && -f "$KEY_FILE" ]] && remote "sudo rm -f /var/www/html/$TEST_OK" >/dev/null || true

echo
echo "=== Resultat: $PASS OK, $FAIL FEL ==="
echo "Sparat i $OUT"
[[ $FAIL -eq 0 ]]
```

*V43_cleanup.sh* raderar hela miljön, består av följande kod:

```bash
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
```

##  *__2. Dokumentation__*

Region: `eu-north-1` (Stockholm). Alla resurser taggas `Projekt=novatrix`. `<konto-id>` är ens 12-siffriga AWS-konto-id.

### Översikt – alla resurser

| Typ | Namn | Syfte | Skapas av |
|---|---|---|---|
| EC2-instans | `novatrix-webb` | Webbserver (Apache) som visar välkomstsidan | `V43_novatrix-iam.sh` |
| Säkerhetsgrupp | `novatrix-web-sg` | Brandvägg för webbservern | `V43_novatrix-iam.sh` |
| Instance profile | `novatrix-web-ec2-profile` | Kopplar läsarrollen till EC2-instansen | `V43_novatrix-iam.sh` |
| S3-bucket | `novatrix-webb-<konto-id>` | Lagring för utkast, publicerad sajt och loggarkiv | `V43_novatrix-iam.sh` |
| Lambda | `novatrix-publicerare` | Kontrollerar och publicerar utkast till sajten | `V43_novatrix-iam.sh` |
| CloudWatch-logggrupp | `/aws/lambda/novatrix-publicerare` | Lambdans logg | `V43_novatrix-iam.sh` |
| IAM-roll | `novatrix-web-ec2-role` | Läsarroll för EC2 | `V43_novatrix-iam.sh` |
| IAM-roll | `novatrix-uppladdare-role` | Uppladdarroll, antas av läsarrollen (role chaining) | `V43_novatrix-iam.sh` |
| IAM-roll | `novatrix-publicerare-role` | Körroll för Lambdan | `V43_novatrix-iam.sh` |
| IAM-grupp | `novatrix-drift` | Drift | `V43_novatrix-iam.sh` |
| IAM-grupp | `novatrix-utveckling` | Utveckling | `V43_novatrix-iam.sh` |
| IAM-grupp | `novatrix-marknad` | Marknad | `V43_novatrix-iam.sh` |
| IAM-användare | `anna.drift` | Medlem i `novatrix-drift` | `V43_novatrix-iam.sh` |
| IAM-användare | `erik.utveckling` | Medlem i `novatrix-utveckling` | `V43_novatrix-iam.sh` |
| IAM-användare | `maja.marknad` | Medlem i `novatrix-marknad` | `V43_novatrix-iam.sh` |
| Managed policy | `novatrix-drift-policy` | Kopplad till `novatrix-drift` | `V43_novatrix-iam.sh` |
| Managed policy | `novatrix-utveckling-policy` | Kopplad till `novatrix-utveckling` | `V43_novatrix-iam.sh` |
| Managed policy | `novatrix-marknad-policy` | Kopplad till `novatrix-marknad` | `V43_novatrix-iam.sh` |

Allt tas bort med `V43_cleanup.sh`.

### S3-bucketens struktur

| Prefix | Innehåll | Skrivs av | Läses av | Övrigt |
|---|---|---|---|---|
| `utkast/` | Nytt innehåll som ska publiceras | Utveckling (allt), marknad (bara `utkast/bilder/`) | Lambdan, utveckling, marknad (bara bilder/) | Uppladdning startar Lambdan |
| `web/` | Den publicerade sajten | Endast Lambdan | EC2 (läsarrollen), utveckling | Bara tillåtna filtyper |
| `loggar/` | Arkiverade Apache-loggar | Endast uppladdarrollen | Drift | Tas bort efter 30 dagar |

| Bucketinställning | Värde | Varför |
|---|---|---|
| Block Public Access | Allt på | Besökare når aldrig S3 direkt, bara via EC2 |
| Bucket policy | Deny om `aws:SecureTransport = false` | All trafik måste gå över TLS |
| Händelse | `s3:ObjectCreated:*` på `utkast/` → Lambda | Startar publiceringen |
| Livscykelregel | `loggar/` raderas efter 30 dagar | Håller nere lagring och kostnad |

### IAM-roller (tjänster)

| Roll | Trust policy (vem får anta den) | Rättigheter | Får inte |
|---|---|---|---|
| `novatrix-web-ec2-role` (läsare) | `ec2.amazonaws.com` | `s3:ListBucket` med `s3:prefix = web/*`<br>`s3:GetObject` på `web/*`<br>`sts:AssumeRole` på uppladdarrollen | Skriva något, läsa utkast eller loggar, lista andra buckets |
| `novatrix-uppladdare-role` | Endast rollen `novatrix-web-ec2-role` | `s3:PutObject` på `loggar/*` | Läsa något, skriva till `web/` eller `utkast/`, radera, lista |
| `novatrix-publicerare-role` | `lambda.amazonaws.com` | `s3:GetObject` på `utkast/*`<br>`s3:PutObject` på `web/*`<br>`logs:CreateLogStream`, `logs:PutLogEvents` på sin egen logggrupp | Läsa `web/`, skriva `utkast/` (kan inte trigga sig själv), radera, lista, nå andra tjänster |

| Resursbaserad policy | Var | Tillåter | Villkor |
|---|---|---|---|
| `s3-utkast` | På Lambdan `novatrix-publicerare` | `s3.amazonaws.com` får `lambda:InvokeFunction` | `SourceArn` = vår bucket, `SourceAccount` = vårt konto (skydd mot confused deputy) |
| `EndastTLS` | På S3-bucketen | Nekar alla anrop utan TLS | `aws:SecureTransport = false` |

### IAM-grupper och användare (människor)

Användarna får rättigheter **endast** via sin grupp. Inga lösenord eller åtkomstnycklar skapas.

| Grupp | Användare | Får | Får inte |
|---|---|---|---|
| `novatrix-drift` | `anna.drift` | Se instanser och säkerhetsgrupper<br>Starta, stoppa och starta om instanser taggade `Projekt=novatrix`<br>Läsa Lambdans logg och CloudWatch-mätvärden<br>Lista och läsa `loggar/` | Terminera instanser, ändra innehåll eller kod, skriva i loggarkivet, anta uppladdarrollen, IAM |
| `novatrix-utveckling` | `erik.utveckling` | Lista, läsa, skriva och radera i `utkast/`<br>Läsa `web/`<br>`lambda:GetFunction`, `lambda:UpdateFunctionCode` på publiceraren<br>Läsa Lambdans logg | Skriva direkt till `web/`, läsa `loggar/` (besökares IP), ändra Lambdans roll eller inställningar, `iam:PassRole`, se eller styra EC2 |
| `novatrix-marknad` | `maja.marknad` | Lista, läsa och skriva i `utkast/bilder/` | Ändra HTML och CSS, radera, skriva till `web/`, se resten av bucketen, Lambda |

### IAM-översikt

Heldragen pil = rättighet. Streckad pil = vem som får anta en roll (trust policy) eller starta Lambdan (resource policy).

```mermaid
flowchart LR
    subgraph manniskor["Människor · användare → grupp → policy"]
        anna["anna.drift"] --> gd["Grupp<br/>novatrix-drift"] --> pd["novatrix-drift-policy<br/>EC2 start/stopp/reboot om tagg novatrix<br/>läsa loggar"]
        erik["erik.utveckling"] --> gu["Grupp<br/>novatrix-utveckling"] --> pu["novatrix-utveckling-policy<br/>hantera utkast/* · läsa web/*<br/>UpdateFunctionCode"]
        maja["maja.marknad"] --> gm["Grupp<br/>novatrix-marknad"] --> pm["novatrix-marknad-policy<br/>ladda upp i utkast/bilder/*"]
    end

    subgraph tjanster["Tjänster · trust policy → roll"]
        ec2t["ec2.amazonaws.com"] -.->|"trust"| rl["novatrix-web-ec2-role · läsare<br/>läsa web/* · AssumeRole uppladdare"]
        rl -.->|"trust: endast läsarrollen"| ru["novatrix-uppladdare-role<br/>skriva loggar/*"]
        lt["lambda.amazonaws.com"] -.->|"trust"| rp["novatrix-publicerare-role<br/>läsa utkast/* · skriva web/* · egen logg"]
    end

    subgraph res["Resurser"]
        ec2r["EC2 novatrix-webb"]
        s3u[("S3 utkast/")]
        s3w[("S3 web/")]
        s3l[("S3 loggar/")]
        lam["Lambda novatrix-publicerare"]
        cwl["CloudWatch Logs"]
    end

    pd --> ec2r
    pd --> cwl
    pd -->|"läsa"| s3l
    pu --> s3u
    pu -->|"läsa"| s3w
    pu --> lam
    pm --> s3u
    rl -->|"läsa"| s3w
    ru -->|"skriva"| s3l
    rp -->|"läsa"| s3u
    rp -->|"skriva"| s3w
    rp --> cwl
    s3u -.->|"resource policy: InvokeFunction"| lam
```

### Behörighetskedjor

#### Publicering

| Steg | Vem | Identitet | Åtgärd | Resultat |
|---|---|---|---|---|
| 1 | Utveckling / marknad | IAM-användare via grupp | `s3:PutObject` till `utkast/` | Fil ligger som utkast |
| 2 | S3 | Resursbaserad policy på Lambdan | `lambda:InvokeFunction` | Lambdan startas |
| 3 | Lambda | `novatrix-publicerare-role` | `GetObject utkast/` → kontroll av filtyp och storlek → `PutObject web/` | Godkända filer publiceras, övriga nekas och loggas |
| 4 | EC2 | `novatrix-web-ec2-role` | `ListBucket` + `GetObject` på `web/` var 30:e minut | Apache visar ny version |

#### Role chaining (loggarkivering)

| Steg | Identitet | Åtgärd | Resultat |
|---|---|---|---|
| 1 | `novatrix-web-ec2-role` (läsare) | `sts:AssumeRole` på uppladdarrollen | STS kontrollerar uppladdarens trust policy: anroparen är läsarrollen, så det godkänns |
| 2 | `novatrix-uppladdare-role` | Tillfälliga nycklar i 15 minuter | Kan bara skriva till `loggar/` |
| 3 | `novatrix-uppladdare-role` | `s3:PutObject` på `loggar/<instans-id>/…` | Apache-loggarna arkiveras |

Uppladdarrollen kan **bara** antas av en session som redan kör med läsarrollen, alltså EC2-instansen. Varken användarna eller en administratör kan anta den.

### Nätverk och EC2

| Inställning | Värde | Varför |
|---|---|---|
| Instanstyp | `t3.micro` | Free tier |
| CPU-kredit | `standard` | Ingen extra kostnad vid hög CPU-last |
| AMI | Senaste Amazon Linux 2023 (via SSM-parameter) | Senaste versionen när instansen startas, och gratis |
| VPC | Kontots standard-VPC | Ingen NAT gateway behövs |
| Publik IPv4 | Ja (automatisk) | Nåbar för besökare och SSH |
| IMDS | v2 krävs, hop limit 1 | Försvårar stöld av rollens nycklar via SSRF |
| Säkerhetsgrupp, port 80 | `0.0.0.0/0` | Webbplatsen är publik |
| Säkerhetsgrupp, port 22 | Din IP `/32` | SSH bara från ens dator |
| Nyckelpar | `AWS_MOV25` | SSH-inloggning |

### Komponenter på EC2-instansen

| Komponent | Typ | Vad den gör | Körs |
|---|---|---|---|
| `httpd` | Tjänst | Apache, visar `/var/www/html` | Alltid |
| `/usr/local/bin/novatrix-sync` | Script | `aws s3 sync` från `web/` till `/var/www/html` | Via timer |
| `novatrix-sync.timer` | systemd-timer | Startar synken | 2 min efter uppstart, sedan var 30:e minut |
| `/usr/local/bin/s3-curl` | Script | Läser S3 med bara curl, IMDSv2 och SigV4 (skrivning nekas av rollen)| Manuellt |
| `/usr/local/bin/som-uppladdare` | Script | Antar uppladdarrollen och kör ett kommando som den (role chaining) | Manuellt och av loggjobbet |
| `/usr/local/bin/novatrix-loggar` | Script | Komprimerar och laddar upp Apache-loggar till `loggar/` | Via timer |
| `novatrix-loggar.timer` | systemd-timer | Startar loggjobbet | En gång per dygn |

### Kostnad

| Resurs | Kostnad | Kommentar |
|---|---|---|
| EC2 `t3.micro` | ca $0.011/timme | Free tier-berättigad, dras från credits på nya konton |
| Publik IPv4 | $0.005/timme | Bara när instansen kör |
| EBS 8 GB gp3 | ca $0.02/dygn | Instansens disk |
| S3 | Försumbar | Några kB data, ca 1 500 LIST-anrop/månad |
| Lambda | Gratis | Inom 1 miljon anrop/månad |
| CloudWatch Logs | Gratis | 7 dagars lagring, långt under 5 GB |
| IAM, STS | Gratis | |
| **Totalt** | **ca $0.40/dygn** | Ett testpass på 1–2 timmar kostar några cent |

### Script

| Script | Syfte |
|---|---|
| `V43_config.sh` | Gemensamma namn, ARN:er och inställningar. Läses in av de andra, körs inte själv. |
| `V43_novatrix-iam.sh` | Skapar hela miljön. Kan köras om. |
| `V43_verify.sh` | Testar alla behörigheter och sparar resultatet i `V43_verifiering_<datum>.txt`. |
| `V43_cleanup.sh` | Tar bort allt. Bekräftas med `JA`. |

### Verifiering

| Del | Metod | Antal tester | Vad som visas |
|---|---|---|---|
| 1 | IAM Policy Simulator | 51 | Varje användare och roll: både tillåtna och nekade åtgärder, inklusive villkor (tagg, prefix) |
| 2 | Riktiga anrop från ens dator | 6 | Sajten svarar, `.html` publiceras, `.php` stoppas, Lambdan loggar med sin roll, admin nekas att anta uppladdarrollen |
| 3 | Riktiga anrop inifrån EC2 via SSH | 14 | `s3-curl` läser `web/` men nekas annat, ny publicering syns, role chaining före och efter, uppladdarens begränsningar, loggarkivering |
| **Totalt** | | **71** | Mål: `71 OK, 0 FEL` |

### Mappstruktur

#### Repository

```text
AWS_MOV25/
├── .gitignore                             # utesluter .v43_build/ och *.pem
├── README.md                              # översikt över repot
├── V42/                                   # förra veckans uppgift
│   ├── images/
│   ├── README.md
│   └── V42_novatrix-ec2.sh
└── V43/
    ├── README.md                          # beskrivning, motivering och verifiering
    ├── V43_config.sh                      # gemensamma namn och inställningar
    ├── V43_novatrix-iam.sh                # skapar hela miljön
    ├── V43_verify.sh                      # 71 tester av behörigheterna
    ├── V43_cleanup.sh                     # tar bort allt
    ├── V43_verifiering_20261024-1258.txt  # resultat från V43_verify.sh
    └── pictures/                          # skärmdumpar från verifieringen

Webbsidan och Lambdakoden finns inbäddade i `V43_novatrix-iam.sh` och skapas
tillfälligt i `.v43_build/` när scriptet körs. Den mappen tas bort av `V43_cleanup.sh` och ingår inte i repot.
```

#### S3-bucketen

```text
s3://novatrix-webb-<konto-id>/
├── utkast/                       # människor laddar upp → startar Lambdan
│   ├── index.html                #   utveckling
│   ├── style.css                 #   utveckling
│   └── bilder/                   #   marknad får bara skriva här
│       └── kran.svg
├── web/                          # publicerad sajt, skrivs bara av Lambdan
│   ├── index.html                #   läses av EC2 (läsarrollen)
│   ├── style.css
│   └── bilder/
│       └── kran.svg
└── loggar/                       # skrivs bara av uppladdarrollen, raderas efter 30 dagar
    └── <instans-id>/
        ├── <tid>-access_log.gz
        └── <tid>-error_log.gz
```

#### EC2-instansen

```text
/
├── var/www/html/                 # sajten, synkas från s3://…/web/
├── var/log/httpd/                # Apache-loggar, arkiveras till s3://…/loggar/
├── usr/local/bin/
│   ├── novatrix-sync             # aws s3 sync web/ → /var/www/html
│   ├── novatrix-loggar           # laddar upp Apache-loggar via uppladdarrollen
│   ├── som-uppladdare            # role chaining: läsare → uppladdare
│   └── s3-curl                   # läser S3 med bara curl och instansrollen
└── etc/systemd/system/
    ├── novatrix-sync.timer       # var 30:e minut
    ├── novatrix-sync.service
    ├── novatrix-loggar.timer     # en gång per dygn
    └── novatrix-loggar.service
```

### Arkitektur

```mermaid
flowchart LR
    besok["Besökare<br/>webbläsare"]
    admin["Admin / drift<br/>SSH"]
    team["Utveckling · marknad<br/>S3-konsol eller CLI"]

    subgraph aws["AWS-konto · eu-north-1 Stockholm"]
        subgraph vpc["Standard-VPC"]
            subgraph sg["Säkerhetsgrupp novatrix-web-sg"]
                ec2["EC2 novatrix-webb<br/>t3.micro · Amazon Linux 2023<br/>Apache · novatrix-sync · novatrix-loggar"]
            end
        end

        subgraph s3["S3 novatrix-webb-KONTO-ID · privat · endast TLS"]
            utkast[("utkast/")]
            web[("web/")]
            loggar[("loggar/")]
        end

        lambda["Lambda novatrix-publicerare<br/>Python 3.12"]
        cw["CloudWatch Logs<br/>/aws/lambda/novatrix-publicerare"]
        sts["AWS STS"]
    end

    besok -->|"HTTP :80 · öppen"| ec2
    admin -->|"SSH :22 · bara din IP"| ec2
    team -->|"laddar upp utkast"| utkast
    utkast -->|"S3-händelse startar"| lambda
    lambda -->|"läser"| utkast
    lambda -->|"publicerar"| web
    lambda -->|"skriver logg"| cw
    web -->|"synkas var 30:e min"| ec2
    ec2 -->|"AssumeRole"| sts
    sts -.->|"tillfälliga nycklar<br/>uppladdarrollen"| ec2
    ec2 -->|"Apache-loggar dagligen"| loggar
```

##  *__3. Least privilege och motivering__*

Miljön är uppbyggd så att varje identitet och tjänst endast får de behörigheter den behöver, bara på de resurser som den behöver och bara under de villkor som gäller. Vilket är syftet med *Least privilege* och ingår även i samtliga delar av motiveringen.

Användarnas behörigheter hanteras via grupper, när en ny medarbetare börjar läggs deras användarkonto med i en grupp som delar ut behörigheter. Detta gör alla behörigheter mer spårbara, enklare att hantera och att hålla koll på.

Grundprincipen är simpel, behövs det inte så skall man inte ha det. Det är den centrala argumentationen för designen nedan:

| Princip | Hur den används | Exempel |
|---|---|---|
| **Bara nödvändiga åtgärder** | Inga jokertecken som `s3:*` eller `ec2:*`, varje åtgärd listas för sig | Drift får `Start/Stop/RebootInstances`, men inte `TerminateInstances` |
| **Bara nödvändiga resurser** | Rättigheter låsta till prefix och enskilda resurser | Marknad får bara `utkast/bilder/*`, och utveckling bara funktionen `novatrix-publicerare` |
| **Villkor** | Taggar och prefix styr när en rättighet gäller | Drift styr bara instanser taggade `Projekt=novatrix`. EC2 får bara lista `web/` |
| **Separation of duties** | Varje grupp har en uppgift, ingen har två | Drift kör servern, utveckling bygger, marknad levererar bilder |
| **Dataflöde åt ett håll** | Ingen komponent läser och skriver samma prefix | Lambdan läser `utkast/` och skriver `web/`, aldrig tvärtom, och kan därför inte trigga sig själv |
| **En kontrollpunkt** | Ingen människa kan skriva till sajten direkt | Allt går via Lambdan, som stoppar otillåtna filtyper (t.ex. `.php`) |
| **Skrivrätt bara vid behov** | Role chaining: skrivrätten finns i en separat roll som måste begäras | Läsarrollen kan inte skriva. Den måste anta uppladdarrollen, som gäller i 15 minuter och bara för `loggar/` |
| **Begränsat vem som får anta roller** | Trust policies och resource policies | Bara läsarrollen får anta uppladdarrollen. Bara vår bucket i vårt konto får starta Lambdan |
| **Inga fasta nycklar** | Tjänster får tillfälliga nycklar via roller | EC2 och Lambda har inga sparade nycklar. IMDSv2 skyddar EC2:s nycklar |
| **Ingen eskalering** | Ingen kan ge sig själv mer rätt | Utveckling saknar `iam:PassRole` och `UpdateFunctionConfiguration` och kan inte byta Lambdans roll |

Denna design med *Least privilege* som utgångspunkt bidrar till en miljö med mindre *Blast raduis* om ett konto eller tjänst blir hackad och gör miljön säkrare. *Least privilege* behöver följa med när miljön utvecklas.

##  *__4. Verifiering__*:

### Hemsida kan nås:

![alt text](pictures/novatrix_website.png)

### IAM simulator *Drift*:

![alt text](pictures/iam_drift_example.png)

### IAM simulator *Utveckling*:

![alt text](pictures/iam_utveckling_example_1.png)

![alt text](pictures/iam_utveckling_example_2.png)

![alt text](pictures/iam_utveckling_example_3.png)

### IAM simulator *Marknad*:

![alt text](pictures/iam_marknad_example_1.png)

![alt text](pictures/iam_marknad_example_2.png)

### IAM simulator *EC2*:

![alt text](pictures/iam_ec2_example.png)

### IAM simulator *Publicerare*:

![alt text](pictures/iam_publicerare_example_1.png)

![alt text](pictures/iam_publicerare_example_2.png)

### IAM simulator *Uppladdare*:

![alt text](pictures/iam_uppladdare_example_1.png)

![alt text](pictures/iam_uppladdare_example_2.png)

### Console *Drift*:

![alt text](pictures/drift_console_example_1.png)

![alt text](pictures/drift_console_example_2.png)

![alt text](pictures/drift_console_example_3.png)

### Console *Utveckling*:

![alt text](pictures/utveckling_console_example_1.png)

![alt text](pictures/utveckling_console_example_2.png)

![alt text](pictures/utveckling_console_example_3.png)

![alt text](pictures/utveckling_console_example_4.png)

![alt text](pictures/utveckling_console_example_5.png)

### Console *Marknad*:

![alt text](pictures/marknad_console_example_1.png)

![alt text](pictures/marknad_console_example_2.png)

![alt text](pictures/marknad_console_example_3.png)

### EC2:

![alt text](pictures/ec2_verified_example.png)

### Role chaining:

![alt text](pictures/role_chaining_example.png)

![alt text](pictures/iam_role_chaining_example_1.png)

![alt text](pictures/iam_role_chaining_example_2.png)

### Verification script result:

![alt text](pictures/all_verified.png)

```text
Novatrix V43 - verifiering 2026-10-24 12:58   konto XXXXXXXXXXXX   region eu-north-1

=== Del 1: IAM policy simulator ===

--- anna.drift (grupp novatrix-drift) ---
OK   förväntat ALLOW fick ALLOW ec2:DescribeInstances  -  se alla instanser
OK   förväntat ALLOW fick ALLOW ec2:StopInstances  -  stoppa instans taggad Projekt=novatrix
OK   förväntat DENY  fick DENY  ec2:StopInstances  -  stoppa instans från annat projekt
OK   förväntat DENY  fick DENY  ec2:TerminateInstances  -  terminera Novatrix-instansen
OK   förväntat ALLOW fick ALLOW logs:FilterLogEvents  -  läsa publiceringsloggen
OK   förväntat ALLOW fick ALLOW s3:GetObject  -  läsa arkiverad Apache-logg
OK   förväntat DENY  fick DENY  s3:PutObject  -  skriva i loggarkivet
OK   förväntat DENY  fick DENY  sts:AssumeRole  -  anta uppladdarrollen
OK   förväntat DENY  fick DENY  s3:PutObject  -  ändra webbplatsens innehåll
OK   förväntat DENY  fick DENY  lambda:UpdateFunctionCode  -  ändra publicerarens kod
OK   förväntat DENY  fick DENY  iam:CreateUser  -  skapa IAM-användare

--- erik.utveckling (grupp novatrix-utveckling) ---
OK   förväntat ALLOW fick ALLOW s3:PutObject  -  ladda upp utkast
OK   förväntat ALLOW fick ALLOW s3:GetObject  -  läsa publicerad sida
OK   förväntat DENY  fick DENY  s3:PutObject  -  publicera förbi publiceraren
OK   förväntat ALLOW fick ALLOW lambda:UpdateFunctionCode  -  driftsätta ny publicerarkod
OK   förväntat DENY  fick DENY  lambda:UpdateFunctionConfiguration  -  byta roll/inställningar på Lambda
OK   förväntat DENY  fick DENY  iam:PassRole  -  skicka vidare Lambdarollen
OK   förväntat DENY  fick DENY  ec2:StopInstances  -  stoppa servern
OK   förväntat DENY  fick DENY  s3:GetObject  -  läsa besökarloggar

--- maja.marknad (grupp novatrix-marknad) ---
OK   förväntat ALLOW fick ALLOW s3:PutObject  -  ladda upp bild
OK   förväntat ALLOW fick ALLOW s3:ListBucket  -  lista sina bilder
OK   förväntat DENY  fick DENY  s3:ListBucket  -  lista hela bucketen
OK   förväntat DENY  fick DENY  s3:PutObject  -  ändra sidans HTML
OK   förväntat DENY  fick DENY  s3:PutObject  -  publicera förbi publiceraren
OK   förväntat DENY  fick DENY  s3:DeleteObject  -  radera bilder
OK   förväntat DENY  fick DENY  lambda:UpdateFunctionCode  -  ändra publicerarens kod

--- roll novatrix-web-ec2-role (EC2-instansen) ---
OK   förväntat ALLOW fick ALLOW s3:GetObject  -  läsa publicerad sajt
OK   förväntat ALLOW fick ALLOW s3:ListBucket  -  lista web/
OK   förväntat DENY  fick DENY  s3:ListBucket  -  lista utkast/
OK   förväntat DENY  fick DENY  s3:GetObject  -  läsa opublicerade utkast
OK   förväntat DENY  fick DENY  s3:PutObject  -  skriva över sajten
OK   förväntat DENY  fick DENY  s3:ListAllMyBuckets  -  lista kontots buckets
OK   förväntat DENY  fick DENY  s3:PutObject  -  skriva loggar själv (utan att byta roll)
OK   förväntat ALLOW fick ALLOW sts:AssumeRole  -  begära uppladdarrollen
OK   förväntat DENY  fick DENY  sts:AssumeRole  -  begära publicerarrollen

--- roll novatrix-uppladdare-role (antas av EC2-rollen) ---
OK   förväntat ALLOW fick ALLOW s3:PutObject  -  ladda upp logg
OK   förväntat DENY  fick DENY  s3:GetObject  -  läsa loggar
OK   förväntat DENY  fick DENY  s3:GetObject  -  läsa publicerad sajt
OK   förväntat DENY  fick DENY  s3:PutObject  -  skriva över sajten
OK   förväntat DENY  fick DENY  s3:PutObject  -  lägga utkast (starta publicering)
OK   förväntat DENY  fick DENY  s3:ListBucket  -  lista bucketen
OK   förväntat DENY  fick DENY  s3:DeleteObject  -  radera loggar

--- roll novatrix-publicerare-role (publiceraren) ---
OK   förväntat ALLOW fick ALLOW s3:GetObject  -  läsa utkast
OK   förväntat ALLOW fick ALLOW s3:PutObject  -  publicera till web/
OK   förväntat ALLOW fick ALLOW logs:PutLogEvents  -  skriva till egen logggrupp
OK   förväntat DENY  fick DENY  logs:PutLogEvents  -  skriva till annan logggrupp
OK   förväntat DENY  fick DENY  s3:PutObject  -  skriva utkast (kan inte trigga sig själv)
OK   förväntat DENY  fick DENY  s3:GetObject  -  läsa publicerad sajt
OK   förväntat DENY  fick DENY  s3:DeleteObject  -  radera publicerade filer
OK   förväntat DENY  fick DENY  s3:ListBucket  -  lista bucketen
OK   förväntat DENY  fick DENY  ec2:DescribeInstances  -  se EC2-instanser

=== Del 2: publiceringskedjan (utkast -> Lambda -> web/ -> webbplats) ===
Webbplats: http://16.170.251.154
OK   förväntat 200   fick 200   startsidan svarar (HTTP-status)
OK   förväntat ALLOW fick ALLOW startsidan är välkomstsidan från S3
OK   förväntat ALLOW fick ALLOW utkast/v43-test-125949.html publiceras till web/ av Lambdan
OK   förväntat DENY  fick DENY  utkast/v43-test-125949.php (otillåten filtyp) publiceras inte

Senaste publiceringsloggen (väntar tills testets rader har levererats till CloudWatch):
2026-10-24T10:52:44.756000+00:00 2026/10/24/[$LATEST]9281cef51f85409f8bdeac7d6dd84801 {"publicerad": "web/index.html", "bytes": 1149}
2026-10-24T10:52:44.971000+00:00 2026/10/24/[$LATEST]9281cef51f85409f8bdeac7d6dd84801 {"publicerad": "web/style.css", "bytes": 1518}
2026-10-24T10:52:46.624000+00:00 2026/10/24/[$LATEST]9281cef51f85409f8bdeac7d6dd84801 {"publicerad": "web/bilder/kran.svg", "bytes": 728}
2026-10-24T10:59:51.618000+00:00 2026/10/24/[$LATEST]eebef73bffa6464ea67b4e1f0b578f4f {"publicerad": "web/v43-test-125949.html", "bytes": 46}
2026-10-24T10:59:52.270000+00:00 2026/10/24/[$LATEST]eebef73bffa6464ea67b4e1f0b578f4f {"nekad": "utkast/v43-test-125949.php", "orsak": "filtypen .php publiceras inte"}
OK   förväntat ALLOW fick ALLOW Lambdan skriver sin logg med sin egen roll (raden ovan)

OK   förväntat DENY  fick DENY  du själv (admin, utan läsarrollen) antar uppladdarrollen

=== Del 3: inifrån EC2-instansen (S3 med curl och instansrollen) ===
Instansen kör som: arn:aws:sts::XXXXXXXXXXXX:assumed-role/novatrix-web-ec2-role/i-0ce271f9672b5cd55
OK   förväntat ALLOW fick ALLOW curl: läsa web/index.html
OK   förväntat DENY  fick DENY  curl: läsa utkast/index.html
OK   förväntat DENY  fick DENY  curl: skriva till web/
OK   förväntat DENY  fick DENY  cli: lista kontots buckets
OK   förväntat DENY  fick DENY  cli: lista IAM-användare
OK   förväntat ALLOW fick ALLOW ny publicering syns på sajten

--- Role chaining: läsarrollen -> uppladdarrollen ---
Identitet före rollbytet:  arn:aws:sts::XXXXXXXXXXXX:assumed-role/novatrix-web-ec2-role/i-0ce271f9672b5cd55
Identitet efter rollbytet: arn:aws:sts::XXXXXXXXXXXX:assumed-role/novatrix-uppladdare-role/uppladdare-ip-172-31-38-203

OK   förväntat DENY  fick DENY  läsarrollen: skriva logg själv
OK   förväntat ALLOW fick ALLOW läsarrollen antar uppladdarrollen
OK   förväntat ALLOW fick ALLOW uppladdaren: skriva till loggar/
OK   förväntat DENY  fick DENY  uppladdaren: läsa web/
OK   förväntat DENY  fick DENY  uppladdaren: skriva till web/
OK   förväntat DENY  fick DENY  uppladdaren: lägga utkast
OK   förväntat ALLOW fick ALLOW loggjobbet arkiverar Apache-loggarna
OK   förväntat ALLOW fick ALLOW arkiverade loggar finns i s3://novatrix-webb-XXXXXXXXXXXX/loggar/ (2 st)

=== Resultat: 71 OK, 0 FEL ===
Sparat i V43_verifiering_20261024-1258.txt
```