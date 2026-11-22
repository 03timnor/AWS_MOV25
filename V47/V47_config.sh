# =============================================================================
# Novatrix V47 - shared settings. Sourced by the other V47 scripts, not run.
#
# Everything that VARIES between environments lives here and is passed to the
# CloudFormation templates as parameters. The templates themselves contain no
# account ids, IP addresses or passwords.
#
# New in V47: the single web server is replaced by an Auto Scaling group in two
# Availability Zones behind an Application Load Balancer, and the passwords
# live in AWS Secrets Manager (created by CloudFormation, not by the script).
# =============================================================================

# Stop Git Bash on Windows from rewriting paths like /aws/lambda/... into C:\...
export MSYS_NO_PATHCONV=1

# aws.exe on Windows ends its text output lines with \r\n. Bash only strips the
# \n, so values arrive as e.g. "True\r" and comparisons silently fail. Strip
# every \r from AWS CLI output (pipefail in the scripts keeps aws's exit code).
aws() { command aws "$@" | tr -d '\r'; }

REGION="eu-north-1"                        # Stockholm
PROJECT="novatrix"                         # prefix for stacks, exports and resource names
TAG_KEY="Project"
TAG_VALUE="$PROJECT"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if [[ -z "$ACCOUNT_ID" ]]; then
  echo "Could not read account id - is the AWS CLI configured (aws configure)?" >&2
  exit 1
fi

# ----- Infrastructure as code: five stacks, deployed in this order ------------
# Each layer exports its values (Export name: <PROJECT>-<Key>) and the next layer
# imports them. CloudFormation then refuses to delete a layer that another
# layer still uses - the cleanup script deletes them in reverse order.
STACK_NETWORK="${PROJECT}-network"         # VPC, subnets, routes, SGs (incl. ALB), NACL, S3 endpoint, flow logs
STACK_DATA="${PROJECT}-data"               # RDS MariaDB + EFS + secrets (Secrets Manager)
STACK_SECURITY="${PROJECT}-security"       # IAM: service roles, groups, policies, users
STACK_STORAGE="${PROJECT}-storage"         # S3 bucket + publisher Lambda
STACK_COMPUTE="${PROJECT}-compute"         # launch template, ALB, Auto Scaling group, bastion
STACKS=("$STACK_NETWORK" "$STACK_DATA" "$STACK_SECURITY" "$STACK_STORAGE" "$STACK_COMPUTE")
TEMPLATES=(templates/V47_01-network.yaml templates/V47_02-data.yaml templates/V47_03-security.yaml
           templates/V47_04-storage.yaml templates/V47_05-compute.yaml)
CONTENT_DIR="content"                      # static content, uploaded as drafts to drafts/

# ----- Network (address plan, see templates/V47_01-network.yaml) ---------------
VPC_CIDR="10.0.0.0/16"
MGMT_A_CIDR="10.0.0.0/24"                  # bastion
WEB_A_CIDR="10.0.2.0/24"                   # web servers (AZ a) + ALB node
WEB_B_CIDR="10.0.3.0/24"                   # web servers (AZ b) + ALB node
WEB_TIER_CIDR="10.0.2.0/23"                # web-a + web-b (one NACL rule covers both)
DATA_A_CIDR="10.0.10.0/24"                 # RDS + EFS mount target (AZ a)
DATA_B_CIDR="10.0.11.0/24"                 # EFS mount target (AZ b)
DATA_TIER_CIDR="10.0.10.0/23"
FLOW_LOG_GROUP="/${PROJECT}/vpc-flow-logs"
FLOW_LOG_GROUP_ARN="arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:${FLOW_LOG_GROUP}"

# ----- Database (RDS MariaDB, private subnets data-a/data-b) -------------------
DB_INSTANCE_ID="${PROJECT}-db"
DB_INSTANCE_CLASS="db.t4g.micro"           # smallest Graviton class, free tier / Free plan
DB_STORAGE_GB=20                           # gp2, the free tier allowance (and RDS minimum)
DB_BACKUP_RETENTION_DAYS=1                 # Free plan maximum (see the documentation)
DB_MULTI_AZ=false                          # true = standby in AZ b (about double the DB cost)
DB_PORT=3306                               # MariaDB
DB_NAME="wordpress"
DB_MASTER_USER="${PROJECT}admin"           # only used to create/update the WordPress user
DB_APP_USER="wordpress"                    # WordPress's own user: ONLY the wordpress database

# Secrets live in AWS Secrets Manager and are created by CloudFormation itself
# (layer 2, random 32-character passwords) - no password is ever in a template,
# on the command line or in Git:
#   - the RDS master password: managed by RDS (ManageMasterUserPassword), its
#     secret is named rds!db-... and is rotated automatically every 7 days
#   - the WordPress DB user and the WordPress admin: the names below
DB_APP_SECRET="${PROJECT}/db/wordpress-password"
WP_ADMIN_SECRET="${PROJECT}/wordpress/admin-password"
SECRET_NAMES=("$DB_APP_SECRET" "$WP_ADMIN_SECRET")

# ----- WordPress ----------------------------------------------------------------
WP_TITLE="Novatrix"
WP_ADMIN_USER="novatrix-admin"
WP_ADMIN_EMAIL="admin@novatrix.example"
WP_LOCALE="en_US"
WP_ROOT="/var/www/html"                    # EFS mount point on every web server
STATIC_URL_PATH="/static"                  # static content from S3 web/ is served here

