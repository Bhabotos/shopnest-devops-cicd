"""Static checks of the lab Terraform configuration (infra/lab/). It reads the files only: no Terraform, no AWS, no plan.

What it guards: the approved minimal architecture (one instance, one public subnet, no NAT Gateway, load balancer, RDS or ECR),
the network rules (HTTP 80 in, nothing else, never SSH or the database port), the instance hardening, the identities (no access
key, no wildcard action, a role that can only send its own environment's fixed documents), the gating of everything CI/CD behind
enable_cicd, the remote state settings, and that no account ID, bucket name or credential is committed.
"""

import re
import subprocess
import sys
import shutil
import tempfile
from pathlib import Path

ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
LAB = ROOT / "infra" / "lab"
failures = []
passes = 0


def check(label, ok, detail=""):
    global passes
    if ok:
        passes += 1
        print(f"PASS  {label}")
    else:
        failures.append(label)
        print(f"FAIL  {label}{': ' + detail if detail else ''}")


def code(text):
    """Terraform source without # and // comment lines."""
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith(("#", "//")))


tf = {p.name: code(p.read_text(encoding="utf-8")) for p in sorted(LAB.glob("*.tf"))}
alltf = "\n".join(tf.values())
resources = re.findall(r'^resource "([a-z0-9_]+)" "([a-z0-9_]+)"', alltf, re.M)
types = [t for t, _ in resources]

print("== the approved architecture")
for forbidden in ("aws_nat_gateway", "aws_lb", "aws_alb", "aws_db_instance", "aws_rds_cluster", "aws_ecr_repository", "aws_key_pair", "aws_iam_access_key", "aws_iam_user"):
    check(f"no {forbidden} resource", forbidden not in types)
check("exactly one EC2 instance", types.count("aws_instance") == 1)
check("exactly one VPC, one subnet, one Internet Gateway", types.count("aws_vpc") == 1 and types.count("aws_subnet") == 1 and types.count("aws_internet_gateway") == 1)
check("the default route goes to the Internet Gateway (no NAT)", 'gateway_id = aws_internet_gateway.lab.id' in tf["networking.tf"] and "nat_gateway_id" not in alltf)
check("the instance type defaults to t3.small", re.search(r'variable "instance_type"\s*\{[^}]*default\s*=\s*"t3\.small"', tf["variables.tf"], re.S) is not None)
check("the region is fixed to ap-south-1", 'var.aws_region == "ap-south-1"' in tf["variables.tf"])
check("the AWS profile defaults to devops", re.search(r'variable "aws_profile"\s*\{[^}]*default\s*=\s*"devops"', tf["variables.tf"], re.S) is not None)
check("the provider refuses a wrong account", "allowed_account_ids = var.allowed_account_ids" in tf["provider.tf"])
check("the configuration refuses to run as the AWS root user", ":root" in tf["main.tf"] and "precondition" in tf["main.tf"])

print("== the network: HTTP in, nothing else")
ingress = re.findall(r'resource "aws_vpc_security_group_ingress_rule" "(\w+)" \{(.*?)\n\}', tf["security_groups.tf"], re.S)
check("exactly one inbound rule", len(ingress) == 1, str([n for n, _ in ingress]))
body = ingress[0][1] if ingress else ""
check("the one inbound rule is TCP 80 from anywhere", 'from_port         = 80' in body and 'to_port           = 80' in body and '"0.0.0.0/0"' in body and '"tcp"' in body)
check("no inline ingress block and no legacy rule resource", not re.search(r"^\s*ingress\s*\{", alltf, re.M) and "aws_security_group_rule" not in types)
check("port 22 (SSH) and 5432 (PostgreSQL) never appear in a network rule", not re.search(r"(from_port|to_port)\s*=\s*(22|5432)\b", alltf))
egress = re.findall(r'resource "aws_vpc_security_group_egress_rule" "(\w+)" \{(.*?)\n\}', tf["security_groups.tf"], re.S)
ports = sorted(int(m) for _, b in egress for m in re.findall(r"to_port\s*=\s*(\d+)", b))
check("outbound is HTTPS and HTTP only", ports == [80, 443], str(ports))
check("the default security group is emptied", 'resource "aws_default_security_group" "default"' in tf["networking.tf"] and not re.search(r'aws_default_security_group" "default" \{[^}]*ingress', tf["networking.tf"], re.S))

