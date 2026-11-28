# Monitorering och cloud native

Repository: https://github.com/03timnor/AWS_MOV25

*Tim Noreliusson Lingestedt, 2026-11-28*

Veckans uppgift går ut på att skapa central monitorering av *CPU*, minne disk och inloggning med *CloudWatch*, att utforska cloud native-strategier och hur delar av lösningen kan köras som *containers* eller *serverless*. Man skall kunna konfigurera monitoreringen och förklara varför den är viktig.

För att uppnå Väl Godkänt nivå skall man provisionera infrastrukturen / miljön som kod (*IaC*). Samt göra ett välgrundat och motiverat val av cloud native strategi och beskriva hur en del av lösningen skulle flyttas till *containers* eller *serverless* och vad det ger i skalbarhet, kostnad och drift.

## 1. *__Skapa infrastrukturen / miljön med CloudFormation-mallar (Kod)__*

### *__V48_01-network.yaml__*

```yaml
AWSTemplateFormatVersion: "2010-09-09"
Description: >
  Novatrix V48 - layer 1 of 6: network. VPC with three tiers (mgmt, web, data),
  route tables, S3 gateway endpoint, security groups (incl. the load balancer's)
  AND network ACLs (defense in depth) and VPC flow logs. Exports its ids to
  layers 2-6.

# =============================================================================
# Address plan (defaults, every CIDR is a parameter)
#
#   mgmt-a  10.0.0.0/24   public   bastion host (the only SSH entry point)
#   web-a   10.0.2.0/24   public   web servers (Auto Scaling, AZ a) + ALB node
#   web-b   10.0.3.0/24   public   web servers (Auto Scaling, AZ b) + ALB node
#   data-a  10.0.10.0/24  private  RDS MariaDB + EFS mount target, NO internet route
#   data-b  10.0.11.0/24  private  EFS mount target (the DB subnet group needs two AZs)
#
# Web tier = web-a + web-b (/23), data tier = data-a + data-b (/23), so one
# NACL rule covers both subnets of a tier.
# =============================================================================

Metadata:
  AWS::CloudFormation::Interface:
    ParameterGroups:
      - Label: { default: General }
        Parameters: [ProjectName, AdminCidr, SiteBucket, DbPort]
      - Label: { default: Address plan }
        Parameters: [VpcCidr, MgmtACidr, WebACidr, WebBCidr, WebTierCidr, DataACidr, DataBCidr, DataTierCidr]

Parameters:
  ProjectName:
    Type: String
    Default: novatrix
    AllowedPattern: '^[a-z][a-z0-9-]{1,20}$'
    Description: Prefix for resource names, tags and the exports the other layers import
  AdminCidr:
    Type: String
    Description: The only address allowed to SSH to the bastion (your public IP /32)
    AllowedPattern: '^(\d{1,3}\.){3}\d{1,3}/32$'
    ConstraintDescription: Must be a single host, e.g. 203.0.113.10/32
  SiteBucket:
    Type: String
    Description: The project bucket - the only bucket the S3 endpoint lets through
  DbPort:
    Type: Number
    Default: 3306
    Description: Database port (MariaDB 3306) - exported, the data layer uses the same value
  VpcCidr:      { Type: String, Default: 10.0.0.0/16,  AllowedPattern: '^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$' }
  MgmtACidr:    { Type: String, Default: 10.0.0.0/24,  AllowedPattern: '^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$' }
  WebACidr:     { Type: String, Default: 10.0.2.0/24,  AllowedPattern: '^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$' }
  WebBCidr:     { Type: String, Default: 10.0.3.0/24,  AllowedPattern: '^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$' }
  WebTierCidr:  { Type: String, Default: 10.0.2.0/23,  AllowedPattern: '^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$', Description: Covers web-a + web-b }
  DataACidr:    { Type: String, Default: 10.0.10.0/24, AllowedPattern: '^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$' }
  DataBCidr:    { Type: String, Default: 10.0.11.0/24, AllowedPattern: '^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$' }
  DataTierCidr: { Type: String, Default: 10.0.10.0/23, AllowedPattern: '^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$', Description: Covers data-a + data-b }

Mappings:
  # Ephemeral (client) ports. Our servers run Linux, which picks source ports
  # in 32768-60999, so return traffic TO our servers only needs that range.
  # Visitors and admins can be anything (Windows, NAT), so traffic FROM our
  # servers back to them uses the wide range 1024-65535.
  Ports:
    Linux: { From: 32768, To: 60999 }

Resources:
  # ===========================================================================
  # VPC + internet gateway
  # ===========================================================================
  Vpc:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: !Ref VpcCidr
      EnableDnsSupport: true
      EnableDnsHostnames: true
      Tags:
        - { Key: Name, Value: !Sub "${ProjectName}-vpc" }
        - { Key: Project, Value: !Ref ProjectName }

  InternetGateway:
    Type: AWS::EC2::InternetGateway
    Properties:
      Tags:
        - { Key: Name, Value: !Sub "${ProjectName}-igw" }
        - { Key: Project, Value: !Ref ProjectName }

  InternetGatewayAttachment:
    Type: AWS::EC2::VPCGatewayAttachment
    Properties:
      VpcId: !Ref Vpc
      InternetGatewayId: !Ref InternetGateway

  # ===========================================================================
  # Subnets. MapPublicIpOnLaunch is OFF even in the public subnets: only an
  # instance that explicitly asks for a public IP gets one.
  # ===========================================================================
  MgmtSubnetA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      CidrBlock: !Ref MgmtACidr
      AvailabilityZone: !Select [0, !GetAZs ""]
      MapPublicIpOnLaunch: false
      Tags:
        - { Key: Name, Value: !Sub "${ProjectName}-mgmt-a (public)" }
        - { Key: Tier, Value: mgmt }
        - { Key: Project, Value: !Ref ProjectName }

  WebSubnetA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      CidrBlock: !Ref WebACidr
      AvailabilityZone: !Select [0, !GetAZs ""]
      MapPublicIpOnLaunch: false
      Tags:
        - { Key: Name, Value: !Sub "${ProjectName}-web-a (public)" }
        - { Key: Tier, Value: web }
        - { Key: Project, Value: !Ref ProjectName }

  WebSubnetB:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      CidrBlock: !Ref WebBCidr
      AvailabilityZone: !Select [1, !GetAZs ""]
      MapPublicIpOnLaunch: false
      Tags:
        - { Key: Name, Value: !Sub "${ProjectName}-web-b (public)" }
        - { Key: Tier, Value: web }
        - { Key: Project, Value: !Ref ProjectName }

  DataSubnetA:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      CidrBlock: !Ref DataACidr
      AvailabilityZone: !Select [0, !GetAZs ""]
      MapPublicIpOnLaunch: false
      Tags:
        - { Key: Name, Value: !Sub "${ProjectName}-data-a (private)" }
        - { Key: Tier, Value: data }
        - { Key: Project, Value: !Ref ProjectName }

  DataSubnetB:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      CidrBlock: !Ref DataBCidr
      AvailabilityZone: !Select [1, !GetAZs ""]
      MapPublicIpOnLaunch: false
      Tags:
        - { Key: Name, Value: !Sub "${ProjectName}-data-b (private)" }
        - { Key: Tier, Value: data }
        - { Key: Project, Value: !Ref ProjectName }

  # ===========================================================================
  # Route tables
  #   public : local + 0.0.0.0/0 -> IGW + S3 prefix list -> gateway endpoint
  #   private: local ONLY. No IGW, no NAT: the data tier cannot reach or be
  #            reached from the internet, whatever the firewalls say.
  # ===========================================================================
  PublicRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - { Key: Name, Value: !Sub "${ProjectName}-rt-public" }
        - { Key: Project, Value: !Ref ProjectName }

  PublicDefaultRoute:
    Type: AWS::EC2::Route
    DependsOn: InternetGatewayAttachment
    Properties:
      RouteTableId: !Ref PublicRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      GatewayId: !Ref InternetGateway

  PrivateRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - { Key: Name, Value: !Sub "${ProjectName}-rt-private" }
        - { Key: Project, Value: !Ref ProjectName }

  MgmtSubnetARouteAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties: { SubnetId: !Ref MgmtSubnetA, RouteTableId: !Ref PublicRouteTable }
  WebSubnetARouteAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties: { SubnetId: !Ref WebSubnetA, RouteTableId: !Ref PublicRouteTable }
  WebSubnetBRouteAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties: { SubnetId: !Ref WebSubnetB, RouteTableId: !Ref PublicRouteTable }
  DataSubnetARouteAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties: { SubnetId: !Ref DataSubnetA, RouteTableId: !Ref PrivateRouteTable }
  DataSubnetBRouteAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties: { SubnetId: !Ref DataSubnetB, RouteTableId: !Ref PrivateRouteTable }

  # ===========================================================================
  # S3 gateway endpoint (free). S3 traffic from the public subnets stays on the
  # AWS network, and the bucket policy (layer 4) demands that the instance
  # roles are only used from here (stolen credentials are useless outside).
  # The endpoint policy only lets through OUR bucket and the Amazon Linux
  # package repository - an attacker on the server can't copy data out to his
  # own bucket in this region.
  # ===========================================================================
  S3Endpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref Vpc
      ServiceName: !Sub com.amazonaws.${AWS::Region}.s3
      VpcEndpointType: Gateway
      RouteTableIds: [!Ref PublicRouteTable]
      PolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Sid: OnlyProjectBucket
            Effect: Allow
            Principal: "*"
            Action: "s3:*"
            Resource:
              - !Sub arn:aws:s3:::${SiteBucket}
              - !Sub arn:aws:s3:::${SiteBucket}/*
          - Sid: AmazonLinuxPackageRepos
            Effect: Allow
            Principal: "*"
            Action: s3:GetObject
            Resource: !Sub arn:aws:s3:::al2023-repos-${AWS::Region}-de612dc2/*

  # ===========================================================================
  # Security groups (stateful, per instance). Rules reference OTHER security
  # groups instead of IP addresses where possible: "only the bastion may SSH",
  # "only the web servers may reach the database".
  #
  # Defining SecurityGroupEgress inline replaces AWS's default "allow all out".
  # Rules that would create a reference loop are separate resources below.
  # ===========================================================================
  DbSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupName: !Sub "${ProjectName}-db-sg"
      GroupDescription: RDS database - only the web servers, on the DB port
      VpcId: !Ref Vpc
      SecurityGroupEgress:
        # A security group cannot be completely empty outbound in CloudFormation,
        # so the only rule points at loopback = the database can start nothing.
        - { IpProtocol: "-1", CidrIp: 127.0.0.1/32, Description: No outbound traffic }
      Tags:
        - { Key: Name, Value: !Sub "${ProjectName}-db-sg" }
        - { Key: Project, Value: !Ref ProjectName }

  EfsSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupName: !Sub "${ProjectName}-efs-sg"
      GroupDescription: EFS mount targets - only the web servers, NFS 2049
      VpcId: !Ref Vpc
      SecurityGroupEgress:
        - { IpProtocol: "-1", CidrIp: 127.0.0.1/32, Description: No outbound traffic }
      Tags:
        - { Key: Name, Value: !Sub "${ProjectName}-efs-sg" }
        - { Key: Project, Value: !Ref ProjectName }

  # The load balancer: the ONLY thing the internet can reach on 80/443. It
  # terminates TLS and may only talk to the web servers, on port 80.
  AlbSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupName: !Sub "${ProjectName}-alb-sg"
      GroupDescription: Application Load Balancer - HTTP/HTTPS from everyone, out only to the web servers
      VpcId: !Ref Vpc
      SecurityGroupIngress:
        - { IpProtocol: tcp, FromPort: 80,  ToPort: 80,  CidrIp: 0.0.0.0/0, Description: HTTP from the internet }
        - { IpProtocol: tcp, FromPort: 443, ToPort: 443, CidrIp: 0.0.0.0/0, Description: HTTPS from the internet }
      SecurityGroupEgress:
        - IpProtocol: tcp
          FromPort: 80
          ToPort: 80
          DestinationSecurityGroupId: !Ref WebSecurityGroup
          Description: Requests and health checks to the web servers
      Tags:
        - { Key: Name, Value: !Sub "${ProjectName}-alb-sg" }
        - { Key: Project, Value: !Ref ProjectName }

  # Web servers: NOT reachable from the internet any more - only the ALB may
  # send them HTTP (the rule is a separate resource below). They keep a public
  # IP only for their OWN outbound traffic (packages, STS, Secrets Manager):
  # a NAT gateway would cost ~35 USD/month.
  WebSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupName: !Sub "${ProjectName}-web-sg"
      GroupDescription: Web servers - HTTP only from the load balancer, SSH only from the bastion
      VpcId: !Ref Vpc
      SecurityGroupIngress:
        - { IpProtocol: icmp, FromPort: 3, ToPort: 4, CidrIp: 0.0.0.0/0, Description: Path MTU Discovery }
      SecurityGroupEgress:
        - { IpProtocol: tcp, FromPort: 443, ToPort: 443, CidrIp: 0.0.0.0/0, Description: "HTTPS out: S3, STS, Secrets Manager, CloudFormation, package repos" }
        - IpProtocol: tcp
          FromPort: !Ref DbPort
          ToPort: !Ref DbPort
          DestinationSecurityGroupId: !Ref DbSecurityGroup
          Description: To the database (RDS)
        - IpProtocol: tcp
          FromPort: 2049
          ToPort: 2049
          DestinationSecurityGroupId: !Ref EfsSecurityGroup
          Description: To shared storage (EFS, NFS)
      Tags:
        - { Key: Name, Value: !Sub "${ProjectName}-web-sg" }
        - { Key: Project, Value: !Ref ProjectName }

  BastionSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupName: !Sub "${ProjectName}-bastion-sg"
      GroupDescription: Bastion - SSH only from the admin IP, out only SSH to the web servers
      VpcId: !Ref Vpc
      SecurityGroupIngress:
        - { IpProtocol: tcp, FromPort: 22, ToPort: 22, CidrIp: !Ref AdminCidr, Description: SSH from the admin IP }
      SecurityGroupEgress:
        - IpProtocol: tcp
          FromPort: 22
          ToPort: 22
          DestinationSecurityGroupId: !Ref WebSecurityGroup
          Description: SSH onward to the web servers
      Tags:
        - { Key: Name, Value: !Sub "${ProjectName}-bastion-sg" }
        - { Key: Project, Value: !Ref ProjectName }

  WebIngressHttpFromAlb:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !Ref WebSecurityGroup
      IpProtocol: tcp
      FromPort: 80
      ToPort: 80
      SourceSecurityGroupId: !Ref AlbSecurityGroup
      Description: HTTP only from the load balancer (visitors + health checks)

  WebIngressSshFromBastion:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !Ref WebSecurityGroup
      IpProtocol: tcp
      FromPort: 22
      ToPort: 22
      SourceSecurityGroupId: !Ref BastionSecurityGroup
      Description: SSH only from the bastion

  DbIngressFromWeb:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !Ref DbSecurityGroup
      IpProtocol: tcp
      FromPort: !Ref DbPort
      ToPort: !Ref DbPort
      SourceSecurityGroupId: !Ref WebSecurityGroup
      Description: Database port only from the web servers

  EfsIngressFromWeb:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !Ref EfsSecurityGroup
      IpProtocol: tcp
      FromPort: 2049
      ToPort: 2049
      SourceSecurityGroupId: !Ref WebSecurityGroup
      Description: NFS only from the web servers

  # ===========================================================================
  # Network ACLs (stateless, per subnet) - the second, independent firewall.
  # Stateless means return traffic must be allowed explicitly (ephemeral ports).
  # Everything not listed hits the implicit rule "*  DENY".
  # ===========================================================================

  # ----- mgmt tier (bastion) -------------------------------------------------
  MgmtNacl:
    Type: AWS::EC2::NetworkAcl
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - { Key: Name, Value: !Sub "${ProjectName}-nacl-mgmt" }
        - { Key: Project, Value: !Ref ProjectName }
  MgmtNaclInSshAdmin:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref MgmtNacl
      RuleNumber: 100
      Egress: false
      Protocol: 6
      RuleAction: allow
      CidrBlock: !Ref AdminCidr
      PortRange: { From: 22, To: 22 }
  MgmtNaclInReturnFromWeb:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref MgmtNacl
      RuleNumber: 110
      Egress: false
      Protocol: 6
      RuleAction: allow
      CidrBlock: !Ref WebTierCidr
      PortRange: { From: !FindInMap [Ports, Linux, From], To: !FindInMap [Ports, Linux, To] }
  MgmtNaclOutReturnToAdmin:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref MgmtNacl
      RuleNumber: 100
      Egress: true
      Protocol: 6
      RuleAction: allow
      CidrBlock: !Ref AdminCidr
      PortRange: { From: 1024, To: 65535 }
  MgmtNaclOutSshToWeb:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref MgmtNacl
      RuleNumber: 110
      Egress: true
      Protocol: 6
      RuleAction: allow
      CidrBlock: !Ref WebTierCidr
      PortRange: { From: 22, To: 22 }
  MgmtNaclAssocA:
    Type: AWS::EC2::SubnetNetworkAclAssociation
    Properties: { SubnetId: !Ref MgmtSubnetA, NetworkAclId: !Ref MgmtNacl }

  # ----- web tier ---------------------------------------------------------------
  WebNacl:
    Type: AWS::EC2::NetworkAcl
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - { Key: Name, Value: !Sub "${ProjectName}-nacl-web" }
        - { Key: Project, Value: !Ref ProjectName }
  WebNaclInHttp:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref WebNacl
      RuleNumber: 100
      Egress: false
      Protocol: 6
      RuleAction: allow
      CidrBlock: 0.0.0.0/0
      PortRange: { From: 80, To: 80 }
  WebNaclInHttps:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref WebNacl
      RuleNumber: 110
      Egress: false
      Protocol: 6
      RuleAction: allow
      CidrBlock: 0.0.0.0/0
      PortRange: { From: 443, To: 443 }
  WebNaclInSshFromMgmt:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref WebNacl
      RuleNumber: 120
      Egress: false
      Protocol: 6
      RuleAction: allow
      CidrBlock: !Ref MgmtACidr
      PortRange: { From: 22, To: 22 }
  WebNaclInReturn:
    # Answers to the server's OWN outbound connections (S3, STS, Secrets Manager, packages,
    # wordpress.org, CloudFormation, DB, EFS). Linux range only, so e.g. 3306,
    # 8080 and 9200 from the internet are stopped here already.
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref WebNacl
      RuleNumber: 130
      Egress: false
      Protocol: 6
      RuleAction: allow
      CidrBlock: 0.0.0.0/0
      PortRange: { From: !FindInMap [Ports, Linux, From], To: !FindInMap [Ports, Linux, To] }
  WebNaclInFromWebTier:
    # The ALB has a node in web-a AND web-b and sends to servers in BOTH subnets.
    # Its answers come back to the ALB's own source ports (1024-65535, not only
    # the Linux range) - allowed only from inside the web tier.
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref WebNacl
      RuleNumber: 135
      Egress: false
      Protocol: 6
      RuleAction: allow
      CidrBlock: !Ref WebTierCidr
      PortRange: { From: 1024, To: 65535 }
  WebNaclInPmtud:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref WebNacl
      RuleNumber: 140
      Egress: false
      Protocol: 1
      RuleAction: allow
      CidrBlock: 0.0.0.0/0
      Icmp: { Type: 3, Code: 4 }
  WebNaclOutReturn:
    # Answers to visitors (any client OS) and to the bastion.
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref WebNacl
      RuleNumber: 100
      Egress: true
      Protocol: 6
      RuleAction: allow
      CidrBlock: 0.0.0.0/0
      PortRange: { From: 1024, To: 65535 }
  WebNaclOutHttps:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref WebNacl
      RuleNumber: 110
      Egress: true
      Protocol: 6
      RuleAction: allow
      CidrBlock: 0.0.0.0/0
      PortRange: { From: 443, To: 443 }
  WebNaclOutDb:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref WebNacl
      RuleNumber: 120
      Egress: true
      Protocol: 6
      RuleAction: allow
      CidrBlock: !Ref DataTierCidr
      PortRange: { From: !Ref DbPort, To: !Ref DbPort }
  WebNaclOutNfs:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref WebNacl
      RuleNumber: 130
      Egress: true
      Protocol: 6
      RuleAction: allow
      CidrBlock: !Ref DataTierCidr
      PortRange: { From: 2049, To: 2049 }
  WebNaclOutHttpToWebTier:
    # The ALB's node in web-a sends requests AND health checks to servers in
    # web-b (and the other way round): that traffic leaves the subnet on port 80.
    # Without this rule every ALB node could only reach servers in its own AZ.
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref WebNacl
      RuleNumber: 140
      Egress: true
      Protocol: 6
      RuleAction: allow
      CidrBlock: !Ref WebTierCidr
      PortRange: { From: 80, To: 80 }
  WebNaclAssocA:
    Type: AWS::EC2::SubnetNetworkAclAssociation
    Properties: { SubnetId: !Ref WebSubnetA, NetworkAclId: !Ref WebNacl }
  WebNaclAssocB:
    Type: AWS::EC2::SubnetNetworkAclAssociation
    Properties: { SubnetId: !Ref WebSubnetB, NetworkAclId: !Ref WebNacl }

  # ----- data tier (database + EFS) ----------------------------------------------
  DataNacl:
    Type: AWS::EC2::NetworkAcl
    Properties:
      VpcId: !Ref Vpc
      Tags:
        - { Key: Name, Value: !Sub "${ProjectName}-nacl-data" }
        - { Key: Project, Value: !Ref ProjectName }
  DataNaclInDbFromWeb:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref DataNacl
      RuleNumber: 100
      Egress: false
      Protocol: 6
      RuleAction: allow
      CidrBlock: !Ref WebTierCidr
      PortRange: { From: !Ref DbPort, To: !Ref DbPort }
  DataNaclInNfsFromWeb:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref DataNacl
      RuleNumber: 110
      Egress: false
      Protocol: 6
      RuleAction: allow
      CidrBlock: !Ref WebTierCidr
      PortRange: { From: 2049, To: 2049 }
  DataNaclOutReturnToWeb:
    Type: AWS::EC2::NetworkAclEntry
    Properties:
      NetworkAclId: !Ref DataNacl
      RuleNumber: 100
      Egress: true
      Protocol: 6
      RuleAction: allow
      CidrBlock: !Ref WebTierCidr
      PortRange: { From: !FindInMap [Ports, Linux, From], To: !FindInMap [Ports, Linux, To] }
  DataNaclAssocA:
    Type: AWS::EC2::SubnetNetworkAclAssociation
    Properties: { SubnetId: !Ref DataSubnetA, NetworkAclId: !Ref DataNacl }
  DataNaclAssocB:
    Type: AWS::EC2::SubnetNetworkAclAssociation
    Properties: { SubnetId: !Ref DataSubnetB, NetworkAclId: !Ref DataNacl }

  # ===========================================================================
  # VPC flow logs: every accepted AND rejected connection attempt in the VPC,
  # 1-minute aggregation, kept 7 days.
  # ===========================================================================
  FlowLogGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: !Sub "/${ProjectName}/vpc-flow-logs"
      RetentionInDays: 7
      Tags:
        - { Key: Project, Value: !Ref ProjectName }

  FlowLogRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub "${ProjectName}-flow-log-role"
      Description: Lets the VPC flow log service write to the project's flow log group only
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Effect: Allow
            Principal: { Service: vpc-flow-logs.amazonaws.com }
            Action: sts:AssumeRole
            Condition:   # confused deputy protection: only for OUR account
              StringEquals: { "aws:SourceAccount": !Ref AWS::AccountId }
              ArnLike: { "aws:SourceArn": !Sub "arn:aws:ec2:${AWS::Region}:${AWS::AccountId}:vpc-flow-log/*" }
      Policies:
        - PolicyName: !Sub "${ProjectName}-flow-log-access"
          PolicyDocument:
            Version: "2012-10-17"
            Statement:
              - Effect: Allow
                Action: [logs:CreateLogStream, logs:PutLogEvents, logs:DescribeLogStreams]
                Resource: !GetAtt FlowLogGroup.Arn
              - Effect: Allow
                Action: logs:DescribeLogGroups
                Resource: "*"
      Tags:
        - { Key: Project, Value: !Ref ProjectName }

  VpcFlowLog:
    Type: AWS::EC2::FlowLog
    Properties:
      ResourceType: VPC
      ResourceId: !Ref Vpc
      TrafficType: ALL
      LogDestinationType: cloud-watch-logs
      LogGroupName: !Ref FlowLogGroup
      DeliverLogsPermissionArn: !GetAtt FlowLogRole.Arn
      MaxAggregationInterval: 60
      Tags:
        - { Key: Name, Value: !Sub "${ProjectName}-flow-log" }
        - { Key: Project, Value: !Ref ProjectName }

# Exports (<ProjectName>-<Key>) are what layers 2-6 import. An export that is in use
# can't be changed or deleted - CloudFormation protects the dependency.
Outputs:
  VpcId:
    Value: !Ref Vpc
    Export: { Name: !Sub "${ProjectName}-VpcId" }
  DefaultSecurityGroupId:
    Value: !GetAtt Vpc.DefaultSecurityGroup
  MgmtSubnetAId:
    Value: !Ref MgmtSubnetA
    Export: { Name: !Sub "${ProjectName}-MgmtSubnetAId" }
  WebSubnetAId:
    Value: !Ref WebSubnetA
    Export: { Name: !Sub "${ProjectName}-WebSubnetAId" }
  WebSubnetBId:
    Value: !Ref WebSubnetB
    Export: { Name: !Sub "${ProjectName}-WebSubnetBId" }
  DataSubnetAId:
    Value: !Ref DataSubnetA
    Export: { Name: !Sub "${ProjectName}-DataSubnetAId" }
  DataSubnetBId:
    Value: !Ref DataSubnetB
    Export: { Name: !Sub "${ProjectName}-DataSubnetBId" }
  WebTierCidr:
    Value: !Ref WebTierCidr
    Export: { Name: !Sub "${ProjectName}-WebTierCidr" }
  DbPort:
    Value: !Ref DbPort
    Export: { Name: !Sub "${ProjectName}-DbPort" }
  PublicRouteTableId:   { Value: !Ref PublicRouteTable }
  PrivateRouteTableId:  { Value: !Ref PrivateRouteTable }
  BastionSgId:
    Value: !Ref BastionSecurityGroup
    Export: { Name: !Sub "${ProjectName}-BastionSgId" }
  WebSgId:
    Value: !Ref WebSecurityGroup
    Export: { Name: !Sub "${ProjectName}-WebSgId" }
  AlbSgId:
    Value: !Ref AlbSecurityGroup
    Export: { Name: !Sub "${ProjectName}-AlbSgId" }
  DbSgId:
    Value: !Ref DbSecurityGroup
    Export: { Name: !Sub "${ProjectName}-DbSgId" }
  EfsSgId:
    Value: !Ref EfsSecurityGroup
    Export: { Name: !Sub "${ProjectName}-EfsSgId" }
  MgmtNaclId:           { Value: !Ref MgmtNacl }
  WebNaclId:            { Value: !Ref WebNacl }
  DataNaclId:           { Value: !Ref DataNacl }
  S3EndpointId:
    Value: !Ref S3Endpoint
    Export: { Name: !Sub "${ProjectName}-S3EndpointId" }
  FlowLogGroupName:
    Value: !Ref FlowLogGroup
    Export: { Name: !Sub "${ProjectName}-FlowLogGroupName" }
```