# ----- Storage: ONE bucket, four prefixes ----------------------------------------
#   drafts/  drafts uploaded by people    (writes trigger the publisher Lambda)
#   web/     published static content     (written only by the Lambda, read by EC2)
#   logs/    Apache log archive           (written only via the uploader role)
#   backup/  database dumps + wp-content  (written only via the uploader role)
SITE_BUCKET="${PROJECT}-web-${ACCOUNT_ID}"
FUNCTION_NAME="${PROJECT}-publisher"
LOG_GROUP="/aws/lambda/${FUNCTION_NAME}"
LOG_RETENTION_DAYS=30                      # logs/ objects are deleted after this many days
BACKUP_RETENTION_DAYS=14                   # backup/ objects are deleted after this many days

# ----- Service roles (machines) - names are set in templates/V47_03-security.yaml ---
EC2_ROLE="${PROJECT}-web-ec2-role"
EC2_PROFILE="${PROJECT}-web-ec2-profile"
UPLOADER_ROLE="${PROJECT}-uploader-role"   # may ONLY be assumed by the EC2 role (role chaining)
LAMBDA_ROLE="${PROJECT}-publisher-role"
FLOW_LOG_ROLE="${PROJECT}-flow-log-role"

# ----- Human access: groups and users (user:group) --------------------------
OPS_GROUP="${PROJECT}-operations"
DEV_GROUP="${PROJECT}-development"
MARKETING_GROUP="${PROJECT}-marketing"
USERS=(
  "anna.ops:${OPS_GROUP}"
  "erik.dev:${DEV_GROUP}"
  "maja.marketing:${MARKETING_GROUP}"
)

# ----- EC2: launch template + Auto Scaling group + bastion ----------------------
INSTANCE_TYPE="t3.micro"                   # free tier eligible in eu-north-1 (CpuCredits=standard)
AMI_SSM_PATH="/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
KEY_NAME="AWS_MOV25"
KEY_FILE="$HOME/.ssh/${KEY_NAME}.pem"
INSTANCE_NAME="${PROJECT}-web"             # Name tag of every web server in the group
BASTION_NAME="${PROJECT}-bastion"          # jump host, public subnet mgmt-a
SYNC_INTERVAL="30min"                      # how often each web server pulls web/ from S3

ASG_NAME="${PROJECT}-web-asg"
ASG_MIN=2                                  # one per AZ: the site survives the loss of an AZ
ASG_MAX=4                                  # cost ceiling - never more than 4 web servers
CPU_TARGET=50                              # target tracking: average CPU % in the group
REQUESTS_PER_TARGET=60                     # target tracking: ALB requests per server per minute
                                           # (~60 % of what one t3.micro served in the V47 load test:
                                           # ~100/min - the target must be BELOW a server's capacity)

# ----- Load balancer --------------------------------------------------------------
ALB_NAME="${PROJECT}-alb"
TG_NAME="${PROJECT}-web-tg"
HEALTH_CHECK_PATH="/healthz.php"           # PHP + EFS on the server (not the DB - see compute template)
# No domain yet: HTTPS on the ALB uses a self-signed certificate that the deploy
# script creates and imports into ACM (CloudFormation can't import certificates).
CERT_DOMAIN="${PROJECT}-alb.invalid"       # .invalid = reserved TLD, can never be a real name

# ----- Derived ARNs -------------------------------------------------------------
BUCKET_ARN="arn:aws:s3:::${SITE_BUCKET}"
FUNCTION_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${FUNCTION_NAME}"
LOG_GROUP_ARN="arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:${LOG_GROUP}"
EC2_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${EC2_ROLE}"
UPLOADER_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${UPLOADER_ROLE}"
LAMBDA_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE}"
SECRET_ARN_PREFIX="arn:aws:secretsmanager:${REGION}:${ACCOUNT_ID}:secret"   # + :name-XXXXXX
DB_ARN="arn:aws:rds:${REGION}:${ACCOUNT_ID}:db:${DB_INSTANCE_ID}"

# ----- Stack outputs ------------------------------------------------------------
# Every output key is unique across the five stacks, so one lookup table works.
# load_outputs fills it (call it again after a deploy); stack_output reads it.
declare -A STACK_OUTPUTS=()
load_outputs() {
  local s k v
  STACK_OUTPUTS=()
  for s in "${STACKS[@]}"; do
    while read -r k v; do
      [[ -n "${k:-}" && "$k" != None ]] && STACK_OUTPUTS[$k]=$v
    done < <(aws cloudformation describe-stacks --region "$REGION" --stack-name "$s" \
               --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output text 2>/dev/null)
  done
  return 0
}
stack_output() {   # key -> value (empty if the stack or output is missing)
  [[ ${#STACK_OUTPUTS[@]} -eq 0 ]] && load_outputs
  echo "${STACK_OUTPUTS[$1]:-}"
}
stack_exists() {
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$1" >/dev/null 2>&1
}
# ARN of the imported self-signed certificate (empty if none)
cert_arn() {
  local a
  a=$(aws acm list-certificates --region "$REGION" \
        --query "CertificateSummaryList[?DomainName=='${CERT_DOMAIN}'].CertificateArn | [0]" --output text 2>/dev/null)
  [[ "$a" == arn:* ]] && echo "$a"
  return 0
}

# Local scratch folder (relative, so it also works with aws.exe on Windows)
WORK_DIR=".v47_build"
mkdir -p "$WORK_DIR"
