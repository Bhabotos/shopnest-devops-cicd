"""Static checks of the CI/CD Terraform (infra/terraform): who may do what, and that everything new is gated.

It reads the .tf SOURCE only. It never runs Terraform, never contacts AWS and needs no credentials. It cannot prove what AWS
will accept (that needs a real plan and the IAM policy simulator, after approval); it makes the architecture's rules fail loudly if
someone later widens a permission by accident.
"""

import re
import sys
from pathlib import Path

TF = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("infra/terraform")
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


def read(name):
    return (TF / name).read_text(encoding="utf-8")


def strip_comments(text):
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


def blocks(text, kinds=("resource", "data")):
    """Top-level blocks: {(kind, type, name): body}. Brace matching ignores braces inside quoted strings."""
    found = {}
    pattern = re.compile(r'^(%s) "([^"]+)" "([^"]+)" \{' % "|".join(kinds), re.M)
    for m in pattern.finditer(text):
        depth, i, in_str, escape = 1, m.end(), False, False
        while i < len(text) and depth:
            c = text[i]
            if in_str:
                if escape:
                    escape = False
                elif c == "\\":
                    escape = True
                elif c == '"':
                    in_str = False
            else:
                if c == '"':
                    in_str = True
                elif c == "{":
                    depth += 1
                elif c == "}":
                    depth -= 1
            i += 1
        found[(m.group(1), m.group(2), m.group(3))] = text[m.end():i - 1]
    return found


def statements(body):
    """The statement { ... } blocks of an IAM policy document body: list of (sid, text)."""
    out = []
    for m in re.finditer(r"\bstatement \{", body):
        depth, i = 1, m.end()
        while i < len(body) and depth:
            depth += {"{": 1, "}": -1}.get(body[i], 0)
            i += 1
        text = body[m.end():i - 1]
        sid = re.search(r'sid\s*=\s*"([^"]+)"', text)
        out.append((sid.group(1) if sid else None, text))
    return out


def actions_of(text):
    m = re.search(r"actions\s*=\s*\[(.*?)\]", text, re.S)
    return re.findall(r'"([^"]+)"', m.group(1)) if m else []


new_files = ["github_oidc.tf", "codebuild.tf", "ssm_documents.tf"]
oidc = strip_comments(read("github_oidc.tf"))
cb = strip_comments(read("codebuild.tf"))
ssm = strip_comments(read("ssm_documents.tf"))
iam = strip_comments(read("iam.tf"))
variables = strip_comments(read("variables.tf"))
outputs = strip_comments(read("outputs.tf"))

print("== gating: nothing new exists unless enable_cicd is true")
check("enable_cicd defaults to false", re.search(r'variable "enable_cicd" \{.*?default\s*=\s*false', variables, re.S) is not None)
for name, text in (("github_oidc.tf", oidc), ("codebuild.tf", cb), ("ssm_documents.tf", ssm)):
    for key, body in blocks(text).items():
        check(f"{name}: {key[0]} {key[1]}.{key[2]} is gated by count = local.cicd", re.search(r"count\s*=\s*local\.cicd\b", body) is not None)
check("the CI/CD outputs are null when disabled (one(...) over a counted resource)",
      all("one(" in v for v in re.findall(r'output "(?:github_deploy_role_arn|migrator_project_name|bootstrap_project_name|bootstrap_operator_role_arn|ssm_deploy_document_name|ssm_rollback_document_name)" \{.*?value\s*=\s*(.*?)\n', outputs, re.S)))

print("== the instance role never sees the owner or master secret")
check("iam.tf does not mention the owner secret", "owner" not in iam.lower() and "db_owner" not in iam)
check("iam.tf does not mention a master secret", "master" not in iam.lower())
check("iam.tf only reads the secrets named in db_secret_names", "var.db_secret_names" in iam and "db_owner_secret_name" not in iam)
check("the owner secret name may not be listed in db_secret_names (validation)", "!contains(var.db_secret_names, var.db_owner_secret_name)" in variables)