### *__V48_02-data.yaml__*

```yaml
AWSTemplateFormatVersion: "2010-09-09"
Description: >
  Novatrix V48 - layer 2 of 6: data. RDS MariaDB (error log exported to
  CloudWatch Logs), EFS (shared WordPress files for every web server in both
  AZs) and the passwords in AWS Secrets Manager. Imports subnets and security
  groups from layer 1.

Parameters:
  ProjectName:
    Type: String
    Default: novatrix
    AllowedPattern: '^[a-z][a-z0-9-]{1,20}$'
    Description: Same prefix as the network layer (its exports are imported)
  DbInstanceClass:
    Type: String
    Default: db.t4g.micro
    AllowedValues: [db.t4g.micro, db.t3.micro]
    Description: Free tier / Free plan classes only - a typo can't create an expensive database
  DbAllocatedStorage:
    Type: Number
    Default: 20
    MinValue: 20
    MaxValue: 20
    Description: GiB of gp2 storage (20 = free tier allowance and RDS minimum)
  DbBackupRetentionDays:
    Type: Number
    Default: 1
    MinValue: 1
    MaxValue: 1
    Description: Days of automated RDS backups (Free plan allows at most 1)
  DbName:
    Type: String
    Default: wordpress
    AllowedPattern: '^[a-zA-Z][a-zA-Z0-9_]{0,63}$'
  DbMasterUsername:
    Type: String
    Default: novatrixadmin
    NoEcho: true
    AllowedPattern: '^[a-zA-Z][a-zA-Z0-9_]{0,15}$'
  DbMultiAz:
    Type: String
    Default: "false"
    AllowedValues: ["false", "true"]
    Description: true = synchronous standby in the second AZ (automatic failover, about double the DB cost)
  DbAppSecretName:
    Type: String
    Default: novatrix/db/wordpress-password
    AllowedPattern: '^[a-zA-Z0-9_./+=@-]+$'
    Description: Secrets Manager name for the WordPress database user's password
  WpAdminSecretName:
    Type: String
    Default: novatrix/wordpress/admin-password
    AllowedPattern: '^[a-zA-Z0-9_./+=@-]+$'
    Description: Secrets Manager name for the WordPress admin password
  DbLogRetentionDays:
    Type: Number
    Default: 14
    AllowedValues: [1, 3, 5, 7, 14, 30, 60, 90]
    Description: Days the database's error log is kept in CloudWatch Logs
  WebRoleName:
    Type: String
    Default: novatrix-web-ec2-role
    Description: The web server's instance role (layer 3) - the only principal EFS lets mount

Conditions:
  MultiAz: !Equals [!Ref DbMultiAz, "true"]

Resources:
  # ===========================================================================
  # Secrets (AWS Secrets Manager, encrypted with the AWS managed key
  # aws/secretsmanager). CloudFormation GENERATES the passwords itself, so no
  # password is ever typed, passed on a command line or stored in Git. Only
  # letters and digits: safe in SQL, PHP and shell strings.
  # The RDS master password is not here: RDS creates and rotates that secret
  # itself (ManageMasterUserPassword below).
  # When the stack is deleted CloudFormation deletes them without the usual
  # 7-30 day recovery window, so the same names can be created again at once
  # (the cleanup script force-deletes them too, just in case).
  # ===========================================================================
  DbAppSecret:
    Type: AWS::SecretsManager::Secret
    Properties:
      Name: !Ref DbAppSecretName
      Description: !Sub "${ProjectName} - password of the WordPress database user (ONLY the WordPress database)"
      GenerateSecretString: { PasswordLength: 32, ExcludePunctuation: true }
      Tags:
        - { Key: Project, Value: !Ref ProjectName }

  WpAdminSecret:
    Type: AWS::SecretsManager::Secret
    Properties:
      Name: !Ref WpAdminSecretName
      Description: !Sub "${ProjectName} - WordPress admin password (user in the compute layer)"
      GenerateSecretString: { PasswordLength: 32, ExcludePunctuation: true }
      Tags:
        - { Key: Project, Value: !Ref ProjectName }

  # ===========================================================================
  # Database: RDS MariaDB in the private data tier.
  # ===========================================================================
  DbSubnetGroup:
    Type: AWS::RDS::DBSubnetGroup
    Properties:
      DBSubnetGroupName: !Sub "${ProjectName}-db-subnets"
      DBSubnetGroupDescription: Private subnets data-a + data-b (no internet route)
      SubnetIds:
        - Fn::ImportValue: !Sub "${ProjectName}-DataSubnetAId"
        - Fn::ImportValue: !Sub "${ProjectName}-DataSubnetBId"
      Tags:
        - { Key: Project, Value: !Ref ProjectName }

  # The database's error log (start/stop, crashes, failed logins, TLS
  # problems) next to the web servers' logs in CloudWatch Logs. RDS would
  # create the group itself - but with no retention (kept forever) and not
  # owned by the stack. Created here first, so RDS writes into OUR group.
  DbErrorLogGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: !Sub "/aws/rds/instance/${ProjectName}-db/error"
      RetentionInDays: !Ref DbLogRetentionDays
      Tags:
        - { Key: Project, Value: !Ref ProjectName }

  # Choices (cost first, see the documentation):
  #   db.t4g.micro, 20 GiB gp2, Single-AZ  - all inside the free tier / Free plan
  #                                          (DbMultiAz=true adds a standby in AZ b:
  #                                          the web tier is multi-AZ either way)
  #   AZ a                                 - web servers in AZ b reach it across AZs
  #                                          (cents per GB, see the cost estimate)
  #   PubliclyAccessible false             - no public IP, and the subnet has no
  #                                          internet route anyway
  #   StorageEncrypted (aws/rds key)       - encryption at rest, free
  #   BackupRetentionPeriod 1              - automated backups + point-in-time
  #                                          restore for the last day (Free plan max)
  #   ManageMasterUserPassword             - RDS generates the master password,
  #                                          stores it in Secrets Manager and
  #                                          rotates it every 7 days. Nobody ever
  #                                          sees it; the web servers read it only
  #                                          to create/update the WordPress user.
  #   EnableCloudwatchLogsExports error    - central logging (no reboot needed)
  Database:
    Type: AWS::RDS::DBInstance
    DependsOn: DbErrorLogGroup
    DeletionPolicy: Delete          # lab: cleanup removes everything (default would leave a paid snapshot)
    UpdateReplacePolicy: Snapshot   # but never lose data if a change forces a replacement
    Properties:
      DBInstanceIdentifier: !Sub "${ProjectName}-db"
      Engine: mariadb
      DBInstanceClass: !Ref DbInstanceClass
      AllocatedStorage: !Ref DbAllocatedStorage
      StorageType: gp2
      StorageEncrypted: true
      MultiAZ: !If [MultiAz, true, false]
      AvailabilityZone: !If [MultiAz, !Ref AWS::NoValue, !Select [0, !GetAZs ""]]
      DBSubnetGroupName: !Ref DbSubnetGroup
      VPCSecurityGroups:
        - Fn::ImportValue: !Sub "${ProjectName}-DbSgId"
      PubliclyAccessible: false
      Port:
        Fn::ImportValue: !Sub "${ProjectName}-DbPort"
      DBName: !Ref DbName
      MasterUsername: !Ref DbMasterUsername
      ManageMasterUserPassword: true
      BackupRetentionPeriod: !Ref DbBackupRetentionDays
      PreferredBackupWindow: "01:00-01:30"              # UTC, after the S3 backup at 00:00
      PreferredMaintenanceWindow: "sun:02:00-sun:02:30"
      AutoMinorVersionUpgrade: true
      CopyTagsToSnapshot: true
      DeleteAutomatedBackups: true
      DeletionProtection: false
      EnablePerformanceInsights: false
      EnableCloudwatchLogsExports: [error]
      MonitoringInterval: 0
      Tags:
        - { Key: Name, Value: !Sub "${ProjectName}-db" }
        - { Key: Project, Value: !Ref ProjectName }

  # ===========================================================================
  # Shared storage: EFS for the WordPress files. Every web server mounts the
  # same file system (through the mount target in its own AZ), so all servers
  # in the Auto Scaling group serve the same site - and a replaced or newly
  # scaled-out server (new AMI, new launch template) loses nothing.
  #
  # Three locks besides the network:
  #   1. file system policy: only encrypted (TLS) connections, only the web
  #      server's role, only through an access point
  #   2. access point: every client is forced to uid/gid 48 (apache) in
  #      /wordpress - not even root on the server can act as root on EFS
  #   3. encryption at rest (aws/elasticfilesystem key)
  # ===========================================================================
  FileSystem:
    Type: AWS::EFS::FileSystem
    DeletionPolicy: Delete
    UpdateReplacePolicy: Retain
    Properties:
      Encrypted: true
      PerformanceMode: generalPurpose
      ThroughputMode: bursting       # no charge per GB read/written (elastic charges per GB)
      BackupPolicy: { Status: DISABLED }   # AWS Backup costs extra; wp-content goes to S3 backup/ daily
      FileSystemPolicy:
        Version: "2012-10-17"
        Statement:
          - Sid: OnlyEncryptedTransport
            Effect: Deny
            Principal: { AWS: "*" }
            Action: "*"
            Condition:
              Bool: { "aws:SecureTransport": "false" }
          - Sid: OnlyWebRoleViaAccessPoint
            Effect: Allow
            Principal: { AWS: "*" }
            Action: [elasticfilesystem:ClientMount, elasticfilesystem:ClientWrite]
            Condition:
              ArnEquals: { "aws:PrincipalArn": !Sub "arn:aws:iam::${AWS::AccountId}:role/${WebRoleName}" }
              StringLike: { "elasticfilesystem:AccessPointArn": !Sub "arn:aws:elasticfilesystem:${AWS::Region}:${AWS::AccountId}:access-point/*" }
      FileSystemTags:
        - { Key: Name, Value: !Sub "${ProjectName}-wordpress-efs" }
        - { Key: Project, Value: !Ref ProjectName }

  WordpressAccessPoint:
    Type: AWS::EFS::AccessPoint
    Properties:
      FileSystemId: !Ref FileSystem
      PosixUser: { Uid: "48", Gid: "48" }          # apache on Amazon Linux 2023
      RootDirectory:
        Path: /wordpress
        CreationInfo: { OwnerUid: "48", OwnerGid: "48", Permissions: "0755" }
      AccessPointTags:
        - { Key: Name, Value: !Sub "${ProjectName}-wordpress-ap" }
        - { Key: Project, Value: !Ref ProjectName }

  # Mount targets in the PRIVATE data subnets, one per AZ (the web server uses
  # the one in its own AZ: no cross-AZ traffic).
  EfsMountTargetA:
    Type: AWS::EFS::MountTarget
    Properties:
      FileSystemId: !Ref FileSystem
      SubnetId:
        Fn::ImportValue: !Sub "${ProjectName}-DataSubnetAId"
      SecurityGroups:
        - Fn::ImportValue: !Sub "${ProjectName}-EfsSgId"
  EfsMountTargetB:
    Type: AWS::EFS::MountTarget
    Properties:
      FileSystemId: !Ref FileSystem
      SubnetId:
        Fn::ImportValue: !Sub "${ProjectName}-DataSubnetBId"
      SecurityGroups:
        - Fn::ImportValue: !Sub "${ProjectName}-EfsSgId"

Outputs:
  DbInstanceId:
    Value: !Ref Database
  DbEndpoint:
    Value: !GetAtt Database.Endpoint.Address
    Export: { Name: !Sub "${ProjectName}-DbEndpoint" }
  DbSubnetGroupName:
    Value: !Ref DbSubnetGroup
  FileSystemId:
    Value: !Ref FileSystem
    Export: { Name: !Sub "${ProjectName}-FileSystemId" }
  FileSystemArn:
    Value: !GetAtt FileSystem.Arn
    Export: { Name: !Sub "${ProjectName}-FileSystemArn" }
  AccessPointId:
    Value: !Ref WordpressAccessPoint
    Export: { Name: !Sub "${ProjectName}-AccessPointId" }
  AccessPointArn:
    Value: !GetAtt WordpressAccessPoint.Arn
    Export: { Name: !Sub "${ProjectName}-AccessPointArn" }
  EfsMountTargetAId:
    Value: !Ref EfsMountTargetA
  DbErrorLogGroupName:
    Value: !Ref DbErrorLogGroup
  DbMasterSecretArn:
    Description: Secret managed by RDS (JSON with username + password)
    Value: !GetAtt Database.MasterUserSecret.SecretArn
    Export: { Name: !Sub "${ProjectName}-DbMasterSecretArn" }
  DbAppSecretArn:
    Value: !Ref DbAppSecret
    Export: { Name: !Sub "${ProjectName}-DbAppSecretArn" }
  WpAdminSecretArn:
    Value: !Ref WpAdminSecret
    Export: { Name: !Sub "${ProjectName}-WpAdminSecretArn" }
```

### *__V48_03-security.yaml__*

```yaml
AWSTemplateFormatVersion: "2010-09-09"
Description: >
  Novatrix V48 - layer 3 of 6: security (IAM). Service roles for the web
  server (incl. the CloudWatch agent), the uploader (role chaining), the
  publisher and the site check, plus groups, policies and users for operations,
  development and marketing. Least privilege everywhere.

Metadata:
  AWS::CloudFormation::Interface:
    ParameterGroups:
      - Label: { default: General }
        Parameters: [ProjectName, SiteBucket]
      - Label: { default: Users }
        Parameters: [OpsUserName, DevUserName, MarketingUserName]

Parameters:
  ProjectName:
    Type: String
    Default: novatrix
    AllowedPattern: '^[a-z][a-z0-9-]{1,20}$'
  SiteBucket:
    Type: String
    Description: The project bucket (created in layer 4 - policies only need its name)
  OpsUserName:        { Type: String, Default: anna.ops }
  DevUserName:   { Type: String, Default: erik.dev }
  MarketingUserName:      { Type: String, Default: maja.marketing }

Resources:
  # ===========================================================================
  # Web server (reader) role - shared by EVERY server in the Auto Scaling group
  #   S3:   read-only, and only the published static content (web/). It writes
  #         NOTHING to S3 itself - logs and backups go through the uploader role.
  #   Secrets Manager: read exactly the three project secrets (ARNs imported
  #         from layer 2 - not a wildcard). The master password is only used at
  #         boot, to create/update the WordPress DB user.
  #   EFS:  mount and write - only through the WordPress access point.
  #   CloudWatch agent: metrics ONLY in the namespace CWAgent (a hacked server
  #         can't fake the site check's metrics), logs ONLY into the existing
  #         /<project>/web/* groups (no creating, no deleting, no reading), and
  #         read ONLY its own configuration parameter.
  # ===========================================================================
  Ec2Role:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub "${ProjectName}-web-ec2-role"
      Description: Web server - WordPress on EFS, read static content in S3
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Effect: Allow
            Principal: { Service: ec2.amazonaws.com }
            Action: sts:AssumeRole
      Policies:
        - PolicyName: !Sub "${ProjectName}-web-ec2-access"
          PolicyDocument:
            Version: "2012-10-17"
            Statement:
              - Sid: ListPublishedSite
                Effect: Allow
                Action: s3:ListBucket
                Resource: !Sub "arn:aws:s3:::${SiteBucket}"
                Condition: { StringLike: { "s3:prefix": ["web/*"] } }
              - Sid: ReadPublishedSite
                Effect: Allow
                Action: s3:GetObject
                Resource: !Sub "arn:aws:s3:::${SiteBucket}/web/*"
              - Sid: AssumeUploaderRole
                Effect: Allow
                Action: sts:AssumeRole
                Resource: !Sub "arn:aws:iam::${AWS::AccountId}:role/${ProjectName}-uploader-role"
              - Sid: ReadProjectSecrets
                Effect: Allow
                Action: secretsmanager:GetSecretValue
                Resource:
                  - Fn::ImportValue: !Sub "${ProjectName}-DbMasterSecretArn"
                  - Fn::ImportValue: !Sub "${ProjectName}-DbAppSecretArn"
                  - Fn::ImportValue: !Sub "${ProjectName}-WpAdminSecretArn"
              - Sid: MountWordpressViaAccessPoint
                Effect: Allow
                Action: [elasticfilesystem:ClientMount, elasticfilesystem:ClientWrite]
                Resource:
                  Fn::ImportValue: !Sub "${ProjectName}-FileSystemArn"
                Condition:
                  StringEquals:
                    "elasticfilesystem:AccessPointArn":
                      Fn::ImportValue: !Sub "${ProjectName}-AccessPointArn"
              - Sid: AgentMetricsOnlyOwnNamespace
                Effect: Allow
                Action: cloudwatch:PutMetricData
                Resource: "*"                       # PutMetricData has no resource ARNs
                Condition: { StringEquals: { "cloudwatch:namespace": CWAgent } }
              - Sid: AgentShipLogsToWebGroups
                Effect: Allow
                Action: [logs:CreateLogStream, logs:PutLogEvents, logs:DescribeLogStreams]
                Resource: !Sub "arn:aws:logs:${AWS::Region}:${AWS::AccountId}:log-group:/${ProjectName}/web/*:*"
              - Sid: AgentReadOwnConfig
                Effect: Allow
                Action: ssm:GetParameter
                Resource: !Sub "arn:aws:ssm:${AWS::Region}:${AWS::AccountId}:parameter/${ProjectName}/cloudwatch-agent/web"
              - Sid: AgentFindOwnAutoScalingGroup
                Effect: Allow
                Action: ec2:DescribeTags            # the agent reads the aws:autoscaling:groupName tag
                Resource: "*"
      Tags:
        - { Key: Project, Value: !Ref ProjectName }

  Ec2InstanceProfile:
    Type: AWS::IAM::InstanceProfile
    Properties:
      InstanceProfileName: !Sub "${ProjectName}-web-ec2-profile"
      Roles: [!Ref Ec2Role]

  # ===========================================================================
  # Uploader role: ONLY a session running with the web server's role may assume
  # it (role chaining). Not the EC2 service, not users, not even administrators.
  # Write-only, only logs/ and backup/: a hacked web server can add a backup
  # but never read, list or delete the old ones.
  # ===========================================================================
  UploaderRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub "${ProjectName}-uploader-role"
      Description: Upload logs and backups - assumable only by the web server role
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Sid: OnlyReaderRole
            Effect: Allow
            Principal: { AWS: !GetAtt Ec2Role.Arn }
            Action: sts:AssumeRole
      Policies:
        - PolicyName: !Sub "${ProjectName}-uploader-access"
          PolicyDocument:
            Version: "2012-10-17"
            Statement:
              - Sid: UploadLogsAndBackups
                Effect: Allow
                Action: s3:PutObject
                Resource:
                  - !Sub "arn:aws:s3:::${SiteBucket}/logs/*"
                  - !Sub "arn:aws:s3:::${SiteBucket}/backup/*"
      Tags:
        - { Key: Project, Value: !Ref ProjectName }

  # ===========================================================================
  # Publisher (Lambda) role: read drafts, write published files, log to its own
  # log group. Nothing else - not even logs:CreateLogGroup (layer 4 creates it).
  # ===========================================================================
  LambdaRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub "${ProjectName}-publisher-role"
      Description: Publisher - S3 drafts/ -> web/
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Effect: Allow
            Principal: { Service: lambda.amazonaws.com }
            Action: sts:AssumeRole
      Policies:
        - PolicyName: !Sub "${ProjectName}-publisher-access"
          PolicyDocument:
            Version: "2012-10-17"
            Statement:
              - Sid: ReadDrafts
                Effect: Allow
                Action: s3:GetObject
                Resource: !Sub "arn:aws:s3:::${SiteBucket}/drafts/*"
              - Sid: Publish
                Effect: Allow
                Action: s3:PutObject
                Resource: !Sub "arn:aws:s3:::${SiteBucket}/web/*"
              - Sid: WriteOwnLogs
                Effect: Allow
                Action: [logs:CreateLogStream, logs:PutLogEvents]
                Resource: !Sub "arn:aws:logs:${AWS::Region}:${AWS::AccountId}:log-group:/aws/lambda/${ProjectName}-publisher:*"
      Tags:
        - { Key: Project, Value: !Ref ProjectName }

  # ===========================================================================
  # Site check (Lambda, layer 6): asks the website from OUTSIDE like a visitor
  # and reports to CloudWatch. It needs nothing in the VPC, S3 or IAM - only
  # its own log group and metrics in its own namespace.
  # ===========================================================================
  SiteCheckRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub "${ProjectName}-site-check-role"
      Description: Site check - write metrics Novatrix/SiteCheck and its own logs, nothing else
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Effect: Allow
            Principal: { Service: lambda.amazonaws.com }
            Action: sts:AssumeRole
      Policies:
        - PolicyName: !Sub "${ProjectName}-site-check-access"
          PolicyDocument:
            Version: "2012-10-17"
            Statement:
              - Sid: MetricsOnlyOwnNamespace
                Effect: Allow
                Action: cloudwatch:PutMetricData
                Resource: "*"
                Condition: { StringEquals: { "cloudwatch:namespace": Novatrix/SiteCheck } }
              - Sid: WriteOwnLogs
                Effect: Allow
                Action: [logs:CreateLogStream, logs:PutLogEvents]
                Resource: !Sub "arn:aws:logs:${AWS::Region}:${AWS::AccountId}:log-group:/aws/lambda/${ProjectName}-site-check:*"
      Tags:
        - { Key: Project, Value: !Ref ProjectName }

  # ===========================================================================
  # Humans: permissions ONLY through groups - never directly on a user.
  # No passwords or access keys are created here.
  # ===========================================================================
  OpsGroup:
    Type: AWS::IAM::Group
    Properties: { GroupName: !Sub "${ProjectName}-operations" }
  DevGroup:
    Type: AWS::IAM::Group
    Properties: { GroupName: !Sub "${ProjectName}-development" }
  MarketingGroup:
    Type: AWS::IAM::Group
    Properties: { GroupName: !Sub "${ProjectName}-marketing" }

  # Operations: operate the project's servers (bastion start/stop, web servers
  # through the Auto Scaling group: desired capacity, replace an instance, roll
  # out new servers), read logs/metrics/network/database/EFS/load balancer setup
  # and download backups (to restore). Monitoring: see every alarm, metric and
  # dashboard, read and SEARCH (Logs Insights) all the project's logs. No
  # content, no code, no network, database, load balancer or scaling-limit
  # changes, no secrets, no stack changes - and no deleting or silencing alarms,
  # no deleting logs, no unsubscribing from the alarm mails.
  OpsPolicy:
    Type: AWS::IAM::ManagedPolicy
    Properties:
      ManagedPolicyName: !Sub "${ProjectName}-operations-policy"
      Groups: [!Ref OpsGroup]
      PolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Sid: ReadOnlyOverview
            Effect: Allow
            Action:
              - ec2:DescribeInstances
              - ec2:DescribeInstanceStatus
              - ec2:DescribeSecurityGroups
              - ec2:DescribeSecurityGroupRules
              - ec2:DescribeNetworkAcls
              - ec2:DescribeVpcs
              - ec2:DescribeSubnets
              - ec2:DescribeRouteTables
              - ec2:DescribeVpcEndpoints
              - ec2:DescribeFlowLogs
              - rds:DescribeDBInstances
              - rds:DescribeDBSnapshots
              - rds:DescribeDBSubnetGroups
              - elasticfilesystem:DescribeFileSystems
              - elasticfilesystem:DescribeMountTargets
              - elasticfilesystem:DescribeAccessPoints
              - cloudwatch:GetMetricData
              - cloudwatch:GetMetricStatistics
              - cloudwatch:ListMetrics
              - logs:DescribeLogGroups
              - cloudformation:DescribeStacks
              - cloudformation:DescribeStackEvents
              - cloudformation:DescribeStackResources
              - autoscaling:DescribeAutoScalingGroups
              - autoscaling:DescribeAutoScalingInstances
              - autoscaling:DescribeScalingActivities
              - autoscaling:DescribePolicies
              - autoscaling:DescribeInstanceRefreshes
              - elasticloadbalancing:DescribeLoadBalancers
              - elasticloadbalancing:DescribeListeners
              - elasticloadbalancing:DescribeTargetGroups
              - elasticloadbalancing:DescribeTargetHealth
              - ec2:DescribeLaunchTemplates
              - ec2:DescribeLaunchTemplateVersions
              - cloudwatch:DescribeAlarms
              - cloudwatch:DescribeAlarmHistory
              - cloudwatch:GetDashboard
              - cloudwatch:ListDashboards
              - logs:DescribeQueryDefinitions
              - logs:GetQueryResults
              - logs:StopQuery
              - logs:DescribeMetricFilters
              - sns:ListTopics
            Resource: "*"
          - Sid: ReadAndSearchCentralLogs
            Effect: Allow
            Action: [logs:DescribeLogStreams, logs:GetLogEvents, logs:FilterLogEvents, logs:StartQuery]
            Resource:
              - !Sub "arn:aws:logs:${AWS::Region}:${AWS::AccountId}:log-group:/${ProjectName}/web/*:*"
              - !Sub "arn:aws:logs:${AWS::Region}:${AWS::AccountId}:log-group:/aws/lambda/${ProjectName}-*:*"
              - !Sub "arn:aws:logs:${AWS::Region}:${AWS::AccountId}:log-group:/aws/rds/instance/${ProjectName}-db/*:*"
          # Within the limits in the template (min/max): add a server before a
          # campaign, replace a sick one, roll out all servers again. Only the
          # project's own group (tag), and never change min/max or the policies.
          - Sid: OperateProjectAutoScalingGroup
            Effect: Allow
            Action:
              - autoscaling:SetDesiredCapacity
              - autoscaling:TerminateInstanceInAutoScalingGroup
              - autoscaling:StartInstanceRefresh
            Resource: !Sub "arn:aws:autoscaling:${AWS::Region}:${AWS::AccountId}:autoScalingGroup:*:autoScalingGroupName/${ProjectName}-*"
            Condition: { StringEquals: { "autoscaling:ResourceTag/Project": !Ref ProjectName } }
          - Sid: ReadFlowLogs
            Effect: Allow
            Action: [logs:DescribeLogStreams, logs:GetLogEvents, logs:FilterLogEvents]
            Resource: !Sub
              - "arn:aws:logs:${AWS::Region}:${AWS::AccountId}:log-group:${Grupp}:*"
              - Grupp:
                  Fn::ImportValue: !Sub "${ProjectName}-FlowLogGroupName"
          - Sid: ControlOnlyProjectInstances
            Effect: Allow
            Action: [ec2:StartInstances, ec2:StopInstances, ec2:RebootInstances]
            Resource: !Sub "arn:aws:ec2:${AWS::Region}:${AWS::AccountId}:instance/*"
            Condition: { StringEquals: { "aws:ResourceTag/Project": !Ref ProjectName } }
          - Sid: ReadPublisherLogs
            Effect: Allow
            Action: [logs:DescribeLogStreams, logs:GetLogEvents, logs:FilterLogEvents]
            Resource: !Sub "arn:aws:logs:${AWS::Region}:${AWS::AccountId}:log-group:/aws/lambda/${ProjectName}-publisher:*"
          - Sid: ListLogsAndBackups
            Effect: Allow
            Action: s3:ListBucket
            Resource: !Sub "arn:aws:s3:::${SiteBucket}"
            Condition: { StringLike: { "s3:prefix": ["logs/*", "backup/*"] } }
          - Sid: ReadLogsAndBackups
            Effect: Allow
            Action: s3:GetObject
            Resource:
              - !Sub "arn:aws:s3:::${SiteBucket}/logs/*"
              - !Sub "arn:aws:s3:::${SiteBucket}/backup/*"

  # Development: upload any draft, read the published site, deploy publisher code.
  # Can NOT write web/ directly - everything goes through the publisher's checks.
  DevPolicy:
    Type: AWS::IAM::ManagedPolicy
    Properties:
      ManagedPolicyName: !Sub "${ProjectName}-development-policy"
      Groups: [!Ref DevGroup]
      PolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Sid: ListSite
            Effect: Allow
            Action: s3:ListBucket
            Resource: !Sub "arn:aws:s3:::${SiteBucket}"
            Condition: { StringLike: { "s3:prefix": ["drafts/*", "web/*"] } }
          - Sid: ManageDrafts
            Effect: Allow
            Action: [s3:GetObject, s3:PutObject, s3:DeleteObject]
            Resource: !Sub "arn:aws:s3:::${SiteBucket}/drafts/*"
          - Sid: ReadPublishedSite
            Effect: Allow
            Action: s3:GetObject
            Resource: !Sub "arn:aws:s3:::${SiteBucket}/web/*"
          - Sid: DeployPublisherCode
            Effect: Allow
            Action: [lambda:GetFunction, lambda:UpdateFunctionCode]
            Resource: !Sub "arn:aws:lambda:${AWS::Region}:${AWS::AccountId}:function:${ProjectName}-publisher"
          - Sid: ReadPublisherLogs
            Effect: Allow
            Action: [logs:DescribeLogStreams, logs:GetLogEvents, logs:FilterLogEvents]
            Resource: !Sub "arn:aws:logs:${AWS::Region}:${AWS::AccountId}:log-group:/aws/lambda/${ProjectName}-publisher:*"
          - Sid: ListLogGroups
            Effect: Allow
            Action: logs:DescribeLogGroups
            Resource: "*"

  # Marketing: upload images to drafts/images/ only. Cannot delete, cannot touch pages.
  MarketingPolicy:
    Type: AWS::IAM::ManagedPolicy
    Properties:
      ManagedPolicyName: !Sub "${ProjectName}-marketing-policy"
      Groups: [!Ref MarketingGroup]
      PolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Sid: ListOwnImages
            Effect: Allow
            Action: s3:ListBucket
            Resource: !Sub "arn:aws:s3:::${SiteBucket}"
            Condition: { StringLike: { "s3:prefix": ["drafts/images/*"] } }
          - Sid: UploadImages
            Effect: Allow
            Action: [s3:GetObject, s3:PutObject]
            Resource: !Sub "arn:aws:s3:::${SiteBucket}/drafts/images/*"

  OpsUser:
    Type: AWS::IAM::User
    Properties:
      UserName: !Ref OpsUserName
      Groups: [!Ref OpsGroup]
      Tags: [{ Key: Project, Value: !Ref ProjectName }]
  DevUser:
    Type: AWS::IAM::User
    Properties:
      UserName: !Ref DevUserName
      Groups: [!Ref DevGroup]
      Tags: [{ Key: Project, Value: !Ref ProjectName }]
  MarketingUser:
    Type: AWS::IAM::User
    Properties:
      UserName: !Ref MarketingUserName
      Groups: [!Ref MarketingGroup]
      Tags: [{ Key: Project, Value: !Ref ProjectName }]

Outputs:
  Ec2RoleArn:
    Value: !GetAtt Ec2Role.Arn
    Export: { Name: !Sub "${ProjectName}-Ec2RoleArn" }
  Ec2InstanceProfileName:
    Value: !Ref Ec2InstanceProfile
    Export: { Name: !Sub "${ProjectName}-Ec2InstanceProfileName" }
  UploaderRoleArn:
    Value: !GetAtt UploaderRole.Arn
    Export: { Name: !Sub "${ProjectName}-UploaderRoleArn" }
  LambdaRoleArn:
    Value: !GetAtt LambdaRole.Arn
    Export: { Name: !Sub "${ProjectName}-LambdaRoleArn" }
  SiteCheckRoleArn:
    Value: !GetAtt SiteCheckRole.Arn
    Export: { Name: !Sub "${ProjectName}-SiteCheckRoleArn" }
```

