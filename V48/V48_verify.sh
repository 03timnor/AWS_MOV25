#!/usr/bin/env bash
# =============================================================================
# Novatrix V48 - verifies that the stack built from the templates in the repo
# is what runs in AWS, and that it works: WordPress behind a load balancer on
# an Auto Scaling group in two AZs, RDS + EFS, backups, IAM, the network - and
# the central monitoring and logging (CloudWatch, SNS e-mail, site check).
#
# Run:  ./V48_verify.sh                 everything that changes nothing (Del 0-7, 9)
#       ./V48_verify.sh --failover      + Del 8.1: terminate a web server under traffic
#       ./V48_verify.sh --selfheal      + Del 8.2: break a web server (Apache stopped)
#       ./V48_verify.sh --load          + Del 8.3: load test -> the group scales out
#       ./V48_verify.sh --alarmtest     + Del 8.4: the alarm chain with REAL mails (ALARM + OK)
#       ./V48_verify.sh --all           all four (about 40 minutes)
#
#   Del 0: CloudFormation - all six stacks complete, the template in AWS is
#          byte-for-byte the one in the repo, no drift (nobody has changed
#          anything by hand), and the central resources are owned by a stack
#   Del 1: IAM policy simulator - every user and role, allowed AND denied
#          (secrets in Secrets Manager, EFS mount, backups, the database,
#          operating the Auto Scaling group)
#   Del 2: the website THROUGH THE LOAD BALANCER - WordPress over HTTP/HTTPS,
#          hardening, health check, static content from S3 and the publishing
#          chain draft -> Lambda -> web/
#   Del 3: inside a web server (ONLY via the bastion) - S3 with curl and the
#          role, role chaining reader -> uploader
#   Del 4: WordPress against the database (RDS) and the shared storage (EFS):
#          a file written on the server in one AZ is served by the server in
#          the other AZ, the DB user and the EFS access point are locked down
#   Del 5: backups - DB dump + wp-content to S3 (once per day for the whole
#          group), 14-day lifecycle rule, RDS automated backup (1 day)
#   Del 6: the network - tiers, every SG and NACL rule, real connection
#          attempts from the internet (only the ALB answers), the bastion and
#          a web server, and the VPC flow logs' own ACCEPT/REJECT records.
#   Del 7: high availability - the ALB in two AZs, the Auto Scaling group
#          (servers per AZ, health checks, scaling policies, rolling updates)
#   Del 8: (opt-in, see Run) what happens when a server dies, breaks, or the
#          load rises - measured from the outside, request by request - and
#          whether an alarm really reaches the inbox.
#   Del 9: monitoring and logging - the SNS subscription is confirmed, every
#          alarm mails (critical ones also on OK), CPU/memory/disk arrive from
#          the agent, every server's logs are in CloudWatch and searchable
#          (a request through the ALB is found again, Logs Insights), the
#          metric filters, the database's error log, the site check (Lambda).
#
# All output is also saved to V48_verifiering_<date>.txt for the report.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")"
source ./V48_config.sh

DO_FAILOVER=no; DO_SELFHEAL=no; DO_LOAD=no; DO_ALARMTEST=no
for a in "$@"; do
  case "$a" in
    --failover) DO_FAILOVER=yes ;;
    --selfheal) DO_SELFHEAL=yes ;;
    --load)     DO_LOAD=yes ;;
    --alarmtest) DO_ALARMTEST=yes ;;
    --all)      DO_FAILOVER=yes; DO_SELFHEAL=yes; DO_LOAD=yes; DO_ALARMTEST=yes ;;
    *) echo "Usage: $0 [--failover] [--selfheal] [--load] [--alarmtest] [--all]" >&2; exit 2 ;;
  esac
done

OUT="V48_verifiering_$(date +%Y%m%d-%H%M).txt"
exec > >(tee "$OUT") 2>&1

PASS=0
FAIL=0
U="arn:aws:iam::${ACCOUNT_ID}:user"
START_MS=$(( ($(date +%s) - 120) * 1000 ))   # flow log search window starts here
STAMP=$(date +%H%M%S)

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

ctx()        { echo "[{\"ContextKeyName\":\"$1\",\"ContextKeyValues\":[\"$2\"],\"ContextKeyType\":\"string\"}]"; }
tag_ctx()    { ctx "aws:ResourceTag/${TAG_KEY}" "$1"; }
prefix_ctx() { ctx "s3:prefix" "$1"; }
asg_tag_ctx() { ctx "autoscaling:ResourceTag/${TAG_KEY}" "$1"; }

# Run a command, kill it after <seconds>. Portable (Git Bash/macOS lack a
# reliable `timeout`). Returns the command's status, or 124 on timeout.
with_timeout() {
  local secs=$1 pid i; shift
  "$@" & pid=$!
  for (( i = 0; i < secs * 2; i++ )); do
    kill -0 "$pid" 2>/dev/null || { wait "$pid"; return $?; }
    sleep 0.5
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  return 124
}
# TCP connection attempt from THIS computer: 0 = port answered, else blocked.
probe() { with_timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }
http_code() { curl -sk -m 10 -o /dev/null -w '%{http_code}' "$1"; }

# Values from the six stacks (empty if a stack doesn't exist)
load_outputs
VPC_ID=$(stack_output VpcId)
DB_HOST=$(stack_output DbEndpoint)
FS_ID=$(stack_output FileSystemId)
AP_ARN=$(stack_output AccessPointArn)
FS_ARN="arn:aws:elasticfilesystem:${REGION}:${ACCOUNT_ID}:file-system/${FS_ID:-fs-00000000}"
ALB_DNS=$(stack_output AlbDnsName)
ASG=$(stack_output AsgName)
TG_ARN=$(stack_output WebTargetGroupArn)
HTTPS_ON=$(stack_output HttpsEnabled)
SITE="http://${ALB_DNS:-alb-missing.invalid}"
SITE_TLS="https://${ALB_DNS:-alb-missing.invalid}"

INSTANCE_ARN="arn:aws:ec2:${REGION}:${ACCOUNT_ID}:instance/i-0123456789abcdef0"
SG_ARN="arn:aws:ec2:${REGION}:${ACCOUNT_ID}:security-group/sg-0123456789abcdef0"
NACL_ARN="arn:aws:ec2:${REGION}:${ACCOUNT_ID}:network-acl/acl-0123456789abcdef0"
STACK_ARN="arn:aws:cloudformation:${REGION}:${ACCOUNT_ID}:stack/${STACK_NETWORK}/*"
DRAFT="${BUCKET_ARN}/drafts/index.html"
DRAFT_IMG="${BUCKET_ARN}/drafts/images/logo.png"
WEB="${BUCKET_ARN}/web/index.html"
WEB_IMG="${BUCKET_ARN}/web/images/logo.png"
LOGG="${BUCKET_ARN}/logs/i-0123456789abcdef0/access_log.gz"
BACKUP="${BUCKET_ARN}/backup/db/20261105T000000Z-wordpress.sql.gz"
ASG_ARN="arn:aws:autoscaling:${REGION}:${ACCOUNT_ID}:autoScalingGroup:11111111-2222-3333-4444-555555555555:autoScalingGroupName/${ASG_NAME}"
SECRET_MASTER=$(stack_output DbMasterSecretArn); SECRET_MASTER=${SECRET_MASTER:-${SECRET_ARN_PREFIX}:rds!db-missing-AbCdEf}
SECRET_APP=$(stack_output DbAppSecretArn);       SECRET_APP=${SECRET_APP:-${SECRET_ARN_PREFIX}:${DB_APP_SECRET}-AbCdEf}
SECRET_OTHER="${SECRET_ARN_PREFIX}:other-project/password-AbCdEf"

echo "Novatrix V48 - verifiering $(date '+%Y-%m-%d %H:%M')   konto $ACCOUNT_ID   region $REGION"

# =============================================================================
echo; echo "=== Del 0: CloudFormation - stacken i AWS är koden i repot ==="
# =============================================================================
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Repo:  $(git log -1 --date=short --format='%h  %ad  %s' 2>/dev/null)"
  echo "Mallarnas historik (senaste commits som rör templates/):"
  git log -8 --date=short --format='    %h  %ad  %an  %s' -- templates 2>/dev/null
  dirty=$(git status --porcelain -- templates "$CONTENT_DIR" V48_config.sh)
  [[ -n "$dirty" ]] && { echo "INFO ocommittade ändringar (syns som skillnad nedan om de är deployade):"; sed 's/^/       /' <<<"$dirty"; }
else
  echo "INFO inte ett Git-repo - ingen historik att visa"
fi
echo

# Blank lines and \r (Git on Windows) don't count as a difference.
norm() { tr -d '\r' | grep -v '^[[:space:]]*$'; }
DRIFT_IDS=()
for i in "${!STACKS[@]}"; do
  s=${STACKS[$i]}; t=${TEMPLATES[$i]}
  status=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$s" \
             --query 'Stacks[0].StackStatus' --output text 2>/dev/null)
  [[ "$status" == CREATE_COMPLETE || "$status" == UPDATE_COMPLETE ]] && got=ALLOW || got=DENY
  record ALLOW "$got" "stack $s klar (${status:-saknas})"
  if [[ -z "$status" ]]; then DRIFT_IDS+=(""); continue; fi
  if diff -q <(aws cloudformation get-template --region "$REGION" --stack-name "$s" \
                 --query TemplateBody --output text | norm) <(norm < "$t") >/dev/null; then
    got=ALLOW
  else
    got=DENY
  fi
  record ALLOW "$got" "mallen i AWS = $t i repot (inget odeployat, inget ändrat bredvid)"
  # Start drift detection for every stack now, collect the results below.
  DRIFT_IDS+=("$(aws cloudformation detect-stack-drift --region "$REGION" --stack-name "$s" \
                   --query StackDriftDetectionId --output text 2>/dev/null)")
done

echo; echo "Driftdetektering - AWS jämför varje resurs med mallen (ändrat för hand i konsolen?):"
for i in "${!STACKS[@]}"; do
  s=${STACKS[$i]}; id=${DRIFT_IDS[$i]:-}
  [[ -z "$id" || "$id" == None ]] && continue
  st=""; drift=""
  for n in $(seq 1 40); do
    read -r st drift <<<"$(aws cloudformation describe-stack-drift-detection-status --region "$REGION" \
      --stack-drift-detection-id "$id" --query '[DetectionStatus, StackDriftStatus]' --output text 2>/dev/null)"
    [[ "$st" != DETECTION_IN_PROGRESS ]] && break
    sleep 5
  done
  [[ "$st" == DETECTION_FAILED ]] && echo "INFO $s: vissa resurstyper kan inte driftkontrolleras (resten är kontrollerade)"
  record IN_SYNC "${drift:-?}" "drift: $s"
  if [[ "$drift" == DRIFTED ]]; then
    aws cloudformation describe-stack-resource-drifts --region "$REGION" --stack-name "$s" \
      --stack-resource-drift-status-filters MODIFIED DELETED \
      --query 'StackResourceDrifts[].[StackResourceDriftStatus, LogicalResourceId, ResourceType]' \
      --output text | sed 's/^/       /'
  fi
done

echo; echo "Ägarskap - de centrala resurserna är skapade av en stack, inte för hand:"
owned() {   # physical-id description
  local s=""
  [[ -n "$1" ]] && s=$(aws cloudformation describe-stack-resources --region "$REGION" --physical-resource-id "$1" \
                         --query 'StackResources[0].StackName' --output text 2>/dev/null)
  [[ -n "$s" && "$s" != None ]] && got=ALLOW || { got=DENY; s="ingen"; }
  record ALLOW "$got" "$2 ($1) -> stack $s"
}
owned "$VPC_ID"                       "VPC"
owned "$(stack_output WebSgId)"       "security group web-sg"
owned "$(stack_output DataNaclId)"    "NACL data-nivån"
owned "$DB_INSTANCE_ID"               "RDS-databasen"
owned "$FS_ID"                        "EFS"
owned "$SITE_BUCKET"                  "S3-bucketen"
owned "$FUNCTION_NAME"                "publicerar-Lambdan"
owned "$EC2_ROLE"                     "IAM-roll webbserver"
owned "$UPLOADER_ROLE"                "IAM-roll uppladdare"
owned "arn:aws:iam::${ACCOUNT_ID}:policy/${PROJECT}-operations-policy" "IAM-policy drift"
owned "${USERS[0]%%:*}"               "IAM-användare"
owned "$(stack_output AlbArn)"        "lastbalanseraren (ALB)"
owned "$TG_ARN"                       "målgruppen (target group)"
owned "$(stack_output WebLaunchTemplateId)" "launch template för webbservrarna"
owned "$ASG"                          "Auto Scaling-gruppen"
owned "$(stack_output BastionId)"     "EC2 bastion"
owned "$(stack_output DbAppSecretArn)"   "hemlighet: WordPress databaslösenord (Secrets Manager)"
owned "$(stack_output WpAdminSecretArn)" "hemlighet: WordPress adminlösenord (Secrets Manager)"
owned "$WEB_LOG_PREFIX/access"        "central logggrupp: webbservrarnas accesslogg"
owned "$CW_AGENT_CONFIG"              "CloudWatch-agentens konfiguration (SSM Parameter Store)"
owned "$DB_LOG_GROUP"                 "central logggrupp: databasens fellogg"
owned "$(stack_output AlarmTopicArn)" "SNS-ämnet för larmmejlen"
owned "$SITE_CHECK_FUNCTION"          "site check-Lambdan (serverless)"
owned "${PROJECT}-critical-site-down" "larmet critical-site-down"
owned "$DASHBOARD_NAME"               "dashboarden"
# The master password secret is created by RDS itself (ManageMasterUserPassword).
read -r mstatus <<<"$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$DB_INSTANCE_ID"   --query 'DBInstances[0].MasterUserSecret.SecretStatus' --output text 2>/dev/null)"
[[ "${mstatus:-}" == active ]] && got=ALLOW || got=DENY
record ALLOW "$got" "RDS hanterar masterlösenordet själv i Secrets Manager (status ${mstatus:-saknas})"
rot=$(aws secretsmanager describe-secret --region "$REGION" --secret-id "$SECRET_MASTER"         --query 'RotationEnabled' --output text 2>/dev/null)
[[ "$rot" == True ]] && got=ALLOW || got=DENY
record ALLOW "$got" "masterlösenordet roteras automatiskt (RotationEnabled)"
n=0
for p in "/${PROJECT}/db/master-password" "/${PROJECT}/db/wordpress-password" "/${PROJECT}/wordpress/admin-password"; do
  aws ssm get-parameter --region "$REGION" --name "$p" >/dev/null 2>&1 && n=$((n + 1))
done
[[ $n -eq 0 ]] && got=DENY || got=ALLOW
record DENY "$got" "gamla lösenord ligger kvar i SSM Parameter Store ($n st)"
c=$(cert_arn)
echo "INFO HTTPS-certifikatet ($CERT_DOMAIN, ${c:-saknas}) importeras avsiktligt av skriptet - CloudFormation kan inte importera till ACM"

