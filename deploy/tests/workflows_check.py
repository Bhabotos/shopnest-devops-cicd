"""Static checks of the deployment workflows (.github/workflows/cd.yml and rollback.yml).

It reads the workflow files only. It does not run a workflow and contacts nothing. It replaces the old "SSH steps stay identical"
check: there is no SSH any more, so the rules are now that no SSH can come back, that credentials are never stored, that a failed
migration blocks the deployment, that production is never deployed, and that a rollback request is refused rather than ignored.
"""

import re
import sys
from pathlib import Path

import yaml

ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
WF = ROOT / ".github" / "workflows"
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


def load(name):
    text = (WF / name).read_text(encoding="utf-8")
    data = yaml.safe_load(text)
    return text, data


def uncommented(text):
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


cd_text, cd = load("cd.yml")
rb_text, rb = load("rollback.yml")
cd_code, rb_code = uncommented(cd_text), uncommented(rb_text)

FORBIDDEN_SSH = [
    r"\bssh\b", r"\bscp\b", r"ssh-keyscan", r"known_hosts", r"StrictHostKeyChecking", r"SSH_PRIVATE_KEY", r"SSH_KNOWN_HOSTS",
    r"SSH_SG_ID", r"EC2_HOST", r"EC2_USER", r"authorize-security-group", r"revoke-security-group", r"deploy_key",
]

for name, code in (("cd.yml", cd_code), ("rollback.yml", rb_code)):
    print(f"== {name}")
    check(f"{name}: no SSH of any kind can come back", not any(re.search(p, code) for p in FORBIDDEN_SSH),
          str([p for p in FORBIDDEN_SSH if re.search(p, code)]))
    check(f"{name}: no stored credential (no secrets, no access keys)", "secrets." not in code and "aws-access-key-id" not in code and "aws-secret-access-key" not in code and "AWS_SECRET_ACCESS_KEY" not in code)
    check(f"{name}: nothing is deployed to production", "environment: production" not in code and "--env production" not in code)

for name, data, code in (("cd.yml", cd, cd_code), ("rollback.yml", rb, rb_code)):
    print(f"== {name}: permissions and pinning")
    check(f"{name}: no default token permissions", data.get("permissions") == {})
    uses = re.findall(r"^\s*-?\s*uses:\s*(\S+)", code, re.M)
    check(f"{name}: every action is pinned to a full commit SHA", all(re.match(r"^[\w.-]+/[\w.-]+@[0-9a-f]{40}$", u) for u in uses), str(uses))
    token_jobs = sorted(j for j, spec in data["jobs"].items() if (spec.get("permissions") or {}).get("id-token") == "write")
    check(f"{name}: id-token: write only on the job that deploys", token_jobs == (["deploy-staging"] if name == "cd.yml" else ["rollback"]), str(token_jobs))
    for job, spec in data["jobs"].items():
        steps = spec.get("steps", [])
        runs = [s.get("run", "") for s in steps]
        check(f"{name}: job {job}: no expression is expanded inside a script (everything goes through env)", not any("${{" in r for r in runs), str([r[:60] for r in runs if '${{' in r]))
    aws_jobs = [j for j, spec in data["jobs"].items() if any("configure-aws-credentials" in str(s.get("uses", "")) for s in spec.get("steps", []))]
    check(f"{name}: AWS access comes only from the OIDC action, in the deploying job", aws_jobs == token_jobs, str(aws_jobs))
    check(f"{name}: the OIDC session is short (one hour at most)", re.search(r"role-duration-seconds:\s*3600\b", code) is not None)

print("== cd.yml: the order of a deploy, and a failed migration blocks it")
gate = cd["jobs"]["gate"]
check("the gate needs CD_ENABLED to be true", "vars.CD_ENABLED == 'true'" in str(gate["if"]))
check("the gate needs a successful CI run on main", "conclusion == 'success'" in str(gate["if"]) and "head_branch == 'main'" in str(gate["if"]))
check("every later job depends on the gate", all("gate" in (j.get("needs") if isinstance(j.get("needs"), list) else [j.get("needs")]) or n in ("gate", "production-not-deployed") for n, j in cd["jobs"].items()))
steps = cd["jobs"]["deploy-staging"]["steps"]
def index_of(fragment):
    for i, s in enumerate(steps):
        if fragment in (s.get("run", "") + str(s.get("uses", ""))):
            return i
    return -1