### *__V48_04-storage.yaml__*

```yaml
AWSTemplateFormatVersion: "2010-09-09"
Description: >
  Novatrix V48 - layer 4 of 6: storage. One private S3 bucket (drafts/, web/,
  logs/, backup/) with bucket policy and lifecycle rules, plus the publisher
  (Lambda) that S3 triggers when a draft is uploaded.

Parameters:
  ProjectName:
    Type: String
    Default: novatrix
    AllowedPattern: '^[a-z][a-z0-9-]{1,20}$'
  SiteBucket:
    Type: String
    AllowedPattern: '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$'
    Description: Bucket name (globally unique - the deploy script appends the account id)
  BackupRetentionDays:
    Type: Number
    Default: 14
    MinValue: 1
    Description: backup/ objects (DB dumps + wp-content) are deleted after this many days
  LogRetentionDays:
    Type: Number
    Default: 30
    MinValue: 1
    Description: logs/ objects (Apache logs) are deleted after this many days

Resources:
  # Created here (not by Lambda) so the Lambda role needs no logs:CreateLogGroup.
  PublisherLogGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: !Sub "/aws/lambda/${ProjectName}-publisher"
      RetentionInDays: 7
      Tags:
        - { Key: Project, Value: !Ref ProjectName }

  # ===========================================================================
  # Publisher: copies approved drafts from drafts/ to web/. The code lives in
  # the template itself (inline, < 4 KB), so it is versioned with everything else.
  # ===========================================================================
  PublisherFunction:
    Type: AWS::Lambda::Function
    DependsOn: PublisherLogGroup
    Properties:
      FunctionName: !Sub "${ProjectName}-publisher"
      Description: Publishes approved drafts drafts/ -> web/
      Runtime: python3.12
      Handler: index.lambda_handler
      Role:
        Fn::ImportValue: !Sub "${ProjectName}-LambdaRoleArn"
      Timeout: 15
      MemorySize: 128
      Tags:
        - { Key: Project, Value: !Ref ProjectName }
      Code:
        ZipFile: |
          """Publisher: copies approved drafts from drafts/ to web/.

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
                  rel = key[len("drafts/"):] if key.startswith("drafts/") else ""
                  ext = os.path.splitext(rel)[1].lower()

                  if not rel or ".." in rel or rel.endswith("/"):
                      log(rejected=key, reason="invalid path")
                  elif ext not in ALLOWED:
                      log(rejected=key, reason=f"file type {ext or '(none)'} is not published")
                  elif size > MAX_BYTES:
                      log(rejected=key, reason="file is larger than 5 MB")
                  else:
                      body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
                      s3.put_object(Bucket=bucket, Key=f"web/{rel}", Body=body,
                                    ContentType=ALLOWED[ext], CacheControl="max-age=300")
                      log(published=f"web/{rel}", bytes=len(body))
              return {"ok": True}

  # Resource-based policy on the Lambda: only S3, only from OUR bucket and OUR
  # account may invoke it (protects against the confused deputy problem).
  # The bucket ARN is built from the name, which breaks the circular
  # dependency bucket -> function -> permission -> bucket.
  PublisherPermission:
    Type: AWS::Lambda::Permission
    Properties:
      FunctionName: !Ref PublisherFunction
      Action: lambda:InvokeFunction
      Principal: s3.amazonaws.com
      SourceArn: !Sub "arn:aws:s3:::${SiteBucket}"
      SourceAccount: !Ref AWS::AccountId

  # ===========================================================================
  # The bucket. Private: visitors reach the site through EC2, never S3 directly.
  # ===========================================================================
  Bucket:
    Type: AWS::S3::Bucket
    DependsOn: PublisherPermission     # S3 tests the trigger when it is created
    UpdateReplacePolicy: Retain
    Properties:
      BucketName: !Ref SiteBucket
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault: { SSEAlgorithm: AES256 }
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        IgnorePublicAcls: true
        BlockPublicPolicy: true
        RestrictPublicBuckets: true
      OwnershipControls:
        Rules: [{ ObjectOwnership: BucketOwnerEnforced }]
      # Storage (and cost) never grows without limit.
      LifecycleConfiguration:
        Rules:
          - Id: expire-old-backups
            Status: Enabled
            Prefix: backup/
            ExpirationInDays: !Ref BackupRetentionDays
          - Id: expire-old-logs
            Status: Enabled
            Prefix: logs/
            ExpirationInDays: !Ref LogRetentionDays
          - Id: abort-incomplete-uploads
            Status: Enabled
            AbortIncompleteMultipartUpload: { DaysAfterInitiation: 1 }
      # Trigger only on drafts/ - the Lambda writes to web/, so it can never
      # trigger itself.
      NotificationConfiguration:
        LambdaConfigurations:
          - Event: s3:ObjectCreated:*
            Function: !GetAtt PublisherFunction.Arn
            Filter:
              S3Key:
                Rules: [{ Name: prefix, Value: drafts/ }]
      Tags:
        - { Key: Project, Value: !Ref ProjectName }

  # Resource policy:
  #  1. refuse every request that is not encrypted in transit (TLS)
  #  2. the web server's roles only work from inside the VPC, through the S3
  #     endpoint. Stolen instance credentials are useless anywhere else.
  BucketPolicy:
    Type: AWS::S3::BucketPolicy
    Properties:
      Bucket: !Ref Bucket
      PolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Sid: OnlyTLS
            Effect: Deny
            Principal: "*"
            Action: "s3:*"
            Resource:
              - !GetAtt Bucket.Arn
              - !Sub "${Bucket.Arn}/*"
            Condition: { Bool: { "aws:SecureTransport": "false" } }
          - Sid: InstanceRolesOnlyViaVpcEndpoint
            Effect: Deny
            Principal: "*"
            Action: "s3:*"
            Resource:
              - !GetAtt Bucket.Arn
              - !Sub "${Bucket.Arn}/*"
            Condition:
              ArnEquals:
                "aws:PrincipalArn":
                  - Fn::ImportValue: !Sub "${ProjectName}-Ec2RoleArn"
                  - Fn::ImportValue: !Sub "${ProjectName}-UploaderRoleArn"
              StringNotEquals:
                "aws:SourceVpce":
                  Fn::ImportValue: !Sub "${ProjectName}-S3EndpointId"

Outputs:
  SiteBucketName:
    Value: !Ref Bucket
    Export: { Name: !Sub "${ProjectName}-SiteBucketName" }
  PublisherFunctionName:
    Value: !Ref PublisherFunction
  PublisherLogGroupName:
    Value: !Ref PublisherLogGroup
```

### *__V48_05-compute.yaml__*