# =============================================================================
echo; echo "=== Del 1: IAM policy simulator ==="
# =============================================================================
echo; echo "--- anna.ops (grupp $OPS_GROUP) ---"
check "$U/anna.ops" ec2:DescribeInstances "*" ALLOW "se alla instanser"
check "$U/anna.ops" ec2:StopInstances "$INSTANCE_ARN" ALLOW "stoppa instans taggad ${TAG_KEY}=${TAG_VALUE}" "$(tag_ctx "$TAG_VALUE")"
check "$U/anna.ops" ec2:StartInstances "$INSTANCE_ARN" ALLOW "starta bastionen när den behövs (taggad ${TAG_KEY}=${TAG_VALUE})" "$(tag_ctx "$TAG_VALUE")"
check "$U/anna.ops" ec2:StopInstances "$INSTANCE_ARN" DENY  "stoppa instans från annat projekt" "$(tag_ctx annat)"
check "$U/anna.ops" ec2:TerminateInstances "$INSTANCE_ARN" DENY "terminera Novatrix-instansen" "$(tag_ctx "$TAG_VALUE")"
check "$U/anna.ops" logs:FilterLogEvents "${LOG_GROUP_ARN}:*" ALLOW "läsa publiceringsloggen"
check "$U/anna.ops" logs:FilterLogEvents "${FLOW_LOG_GROUP_ARN}:*" ALLOW "läsa VPC-flödesloggarna"
check "$U/anna.ops" ec2:DescribeNetworkAcls "*" ALLOW "se nätverkets NACL:er"
check "$U/anna.ops" rds:DescribeDBInstances "*" ALLOW "se databasens status"
check "$U/anna.ops" elasticfilesystem:DescribeFileSystems "*" ALLOW "se den delade lagringen"
check "$U/anna.ops" rds:ModifyDBInstance "$DB_ARN" DENY "ändra databasen"
check "$U/anna.ops" rds:DeleteDBInstance "$DB_ARN" DENY "radera databasen"
check "$U/anna.ops" secretsmanager:GetSecretValue "$SECRET_MASTER" DENY "läsa databasens masterlösenord"
check "$U/anna.ops" s3:GetObject "$BACKUP" ALLOW "hämta backup för återställning"
check "$U/anna.ops" s3:DeleteObject "$BACKUP" DENY "radera backuper"
check "$U/anna.ops" ec2:AuthorizeSecurityGroupIngress "$SG_ARN" DENY "öppna en port i en security group"
check "$U/anna.ops" ec2:CreateNetworkAclEntry "$NACL_ARN" DENY "lägga till en NACL-regel"
check "$U/anna.ops" cloudformation:DescribeStacks "$STACK_ARN" ALLOW "se stackarnas status"
check "$U/anna.ops" cloudformation:UpdateStack "$STACK_ARN" DENY "ändra infrastrukturstacken"
check "$U/anna.ops" cloudformation:DeleteStack "$STACK_ARN" DENY "radera infrastrukturstacken"
check "$U/anna.ops" s3:GetObject "$LOGG" ALLOW "läsa arkiverad Apache-logg"
check "$U/anna.ops" s3:PutObject "$LOGG" DENY "skriva i loggarkivet"
check "$U/anna.ops" sts:AssumeRole "$UPLOADER_ROLE_ARN" DENY "anta uppladdarrollen"
check "$U/anna.ops" s3:PutObject "$DRAFT" DENY "ändra det statiska innehållet"
check "$U/anna.ops" lambda:UpdateFunctionCode "$FUNCTION_ARN" DENY "ändra publicerarens kod"
check "$U/anna.ops" iam:CreateUser "*" DENY "skapa IAM-användare"
check "$U/anna.ops" autoscaling:DescribeAutoScalingGroups "*" ALLOW "se Auto Scaling-gruppen"
check "$U/anna.ops" elasticloadbalancing:DescribeTargetHealth "*" ALLOW "se lastbalanserarens hälsokontroller"
check "$U/anna.ops" autoscaling:SetDesiredCapacity "$ASG_ARN" ALLOW "ändra antal webbservrar (inom min/max)" "$(asg_tag_ctx "$TAG_VALUE")"
check "$U/anna.ops" autoscaling:TerminateInstanceInAutoScalingGroup "$ASG_ARN" ALLOW "byta ut en sjuk webbserver" "$(asg_tag_ctx "$TAG_VALUE")"
check "$U/anna.ops" autoscaling:StartInstanceRefresh "$ASG_ARN" ALLOW "rulla ut alla webbservrar på nytt" "$(asg_tag_ctx "$TAG_VALUE")"
check "$U/anna.ops" autoscaling:SetDesiredCapacity "$ASG_ARN" DENY "ändra en annan grupps storlek" "$(asg_tag_ctx annat)"
check "$U/anna.ops" autoscaling:UpdateAutoScalingGroup "$ASG_ARN" DENY "ändra min/max (kostnadstaket)" "$(asg_tag_ctx "$TAG_VALUE")"
check "$U/anna.ops" autoscaling:PutScalingPolicy "$ASG_ARN" DENY "ändra skalningspolicyerna" "$(asg_tag_ctx "$TAG_VALUE")"
check "$U/anna.ops" cloudwatch:DescribeAlarms "*" ALLOW "se alla larm och deras historik"
check "$U/anna.ops" logs:StartQuery "${LOGS_ARN}:${WEB_LOG_PREFIX}/access:*" ALLOW "söka i alla servrars loggar (Logs Insights)"
check "$U/anna.ops" logs:FilterLogEvents "${LOGS_ARN}:${DB_LOG_GROUP}:*" ALLOW "läsa databasens fellogg"
check "$U/anna.ops" logs:FilterLogEvents "${LOGS_ARN}:${SITE_CHECK_LOG_GROUP}:*" ALLOW "läsa site checkens logg"
check "$U/anna.ops" cloudwatch:DeleteAlarms "arn:aws:cloudwatch:${REGION}:${ACCOUNT_ID}:alarm:${PROJECT}-critical-site-down" DENY "radera ett larm"
check "$U/anna.ops" cloudwatch:DisableAlarmActions "arn:aws:cloudwatch:${REGION}:${ACCOUNT_ID}:alarm:${PROJECT}-critical-site-down" DENY "tysta ett larm (stänga av mejlen)"
check "$U/anna.ops" sns:Unsubscribe "$ALARM_TOPIC_ARN" DENY "avregistrera larmmejlen"
check "$U/anna.ops" logs:DeleteLogGroup "${LOGS_ARN}:${WEB_LOG_PREFIX}/access:*" DENY "radera loggar (sopa igen spåren)"
check "$U/anna.ops" elasticloadbalancing:DeleteLoadBalancer "arn:aws:elasticloadbalancing:${REGION}:${ACCOUNT_ID}:loadbalancer/app/${ALB_NAME}/0123456789abcdef" DENY "radera lastbalanseraren"

echo; echo "--- erik.dev (grupp $DEV_GROUP) ---"
check "$U/erik.dev" s3:PutObject "$DRAFT" ALLOW "ladda upp utkast"
check "$U/erik.dev" s3:GetObject "$WEB" ALLOW "läsa publicerad sida"
check "$U/erik.dev" s3:PutObject "$WEB" DENY "publicera förbi publiceraren"
check "$U/erik.dev" lambda:UpdateFunctionCode "$FUNCTION_ARN" ALLOW "driftsätta ny publicerarkod"
check "$U/erik.dev" lambda:UpdateFunctionConfiguration "$FUNCTION_ARN" DENY "byta roll/inställningar på Lambda"
check "$U/erik.dev" iam:PassRole "$LAMBDA_ROLE_ARN" DENY "skicka vidare Lambdarollen"
check "$U/erik.dev" ec2:StopInstances "$INSTANCE_ARN" DENY "stoppa servern" "$(tag_ctx "$TAG_VALUE")"
check "$U/erik.dev" s3:GetObject "$LOGG" DENY "läsa besökarloggar"
check "$U/erik.dev" s3:GetObject "$BACKUP" DENY "ladda ner databasbackup"
check "$U/erik.dev" secretsmanager:GetSecretValue "$SECRET_APP" DENY "läsa WordPress databaslösenord"
check "$U/erik.dev" autoscaling:SetDesiredCapacity "$ASG_ARN" DENY "ändra antal webbservrar" "$(asg_tag_ctx "$TAG_VALUE")"
check "$U/erik.dev" logs:FilterLogEvents "${FLOW_LOG_GROUP_ARN}:*" DENY "läsa VPC-flödesloggarna"
check "$U/erik.dev" ec2:AuthorizeSecurityGroupIngress "$SG_ARN" DENY "öppna en port i en security group"
check "$U/erik.dev" logs:FilterLogEvents "${LOGS_ARN}:${WEB_LOG_PREFIX}/access:*" DENY "läsa besökarnas accesslogg (IP-adresser)"
check "$U/erik.dev" cloudwatch:DeleteAlarms "arn:aws:cloudwatch:${REGION}:${ACCOUNT_ID}:alarm:${PROJECT}-critical-site-down" DENY "radera ett larm"

echo; echo "--- maja.marketing (grupp $MARKETING_GROUP) ---"
check "$U/maja.marketing" s3:PutObject "$DRAFT_IMG" ALLOW "ladda upp bild"
check "$U/maja.marketing" s3:ListBucket "$BUCKET_ARN" ALLOW "lista sina bilder" "$(prefix_ctx drafts/images/)"
check "$U/maja.marketing" s3:ListBucket "$BUCKET_ARN" DENY  "lista hela bucketen" "$(prefix_ctx drafts/)"
check "$U/maja.marketing" s3:PutObject "$DRAFT" DENY "ändra sidans HTML"
check "$U/maja.marketing" s3:PutObject "$WEB_IMG" DENY "publicera förbi publiceraren"
check "$U/maja.marketing" s3:DeleteObject "$DRAFT_IMG" DENY "radera bilder"
check "$U/maja.marketing" s3:GetObject "$BACKUP" DENY "ladda ner databasbackup"
check "$U/maja.marketing" lambda:UpdateFunctionCode "$FUNCTION_ARN" DENY "ändra publicerarens kod"

echo; echo "--- roll $EC2_ROLE (webbservern) ---"
check "$EC2_ROLE_ARN" s3:GetObject "$WEB" ALLOW "läsa statiskt innehåll"
check "$EC2_ROLE_ARN" s3:ListBucket "$BUCKET_ARN" ALLOW "lista web/" "$(prefix_ctx web/)"
check "$EC2_ROLE_ARN" s3:ListBucket "$BUCKET_ARN" DENY  "lista drafts/" "$(prefix_ctx drafts/)"
check "$EC2_ROLE_ARN" s3:GetObject "$DRAFT" DENY "läsa opublicerade utkast"
check "$EC2_ROLE_ARN" s3:PutObject "$WEB" DENY "skriva över det statiska innehållet"
check "$EC2_ROLE_ARN" s3:ListAllMyBuckets "*" DENY "lista kontots buckets"
check "$EC2_ROLE_ARN" s3:PutObject "$LOGG" DENY "skriva loggar själv (utan att byta roll)"
check "$EC2_ROLE_ARN" s3:PutObject "$BACKUP" DENY "skriva backup själv (utan att byta roll)"
check "$EC2_ROLE_ARN" s3:GetObject "$BACKUP" DENY "läsa backuper"
check "$EC2_ROLE_ARN" secretsmanager:GetSecretValue "$SECRET_APP" ALLOW "läsa WordPress databaslösenord"
check "$EC2_ROLE_ARN" secretsmanager:GetSecretValue "$SECRET_MASTER" ALLOW "läsa masterlösenordet (skapar/uppdaterar DB-användaren vid start)"
check "$EC2_ROLE_ARN" secretsmanager:GetSecretValue "$SECRET_OTHER" DENY "läsa andra hemligheter i kontot"
check "$EC2_ROLE_ARN" secretsmanager:PutSecretValue "$SECRET_APP" DENY "byta databaslösenordet"
check "$EC2_ROLE_ARN" secretsmanager:ListSecrets "*" DENY "lista kontots hemligheter"
check "$EC2_ROLE_ARN" autoscaling:SetDesiredCapacity "$ASG_ARN" DENY "skala sin egen grupp" "$(asg_tag_ctx "$TAG_VALUE")"
check "$EC2_ROLE_ARN" elasticfilesystem:ClientMount "$FS_ARN" ALLOW "montera EFS via WordPress access point" "$(ctx elasticfilesystem:AccessPointArn "${AP_ARN:-none}")"
check "$EC2_ROLE_ARN" elasticfilesystem:ClientMount "$FS_ARN" DENY "montera EFS UTAN access point (som root)"
check "$EC2_ROLE_ARN" elasticfilesystem:ClientRootAccess "$FS_ARN" DENY "root-åtkomst till EFS"
check "$EC2_ROLE_ARN" rds:DeleteDBInstance "$DB_ARN" DENY "radera databasen"
check "$EC2_ROLE_ARN" sts:AssumeRole "$UPLOADER_ROLE_ARN" ALLOW "begära uppladdarrollen"
check "$EC2_ROLE_ARN" sts:AssumeRole "$LAMBDA_ROLE_ARN" DENY "begära publicerarrollen"
check "$EC2_ROLE_ARN" ec2:AuthorizeSecurityGroupIngress "$SG_ARN" DENY "öppna sin egen brandvägg"
check "$EC2_ROLE_ARN" cloudwatch:PutMetricData "*" ALLOW "agenten: skicka minne/disk (namnrymd CWAgent)" "$(ctx cloudwatch:namespace CWAgent)"
check "$EC2_ROLE_ARN" cloudwatch:PutMetricData "*" DENY "förfalska site checkens mätvärden" "$(ctx cloudwatch:namespace Novatrix/SiteCheck)"
check "$EC2_ROLE_ARN" logs:PutLogEvents "${LOGS_ARN}:${WEB_LOG_PREFIX}/access:*" ALLOW "agenten: skicka loggar till ${WEB_LOG_PREFIX}/*"
check "$EC2_ROLE_ARN" logs:PutLogEvents "${LOGS_ARN}:${SITE_CHECK_LOG_GROUP}:*" DENY "skriva i site checkens logg"
check "$EC2_ROLE_ARN" logs:CreateLogGroup "${LOGS_ARN}:${WEB_LOG_PREFIX}/annat:*" DENY "skapa egna logggrupper"
check "$EC2_ROLE_ARN" logs:DeleteLogGroup "${LOGS_ARN}:${WEB_LOG_PREFIX}/access:*" DENY "radera loggarna (sopa igen spåren)"
check "$EC2_ROLE_ARN" logs:FilterLogEvents "${LOGS_ARN}:${WEB_LOG_PREFIX}/access:*" DENY "läsa loggarna (andra servrars besökare)"
check "$EC2_ROLE_ARN" ssm:GetParameter "arn:aws:ssm:${REGION}:${ACCOUNT_ID}:parameter${CW_AGENT_CONFIG}" ALLOW "agenten: läsa sin konfiguration"
check "$EC2_ROLE_ARN" ssm:GetParameter "arn:aws:ssm:${REGION}:${ACCOUNT_ID}:parameter/annat/parameter" DENY "läsa andra SSM-parametrar"
check "$EC2_ROLE_ARN" cloudwatch:DeleteAlarms "arn:aws:cloudwatch:${REGION}:${ACCOUNT_ID}:alarm:${PROJECT}-critical-site-down" DENY "radera larmen"

echo; echo "--- roll $UPLOADER_ROLE (antas av EC2-rollen) ---"
check "$UPLOADER_ROLE_ARN" s3:PutObject "$LOGG" ALLOW "ladda upp logg"
check "$UPLOADER_ROLE_ARN" s3:PutObject "$BACKUP" ALLOW "ladda upp backup"
check "$UPLOADER_ROLE_ARN" s3:GetObject "$BACKUP" DENY "läsa backuper"
check "$UPLOADER_ROLE_ARN" s3:DeleteObject "$BACKUP" DENY "radera backuper"
check "$UPLOADER_ROLE_ARN" s3:GetObject "$LOGG" DENY "läsa loggar"
check "$UPLOADER_ROLE_ARN" s3:GetObject "$WEB" DENY "läsa statiskt innehåll"
check "$UPLOADER_ROLE_ARN" s3:PutObject "$WEB" DENY "skriva över det statiska innehållet"
check "$UPLOADER_ROLE_ARN" s3:PutObject "$DRAFT" DENY "lägga utkast (starta publicering)"
check "$UPLOADER_ROLE_ARN" s3:ListBucket "$BUCKET_ARN" DENY "lista bucketen" "$(prefix_ctx backup/)"
check "$UPLOADER_ROLE_ARN" secretsmanager:GetSecretValue "$SECRET_APP" DENY "läsa databaslösenordet"