print("== the instance")
ec2 = tf["ec2.tf"]
check("IMDSv2 is required", 'http_tokens   = "required"' in ec2)
check("the metadata hop limit is 1 (no container can reach the instance role)", "http_put_response_hop_limit = 1" in ec2)
check("the instance asks for a public IPv4 address", "associate_public_ip_address = true" in ec2)
check("there is no SSH key pair", "key_name" not in ec2)
check("the root volume is encrypted", "encrypted             = true" in ec2)
check("a new image or boot script never replaces the running host", "ignore_changes = [ami, user_data]" in ec2)
check("the Elastic IP is optional and attached to the instance", 'resource "aws_eip" "app"' in ec2 and 'resource "aws_eip_association" "app"' in ec2 and "count = var.use_elastic_ip" in ec2)
check("the instance gets its profile from one conditional: the existing profile when named, else the lab's own",
      "iam_instance_profile   = local.use_existing_profile ? data.aws_iam_instance_profile.existing[0].name : aws_iam_instance_profile.instance[0].name" in ec2)

print("== optional reuse of a pre-provisioned instance profile (default: create the lab's own)")
iam_src = tf["iam.tf"]
check("existing_instance_profile is a string that defaults to empty",
      re.search(r'variable "existing_instance_profile"\s*\{[^}]*type\s*=\s*string[^}]*\n\s*default\s*=\s*""', tf["variables.tf"], re.S) is not None)
check("existing_instance_profile is validated as a profile name or empty", 'var.existing_instance_profile == "" || can(regex(' in tf["variables.tf"])
check("the reuse switch is exactly: the variable is non-empty", 'use_existing_profile = var.existing_instance_profile != ""' in iam_src)
check("the existing profile is only READ (a data source, never a resource)",
      re.search(r'data "aws_iam_instance_profile" "existing" \{\s*count = local\.use_existing_profile \? 1 : 0\s*name\s*=\s*var\.existing_instance_profile\s*\}', iam_src) is not None
      and not re.search(r'resource "aws_iam_instance_profile" "existing"', alltf))
for rtype, rname in (("aws_iam_role", "instance"), ("aws_iam_role_policy_attachment", "ssm_core"), ("aws_iam_instance_profile", "instance")):
    body = re.search(r'resource "%s" "%s" \{(.*?)\n\}' % (rtype, rname), iam_src, re.S)
    check(f"{rtype}.{rname} is created only when no existing profile is named", body is not None and "count = local.use_existing_profile ? 0 : 1" in body.group(1))
check("the default path is unchanged: the lab's own role and profile keep their names", iam_src.count('name               = "${local.name}-instance"') == 1 and iam_src.count('name = "${local.name}-instance"') == 1)
check("the default path still attaches only AmazonSSMManagedInstanceCore", re.findall(r'policy_arn\s*=\s*"([^"]+)"', iam_src) == [re.findall(r'policy_arn\s*=\s*"([^"]+)"', iam_src)[0]] and "AmazonSSMManagedInstanceCore" in iam_src)
check("no IAM resource touches the existing role or profile (no policy, attachment or role reads it)",
      "data.aws_iam_instance_profile.existing" not in iam_src.replace('data "aws_iam_instance_profile" "existing"', "") and "aws_iam_role_policy" not in re.findall(r'^resource "([a-z0-9_]+)"', iam_src, re.M))
check("the reuse path adds no IAM write beyond the default path (iam.tf resources are the same three, all conditional)",
      re.findall(r'^resource "([a-z0-9_]+)"', iam_src, re.M) == ["aws_iam_role", "aws_iam_role_policy_attachment", "aws_iam_instance_profile"])