```yaml
AWSTemplateFormatVersion: "2010-09-09"
Description: >
  Novatrix V48 - layer 5 of 6: compute. A launch template for the WordPress
  servers (IMDSv2, encrypted disk, CloudWatch agent), an Auto Scaling group
  across two Availability Zones behind an Application Load Balancer with health
  checks, target tracking scaling, rolling replacement on every change, the
  servers' central log groups + agent configuration, and a bastion as the only
  SSH entry point.

Metadata:
  AWS::CloudFormation::Interface:
    ParameterGroups:
      - Label: { default: Instances }
        Parameters: [ProjectName, AmiId, InstanceType, KeyName, SyncInterval]
      - Label: { default: Auto Scaling and load balancer }
        Parameters: [AsgMinSize, AsgMaxSize, CpuTargetPercent, RequestsPerTargetPerMinute, HealthCheckPath, CertificateArn]
      - Label: { default: Monitoring and logging }
        Parameters: [LogRetentionDays]
      - Label: { default: Database }
        Parameters: [DbName, DbAppUsername]
      - Label: { default: WordPress }
        Parameters: [WpTitle, WpAdminUser, WpAdminEmail, WpLocale]

Parameters:
  ProjectName:
    Type: String
    Default: novatrix
    AllowedPattern: '^[a-z][a-z0-9-]{1,20}$'
  AmiId:
    # A plain image id, NOT the SSM path: the deploy script resolves the latest
    # Amazon Linux 2023 the first time and keeps it, so a routine re-deploy never
    # replaces the servers. A new AMI is a deliberate change (NEW_AMI=1) - and
    # is then rolled out one server at a time (UpdatePolicy below).
    Type: AWS::EC2::Image::Id
  InstanceType:
    Type: String
    Default: t3.micro
    AllowedValues: [t3.micro, t3.small]
    Description: t3.micro is free tier eligible in eu-north-1
  KeyName:
    Type: AWS::EC2::KeyPair::KeyName
    Description: Existing key pair (CloudFormation checks that it exists)
  SyncInterval:
    Type: String
    Default: 30min
    Description: How often each web server pulls web/ from S3 (systemd time span)
  AsgMinSize:
    Type: Number
    Default: 2
    MinValue: 2
    MaxValue: 4
    Description: Never fewer servers than this - 2 = one per AZ, the site survives losing an AZ
  AsgMaxSize:
    Type: Number
    Default: 4
    MinValue: 3
    MaxValue: 6
    Description: Cost ceiling. Must be larger than AsgMinSize (a rolling update starts one extra server)
  CpuTargetPercent:
    Type: Number
    Default: 50
    MinValue: 20
    MaxValue: 90
    Description: Target tracking - keep the group's average CPU around this
  RequestsPerTargetPerMinute:
    Type: Number
    Default: 60
    MinValue: 10
    Description: Target tracking - keep ALB requests per server per minute around this. Set it BELOW a server's measured capacity (~100/min for t3.micro + WordPress on EFS)
  HealthCheckPath:
    Type: String
    Default: /healthz.php
    AllowedPattern: '^/[a-zA-Z0-9_./-]*$'
  CertificateArn:
    Type: String
    Default: ""
    Description: ACM certificate for the HTTPS listener (empty = HTTP only)
  LogRetentionDays:
    Type: Number
    Default: 14
    AllowedValues: [1, 3, 5, 7, 14, 30, 60, 90]
    Description: Days the web servers' logs are kept in CloudWatch Logs (the S3 archive keeps Apache logs longer)
  DbName:                { Type: String, Default: wordpress }
  DbAppUsername:         { Type: String, Default: wordpress }
  WpTitle:               { Type: String, Default: Novatrix, AllowedPattern: "^[^']+$" }
  WpAdminUser:           { Type: String, Default: novatrix-admin }
  WpAdminEmail:          { Type: String, Default: admin@novatrix.example }
  WpLocale:              { Type: String, Default: en_US }

Conditions:
  HasCertificate: !Not [!Equals [!Ref CertificateArn, ""]]

Resources:
  # ===========================================================================
  # Application Load Balancer - the site's only public entrance. One node in
  # web-a and one in web-b (two AZs). It terminates TLS and forwards plain HTTP
  # to the web servers, which only accept traffic from the ALB's security group.
  # ===========================================================================
  Alb:
    Type: AWS::ElasticLoadBalancingV2::LoadBalancer
    Properties:
      Name: !Sub "${ProjectName}-alb"
      Type: application
      Scheme: internet-facing
      IpAddressType: ipv4
      Subnets:
        - Fn::ImportValue: !Sub "${ProjectName}-WebSubnetAId"
        - Fn::ImportValue: !Sub "${ProjectName}-WebSubnetBId"
      SecurityGroups:
        - Fn::ImportValue: !Sub "${ProjectName}-AlbSgId"
      LoadBalancerAttributes:
        - { Key: routing.http.drop_invalid_header_fields.enabled, Value: "true" }   # request smuggling protection
        - { Key: routing.http.desync_mitigation_mode, Value: defensive }
        - { Key: idle_timeout.timeout_seconds, Value: "60" }
        - { Key: deletion_protection.enabled, Value: "false" }                     # lab: cleanup must be able to delete it
      Tags:
        - { Key: Project, Value: !Ref ProjectName }

  # Health check = "can THIS server serve WordPress?": Apache + PHP-FPM answer
  # and the WordPress files on EFS are readable. The database is deliberately
  # NOT part of it: a database outage is not fixed by replacing web servers -
  # with HealthCheckType ELB the group would otherwise terminate every server
  # during e.g. a 2-minute RDS maintenance reboot.
  WebTargetGroup:
    Type: AWS::ElasticLoadBalancingV2::TargetGroup
    Properties:
      Name: !Sub "${ProjectName}-web-tg"
      VpcId:
        Fn::ImportValue: !Sub "${ProjectName}-VpcId"
      TargetType: instance
      Protocol: HTTP
      Port: 80
      HealthCheckProtocol: HTTP
      HealthCheckPath: !Ref HealthCheckPath
      HealthCheckIntervalSeconds: 15
      HealthCheckTimeoutSeconds: 5
      HealthyThresholdCount: 2       # healthy after 30 s
      UnhealthyThresholdCount: 3     # out of rotation after 45 s
      Matcher: { HttpCode: "200" }
      TargetGroupAttributes:
        - { Key: deregistration_delay.timeout_seconds, Value: "30" }   # finish ongoing requests before termination
      Tags:
        - { Key: Project, Value: !Ref ProjectName }

  HttpListener:
    Type: AWS::ElasticLoadBalancingV2::Listener
    Properties:
      LoadBalancerArn: !Ref Alb
      Port: 80
      Protocol: HTTP
      DefaultActions:
        - { Type: forward, TargetGroupArn: !Ref WebTargetGroup }

  # Self-signed certificate (no domain yet) -> browsers warn, but the traffic is
  # encrypted. With a domain: an ACM certificate here and a redirect on port 80.
  HttpsListener:
    Type: AWS::ElasticLoadBalancingV2::Listener
    Condition: HasCertificate
    Properties:
      LoadBalancerArn: !Ref Alb
      Port: 443
      Protocol: HTTPS
      SslPolicy: ELBSecurityPolicy-TLS13-1-2-2021-06     # TLS 1.2 + 1.3 only
      Certificates:
        - CertificateArn: !Ref CertificateArn
      DefaultActions:
        - { Type: forward, TargetGroupArn: !Ref WebTargetGroup }

  # ===========================================================================
  # Central logging: ONE log group per kind of log, one stream per server
  # (named after its instance id). Servers come and go in the Auto Scaling
  # group - their logs stay here, searchable with Logs Insights across ALL
  # servers at once, and are deleted automatically after LogRetentionDays.
  # Created here, before any server starts: the servers' role may write to
  # them but NOT create (or delete) log groups.
  # ===========================================================================
  WebAccessLogGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: !Sub "/${ProjectName}/web/access"     # Apache, one JSON object per request
      RetentionInDays: !Ref LogRetentionDays
      Tags: [{ Key: Project, Value: !Ref ProjectName }]
  WebErrorLogGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: !Sub "/${ProjectName}/web/error"      # Apache error_log
      RetentionInDays: !Ref LogRetentionDays
      Tags: [{ Key: Project, Value: !Ref ProjectName }]
  WebPhpLogGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: !Sub "/${ProjectName}/web/php"        # PHP-FPM: PHP warnings and fatal errors
      RetentionInDays: !Ref LogRetentionDays
      Tags: [{ Key: Project, Value: !Ref ProjectName }]
  WebJobsLogGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: !Sub "/${ProjectName}/web/jobs"       # backup, log archive, sync, wp-cron
      RetentionInDays: !Ref LogRetentionDays
      Tags: [{ Key: Project, Value: !Ref ProjectName }]
  WebBootLogGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: !Sub "/${ProjectName}/web/boot"       # cloud-init: the user data's output
      RetentionInDays: !Ref LogRetentionDays
      Tags: [{ Key: Project, Value: !Ref ProjectName }]

  # CloudWatch agent configuration (the agent on every web server reads it from
  # Parameter Store at boot). Why not in the user data: EC2 limits user data
  # to 16 KB and it is nearly full. Why Parameter Store: free (standard tier),
  # versioned with the template, and the role may read ONLY this parameter.
  #   metrics: memory and root disk use (EC2 itself can't see inside the OS -
  #            CPU it measures from the outside, memory and disk it can't).
  #            ONLY the Auto Scaling group as dimension: servers come and go,
  #            but the metric (and its alarm) stays the same - 2 custom
  #            metrics in total, not 2 per server ever started.
  #   logs:    five files -> the five log groups above, stream = instance id
  WebAgentConfig:
    Type: AWS::SSM::Parameter
    Properties:
      Name: !Sub "/${ProjectName}/cloudwatch-agent/web"
      Type: String
      Tier: Standard
      Description: CloudWatch agent configuration for the web servers
      Value: !Sub |
        {
          "agent": { "metrics_collection_interval": 60, "run_as_user": "root", "omit_hostname": true },
          "metrics": {
            "namespace": "CWAgent",
            "append_dimensions": { "AutoScalingGroupName": "${!aws:AutoScalingGroupName}" },
            "metrics_collected": {
              "mem":  { "measurement": ["mem_used_percent"] },
              "disk": { "measurement": ["used_percent"], "resources": ["/"], "drop_device": true }
            }
          },
          "logs": {
            "logs_collected": { "files": { "collect_list": [
              { "file_path": "/var/log/httpd/access_json.log", "log_group_name": "${WebAccessLogGroup}", "log_stream_name": "{instance_id}" },
              { "file_path": "/var/log/httpd/error_log", "log_group_name": "${WebErrorLogGroup}", "log_stream_name": "{instance_id}" },
              { "file_path": "/var/log/php-fpm/www-error.log", "log_group_name": "${WebPhpLogGroup}", "log_stream_name": "{instance_id}" },
              { "file_path": "/var/log/novatrix-jobs.log", "log_group_name": "${WebJobsLogGroup}", "log_stream_name": "{instance_id}" },
              { "file_path": "/var/log/cloud-init-output.log", "log_group_name": "${WebBootLogGroup}", "log_stream_name": "{instance_id}" }
            ] } }
          }
        }
      Tags: { Project: !Ref ProjectName }

  # ===========================================================================
  # Launch template for the web servers. ALL configuration lives here, so ANY
  # change (new AMI, new user data, new hardening) becomes a new template
  # version - which the Auto Scaling group rolls out one server at a time
  # (immutable servers). The servers are stateless (WordPress lives on EFS +
  # RDS), so a replaced or added server loses nothing.
  #
  # Hardening shared with the bastion (kept identical on purpose):
  #   IMDSv2 only (blocks SSRF-style credential theft with a plain GET),
  #   encrypted gp3 root disk, CpuCredits=standard (no surplus CPU charges).
  # ===========================================================================
  WebLaunchTemplate:
    Type: AWS::EC2::LaunchTemplate
    Properties:
      LaunchTemplateName: !Sub "${ProjectName}-web"
      LaunchTemplateData:
        ImageId: !Ref AmiId
        InstanceType: !Ref InstanceType
        KeyName: !Ref KeyName
        MetadataOptions:
          HttpTokens: required
          HttpEndpoint: enabled
          HttpPutResponseHopLimit: 1
        BlockDeviceMappings:
          - DeviceName: /dev/xvda
            Ebs: { Encrypted: true, VolumeType: gp3, DeleteOnTermination: true }
        CreditSpecification: { CpuCredits: standard }
        IamInstanceProfile:
          Name:
            Fn::ImportValue: !Sub "${ProjectName}-Ec2InstanceProfileName"
        # The subnet is chosen by the Auto Scaling group (web-a or web-b). Public
        # IP only for the server's own outbound traffic - inbound HTTP is only
        # allowed from the ALB (web-sg), SSH only from the bastion.
        NetworkInterfaces:
          - DeviceIndex: 0
            AssociatePublicIpAddress: true
            DeleteOnTermination: true
            Groups:
              - Fn::ImportValue: !Sub "${ProjectName}-WebSgId"
        TagSpecifications:
          - ResourceType: volume
            Tags:
              - { Key: Name, Value: !Sub "${ProjectName}-web" }
              - { Key: Project, Value: !Ref ProjectName }
        # Part 1 (Fn::Sub): this server's settings, written to an env file.
        # Part 2 (plain text, no substitution): the installation, which only reads
        # the env file - so bash's own ${...} needs no escaping.
        # What the user data does, in order (the comments live HERE, outside the
        # script: EC2 limits user data to 16 KB, and every comment line counted):
        #   1. env file /etc/novatrix/wordpress.env (Fn::Sub part) - the rest only reads it
        #   2. trap EXIT -> cfn-signal: success or failure is reported to CloudFormation at
        #      once (a server started later by scaling also signals - ignored then)
        #   3. packages (+ CloudWatch agent); RDS CA in the trust store (mysql + PHP
        #      verify the database's TLS)
        #   4. SSH hardening (validated with sshd -t first - never lock ourselves out)
        #   5. Apache: HTTP only (TLS ends at the ALB, only the ALB may connect),
        #      security headers, no xmlrpc, no PHP in uploads, /.novatrix denied,
        #      /static/ (S3 content), /healthz.php (the ALB health check: PHP + EFS,
        #      NOT the database), mod_remoteip: the visitor's real IP from
        #      X-Forwarded-For, trusted only from the web tier where the ALB lives;
        #      an extra access log as JSON (fields for Logs Insights), WITHOUT the ALB's
        #      health checks (8 per minute per server - noise that costs ingestion)
        #   5b. CloudWatch agent: config from Parameter Store, started BEFORE the slow
        #      part, so even a failing first boot ships its log (/web/boot)
        #   6. EFS mount: tls + iam + access point (uid/gid 48); the EFS DNS name gives
        #      the mount target in this server's own AZ; nofail so a missing EFS never
        #      stops the boot; httpd/php-fpm get RequiresMountsFor
        #   7. helpers in /usr/local/bin: novatrix-secret (Secrets Manager, never on
        #      disk), s3-curl, novatrix-sync, as-uploader (role chaining),
        #      novatrix-logs (per instance id), novatrix-db (master user + password from
        #      the secret RDS manages and rotates), novatrix-backup (ONE per day for
        #      the whole group: the first server to create today's marker on EFS with
        #      O_EXCL takes it; NOVATRIX_BACKUP_FORCE=1 always runs)
        #   8. systemd timers: sync, logs, backup, wp-cron (WordPress locks its cron);
        #      their output -> /var/log/novatrix-jobs.log -> CloudWatch; a failed backup
        #      writes "FAILED" (a metric filter + alarm in the monitoring layer)
        #   9. flock on EFS: at the first deploy two servers boot at once - the second
        #      waits until the first has created the DB user and installed WordPress
        #  10. DB user limited to the web tier CIDR; WordPress via WP-CLI (idempotent:
        #      a new server finds it installed); wp-config trusts X-Forwarded-Proto
        #      from the ALB (no mixed content) and follows the visitor's host name;
        #      DB_PASSWORD is re-synced from the secret on every boot
        #  11. first static sync, start services, prove http://localhost/ and
        #      /healthz.php answer - only then signal success
        UserData:
          Fn::Base64: !Join
            - ""
            - - !Sub
                - |
                  #!/bin/bash
                  set -euo pipefail
                  mkdir -p /etc/novatrix
                  cat > /etc/novatrix/wordpress.env <<'ENV'
                  REGION=${AWS::Region}
                  CFN_STACK=${AWS::StackName}
                  CFN_RESOURCE=WebAsg
                  BUCKET=${Bucket}
                  FS_ID=${FsId}
                  AP_ID=${ApId}
                  DB_HOST=${DbHost}
                  DB_PORT=${DbPort}
                  DB_NAME=${DbName}
                  DB_APP_USER=${DbAppUsername}
                  DB_MASTER_SECRET=${MasterSecret}
                  DB_APP_SECRET=${AppSecret}
                  WP_ADMIN_SECRET=${AdminSecret}
                  WEB_TIER_CIDR=${WebTier}
                  UPLOADER_ARN=${UploaderArn}
                  SYNC_INTERVAL=${SyncInterval}
                  ALB_DNS=${AlbDns}
                  WP_ROOT=/var/www/html
                  WP_LOCALE=${WpLocale}
                  WP_TITLE='${WpTitle}'
                  WP_ADMIN_USER='${WpAdminUser}'
                  WP_ADMIN_EMAIL='${WpAdminEmail}'
                  CW_CONFIG=${WebAgentConfig}
                  ENV
                  chmod 644 /etc/novatrix/wordpress.env
                - Bucket:       { "Fn::ImportValue": !Sub "${ProjectName}-SiteBucketName" }
                  FsId:         { "Fn::ImportValue": !Sub "${ProjectName}-FileSystemId" }
                  ApId:         { "Fn::ImportValue": !Sub "${ProjectName}-AccessPointId" }
                  DbHost:       { "Fn::ImportValue": !Sub "${ProjectName}-DbEndpoint" }
                  DbPort:       { "Fn::ImportValue": !Sub "${ProjectName}-DbPort" }
                  MasterSecret: { "Fn::ImportValue": !Sub "${ProjectName}-DbMasterSecretArn" }
                  AppSecret:    { "Fn::ImportValue": !Sub "${ProjectName}-DbAppSecretArn" }
                  AdminSecret:  { "Fn::ImportValue": !Sub "${ProjectName}-WpAdminSecretArn" }
                  WebTier:      { "Fn::ImportValue": !Sub "${ProjectName}-WebTierCidr" }
                  UploaderArn:  { "Fn::ImportValue": !Sub "${ProjectName}-UploaderRoleArn" }
                  AlbDns:       !GetAtt Alb.DNSName
              - |
                source /etc/novatrix/wordpress.env

                signal() {
                  [ -x /opt/aws/bin/cfn-signal ] && /opt/aws/bin/cfn-signal -e "$1" \
                    --stack "$CFN_STACK" --resource "$CFN_RESOURCE" --region "$REGION" || true
                }
                trap 'rc=$?; signal "$rc"; exit "$rc"' EXIT

                dnf install -y aws-cfn-bootstrap httpd php php-fpm php-mysqlnd mariadb105 amazon-efs-utils util-linux amazon-cloudwatch-agent
                dnf install -y --setopt=strict=0 php-gd php-mbstring php-xml php-opcache php-intl || true

                curl -fsSL -o /etc/pki/ca-trust/source/anchors/rds-$REGION.pem \
                  "https://truststore.pki.rds.amazonaws.com/$REGION/$REGION-bundle.pem"
                update-ca-trust extract

                cat > /etc/ssh/sshd_config.d/10-novatrix.conf <<'SSHD'
                PermitRootLogin no
                PasswordAuthentication no
                KbdInteractiveAuthentication no
                X11Forwarding no
                AllowAgentForwarding no
                MaxAuthTries 3
                LoginGraceTime 30
                ClientAliveInterval 300
                ClientAliveCountMax 2
                AllowTcpForwarding no
                SSHD
                if sshd -t; then systemctl reload sshd
                else echo "sshd rejected 10-novatrix.conf - removed it" >&2; rm -f /etc/ssh/sshd_config.d/10-novatrix.conf; fi

                cat > /etc/httpd/conf.d/10-novatrix-security.conf <<'CONF'
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
                LogFormat "{\"time\":\"%{%FT%T%z}t\",\"ip\":\"%a\",\"method\":\"%m\",\"path\":\"%U\",\"status\":%>s,\"bytes\":%B,\"ms\":%{ms}T,\"ua\":\"%{User-Agent}i\"}" json
                SetEnvIf Request_URI "^/healthz\.php$" nolog
                CustomLog logs/access_json.log json env=!nolog
                <Files "xmlrpc.php">
                    Require all denied
                </Files>
                <Directory "/var/www/html/wp-content/uploads">
                    <FilesMatch "\.(php|phtml|phar)$">
                        Require all denied
                    </FilesMatch>
                </Directory>
                <DirectoryMatch "^/var/www/html/\.novatrix">
                    Require all denied
                </DirectoryMatch>

                Alias /static/ /var/www/static/
                <Directory "/var/www/static">
                    Options -Indexes
                    AllowOverride None
                    Require all granted
                </Directory>

                Alias /healthz.php /var/www/health/healthz.php
                <Directory "/var/www/health">
                    Options None
                    AllowOverride None
                    Require all granted
                </Directory>
                CONF
                printf '<IfModule remoteip_module>\nRemoteIPHeader X-Forwarded-For\nRemoteIPInternalProxy %s\n</IfModule>\n' \
                  "$WEB_TIER_CIDR" > /etc/httpd/conf.d/11-novatrix-remoteip.conf
                cat > /etc/php.d/90-novatrix.ini <<'INI'
                expose_php = Off
                upload_max_filesize = 16M
                post_max_size = 16M
                INI
                /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c "ssm:$CW_CONFIG" || true
                mkdir -p /var/www/health
                cat > /var/www/health/healthz.php <<'PHP'
                <?php
                header('Content-Type: text/plain');
                header('Cache-Control: no-store');
                if (is_file('/var/www/html/wp-config.php') && is_file('/var/www/html/wp-includes/version.php')) {
                    echo "ok\n";
                } else {
                    http_response_code(503);
                    echo "wordpress files missing\n";
                }
                PHP

                mkdir -p "$WP_ROOT"
                echo "$FS_ID:/ $WP_ROOT efs _netdev,nofail,tls,iam,accesspoint=$AP_ID 0 0" >> /etc/fstab
                for i in $(seq 1 18); do
                  mount "$WP_ROOT" 2>/dev/null && break
                  echo "waiting for EFS / the instance role ($i/18)"; sleep 10
                done
                mountpoint -q "$WP_ROOT"
                for svc in httpd php-fpm; do
                  mkdir -p /etc/systemd/system/$svc.service.d
                  printf '[Unit]\nRequiresMountsFor=%s\n' "$WP_ROOT" > /etc/systemd/system/$svc.service.d/10-novatrix-efs.conf
                done

                cat > /usr/local/bin/novatrix-secret <<'SH'
                #!/bin/bash
                set -euo pipefail
                source /etc/novatrix/wordpress.env
                v=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$1" \
                      --query SecretString --output text)
                if [[ -n "${2:-}" ]]; then
                  python3 -c 'import json,sys; print(json.loads(sys.stdin.read())[sys.argv[1]])' "$2" <<<"$v"
                else
                  printf '%s\n' "$v"
                fi
                SH
                chmod 700 /usr/local/bin/novatrix-secret

                cat > /usr/local/bin/s3-curl <<'SH'
                #!/bin/bash
                set -euo pipefail
                source /etc/novatrix/wordpress.env
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

                mkdir -p /var/www/static
                cat > /usr/local/bin/novatrix-sync <<'SH'
                #!/bin/bash
                source /etc/novatrix/wordpress.env
                aws s3 sync "s3://$BUCKET/web/" /var/www/static/ --region "$REGION" --only-show-errors
                SH
                chmod 755 /usr/local/bin/novatrix-sync

                cat > /usr/local/bin/as-uploader <<'SH'
                #!/bin/bash
                set -euo pipefail
                source /etc/novatrix/wordpress.env
                CREDS=$(aws sts assume-role --region "$REGION" \
                  --role-arn "$UPLOADER_ARN" \
                  --role-session-name "uploader-$(hostname -s)" \
                  --duration-seconds 900 \
                  --query '[Credentials.AccessKeyId,Credentials.SecretAccessKey,Credentials.SessionToken]' \
                  --output text)
                read -r AK SK ST <<<"$CREDS"
                AWS_ACCESS_KEY_ID=$AK AWS_SECRET_ACCESS_KEY=$SK AWS_SESSION_TOKEN=$ST exec "$@"
                SH
                chmod 755 /usr/local/bin/as-uploader

                cat > /usr/local/bin/novatrix-logs <<'SH'
                #!/bin/bash
                set -euo pipefail
                source /etc/novatrix/wordpress.env
                IMDS="http://169.254.169.254/latest"
                TOKEN=$(curl -sf -X PUT "$IMDS/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
                IID=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" "$IMDS/meta-data/instance-id")
                STAMP=$(date -u +%Y%m%dT%H%M%SZ)
                for f in access_log error_log; do
                  [[ -s "/var/log/httpd/$f" ]] || continue
                  gzip -c "/var/log/httpd/$f" > "/tmp/$f.gz"
                  /usr/local/bin/as-uploader aws s3 cp "/tmp/$f.gz" \
                    "s3://$BUCKET/logs/$IID/$STAMP-$f.gz" --region "$REGION" --only-show-errors
                  rm -f "/tmp/$f.gz"
                  echo "Uploaded $f -> logs/$IID/$STAMP-$f.gz"
                done
                SH
                chmod 755 /usr/local/bin/novatrix-logs

                cat > /usr/local/bin/novatrix-db <<'SH'
                #!/bin/bash
                set -euo pipefail
                source /etc/novatrix/wordpress.env
                case "${1:-}" in
                  app)    user=$DB_APP_USER
                          pw=$(/usr/local/bin/novatrix-secret "$DB_APP_SECRET") ;;
                  master) user=$(/usr/local/bin/novatrix-secret "$DB_MASTER_SECRET" username)
                          pw=$(/usr/local/bin/novatrix-secret "$DB_MASTER_SECRET" password) ;;
                  *) echo "usage: novatrix-db app|master [args]" >&2; exit 2 ;;
                esac
                shift
                pw=${pw//\\/\\\\}    # option file: value in "", backslash escaped
                cnf=$(mktemp); trap 'rm -f "$cnf"' EXIT
                printf '[client]\nhost=%s\nport=%s\nuser=%s\npassword="%s"\nssl-ca=/etc/pki/ca-trust/source/anchors/rds-%s.pem\nssl-verify-server-cert\n' \
                  "$DB_HOST" "$DB_PORT" "$user" "$pw" "$REGION" > "$cnf"
                if [[ -n "${NOVATRIX_DUMP:-}" ]]; then mysqldump --defaults-extra-file="$cnf" "$@"
                else mysql --defaults-extra-file="$cnf" "$@"; fi
                SH
                chmod 750 /usr/local/bin/novatrix-db

                cat > /usr/local/bin/novatrix-backup <<'SH'
                #!/bin/bash
                set -euo pipefail
                source /etc/novatrix/wordpress.env
                MARKERS="$WP_ROOT/.novatrix"
                mkdir -p "$MARKERS"
                find "$MARKERS" -name 'backup-*' -mtime +7 -delete 2>/dev/null || true
                if [[ -z "${NOVATRIX_BACKUP_FORCE:-}" ]]; then
                  MARK="$MARKERS/backup-$(date -u +%Y%m%d)"
                  if ! (set -o noclobber; hostname -s > "$MARK") 2>/dev/null; then
                    echo "Today's backup is already taken by $(cat "$MARK" 2>/dev/null) - skipping."
                    exit 0
                  fi
                fi
                STAMP=$(date -u +%Y%m%dT%H%M%SZ)
                trap 'echo "novatrix-backup FAILED (line $LINENO)" >&2' ERR
                DUMP=$(mktemp /tmp/novatrix-db-XXXXXX.sql.gz); trap 'rm -f "$DUMP"' EXIT
                NOVATRIX_DUMP=1 /usr/local/bin/novatrix-db app --single-transaction --no-tablespaces "$DB_NAME" | gzip > "$DUMP"
                /usr/local/bin/as-uploader aws s3 cp "$DUMP" \
                  "s3://$BUCKET/backup/db/$STAMP-$DB_NAME.sql.gz" --region "$REGION" --only-show-errors
                echo "Uploaded backup/db/$STAMP-$DB_NAME.sql.gz"
                tar -czf - -C "$WP_ROOT" wp-content | /usr/local/bin/as-uploader aws s3 cp - \
                  "s3://$BUCKET/backup/files/$STAMP-wp-content.tar.gz" --region "$REGION" --only-show-errors
                echo "Uploaded backup/files/$STAMP-wp-content.tar.gz"
                SH
                chmod 750 /usr/local/bin/novatrix-backup

                unit() {   # name description exec-start [user]
                  printf '[Unit]\nDescription=%s\nAfter=network-online.target\nWants=network-online.target\n[Service]\nType=oneshot\nExecStart=%s\nStandardOutput=append:/var/log/novatrix-jobs.log\nStandardError=append:/var/log/novatrix-jobs.log\n' \
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
                OnUnitActiveSec=$SYNC_INTERVAL"
                unit  novatrix-logs "Archive Apache logs to S3 via the uploader role" /usr/local/bin/novatrix-logs
                timer novatrix-logs "Archive Apache logs daily" "OnCalendar=daily
                Persistent=true"
                unit  novatrix-backup "Back up WordPress (database + wp-content) to S3" /usr/local/bin/novatrix-backup
                timer novatrix-backup "Back up WordPress daily" "OnCalendar=*-*-* 00:00:00
                Persistent=true"
                unit  novatrix-wpcron "WordPress scheduled tasks" "/usr/bin/php $WP_ROOT/wp-cron.php" apache
                timer novatrix-wpcron "WordPress scheduled tasks every 5 minutes" "OnBootSec=5min
                OnUnitActiveSec=5min"

                mkdir -p "$WP_ROOT/.novatrix"
                exec 9>"$WP_ROOT/.novatrix/setup.lock"
                flock -w 900 9

                for i in $(seq 1 30); do
                  /usr/local/bin/novatrix-db master -e "SELECT 1" >/dev/null 2>&1 && break
                  echo "waiting for the database ($i/30)"; sleep 10
                done
                APP_PW=$(/usr/local/bin/novatrix-secret "$DB_APP_SECRET")
                bits=${WEB_TIER_CIDR#*/}
                m=$(( (0xffffffff << (32 - bits)) & 0xffffffff ))
                DB_USER_HOST="${WEB_TIER_CIDR%/*}/$(( m >> 24 & 255 )).$(( m >> 16 & 255 )).$(( m >> 8 & 255 )).$(( m & 255 ))"
                /usr/local/bin/novatrix-db master <<SQL
                CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
                CREATE USER IF NOT EXISTS '$DB_APP_USER'@'$DB_USER_HOST' IDENTIFIED BY '$APP_PW';
                ALTER USER '$DB_APP_USER'@'$DB_USER_HOST' IDENTIFIED BY '$APP_PW';
                GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_APP_USER'@'$DB_USER_HOST';
                SQL

                curl -fsSL -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
                chmod 755 /usr/local/bin/wp
                WP=(/usr/bin/php -d memory_limit=512M /usr/local/bin/wp --path="$WP_ROOT" --allow-root)
                [[ -f "$WP_ROOT/wp-includes/version.php" ]] || "${WP[@]}" core download --locale="$WP_LOCALE"
                if [[ ! -f "$WP_ROOT/wp-config.php" ]]; then
                  "${WP[@]}" config create --dbname="$DB_NAME" --dbuser="$DB_APP_USER" --dbpass="$APP_PW" \
                    --dbhost="$DB_HOST:$DB_PORT" --locale="$WP_LOCALE" --skip-check --extra-php <<'PHP'
                if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
                    $_SERVER['HTTPS'] = 'on';
                }
                if (isset($_SERVER['HTTP_HOST'])) {
                    $novatrix_scheme = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ? 'https' : 'http';
                    define('WP_HOME', $novatrix_scheme . '://' . $_SERVER['HTTP_HOST']);
                    define('WP_SITEURL', WP_HOME);
                }
                define('MYSQL_CLIENT_FLAGS', MYSQLI_CLIENT_SSL);   // TLS to RDS (CA in the system trust store)
                define('DISABLE_WP_CRON', true);      // runs from systemd (novatrix-wpcron.timer)
                define('DISALLOW_FILE_EDIT', true);   // no PHP editing from the admin panel
                define('FS_METHOD', 'direct');
                define('WP_AUTO_UPDATE_CORE', 'minor');
                PHP
                fi
                "${WP[@]}" config set DB_PASSWORD "$APP_PW" --quiet
                if ! "${WP[@]}" core is-installed 2>/dev/null; then
                  ADMIN_PW=$(/usr/local/bin/novatrix-secret "$WP_ADMIN_SECRET")
                  "${WP[@]}" core install --url="http://$ALB_DNS" --title="$WP_TITLE" \
                    --admin_user="$WP_ADMIN_USER" --admin_password="$ADMIN_PW" \
                    --admin_email="$WP_ADMIN_EMAIL" --skip-email
                  "${WP[@]}" option update blogdescription "WordPress on RDS and EFS - load balanced and auto scaled, built with CloudFormation"
                  "${WP[@]}" post create --post_type=page --post_status=publish --post_title="About Novatrix" \
                    --post_content="This whole environment - network, load balancer, auto scaled servers, database, storage and permissions - is created from CloudFormation templates in Git."
                fi
                mkdir -p "$WP_ROOT/wp-content/uploads"
                exec 9>&-      # release the setup lock: the next server may continue

                for i in $(seq 1 12); do
                  /usr/local/bin/novatrix-sync && [[ -f /var/www/static/index.html ]] && break
                  sleep 5
                done

                systemctl daemon-reload
                systemctl enable --now php-fpm httpd novatrix-sync.timer novatrix-logs.timer \
                  novatrix-backup.timer novatrix-wpcron.timer
                curl -sf -o /dev/null http://localhost/
                curl -sf -o /dev/null "http://localhost/healthz.php"
                echo "Novatrix WordPress ready"

  # ===========================================================================
  # Auto Scaling group: the web servers, spread over web-a (AZ a) and web-b
  # (AZ b). The group keeps at least AsgMinSize servers running:
  #   - HealthCheckType ELB: a server the load balancer marks unhealthy (or that
  #     EC2 reports broken) is terminated and replaced automatically
  #   - an AZ outage: the group launches the replacements in the other AZ
  #   - load: two target tracking policies below add/remove servers
  # DesiredCapacity is deliberately NOT set: a re-deploy must not reset what
  # the scaling policies have decided.
  #
  # CreationPolicy: the first deploy waits until AsgMinSize servers have
  # reported "WordPress works" (cfn-signal) - "the stack is green" means "the
  # site works".
  # UpdatePolicy: a new launch template version (new AMI, new user data) is
  # rolled out ONE server at a time. A new server is started first, it must
  # signal success, then an old one is terminated (after the ALB has drained
  # it). At least AsgMinSize servers stay in service the whole time; a failing
  # new version stops the rollout and CloudFormation rolls back.
  # ===========================================================================
  WebAsg:
    Type: AWS::AutoScaling::AutoScalingGroup
    # The servers log and read their agent config from the first boot on.
    DependsOn: [WebAccessLogGroup, WebErrorLogGroup, WebPhpLogGroup, WebJobsLogGroup, WebBootLogGroup]
    CreationPolicy:
      ResourceSignal: { Count: !Ref AsgMinSize, Timeout: PT20M }
      AutoScalingCreationPolicy: { MinSuccessfulInstancesPercent: 100 }
    UpdatePolicy:
      AutoScalingRollingUpdate:
        MinInstancesInService: !Ref AsgMinSize
        MaxBatchSize: 1
        PauseTime: PT20M
        WaitOnResourceSignals: true
        SuspendProcesses: [HealthCheck, ReplaceUnhealthy, AZRebalance, AlarmNotification, ScheduledActions]
    Properties:
      AutoScalingGroupName: !Sub "${ProjectName}-web-asg"
      LaunchTemplate:
        LaunchTemplateId: !Ref WebLaunchTemplate
        Version: !GetAtt WebLaunchTemplate.LatestVersionNumber
      MinSize: !Ref AsgMinSize
      MaxSize: !Ref AsgMaxSize
      VPCZoneIdentifier:
        - Fn::ImportValue: !Sub "${ProjectName}-WebSubnetAId"
        - Fn::ImportValue: !Sub "${ProjectName}-WebSubnetBId"
      TargetGroupARNs: [!Ref WebTargetGroup]
      HealthCheckType: ELB
      HealthCheckGracePeriod: 600       # first boot installs packages (+ WordPress): 3-6 min
      DefaultInstanceWarmup: 300        # a new server's metrics count only after 5 min
      MetricsCollection:
        - Granularity: 1Minute          # group metrics in CloudWatch (free)
      Tags:
        - { Key: Name, Value: !Sub "${ProjectName}-web", PropagateAtLaunch: true }
        - { Key: Role, Value: web, PropagateAtLaunch: true }
        - { Key: Project, Value: !Ref ProjectName, PropagateAtLaunch: true }

  # Target tracking = "keep the metric near this value": AWS creates the
  # CloudWatch alarms itself. Two policies: the group scales OUT when EITHER is
  # above its target and IN only when BOTH are below (the safe combination).
  #   CPU      - heavy pages (PHP) on the servers we have
  #   requests - many visitors; ALB metrics are per minute (free), so this one
  #              reacts in ~3 minutes, before the CPU average (5-minute) does
  CpuScalingPolicy:
    Type: AWS::AutoScaling::ScalingPolicy
    Properties:
      AutoScalingGroupName: !Ref WebAsg
      PolicyType: TargetTrackingScaling
      TargetTrackingConfiguration:
        PredefinedMetricSpecification: { PredefinedMetricType: ASGAverageCPUUtilization }
        TargetValue: !Ref CpuTargetPercent

  RequestScalingPolicy:
    Type: AWS::AutoScaling::ScalingPolicy
    DependsOn: HttpListener            # the target group must be attached to the ALB
    Properties:
      AutoScalingGroupName: !Ref WebAsg
      PolicyType: TargetTrackingScaling
      TargetTrackingConfiguration:
        PredefinedMetricSpecification:
          PredefinedMetricType: ALBRequestCountPerTarget
          ResourceLabel: !Sub "${Alb.LoadBalancerFullName}/${WebTargetGroup.TargetGroupFullName}"
        TargetValue: !Ref RequestsPerTargetPerMinute

  # ===========================================================================
  # Bastion: public subnet mgmt-a, bastion security group, NO IAM role.
  # User data installs NOTHING (its security group doesn't even let it reach
  # the internet). It only hardens SSH: forward SSH (port 22) and nothing else,
  # so it can't be used as a tunnel to the database. Not in an Auto Scaling
  # group: it is only needed while someone administers (stop it otherwise).
  # ===========================================================================
  BastionLaunchTemplate:
    Type: AWS::EC2::LaunchTemplate
    Properties:
      LaunchTemplateName: !Sub "${ProjectName}-bastion"
      LaunchTemplateData:
        ImageId: !Ref AmiId
        InstanceType: !Ref InstanceType
        KeyName: !Ref KeyName
        MetadataOptions:
          HttpTokens: required
          HttpEndpoint: enabled
          HttpPutResponseHopLimit: 1
        BlockDeviceMappings:
          - DeviceName: /dev/xvda
            Ebs: { Encrypted: true, VolumeType: gp3, DeleteOnTermination: true }
        CreditSpecification: { CpuCredits: standard }
        UserData:
          Fn::Base64: |
            #!/bin/bash
            set -e
            cat > /etc/ssh/sshd_config.d/10-novatrix.conf <<'SSHD'
            PermitRootLogin no
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            X11Forwarding no
            AllowAgentForwarding no
            MaxAuthTries 3
            LoginGraceTime 30
            ClientAliveInterval 300
            ClientAliveCountMax 2
            AllowTcpForwarding local
            PermitOpen *:22
            SSHD
            # Validate before reloading: a typo must never lock us out of the server.
            if sshd -t; then systemctl reload sshd
            else echo "sshd rejected 10-novatrix.conf - removed it" >&2; rm -f /etc/ssh/sshd_config.d/10-novatrix.conf; fi

  Bastion:
    Type: AWS::EC2::Instance
    Properties:
      LaunchTemplate:
        LaunchTemplateId: !Ref BastionLaunchTemplate
        Version: !GetAtt BastionLaunchTemplate.LatestVersionNumber
      NetworkInterfaces:
        - DeviceIndex: "0"
          AssociatePublicIpAddress: true
          SubnetId:
            Fn::ImportValue: !Sub "${ProjectName}-MgmtSubnetAId"
          GroupSet:
            - Fn::ImportValue: !Sub "${ProjectName}-BastionSgId"
      Tags:
        - { Key: Name, Value: !Sub "${ProjectName}-bastion" }
        - { Key: Role, Value: bastion }
        - { Key: Project, Value: !Ref ProjectName }

# The monitoring layer (6) imports the names its alarms, dashboard and
# site check need.
Outputs:
  AmiId:            { Value: !Ref AmiId }
  AlbDnsName:
    Description: The site's address (no domain yet)
    Value: !GetAtt Alb.DNSName
    Export: { Name: !Sub "${ProjectName}-AlbDnsName" }
  AlbArn:           { Value: !Ref Alb }
  AlbFullName:
    Value: !GetAtt Alb.LoadBalancerFullName
    Export: { Name: !Sub "${ProjectName}-AlbFullName" }
  WebTargetGroupArn: { Value: !Ref WebTargetGroup }
  WebTargetGroupFullName:
    Value: !GetAtt WebTargetGroup.TargetGroupFullName
    Export: { Name: !Sub "${ProjectName}-WebTargetGroupFullName" }
  AsgName:
    Value: !Ref WebAsg
    Export: { Name: !Sub "${ProjectName}-AsgName" }
  WebAgentConfigName: { Value: !Ref WebAgentConfig }
  WebAccessLogGroupName: { Value: !Ref WebAccessLogGroup }
  WebLaunchTemplateId:          { Value: !Ref WebLaunchTemplate }
  WebLaunchTemplateVersion:     { Value: !GetAtt WebLaunchTemplate.LatestVersionNumber }
  BastionLaunchTemplateVersion: { Value: !GetAtt BastionLaunchTemplate.LatestVersionNumber }
  BastionId:        { Value: !Ref Bastion }
  # Public IPs change when an instance is stopped/started - the scripts always
  # ask EC2 for the current one. This shows the address at deploy time.
  BastionPrivateIp: { Value: !GetAtt Bastion.PrivateIp }
  HttpsEnabled:     { Value: !If [HasCertificate, "yes", "no"] }
```