echo; echo "--- roll $SITE_CHECK_ROLE (site check, serverless) ---"
check "$SITE_CHECK_ROLE_ARN" cloudwatch:PutMetricData "*" ALLOW "skicka Available/ResponseTimeMs" "$(ctx cloudwatch:namespace Novatrix/SiteCheck)"
check "$SITE_CHECK_ROLE_ARN" cloudwatch:PutMetricData "*" DENY "skicka i agentens namnrymd" "$(ctx cloudwatch:namespace CWAgent)"
check "$SITE_CHECK_ROLE_ARN" logs:PutLogEvents "${LOGS_ARN}:${SITE_CHECK_LOG_GROUP}:*" ALLOW "skriva till egen logggrupp"
check "$SITE_CHECK_ROLE_ARN" logs:PutLogEvents "${LOG_GROUP_ARN}:*" DENY "skriva i publicerarens logg"
check "$SITE_CHECK_ROLE_ARN" sns:Publish "$ALARM_TOPIC_ARN" DENY "skicka egna larmmejl"
check "$SITE_CHECK_ROLE_ARN" cloudwatch:SetAlarmState "arn:aws:cloudwatch:${REGION}:${ACCOUNT_ID}:alarm:${PROJECT}-critical-site-down" DENY "ändra ett larms tillstånd"
check "$SITE_CHECK_ROLE_ARN" s3:GetObject "$WEB" DENY "läsa S3"
check "$SITE_CHECK_ROLE_ARN" secretsmanager:GetSecretValue "$SECRET_APP" DENY "läsa databaslösenordet"
check "$SITE_CHECK_ROLE_ARN" ec2:DescribeInstances "*" DENY "se EC2-instanser"

echo; echo "--- roll $LAMBDA_ROLE (publiceraren) ---"
check "$LAMBDA_ROLE_ARN" s3:GetObject "$DRAFT" ALLOW "läsa utkast"
check "$LAMBDA_ROLE_ARN" s3:PutObject "$WEB" ALLOW "publicera till web/"
check "$LAMBDA_ROLE_ARN" logs:PutLogEvents "${LOG_GROUP_ARN}:*" ALLOW "skriva till egen logggrupp"
check "$LAMBDA_ROLE_ARN" logs:PutLogEvents "arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:annan-grupp:*" DENY "skriva till annan logggrupp"
check "$LAMBDA_ROLE_ARN" s3:PutObject "$DRAFT" DENY "skriva utkast (kan inte trigga sig själv)"
check "$LAMBDA_ROLE_ARN" s3:GetObject "$WEB" DENY "läsa publicerad sajt"
check "$LAMBDA_ROLE_ARN" s3:DeleteObject "$WEB" DENY "radera publicerade filer"
check "$LAMBDA_ROLE_ARN" s3:ListBucket "$BUCKET_ARN" DENY "lista bucketen" "$(prefix_ctx web/)"
check "$LAMBDA_ROLE_ARN" s3:GetObject "$BACKUP" DENY "läsa backuper"
check "$LAMBDA_ROLE_ARN" ec2:DescribeInstances "*" DENY "se EC2-instanser"

# =============================================================================
echo; echo "=== Del 2: webbplatsen genom lastbalanseraren (WordPress, statiskt innehåll, publiceringskedjan) ==="
# =============================================================================
instance_info() {   # name -> "public-ip private-ip id" of the running instance in our VPC
  aws ec2 describe-instances --region "$REGION" \
    --filters Name=tag:Name,Values="$1" Name=vpc-id,Values="${VPC_ID:-none}" Name=instance-state-name,Values=running \
    --query 'Reservations[0].Instances[0].[PublicIpAddress,PrivateIpAddress,InstanceId]' --output text 2>/dev/null
}
# The web servers are whatever the Auto Scaling group runs right now:
# one line per InService server -> "id az private-ip public-ip"
web_instances() {
  local ids
  ids=$(aws autoscaling describe-auto-scaling-groups --region "$REGION" --auto-scaling-group-names "${ASG:-none}" \
          --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' --output text 2>/dev/null)
  [[ -z "$ids" || "$ids" == None ]] && return 0
  aws ec2 describe-instances --region "$REGION" --instance-ids $ids \
    --query 'Reservations[].Instances[].[InstanceId, Placement.AvailabilityZone, PrivateIpAddress, PublicIpAddress]' \
    --output text 2>/dev/null | sort -k2,2
}
healthy_count() {
  aws elbv2 describe-target-health --region "$REGION" --target-group-arn "${TG_ARN:-none}" \
    --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text 2>/dev/null
}
# Server 1 = the first in AZ order, server 2 = the first in ANOTHER AZ.
WEB_ID=""; WEB_AZ=""; WEB_PRIV=""; WEB_PUB=""; WEB2_ID=""; WEB2_AZ=""; WEB2_PRIV=""
while read -r id az priv pub; do
  [[ -z "${id:-}" ]] && continue
  if [[ -z "$WEB_ID" ]]; then WEB_ID=$id; WEB_AZ=$az; WEB_PRIV=$priv; WEB_PUB=$pub
  elif [[ -z "$WEB2_ID" && "$az" != "$WEB_AZ" ]]; then WEB2_ID=$id; WEB2_AZ=$az; WEB2_PRIV=$priv; fi
done <<<"$(web_instances)"
[[ "${WEB_PUB:-None}" == None ]] && WEB_PUB=""
read -r BASTION_IP BASTION_PRIV BASTION_ID <<<"$(instance_info "$BASTION_NAME")"
[[ "${BASTION_IP:-None}" == "None" ]] && BASTION_IP=""

if [[ -z "$ALB_DNS" ]]; then
  echo "Ingen lastbalanserare (stacken $STACK_COMPUTE saknas) - hoppar över webbplatstesterna."
else
  echo "Webbplatsen: $SITE   (lastbalanserare, webbservrar: $WEB_ID $WEB_AZ, ${WEB2_ID:-?} ${WEB2_AZ:-?})"
  # Fresh servers install at first boot: wait until the ALB has a healthy target.
  for i in $(seq 1 30); do
    PAGE=$(curl -s -m 10 -w '\n%{http_code}' "$SITE/")
    [[ "$(tail -n1 <<<"$PAGE")" == 200 ]] && grep -q "wp-content" <<<"$PAGE" && break
    [[ $i -eq 1 ]] && echo "Väntar på att WordPress ska svara genom lastbalanseraren (upp till 5 minuter)..."
    sleep 10
  done
  record 200 "$(tail -n1 <<<"$PAGE")" "startsidan svarar genom ALB över HTTP (port 80)"
  grep -qi '<meta name="generator" content="WordPress' <<<"$PAGE" && got=ALLOW || got=DENY
  record ALLOW "$got" "startsidan genereras av WordPress"
  grep -q "$WP_TITLE" <<<"$PAGE" && got=ALLOW || got=DENY
  record ALLOW "$got" "webbplatsens titel ($WP_TITLE) kommer från databasen"
  HDR_URL=$SITE
  if [[ "$HTTPS_ON" == yes ]]; then
    HDR_URL=$SITE_TLS
    record 200 "$(http_code "$SITE_TLS/")" "startsidan svarar över HTTPS (TLS avslutas i ALB, självsignerat certifikat)"
    # WordPress must know the visitor used HTTPS (X-Forwarded-Proto), or the
    # page links its own CSS/JS over http:// and the browser blocks it.
    grep -q "http://$ALB_DNS" <<<"$(curl -sk -m 10 "$SITE_TLS/")" && got=ALLOW || got=DENY
    record DENY "$got" "HTTPS-sidan länkar till http:// (blandat innehåll)"
    if command -v openssl >/dev/null 2>&1; then
      out=$(with_timeout 10 bash -c "openssl s_client -connect '$ALB_DNS:443' -servername '$ALB_DNS' -tls1_1 -cipher 'DEFAULT:@SECLEVEL=0' </dev/null 2>&1")
      grep -q "BEGIN CERTIFICATE" <<<"$out" && got=ALLOW || got=DENY
      record DENY "$got" "ALB accepterar gammal TLS 1.1 (SslPolicy TLS13-1-2)"
    fi
  else
    echo "INFO ingen HTTPS-lyssnare (inget certifikat) - bara HTTP testas"
  fi
  record 200 "$(http_code "$SITE/wp-login.php")" "inloggningssidan /wp-login.php finns (lösenord i Secrets Manager)"
  HEADERS=$(curl -skI -m 10 "$HDR_URL/")
  grep -qi '^x-frame-options: *SAMEORIGIN' <<<"$HEADERS" && grep -qi '^x-content-type-options: *nosniff' <<<"$HEADERS" \
    && got=ALLOW || got=DENY
  record ALLOW "$got" "säkerhetshuvuden skickas (X-Frame-Options, nosniff, CSP)"
  grep -qiE '^server: *apache/[0-9]' <<<"$HEADERS" && got=ALLOW || got=DENY
  record DENY "$got" "Server-huvudet avslöjar Apache-version"
  grep -qi '^x-powered-by: *php' <<<"$HEADERS" && got=ALLOW || got=DENY
  record DENY "$got" "X-Powered-By avslöjar PHP-version"
  [[ "$(http_code "$SITE/xmlrpc.php")" == 403 ]] && got=DENY || got=ALLOW
  record DENY "$got" "xmlrpc.php (gammalt API för lösenordsgissning) är åtkomligt"
  grep -qi "Index of" <<<"$(curl -s -m 10 "$SITE/wp-content/uploads/")" && got=ALLOW || got=DENY
  record DENY "$got" "kataloglistning av /wp-content/uploads/ (Options -Indexes)"
  [[ "$(http_code "$SITE/.novatrix/setup.lock")" == 403 ]] && got=DENY || got=ALLOW
  record DENY "$got" "servrarnas lås/markeringar på EFS (/.novatrix/) är åtkomliga"
  grep -qx "ok" <<<"$(curl -s -m 10 "$SITE$HEALTH_CHECK_PATH")" && got=ALLOW || got=DENY
  record ALLOW "$got" "hälsokontrollen $HEALTH_CHECK_PATH svarar ok"
  grep -qi "static page" <<<"$(curl -s -m 10 "$SITE$STATIC_URL_PATH/")" && got=ALLOW || got=DENY
  record ALLOW "$got" "statiskt innehåll från S3 under $STATIC_URL_PATH/"
fi

TEST_OK="v47-test-${STAMP}.html"
TEST_BAD="v47-test-${STAMP}.php"
echo "<p>Publicerad av V48-verifieringen ${STAMP}</p>" > "$WORK_DIR/$TEST_OK"
echo "<?php echo 'ska aldrig publiceras'; ?>" > "$WORK_DIR/$TEST_BAD"
aws s3 cp "$WORK_DIR/$TEST_OK"  "s3://$SITE_BUCKET/drafts/$TEST_OK"  --region "$REGION" --only-show-errors
aws s3 cp "$WORK_DIR/$TEST_BAD" "s3://$SITE_BUCKET/drafts/$TEST_BAD" --region "$REGION" --only-show-errors

published() { aws s3api head-object --bucket "$SITE_BUCKET" --key "web/$1" --region "$REGION" >/dev/null 2>&1; }
got=DENY
for i in $(seq 1 12); do published "$TEST_OK" && { got=ALLOW; break; }; sleep 5; done
record ALLOW "$got" "drafts/$TEST_OK publiceras till web/ av Lambdan"
published "$TEST_BAD" && got=ALLOW || got=DENY
record DENY "$got" "drafts/$TEST_BAD (otillåten filtyp) publiceras inte"

echo; echo "Senaste publiceringsloggen (väntar tills testets rader har levererats till CloudWatch):"
for i in $(seq 1 12); do
  LAMBDA_LOG=$(aws logs tail "$LOG_GROUP" --region "$REGION" --since 10m 2>&1 | grep -E "published|rejected")
  grep -q "web/$TEST_OK" <<<"$LAMBDA_LOG" && grep -q "$TEST_BAD" <<<"$LAMBDA_LOG" && break
  sleep 5
done
tail -n 6 <<<"$LAMBDA_LOG"
grep -q "web/$TEST_OK" <<<"$LAMBDA_LOG" && got=ALLOW || got=DENY
record ALLOW "$got" "Lambdan skriver sin logg med sin egen roll (raden ovan)"

# Even an administrator may NOT assume the uploader role: its trust policy
# only names the EC2 reader role.
echo
if out=$(aws sts assume-role --role-arn "$UPLOADER_ROLE_ARN" --role-session-name v47-admin-test 2>&1); then
  got=ALLOW
elif grep -qiE "AccessDenied|not authorized" <<<"$out"; then
  got=DENY
else
  got=ERROR; echo "     $out" | head -n 2
fi
record DENY "$got" "du själv (admin, utan läsarrollen) antar uppladdarrollen"

# =============================================================================
echo; echo "=== Del 3: inifrån en webbserver - via bastionen (S3 med curl och instansrollen) ==="
# =============================================================================
# Every SSH session goes laptop -> bastion (public, only your IP) -> web server
# (private IP, only from the bastion's security group). A fresh known_hosts per
# run: trust-on-first-use without clashing with other labs' private IPs.
KNOWN="$WORK_DIR/known_hosts_verify"
rm -f "$KNOWN"
SSH_BASE=(-i "$KEY_FILE" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN"
          -o ConnectTimeout=10 -o LogLevel=ERROR -o BatchMode=yes)
JUMP="ssh -i '$KEY_FILE' -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile='$KNOWN' -o ConnectTimeout=10 -o LogLevel=ERROR -o BatchMode=yes -W %h:%p ec2-user@${BASTION_IP}"

bastion()    { ssh "${SSH_BASE[@]}" ec2-user@"$BASTION_IP" "$1" 2>&1; }
remote()     { ssh "${SSH_BASE[@]}" -o "ProxyCommand=$JUMP" ec2-user@"$WEB_PRIV" "$1" 2>&1; }          # stdout+stderr
remote_out() { ssh "${SSH_BASE[@]}" -o "ProxyCommand=$JUMP" ec2-user@"$WEB_PRIV" "$1" 2>/dev/null; }   # stdout only
remote_on()  { ssh "${SSH_BASE[@]}" -o "ProxyCommand=$JUMP" ec2-user@"$1" "$2" 2>&1; }                  # any web server
remote_check() {   # expected description command
  local output got
  if output=$(remote "$3"); then
    got=ALLOW
  elif grep -qiE "AccessDenied|Access denied|command denied|not authorized|Forbidden|\(403\)| 403" <<<"$output"; then
    got=DENY
  else
    got=ERROR; echo "     $output" | head -n 3
  fi
  record "$1" "$got" "$2"
}
# Network test run ON a server: the marker tells "blocked" apart from "SSH failed".
net_check() {   # expected description bastion|remote command
  local output got
  output=$(with_timeout 30 "$3" "($4) >/dev/null 2>&1 && echo __OPPEN__ || echo __STANGD__")
  case "$output" in
    *__OPPEN__*)  got=ALLOW ;;
    *__STANGD__*) got=DENY ;;
    *)            got=ERROR; echo "     $output" | head -n 3 ;;
  esac
  record "$1" "$got" "$2"
}

SSH_OK=no
if [[ -z "$WEB_PRIV" || -z "$BASTION_IP" ]]; then
  echo "Hoppar över (ingen webbserver i gruppen, eller bastionen saknas/är stoppad)."
elif [[ ! -f "$KEY_FILE" ]]; then
  echo "Hittar inte $KEY_FILE - hoppar över SSH-testerna."
else
  echo "Bastion: $BASTION_IP ($BASTION_ID)  ->  webbserver $WEB_PRIV ($WEB_ID, $WEB_AZ)"
  remote_check ALLOW "SSH till webbservern via bastionen" "true"
  [[ -n "$WEB2_PRIV" ]] && { remote_on "$WEB2_PRIV" true >/dev/null && got=ALLOW || got=DENY
    record ALLOW "$got" "SSH till webbservern i den andra AZ:n ($WEB2_PRIV, $WEB2_AZ) via bastionen"; }
  remote "true" >/dev/null && SSH_OK=yes
fi