order = [index_of("push-image.sh"), index_of("run-codebuild.sh"), index_of("aws s3 cp upload/bundle.tar.gz"), index_of("run-ssm-command.sh")]
check("image push, then migrations, then upload, then deploy, in that order", all(i >= 0 for i in order) and order == sorted(order), str(order))
migrate = steps[order[1]]
check("the migration step cannot be ignored (no continue-on-error)", not migrate.get("continue-on-error") and not any(s.get("continue-on-error") for s in steps[: order[3] + 1]))
check("no step between the migration and the deploy can skip it (no `if: always()` or `failure()` before the deploy)", not any("always()" in str(s.get("if", "")) or "failure()" in str(s.get("if", "")) for s in steps[: order[3] + 1]))
check("the deploy uses the image DIGEST from the push step", "steps.image.outputs.image_ref" in str(steps[order[3]].get("env", {})) and "steps.image.outputs.image_ref" in str(migrate.get("env", {})))
check("the deploy sends the bundle's SHA-256 from the package job", "BundleSha256=" in cd_code and "needs.package.outputs.bundle_sha256" in cd_code)
check("the bundle is checked against the package job's hash before AWS is touched", index_of("sha256sum --check") != -1 and index_of("sha256sum --check") < index_of("configure-aws-credentials"))
check("exit codes 1 and 3 are reported as such", "(exit 1)" in cd_code and "(exit 3)" in cd_code and "exit \"$rc\"" in cd_code)
check("the deploy environment is staging", cd["jobs"]["deploy-staging"].get("environment") == "staging")
check("the deploys never overlap", cd["jobs"]["deploy-staging"]["concurrency"]["group"] == "deploy-staging" and cd["jobs"]["deploy-staging"]["concurrency"]["cancel-in-progress"] is False)
check("the production note job writes a notice only (no environment, no permissions, no AWS)",
      cd["jobs"]["production-not-deployed"].get("environment") is None and cd["jobs"]["production-not-deployed"].get("permissions") == {} and "aws" not in str(cd["jobs"]["production-not-deployed"]).lower().replace("workflow", ""))

print("== rollback.yml: it fails closed, and it never touches the schema")
guard = rb["jobs"]["guard"]
guard_run = guard["steps"][0]["run"]
check("a production request is refused with an error", 'TARGET_ENV" = "production"' in guard_run and "exit 1" in guard_run)
check("a request while CD is disabled is refused, not skipped", 'CD_ENABLED" != "true"' in guard_run and "never silently ignored" in guard_run and "if" not in guard)
check("a request from any ref but main is refused", "refs/heads/main" in guard_run)
check("the guard has no permissions and checks nothing out", guard.get("permissions") == {} and not any("checkout" in str(s.get("uses", "")) for s in guard["steps"]))
check("validation waits for the guard, and the rollback waits for validation", rb["jobs"]["validate"]["needs"] == "guard" and rb["jobs"]["rollback"]["needs"] == "validate")
check("the rollback is for staging only", rb["jobs"]["rollback"].get("environment") == "staging")
check("a rollback never starts a migration or CodeBuild", not re.search(r"(?i)codebuild|migrat(?!ions)|run-codebuild", rb_code.replace("never runs migrations", "").replace("NEVER runs migrations", "").replace("no migrations", "").replace("never run migrations", "").replace("a rollback never runs migrations", "")), "")
check("the carrier bundle's key is derived from its own content (it cannot overwrite a release)", 'hash:0:40' in rb_code or "hash:0:40}" in rb_code)
check("it uses the rollback document, not the deploy document", "SSM_ROLLBACK_DOCUMENT" in rb_code and "SSM_DEPLOY_DOCUMENT" not in rb_code)
check("it shares the deploy concurrency group", rb["jobs"]["rollback"]["concurrency"]["group"] == "deploy-staging")
check("the summary says the schema was not changed", "was NOT changed" in rb_code)

print("== the contract with the SSM documents (Terraform allowedPattern vs what the workflows send)")
ssm_tf = (ROOT / "infra" / "terraform" / "ssm_documents.tf").read_text(encoding="utf-8")


def hcl_pattern(name):
    """The regex a Terraform local builds, with the project's default variable values substituted."""
    raw = re.search(r'%s\s*=\s*"(.*)"\s*$' % name, ssm_tf, re.M).group(1)
    values = {"var.environment": "staging", "var.aws_region": "ap-south-1", "var.project": "shopnest", "local.bundle_prefix": "deploy/staging/"}

    def replace_call(m):  # ${replace(<value>, ".", "\.")}: the value with its dots escaped
        return values[m.group(1)].replace(".", r"\.")

    # Terraform spells the second argument  "\\."  (two backslashes, a dot): built from chr(92) so no backslash counting is needed.
    escaped_dot_argument = '"' + chr(92) * 2 + '."'
    raw = re.sub(r'\$\{replace\(([a-z_.]+), "\.", ' + re.escape(escaped_dot_argument) + r'\)\}', replace_call, raw)
    raw = re.sub(r"\$\{([a-z_.]+)\}", lambda m: values[m.group(1)], raw)
    return raw.replace("\\\\", "\\")