### *__V48_06-monitoring.yaml__*

```yaml
AWSTemplateFormatVersion: "2010-09-09"
Description: >
  Novatrix V48 - layer 6 of 6: monitoring. Alarm mails (SNS), CloudWatch
  alarms on CPU, memory, disk, the load balancer, the database, EFS and the
  logs, a serverless site check (Lambda + EventBridge) that asks the website
  like a visitor, metric filters that turn log lines into alarms, saved Logs
  Insights queries and a dashboard. Imports from layers 2, 3 and 5.

# =============================================================================
# Who measures what
#   EC2 (free, from the outside)   CPU per Auto Scaling group
#   CloudWatch agent (layer 5)     memory + root disk (only visible INSIDE the OS),
#                                  five log files per server -> /<project>/web/*
#   ALB, RDS, EFS, Lambda (free)   requests, 5xx, healthy servers, DB CPU/memory/
#                                  storage, EFS burst credits, Lambda errors
#   site check (this layer)        the visitor's view: is the site up, how fast?
#   metric filters (this layer)    "PHP Fatal" and "novatrix-backup FAILED" in the logs
#
# Two kinds of alarm (name tells which):
#   <project>-critical-*  the site is down or about to be - mail on ALARM AND on OK
#                         (you also learn that it's over without logging in)
#   <project>-warning-*   needs a look, not a night call - mail on ALARM only
# Every alarm mail goes to ONE SNS topic; its e-mail subscription must be
# confirmed once (link in the first mail from AWS).
# =============================================================================

Metadata:
  AWS::CloudFormation::Interface:
    ParameterGroups:
      - Label: { default: General }
        Parameters: [ProjectName, AlarmEmail, HttpsEnabled, LogRetentionDays]
      - Label: { default: Site check }
        Parameters: [SiteCheckSchedule, SlowSiteMs]
      - Label: { default: Thresholds }
        Parameters: [WebCpuAlarmPercent, WebMemoryAlarmPercent, WebDiskAlarmPercent, AsgMaxSize]

Parameters:
  ProjectName:
    Type: String
    Default: novatrix
    AllowedPattern: '^[a-z][a-z0-9-]{1,20}$'
  AlarmEmail:
    Type: String
    AllowedPattern: '^[^@\s]+@[^@\s]+\.[^@\s]+$'
    ConstraintDescription: An e-mail address
    Description: Receives every alarm (and OK for the critical ones)
  HttpsEnabled:
    Type: String
    Default: "no"
    AllowedValues: ["yes", "no"]
    Description: yes = the site check also asks over HTTPS (the compute layer's HttpsEnabled)
  LogRetentionDays:
    Type: Number
    Default: 14
    AllowedValues: [1, 3, 5, 7, 14, 30, 60, 90]
  SiteCheckSchedule:
    Type: String
    Default: rate(5 minutes)
    Description: How often the site check runs (EventBridge schedule expression)
  SlowSiteMs:
    Type: Number
    Default: 3000
    Description: Warning when the start page is slower than this (average over 15 min)
  WebCpuAlarmPercent:
    Type: Number
    Default: 80
    Description: Above the scaling target (50) on purpose - alarm = scaling is NOT keeping up
  WebMemoryAlarmPercent:
    Type: Number
    Default: 85
  WebDiskAlarmPercent:
    Type: Number
    Default: 80
  AsgMaxSize:
    Type: Number
    Default: 4
    Description: Same as the compute layer's - warning when the group sits at its cost ceiling

Conditions:
  Https: !Equals [!Ref HttpsEnabled, "yes"]

Resources:
  # ===========================================================================
  # Notification: one topic, e-mail. Not encrypted with a KMS key on purpose:
  # CloudWatch alarms cannot publish to a topic encrypted with the AWS managed
  # key aws/sns (a customer managed key costs 1 USD/month).
  # ===========================================================================
  AlarmTopic:
    Type: AWS::SNS::Topic
    Properties:
      TopicName: !Sub "${ProjectName}-alarms"
      DisplayName: Novatrix
      Subscription:
        - { Protocol: email, Endpoint: !Ref AlarmEmail }
      Tags:
        - { Key: Project, Value: !Ref ProjectName }

  # Only CloudWatch (in THIS account) and the account itself may publish.
  AlarmTopicPolicy:
    Type: AWS::SNS::TopicPolicy
    Properties:
      Topics: [!Ref AlarmTopic]
      PolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Sid: CloudWatchAlarmsFromThisAccount
            Effect: Allow
            Principal: { Service: cloudwatch.amazonaws.com }
            Action: sns:Publish
            Resource: !Ref AlarmTopic
            Condition: { StringEquals: { "aws:SourceAccount": !Ref AWS::AccountId } }
          - Sid: AccountOwner
            Effect: Allow
            Principal: { AWS: !Sub "arn:aws:iam::${AWS::AccountId}:root" }
            Action: [sns:Publish, sns:GetTopicAttributes, sns:Subscribe, sns:ListSubscriptionsByTopic]
            Resource: !Ref AlarmTopic

  # ===========================================================================
  # Site check - the serverless part. A Lambda that EventBridge starts every
  # 5 minutes. It runs OUTSIDE the VPC on purpose: it sees exactly what a
  # visitor sees (DNS, load balancer, TLS, WordPress, EFS, database, S3
  # content). Everything inside can be "green" while the site is unreachable
  # - this check notices. ~8,640 runs/month: well inside Lambda's free tier
  # (CloudWatch Synthetics would cost ~10 USD/month for the same).
  # Source: lambda/site-check.py (identical, the deploy script checks it).
  # ===========================================================================
  SiteCheckLogGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: !Sub "/aws/lambda/${ProjectName}-site-check"
      RetentionInDays: !Ref LogRetentionDays
      Tags:
        - { Key: Project, Value: !Ref ProjectName }

  SiteCheckFunction:
    Type: AWS::Lambda::Function
    DependsOn: SiteCheckLogGroup
    Properties:
      FunctionName: !Sub "${ProjectName}-site-check"
      Description: Asks the website like a visitor, reports Available + ResponseTimeMs to CloudWatch
      Runtime: python3.12
      Handler: index.lambda_handler
      Role:
        Fn::ImportValue: !Sub "${ProjectName}-SiteCheckRoleArn"
      Timeout: 60
      MemorySize: 128
      Environment:
        Variables:
          SITE_NAME: !Ref ProjectName
          SITE_URL: !Sub
            - "http://${Dns}"
            - Dns: { "Fn::ImportValue": !Sub "${ProjectName}-AlbDnsName" }
          HTTPS_URL: !If
            - Https
            - !Sub
              - "https://${Dns}"
              - Dns: { "Fn::ImportValue": !Sub "${ProjectName}-AlbDnsName" }
            - ""
          # path|text that must be in the answer: WordPress (start page + login,
          # database and EFS), the health check, the static content from S3
          CHECKS: "/|wp-content,/wp-login.php|user_login,/healthz.php|ok,/static/|Static content"
      Tags:
        - { Key: Project, Value: !Ref ProjectName }
      Code:
        ZipFile: |
          """novatrix-site-check: asks the site like a visitor (from OUTSIDE the VPC).

          Runs every 5 minutes (EventBridge). Each check fetches one page through the
          load balancer and demands HTTP 200 AND a text that proves the RIGHT content
          answered (not e.g. an error page). Two metrics to CloudWatch, namespace
          Novatrix/SiteCheck, dimension Site:
            Available       1 = every check passed, 0 = at least one failed
            ResponseTimeMs  the start page
          The alarms in the monitoring layer watch them and mail via SNS. One JSON line
          per check goes to the log -> searchable with Logs Insights.

          The deployed code is inline in templates/V48_06-monitoring.yaml (no zip, no
          build step); the deploy script refuses to run if the two differ.
          """
          import json
          import os
          import ssl
          import time
          import urllib.error
          import urllib.request

          import boto3

          cloudwatch = boto3.client("cloudwatch")
          # The ALB's certificate is self-signed (no domain yet): check that HTTPS
          # answers with the site, not who signed the certificate.
          NO_VERIFY = ssl._create_unverified_context()


          def check(url, must_contain):
              start = time.time()
              try:
                  request = urllib.request.Request(url, headers={"User-Agent": "novatrix-site-check"})
                  with urllib.request.urlopen(request, timeout=10, context=NO_VERIFY) as answer:
                      status = answer.status
                      body = answer.read(300000).decode("utf-8", "replace")
              except urllib.error.HTTPError as error:
                  status, body = error.code, ""
              except Exception as error:
                  status, body = 0, repr(error)
              ok = int(status == 200 and must_contain in body)
              ms = round((time.time() - start) * 1000)
              print(json.dumps({"url": url, "status": status, "ok": ok, "ms": ms,
                                "error": "" if ok or status else body[:200]}))
              return ok, ms


          def lambda_handler(event, context):
              site = os.environ["SITE_URL"]
              # CHECKS = "path|text,path|text,..." (set in the template)
              checks = [c.split("|", 1) for c in os.environ["CHECKS"].split(",")]
              targets = [(site + path, text) for path, text in checks]
              if os.environ.get("HTTPS_URL"):
                  targets.append((os.environ["HTTPS_URL"] + "/", checks[0][1]))
              results = [check(url, text) for url, text in targets]
              available = min(ok for ok, _ in results)
              ms = results[0][1]
              dims = [{"Name": "Site", "Value": os.environ["SITE_NAME"]}]
              cloudwatch.put_metric_data(Namespace="Novatrix/SiteCheck", MetricData=[
                  {"MetricName": "Available", "Dimensions": dims, "Value": available, "Unit": "Count"},
                  {"MetricName": "ResponseTimeMs", "Dimensions": dims, "Value": ms, "Unit": "Milliseconds"},
              ])
              print(json.dumps({"summary": True, "available": available, "passed": sum(ok for ok, _ in results),
                                "checks": len(results), "ms": ms}))
              return {"available": available, "passed": sum(ok for ok, _ in results),
                      "checks": len(results), "ms": ms}

  SiteCheckRule:
    Type: AWS::Events::Rule
    Properties:
      Name: !Sub "${ProjectName}-site-check"
      Description: Starts the site check
      ScheduleExpression: !Ref SiteCheckSchedule
      State: ENABLED
      Targets:
        - { Id: site-check, Arn: !GetAtt SiteCheckFunction.Arn }

  SiteCheckPermission:
    Type: AWS::Lambda::Permission
    Properties:
      FunctionName: !Ref SiteCheckFunction
      Action: lambda:InvokeFunction
      Principal: events.amazonaws.com
      SourceArn: !GetAtt SiteCheckRule.Arn

  # ===========================================================================
  # Metric filters: log lines -> numbers -> alarms. The log groups belong to
  # the compute layer; a metric is only stored when a line matches (no cost
  # while all is well).
  # ===========================================================================
  PhpFatalFilter:
    Type: AWS::Logs::MetricFilter
    Properties:
      LogGroupName: !Sub "/${ProjectName}/web/php"
      FilterPattern: '"PHP Fatal"'
      MetricTransformations:
        - { MetricNamespace: Novatrix/Logs, MetricName: PhpFatalErrors, MetricValue: "1", Unit: Count }

  BackupFailedFilter:
    Type: AWS::Logs::MetricFilter
    Properties:
      LogGroupName: !Sub "/${ProjectName}/web/jobs"
      FilterPattern: '"novatrix-backup FAILED"'
      MetricTransformations:
        - { MetricNamespace: Novatrix/Logs, MetricName: BackupFailures, MetricValue: "1", Unit: Count }

  # ===========================================================================
  # CRITICAL alarms - mail on ALARM and on OK
  # ===========================================================================
  # Missing data = breaching: if the check stops reporting, we don't know
  # that the site is up. 2 of 2 periods: one lost request is not an outage.
  SiteDownAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub "${ProjectName}-critical-site-down"
      AlarmDescription: >-
        The site check (a visitor's view from outside) failed twice in a row - or stopped
        reporting. Which page failed: Logs Insights query "6 site-check failures" or
        log group /aws/lambda/novatrix-site-check.
      Namespace: Novatrix/SiteCheck
      MetricName: Available
      Dimensions: [{ Name: Site, Value: !Ref ProjectName }]
      Statistic: Minimum
      Period: 300
      EvaluationPeriods: 2
      DatapointsToAlarm: 2
      Threshold: 1
      ComparisonOperator: LessThanThreshold
      TreatMissingData: breaching
      AlarmActions: [!Ref AlarmTopic]
      OKActions: [!Ref AlarmTopic]

  NoHealthyServersAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub "${ProjectName}-critical-no-healthy-servers"
      AlarmDescription: >-
        The load balancer has NO healthy web server for 2 minutes - every visitor gets 503.
        Check the target group's health and /novatrix/web/boot + /novatrix/web/error.
      Namespace: AWS/ApplicationELB
      MetricName: HealthyHostCount
      Dimensions:
        - { Name: LoadBalancer, Value: { "Fn::ImportValue": !Sub "${ProjectName}-AlbFullName" } }
        - { Name: TargetGroup, Value: { "Fn::ImportValue": !Sub "${ProjectName}-WebTargetGroupFullName" } }
      Statistic: Minimum
      Period: 60
      EvaluationPeriods: 2
      Threshold: 1
      ComparisonOperator: LessThanThreshold
      TreatMissingData: breaching
      AlarmActions: [!Ref AlarmTopic]
      OKActions: [!Ref AlarmTopic]

  # 5xx from the servers (PHP/database errors) AND from the ALB itself (502/503:
  # no server answered). FILL: a metric with no 5xx at all has no data points.
  Site5xxAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub "${ProjectName}-critical-5xx-errors"
      AlarmDescription: >-
        10 or more server errors (HTTP 5xx) in 5 minutes. Which pages and which server:
        Logs Insights query "1 5xx requests".
      Metrics:
        - Id: errors
          Label: 5xx (servers + load balancer)
          Expression: FILL(target, 0) + FILL(elb, 0)
          ReturnData: true
        - Id: target
          ReturnData: false
          MetricStat:
            Metric:
              Namespace: AWS/ApplicationELB
              MetricName: HTTPCode_Target_5XX_Count
              Dimensions: [{ Name: LoadBalancer, Value: { "Fn::ImportValue": !Sub "${ProjectName}-AlbFullName" } }]
            Period: 300
            Stat: Sum
        - Id: elb
          ReturnData: false
          MetricStat:
            Metric:
              Namespace: AWS/ApplicationELB
              MetricName: HTTPCode_ELB_5XX_Count
              Dimensions: [{ Name: LoadBalancer, Value: { "Fn::ImportValue": !Sub "${ProjectName}-AlbFullName" } }]
            Period: 300
            Stat: Sum
      EvaluationPeriods: 1
      Threshold: 10
      ComparisonOperator: GreaterThanOrEqualToThreshold
      TreatMissingData: notBreaching
      AlarmActions: [!Ref AlarmTopic]
      OKActions: [!Ref AlarmTopic]

  # Above the scaling target (50 %): target tracking should keep CPU near 50.
  # 80 % for 15 minutes means it can't - the group is at max, or new servers
  # don't become healthy.
  WebCpuAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub "${ProjectName}-critical-web-cpu"
      AlarmDescription: >-
        Average CPU of the web servers above the threshold for 15 minutes - scaling is not
        keeping up (at max? new servers failing?). See the Auto Scaling group's activity.
      Namespace: AWS/EC2
      MetricName: CPUUtilization
      Dimensions: [{ Name: AutoScalingGroupName, Value: { "Fn::ImportValue": !Sub "${ProjectName}-AsgName" } }]
      Statistic: Average
      Period: 300
      EvaluationPeriods: 3
      Threshold: !Ref WebCpuAlarmPercent
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching
      AlarmActions: [!Ref AlarmTopic]
      OKActions: [!Ref AlarmTopic]

  # Maximum = the WORST server: one server out of memory is enough to fail
  # requests. Missing data = breaching: no memory figures = the CloudWatch
  # agent has stopped on every server.
  WebMemoryAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub "${ProjectName}-critical-web-memory"
      AlarmDescription: >-
        A web server uses more memory than the threshold (10 minutes) - or the CloudWatch
        agent has stopped reporting. t3.micro has 1 GiB: PHP-FPM workers or a plugin.
      Namespace: CWAgent
      MetricName: mem_used_percent
      Dimensions: [{ Name: AutoScalingGroupName, Value: { "Fn::ImportValue": !Sub "${ProjectName}-AsgName" } }]
      Statistic: Maximum
      Period: 300
      EvaluationPeriods: 2
      Threshold: !Ref WebMemoryAlarmPercent
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: breaching
      AlarmActions: [!Ref AlarmTopic]
      OKActions: [!Ref AlarmTopic]

  # The root disk (8 GB gp3): logs and /tmp (backup dumps) live here. WordPress
  # itself is on EFS, which can't fill up.
  WebDiskAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub "${ProjectName}-critical-web-disk"
      AlarmDescription: >-
        A web server's root disk is fuller than the threshold. Usually logs or a failed
        backup in /tmp. The server can be replaced: terminate it in the Auto Scaling group.
      Namespace: CWAgent
      MetricName: disk_used_percent
      Dimensions:
        - { Name: AutoScalingGroupName, Value: { "Fn::ImportValue": !Sub "${ProjectName}-AsgName" } }
        - { Name: path, Value: / }
        - { Name: fstype, Value: xfs }
      Statistic: Maximum
      Period: 300
      EvaluationPeriods: 2
      Threshold: !Ref WebDiskAlarmPercent
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching
      AlarmActions: [!Ref AlarmTopic]
      OKActions: [!Ref AlarmTopic]

  # 2 GiB = 10 % of 20 GiB. A full database stops WordPress completely.
  DbStorageAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub "${ProjectName}-critical-db-storage"
      AlarmDescription: >-
        Less than 2 GiB free in the database (20 GiB). Find what grows (revisions, spam,
        logs tables) before WordPress stops writing.
      Namespace: AWS/RDS
      MetricName: FreeStorageSpace
      Dimensions: [{ Name: DBInstanceIdentifier, Value: !Sub "${ProjectName}-db" }]
      Statistic: Minimum
      Period: 300
      EvaluationPeriods: 1
      Threshold: 2147483648
      ComparisonOperator: LessThanThreshold
      TreatMissingData: notBreaching
      AlarmActions: [!Ref AlarmTopic]
      OKActions: [!Ref AlarmTopic]

  # ===========================================================================
  # WARNING alarms - mail on ALARM only
  # ===========================================================================
  DbCpuAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub "${ProjectName}-warning-db-cpu"
      AlarmDescription: >-
        Database CPU above 80 % for 15 minutes. db.t4g.micro is small: slow queries
        (Query Monitor plugin) or more web servers than the database can serve.
      Namespace: AWS/RDS
      MetricName: CPUUtilization
      Dimensions: [{ Name: DBInstanceIdentifier, Value: !Sub "${ProjectName}-db" }]
      Statistic: Average
      Period: 300
      EvaluationPeriods: 3
      Threshold: 80
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching
      AlarmActions: [!Ref AlarmTopic]

  DbMemoryAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub "${ProjectName}-warning-db-memory"
      AlarmDescription: Less than 100 MiB free memory in the database for 15 minutes (1 GiB in total).
      Namespace: AWS/RDS
      MetricName: FreeableMemory
      Dimensions: [{ Name: DBInstanceIdentifier, Value: !Sub "${ProjectName}-db" }]
      Statistic: Minimum
      Period: 300
      EvaluationPeriods: 3
      Threshold: 104857600
      ComparisonOperator: LessThanThreshold
      TreatMissingData: notBreaching
      AlarmActions: [!Ref AlarmTopic]

  # Degraded, not down: the other server(s) still serve. The Auto Scaling
  # group replaces the sick one by itself - this tells you it happened.
  UnhealthyServerAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub "${ProjectName}-warning-unhealthy-server"
      AlarmDescription: >-
        A web server has failed the load balancer's health check for 3 minutes. The Auto
        Scaling group replaces it automatically - check why in /novatrix/web/error.
      Namespace: AWS/ApplicationELB
      MetricName: UnHealthyHostCount
      Dimensions:
        - { Name: LoadBalancer, Value: { "Fn::ImportValue": !Sub "${ProjectName}-AlbFullName" } }
        - { Name: TargetGroup, Value: { "Fn::ImportValue": !Sub "${ProjectName}-WebTargetGroupFullName" } }
      Statistic: Maximum
      Period: 60
      EvaluationPeriods: 3
      Threshold: 1
      ComparisonOperator: GreaterThanOrEqualToThreshold
      TreatMissingData: notBreaching
      AlarmActions: [!Ref AlarmTopic]

  # The group's own metric (MetricsCollection in layer 5).
  AsgAtMaxAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub "${ProjectName}-warning-at-max-servers"
      AlarmDescription: >-
        The Auto Scaling group has run at its maximum (the cost ceiling) for 15 minutes.
        More load can't be met by more servers - raise ASG_MAX (cost!) or find the cause.
      Namespace: AWS/AutoScaling
      MetricName: GroupInServiceInstances
      Dimensions: [{ Name: AutoScalingGroupName, Value: { "Fn::ImportValue": !Sub "${ProjectName}-AsgName" } }]
      Statistic: Minimum
      Period: 300
      EvaluationPeriods: 3
      Threshold: !Ref AsgMaxSize
      ComparisonOperator: GreaterThanOrEqualToThreshold
      TreatMissingData: notBreaching
      AlarmActions: [!Ref AlarmTopic]

  # Bursting throughput: a small file system earns little credit. Out of
  # credits = every page load on every server gets slow at once.
  EfsCreditsAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub "${ProjectName}-warning-efs-burst-credits"
      AlarmDescription: >-
        EFS burst credits below 100 GB - when they run out, the shared WordPress files (every
        server) are throttled to the baseline. Look for a job reading/writing a lot.
      Namespace: AWS/EFS
      MetricName: BurstCreditBalance
      Dimensions: [{ Name: FileSystemId, Value: { "Fn::ImportValue": !Sub "${ProjectName}-FileSystemId" } }]
      Statistic: Minimum
      Period: 300
      EvaluationPeriods: 1
      Threshold: 100000000000
      ComparisonOperator: LessThanThreshold
      TreatMissingData: notBreaching
      AlarmActions: [!Ref AlarmTopic]

  PhpFatalAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub "${ProjectName}-warning-php-fatal"
      AlarmDescription: >-
        "PHP Fatal" in the PHP log of a web server (metric filter). Which server and what:
        Logs Insights query "4 errors on all servers".
      Namespace: Novatrix/Logs
      MetricName: PhpFatalErrors
      Statistic: Sum
      Period: 300
      EvaluationPeriods: 1
      Threshold: 1
      ComparisonOperator: GreaterThanOrEqualToThreshold
      TreatMissingData: notBreaching
      AlarmActions: [!Ref AlarmTopic]

  BackupFailedAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub "${ProjectName}-warning-backup-failed"
      AlarmDescription: >-
        The nightly backup (database dump + wp-content to S3) failed - see /novatrix/web/jobs.
        RDS's own automated backup still exists (1 day).
      Namespace: Novatrix/Logs
      MetricName: BackupFailures
      Statistic: Sum
      Period: 300
      EvaluationPeriods: 1
      Threshold: 1
      ComparisonOperator: GreaterThanOrEqualToThreshold
      TreatMissingData: notBreaching
      AlarmActions: [!Ref AlarmTopic]

  # The serverless parts: the publisher (drafts -> web/) and the site check
  # itself (who watches the watcher?).
  LambdaErrorsAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub "${ProjectName}-warning-lambda-errors"
      AlarmDescription: >-
        The publisher or the site check Lambda ended with an error. Their logs:
        /aws/lambda/novatrix-publisher and /aws/lambda/novatrix-site-check.
      Metrics:
        - Id: errors
          Label: Lambda errors (publisher + site check)
          Expression: FILL(publisher, 0) + FILL(sitecheck, 0)
          ReturnData: true
        - Id: publisher
          ReturnData: false
          MetricStat:
            Metric:
              Namespace: AWS/Lambda
              MetricName: Errors
              Dimensions: [{ Name: FunctionName, Value: !Sub "${ProjectName}-publisher" }]
            Period: 300
            Stat: Sum
        - Id: sitecheck
          ReturnData: false
          MetricStat:
            Metric:
              Namespace: AWS/Lambda
              MetricName: Errors
              Dimensions: [{ Name: FunctionName, Value: !Ref SiteCheckFunction }]
            Period: 300
            Stat: Sum
      EvaluationPeriods: 1
      Threshold: 1
      ComparisonOperator: GreaterThanOrEqualToThreshold
      TreatMissingData: notBreaching
      AlarmActions: [!Ref AlarmTopic]

  SlowSiteAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub "${ProjectName}-warning-slow-site"
      AlarmDescription: >-
        The start page has been slower than the threshold for 15 minutes (as a visitor sees it).
        Slowest pages: Logs Insights query "2 slowest pages".
      Namespace: Novatrix/SiteCheck
      MetricName: ResponseTimeMs
      Dimensions: [{ Name: Site, Value: !Ref ProjectName }]
      Statistic: Average
      Period: 300
      EvaluationPeriods: 3
      Threshold: !Ref SlowSiteMs
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching
      AlarmActions: [!Ref AlarmTopic]

  # ===========================================================================
  # Central logging - follow-up: saved Logs Insights queries (CloudWatch ->
  # Logs Insights -> Saved queries). They search ALL servers at once, also
  # servers that no longer exist. The access log is JSON (layer 5), so the
  # fields (ip, path, status, ms ...) are found without parsing.
  # ===========================================================================
  Query5xx:
    Type: AWS::Logs::QueryDefinition
    Properties:
      Name: !Sub "${ProjectName}/1 5xx requests"
      LogGroupNames: [!Sub "/${ProjectName}/web/access"]
      QueryString: |
        fields @timestamp, @logStream as server, ip, method, path, status, ms
        | filter status >= 500
        | sort @timestamp desc
        | limit 100
  QuerySlowest:
    Type: AWS::Logs::QueryDefinition
    Properties:
      Name: !Sub "${ProjectName}/2 slowest pages"
      LogGroupNames: [!Sub "/${ProjectName}/web/access"]
      QueryString: |
        stats count(*) as requests, avg(ms) as avg_ms, max(ms) as max_ms by path
        | sort avg_ms desc
        | limit 20
  QueryVisitors:
    Type: AWS::Logs::QueryDefinition
    Properties:
      Name: !Sub "${ProjectName}/3 top visitors"
      LogGroupNames: [!Sub "/${ProjectName}/web/access"]
      QueryString: |
        stats count(*) as requests by ip, ua
        | sort requests desc
        | limit 20
  QueryErrors:
    Type: AWS::Logs::QueryDefinition
    Properties:
      Name: !Sub "${ProjectName}/4 errors on all servers"
      LogGroupNames:
        - !Sub "/${ProjectName}/web/error"
        - !Sub "/${ProjectName}/web/php"
        - !Sub "/${ProjectName}/web/jobs"
        - !Sub "/${ProjectName}/web/boot"
        - !Sub "/aws/rds/instance/${ProjectName}-db/error"
      QueryString: |
        fields @timestamp, @log, @logStream, @message
        | filter @message like /(?i)(error|fatal|failed|denied)/
        | sort @timestamp desc
        | limit 100
  QueryPerServer:
    Type: AWS::Logs::QueryDefinition
    Properties:
      Name: !Sub "${ProjectName}/5 requests per server"
      LogGroupNames: [!Sub "/${ProjectName}/web/access"]
      QueryString: |
        stats count(*) as requests by @logStream, bin(5m)
  QuerySiteCheck:
    Type: AWS::Logs::QueryDefinition
    Properties:
      Name: !Sub "${ProjectName}/6 site-check failures"
      LogGroupNames: [!Ref SiteCheckLogGroup]
      QueryString: |
        fields @timestamp, url, status, ms, error
        | filter ok = 0
        | sort @timestamp desc
        | limit 50

  # ===========================================================================
  # Dashboard: the whole solution on one page (3 dashboards are free).
  # ===========================================================================
  Dashboard:
    Type: AWS::CloudWatch::Dashboard
    Properties:
      DashboardName: !Ref ProjectName
      DashboardBody: !Sub
        - |
          {
            "widgets": [
              { "type": "alarm", "x": 0, "y": 0, "width": 24, "height": 4,
                "properties": { "title": "Alarms (critical = mail on ALARM and OK)", "alarms": [
                  "${SiteDownAlarm.Arn}", "${NoHealthyServersAlarm.Arn}", "${Site5xxAlarm.Arn}",
                  "${WebCpuAlarm.Arn}", "${WebMemoryAlarm.Arn}", "${WebDiskAlarm.Arn}", "${DbStorageAlarm.Arn}",
                  "${DbCpuAlarm.Arn}", "${DbMemoryAlarm.Arn}", "${UnhealthyServerAlarm.Arn}", "${AsgAtMaxAlarm.Arn}",
                  "${EfsCreditsAlarm.Arn}", "${PhpFatalAlarm.Arn}", "${BackupFailedAlarm.Arn}",
                  "${LambdaErrorsAlarm.Arn}", "${SlowSiteAlarm.Arn}" ] } },
              { "type": "metric", "x": 0, "y": 4, "width": 8, "height": 6,
                "properties": { "title": "Site check (visitor's view)", "region": "${AWS::Region}", "period": 300,
                  "metrics": [
                    [ "Novatrix/SiteCheck", "Available", "Site", "${ProjectName}", { "stat": "Minimum" } ],
                    [ ".", "ResponseTimeMs", ".", ".", { "stat": "Average", "yAxis": "right" } ] ] } },
              { "type": "metric", "x": 8, "y": 4, "width": 8, "height": 6,
                "properties": { "title": "Load balancer", "region": "${AWS::Region}", "period": 60, "stat": "Sum",
                  "metrics": [
                    [ "AWS/ApplicationELB", "RequestCount", "LoadBalancer", "${Alb}" ],
                    [ ".", "HTTPCode_Target_5XX_Count", ".", "." ],
                    [ ".", "HTTPCode_ELB_5XX_Count", ".", "." ],
                    [ ".", "HealthyHostCount", "TargetGroup", "${Tg}", "LoadBalancer", "${Alb}", { "stat": "Minimum", "yAxis": "right" } ] ] } },
              { "type": "metric", "x": 16, "y": 4, "width": 8, "height": 6,
                "properties": { "title": "Web servers: CPU, memory, disk (%)", "region": "${AWS::Region}", "period": 300,
                  "yAxis": { "left": { "min": 0, "max": 100 } },
                  "metrics": [
                    [ "AWS/EC2", "CPUUtilization", "AutoScalingGroupName", "${Asg}", { "stat": "Average", "label": "CPU (average)" } ],
                    [ "CWAgent", "mem_used_percent", "AutoScalingGroupName", "${Asg}", { "stat": "Maximum", "label": "memory (worst server)" } ],
                    [ "CWAgent", "disk_used_percent", "AutoScalingGroupName", "${Asg}", "path", "/", "fstype", "xfs", { "stat": "Maximum", "label": "disk / (worst server)" } ] ] } },
              { "type": "metric", "x": 0, "y": 10, "width": 8, "height": 6,
                "properties": { "title": "Auto Scaling group: servers", "region": "${AWS::Region}", "period": 60, "stat": "Average",
                  "metrics": [
                    [ "AWS/AutoScaling", "GroupDesiredCapacity", "AutoScalingGroupName", "${Asg}" ],
                    [ ".", "GroupInServiceInstances", ".", "." ] ] } },
              { "type": "metric", "x": 8, "y": 10, "width": 8, "height": 6,
                "properties": { "title": "Database (RDS)", "region": "${AWS::Region}", "period": 300,
                  "metrics": [
                    [ "AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", "${ProjectName}-db", { "stat": "Average" } ],
                    [ ".", "FreeStorageSpace", ".", ".", { "stat": "Minimum", "yAxis": "right" } ],
                    [ ".", "FreeableMemory", ".", ".", { "stat": "Minimum", "yAxis": "right" } ] ] } },
              { "type": "metric", "x": 16, "y": 10, "width": 8, "height": 6,
                "properties": { "title": "Shared storage (EFS) + Lambda", "region": "${AWS::Region}", "period": 300,
                  "metrics": [
                    [ "AWS/EFS", "BurstCreditBalance", "FileSystemId", "${Fs}", { "stat": "Minimum", "yAxis": "right" } ],
                    [ "AWS/Lambda", "Errors", "FunctionName", "${ProjectName}-publisher", { "stat": "Sum" } ],
                    [ ".", ".", ".", "${ProjectName}-site-check", { "stat": "Sum" } ] ] } },
              { "type": "log", "x": 0, "y": 16, "width": 24, "height": 6,
                "properties": { "title": "Requests per status code and server (last hour)", "region": "${AWS::Region}", "view": "table",
                  "query": "SOURCE '/${ProjectName}/web/access' | stats count(*) as requests by status, @logStream | sort requests desc" } }
            ]
          }
        - Alb: { "Fn::ImportValue": !Sub "${ProjectName}-AlbFullName" }
          Tg:  { "Fn::ImportValue": !Sub "${ProjectName}-WebTargetGroupFullName" }
          Asg: { "Fn::ImportValue": !Sub "${ProjectName}-AsgName" }
          Fs:  { "Fn::ImportValue": !Sub "${ProjectName}-FileSystemId" }

Outputs:
  AlarmTopicArn:
    Value: !Ref AlarmTopic
  SiteCheckFunctionName:
    Value: !Ref SiteCheckFunction
  SiteCheckLogGroupName:
    Value: !Ref SiteCheckLogGroup
  DashboardName:
    Value: !Ref Dashboard
  SiteDownAlarmName:
    Value: !Ref SiteDownAlarm
  PhpFatalAlarmName:
    Value: !Ref PhpFatalAlarm
```