R="--region $REGION"
if [[ "$SSH_OK" == yes ]]; then
  echo "Instansen kör som: $(remote_out "aws sts get-caller-identity --query Arn --output text")"
  remote_check ALLOW "SSH-härdning aktiv (inga lösenord, ingen root, ingen tunnling)" \
    "sudo sshd -T | grep -qx 'passwordauthentication no' && sudo sshd -T | grep -qx 'permitrootlogin no' && sudo sshd -T | grep -qx 'allowtcpforwarding no'"
  remote_check ALLOW "curl: läsa web/index.html"      "s3-curl web/index.html | grep -qi 'static page'"
  remote_check DENY  "curl: läsa drafts/index.html"   "s3-curl drafts/index.html"
  remote_check DENY  "curl: skriva till web/"         "echo hack > /tmp/h.html && s3-curl web/hack.html /tmp/h.html"
  remote_check DENY  "cli: lista kontots buckets"     "aws s3 ls $R"
  remote_check DENY  "cli: lista IAM-användare"       "aws iam list-users"
  remote_check ALLOW "ny publicering syns under $STATIC_URL_PATH/" \
    "sudo systemctl start novatrix-sync && curl -sf http://localhost$STATIC_URL_PATH/$TEST_OK | grep -q V48"

  echo; echo "--- Role chaining: läsarrollen -> uppladdarrollen ---"
  echo "Identitet före rollbytet:  $(remote_out "aws sts get-caller-identity --query Arn --output text")"
  echo "Identitet efter rollbytet: $(remote_out "as-uploader aws sts get-caller-identity --query Arn --output text")"
  echo
  LT="logs/verifiering-${STAMP}"
  remote_check DENY  "läsarrollen: skriva logg själv" \
    "echo test | aws s3 cp - s3://$SITE_BUCKET/$LT/direkt.txt $R"
  remote_check ALLOW "läsarrollen antar uppladdarrollen" \
    "as-uploader aws sts get-caller-identity --query Arn --output text | grep -q assumed-role/$UPLOADER_ROLE/"
  remote_check ALLOW "uppladdaren: skriva till logs/" \
    "echo test | as-uploader aws s3 cp - s3://$SITE_BUCKET/$LT/via-roll.txt $R"
  remote_check DENY  "uppladdaren: läsa web/" \
    "as-uploader aws s3 cp s3://$SITE_BUCKET/web/index.html - $R"
  remote_check DENY  "uppladdaren: skriva till web/" \
    "echo hack | as-uploader aws s3 cp - s3://$SITE_BUCKET/web/hack.html $R"
  remote_check DENY  "uppladdaren: lägga utkast" \
    "echo hack | as-uploader aws s3 cp - s3://$SITE_BUCKET/drafts/hack.html $R"
  remote_check ALLOW "loggjobbet arkiverar Apache-loggarna" \
    "curl -s -o /dev/null http://localhost/ && sudo systemctl start novatrix-logs"
  n=$(aws s3api list-objects-v2 --bucket "$SITE_BUCKET" --prefix logs/i- --region "$REGION" \
        --query 'length(Contents || `[]`)' --output text 2>/dev/null)
  [[ "${n:-0}" =~ ^[0-9]+$ && "${n:-0}" -gt 0 ]] && got=ALLOW || got=DENY
  record ALLOW "$got" "arkiverade loggar finns i s3://$SITE_BUCKET/logs/ ($n st)"
  aws s3 rm "s3://$SITE_BUCKET/$LT/" --recursive --region "$REGION" --only-show-errors 2>/dev/null
fi

# =============================================================================
echo; echo "=== Del 4: WordPress mot databasen (RDS) och den delade lagringen (EFS) ==="
# =============================================================================
DB_PRIV=""
POST_ID=""
DBCLI="sudo /usr/local/bin/novatrix-db app"
WPCLI="sudo /usr/bin/php -d memory_limit=512M /usr/local/bin/wp --path=$WP_ROOT --allow-root"
if [[ "$SSH_OK" != yes ]]; then
  echo "Hoppar över (ingen SSH till webbservern)."
else
  echo "--- 4.1 Delad lagring (EFS) ---"
  echo "Monterat på $WP_ROOT:  $(remote_out "findmnt -no FSTYPE,SOURCE,OPTIONS $WP_ROOT | cut -c1-110")"
  echo "                       $(remote_out "df -h $WP_ROOT | tail -n1")"
  remote_check ALLOW "EFS monterad på $WP_ROOT, krypterad i transit (TLS-tunnel via 127.0.0.1)" \
    "findmnt -no FSTYPE,SOURCE $WP_ROOT | grep -qE '^nfs4 +127\.0\.0\.1:'"
  remote_check ALLOW "WordPress-filerna ligger på EFS (wp-config.php, wp-includes/)" \
    "test -f $WP_ROOT/wp-config.php && test -d $WP_ROOT/wp-includes"
  remote_check ALLOW "access point: root på servern skriver som apache (uid 48) på EFS" \
    "sudo touch $WP_ROOT/.v47-uid && u=\$(stat -c %u $WP_ROOT/.v47-uid); sudo rm -f $WP_ROOT/.v47-uid; [ \"\$u\" = 48 ]"
  EFS_FILE="wp-content/uploads/v47-efs-${STAMP}.txt"
  remote "echo 'V48 EFS-test $STAMP' | sudo tee $WP_ROOT/$EFS_FILE >/dev/null" >/dev/null
  # Shared storage across AZs: written on server 1, read on server 2 itself
  # (localhost - not through the ALB, which could pick server 1 again).
  if [[ -n "$WEB2_PRIV" ]]; then
    grep -q "V48 EFS-test $STAMP" <<<"$(remote_on "$WEB2_PRIV" "curl -s -m 10 http://localhost/$EFS_FILE")" && got=ALLOW || got=DENY
    record ALLOW "$got" "fil skriven på EFS av servern i $WEB_AZ serveras av servern i $WEB2_AZ"
    efs_dns="getent hosts $FS_ID.efs.$REGION.amazonaws.com | awk '{print \$1}'"
    echo "    EFS-namnet ger varje server mount target i sin EGEN AZ: $WEB_AZ -> $(remote_out "$efs_dns"),  $WEB2_AZ -> $(remote_on "$WEB2_PRIV" "$efs_dns" | tail -n1)"
  else
    echo "INFO bara en webbserver i gruppen just nu - delad lagring mellan AZ:er testas inte"
  fi
  grep -q "V48 EFS-test $STAMP" <<<"$(curl -s -m 10 "$SITE/$EFS_FILE")" && got=ALLOW || got=DENY
  record ALLOW "$got" "filen på EFS serveras genom lastbalanseraren (/$EFS_FILE)"
  PHP_FILE="wp-content/uploads/v47-${STAMP}.php"
  remote "echo '<?php echo 6*7;' | sudo tee $WP_ROOT/$PHP_FILE >/dev/null" >/dev/null
  [[ "$(curl -s -m 10 "$SITE/$PHP_FILE")" == 42 ]] && got=ALLOW || got=DENY
  record DENY "$got" "PHP-kod i uppladdningsmappen körs (uppladdat skal)"

  echo; echo "--- 4.2 Databasen (RDS) ---"
  DB_PRIV=$(remote_out "getent hosts $DB_HOST | awk '{print \$1}' | head -n1")
  echo "Databas: $DB_HOST -> $DB_PRIV"
  # Which subnet does that address live in? Must be one of the private data subnets.
  DB_SUBNET=$(aws ec2 describe-network-interfaces --region "$REGION" \
    --filters Name=addresses.private-ip-address,Values="${DB_PRIV:-none}" Name=vpc-id,Values="${VPC_ID:-none}" \
    --query 'NetworkInterfaces[0].SubnetId' --output text 2>/dev/null)
  [[ -n "$DB_SUBNET" && ( "$DB_SUBNET" == "$(stack_output DataSubnetAId)" || "$DB_SUBNET" == "$(stack_output DataSubnetBId)" ) ]] \
    && got=ALLOW || got=DENY
  record ALLOW "$got" "databasens namn pekar på en privat adress i data-nivån ($DB_PRIV i ${DB_SUBNET:-?})"
  echo "WordPress-användarens rättigheter:"
  remote_out "$DBCLI -N -e 'SHOW GRANTS'" | sed 's/IDENTIFIED BY PASSWORD .*//; s/^/    /'
  echo "Krypterad anslutning: $(remote_out "$DBCLI -N -e \"SHOW SESSION STATUS LIKE 'Ssl_version'\"" | tr '\t' ' ')"
  remote_check ALLOW "anslutningen till databasen är krypterad (TLS, servercertifikatet verifieras)" \
    "$DBCLI -N -e \"SHOW SESSION STATUS LIKE 'Ssl_cipher'\" | grep -qE 'Ssl_cipher[[:space:]]+[A-Z0-9_-]+'"
  remote_check ALLOW "WordPress-användaren läser sin databas ($DB_NAME.wp_posts)" \
    "$DBCLI -N -e 'SELECT COUNT(*) FROM $DB_NAME.wp_posts'"
  remote_check DENY  "WordPress-användaren skapar en annan databas" \
    "$DBCLI -e 'CREATE DATABASE v47_intrang'"
  remote_check DENY  "WordPress-användaren läser mysql.user (andra konton och lösenord)" \
    "$DBCLI -e 'SELECT user, host FROM mysql.user'"

  echo; echo "--- 4.3 Hela vägen: WordPress -> RDS -> webbplatsen ---"
  POST_ID=$(remote_out "$WPCLI post create --post_title='V48-test $STAMP' --post_content='Skrivet av V48-verifieringen.' --post_status=publish --porcelain" | tr -dc '0-9')
  echo "WordPress skapade inlägg ID ${POST_ID:-?}"
  remote_check ALLOW "inlägget ligger i RDS-tabellen $DB_NAME.wp_posts" \
    "$DBCLI -N -e 'SELECT post_title FROM $DB_NAME.wp_posts WHERE ID=${POST_ID:-0}' | grep -q 'V48-test $STAMP'"
  # Every server shows it - ask the ALB several times (it spreads the requests).
  seen=0
  for i in 1 2 3 4; do
    grep -q "V48-test $STAMP" <<<"$(curl -sL -m 10 "$SITE/?p=${POST_ID:-0}")" && seen=$((seen + 1))
  done
  [[ $seen -eq 4 ]] && got=ALLOW || got=DENY
  record ALLOW "$got" "inlägget visas genom lastbalanseraren, $seen av 4 anrop ($SITE/?p=${POST_ID:-0})"
fi

# =============================================================================
echo; echo "=== Del 5: backup ==="
# =============================================================================
echo "--- 5.1 S3: databasdump + wp-content, raderas automatiskt efter $BACKUP_RETENTION_DAYS dagar ---"
days=$(aws s3api get-bucket-lifecycle-configuration --bucket "$SITE_BUCKET" --region "$REGION" \
         --query "Rules[?(Filter.Prefix=='backup/' || Prefix=='backup/') && Status=='Enabled'].Expiration.Days | [0]" --output text 2>/dev/null)