print("== the GitHub deploy role")
docs = blocks(oidc, ("data",))
deploy = docs[("data", "aws_iam_policy_document", "github_deploy")]
stmts = statements(deploy)
all_actions = sorted({a for _, t in stmts for a in actions_of(t)})
check("it has no secret, database, IAM, EC2 or key-decrypt permission",
      not any(a.startswith(p) for a in all_actions for p in ("secretsmanager:", "rds", "iam:", "ec2:", "kms:Decrypt", "sts:", "ssm:StartSession", "ssm:StartAutomation")), str(all_actions))
check("its S3 permission is PutObject only (no read, list or delete)", [a for a in all_actions if a.startswith("s3:")] == ["s3:PutObject"])
check("its SSM permissions are exactly the four it needs",
      sorted(a for a in all_actions if a.startswith("ssm:")) == ["ssm:DescribeInstanceInformation", "ssm:GetCommandInvocation", "ssm:ListCommandInvocations", "ssm:SendCommand"])
check("its CodeBuild permissions are StartBuild and BatchGetBuilds only",
      sorted(a for a in all_actions if a.startswith("codebuild:")) == ["codebuild:BatchGetBuilds", "codebuild:StartBuild"])
check("it can start the migrator and never refers to the bootstrap project", "migrator" in deploy and "bootstrap" not in deploy)
check("no action is a wildcard", not any(a == "*" or a.endswith(":*") for a in all_actions))
wild = [sid for sid, t in stmts if re.search(r'resources\s*=\s*\["\*"\]', t)]
check("a resource of * appears only where AWS gives no resource-level scope", sorted(wild) == ["EcrLogin", "ReadCommandResults"], str(wild))
send = [t for sid, t in statements(deploy) if sid == "SendTheTwoFixedDocuments"][0]
check("SendCommand targets the two documents and the application instances only",
      "aws_ssm_document.deploy[0].arn" in send and "aws_ssm_document.rollback[0].arn" in send and "aws_instance.app" in send and '"*"' not in send)
check("the bundle upload is limited to this environment's prefix", "local.bundle_prefix" in deploy and "PutObject" in deploy)
trust = docs[("data", "aws_iam_policy_document", "github_trust")]
check("trust is OIDC web identity only", actions_of(trust) == ["sts:AssumeRoleWithWebIdentity"] and 'type        = "Federated"' in trust)
check("trust pins the audience and the subject with StringEquals", trust.count('test     = "StringEquals"') == 2 and "aud" in trust and ":sub" in trust)
check("trust never uses StringLike or a wildcard principal", "StringLike" not in trust and '"*"' not in trust)

print("== the CodeBuild roles")
cdocs = blocks(cb, ("data",))
migrator = cdocs[("data", "aws_iam_policy_document", "migrator")]
bootstrap = cdocs[("data", "aws_iam_policy_document", "bootstrap")]
operator = cdocs[("data", "aws_iam_policy_document", "operator")]
check("the migrator reads the owner secret and nothing else",
      "local.db_owner_secret_id" in migrator and "master" not in migrator and "db_app_secret_id" not in migrator and "master_user_secret" not in migrator)
check("the migrator's only secret action is GetSecretValue", sorted({a for _, t in statements(migrator) for a in actions_of(t) if a.startswith("secretsmanager:")}) == ["secretsmanager:GetSecretValue"])
check("the migrator cannot touch S3, SSM or RDS", not re.search(r'"(s3|ssm|rds[-a-z]*):', migrator))
check("only the bootstrap can read the RDS master secret", "master_user_secret" in bootstrap and "master_user_secret" not in migrator and "master_user_secret" not in oidc and "master_user_secret" not in iam)
check("the bootstrap reads exactly three secrets (master, owner, app)", bootstrap.count("secret:${local.db_") == 2 and "master_user_secret" in bootstrap)
check("the operator can only start and inspect the bootstrap project", sorted({a for _, t in statements(operator) for a in actions_of(t) if a.startswith("codebuild:")}) == ["codebuild:BatchGetBuilds", "codebuild:StartBuild"] and "aws_codebuild_project.bootstrap[0].arn" in operator and "migrator" not in operator)
op_trust = cdocs[("data", "aws_iam_policy_document", "operator_trust")]
check("the operator role requires MFA", 'variable = "aws:MultiFactorAuthPresent"' in op_trust and 'values   = ["true"]' in op_trust)
check("the operator role trusts only the listed people (not a service, not *)", "var.operator_principal_arns" in op_trust and '"*"' not in op_trust and "Service" not in op_trust)
check("CodeBuild may attach its network interface only in the application subnets", 'variable = "ec2:Subnet"' in cb and "aws_subnet.app" in cb and "ec2:AuthorizedService" in cb)
check("every CodeBuild project is started in private subnets, one build at a time",
      cb.count("concurrent_build_limit = 1") == 2 and cb.count("vpc_config {") == 2 and "aws_subnet.app" in cb)