### *__site-check.py__*

```py
"""novatrix-site-check: asks the site like a visitor (from OUTSIDE the VPC).

Runs every 5 minutes (EventBridge). Each check fetches one page through the
load balancer and demands HTTP 200 AND a text that proves the RIGHT content
answered (not e.g. an error page). Two metrics to CloudWatch, namespace
Novatrix/SiteCheck, dimension Site:
  Available       1 = every check passed, 0 = at least one failed
  ResponseTimeMs  the start page
The alarms in the monitoring layer watch them and mail via SNS. One JSON line
per check goes to the log -> searchable with Logs Insights.

The deployed code is inline in templates/V48_06-monitoring.yaml (no zip, no
build step); the deploy script refuses to run if the two differ.
"""
import json
import os
import ssl
import time
import urllib.error
import urllib.request

import boto3

cloudwatch = boto3.client("cloudwatch")
# The ALB's certificate is self-signed (no domain yet): check that HTTPS
# answers with the site, not who signed the certificate.
NO_VERIFY = ssl._create_unverified_context()


def check(url, must_contain):
    start = time.time()
    try:
        request = urllib.request.Request(url, headers={"User-Agent": "novatrix-site-check"})
        with urllib.request.urlopen(request, timeout=10, context=NO_VERIFY) as answer:
            status = answer.status
            body = answer.read(300000).decode("utf-8", "replace")
    except urllib.error.HTTPError as error:
        status, body = error.code, ""
    except Exception as error:
        status, body = 0, repr(error)
    ok = int(status == 200 and must_contain in body)
    ms = round((time.time() - start) * 1000)
    print(json.dumps({"url": url, "status": status, "ok": ok, "ms": ms,
                      "error": "" if ok or status else body[:200]}))
    return ok, ms


def lambda_handler(event, context):
    site = os.environ["SITE_URL"]
    # CHECKS = "path|text,path|text,..." (set in the template)
    checks = [c.split("|", 1) for c in os.environ["CHECKS"].split(",")]
    targets = [(site + path, text) for path, text in checks]
    if os.environ.get("HTTPS_URL"):
        targets.append((os.environ["HTTPS_URL"] + "/", checks[0][1]))
    results = [check(url, text) for url, text in targets]
    available = min(ok for ok, _ in results)
    ms = results[0][1]
    dims = [{"Name": "Site", "Value": os.environ["SITE_NAME"]}]
    cloudwatch.put_metric_data(Namespace="Novatrix/SiteCheck", MetricData=[
        {"MetricName": "Available", "Dimensions": dims, "Value": available, "Unit": "Count"},
        {"MetricName": "ResponseTimeMs", "Dimensions": dims, "Value": ms, "Unit": "Milliseconds"},
    ])
    print(json.dumps({"summary": True, "available": available, "passed": sum(ok for ok, _ in results),
                      "checks": len(results), "ms": ms}))
    return {"available": available, "passed": sum(ok for ok, _ in results),
            "checks": len(results), "ms": ms}
```

### *__V48_novatrix.sh__*

```bash
#!/usr/bin/env bash
# =============================================================================
# Novatrix V48 - the WHOLE stack from code: deploys the six CloudFormation
# templates in templates/ in order. Nothing is clicked in the console -
# monitoring and alarms included.
#
#   templates/V48_01-network.yaml   VPC, subnets, routes, S3 endpoint, SGs (incl. ALB), NACL, flow logs
#   templates/V48_02-data.yaml      RDS MariaDB (error log -> CloudWatch) + EFS + secrets
#   templates/V48_03-security.yaml  IAM: service roles (incl. CloudWatch agent, site check),
#                                   instance profile, groups, policies, users
#   templates/V48_04-storage.yaml   S3 bucket (policy, lifecycle, trigger) + publisher Lambda
#   templates/V48_05-compute.yaml   launch template (+ CloudWatch agent), ALB + target group,
#                                   Auto Scaling group (two AZs, target tracking, rolling
#                                   updates), bastion, the web servers' log groups + agent config
#   templates/V48_06-monitoring.yaml  SNS (e-mail), alarms, site check (Lambda + EventBridge,
#                                   code = lambda/site-check.py), metric filters, saved
#                                   Logs Insights queries, dashboard
#
# Each layer exports its ids (<project>-<Key>) and the next layer imports them.
# Everything that varies (IP, names, sizes, CIDRs, scaling limits) is a
# parameter, set in V48_config.sh. Only two things are deliberately NOT in
# CloudFormation:
#   - the self-signed HTTPS certificate: CloudFormation can't import into ACM,
#     so it is created (openssl) and imported here - once, then reused
#   - emptying the VPC's default security group (CloudFormation can't manage it)
# The passwords ARE in CloudFormation now: Secrets Manager generates them.
#
# Requirements: AWS CLI v2 with admin credentials, existing key pair, openssl
#               (Git Bash has it), git (optional), ALARM_EMAIL set in V48_config.sh.
# From V47:     updates it in place (new launch template -> the servers are rolled
#               over one at a time, the site stays up), then adds layer 6.
# Run:          ./V48_novatrix.sh           create / update everything (safe to re-run;
#                                           re-run if your IP changes)
#               ./V48_novatrix.sh --plan    show what WOULD change (change sets), change nothing
#               NEW_AMI=1 ./V48_novatrix.sh  roll all web servers over to the latest Amazon
#                                           Linux - one at a time, the site stays up
# Verify:       ./V48_verify.sh   [--failover] [--selfheal] [--load] [--alarmtest] [--all]
# Clean up:     ./V48_cleanup.sh
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
source ./V48_config.sh

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
  DIRTY=$(git status --porcelain -- templates "$CONTENT_DIR" V48_config.sh)
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
# Alarm mails need a real address (the SNS subscription is created with it).
if [[ ! "$ALARM_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ || "$ALARM_EMAIL" == CHANGE-ME@* ]]; then
  echo "Set ALARM_EMAIL in V48_config.sh (or: ALARM_EMAIL=you@example.com $0) - every alarm is mailed there." >&2
  exit 1
fi
echo "Alarm mails to: $ALARM_EMAIL"
# The site check is deployed from the template's inline copy: it must be
# exactly lambda/site-check.py, or what runs is not what is in the repo.
[[ -f "$SITE_CHECK_SOURCE" ]] || { echo "Missing $SITE_CHECK_SOURCE" >&2; exit 1; }
if ! diff <(inline_code "${TEMPLATES[5]}" SiteCheckFunction | grep -v '^[[:space:]]*$') \
          <(tr -d '\r' < "$SITE_CHECK_SOURCE" | grep -v '^[[:space:]]*$') >"$WORK_DIR/site-check.diff"; then
  echo "$SITE_CHECK_SOURCE and the inline code in ${TEMPLATES[5]} (SiteCheckFunction) differ:" >&2
  sed 's/^/    /' "$WORK_DIR/site-check.diff" | head -n 20 >&2
  echo "Copy the change into both (the template's copy is indented 10 spaces), then run again." >&2
  exit 1
fi
echo "Site check: $SITE_CHECK_SOURCE = the code in ${TEMPLATES[5]}"

# EC2 refuses user data over 16,384 bytes - and only when the stack is created,
# after the earlier layers. Estimate it here: the web server's user data block
# without YAML indentation, plus ~1,200 bytes for the values CloudFormation fills in.
UD_BYTES=$(awk '/^  WebLaunchTemplate:/ { lt = 1 } lt && /UserData:/ { on = 1; next }
                on && /^  [A-Za-z]/ { exit } on && !/^ *#/ { sub(/^ +/, ""); n += length($0) + 1 }
                END { print n + 1200 }' "${TEMPLATES[4]}")
(( UD_BYTES <= 16384 )) || { echo "Web server user data ~${UD_BYTES} bytes > EC2's limit 16,384 - shorten it." >&2; exit 1; }
echo "Web server user data: ~${UD_BYTES} of 16,384 bytes"

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
  echo "Run ./V46_cleanup.sh first (V48 creates everything again from the repo), then this script." >&2
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
for g in "${WEB_LOG_GROUPS[@]}"; do
  must_be_free "log group"     "$WEB_LOG_PREFIX/$g" log_group_exists "$WEB_LOG_PREFIX/$g"
done
must_be_free "log group"       "$SITE_CHECK_LOG_GROUP" log_group_exists "$SITE_CHECK_LOG_GROUP"
must_be_free "log group"       "$DB_LOG_GROUP"  log_group_exists "$DB_LOG_GROUP"
must_be_free "Lambda"          "$SITE_CHECK_FUNCTION" aws lambda get-function --region "$REGION" --function-name "$SITE_CHECK_FUNCTION"
must_be_free "SSM parameter"   "$CW_AGENT_CONFIG" aws ssm get-parameter --region "$REGION" --name "$CW_AGENT_CONFIG"
must_be_free "instance profile" "$EC2_PROFILE"  aws iam get-instance-profile --instance-profile-name "$EC2_PROFILE"
for r in "$EC2_ROLE" "$UPLOADER_ROLE" "$LAMBDA_ROLE" "$FLOW_LOG_ROLE" "$SITE_CHECK_ROLE"; do
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
step "Layer 1/6: network"
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
step "Layer 2/6: data (RDS + EFS + Secrets Manager, DB error log -> CloudWatch)"
stack_exists "$STACK_DATA" || [[ "$PLAN" == yes ]] || echo "The first time, RDS takes 5-15 minutes - the script waits."
deploy "$STACK_DATA" "${TEMPLATES[1]}" \
  ProjectName="$PROJECT" DbInstanceClass="$DB_INSTANCE_CLASS" DbAllocatedStorage="$DB_STORAGE_GB" \
  DbBackupRetentionDays="$DB_BACKUP_RETENTION_DAYS" DbMultiAz="$DB_MULTI_AZ" DbName="$DB_NAME" \
  DbMasterUsername="$DB_MASTER_USER" DbAppSecretName="$DB_APP_SECRET" WpAdminSecretName="$WP_ADMIN_SECRET" \
  WebRoleName="$EC2_ROLE" DbLogRetentionDays="$CW_LOG_RETENTION_DAYS"

# =============================================================================
# 6. Layer 3: IAM
# =============================================================================
step "Layer 3/6: security (IAM)"
deploy "$STACK_SECURITY" "${TEMPLATES[2]}" \
  ProjectName="$PROJECT" SiteBucket="$SITE_BUCKET" \
  OpsUserName="${USERS[0]%%:*}" DevUserName="${USERS[1]%%:*}" MarketingUserName="${USERS[2]%%:*}"

# =============================================================================
# 7. Layer 4: S3 + publisher, then the static content (from the repo)
# =============================================================================
step "Layer 4/6: storage (S3 + publisher)"
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
step "Layer 5/6: compute (ALB + Auto Scaling group + CloudWatch agent + bastion)"
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
  HealthCheckPath="$HEALTH_CHECK_PATH" CertificateArn="${CERT_ARN:-}" LogRetentionDays="$CW_LOG_RETENTION_DAYS" \
  DbName="$DB_NAME" DbAppUsername="$DB_APP_USER" \
  WpTitle="$WP_TITLE" WpAdminUser="$WP_ADMIN_USER" WpAdminEmail="$WP_ADMIN_EMAIL" WpLocale="$WP_LOCALE"

# =============================================================================
# 9. Layer 6: monitoring - alarms, SNS, site check, log follow-up, dashboard
# =============================================================================
step "Layer 6/6: monitoring (alarms -> SNS e-mail, site check, Logs Insights, dashboard)"
HTTPS_ENABLED=no
[[ -n "${CERT_ARN:-}" ]] && HTTPS_ENABLED=yes
deploy "$STACK_MONITORING" "${TEMPLATES[5]}" \
  ProjectName="$PROJECT" AlarmEmail="$ALARM_EMAIL" HttpsEnabled="$HTTPS_ENABLED" \
  LogRetentionDays="$CW_LOG_RETENTION_DAYS" SiteCheckSchedule="$SITE_CHECK_SCHEDULE" SlowSiteMs="$SLOW_SITE_MS" \
  WebCpuAlarmPercent="$WEB_CPU_ALARM" WebMemoryAlarmPercent="$WEB_MEMORY_ALARM" \
  WebDiskAlarmPercent="$WEB_DISK_ALARM" AsgMaxSize="$ASG_MAX"

if [[ "$PLAN" == yes ]]; then
  echo
  echo "Plan done - nothing was changed. Run without --plan to apply."
  exit 0
fi

# First data point at once (not in up to 5 minutes): the site-down alarm treats
# missing data as "down".
if aws lambda invoke --region "$REGION" --function-name "$SITE_CHECK_FUNCTION" \
     "$WORK_DIR/site-check.json" >/dev/null 2>&1; then
  echo "Site check, first run: $(tr -d '\r' < "$WORK_DIR/site-check.json")"
else
  echo "WARNING: could not run the site check - see: aws logs tail $SITE_CHECK_LOG_GROUP --region $REGION"
fi
SUB=$(aws sns list-subscriptions-by-topic --region "$REGION" --topic-arn "$(stack_output AlarmTopicArn)" \
        --query "Subscriptions[?Endpoint=='$ALARM_EMAIL'].SubscriptionArn | [0]" --output text 2>/dev/null || true)
if [[ "$SUB" == arn:* ]]; then
  echo "Alarm mails: $ALARM_EMAIL (subscription confirmed)"
else
  echo "ACTION NEEDED: AWS has sent a confirmation mail to $ALARM_EMAIL (\"AWS Notification -"
  echo "  Subscription Confirmation\"). Click its link - until then NO alarm mail is delivered."
fi

# =============================================================================
# 10. Summary
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
echo "  Monitoring: https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards/dashboard/${DASHBOARD_NAME}"
echo "              $(aws cloudwatch describe-alarms --region "$REGION" --alarm-name-prefix "${PROJECT}-" \
                    --query 'length(MetricAlarms)' --output text) alarms -> $ALARM_EMAIL (critical ones also mail when OK again)"
echo "  Logs:       ${WEB_LOG_PREFIX}/{$(IFS=,; echo "${WEB_LOG_GROUPS[*]}")}, $SITE_CHECK_LOG_GROUP, $DB_LOG_GROUP"
echo "              follow live: aws logs tail ${WEB_LOG_PREFIX}/access --follow --region $REGION"
echo "              search: CloudWatch -> Logs Insights -> Saved queries (${PROJECT}/1-6)"
echo
echo "Change something: edit a template, ./V48_novatrix.sh --plan, commit, ./V48_novatrix.sh"
echo "Tip:      stop the bastion when you are not administering - nothing else needs it:"
echo "            aws ec2 stop-instances --instance-ids $BASTION_ID --region $REGION"
echo "Next:     ./V48_verify.sh          (stacks vs repo, drift, permissions, WordPress, backups, network, HA, monitoring)"
echo "          ./V48_verify.sh --all    (also: kill a server, break a server, load test -> scaling, alarm mails)"
echo "Clean up: ./V48_cleanup.sh"
```