record "$BACKUP_RETENTION_DAYS" "${days:-saknas}" "livscykelregel: objekt under backup/ raderas efter (dagar)"
if [[ "$SSH_OK" == yes ]]; then
  remote_check ALLOW "backupjobbet laddar upp databasdump + wp-content via uppladdarrollen" \
    "sudo NOVATRIX_BACKUP_FORCE=1 /usr/local/bin/novatrix-backup"
  LATEST_DB=$(aws s3api list-objects-v2 --bucket "$SITE_BUCKET" --prefix backup/db/ --region "$REGION" \
                --query 'sort_by(Contents || `[]`, &LastModified)[-1].Key' --output text 2>/dev/null)
  LATEST_FILES=$(aws s3api list-objects-v2 --bucket "$SITE_BUCKET" --prefix backup/files/ --region "$REGION" \
                --query 'sort_by(Contents || `[]`, &LastModified)[-1].Key' --output text 2>/dev/null)
  echo "Backuper i s3://$SITE_BUCKET/backup/ (nyaste sist):"
  aws s3 ls "s3://$SITE_BUCKET/backup/" --recursive --region "$REGION" 2>/dev/null | tail -n 4 | sed 's/^/    /'
  [[ "$LATEST_DB" == backup/db/* ]] && got=ALLOW || got=DENY
  record ALLOW "$got" "databasdump finns ($LATEST_DB)"
  [[ "$LATEST_FILES" == backup/files/* ]] && got=ALLOW || got=DENY
  record ALLOW "$got" "wp-content-arkiv finns ($LATEST_FILES)"
  # Binary download: bypass the \r-stripping aws() wrapper.
  n=$(command aws s3 cp "s3://$SITE_BUCKET/$LATEST_DB" - --region "$REGION" 2>/dev/null | gzip -dc 2>/dev/null | grep -c 'CREATE TABLE')
  [[ "${n:-0}" -ge 10 ]] && got=ALLOW || got=DENY
  record ALLOW "$got" "dumpen innehåller WordPress-tabellerna ($n CREATE TABLE)"
  remote_check DENY "läsarrollen (webbservern) laddar ner en backup" \
    "aws s3 cp s3://$SITE_BUCKET/$LATEST_DB /tmp/b.gz $R"
  remote_check DENY "uppladdaren raderar en backup (en angripare kan inte förstöra dem)" \
    "as-uploader aws s3 rm s3://$SITE_BUCKET/$LATEST_DB $R"
  # All servers run the daily backup timer, but they share EFS and RDS: only the
  # first one per day may take it (marker on EFS), the others must skip.
  if [[ -n "$WEB2_PRIV" ]]; then
    count_db() { aws s3api list-objects-v2 --bucket "$SITE_BUCKET" --prefix backup/db/ --region "$REGION" \
                   --query 'length(Contents || `[]`)' --output text 2>/dev/null; }
    remote "sudo /usr/local/bin/novatrix-backup" >/dev/null    # takes today's backup, or skips if taken
    before=$(count_db)
    out=$(remote_on "$WEB2_PRIV" "sudo /usr/local/bin/novatrix-backup")
    after=$(count_db)
    echo "    server 2 ($WEB2_AZ): $(tail -n1 <<<"$out")"
    [[ "$before" == "$after" ]] && got=ALLOW || got=DENY
    record ALLOW "$got" "bara EN server tar dygnets backup ($before dumpar före, $after efter server 2:s försök)"
  fi
fi

echo; echo "--- 5.2 RDS automatisk backup ---"
read -r ret window latest <<<"$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$DB_INSTANCE_ID" \
  --query 'DBInstances[0].[BackupRetentionPeriod, PreferredBackupWindow, LatestRestorableTime]' --output text 2>/dev/null)"
echo "Lagringstid: ${ret:-?} dag(ar)   backupfönster (UTC): ${window:-?}   senaste återställningspunkt: ${latest:-?}"
record "$DB_BACKUP_RETENTION_DAYS" "${ret:-saknas}" "RDS automatisk backup: lagringstid (dagar)"
n=$(aws rds describe-db-snapshots --region "$REGION" --db-instance-identifier "$DB_INSTANCE_ID" \
      --snapshot-type automated --query 'length(DBSnapshots)' --output text 2>/dev/null)
[[ "${n:-0}" =~ ^[0-9]+$ && "${n:-0}" -ge 1 ]] && got=ALLOW || got=DENY
record ALLOW "$got" "RDS har automatiska snapshots ($n st)"
[[ -n "${latest:-}" && "$latest" != None ]] && got=ALLOW || got=DENY
record ALLOW "$got" "point-in-time restore möjlig (senaste återställningspunkt finns)"

# =============================================================================
echo; echo "=== Del 6: nätverket och lagren runt databasen ==="
# =============================================================================
if [[ -z "$VPC_ID" ]]; then
  echo "Stacken $STACK_NETWORK finns inte - kör ./V48_novatrix.sh först."
else
MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')
declare -A NAMES   # resource id -> readable name, used in the tables
for k in MgmtSubnetAId:mgmt-a WebSubnetAId:web-a WebSubnetBId:web-b DataSubnetAId:data-a DataSubnetBId:data-b \
         BastionSgId:bastion-sg WebSgId:web-sg AlbSgId:alb-sg DbSgId:db-sg EfsSgId:efs-sg S3EndpointId:s3-endpoint; do
  id=$(stack_output "${k%%:*}")
  [[ -n "$id" ]] && NAMES[$id]=${k##*:}
done
name_of() { local id=$1; [[ -z "$id" ]] && { echo "-"; return; }; echo "${NAMES[$id]:-$id}"; }

echo; echo "--- 6.1 Segmentering: subnät och route tables (som AWS ser dem) ---"
printf '%-8s %-15s %-12s %-24s %s\n' SUBNÄT CIDR AZ "ROUTE TABLE" "VÄG TILL INTERNET"
for key in MgmtSubnetAId WebSubnetAId WebSubnetBId DataSubnetAId DataSubnetBId; do
  sid=$(stack_output "$key")
  read -r cidr az <<<"$(aws ec2 describe-subnets --region "$REGION" --subnet-ids "$sid" \
      --query 'Subnets[0].[CidrBlock,AvailabilityZone]' --output text)"
  read -r rt igw <<<"$(aws ec2 describe-route-tables --region "$REGION" \
      --filters Name=association.subnet-id,Values="$sid" \
      --query 'RouteTables[0].[RouteTableId, Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId | [0]]' --output text)"
  printf '%-8s %-15s %-12s %-24s %s\n' "$(name_of "$sid")" "$cidr" "$az" "$rt" "$([[ "$igw" == igw-* ]] && echo "ja -> $igw" || echo "NEJ (endast lokalt)")"
done
echo
PUB_RT=$(stack_output PublicRouteTableId); PRIV_RT=$(stack_output PrivateRouteTableId)
for rt in "$PUB_RT" "$PRIV_RT"; do
  echo "Rutter i $rt:"
  aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$rt" \
    --query 'RouteTables[0].Routes[].[DestinationCidrBlock || DestinationPrefixListId, GatewayId, State]' --output text \
    | awk '{ printf "    %-22s -> %-24s %s\n", $1, $2, $3 }'
done
n=$(aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$PRIV_RT" \
      --query 'length(RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`])' --output text)
[[ "$n" == "0" ]] && got=DENY || got=ALLOW
record DENY "$got" "privata subnät (RDS, EFS) har en väg till internet"
n=$(aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$PUB_RT" \
      --query "length(RouteTables[0].Routes[?GatewayId=='$(stack_output S3EndpointId)'])" --output text)
[[ "$n" -ge 1 ]] 2>/dev/null && got=ALLOW || got=DENY
record ALLOW "$got" "publika subnät når S3 via gateway endpoint (inte via internet)"
n=$(aws ec2 describe-security-group-rules --region "$REGION" \
      --filters Name=group-id,Values="$(stack_output DefaultSecurityGroupId)" \
      --query 'length(SecurityGroupRules)' --output text)
[[ "$n" == "0" ]] && got=DENY || got=ALLOW
record DENY "$got" "VPC:ns default security group har några regler ($n st)"

echo; echo "--- 6.2 Databasen och den delade lagringen (som AWS ser dem) ---"
read -r engine ver class storage stype enc multiaz public dbaz <<<"$(aws rds describe-db-instances --region "$REGION" \
  --db-instance-identifier "$DB_INSTANCE_ID" \
  --query 'DBInstances[0].[Engine, EngineVersion, DBInstanceClass, AllocatedStorage, StorageType, StorageEncrypted, MultiAZ, PubliclyAccessible, AvailabilityZone]' \
  --output text 2>/dev/null)"
echo "RDS $DB_INSTANCE_ID: $engine $ver, $class, ${storage} GiB $stype, krypterad=$enc, Multi-AZ=$multiaz, publik=$public, AZ $dbaz"
[[ "$public" == True ]] && got=ALLOW || got=DENY
record DENY "$got" "databasen är publikt åtkomlig (PubliclyAccessible)"
[[ "$enc" == True ]] && got=ALLOW || got=DENY
record ALLOW "$got" "databasen är krypterad i vila"
DBSG=$(aws rds describe-db-subnet-groups --region "$REGION" --db-subnet-group-name "$(stack_output DbSubnetGroupName)" \
         --query 'DBSubnetGroups[0].Subnets[].SubnetIdentifier' --output text 2>/dev/null)
[[ "$DBSG" == *"$(stack_output DataSubnetAId)"* && "$DBSG" == *"$(stack_output DataSubnetBId)"* && $(wc -w <<<"$DBSG") -eq 2 ]] && got=ALLOW || got=DENY
record ALLOW "$got" "databasens subnet group består bara av de privata subnäten data-a + data-b"
DB_SGS=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$DB_INSTANCE_ID" \
           --query 'DBInstances[0].VpcSecurityGroups[].VpcSecurityGroupId' --output text 2>/dev/null)
[[ "$DB_SGS" == "$(stack_output DbSgId)" ]] && got=ALLOW || got=DENY
record ALLOW "$got" "databasen har bara security group db-sg"

read -r fs_enc fs_mode fs_tp fs_size <<<"$(aws efs describe-file-systems --region "$REGION" --file-system-id "$FS_ID" \
  --query 'FileSystems[0].[Encrypted, PerformanceMode, ThroughputMode, SizeInBytes.Value]' --output text 2>/dev/null)"
echo "EFS $FS_ID: krypterad=$fs_enc, $fs_mode, $fs_tp, $(( ${fs_size:-0} / 1024 / 1024 )) MiB använt"
[[ "$fs_enc" == True ]] && got=ALLOW || got=DENY
record ALLOW "$got" "EFS är krypterad i vila"
echo "Mount targets:"
EFS_IP_A=""; EFS_IP_B=""; mt_ok=yes
while read -r sid mip maz; do
  [[ -z "${sid:-}" ]] && continue
  printf '    %-8s %-15s %s\n' "$(name_of "$sid")" "$mip" "$maz"
  case "$(name_of "$sid")" in data-a) EFS_IP_A=$mip ;; data-b) EFS_IP_B=$mip ;; *) mt_ok=no ;; esac
done <<<"$(aws efs describe-mount-targets --region "$REGION" --file-system-id "$FS_ID" \
             --query 'MountTargets[].[SubnetId, IpAddress, AvailabilityZoneName]' --output text 2>/dev/null)"
[[ "$mt_ok" == yes && -n "$EFS_IP_A" ]] && got=ALLOW || got=DENY
record ALLOW "$got" "EFS mount targets finns bara i de privata subnäten"
POLICY=$(aws efs describe-file-system-policy --region "$REGION" --file-system-id "$FS_ID" --query Policy --output text 2>/dev/null)
grep -q 'aws:SecureTransport' <<<"$POLICY" && grep -q "$EC2_ROLE" <<<"$POLICY" && got=ALLOW || got=DENY
record ALLOW "$got" "EFS-policyn kräver TLS och tillåter bara webbserverrollen"

echo; echo "--- 6.3 Security groups (stateful - svarstrafik släpps automatiskt) ---"
fmt_proto() { case "$1" in -1) echo alla ;; *) echo "$1" ;; esac; }
for key in AlbSgId WebSgId BastionSgId DbSgId EfsSgId; do
  sg=$(stack_output "$key")
  echo "$(name_of "$sg") ($sg):"
  aws ec2 describe-security-group-rules --region "$REGION" --filters Name=group-id,Values="$sg" \
    --query 'SecurityGroupRules[].[IsEgress, IpProtocol, FromPort, ToPort, CidrIpv4 || ReferencedGroupInfo.GroupId || PrefixListId]' \
    --output text | sort | while read -r egress proto from to peer; do
      if [[ "$proto" == icmp ]]; then ports="typ $from kod $to"
      elif [[ "$from" == "-1" ]]; then ports="alla"
      elif [[ "$from" == "$to" ]]; then ports="$from"
      else ports="$from-$to"; fi
      [[ "$egress" == "True" ]] && dir="UT  till" || dir="IN  från"
      printf '    TILLÅT %s %-28s %-5s port %s\n' "$dir" "$(name_of "$peer")" "$(fmt_proto "$proto")" "$ports"
    done
  echo "    (allt annat: BLOCKERAS)"
done

echo; echo "--- 6.4 Network ACL:er (stateless - regler prövas i nummerordning, första träff gäller) ---"
for key in MgmtNaclId WebNaclId DataNaclId; do
  acl=$(stack_output "$key")
  label=${key%NaclId}; label=$(tr '[:upper:]' '[:lower:]' <<<"$label")
  echo "nacl-$label ($acl):"
  aws ec2 describe-network-acls --region "$REGION" --network-acl-ids "$acl" \
    --query 'NetworkAcls[0].Entries[].[Egress, RuleNumber, RuleAction, Protocol, CidrBlock, PortRange.From, PortRange.To, IcmpTypeCode.Type, IcmpTypeCode.Code]' \
    --output text | sort -k1,1 -k2,2n | while read -r egress nr action proto cidr from to itype icode; do
      case "$proto" in 6) p=tcp ;; 17) p=udp ;; 1) p=icmp ;; -1) p=alla ;; *) p=$proto ;; esac
      if [[ "$p" == icmp ]]; then ports="typ $itype kod $icode"
      elif [[ "$from" == "None" ]]; then ports="alla"
      elif [[ "$from" == "$to" ]]; then ports="$from"
      else ports="$from-$to"; fi
      [[ "$nr" == "32767" ]] && nr="*"
      [[ "$egress" == "True" ]] && dir="UT " || dir="IN "
      printf '    %s %5s  %-6s %-4s %-18s port %s\n' "$dir" "$nr" "$(tr '[:lower:]' '[:upper:]' <<<"$action")" "$p" "$cidr" "$ports"
    done
done

echo; echo "--- 6.5 Från internet (den här datorn, $MY_IP) ---"
if [[ -n "$ALB_DNS" ]]; then
  ALB_TESTS=("80:ALLOW:HTTP" "22:DENY:SSH" "${DB_PORT}:DENY:databasporten" "8080:DENY:alternativ webbport")
  [[ "$HTTPS_ON" == yes ]] && ALB_TESTS+=("443:ALLOW:HTTPS")
  for t in "${ALB_TESTS[@]}"; do
    port=${t%%:*}; rest=${t#*:}; exp=${rest%%:*}; desc=${rest#*:}
    probe "$ALB_DNS" "$port" && got=ALLOW || got=DENY
    record "$exp" "$got" "lastbalanseraren :$port  ($desc)"
  done
fi
if [[ -n "$WEB_PUB" ]]; then
  # The web servers still have a public IP (for their own outbound traffic),
  # but NOTHING answers on it: visitors must go through the ALB.
  for t in "80:DENY:HTTP direkt till webbservern, förbi ALB" "443:DENY:HTTPS direkt till webbservern" \
           "22:DENY:SSH direkt till webbservern" "${DB_PORT}:DENY:databasporten" "2049:DENY:NFS" \
           "8080:DENY:alternativ webbport" "3389:DENY:RDP"; do
    port=${t%%:*}; rest=${t#*:}; exp=${rest%%:*}; desc=${rest#*:}
    probe "$WEB_PUB" "$port" && got=ALLOW || got=DENY
    record "$exp" "$got" "webbserver $WEB_PUB:$port  ($desc)"
  done
fi
if [[ -n "$BASTION_IP" ]]; then
  for t in "22:ALLOW:SSH från din IP" "80:DENY:HTTP" "443:DENY:HTTPS"; do
    port=${t%%:*}; rest=${t#*:}; exp=${rest%%:*}; desc=${rest#*:}
    probe "$BASTION_IP" "$port" && got=ALLOW || got=DENY
    record "$exp" "$got" "bastion $BASTION_IP:$port  ($desc)"
  done
fi
echo "    (databasen och EFS har ingen publik IP och deras subnät ingen väg till internet - de kan inte"
echo "     ens adresseras härifrån; se 6.1-6.2)"

if [[ "$SSH_OK" == yes ]]; then
  echo; echo "--- 6.6 Från bastionen (hoppserver: får bara vidarebefordra SSH) ---"
  net_check ALLOW "bastion -> webbserver $WEB_PRIV:22 (SSH)"   bastion "timeout 5 bash -c '</dev/tcp/$WEB_PRIV/22'"
  net_check DENY  "bastion -> webbserver $WEB_PRIV:80 (HTTP)"  bastion "timeout 5 bash -c '</dev/tcp/$WEB_PRIV/80'"
  net_check DENY  "bastion -> databasen $DB_HOST:$DB_PORT"     bastion "timeout 5 bash -c '</dev/tcp/$DB_HOST/$DB_PORT'"
  [[ -n "$EFS_IP_A" ]] && net_check DENY "bastion -> EFS $EFS_IP_A:2049" bastion "timeout 5 bash -c '</dev/tcp/$EFS_IP_A/2049'"
  net_check DENY  "bastion -> internet :443 (ladda ner verktyg/exfiltrera)" bastion "curl -s -m 6 -o /dev/null https://checkip.amazonaws.com"
  out=$(bastion "sudo sshd -T | grep -x 'permitopen \*:22' && sudo sshd -T | grep -x 'passwordauthentication no'")
  [[ $(grep -c . <<<"$out") -eq 2 ]] && got=ALLOW || got=DENY
  record ALLOW "$got" "bastionens SSH-härdning aktiv (PermitOpen *:22, inga lösenord)"
  # sshd on the bastion only forwards to port 22 (PermitOpen *:22): it can't be
  # used as a tunnel to the web server's port 80 or the database. ssh prints the
  # refusal ("administratively prohibited") at INFO level. The first tunnel, to
  # the allowed port 22, proves the test can tell "open" from "refused".
  tunnel_check() {   # expected description host:port
    local out got
    out=$(with_timeout 20 ssh -i "$KEY_FILE" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN" \
            -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=INFO \
            -W "$3" ec2-user@"$BASTION_IP" </dev/null 2>&1)
    if grep -qi "administratively prohibited" <<<"$out"; then got=DENY
    elif grep -q "SSH-2.0" <<<"$out"; then got=ALLOW
    else got=ERROR; echo "     $(head -n 3 <<<"$out")"; fi
    record "$1" "$got" "$2"
  }
  tunnel_check ALLOW "SSH-tunnel genom bastionen till port 22 (kontroll: tillåten port)" "127.0.0.1:22"
  tunnel_check DENY  "SSH-tunnel genom bastionen till $WEB_PRIV:80 (sshd PermitOpen)" "$WEB_PRIV:80"
  tunnel_check DENY  "SSH-tunnel genom bastionen till databasen $DB_HOST:$DB_PORT" "$DB_HOST:$DB_PORT"

  echo; echo "--- 6.7 Från webbservern (det en angripare som tagit över WordPress skulle försöka) ---"
  net_check ALLOW "webb -> databasen $DB_HOST:$DB_PORT (WordPress)" remote "timeout 5 bash -c '</dev/tcp/$DB_HOST/$DB_PORT'"
  [[ -n "$EFS_IP_A" ]] && net_check ALLOW "webb -> EFS $EFS_IP_A:2049 (samma AZ)" remote "timeout 5 bash -c '</dev/tcp/$EFS_IP_A/2049'"
  net_check ALLOW "webb -> internet :443 (S3, STS, SSM, wordpress.org)" remote "curl -s -m 8 -o /dev/null https://checkip.amazonaws.com"
  net_check DENY  "webb -> internet :80 (okrypterad trafik ut)"    remote "curl -s -m 6 -o /dev/null http://checkip.amazonaws.com"
  net_check DENY  "webb -> internet :22 (SSH ut till angriparens server)" remote "timeout 5 bash -c '</dev/tcp/github.com/22'"
  net_check DENY  "webb -> internet :$DB_PORT (databasdump ut till angriparens server)" remote "timeout 5 bash -c '</dev/tcp/portquiz.net/$DB_PORT'"
  net_check DENY  "webb -> bastion $BASTION_PRIV:22 (bakåt mot admin-zonen)" remote "timeout 5 bash -c '</dev/tcp/$BASTION_PRIV/22'"
  net_check ALLOW "webb -> S3 via endpoint (statiskt innehåll)"   remote "s3-curl web/index.html"

  echo; echo "--- 6.8 Stulna nycklar: instansrollens credentials används UTANFÖR VPC:n ---"
  # Simulates credential theft (e.g. SSRF against the metadata service): read the
  # role's temporary keys on the server and use them from this computer instead.
  # The keys are never printed.
  CREDS=$(ssh "${SSH_BASE[@]}" -o "ProxyCommand=$JUMP" ec2-user@"$WEB_PRIV" 'bash -s' 2>/dev/null <<'EOF'
TOKEN=$(curl -sf -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
ROLE=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/iam/security-credentials/)
curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/iam/security-credentials/$ROLE" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["AccessKeyId"], d["SecretAccessKey"], d["Token"])'
EOF
)
  read -r AK SK ST <<<"$CREDS"
  stolen() { env -u AWS_PROFILE AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" AWS_SESSION_TOKEN="$ST" "$@"; }
  if [[ -z "${ST:-}" ]]; then
    record ALLOW ERROR "kunde inte hämta instansrollens nycklar för testet"
  else
    out=$(stolen aws sts get-caller-identity --query Arn --output text 2>&1)
    [[ "$out" == *"assumed-role/$EC2_ROLE/"* ]] && got=ALLOW || got=DENY
    record ALLOW "$got" "de stulna nycklarna är giltiga (sts get-caller-identity)"
    if out=$(stolen aws s3 cp "s3://$SITE_BUCKET/web/index.html" - --region "$REGION" 2>&1); then got=ALLOW
    elif grep -qi "AccessDenied\|Forbidden\|403" <<<"$out"; then got=DENY
    else got=ERROR; echo "     $(head -n 2 <<<"$out")"; fi
    record DENY "$got" "...men S3 nekar dem utanför VPC:n (bucket policy aws:SourceVpce)"
    # Honest limit: Secrets Manager is reached over the internet (an interface
    # endpoint costs ~8 USD/month per AZ), so the stolen keys CAN read the DB
    # password - but the database is only reachable from the web tier, so it
    # is useless out here.
    if stolen aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SECRET_APP" >/dev/null 2>&1; then
      echo "INFO ...de kan läsa DB-lösenordet i Secrets Manager (ingen VPC-endpoint), men databasen nås bara"
      echo "     från web-sg/$(stack_output WebTierCidr): utan fotfäste i VPC:n är lösenordet oanvändbart (se 6.2 och 6.5)."
    fi
  fi
  unset AK SK ST CREDS
fi

echo; echo "--- 6.9 VPC flow logs: AWS:s egen logg över släppt (ACCEPT) och blockerad (REJECT) trafik ---"
# Flow logs are aggregated per minute and delivered to CloudWatch a few
# minutes later, so poll for the records of the attempts made above.
flow() {   # src dst dstport action -> matching records
  aws logs filter-log-events --region "$REGION" --log-group-name "$FLOW_LOG_GROUP" --start-time "$START_MS" \
    --filter-pattern "[version, account, eni, src=\"$1\", dst=\"$2\", srcport, dstport=$3, protocol=6, packets, bytes, start, end, action=\"$4\", status]" \
    --query 'events[].message' --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$'
}
if [[ -n "$WEB_PUB" && -n "$BASTION_IP" ]]; then
  echo "Format: version konto ENI källa mål källport målport protokoll paket bytes start slut BESLUT status"
  echo "Väntar på leverans (upp till 6 minuter)..."
  # One of the ALB's own private addresses (its network interface in our VPC)
  ALB_PRIV=$(aws ec2 describe-network-interfaces --region "$REGION" \
    --filters Name=vpc-id,Values="$VPC_ID" Name=description,Values="ELB $(stack_output AlbFullName)" \
    --query 'NetworkInterfaces[0].PrivateIpAddress' --output text 2>/dev/null)
  WANT=("$MY_IP $WEB_PRIV 80 REJECT HTTP direkt till webbservern (förbi ALB)"
        "$MY_IP $WEB_PRIV 22 REJECT SSH direkt till webbservern"
        "$MY_IP $WEB_PRIV $DB_PORT REJECT databasporten på webbservern"
        "$MY_IP $BASTION_PRIV 22 ACCEPT SSH till bastionen")
  [[ "$ALB_PRIV" =~ ^10\. ]] && WANT+=("$ALB_PRIV $WEB_PRIV 80 ACCEPT lastbalanseraren -> webbservern (trafik + hälsokontroll)")
  [[ -n "$DB_PRIV" ]]  && WANT+=("$WEB_PRIV $DB_PRIV $DB_PORT ACCEPT webbserver -> databasen (RDS)")
  [[ -n "$EFS_IP_A" && "$SSH_OK" == yes ]] && WANT+=("$WEB_PRIV $EFS_IP_A 2049 ACCEPT webbserver -> EFS")
  declare -A FOUND=()
  for i in $(seq 1 24); do
    for w in "${WANT[@]}"; do
      read -r s d p a _ <<<"$w"
      [[ -n "${FOUND[$w]:-}" ]] && continue
      line=$(flow "$s" "$d" "$p" "$a" | head -n 1)
      [[ -n "$line" ]] && FOUND[$w]=$line
    done
    [[ ${#FOUND[@]} -eq ${#WANT[@]} ]] && break
    sleep 15
  done
  for w in "${WANT[@]}"; do
    read -r s d p a desc <<<"$w"
    if [[ -n "${FOUND[$w]:-}" ]]; then
      record "$a" "$a" "flödeslogg: $desc"
      echo "       ${FOUND[$w]}"
    else
      echo "INFO flödeslogg: $desc - ingen post levererad ännu (kör testet igen om en stund)"
    fi
  done
fi
fi   # end: stack exists

# =============================================================================
echo; echo "=== Del 7: hög tillgänglighet - lastbalanserare och Auto Scaling-grupp ==="
# =============================================================================
LT_LATEST=$(stack_output WebLaunchTemplateVersion)
asg_field() {   # JMESPath under AutoScalingGroups[0]
  aws autoscaling describe-auto-scaling-groups --region "$REGION" --auto-scaling-group-names "$ASG" \
    --query "AutoScalingGroups[0].$1" --output text 2>/dev/null
}
hint=15; hbad=3
if [[ -z "$ASG" || -z "$ALB_DNS" ]]; then
  echo "Stacken $STACK_COMPUTE saknas - hoppar över."
else
  echo "--- 7.1 Lastbalanseraren ---"
  read -r scheme state <<<"$(aws elbv2 describe-load-balancers --region "$REGION" --names "$ALB_NAME" \
    --query 'LoadBalancers[0].[Scheme, State.Code]' --output text 2>/dev/null)"
  ALB_AZS=$(aws elbv2 describe-load-balancers --region "$REGION" --names "$ALB_NAME" \
    --query 'LoadBalancers[0].AvailabilityZones[].ZoneName' --output text 2>/dev/null)
  echo "$ALB_NAME: $scheme, $state, noder i: $ALB_AZS"
  record active "${state:-saknas}" "lastbalanseraren är aktiv"
  [[ $(wc -w <<<"$ALB_AZS") -ge 2 ]] && got=ALLOW || got=DENY
  record ALLOW "$got" "lastbalanseraren har noder i minst två AZ ($ALB_AZS)"
  echo "Lyssnare:"
  aws elbv2 describe-listeners --region "$REGION" --load-balancer-arn "$(stack_output AlbArn)" \
    --query 'Listeners[].[Port, Protocol, SslPolicy]' --output text 2>/dev/null \
    | sort -n | awk '{ printf "    port %-4s %-6s %s\n", $1, $2, ($3=="None" ? "" : $3) }'
  read -r hpath hint hok hbad <<<"$(aws elbv2 describe-target-groups --region "$REGION" --target-group-arns "$TG_ARN" \
    --query 'TargetGroups[0].[HealthCheckPath, HealthCheckIntervalSeconds, HealthyThresholdCount, UnhealthyThresholdCount]' \
    --output text 2>/dev/null)"
  hint=${hint:-15}; hbad=${hbad:-3}
  echo "Hälsokontroll: GET $hpath var ${hint}s - frisk efter $hok OK, ur rotation efter $hbad fel ($(( hint * hbad ))s)"

  echo; echo "--- 7.2 Auto Scaling-gruppen ---"
  read -r min max desired hctype grace <<<"$(asg_field '[MinSize, MaxSize, DesiredCapacity, HealthCheckType, HealthCheckGracePeriod]')"
  echo "$ASG: min $min, max $max, önskat nu $desired, hälsokontroll $hctype (grace ${grace}s)"
  record ELB "${hctype:-saknas}" "gruppen byter ut servrar som lastbalanseraren underkänner (HealthCheckType)"
  [[ "${min:-0}" -ge 2 ]] && got=ALLOW || got=DENY
  record ALLOW "$got" "minst två webbservrar hela tiden (MinSize $min)"
  SUBNETS=$(asg_field VPCZoneIdentifier)
  [[ "$SUBNETS" == *"$(stack_output WebSubnetAId)"* && "$SUBNETS" == *"$(stack_output WebSubnetBId)"* ]] && got=ALLOW || got=DENY
  record ALLOW "$got" "gruppen startar servrar i både web-a och web-b"
  declare -A TH=()
  while read -r tid tstate; do [[ -n "${tid:-}" ]] && TH[$tid]=$tstate; done <<<"$(aws elbv2 describe-target-health \
    --region "$REGION" --target-group-arn "$TG_ARN" \
    --query 'TargetHealthDescriptions[].[Target.Id, TargetHealth.State]' --output text 2>/dev/null)"
  printf '    %-20s %-12s %-11s %-9s %-10s %s\n' INSTANS AZ LIVSCYKEL ASG-HÄLSA ALB-HÄLSA "LT-VERSION"
  AZ_SET=""; OLD_LT=0
  while read -r id az life health ltv; do
    [[ -z "${id:-}" ]] && continue
    printf '    %-20s %-12s %-11s %-9s %-10s %s\n' "$id" "$az" "$life" "$health" "${TH[$id]:-?}" "$ltv"
    [[ "$life" == InService ]] && AZ_SET+="$az"$'\n'
    [[ "$ltv" != "$LT_LATEST" ]] && OLD_LT=$((OLD_LT + 1))
  done <<<"$(asg_field 'Instances[].[InstanceId, AvailabilityZone, LifecycleState, HealthStatus, LaunchTemplate.Version]')"
  n_az=$(sort -u <<<"$AZ_SET" | grep -c .)
  [[ $n_az -ge 2 ]] && got=ALLOW || got=DENY
  record ALLOW "$got" "webbservrarna är spridda över $n_az AZ"
  hc=$(healthy_count)
  [[ "${hc:-0}" -ge "${desired:-99}" ]] && got=ALLOW || got=DENY
  record ALLOW "$got" "alla önskade servrar är friska i lastbalanseraren ($hc av $desired)"
  [[ $OLD_LT -eq 0 ]] && got=ALLOW || got=DENY
  record ALLOW "$got" "alla servrar kör senaste launch template-versionen ($LT_LATEST) - inget halvfärdigt utrullat"

  echo; echo "--- 7.3 Skalning: target tracking (AWS skapar larmen själv) ---"
  aws autoscaling describe-policies --region "$REGION" --auto-scaling-group-name "$ASG" \
    --query 'ScalingPolicies[].[TargetTrackingConfiguration.PredefinedMetricSpecification.PredefinedMetricType, TargetTrackingConfiguration.TargetValue]' \
    --output text 2>/dev/null | awk '{ printf "    håll %-26s runt %s\n", $1, $2 }'
  n=$(aws autoscaling describe-policies --region "$REGION" --auto-scaling-group-name "$ASG" \
        --query "length(ScalingPolicies[?PolicyType=='TargetTrackingScaling'])" --output text 2>/dev/null)
  record 2 "${n:-0}" "skalningspolicyer: CPU och anrop per server (target tracking)"
  n=$(aws cloudwatch describe-alarms --region "$REGION" --alarm-name-prefix "TargetTracking-$ASG" \
        --query 'length(MetricAlarms)' --output text 2>/dev/null)
  echo "    CloudWatch-larm som target tracking skapat: ${n:-0} (ett för hög och ett för låg last per policy)"
  echo "Senaste aktiviteterna i gruppen:"
  aws autoscaling describe-scaling-activities --region "$REGION" --auto-scaling-group-name "$ASG" --no-paginate --max-records 5 \
    --query 'Activities[].[StartTime, StatusCode, Description]' --output text 2>/dev/null \
    | cut -c1-140 | sed 's/^/    /'
fi

# =============================================================================
echo; echo "=== Del 9: central monitorering och loggning (CloudWatch, SNS, site check) ==="
# =============================================================================
# Helpers: newest value of a metric over the last 15 minutes (empty if none),
# an alarm's state, the deployed filter pattern of a log group.
metric_last() {   # statistic namespace metric dimension...
  local st=$1 ns=$2 m=$3; shift 3
  aws cloudwatch get-metric-statistics --region "$REGION" --namespace "$ns" --metric-name "$m" --dimensions "$@" \
    --start-time "$(date -u -d '-15 min' +%Y-%m-%dT%H:%M:%SZ)" --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 300 --statistics "$st" --query "sort_by(Datapoints, &Timestamp)[-1].$st" --output text 2>/dev/null
}
alarm_state() {
  aws cloudwatch describe-alarms --region "$REGION" --alarm-names "$1" --query 'MetricAlarms[0].StateValue' --output text 2>/dev/null
}
TOPIC_ARN=$(stack_output AlarmTopicArn)
if [[ -z "$TOPIC_ARN" ]]; then
  echo "Stacken $STACK_MONITORING saknas - hoppar över."
else
  echo "--- 9.1 Larmkanalen: SNS -> e-post ---"
  read -r sub_arn sub_to <<<"$(aws sns list-subscriptions-by-topic --region "$REGION" --topic-arn "$TOPIC_ARN" \
    --query "Subscriptions[?Protocol=='email'] | [0].[SubscriptionArn, Endpoint]" --output text 2>/dev/null)"
  echo "Ämne: $TOPIC_ARN  ->  e-post ${sub_to:-saknas}"
  [[ "${sub_arn:-}" == arn:* ]] && got=ALLOW || got=DENY
  record ALLOW "$got" "e-postprenumerationen är bekräftad (${sub_arn:-saknas})"
  [[ "$got" == DENY ]] && echo "     Klicka på länken i mejlet \"AWS Notification - Subscription Confirmation\" - annars levereras inga larm."

  echo; echo "--- 9.2 Larmen (critical: mejl vid ALARM och OK, warning: mejl vid ALARM) ---"
  cmp_sym() { case "$1" in GreaterThanOrEqualToThreshold) echo ">=" ;; GreaterThanThreshold) echo ">" ;;
              LessThanThreshold) echo "<" ;; LessThanOrEqualToThreshold) echo "<=" ;; *) echo "$1" ;; esac; }
  ALARMS=$(aws cloudwatch describe-alarms --region "$REGION" --alarm-name-prefix "${PROJECT}-" --alarm-types MetricAlarm \
    --query "MetricAlarms[].[AlarmName, StateValue, contains(AlarmActions, '$TOPIC_ARN'), contains(OKActions, '$TOPIC_ARN'), MetricName || 'metric math', ComparisonOperator, Threshold]" \
    --output text 2>/dev/null)
  printf '    %-30s %-18s %-5s %-7s %s\n' LARM TILLSTÅND MEJL OK-MEJL VILLKOR
  n=0; no_mail=0; crit_no_ok=0; crit_alarm=""
  while IFS=$'\t' read -r name state on_alarm on_ok metric cmp thr; do
    [[ -z "${name:-}" ]] && continue
    n=$((n + 1))
    [[ "$on_alarm" == True ]] || no_mail=$((no_mail + 1))
    if [[ "$name" == "${PROJECT}-critical-"* ]]; then
      [[ "$on_ok" == True ]] || crit_no_ok=$((crit_no_ok + 1))
      [[ "$state" == ALARM ]] && crit_alarm+=" ${name#"${PROJECT}"-}"
    fi
    printf '    %-30s %-18s %-5s %-7s %s\n' "${name#"${PROJECT}"-}" "$state" \
      "$([[ "$on_alarm" == True ]] && echo ja || echo NEJ)" "$([[ "$on_ok" == True ]] && echo ja || echo -)" \
      "$metric $(cmp_sym "$cmp") ${thr%.0}"
  done <<<"$ALARMS"
  record 16 "$n" "antal larm (7 critical + 9 warning)"
  [[ $n -gt 0 && $no_mail -eq 0 ]] && got=ALLOW || got=DENY
  record ALLOW "$got" "alla larm mejlar via SNS när de går i ALARM"
  [[ $n -gt 0 && $crit_no_ok -eq 0 ]] && got=ALLOW || got=DENY
  record ALLOW "$got" "alla critical-larm mejlar även när de är OK igen"
  [[ -n "$crit_alarm" ]] && got=ALLOW || got=DENY
  record DENY "$got" "något critical-larm är i ALARM just nu${crit_alarm:+ (${crit_alarm# })}"
  n=$(aws cloudwatch describe-alarms --region "$REGION" --alarm-name-prefix "TargetTracking-$ASG" \
        --query 'length(MetricAlarms)' --output text 2>/dev/null)
  echo "    (plus ${n:-0} larm som target tracking äger - de skalar gruppen, de mejlar inte)"
  echo "Senaste larmhändelserna (24 h):"
  aws cloudwatch describe-alarm-history --region "$REGION" --history-item-type StateUpdate \
    --start-date "$(date -u -d '-24 hours' +%Y-%m-%dT%H:%M:%SZ)" --no-paginate --max-records 100 \
    --query "AlarmHistoryItems[?starts_with(AlarmName, '${PROJECT}-')] | [:8].[Timestamp, AlarmName, HistorySummary]" \
    --output text 2>/dev/null | cut -c1-140 | sed 's/^/    /'

  echo; echo "--- 9.3 CPU, minne och disk (CloudWatch-agenten ser inuti servrarna, EC2 bara utifrån) ---"
  if [[ "$SSH_OK" == yes ]]; then
    for ip in "$WEB_PRIV" ${WEB2_PRIV:+"$WEB2_PRIV"}; do
      st=$(remote_on "$ip" "systemctl is-active amazon-cloudwatch-agent" | tail -n1)
      [[ "$st" == active ]] && got=ALLOW || got=DENY
      record ALLOW "$got" "CloudWatch-agenten kör på webbservern $ip ($st)"
    done
  fi
  v=$(metric_last Average AWS/EC2 CPUUtilization Name=AutoScalingGroupName,Value="$ASG")
  [[ "$v" =~ ^[0-9.]+$ ]] && got=ALLOW || got=DENY
  record ALLOW "$got" "CPU (EC2, gruppens snitt): ${v%.*} % - larm över $WEB_CPU_ALARM %"
  v=$(metric_last Maximum CWAgent mem_used_percent Name=AutoScalingGroupName,Value="$ASG")
  [[ "$v" =~ ^[0-9.]+$ ]] && got=ALLOW || got=DENY
  record ALLOW "$got" "minne (agenten, värsta servern): ${v%.*} % - larm över $WEB_MEMORY_ALARM %"
  v=$(metric_last Maximum CWAgent disk_used_percent Name=AutoScalingGroupName,Value="$ASG" Name=path,Value=/ Name=fstype,Value=xfs)
  [[ "$v" =~ ^[0-9.]+$ ]] && got=ALLOW || got=DENY
  record ALLOW "$got" "disk / (agenten, värsta servern): ${v%.*} % - larm över $WEB_DISK_ALARM %"
  v=$(metric_last Minimum AWS/RDS FreeStorageSpace Name=DBInstanceIdentifier,Value="$DB_INSTANCE_ID")
  [[ "$v" =~ ^[0-9.E+]+$ ]] && got=ALLOW || got=DENY
  record ALLOW "$got" "databasens lediga disk (RDS): $(awk -v b="${v:-0}" 'BEGIN { printf "%.1f", b / 1073741824 }') GiB - larm under 2 GiB"
  n=$(aws cloudwatch list-metrics --region "$REGION" --namespace CWAgent \
        --dimensions Name=AutoScalingGroupName,Value="$ASG" --query 'length(Metrics)' --output text 2>/dev/null)
  echo "    egna mätvärden från agenten: ${n:-0} st (per GRUPP, inte per server: samma larm oavsett vilka servrar som kör)"

  echo; echo "--- 9.4 Central loggning: alla servrars loggar på ett ställe, sökbara ---"
  printf '    %-40s %-8s %-9s %s\n' LOGGRUPP LAGRING STRÖMMAR "SENASTE HÄNDELSE"
  no_ret=0
  for g in "${WEB_LOG_GROUPS[@]/#/$WEB_LOG_PREFIX/}" "$SITE_CHECK_LOG_GROUP" "$LOG_GROUP" "$DB_LOG_GROUP" "$FLOW_LOG_GROUP"; do
    ret=$(aws logs describe-log-groups --region "$REGION" --log-group-name-prefix "$g" \
            --query "logGroups[?logGroupName=='$g'] | [0].retentionInDays" --output text 2>/dev/null)
    read -r ns last <<<"$(aws logs describe-log-streams --region "$REGION" --log-group-name "$g" \
      --order-by LastEventTime --descending --query '[length(logStreams), logStreams[0].lastEventTimestamp]' --output text 2>/dev/null)"
    [[ "${ret:-None}" =~ ^[0-9]+$ ]] || no_ret=$((no_ret + 1))
    [[ "${last:-None}" =~ ^[0-9]+$ ]] && last=$(date -d "@$(( last / 1000 ))" '+%Y-%m-%d %H:%M') || last="-"
    printf '    %-40s %-8s %-9s %s\n' "$g" "${ret:-?} d" "${ns:-0}" "$last"
  done
  [[ $no_ret -eq 0 ]] && got=ALLOW || got=DENY
  record ALLOW "$got" "alla logggrupper har en lagringstid (inget sparas - och kostar - för evigt)"
  n=$(aws logs describe-log-streams --region "$REGION" --log-group-name "$WEB_LOG_PREFIX/access" \
        --query 'length(logStreams[?starts_with(logStreamName, `i-`)])' --output text 2>/dev/null)
  echo "    $WEB_LOG_PREFIX/access: $n strömmar = en per webbserver som någonsin kört (även ersatta)"

  # A unique request through the ALB - and find it again in the central log.
  LOG_MARK="v48-logtest-${STAMP}"
  for i in 1 2 3; do curl -s -o /dev/null -m 10 "$SITE/$LOG_MARK"; done
  got=DENY; hit=""
  for i in $(seq 1 24); do
    hit=$(aws logs filter-log-events --region "$REGION" --log-group-name "$WEB_LOG_PREFIX/access" \
            --start-time "$START_MS" --filter-pattern "\"$LOG_MARK\"" \
            --query 'events[0].[logStreamName, message]' --output text 2>/dev/null)
    [[ "$hit" == i-* ]] && { got=ALLOW; break; }
    sleep 5
  done
  echo "    ${hit:-ingen träff}" | cut -c1-200
  record ALLOW "$got" "anrop genom ALB hittas i den centrala loggen inom 2 min (sökning: /$LOG_MARK)"
  grep -q "\"path\":\"/$LOG_MARK\"" <<<"$hit" && grep -q '"status":404' <<<"$hit" && got=ALLOW || got=DENY
  record ALLOW "$got" "accessloggen är JSON med fält (ip, path, status, ms) - Logs Insights hittar dem själv"
  n=$(aws logs filter-log-events --region "$REGION" --log-group-name "$WEB_LOG_PREFIX/access" \
        --start-time $(( ($(date +%s) - 600) * 1000 )) --filter-pattern '"healthz.php"' \
        --query 'length(events)' --output text 2>/dev/null)
  [[ "${n:-0}" == 0 ]] && got=DENY || got=ALLOW
  record DENY "$got" "lastbalanserarens hälsokontroller fyller loggen (${n:-0} rader, 10 min)"

  QID=$(aws logs start-query --region "$REGION" --log-group-name "$WEB_LOG_PREFIX/access" \
          --start-time $(( $(date +%s) - 3600 )) --end-time "$(date +%s)" \
          --query-string 'stats count(*) as anrop, round(avg(ms)) as snitt_ms by status | sort anrop desc' \
          --query queryId --output text 2>/dev/null)
  st=""
  for i in $(seq 1 30); do
    st=$(aws logs get-query-results --region "$REGION" --query-id "${QID:-none}" --query status --output text 2>/dev/null)
    [[ "$st" == Complete || "$st" == Failed || "$st" == Cancelled || -z "$st" ]] && break
    sleep 2
  done
  echo "    Logs Insights, senaste timmen, ALLA servrar - status  anrop  snitt-ms:"
  aws logs get-query-results --region "$REGION" --query-id "${QID:-none}" --query 'results[*][*].value' \
    --output text 2>/dev/null | head -n 8 | sed 's/^/      /'
  record Complete "${st:-?}" "Logs Insights-fråga över accessloggen"
  n=$(aws logs describe-query-definitions --region "$REGION" --query-definition-name-prefix "${PROJECT}/" \
        --query 'length(queryDefinitions)' --output text 2>/dev/null)
  record 6 "${n:-0}" "sparade Logs Insights-frågor (${PROJECT}/1-6) för uppföljning"

  # The deployed metric filters, tested against sample lines (changes nothing).
  mf_test() {   # log-group sample-that-must-match sample-that-must-not
    local p
    p=$(aws logs describe-metric-filters --region "$REGION" --log-group-name "$1" \
          --query 'metricFilters[0].filterPattern' --output text 2>/dev/null)
    aws logs test-metric-filter --region "$REGION" --filter-pattern "$p" --log-event-messages "$2" "$3" \
      --query 'length(matches)' --output text 2>/dev/null
  }
  n=$(mf_test "$WEB_LOG_PREFIX/php" "[27-Nov-2026 10:00:00 UTC] PHP Fatal error:  Uncaught Error: Call to undefined function x()" \
                                    "[27-Nov-2026 10:00:00 UTC] PHP Warning:  Undefined variable \$y")
  record 1 "${n:-0}" "metrikfilter PHP Fatal: träffar fatal, inte varning (testrader)"
  n=$(mf_test "$WEB_LOG_PREFIX/jobs" "novatrix-backup FAILED (line 14)" "Uploaded backup/db/20261127T000000Z-wordpress.sql.gz")
  record 1 "${n:-0}" "metrikfilter backup FAILED: träffar fel, inte lyckad backup (testrader)"
  n=$(aws logs filter-log-events --region "$REGION" --log-group-name "$WEB_LOG_PREFIX/boot" \
        --filter-pattern '"Novatrix WordPress ready"' --query 'events[].logStreamName' --output text 2>/dev/null | wc -w)
  [[ "${n:-0}" -ge 1 ]] && got=ALLOW || got=DENY
  record ALLOW "$got" "uppstartsloggen (user data) finns centralt: \"Novatrix WordPress ready\" från $n servrar"
  ex=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$DB_INSTANCE_ID" \
         --query 'DBInstances[0].EnabledCloudwatchLogsExports' --output text 2>/dev/null)
  [[ "$ex" == *error* ]] && got=ALLOW || got=DENY
  record ALLOW "$got" "databasens fellogg exporteras till CloudWatch Logs ($DB_LOG_GROUP)"

  echo; echo "--- 9.5 Serverless: site check (Lambda, startas var 5:e minut av EventBridge) ---"
  read -r rstate rexpr <<<"$(aws events describe-rule --region "$REGION" --name "$SITE_CHECK_FUNCTION" \
    --query '[State, ScheduleExpression]' --output text 2>/dev/null)"
  record ENABLED "${rstate:-saknas}" "schemat ${rexpr:-?} är aktivt"
  ferr=$(aws lambda invoke --region "$REGION" --function-name "$SITE_CHECK_FUNCTION" "$WORK_DIR/site-check.json" \
           --query FunctionError --output text 2>&1)
  payload=$(tr -d '\r' < "$WORK_DIR/site-check.json" 2>/dev/null)
  echo "    svar: $payload  (fel: ${ferr:-None})"
  aws logs tail "$SITE_CHECK_LOG_GROUP" --region "$REGION" --since 3m 2>/dev/null | grep '"url"' | tail -n 5 \
    | sed -E 's/^[^ ]+ [^ ]+ //; s/^/    /'
  grep -q '"available": 1' <<<"$payload" && got=ALLOW || got=DENY
  record ALLOW "$got" "site check: alla kontroller godkända (startsida, inloggning, hälsokontroll, /static/$([[ "$HTTPS_ON" == yes ]] && echo ", HTTPS"))"
  v=""
  for i in $(seq 1 12); do
    v=$(metric_last Minimum Novatrix/SiteCheck Available Name=Site,Value="$PROJECT")
    [[ "$v" =~ ^[0-9.]+$ ]] && break
    sleep 5
  done
  [[ "$v" == 1* ]] && got=ALLOW || got=DENY
  record ALLOW "$got" "mätvärdet Available når CloudWatch (${v:-saknas}) - larmet site-down vaktar det"
  aws cloudwatch get-dashboard --region "$REGION" --dashboard-name "$DASHBOARD_NAME" >/dev/null 2>&1 && got=ALLOW || got=DENY
  record ALLOW "$got" "dashboard $DASHBOARD_NAME finns (larm, site check, ALB, servrar, RDS, EFS, loggar)"
  echo "    https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards/dashboard/${DASHBOARD_NAME}"
fi

# Remove the test data again (backups from the run are kept - the lifecycle rule removes them)
for k in "drafts/$TEST_OK" "drafts/$TEST_BAD" "web/$TEST_OK"; do
  aws s3 rm "s3://$SITE_BUCKET/$k" --region "$REGION" --only-show-errors 2>/dev/null
done
rm -f -- "${WORK_DIR:?}/${TEST_OK:?}" "${WORK_DIR:?}/${TEST_BAD:?}"
if [[ "$SSH_OK" == yes ]]; then
  remote "sudo rm -f /var/www/static/$TEST_OK $WP_ROOT/wp-content/uploads/v47-*-${STAMP}.txt $WP_ROOT/wp-content/uploads/v47-${STAMP}.php" >/dev/null || true
  [[ -n "$WEB2_PRIV" ]] && { remote_on "$WEB2_PRIV" "sudo rm -f /var/www/static/$TEST_OK" >/dev/null || true; }
  [[ -n "$POST_ID" ]] && { remote "$WPCLI post delete $POST_ID --force" >/dev/null || true; }
fi

# =============================================================================
# Del 8 (opt-in): failure and load, measured from the outside
# =============================================================================
# A poller asks the site for the start page through the ALB about every 1.5 s
# and writes "<epoch> <http-code>" per request: the proof of what a visitor saw.
# Slow on purpose: the poller is itself traffic, and with a scaling target of
# 60 requests per server and minute a faster poller would make the group scale
# out in the middle of the test. Timeout 10 s: a slow page is not an outage.
POLL="$WORK_DIR/poll.txt"
POLL_STOP="$WORK_DIR/poll.stop"
POLL_PID=""
POLL_MAX_GAP=30   # "the site stayed up" = never 30 s without a successful page.
                  # A hard-killed server keeps getting requests until the health
                  # check notices (3 x 15 s = 45 s) - the other server answers
                  # meanwhile, so the longest gap stays far below that.
poll_start() {
  : > "$POLL"; rm -f -- "${POLL_STOP:?}"
  ( while [[ ! -f "$POLL_STOP" ]]; do
      printf '%s %s\n' "$(date +%s)" "$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$SITE/")" >> "$POLL"
      sleep 1.5
    done ) &
  POLL_PID=$!
}
poll_stop() { touch "$POLL_STOP"; [[ -n "$POLL_PID" ]] && wait "$POLL_PID" 2>/dev/null; POLL_PID=""; }
# -> "requests ok errors longest-gap-without-a-200 (seconds)"
poll_stats() {
  awk 'NR == 1 { last = $1 } { n++ } $2 == 200 { ok++; if ($1 - last > gap) gap = $1 - last; last = $1 }
       END { printf "%d %d %d %d\n", n, ok, n - ok, gap }' "$POLL"
}
poll_report() {   # description-prefix
  local n ok err gap
  read -r n ok err gap <<<"$(poll_stats)"
  echo "    Besökarens bild: $n anrop, $ok OK (200), $err fel, längsta tid utan lyckat svar ${gap}s"
  echo "    Felkoder: $(awk '$2 != 200 { c[$2]++ } END { for (k in c) printf "%s x%d  ", k, c[k] }' "$POLL")(000 = inget svar inom 10 s)"
  [[ "$n" -gt 0 && "$gap" -lt "$POLL_MAX_GAP" ]] && got=ALLOW || got=DENY
  record ALLOW "$got" "$1: sajten svarade hela tiden (längsta lucka ${gap}s < ${POLL_MAX_GAP}s, $(( ok * 100 / (n > 0 ? n : 1) ))% OK)"
}
target_state() {  # instance -> healthy | unhealthy | initial | draining | gone ...
  local st
  st=$(aws elbv2 describe-target-health --region "$REGION" --target-group-arn "$TG_ARN" --targets Id="$1" \
         --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text 2>/dev/null)
  [[ -z "$st" || "$st" == None ]] && st=gone
  echo "$st"
}
# InService servers with launch time: "id az private-ip launch-time"
web_instances_lt() {
  local ids
  ids=$(asg_field 'Instances[?LifecycleState==`InService`].InstanceId')
  [[ -z "$ids" || "$ids" == None ]] && return 0
  aws ec2 describe-instances --region "$REGION" --instance-ids $ids \
    --query 'Reservations[].Instances[].[InstanceId, Placement.AvailabilityZone, PrivateIpAddress, LaunchTime]' \
    --output text 2>/dev/null
}
# A victim for a test: healthy in the ALB and - with "old" - past the group's
# health check grace period. A server that is still booting is useless as a
# victim: its user data starts Apache again, and during the grace period the
# group ignores the load balancer's verdict anyway.
pick_victim() {   # any|old preferred-az -> "id az private-ip" (empty if none)
  local grace now best="" id az priv lt
  grace=$(asg_field HealthCheckGracePeriod); now=$(date +%s)
  while read -r id az priv lt; do
    [[ -z "${id:-}" ]] && continue
    [[ "$(target_state "$id")" == healthy ]] || continue
    if [[ "$1" == old ]]; then
      (( now - $(date -d "$lt" +%s) > ${grace:-600} + 30 )) || continue
    fi
    if [[ -z "$best" || "$az" == "$2" ]]; then best="$id $az $priv"; fi
    [[ "$az" == "$2" ]] && break
  done <<<"$(web_instances_lt)"
  echo "$best"
}
# Before every test: the group must be at rest (desired = InService = healthy)
# and - when a victim is wanted - have one. Earlier tests leave the group in
# motion (replacements booting, scale-in), which must not count against the next.
wait_stable() {   # none|any|old preferred-az -> sets VICTIM_ID VICTIM_AZ VICTIM_IP; status 0/1
  local t0=$SECONDS last=-60 d i h v
  VICTIM_ID=""; VICTIM_AZ=""; VICTIM_IP=""
  while (( SECONDS - t0 < 900 )); do
    d=$(asg_field DesiredCapacity); i=$(asg_field "length(Instances[?LifecycleState=='InService'])"); h=$(healthy_count)
    if [[ "${i:-0}" == "${d:-x}" && "${h:-0}" -ge "${d:-99}" ]]; then
      [[ "$1" == none ]] && { echo "    gruppen i vila: $d servrar, alla friska"; return 0; }
      v=$(pick_victim "$1" "$2")
      if [[ -n "$v" ]]; then
        read -r VICTIM_ID VICTIM_AZ VICTIM_IP <<<"$v"
        echo "    gruppen i vila: $d servrar, alla friska"; return 0
      fi
    fi
    if (( SECONDS - last >= 60 )); then
      last=$SECONDS
      echo "    väntar på att gruppen ska bli stabil ($(( SECONDS - t0 ))s): önskat $d, i tjänst $i, friska $h$( [[ "$1" == old ]] && echo ", och en server äldre än grace-perioden")"
    fi
    sleep 15
  done
  echo "    gruppen blev inte stabil inom 15 min - testet hoppas över"; return 1
}
# Wait until <id> has left the group AND <desired> servers are InService + healthy.
wait_recovered() {   # old-instance-id timeout-seconds -> echo seconds taken, status 0/1
  local old=$1 t0=$SECONDS want insvc hc last=-60
  want=$(asg_field DesiredCapacity)
  while (( SECONDS - t0 < $2 )); do
    insvc=$(asg_field "length(Instances[?LifecycleState=='InService' && InstanceId!='$old'])")
    hc=$(healthy_count)
    if [[ "${insvc:-0}" -ge "$want" && "${hc:-0}" -ge "$want" ]] \
       && [[ "$(asg_field "length(Instances[?InstanceId=='$old'])")" == 0 ]]; then
      echo $(( SECONDS - t0 )); return 0
    fi
    if (( SECONDS - last >= 60 )); then
      last=$SECONDS
      echo "    ... $(( SECONDS - t0 ))s: $insvc andra servrar i tjänst, $hc friska i ALB (mål $want)" >&2
    fi
    sleep 15
  done
  echo $(( SECONDS - t0 )); return 1
}
show_activities() {
  aws autoscaling describe-scaling-activities --region "$REGION" --auto-scaling-group-name "$ASG" --no-paginate --max-records "$1" \
    --query 'Activities[].[StartTime, Description]' --output text 2>/dev/null | cut -c1-140 | sed 's/^/    /'
}
# Never leave the poller or load workers running if the script is interrupted.
trap 'touch "$POLL_STOP" 2>/dev/null; kill $(jobs -p) 2>/dev/null' EXIT

if [[ "$DO_FAILOVER$DO_SELFHEAL$DO_LOAD" == *yes* && ( -z "$ASG" || -z "$ALB_DNS" ) ]]; then
  echo; echo "Del 8 hoppas över: stacken $STACK_COMPUTE saknas."
  DO_FAILOVER=no; DO_SELFHEAL=no; DO_LOAD=no; DO_ALARMTEST=no
fi

if [[ "$DO_FAILOVER" == yes ]]; then
  echo; echo "=== Del 8.1: en webbserver försvinner (EC2 terminerar den hårt, under trafik) ==="
  if wait_stable any "${REGION}a"; then
    victim=$VICTIM_ID
    echo "Offer: $victim i $VICTIM_AZ - termineras direkt i EC2 (inte via gruppen: ingen förvarning, ingen dränering)"
    poll_start; sleep 10
    aws ec2 terminate-instances --region "$REGION" --instance-ids "$victim" >/dev/null
    t0=$SECONDS
    while [[ "$(target_state "$victim")" == healthy ]] && (( SECONDS - t0 < 180 )); do sleep 3; done
    echo "    lastbalanseraren tog servern ur rotation efter $(( SECONDS - t0 ))s ($(target_state "$victim"))"
    if secs=$(wait_recovered "$victim" 900); then got=ALLOW; else got=DENY; fi
    record ALLOW "$got" "gruppen ersatte servern automatiskt (tillbaka till fullt antal friska efter ${secs}s)"
    sleep 20; poll_stop
    poll_report "server terminerad"
    echo "    Nu i tjänst: $(web_instances | awk '{printf "%s (%s)  ", $1, $2}')"
    show_activities 2
  fi
fi

if [[ "$DO_SELFHEAL" == yes ]]; then
  echo; echo "=== Del 8.2: en webbserver går sönder (Apache stoppas) - hälsokontroll + självläkning ==="
  if [[ -z "$BASTION_IP" || ! -f "$KEY_FILE" ]]; then
    echo "Hoppar över (behöver SSH via bastionen)."
  elif wait_stable old "${REGION}b"; then
    victim=$VICTIM_ID; victim_ip=$VICTIM_IP
    echo "Offer: $victim ($victim_ip, $VICTIM_AZ) - instansen kör vidare, men webbservern svarar inte"
    poll_start; sleep 10
    remote_on "$victim_ip" "sudo systemctl stop httpd" >/dev/null
    t0=$SECONDS
    while [[ "$(target_state "$victim")" == healthy ]] && (( SECONDS - t0 < 180 )); do sleep 3; done
    st=$(target_state "$victim"); det=$(( SECONDS - t0 ))
    [[ "$st" != healthy ]] && got=ALLOW || got=DENY
    record ALLOW "$got" "hälsokontrollen upptäckte felet och tog servern ur rotation efter ${det}s ($st)"
    if secs=$(wait_recovered "$victim" 900); then got=ALLOW; else got=DENY; fi
    record ALLOW "$got" "gruppen terminerade den sjuka servern och startade en ny (klart efter ${secs}s)"
    sleep 20; poll_stop
    poll_report "trasig server"
    echo "    (eventuella fel ovan är anrop som hann gå till servern innan den underkändes: $hbad kontroller à ${hint}s)"
    show_activities 2
  fi
fi

# Safety: load only OUR load balancer. The address must be the one EC2 reports
# for the ALB named $ALB_NAME in THIS account and region, and an AWS ELB name.
if [[ "$DO_LOAD" == yes ]]; then
  own_dns=$(aws elbv2 describe-load-balancers --region "$REGION" --names "$ALB_NAME" \
              --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null)
  if [[ -z "$ALB_DNS" || "$own_dns" != "$ALB_DNS" || "$ALB_DNS" != *".${REGION}.elb.amazonaws.com" ]]; then
    echo; echo "Del 8.3 hoppas över: '${ALB_DNS:-?}' är inte kontots egen lastbalanserare $ALB_NAME (${own_dns:-saknas})."
    DO_LOAD=no
  fi
fi

if [[ "$DO_LOAD" == yes ]]; then
  LOAD_MINUTES=${LOAD_MINUTES:-8}; LOAD_WORKERS=${LOAD_WORKERS:-12}
  (( LOAD_WORKERS <= 30 && LOAD_MINUTES <= 15 )) || { echo "LOAD_WORKERS max 30, LOAD_MINUTES max 15"; exit 2; }
  echo "Mål: $SITE/  = $ALB_NAME i konto $ACCOUNT_ID ($REGION) - bara GET mot startsidan, ingen annan adress."
  echo; echo "=== Del 8.3: lasttest - $LOAD_WORKERS parallella besökare i $LOAD_MINUTES minuter mot $SITE/ ==="
  wait_stable none ""
  start_desired=$(asg_field DesiredCapacity); max_desired=$start_desired; low=$start_desired; scaled=no
  echo "Före: önskat $start_desired servrar. Målvärden: $REQUESTS_PER_TARGET anrop/server/minut och ${CPU_TARGET}% CPU."
  end=$(( $(date +%s) + LOAD_MINUTES * 60 ))
  WORKERS=()
  for w in $(seq 1 "$LOAD_WORKERS"); do
    ( while (( $(date +%s) < end )); do curl -s -m 10 -o /dev/null "$SITE/"; done ) &
    WORKERS+=($!)
  done
  t0=$SECONDS
  while (( SECONDS - t0 < LOAD_MINUTES * 60 + 360 )); do
    d=$(asg_field DesiredCapacity); i=$(asg_field "length(Instances[?LifecycleState=='InService'])")
    [[ "${d:-0}" -gt "$max_desired" ]] && max_desired=$d
    # Judged against the LOWEST capacity seen: a scale-in left over from an
    # earlier test may still happen at the start - growth after it is what counts.
    [[ "${d:-0}" -lt "$low" ]] && low=$d
    [[ "${d:-0}" -gt "$low" ]] && scaled=yes
    (( $(date +%s) < end )) && phase="last " || phase="efter"
    echo "    $(( (SECONDS - t0) / 60 )) min ($phase): önskat $d, i tjänst $i, friska i ALB $(healthy_count)"
    [[ "$scaled" == yes ]] && (( $(date +%s) >= end && ${i:-0} >= max_desired )) && break
    sleep 30
  done
  wait "${WORKERS[@]}" 2>/dev/null
  [[ "$scaled" == yes ]] && got=ALLOW || got=DENY
  record ALLOW "$got" "gruppen skalade ut under last ($low -> $max_desired servrar, max $(asg_field MaxSize))"
  show_activities 3
  echo "INFO target tracking skalar in först efter ~15 min låg last (avsiktligt försiktigt) - kör"
  echo "     ./V48_verify.sh om en halvtimme och se att gruppen är tillbaka på $(asg_field MinSize) servrar (7.2)."
fi

# The whole alarm chain, with real mails. Two alarms:
#   critical-site-down: forced to ALARM by hand (set-alarm-state). The site is
#       up, so CloudWatch sets it back to OK at its next evaluation by itself
#       -> TWO mails: ALARM and OK.
#   warning-php-fatal: a REAL PHP fatal error on a web server, written by PHP
#       into its log -> CloudWatch agent -> log group -> metric filter ->
#       alarm -> SNS -> ONE mail (warnings don't mail on OK).
if [[ "$DO_ALARMTEST" == yes && -n "${TOPIC_ARN:-}" ]]; then
  echo; echo "=== Del 8.4: larmkedjan - logg -> metrikfilter -> larm -> SNS -> mejl ==="
  mails_sent() {   # alarm since -> number of successful SNS actions
    aws cloudwatch describe-alarm-history --region "$REGION" --alarm-name "$1" --history-item-type Action \
      --start-date "$2" --query 'AlarmHistoryItems[].HistorySummary' --output text 2>/dev/null \
      | tr '\t' '\n' | grep -c "Successfully executed action"
  }
  T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  SD_ALARM="${PROJECT}-critical-site-down"
  aws lambda invoke --region "$REGION" --function-name "$SITE_CHECK_FUNCTION" "$WORK_DIR/site-check.json" >/dev/null 2>&1
  aws cloudwatch set-alarm-state --region "$REGION" --alarm-name "$SD_ALARM" --state-value ALARM \
    --state-reason "V48-verifiering $STAMP: test av larmmejlet (sajten är uppe)"
  echo "    $SD_ALARM satt till ALARM för hand - CloudWatch ska själv sätta OK igen (sajten är uppe)..."
  st=""
  for i in $(seq 1 40); do st=$(alarm_state "$SD_ALARM"); [[ "$st" == OK ]] && break; sleep 15; done
  record OK "${st:-?}" "critical-larmet gick tillbaka till OK av sig självt (efter ca $(( i * 15 ))s)"
  sleep 10
  n=$(mails_sent "$SD_ALARM" "$T0")
  record 2 "${n:-0}" "SNS skickade mejl för critical-larmet: ALARM + OK"

  PF_ALARM="${PROJECT}-warning-php-fatal"
  if [[ "$SSH_OK" == yes ]]; then
    fn="v48_larmtest_${STAMP}"
    remote "sudo -u apache php -d log_errors=1 -d display_errors=0 -d error_log=/var/log/php-fpm/www-error.log -r '${fn}();'" >/dev/null
    echo "    äkta PHP Fatal skrivet av PHP på $WEB_PRIV ($WEB_ID): Call to undefined function ${fn}()"
    got=DENY
    for i in $(seq 1 24); do
      line=$(aws logs filter-log-events --region "$REGION" --log-group-name "$WEB_LOG_PREFIX/php" \
               --start-time "$START_MS" --filter-pattern "\"$fn\"" --query 'events[0].message' --output text 2>/dev/null)
      [[ "$line" == *"PHP Fatal"* ]] && { got=ALLOW; break; }
      sleep 5
    done
    echo "    i loggen: ${line:-ingen träff}" | cut -c1-200
    record ALLOW "$got" "felet syns i den centrala loggen $WEB_LOG_PREFIX/php"
    echo "    väntar på larmet $PF_ALARM (metrikfilter -> 5-minutersperiod, upp till 10 min)..."
    st=""
    for i in $(seq 1 40); do st=$(alarm_state "$PF_ALARM"); [[ "$st" == ALARM ]] && break; sleep 15; done
    record ALARM "${st:-?}" "metrikfiltret gjorde loggraden till ett larm (efter ca $(( i * 15 ))s)"
    sleep 10
    n=$(mails_sent "$PF_ALARM" "$T0")
    [[ "${n:-0}" -ge 1 ]] && got=ALLOW || got=DENY
    record ALLOW "$got" "SNS skickade mejl för warning-larmet ($n st - inget OK-mejl för varningar)"
  fi
  echo "    Kontrollera inkorgen $sub_to: \"ALARM: $SD_ALARM\", \"OK: $SD_ALARM\" och \"ALARM: $PF_ALARM\"."
fi

echo
echo "=== Resultat: $PASS OK, $FAIL FEL ==="
echo "Sparat i $OUT"
[[ $FAIL -eq 0 ]]