check("enable_cicd is still false by default and untouched by the reuse option", re.search(r'variable "enable_cicd"\s*\{[^}]*default\s*=\s*false', tf["variables.tf"], re.S) is not None and "existing_instance_profile" not in tf["github_oidc.tf"])

print("== identities")
iam = tf["iam.tf"]
check("the instance role has exactly one managed policy: AmazonSSMManagedInstanceCore", re.findall(r'policy_arn\s*=\s*"([^"]+)"', iam) == [re.findall(r'policy_arn\s*=\s*"([^"]+)"', iam)[0]] and "AmazonSSMManagedInstanceCore" in iam)
check("no inline policy on the instance role", "aws_iam_role_policy" not in re.findall(r'^resource "([a-z0-9_]+)"', iam, re.M))
check("no AdministratorAccess, PowerUser or wildcard action anywhere", not re.search(r"Administrator|PowerUser", alltf) and not re.search(r'actions\s*=\s*\[\s*"\*"', alltf) and not re.search(r'"[a-z0-9]+:\*"', alltf))
oidc = tf["github_oidc.tf"]
check("the deploy roles trust one exact subject each (StringEquals, no wildcard)", 'test     = "StringEquals"' in oidc and 'StringLike' not in oidc and 'token.actions.githubusercontent.com:sub' in oidc)
check("a role can be assumed only from its own Environment's subject", 'endswith(lookup(var.github_oidc_subjects, each.key, ""), ":environment:${each.key}")' in oidc)
deploy_policy = re.search(r'data "aws_iam_policy_document" "github_deploy" \{(.*?)\n\}\n', oidc, re.S).group(1)
policy_statements = re.findall(r'\n  statement \{(.*?)\n  \}', deploy_policy, re.S)
policy_actions = sorted(a for st in policy_statements for blk in re.findall(r'actions\s*=\s*\[(.*?)\]', st, re.S) for a in re.findall(r'"([^"]+)"', blk))
start = re.search(r'sid\s*=\s*"StartPortForwardingToTheLabInstance"(.*?)\n  \}', deploy_policy, re.S)
end_own = re.search(r'sid\s*=\s*"UseAndEndOwnSessions"(.*?)\n  \}', deploy_policy, re.S)
find = re.search(r'sid\s*=\s*"CheckTheInstanceIsOnline"(.*?)\n  \}', deploy_policy, re.S)
check("a deploy role has exactly these permissions: start a session, use and end its own, check the instance is online",
      policy_actions == ["ssm:DescribeInstanceInformation", "ssm:StartSession", "ssm:TerminateSession", "ssmmessages:OpenDataChannel"] and len(policy_statements) == 3, str(policy_actions))
check("it may start a session only on the lab instance, with the AWS port-forwarding document (no shell document, no other instance)",
      start is not None and 'actions = ["ssm:StartSession"]' in start.group(1) and "aws_instance.lab.arn" in start.group(1)
      and "document/AWS-StartPortForwardingSession" in start.group(1) and start.group(1).count("document/") == 1 and '"*"' not in start.group(1))
check("the document must also be allowed to the caller (ssm:SessionDocumentAccessCheck = true)", start is not None and 'variable = "ssm:SessionDocumentAccessCheck"' in start.group(1) and 'values   = ["true"]' in start.group(1))
check("it may use and end only its own sessions: the AWS-documented tag condition aws:ssmmessages:session-id == aws:userid, on session ARNs of this account and region",
      end_own is not None and 'variable = "ssm:resourceTag/aws:ssmmessages:session-id"' in end_own.group(1) and 'values   = ["&{aws:userid}"]' in end_own.group(1)
      and 'test     = "StringEquals"' in end_own.group(1) and ":session/*" in end_own.group(1)
      and "data.aws_caller_identity.current.account_id" in end_own.group(1) and "var.aws_region" in end_own.group(1) and 'resources = ["*"]' not in end_own.group(1))
