# =============================================================================
# Novatrix V45 - shared settings. Sourced by the other V45 scripts, not run.
# =============================================================================

# Stop Git Bash on Windows from rewriting paths like /aws/lambda/... into C:\...
export MSYS_NO_PATHCONV=1

# aws.exe on Windows ends its text output lines with \r\n. Bash only strips the
# \n, so values arrive as e.g. "True\r" and comparisons silently fail. Strip
# every \r from AWS CLI output (pipefail in the scripts keeps aws's exit code).
aws() { command aws "$@" | tr -d '\r'; }

REGION="eu-north-1"                        # Stockholm
TAG_KEY="Projekt"
TAG_VALUE="novatrix"
VERSION_TAG="V45"                          # web servers launched by older labs are replaced

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if [[ -z "$ACCOUNT_ID" ]]; then
  echo "Could not read account id - is the AWS CLI configured (aws configure)?" >&2
  exit 1
fi

# ----- Infrastructure as code: V45_infra.yaml ----------------------------------
# Same stack as V44: deploying V45 updates the network in place and ADDS the
# database (RDS) and the shared storage (EFS) to it.
STACK_NAME="novatrix-natverk"
INFRA_TEMPLATE="V45_infra.yaml"
FLOW_LOG_GROUP="/novatrix/vpc-flodesloggar"
FLOW_LOG_GROUP_ARN="arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:${FLOW_LOG_GROUP}"

# ----- Database (RDS MariaDB, private subnets data-a/data-b) -------------------
DB_INSTANCE_ID="novatrix-db"
DB_INSTANCE_CLASS="db.t4g.micro"           # smallest Graviton class, free tier / Free plan
DB_STORAGE_GB=20                           # gp2, the free tier allowance (and RDS minimum)
DB_BACKUP_RETENTION_DAYS=1                 # Free plan maximum (see the documentation)
DB_PORT=3306                               # MariaDB
DB_NAME="wordpress"
DB_MASTER_USER="novatrixadmin"             # only used once, to create the WordPress user
DB_APP_USER="wordpress"                    # WordPress's own user: ONLY the wordpress database

# Secrets live in SSM Parameter Store as SecureString (free standard tier,
# encrypted with the AWS managed key aws/ssm). Never in the scripts or the repo.
# NOTE: the master password name is also written in V45_infra.yaml
# ({{resolve:ssm-secure:...}}) - change both together.
DB_MASTER_PW_PARAM="/novatrix/db/master-losenord"
DB_APP_PW_PARAM="/novatrix/db/wordpress-losenord"
WP_ADMIN_PW_PARAM="/novatrix/wordpress/admin-losenord"
SECRET_PARAMS=("$DB_MASTER_PW_PARAM" "$DB_APP_PW_PARAM" "$WP_ADMIN_PW_PARAM")

# ----- WordPress ----------------------------------------------------------------
WP_TITLE="Novatrix"
WP_ADMIN_USER="novatrix-admin"
WP_ADMIN_EMAIL="admin@novatrix.example"
WP_LOCALE="sv_SE"
WP_ROOT="/var/www/html"                    # EFS mount point on the web server
STATIC_URL_PATH="/statiskt"                # static content from S3 web/ is served here

# ----- Storage: ONE bucket, four prefixes ----------------------------------------
#   utkast/  drafts uploaded by people    (writes trigger the publisher Lambda)
#   web/     published static content     (written only by the Lambda, read by EC2)
#   loggar/  Apache log archive           (written only via the uploader role)
#   backup/  database dumps + wp-content  (written only via the uploader role,
#                                          deleted automatically after 14 days)
SITE_BUCKET="novatrix-webb-${ACCOUNT_ID}"
FUNCTION_NAME="novatrix-publicerare"
LOG_GROUP="/aws/lambda/${FUNCTION_NAME}"
LOG_RETENTION_DAYS=30                      # loggar/ objects are deleted after this many days
BACKUP_RETENTION_DAYS=14                   # backup/ objects are deleted after this many days

# ----- Service roles (machines) ---------------------------------------------
EC2_ROLE="novatrix-web-ec2-role"
EC2_PROFILE="novatrix-web-ec2-profile"
UPLOADER_ROLE="novatrix-uppladdare-role"   # may ONLY be assumed by the EC2 role (role chaining)
LAMBDA_ROLE="novatrix-publicerare-role"

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
INSTANCE_NAME="novatrix-webb"              # web server (WordPress), public subnet web-a
BASTION_NAME="novatrix-bastion"            # jump host, public subnet mgmt-a
LEGACY_SG_NAME="novatrix-web-sg"           # V43's group in the DEFAULT VPC (removed by cleanup)
SYNC_INTERVAL="30min"                      # how often EC2 pulls web/ (keeps S3 requests in free tier)

# ----- Derived ARNs -------------------------------------------------------------
BUCKET_ARN="arn:aws:s3:::${SITE_BUCKET}"
FUNCTION_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${FUNCTION_NAME}"
LOG_GROUP_ARN="arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:${LOG_GROUP}"
EC2_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${EC2_ROLE}"
UPLOADER_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${UPLOADER_ROLE}"
LAMBDA_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE}"
SSM_ARN_PREFIX="arn:aws:ssm:${REGION}:${ACCOUNT_ID}:parameter"   # + name (which starts with /)
DB_ARN="arn:aws:rds:${REGION}:${ACCOUNT_ID}:db:${DB_INSTANCE_ID}"

# Read one output value from the stack (empty if the stack is missing).
stack_output() {
  local v
  v=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text 2>/dev/null) || v=""
  [[ "$v" == "None" ]] && v=""
  echo "$v"
}

# Local scratch folder (relative, so it also works with aws.exe on Windows)
WORK_DIR=".v45_build"
mkdir -p "$WORK_DIR"