### *__V48_config.sh__*

```bash
# =============================================================================
# Novatrix V48 - shared settings. Sourced by the other V48 scripts, not run.
#
# Everything that VARIES between environments lives here and is passed to the
# CloudFormation templates as parameters. The templates themselves contain no
# account ids, IP addresses or passwords.
#
# New in V48: central monitoring and logging, all in CloudFormation - a sixth
# layer (monitoring: alarms -> SNS e-mail, a serverless site check, metric
# filters, saved Logs Insights queries, a dashboard), the CloudWatch agent on
# every web server (memory, disk, five log files) and the database's error log
# in CloudWatch Logs. V47 (load balancer + Auto Scaling group + Secrets
# Manager) is updated in place - nothing has to be torn down first.
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

# ----- Infrastructure as code: six stacks, deployed in this order -------------
# Each layer exports its values (Export name: <PROJECT>-<Key>) and the next layer
# imports them. CloudFormation then refuses to delete a layer that another
# layer still uses - the cleanup script deletes them in reverse order.
STACK_NETWORK="${PROJECT}-network"         # VPC, subnets, routes, SGs (incl. ALB), NACL, S3 endpoint, flow logs
STACK_DATA="${PROJECT}-data"               # RDS MariaDB + EFS + secrets (Secrets Manager)
STACK_SECURITY="${PROJECT}-security"       # IAM: service roles, groups, policies, users
STACK_STORAGE="${PROJECT}-storage"         # S3 bucket + publisher Lambda
STACK_COMPUTE="${PROJECT}-compute"         # launch template, ALB, Auto Scaling group, bastion, web log groups
STACK_MONITORING="${PROJECT}-monitoring"   # SNS, alarms, site check (Lambda), metric filters, queries, dashboard
STACKS=("$STACK_NETWORK" "$STACK_DATA" "$STACK_SECURITY" "$STACK_STORAGE" "$STACK_COMPUTE" "$STACK_MONITORING")
TEMPLATES=(templates/V48_01-network.yaml templates/V48_02-data.yaml templates/V48_03-security.yaml
           templates/V48_04-storage.yaml templates/V48_05-compute.yaml templates/V48_06-monitoring.yaml)
CONTENT_DIR="content"                      # static content (index.html, style.css, images/), uploaded as drafts to drafts/

# ----- Network (address plan, see templates/V48_01-network.yaml) ---------------
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

# ----- Service roles (machines) - names are set in templates/V48_03-security.yaml ---
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
                                           # (~60 % of what one t3.micro served in the V48 load test:
                                           # ~100/min - the target must be BELOW a server's capacity)

# ----- Load balancer --------------------------------------------------------------
ALB_NAME="${PROJECT}-alb"
TG_NAME="${PROJECT}-web-tg"
HEALTH_CHECK_PATH="/healthz.php"           # PHP + EFS on the server (not the DB - see compute template)
# No domain yet: HTTPS on the ALB uses a self-signed certificate that the deploy
# script creates and imports into ACM (CloudFormation can't import certificates).
CERT_DOMAIN="${PROJECT}-alb.invalid"       # .invalid = reserved TLD, can never be a real name

# ----- Monitoring and logging (templates/V48_06-monitoring.yaml + the agent in layer 5) ---
# Every alarm mails this address through SNS. AWS first sends a confirmation
# mail - click its link once, otherwise no alarm mail is delivered. Set it here
# or for one run: ALARM_EMAIL=you@example.com ./V48_novatrix.sh
ALARM_EMAIL="${ALARM_EMAIL:-CHANGE-ME@example.com}"
ALARM_TOPIC="${PROJECT}-alarms"
SITE_CHECK_FUNCTION="${PROJECT}-site-check"     # lambda/site-check.py, inline in the template
SITE_CHECK_ROLE="${PROJECT}-site-check-role"
SITE_CHECK_SCHEDULE="rate(5 minutes)"           # ~8,640 runs/month - Lambda free tier
SITE_CHECK_SOURCE="lambda/site-check.py"
SITE_CHECK_LOG_GROUP="/aws/lambda/${SITE_CHECK_FUNCTION}"
WEB_LOG_PREFIX="/${PROJECT}/web"                # access, error, php, jobs, boot - one stream per server
WEB_LOG_GROUPS=(access error php jobs boot)
DB_LOG_GROUP="/aws/rds/instance/${DB_INSTANCE_ID}/error"
CW_LOG_RETENTION_DAYS=14                        # CloudWatch Logs (the S3 archive in logs/ keeps 30 days)
CW_AGENT_CONFIG="/${PROJECT}/cloudwatch-agent/web"   # SSM parameter the agent reads at boot
DASHBOARD_NAME="$PROJECT"
# Thresholds (warning vs critical, see the monitoring template)
WEB_CPU_ALARM=80                           # % - ABOVE the scaling target: scaling isn't keeping up
WEB_MEMORY_ALARM=85                        # % of 1 GiB, the worst server
WEB_DISK_ALARM=80                          # % of the root disk, the worst server
SLOW_SITE_MS=3000                          # start page, as the site check measures it

# The site check's code lives inline in the monitoring template (CloudFormation
# deploys it - no zip, no build tool, works in Git Bash) AND as a normal file in
# lambda/. This prints the template's copy, unindented, to compare the two.
inline_code() {   # template logical-id
  awk -v res="  $2:" '
    $0 == res { r = 1; next }
    r && /ZipFile: \|/ { z = 1; next }
    z && /^[[:space:]]*$/ { print ""; next }
    z { match($0, /^ */); if (!ind) ind = RLENGTH; if (RLENGTH < ind) exit; print substr($0, ind + 1) }' "$1" | tr -d '\r'
}

# ----- Derived ARNs -------------------------------------------------------------
BUCKET_ARN="arn:aws:s3:::${SITE_BUCKET}"
FUNCTION_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${FUNCTION_NAME}"
LOG_GROUP_ARN="arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:${LOG_GROUP}"
EC2_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${EC2_ROLE}"
UPLOADER_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${UPLOADER_ROLE}"
LAMBDA_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE}"
SECRET_ARN_PREFIX="arn:aws:secretsmanager:${REGION}:${ACCOUNT_ID}:secret"   # + :name-XXXXXX
DB_ARN="arn:aws:rds:${REGION}:${ACCOUNT_ID}:db:${DB_INSTANCE_ID}"
SITE_CHECK_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${SITE_CHECK_ROLE}"
ALARM_TOPIC_ARN="arn:aws:sns:${REGION}:${ACCOUNT_ID}:${ALARM_TOPIC}"
LOGS_ARN="arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group"

# ----- Stack outputs ------------------------------------------------------------
# Every output key is unique across the six stacks, so one lookup table works.
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
```

### *__V48_verify.sh__*

```bash
#!/usr/bin/env bash
# =============================================================================
# Novatrix V48 - verifies that the stack built from the templates in the repo
# is what runs in AWS, and that it works: WordPress behind a load balancer on
# an Auto Scaling group in two AZs, RDS + EFS, backups, IAM, the network - and
# the central monitoring and logging (CloudWatch, SNS e-mail, site check).
#
# Run:  ./V48_verify.sh                 everything that changes nothing (Del 0-8)
#       ./V48_verify.sh --failover      + Del 9.1: terminate a web server under traffic
#       ./V48_verify.sh --selfheal      + Del 9.2: break a web server (Apache stopped)
#       ./V48_verify.sh --load          + Del 9.3: load test -> the group scales out
#       ./V48_verify.sh --alarmtest     + Del 9.4: the alarm chain with REAL mails (ALARM + OK)
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
#   Del 8: monitoring and logging - the SNS subscription is confirmed, every
#          alarm mails (critical ones also on OK), CPU/memory/disk arrive from
#          the agent, every server's logs are in CloudWatch and searchable
#          (a request through the ALB is found again, Logs Insights), the
#          metric filters, the database's error log, the site check (Lambda).
#   Del 9: (opt-in, see Run, always LAST: it replaces servers and sets off
#          alarms) what happens when a server dies, breaks, or the load rises
#          - measured from the outside, request by request - and whether an
#          alarm really reaches the inbox.
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

TEST_OK="v48-test-${STAMP}.html"
TEST_BAD="v48-test-${STAMP}.php"
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
if out=$(aws sts assume-role --role-arn "$UPLOADER_ROLE_ARN" --role-session-name v48-admin-test 2>&1); then
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
  # Neither marker = the SSH session broke (e.g. "Connection reset by peer"),
  # not a network verdict: try once more before calling it an error.
  if [[ "$output" != *__OPPEN__* && "$output" != *__STANGD__* ]]; then
    sleep 5
    output=$(with_timeout 30 "$3" "($4) >/dev/null 2>&1 && echo __OPPEN__ || echo __STANGD__")
  fi
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
  if [[ "$SSH_OK" == no ]]; then
    # The most common cause: this computer's public IP changed since the deploy
    # (the bastion only lets in AdminCidr - ONE address).
    NOW_IP=$(curl -s -m 10 https://checkip.amazonaws.com | tr -d '[:space:]')
    ADMIN_CIDR=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK_NETWORK" \
      --query "Stacks[0].Parameters[?ParameterKey=='AdminCidr'].ParameterValue | [0]" --output text 2>/dev/null)
    if [[ -n "$NOW_IP" && "$ADMIN_CIDR" != "$NOW_IP/32" ]]; then
      echo "     ORSAK: din IP är nu $NOW_IP men bastionen släpper bara in $ADMIN_CIDR."
      echo "     Kör ./V48_novatrix.sh (uppdaterar bara SG/NACL-reglerna, ingen server byts) och sedan verify igen."
    fi
  fi
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
    "sudo touch $WP_ROOT/.v48-uid && u=\$(stat -c %u $WP_ROOT/.v48-uid); sudo rm -f $WP_ROOT/.v48-uid; [ \"\$u\" = 48 ]"
  EFS_FILE="wp-content/uploads/v48-efs-${STAMP}.txt"
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
  PHP_FILE="wp-content/uploads/v48-${STAMP}.php"
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
    "$DBCLI -e 'CREATE DATABASE v48_intrang'"
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
echo; echo "=== Del 8: central monitorering och loggning (CloudWatch, SNS, site check) ==="
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
  echo "--- 8.1 Larmkanalen: SNS -> e-post ---"
  read -r sub_arn sub_to <<<"$(aws sns list-subscriptions-by-topic --region "$REGION" --topic-arn "$TOPIC_ARN" \
    --query "Subscriptions[?Protocol=='email'] | [0].[SubscriptionArn, Endpoint]" --output text 2>/dev/null)"
  echo "Ämne: $TOPIC_ARN  ->  e-post ${sub_to:-saknas}"
  [[ "${sub_arn:-}" == arn:* ]] && got=ALLOW || got=DENY
  record ALLOW "$got" "e-postprenumerationen är bekräftad (${sub_arn:-saknas})"
  [[ "$got" == DENY ]] && echo "     Klicka på länken i mejlet \"AWS Notification - Subscription Confirmation\" - annars levereras inga larm."

  echo; echo "--- 8.2 Larmen (critical: mejl vid ALARM och OK, warning: mejl vid ALARM) ---"
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

  echo; echo "--- 8.3 CPU, minne och disk (CloudWatch-agenten ser inuti servrarna, EC2 bara utifrån) ---"
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

  echo; echo "--- 8.4 Central loggning: alla servrars loggar på ett ställe, sökbara ---"
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
            --query 'events[0].[logStreamName, message]' --output text 2>/dev/null | grep -m1 '^i-')
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
  n=$(aws cloudformation describe-stack-resources --region "$REGION" --stack-name "$STACK_MONITORING" \
        --query "length(StackResources[?ResourceType=='AWS::Logs::QueryDefinition' && ResourceStatus!='DELETE_COMPLETE'])" \
        --output text 2>/dev/null)
  record 6 "${n:-0}" "sparade Logs Insights-frågor i stacken (CloudWatch -> Logs Insights -> Saved queries)"
  aws logs describe-query-definitions --region "$REGION" --query 'queryDefinitions[].name' --output text 2>/dev/null \
    | tr '\t' '\n' | grep "^${PROJECT}/" | sort | sed 's/^/      /'

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

  echo; echo "--- 8.5 Serverless: site check (Lambda, startas var 5:e minut av EventBridge) ---"
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
  remote "sudo rm -f /var/www/static/$TEST_OK $WP_ROOT/wp-content/uploads/v48-*-${STAMP}.txt $WP_ROOT/wp-content/uploads/v48-${STAMP}.php" >/dev/null || true
  [[ -n "$WEB2_PRIV" ]] && { remote_on "$WEB2_PRIV" "sudo rm -f /var/www/static/$TEST_OK" >/dev/null || true; }
  [[ -n "$POST_ID" ]] && { remote "$WPCLI post delete $POST_ID --force" >/dev/null || true; }
fi

# =============================================================================
# Del 9 (opt-in): failure and load, measured from the outside
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
  echo; echo "Del 9 hoppas över: stacken $STACK_COMPUTE saknas."
  DO_FAILOVER=no; DO_SELFHEAL=no; DO_LOAD=no; DO_ALARMTEST=no
fi

if [[ "$DO_FAILOVER" == yes ]]; then
  echo; echo "=== Del 9.1: en webbserver försvinner (EC2 terminerar den hårt, under trafik) ==="
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
  echo; echo "=== Del 9.2: en webbserver går sönder (Apache stoppas) - hälsokontroll + självläkning ==="
  if [[ -z "$BASTION_IP" || ! -f "$KEY_FILE" ]]; then
    echo "Hoppar över (behöver SSH via bastionen)."
  elif wait_stable old "${REGION}b"; then
    victim=$VICTIM_ID; victim_ip=$VICTIM_IP
    echo "Offer: $victim ($victim_ip, $VICTIM_AZ) - instansen kör vidare, men webbservern svarar inte"
    poll_start; sleep 10
    if ! remote_on "$victim_ip" "sudo systemctl stop httpd" >/dev/null; then
      poll_stop
      record ALLOW ERROR "kunde inte stoppa Apache på $victim_ip (ingen SSH via bastionen) - testet hoppas över"
    else
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
fi

# Safety: load only OUR load balancer. The address must be the one EC2 reports
# for the ALB named $ALB_NAME in THIS account and region, and an AWS ELB name.
if [[ "$DO_LOAD" == yes ]]; then
  own_dns=$(aws elbv2 describe-load-balancers --region "$REGION" --names "$ALB_NAME" \
              --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null)
  if [[ -z "$ALB_DNS" || "$own_dns" != "$ALB_DNS" || "$ALB_DNS" != *".${REGION}.elb.amazonaws.com" ]]; then
    echo; echo "Del 9.3 hoppas över: '${ALB_DNS:-?}' är inte kontots egen lastbalanserare $ALB_NAME (${own_dns:-saknas})."
    DO_LOAD=no
  fi
fi

if [[ "$DO_LOAD" == yes ]]; then
  LOAD_MINUTES=${LOAD_MINUTES:-8}; LOAD_WORKERS=${LOAD_WORKERS:-12}
  (( LOAD_WORKERS <= 30 && LOAD_MINUTES <= 15 )) || { echo "LOAD_WORKERS max 30, LOAD_MINUTES max 15"; exit 2; }
  echo "Mål: $SITE/  = $ALB_NAME i konto $ACCOUNT_ID ($REGION) - bara GET mot startsidan, ingen annan adress."
  echo; echo "=== Del 9.3: lasttest - $LOAD_WORKERS parallella besökare i $LOAD_MINUTES minuter mot $SITE/ ==="
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
  echo; echo "=== Del 9.4: larmkedjan - logg -> metrikfilter -> larm -> SNS -> mejl ==="
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
  # The servers chosen in Del 2 may be gone (Del 9.1-9.3 replace and add
  # servers): take one that is in service NOW.
  read -r PF_ID PF_AZ PF_PRIV _ <<<"$(web_instances | head -n 1)"
  if [[ "$SSH_OK" != yes || -z "${PF_PRIV:-}" ]]; then
    echo "    Hoppar över PHP-delen (ingen SSH via bastionen, eller ingen server i tjänst)."
  else
    # A REAL fatal error through the same path as a broken plugin: Apache ->
    # PHP-FPM -> its error log. A one-line PHP file on EFS calls a function
    # that doesn't exist; the file is removed again at once.
    fn="v48_larmtest_${STAMP}"
    PF_FILE="v48-fatal-${STAMP}.php"
    code=$(remote_on "$PF_PRIV" "echo '<?php ${fn}();' | sudo tee $WP_ROOT/$PF_FILE >/dev/null && curl -s -o /dev/null -w '%{http_code}' http://localhost/$PF_FILE; sudo rm -f $WP_ROOT/$PF_FILE" | tail -n 1)
    echo "    PHP Fatal framkallat på $PF_PRIV ($PF_ID, $PF_AZ): /$PF_FILE anropar ${fn}() som inte finns -> HTTP ${code:-?}"
    [[ "$code" == 500 ]] && got=ALLOW || got=DENY
    record ALLOW "$got" "PHP-FPM svarar 500 på det trasiga skriptet (ett riktigt fatalt fel, HTTP ${code:-inget svar})"
    got=DENY; line=""
    for i in $(seq 1 24); do
      line=$(aws logs filter-log-events --region "$REGION" --log-group-name "$WEB_LOG_PREFIX/php" \
               --start-time "$START_MS" --filter-pattern "\"$fn\"" --query 'events[0].message' --output text 2>/dev/null | grep -m1 'PHP')
      [[ "$line" == *"PHP Fatal"* ]] && { got=ALLOW; break; }
      sleep 5
    done
    echo "    i loggen ($WEB_LOG_PREFIX/php, ström $PF_ID): ${line:-ingen träff}" | cut -c1-220
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
```

### *__V48_cleanup.sh__*

```bash
#!/usr/bin/env bash
# =============================================================================
# Novatrix V48 - removes everything V48_novatrix.sh created: the six stacks
# (in REVERSE order - CloudFormation refuses to delete a layer whose exports
# another layer still imports), the secrets, and the self-signed certificate.
#
# NOTE: the database, its automated backups, the EFS file system and the S3
# backups are deleted too - nothing is kept (and nothing keeps costing money).
# Deleting the compute stack also deletes the load balancer and terminates
# EVERY web server in the Auto Scaling group (also ones it scaled out itself).
# Monitoring: the alarms, the alarm mails (the SNS subscription), the site
# check, the dashboard and ALL CloudWatch log groups go too. Metrics can't be
# deleted - CloudWatch drops them by itself (no cost once nothing is sent).
# The repo is untouched: ./V48_novatrix.sh recreates the whole stack from it.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")"
source ./V48_config.sh

read -r -p "This deletes ALL ${PROJECT} V48 resources (incl. the database and all backups) in account $ACCOUNT_ID. Type JA: " answer
[[ "$answer" == "JA" ]] || { echo "Aborted."; exit 1; }

quiet() { "$@" >/dev/null 2>&1 || true; }
FAILED=0

delete_stack() {   # stack
  local s=$1
  if ! stack_exists "$s"; then
    echo "  $s: does not exist"
    return
  fi
  aws cloudformation delete-stack --region "$REGION" --stack-name "$s"
  if aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$s"; then
    echo "  $s: deleted"
  else
    echo "  WARNING: $s could not be deleted - see its Events tab in the CloudFormation console."
    aws cloudformation describe-stack-events --region "$REGION" --stack-name "$s" \
      --query "StackEvents[?ResourceStatus=='DELETE_FAILED'] | [:3].[LogicalResourceId, ResourceStatusReason]" \
      --output text 2>/dev/null | sed 's/^/      /'
    FAILED=$((FAILED + 1))
  fi
}

# The certificate is in use by the HTTPS listener until the compute stack is
# gone, and ELB lets go of it a little after that - retry for a minute.
delete_certificate() {
  local arn i
  arn=$(cert_arn)
  [[ -z "$arn" ]] && { echo "  no certificate for $CERT_DOMAIN"; return; }
  for i in $(seq 1 12); do
    if aws acm delete-certificate --region "$REGION" --certificate-arn "$arn" >/dev/null 2>&1; then
      echo "  certificate $CERT_DOMAIN deleted"
      return
    fi
    sleep 5
  done
  echo "  WARNING: certificate $arn still in use - delete it later in the ACM console."
  FAILED=$((FAILED + 1))
}

# First: nothing may import from the compute layer any more - and no alarm
# should mail about servers that are being removed on purpose.
echo "Layer 6: monitoring (alarms, SNS e-mail, site check, dashboard)..."
delete_stack "$STACK_MONITORING"

echo "Layer 5: compute (load balancer, Auto Scaling group with all web servers, bastion, web log groups)..."
delete_stack "$STACK_COMPUTE"

echo "HTTPS certificate (ACM, imported by the deploy script)..."
if stack_exists "$STACK_COMPUTE"; then
  echo "  kept - the compute stack (and its HTTPS listener) still exists"
else
  delete_certificate
fi

# CloudFormation can't delete a bucket that still holds objects. The servers
# are gone now, so nothing writes new logs or backups while we empty it.
echo "Layer 4: storage - emptying the bucket first (static content, logs, backups)..."
quiet aws s3 rm "s3://$SITE_BUCKET" --recursive --region "$REGION"
delete_stack "$STACK_STORAGE"

# CloudFormation can't delete an IAM user that has things it didn't create
# (a console password or access keys added by hand for testing).
echo "Layer 3: security (IAM) - first removing passwords/keys added by hand..."
for entry in "${USERS[@]}"; do
  user=${entry%%:*}
  quiet aws iam delete-login-profile --user-name "$user"
  for key in $(aws iam list-access-keys --user-name "$user" \
                 --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null); do
    quiet aws iam delete-access-key --user-name "$user" --access-key-id "$key"
  done
done
delete_stack "$STACK_SECURITY"

# Deleting the database also deletes the master password secret RDS manages.
echo "Layer 2: data (RDS + EFS + secrets) - RDS takes 5-10 minutes..."
delete_stack "$STACK_DATA"

echo "Layer 1: network..."
delete_stack "$STACK_NETWORK"

# CloudFormation deletes its secrets without a recovery window. If the data
# stack was deleted some other way, a secret may be left SCHEDULED for deletion
# (7-30 days) - and would block its name at the next deploy. Delete for good.
echo "Secrets in Secrets Manager (anything left over, also if scheduled for deletion)..."
if stack_exists "$STACK_DATA"; then
  echo "  kept - the data stack still exists"
else
  for s in "${SECRET_NAMES[@]}"; do
    quiet aws secretsmanager delete-secret --region "$REGION" --secret-id "$s" --force-delete-without-recovery
  done
  echo "  done"
fi

# The stacks own every log group - but a service can recreate one while it is
# being deleted (RDS writes a last line when the database stops, the agent on
# a terminating server flushes its buffer). Delete such leftovers too.
echo "CloudWatch log groups left behind (if any)..."
for g in "${WEB_LOG_GROUPS[@]/#/$WEB_LOG_PREFIX/}" "$SITE_CHECK_LOG_GROUP" "$DB_LOG_GROUP" "$LOG_GROUP"; do
  if [[ "$(aws logs describe-log-groups --region "$REGION" --log-group-name-prefix "$g" \
           --query "logGroups[?logGroupName=='$g'] | [0].logGroupName" --output text 2>/dev/null)" == "$g" ]]; then
    if (( FAILED > 0 )); then
      echo "  kept $g - a stack that may own it was not deleted (see above)"
    else
      quiet aws logs delete-log-group --region "$REGION" --log-group-name "$g"
      echo "  deleted $g"
    fi
  fi
done

rm -rf -- "${WORK_DIR:?}"
if (( FAILED > 0 )); then
  echo "Done, but $FAILED item(s) remain - fix the cause above and run the script again."
  exit 1
fi
echo "Done. Recreate everything from the repo with: ./V48_novatrix.sh"
```

## 2. *__Dokumentation__*

Hela miljön skapas från sex CloudFormation-mallar i `templates/` med `./V48_novatrix.sh`. Värden som varierar (namn, CIDR, storlekar, trösklar) sätts i `V48_config.sh`. Region: __eu-north-1 (Stockholm)__. Stackarna taggas `Project=novatrix`, och taggen följer med till resurserna.

### *__Stackar (lager)__*

| # | Stack | Mall | Innehåll | Resurser |
|---|---|---|---|---|
| 1 | `novatrix-network` | `V48_01-network.yaml` | VPC, 5 subnät, route tables, internet gateway, S3 gateway endpoint, 5 security groups, 3 NACL:er, VPC flow logs | 55 |
| 2 | `novatrix-data` | `V48_02-data.yaml` | RDS MariaDB, EFS + access point + 2 mount targets, 2 hemligheter i Secrets Manager, logggrupp för databasens fellogg | 9 |
| 3 | `novatrix-security` | `V48_03-security.yaml` | IAM: 4 tjänsteroller, instansprofil, 3 grupper, 3 policyer, 3 användare | 14 |
| 4 | `novatrix-storage` | `V48_04-storage.yaml` | S3-bucket (policy, livscykel, trigger), publicerar-Lambda | 5 |
| 5 | `novatrix-compute` | `V48_05-compute.yaml` | ALB + target group + lyssnare, launch template, Auto Scaling-grupp + 2 skalningspolicyer, 5 logggrupper, CloudWatch-agentens konfiguration, bastion | 16 |
| 6 | `novatrix-monitoring` | `V48_06-monitoring.yaml` | SNS (e-post), site check (Lambda + EventBridge), 2 metrikfilter, 16 larm, 6 sparade Logs Insights-frågor, dashboard | 31 |

Lagren driftsätts i ordning 1→6 och raderas i omvänd ordning (6→1). Varje lager exporterar sina id:n (`novatrix-<Nyckel>`) och nästa lager importerar dem.

__Utanför CloudFormation (avsiktligt, skapas av skriptet):__ det självsignerade HTTPS-certifikatet (`novatrix-alb.invalid`, openssl, 365 dagar, importeras till ACM) och tömningen av VPC:ns default security group.

### *__Nätverk__*