check("no session ARN is built from aws:userid (a role session's id starts with the role session NAME, so that ARN would never match)", "session/&{aws:userid}" not in oidc and "session/${aws:userid}" not in oidc)
check("the only resource of * is the read-only instance-online check (IAM has no resource-level scope for it)",
      find is not None and 'actions   = ["ssm:DescribeInstanceInformation"]' in find.group(1) and 'resources = ["*"]' in find.group(1) and deploy_policy.count('resources = ["*"]') == 1 and deploy_policy.count('resources = ["*"]') == 1)
check("a deploy role can no longer send a command (no ssm:SendCommand anywhere in the identity files)", "ssm:SendCommand" not in oidc and "ssm:SendCommand" not in tf["iam.tf"])
check("the deploy role has no access to a secret, S3, EC2 or IAM", not re.search(r"secretsmanager|s3:|ec2:|iam:|ecr:|codebuild:|kms:", oidc.replace("sts:AssumeRoleWithWebIdentity", "")))
check("the OIDC session is one hour at most", "max_session_duration = 3600" in oidc)

print("== everything CI/CD is gated by enable_cicd (default false)")
check("enable_cicd defaults to false", re.search(r'variable "enable_cicd"\s*\{[^}]*default\s*=\s*false', tf["variables.tf"], re.S) is not None)
gated = ["aws_ssm_document", "aws_iam_role", "aws_iam_role_policy", "aws_iam_openid_connect_provider"]
for name in ("github_oidc.tf", "ssm_documents.tf"):
    for m in re.finditer(r'resource "(\w+)" "(\w+)" \{(.*?)\n\}', tf[name], re.S):
        rtype, rname, rbody = m.groups()
        if rtype == "aws_ssm_document":
            check(f"{rtype}.{rname} exists only when enable_cicd AND create_ssm_documents are true", "local.ssm_documents" in rbody and "local.cicd" not in rbody.replace("local.ssm_documents", ""), rbody[:80])
        elif rtype in gated:
            check(f"{rtype}.{rname} exists only when enable_cicd is true", "local.cicd" in rbody, rbody[:80])
check("create_ssm_documents defaults to false (the fallback documents are not created unless asked for)", re.search(r'variable "create_ssm_documents"\s*\{[^}]*default\s*=\s*false', tf["variables.tf"], re.S) is not None)
check("the documents need BOTH switches: local.ssm_documents = enable_cicd && create_ssm_documents", "ssm_documents = var.enable_cicd && var.create_ssm_documents" in tf["ssm_documents.tf"])
check("both document resources use only that gate", tf["ssm_documents.tf"].count("for_each = local.ssm_documents ? toset(local.environments) : toset([])") == 2)
check("no role, policy or workflow depends on a document (the roles work without them)", "aws_ssm_document" not in tf["github_oidc.tf"] and "aws_ssm_document" not in tf["iam.tf"])
check("the document outputs stay (empty maps when the documents are not created)", 'output "ssm_document_names"' in tf["outputs.tf"] and "for env, d in aws_ssm_document.deploy" in tf["outputs.tf"])