check("the projects do not run privileged", cb.count("privileged_mode             = false") == 2)
check("BOOTSTRAP_CONFIRM is not preset (the operator must supply it)", 'name  = "BOOTSTRAP_CONFIRM"' not in cb)
check("the buildspecs are the repository files", "deploy/codebuild/migrate.buildspec.yml" in cb and "deploy/codebuild/bootstrap.buildspec.yml" in cb)
check("the database security group accepts the two jobs only through their own groups", cb.count("referenced_security_group_id = aws_security_group.migrator[0].id") == 1 and cb.count("referenced_security_group_id = aws_security_group.bootstrap[0].id") == 1 and "0.0.0.0/0" in cb)
check("the jobs' only internet egress is HTTPS", cb.count('from_port         = 443') == 2 and cb.count('cidr_ipv4         = "0.0.0.0/0"') == 2)

print("== no policy anywhere in the new files has a wildcard ACTION, and a wildcard RESOURCE only where AWS has no resource-level scope")
for name, text in (("github_oidc.tf", oidc), ("codebuild.tf", cb)):
    for (_, _, doc_name), body in blocks(text, ("data",)).items():
        if not doc_name.startswith(("github_deploy", "migrator", "bootstrap", "operator", "codebuild_")):
            continue
        doc_actions = [a for _, t in statements(body) for a in actions_of(t)]
        bad = [a for a in doc_actions if a == "*" or a.endswith(":*")]
        check(f"{name}: {doc_name}: no wildcard action", not bad, str(bad))
allowed_star = {"EcrLogin", "ReadCommandResults", "NetworkInterfacesForCodeBuild"}
for name, text in (("github_oidc.tf", oidc), ("codebuild.tf", cb)):
    for (_, _, doc_name), body in blocks(text, ("data",)).items():
        star = [sid for sid, t in statements(body) if re.search(r'resources\s*=\s*\["\*"\]', t)]
        check(f"{name}: {doc_name}: a resource of * only in {sorted(allowed_star)}", set(star) <= allowed_star, str(star))

print("== the SSM documents: fixed commands, validated parameters, hash verified before extraction")
check("only two documents exist", len([k for k in blocks(ssm, ('resource',)) if k[1] == "aws_ssm_document"]) == 2)
check("every parameter has an allowedPattern", ssm.count('type           = "String"') == ssm.count("allowedPattern = "))
check("no generic run-command document is used", "AWS-RunShellScript" not in ssm and "AWS-RunRemoteScript" not in ssm and "AWS-RunPowerShellScript" not in ssm)
check("the image must be a digest of this environment's repository", "@sha256:[0-9a-f]{64}" in ssm and "${var.environment}/backend@sha256" in ssm)
check("the bundle key is confined to this environment's prefix", "local.bundle_prefix" in ssm and "bundle\\\\.tar\\\\.gz$" in ssm)
fetch = re.search(r"fetch_and_verify = <<-EOT\n(.*?)\n\s*EOT", ssm, re.S).group(1)
check("the SHA-256 is verified before anything is extracted", 0 <= fetch.find("sha256sum --check --strict") < fetch.find("tar -xzf"))
check("extraction does not restore foreign ownership", "--no-same-owner" in fetch)
check("both scripts fail on any error and pass the exit code through", ssm.count("set -euo pipefail") == 2 and ssm.count('exit "$rc"') == 2)
check("the rollback document never runs a migration", "migrate" not in ssm.split("rollback_script")[1] and "codebuild" not in ssm)
check("no SSH is involved", not re.search(r"\bssh\b|scp |authorize-security-group", ssm))
check("no secret value or credential is built into a document", not re.search(r"(?i)password|secret_key|aws_access|token=", ssm))

print()
print(f"terraform-iam checks: {passes} passed, {len(failures)} failed")
sys.exit(1 if failures else 0)