| Subnät | CIDR | AZ | Typ | Route table | Innehåll |
|---|---|---|---|---|---|
| mgmt-a | 10.0.0.0/24 | eu-north-1a | publikt | publik | bastion |
| web-a | 10.0.2.0/24 | eu-north-1a | publikt | publik | webbservrar, ALB-nod |
| web-b | 10.0.3.0/24 | eu-north-1b | publikt | publik | webbservrar, ALB-nod |
| data-a | 10.0.10.0/24 | eu-north-1a | privat | privat | RDS, EFS mount target |
| data-b | 10.0.11.0/24 | eu-north-1b | privat | privat | EFS mount target (DB subnet group kräver 2 AZ) |

VPC: `10.0.0.0/16`. Webbnivån = `10.0.2.0/23`, datanivån = `10.0.10.0/23`. Ingen publik IP tilldelas automatiskt (`MapPublicIpOnLaunch: false`).

| Route table | Rutter |
|---|---|
| publik (mgmt-a, web-a, web-b) | 10.0.0.0/16 → local · 0.0.0.0/0 → internet gateway · S3 prefix list → gateway endpoint |
| privat (data-a, data-b) | 10.0.0.0/16 → local (ingen väg till internet, ingen NAT) |

__S3 gateway endpoint:__ släpper bara igenom projektets bucket och Amazon Linux paketförråd (`al2023-repos-eu-north-1-…`).

__VPC flow logs:__ all trafik (ACCEPT + REJECT), 60 s aggregering, till `/novatrix/vpc-flow-logs`.

#### *__Security groups (stateful)__*

| Security group | In | Ut |
|---|---|---|
| alb-sg | tcp 80, 443 från 0.0.0.0/0 | tcp 80 till web-sg |
| web-sg | tcp 80 från alb-sg · tcp 22 från bastion-sg · icmp typ 3 kod 4 (PMTUD) från 0.0.0.0/0 | tcp 443 till 0.0.0.0/0 · tcp 3306 till db-sg · tcp 2049 till efs-sg |
| bastion-sg | tcp 22 från admin-IP /32 | tcp 22 till web-sg |
| db-sg | tcp 3306 från web-sg | endast 127.0.0.1/32 (inget ut) |
| efs-sg | tcp 2049 från web-sg | endast 127.0.0.1/32 (inget ut) |
| default | – (tömd av skriptet) | – |

#### *__Network ACL:er (stateless, första träff gäller)__*

| NACL | Riktning | Regel | Port | Källa / mål |
|---|---|---|---|---|
| nacl-mgmt | IN | 100 ALLOW | 22 | admin-IP /32 |
| | IN | 110 ALLOW | 32768–60999 | 10.0.2.0/23 |
| | UT | 100 ALLOW | 1024–65535 | admin-IP /32 |
| | UT | 110 ALLOW | 22 | 10.0.2.0/23 |
| nacl-web | IN | 100 ALLOW | 80 | 0.0.0.0/0 |
| | IN | 110 ALLOW | 443 | 0.0.0.0/0 |
| | IN | 120 ALLOW | 22 | 10.0.0.0/24 |
| | IN | 130 ALLOW | 32768–60999 | 0.0.0.0/0 |
| | IN | 135 ALLOW | 1024–65535 | 10.0.2.0/23 |
| | IN | 140 ALLOW | icmp typ 3 kod 4 | 0.0.0.0/0 |
| | UT | 100 ALLOW | 1024–65535 | 0.0.0.0/0 |
| | UT | 110 ALLOW | 443 | 0.0.0.0/0 |
| | UT | 120 ALLOW | 3306 | 10.0.10.0/23 |
| | UT | 130 ALLOW | 2049 | 10.0.10.0/23 |
| | UT | 140 ALLOW | 80 | 10.0.2.0/23 |
| nacl-data | IN | 100 ALLOW | 3306 | 10.0.2.0/23 |
| | IN | 110 ALLOW | 2049 | 10.0.2.0/23 |
| | UT | 100 ALLOW | 32768–60999 | 10.0.2.0/23 |
| alla | IN/UT | * DENY | alla | 0.0.0.0/0 |

### *__Beräkning (compute)__*

#### *__Lastbalanserare och target group__*

| Egenskap | Värde |
|---|---|
| ALB | `novatrix-alb`, application, internet-facing, IPv4, noder i web-a + web-b, alb-sg |
| Lyssnare 80 | HTTP → target group |
| Lyssnare 443 | HTTPS, `ELBSecurityPolicy-TLS13-1-2-2021-06` (TLS 1.2 + 1.3), självsignerat certifikat → target group (skapas bara när certifikatet finns) |
| Attribut | ogiltiga headers släpps, desync-skydd `defensive`, idle timeout 60 s, deletion protection av |
| Target group | `novatrix-web-tg`, HTTP 80, typ instance |
| Hälsokontroll | `GET /healthz.php` var 15 s, timeout 5 s, frisk efter 2 OK, ur rotation efter 3 fel, kräver HTTP 200 |
| Deregistration delay | 30 s |

`/healthz.php` kontrollerar Apache, PHP och att WordPress-filerna finns på EFS – inte databasen.

#### *__Auto Scaling-grupp__*

| Egenskap | Värde |
|---|---|
| Namn | `novatrix-web-asg` |
| Min / max | 2 / 4 (önskat antal sätts inte i mallen – skalningen bestämmer) |
| Subnät | web-a + web-b (två AZ) |
| Hälsokontroll | ELB, grace period 600 s |
| Default instance warmup | 300 s |
| Gruppmetrik | på, 1 minut |
| Skalning (target tracking) | `ASGAverageCPUUtilization` runt 50 % · `ALBRequestCountPerTarget` runt 60 anrop/server/minut |
| CreationPolicy | väntar på signal från 2 servrar, timeout 20 min |
| Rolling update | 1 server i taget, minst 2 i tjänst, väntar på signal (max 20 min) |

#### *__Launch template – webbservrar__*

| Egenskap | Värde |
|---|---|
| AMI | Amazon Linux 2023 (väljs första gången och behålls, `NEW_AMI=1` byter) |
| Instanstyp | t3.micro, CPU credits `standard` |
| Nyckelpar | `AWS_MOV25` |
| Metadata | IMDSv2 krävs, hop limit 1 |
| Disk | gp3, krypterad, raderas med instansen (storlek enligt AMI) |
| Nätverk | publik IP (bara för utgående trafik), web-sg |
| IAM | instansprofil `novatrix-web-ec2-profile` (roll `novatrix-web-ec2-role`) |
| Programvara | Apache, PHP-FPM, MariaDB-klient, amazon-efs-utils, CloudWatch-agenten, WP-CLI, WordPress |

__Bastion:__ en EC2-instans (ingen ASG) i mgmt-a, publik IP, bastion-sg, __ingen IAM-roll__, samma AMI och instanstyp. sshd: inga lösenord, ingen root, vidarebefordrar bara port 22 (`PermitOpen *:22`).

#### Schemalagda jobb på varje webbserver (systemd)

| Timer | När | Gör |
|---|---|---|
| `novatrix-sync` | 2 min efter start, sedan var 30:e min | hämtar `web/` från S3 till `/var/www/static` |
| `novatrix-logs` | dagligen | arkiverar Apache-loggarna till `s3://…/logs/<instans-id>/` via uppladdarrollen |
| `novatrix-backup` | dagligen 00:00 UTC | databasdump + wp-content till `s3://…/backup/` – bara EN server per dygn (markering på EFS) |
| `novatrix-wpcron` | 5 min efter start, sedan var 5:e min | WordPress schemalagda uppgifter (som apache) |

Jobbens utskrifter går till `/var/log/novatrix-jobs.log` och därifrån till CloudWatch.

### *__Data__*

#### *__Databas (RDS)__*

| Egenskap | Värde |
|---|---|
| Instans | `novatrix-db`, MariaDB, db.t4g.micro |
| Lagring | 20 GiB gp2, krypterad i vila |
| Placering | Single-AZ i eu-north-1a, subnet group data-a + data-b, ej publik, db-sg, port 3306 |
| Databas / användare | `wordpress` · master `novatrixadmin` · app-användaren `wordpress` (bara databasen `wordpress`, bara från 10.0.2.0/23) |
| Masterlösenord | hanteras av RDS i Secrets Manager (`rds!db-…`), roteras automatiskt |
| Anslutning | TLS (RDS:s CA i servrarnas trust store, databasklienten verifierar servercertifikatet) |
| Backup | automatisk, 1 dag, fönster 01:00–01:30 UTC, point-in-time restore |
| Underhåll | söndag 02:00–02:30 UTC, automatiska minor-uppgraderingar |
| Loggar | fellogg exporteras till `/aws/rds/instance/novatrix-db/error` |
| Av | Performance Insights, Enhanced Monitoring, deletion protection |

#### *__Delad lagring (EFS)__*

| Egenskap | Värde |
|---|---|
| Filsystem | krypterat i vila, General Purpose, Bursting throughput, AWS Backup av |
| Mount targets | data-a + data-b, efs-sg (varje server använder sin egen AZ) |
| Access point | `/wordpress`, uid/gid 48 (apache), rättigheter 0755 |
| Filsystemspolicy | kräver TLS, tillåter bara `novatrix-web-ec2-role` och bara via access point |
| Montering | `/var/www/html` med `tls,iam,accesspoint` |

#### *__Hemligheter (Secrets Manager)__*

| Hemlighet | Skapas av | Innehåll |
|---|---|---|
| `novatrix/db/wordpress-password` | CloudFormation | 32 tecken, bokstäver + siffror |
| `novatrix/wordpress/admin-password` | CloudFormation | 32 tecken, bokstäver + siffror |
| `rds!db-…` | RDS | masteranvändare + lösenord, roteras automatiskt |

### *__Lagring (S3) och publicering__*

| Egenskap | Värde |
|---|---|
| Bucket | `novatrix-web-<konto-id>` |
| Kryptering | SSE-S3 (AES256) |
| Publik åtkomst | helt blockerad, Object Ownership `BucketOwnerEnforced` |
| Bucket policy | nekar allt utan TLS · nekar webbserverns och uppladdarens roller utanför S3-endpointen |
| Trigger | `ObjectCreated` under `drafts/` → publicerar-Lambdan |

| Prefix | Innehåll | Skrivs av | Livscykel |
|---|---|---|---|
| `drafts/` | utkast | erik.dev, maja.marketing (bara `drafts/images/`), deploy-skriptet | – |
| `web/` | publicerat statiskt innehåll | bara publicerar-Lambdan | – |
| `logs/` | Apache-loggarkiv | bara uppladdarrollen | raderas efter 30 dagar |
| `backup/` | databasdumpar + wp-content | bara uppladdarrollen | raderas efter 14 dagar |
| alla | ofullständiga multipart-uppladdningar | – | avbryts efter 1 dag |

__Publicerar-Lambda__ (`novatrix-publisher`): Python 3.12, 128 MB, timeout 15 s. Kopierar `drafts/` → `web/` om filtypen är tillåten (`.html .css .js .txt .svg .png .jpg .jpeg .webp .ico`) och filen är högst 5 MB. Allt annat avvisas och loggas.

### *__Behörigheter (IAM)__*

#### *__Tjänsteroller__*

| Roll | Antas av | Får |
|---|---|---|
| `novatrix-web-ec2-role` | EC2 (webbservrarna) | läsa `web/` i S3 · läsa de 3 projekthemligheterna · montera EFS via access point · anta uppladdarrollen · CloudWatch-agenten: mätvärden i `CWAgent`, loggar till `/novatrix/web/*`, läsa sin SSM-parameter, `ec2:DescribeTags` |
| `novatrix-uploader-role` | bara `novatrix-web-ec2-role` | `s3:PutObject` i `logs/` och `backup/` (inte läsa, lista eller radera) |
| `novatrix-publisher-role` | Lambda (publiceraren) | läsa `drafts/`, skriva `web/`, logga till egen logggrupp |
| `novatrix-site-check-role` | Lambda (site check) | mätvärden i `Novatrix/SiteCheck`, logga till egen logggrupp |
| `novatrix-flow-log-role` | VPC flow logs (bara eget konto) | skriva till `/novatrix/vpc-flow-logs` (skapas i lager 1) |

#### *__Människor (bara via grupper)__*

| Användare | Grupp | Får | Får inte |
|---|---|---|---|
| `anna.ops` | `novatrix-operations` | se allt (EC2, RDS, EFS, ALB, ASG, stackar, larm, dashboards) · starta/stoppa/starta om projektets instanser · ändra antal webbservrar inom min/max, byta en server, instance refresh · läsa och söka i projektets loggar (Logs Insights) · ladda ner loggar och backuper | ändra nätverk, databas, ALB, min/max, skalningspolicyer eller stackar · läsa hemligheter · radera eller tysta larm · avregistrera larmmejl · radera loggar |
| `erik.dev` | `novatrix-development` | ladda upp/ändra/radera utkast · läsa `web/` · driftsätta ny publicerarkod · läsa publicerarens logg | skriva `web/` direkt · ändra Lambdans konfiguration/roll · läsa besöksloggar, backuper och hemligheter |
| `maja.marketing` | `novatrix-marketing` | ladda upp och läsa bilder i `drafts/images/` | radera, ändra sidor, se resten av bucketen |

Inga lösenord eller åtkomstnycklar skapas för användarna.

### *__Monitorering__*

#### *__Mätvärden__*

| Källa | Mätvärden | Dimension |
|---|---|---|
| EC2 (utifrån) | CPU | Auto Scaling-gruppen |
| CloudWatch-agenten (inuti, var 60:e s) | `mem_used_percent`, `disk_used_percent` (`/`, xfs) | Auto Scaling-gruppen (inte per server) |
| ALB | anrop, 5xx från servrar och ALB, friska/sjuka servrar | lastbalanserare, target group |
| Auto Scaling | önskat antal, antal i tjänst | gruppen |
| RDS | CPU, ledigt minne, ledig disk | `novatrix-db` |
| EFS | burst-krediter | filsystemet |
| Lambda | fel | `novatrix-publisher`, `novatrix-site-check` |
| Site check | `Available` (1/0), `ResponseTimeMs` | `Site=novatrix` |
| Metrikfilter | `PhpFatalErrors` (`"PHP Fatal"` i PHP-loggen), `BackupFailures` (`"novatrix-backup FAILED"` i jobbloggen) | – |

#### *__Larm (16 st) → SNS `novatrix-alarms` → e-post__*

Alla larm mejlar vid ALARM. **Critical** mejlar även när de är OK igen.

| Larm | Mätvärde | Villkor | Saknad data | OK-mejl |
|---|---|---|---|---|
| `novatrix-critical-site-down` | site check `Available` (min) | < 1 i 2 av 2 perioder à 5 min | = larm | ja |
| `novatrix-critical-no-healthy-servers` | ALB `HealthyHostCount` (min) | < 1 i 2 perioder à 1 min | = larm | ja |
| `novatrix-critical-5xx-errors` | 5xx servrar + ALB (summa) | ≥ 10 på 5 min | ignoreras | ja |
| `novatrix-critical-web-cpu` | EC2 CPU (snitt) | > 80 % i 3 perioder à 5 min | ignoreras | ja |
| `novatrix-critical-web-memory` | `mem_used_percent` (max) | > 85 % i 2 perioder à 5 min | = larm | ja |
| `novatrix-critical-web-disk` | `disk_used_percent` (max) | > 80 % i 2 perioder à 5 min | ignoreras | ja |
| `novatrix-critical-db-storage` | RDS `FreeStorageSpace` (min) | < 2 GiB på 5 min | ignoreras | ja |
| `novatrix-warning-db-cpu` | RDS CPU (snitt) | > 80 % i 3 perioder à 5 min | ignoreras | nej |
| `novatrix-warning-db-memory` | RDS `FreeableMemory` (min) | < 100 MiB i 3 perioder à 5 min | ignoreras | nej |
| `novatrix-warning-unhealthy-server` | ALB `UnHealthyHostCount` (max) | ≥ 1 i 3 perioder à 1 min | ignoreras | nej |
| `novatrix-warning-at-max-servers` | `GroupInServiceInstances` (min) | ≥ 4 i 3 perioder à 5 min | ignoreras | nej |
| `novatrix-warning-efs-burst-credits` | EFS `BurstCreditBalance` (min) | < 100 GB på 5 min | ignoreras | nej |
| `novatrix-warning-php-fatal` | `PhpFatalErrors` (summa) | ≥ 1 på 5 min | ignoreras | nej |
| `novatrix-warning-backup-failed` | `BackupFailures` (summa) | ≥ 1 på 5 min | ignoreras | nej |
| `novatrix-warning-lambda-errors` | Lambda-fel publicerare + site check (summa) | ≥ 1 på 5 min | ignoreras | nej |
| `novatrix-warning-slow-site` | site check `ResponseTimeMs` (snitt) | > 3000 ms i 3 perioder à 5 min | ignoreras | nej |

Utöver dessa skapar target tracking 4 egna larm (`TargetTracking-novatrix-web-asg-…`) som bara skalar gruppen och inte mejlar. `AlarmLow`-larmen står normalt i ALARM när lasten är låg och gruppen är på minimum.

__SNS-ämne:__ `novatrix-alarms`, e-postprenumeration (måste bekräftas), får bara publiceras till av CloudWatch i det egna kontot och av kontot självt. Ingen KMS-kryptering (CloudWatch-larm kan inte publicera till ett ämne krypterat med `aws/sns`).

#### *__Dashboard `novatrix`__*

| Ruta | Visar |
|---|---|
| Alarms | status för alla 16 larm |
| Site check | `Available` och `ResponseTimeMs` |
| Load balancer | anrop, 5xx (servrar + ALB), friska servrar |
| Web servers | CPU (snitt), minne och disk (värsta servern) |
| Auto Scaling group | önskat antal och antal i tjänst |
| Database (RDS) | CPU, ledig disk, ledigt minne |
| EFS + Lambda | burst-krediter, Lambda-fel |
| Logg-tabell | Logs Insights: anrop per statuskod och server |

### *__Central loggning (CloudWatch Logs)__*

| Logggrupp | Innehåll | Källa | Lagring | Ägs av |
|---|---|---|---|---|
| `/novatrix/web/access` | varje anrop som JSON (time, ip, method, path, status, bytes, ms, ua), utan anrop till `/healthz.php` | agenten, en ström per instans | 14 d | compute |
| `/novatrix/web/error` | Apaches fellogg | agenten | 14 d | compute |
| `/novatrix/web/php` | PHP-FPM:s fellogg | agenten | 14 d | compute |
| `/novatrix/web/jobs` | sync, logs, backup, wp-cron | agenten | 14 d | compute |
| `/novatrix/web/boot` | uppstarten (cloud-init / user data) | agenten | 14 d | compute |
| `/aws/rds/instance/novatrix-db/error` | databasens fellogg | RDS-export | 14 d | data |
| `/aws/lambda/novatrix-site-check` | en JSON-rad per kontroll | site check | 14 d | monitoring |
| `/aws/lambda/novatrix-publisher` | publicerade och avvisade filer | publiceraren | 7 d | storage |
| `/novatrix/vpc-flow-logs` | släppt och blockerad nätverkstrafik | VPC flow logs | 7 d | network |

Agentens konfiguration ligger i SSM Parameter Store: `/novatrix/cloudwatch-agent/web`. Apache-loggarna arkiveras dessutom till S3 (`logs/`, 30 dagar).

#### *__Sparade Logs Insights-frågor__*

| Fråga | Logggrupper | Visar |
|---|---|---|
| `novatrix/1 5xx requests` | access | anrop med status ≥ 500: tid, server, ip, metod, sökväg, ms |
| `novatrix/2 slowest pages` | access | antal, snitt och max svarstid per sökväg |
| `novatrix/3 top visitors` | access | antal anrop per ip och user agent |
| `novatrix/4 errors on all servers` | error, php, jobs, boot, RDS-fellogg | rader med error, fatal, failed eller denied |
| `novatrix/5 requests per server` | access | anrop per server och 5-minutersintervall |
| `novatrix/6 site-check failures` | site check | misslyckade kontroller: url, status, ms, fel |

### *__Serverless__*

| Funktion | Startas av | Körmiljö | Gör |
|---|---|---|---|
| `novatrix-site-check` (`lambda/site-check.py`) | EventBridge-regeln `novatrix-site-check`, `rate(5 minutes)` | Python 3.12, 128 MB, timeout 60 s, utanför VPC:n | anropar sajten som en besökare: `/` (kräver `wp-content`), `/wp-login.php` (`user_login`), `/healthz.php` (`ok`), `/static/` (`Static content`) och `/` över HTTPS (när HTTPS är på) – skickar `Available` och `ResponseTimeMs` |
| `novatrix-publisher` (inline i lager 4) | S3 `ObjectCreated` under `drafts/` | Python 3.12, 128 MB, timeout 15 s | kontrollerar och publicerar utkast till `web/` |

Site checkens kod ligger både i `lambda/site-check.py` och inline i `V48_06-monitoring.yaml`. Deploy-skriptet stoppar om de skiljer sig åt.

### *__Script__*

| Script | Gör |
|---|---|
| `V48_config.sh` | gemensamma inställningar, körs inte själv (`ALARM_EMAIL` måste sättas) |
| `V48_novatrix.sh` | driftsätter/uppdaterar alla sex stackar · `--plan` visar ändringar utan att ändra · `NEW_AMI=1` rullar ut senaste Amazon Linux |
| `V48_verify.sh` | Del 0–8 ändrar inget · `--failover`, `--selfheal`, `--load`, `--alarmtest`, `--all` = Del 9.1–9.4 · sparar rapporten i `V48_verifiering_<datum>.txt` |
| `V48_cleanup.sh` | raderar allt efter bekräftelse med `JA`: stackar 6→1 (tömmer bucketen först), certifikatet, kvarvarande hemligheter och logggrupper |

### *__Varför central monitorering är väsentlig i en skalbar molnmiljö__*

- __Servrarna är tillfälliga.__ Auto Scaling-gruppen startar och terminerar servrar själv (2 → 4 vid last, ersättning vid fel). Rotdisken raderas med servern, så loggar måste skickas centralt – efter testerna fanns loggar från 5 servrar, även borttagna.
- __CPU styr skalningen.__ Target tracking håller CPU runt 50 %. Larmet på 80 % går bara igång när skalningen inte hinner med.
- __Minne och disk syns inte utifrån.__ EC2 ser bara CPU, så CloudWatch-agenten mäter minne och disk inifrån. Mätvärdena gäller hela gruppen, så larmen fungerar oavsett vilka servrar som kör.
- __Loggar måste kunna sökas över alla servrar.__ Bakom en lastbalanserare kan ett anrop hamna på vilken server som helst. Logs Insights söker i alla på en gång – loggarna visade bland annat skannrar som letade efter `/.env`.
- __Besökarens perspektiv.__ Allt internt kan vara grönt medan sajten är trasig. Site checken kontrollerar sajten utifrån var 5:e minut.
- __Kostnad och reaktion.__ Larm mejlar via SNS när kostnadstaket nås (max servrar) och vid fel. Critical-larm mejlar även när de är OK igen.

### *__Monitoreringen som IaC (VG)__*

- Allt ligger i CloudFormation: larm, SNS, site check, metrikfilter, sparade frågor och dashboard (lager 6), logggrupper och agentens konfiguration (lager 5) samt rättigheter (lager 3).
- Övervakningen skapas och tas bort med resten av miljön. Trösklarna är parametrar i `V48_config.sh`.
- Versionshanterat i Git. `V48_verify.sh` kontrollerar att AWS stämmer med repot (drift: `IN_SYNC`) och testar larmkedjan med riktiga mejl.

### *__Cloud native-strategi (VG)__*

__Redan serverless:__ publiceraren och site checken – korta, händelsestyrda jobb som passar Lambda.

#### *__Nästa steg: WordPress till containrar på ECS Fargate:__*

- *Inte Lambda:* WordPress körs hela tiden och läser och skriver filer – det passar inte korta, tillståndslösa anrop.
- *Inte EKS:* Kubernetes är för stort och dyrt för en webbplats.
- *Flytten:* en Dockerfile ersätter user data. ECS-tjänsten placeras bakom samma ALB, och EFS, RDS och Secrets Manager behålls. Loggar går till CloudWatch via `awslogs`, och skalningen sker med samma target tracking. Backup och wp-cron blir schemalagda tasks.

#### *__Vad det ger:__*

- __Skalbarhet:__ en container startar på sekunder till en minut, mot 2,5–6 minuter för en ny EC2-server i våra tester.
- __Drift:__ inga AMI:er att patcha, ingen bastion eller SSH, ingen gräns på 16 KB för user data. Rollback = föregående version.
- __Kostnad:__ betalning per sekund för det som används. I lab-skala är t3.micro i gratisnivån dock billigare – vinsten ligger främst i minskad drift.
- __Statiskt innehåll__ kan serveras direkt från S3 via CloudFront i stället för att synkas till varje server.

> *__OBS – hälsokontrollen kontrollerar inte databasen.__*
> `/healthz.php` kontrollerar bara den enskilda servern: Apache, PHP och att WordPress-filerna finns
> på EFS. En riktig WordPress-sida skulle kräva databasen (är RDS nere byts alla servrar ut i onödan)
> och tar 3–4 s under last (friska servrar skulle underkännas). Databasfel löses inte genom att byta
> servrar. Hela WordPress, inklusive databasen, kontrolleras i stället utifrån av site-checken
> (Lambda) var 5:e minut – den larmar via `novatrix-critical-site-down` men byter inga servrar.

> *__OBS – `content/` (HTML, CSS, SVG) finns kvar.__*
> Den statiska sidan visar publiceringskedjan från tidigare veckor: Git → S3 → Lambda → `/static/` på
> varje server. Verifieringen testar den, site-checken kontrollerar att `/static/` svarar, och
> innehållet finns i repository.

## *__3. Verifiering__*

### *__Webbsida:__*

![alt text](pictures/website.png)

### *__Stackar:__*

![alt text](pictures/stacks.png)

### *__Dashboard:__*

![alt text](pictures/dashboard.png)

### *__Central loggning (Log Insights):__*

![alt text](pictures/log_insights.png)

### *__Verifiering OK:__*

![alt text](pictures/verified.png)

### *__Alarm finns och fungerar:__*

![alt text](pictures/all_alarms.png)

![alt text](pictures/alarm.png)

![alt text](pictures/alarm_ok.png)