print("== state, secrets and what is committed")
versions = tf["versions.tf"]
check("remote state in S3, encrypted, with a lock file", 'backend "s3"' in versions and "encrypt      = true" in versions and "use_lockfile = true" in versions)
check("the state key is terraform/shopnest/terraform.tfstate", 'key          = "terraform/shopnest/terraform.tfstate"' in versions)
check("no bucket name is committed (it comes from an untracked backend.hcl)", not re.search(r"^\s*bucket\s*=", versions, re.M))
CANONICAL = "099720109477"  # Canonical's public AWS account ID, the owner of the Ubuntu AMIs: not this project's account
tracked_text = {p.name: p.read_text(encoding="utf-8").replace(CANONICAL, "canonical") for p in LAB.iterdir() if p.is_file() and p.name not in (".terraform.lock.hcl", "lab.tfvars", "backend.hcl")}  # the last two are the git-ignored local files that DO hold the account ID and the bucket name
check("no 12-digit AWS account ID in any lab file", not [n for n, t in tracked_text.items() if re.search(r"(?<![0-9a-f])[0-9]{12}(?![0-9a-f])", t)], str([n for n, t in tracked_text.items() if re.search(r"(?<![0-9a-f])[0-9]{12}(?![0-9a-f])", t)]))
check("no access key, secret key or private key in any lab file", not [n for n, t in tracked_text.items() if re.search(r"AKIA[0-9A-Z]{16}|BEGIN [A-Z ]*PRIVATE KEY|aws_secret_access_key", t)])
check("no public IPv4 address is written in any lab file", not [n for n, t in tracked_text.items() if re.search(r"\b(?!10\.|127\.|0\.0\.0\.0|169\.254\.)(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b", t)], str([n for n, t in tracked_text.items() if re.search(r"\b(?!10\.|127\.|0\.0\.0\.0|169\.254\.)(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b", t)]))
ignore = (LAB / ".gitignore").read_text(encoding="utf-8")
for pattern in ("backend.hcl", "*.tfvars", "*.tfplan", ".terraform/", "*.tfstate"):
    check(f".gitignore keeps {pattern} out of Git", any(line.strip() == pattern for line in ignore.splitlines()))
check("the VPC range has no default and no IPv4 literal is committed (the range comes from the untracked tfvars)", re.search(r'variable "vpc_cidr"\s*\{[^}]*\n\s*default\s*=', tf["variables.tf"], re.S) is None and "public_subnet_cidr" not in alltf)
check("the example files hold placeholders only", "<name of the existing lab state bucket>" in tracked_text["backend.hcl.example"] and "allowed_account_ids" in tracked_text["lab.tfvars.example"])
outputs = tf["outputs.tf"]
check("outputs carry no secret (instance id, region, public address, role ARNs, document names)", sorted(re.findall(r'^output "(\w+)"', outputs, re.M)) == ["deploy_role_arns", "instance_id", "public_ip", "region", "ssm_document_names"])

print("== the scripts the documents run")
shell = shutil.which("shellcheck")
if shell:
    for tpl in ("deploy.sh.tftpl", "rollback.sh.tftpl", "user_data.sh.tftpl"):
        text = (LAB / tpl).read_text(encoding="utf-8")
        # Terraform fills these in; shellcheck sees plain text.
        # (the swap size becomes a variable, not the number 1, so ShellCheck does not report the `[ 1 -gt 0 ]` test as constant)
        text = text.replace("${environment}", "staging").replace("${repository}", "owner/name").replace("${swap_size_gb}", "${SWAP_SIZE_GB}")
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / tpl.replace(".tftpl", "")
            f.write_text(text, encoding="utf-8", newline="\n")
            r = subprocess.run([shell, "--severity=warning", str(f)], capture_output=True, text=True)
            check(f"{tpl} passes ShellCheck", r.returncode == 0, r.stdout[-300:])
else:
    print("SKIP  ShellCheck is not installed here (CI has it)")
for tpl in ("deploy.sh.tftpl", "rollback.sh.tftpl"):
    text = (LAB / tpl).read_text(encoding="utf-8")
    check(f"{tpl} runs from a fetched commit and never uses a credential or SSH", "git fetch" in text and "BG_LAB=1" in text and not re.search(r"\bssh\b|AWS_SECRET|secretsmanager", text))
    check(f"{tpl} takes only validated parameters (no free-form command)", set(re.findall(r"\{\{ (\w+) \}\}", text)) <= {"Sha", "ImageRef", "FrontendRef", "Seed", "TargetSha", "CarrierSha"})
check("the rollback script never runs migrations", "migrate" not in (LAB / "rollback.sh.tftpl").read_text(encoding="utf-8").lower())

print()
print(f"lab checks: {passes} passed, {len(failures)} failed")
sys.exit(1 if failures else 0)
