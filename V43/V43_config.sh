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