sha = "a" * 40
digest = "c" * 64
good = {
    "sha": (hcl_pattern("sha_pattern"), sha),
    "sha256": (hcl_pattern("sha256_pattern"), "d" * 64),
    "bundle key (release)": (hcl_pattern("bundle_key_pattern"), f"deploy/staging/{sha}/bundle.tar.gz"),
    "bundle key (carrier, content-addressed)": (hcl_pattern("bundle_key_pattern"), f"deploy/staging/{'e' * 40}/bundle.tar.gz"),
    "image ref": (hcl_pattern("image_ref_pattern"), f"111122223333.dkr.ecr.ap-south-1.amazonaws.com/shopnest/staging/backend@sha256:{digest}"),
}
for label, (pattern, value) in good.items():
    check(f"a value the workflows send matches the document's pattern: {label}", re.fullmatch(pattern, value) is not None, pattern)
bad = {
    "a tag instead of a digest": (hcl_pattern("image_ref_pattern"), "111122223333.dkr.ecr.ap-south-1.amazonaws.com/shopnest/staging/backend:latest"),
    "another region": (hcl_pattern("image_ref_pattern"), f"111122223333.dkr.ecr.us-east-1.amazonaws.com/shopnest/staging/backend@sha256:{digest}"),
    "another environment's repository": (hcl_pattern("image_ref_pattern"), f"111122223333.dkr.ecr.ap-south-1.amazonaws.com/shopnest/production/backend@sha256:{digest}"),
    "another registry host": (hcl_pattern("image_ref_pattern"), f"evil.example.com/shopnest/staging/backend@sha256:{digest}"),
    "a bundle key for production": (hcl_pattern("bundle_key_pattern"), f"deploy/production/{sha}/bundle.tar.gz"),
    "a bundle key with another file name": (hcl_pattern("bundle_key_pattern"), f"deploy/staging/{sha}/other.tar.gz"),
    "a bundle key with a path trick": (hcl_pattern("bundle_key_pattern"), f"deploy/staging/{sha}/../x/bundle.tar.gz"),
    "a digest that is not hexadecimal": (hcl_pattern("image_ref_pattern"), "111122223333.dkr.ecr.ap-south-1.amazonaws.com/shopnest/staging/backend@sha256:" + "z" * 64),
    "a digest that is too short": (hcl_pattern("image_ref_pattern"), "111122223333.dkr.ecr.ap-south-1.amazonaws.com/shopnest/staging/backend@sha256:" + "c" * 63),
    "a digest followed by extra text": (hcl_pattern("image_ref_pattern"), f"111122223333.dkr.ecr.ap-south-1.amazonaws.com/shopnest/staging/backend@sha256:{digest};id"),
    "a short sha": (hcl_pattern("sha_pattern"), "abc123"),
    "an upper-case hash": (hcl_pattern("sha256_pattern"), "D" * 64),
}
for label, (pattern, value) in bad.items():
    check(f"the document refuses: {label}", re.fullmatch(pattern, value) is None, pattern)
doc_params = {"Sha", "ImageRef", "BundleKey", "BundleSha256", "TargetSha", "CarrierSha", "CarrierBundleKey", "CarrierBundleSha256"}
check("the parameter names the workflows send are exactly the documents' parameters",
      set(re.findall(r'"(Sha|ImageRef|BundleKey|BundleSha256)=', cd_code)) == {"Sha", "ImageRef", "BundleKey", "BundleSha256"}
      and set(re.findall(r'"(TargetSha|CarrierSha|CarrierBundleKey|CarrierBundleSha256)=', rb_code)) == {"TargetSha", "CarrierSha", "CarrierBundleKey", "CarrierBundleSha256"}
      and set(re.findall(r"^      (\w+) = \{$", ssm_tf, re.M)) >= doc_params)
check("the carrier id the rollback workflow sends is 40 hex digits (a slice of a SHA-256)", "${hash:0:40}" in rb_code)
check("the bundle key the deploy workflow uploads is the key it sends", cd_code.count("deploy/staging/${RELEASE_SHA}/bundle.tar.gz") == 2)
check("the rollback uploads the carrier to the key it sends", rb_code.count("deploy/staging/${CARRIER_ID}/bundle.tar.gz") == 2)

print()
print(f"workflow checks: {passes} passed, {len(failures)} failed")
sys.exit(1 if failures else 0)
