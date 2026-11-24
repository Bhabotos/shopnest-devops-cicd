"""Static checks of the deployment workflows (.github/workflows/cd.yml and rollback.yml) for the lab deployment.

It reads the workflow files and the deploy scripts only (deploy/ci/ssh-deploy.sh, install-ssm-plugin.sh, deploy/host/*.sh). It does not
run a workflow and contacts nothing. The rules are: the deploy goes over SSH through an SSM tunnel and never weakens host key checking,
the only secret is the SSH key of the job's own Environment (and it is never put on a command line or in a script body), AWS
credentials are never stored, images are published with the run's own token and used by digest, the deploy jobs run in the right
order and the right Environment, production is deployed only by the one job bound to the production Environment (so GitHub's
approval gate applies), a rollback request is refused rather than ignored, and what the workflows send matches what the wrappers on
the host accept.
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


def needs_of(job):
    needs = job.get("needs") or []
    return needs if isinstance(needs, list) else [needs]


def script(path):
    return (ROOT / path).read_text(encoding="utf-8")


cd_text, cd = load("cd.yml")
rb_text, rb = load("rollback.yml")
cd_code, rb_code = uncommented(cd_text), uncommented(rb_text)
ssh_deploy = script("deploy/ci/ssh-deploy.sh")
ssh_code = uncommented(ssh_deploy)
plugin = script("deploy/ci/install-ssm-plugin.sh")
plugin_code = uncommented(plugin)
wrapper = script("deploy/host/shopnest-release.sh")
entry = script("deploy/host/shopnest-ssh-entry.sh")
setup = script("deploy/host/setup-deploy-host.sh")

# A direct call of ssh/scp (not the name of our script): the workflows may only reach SSH through deploy/ci/ssh-deploy.sh.
DIRECT_SSH = r"(^|[\s;&|(`])(ssh|scp|sftp|ssh-keyscan|ssh-add|ssh-agent)(\s|$)"
WEAKENED_HOST_KEY_CHECKING = [r"StrictHostKeyChecking[= ]+(no|off|accept-new|ask)", r"UserKnownHostsFile[= ]+/dev/null", r"ssh-keyscan", r"-o\s+CheckHostIP=no"]
OPEN_SSH_TO_INTERNET = [r"authorize-security-group", r"revoke-security-group", r"EC2_HOST", r"EC2_USER", r"SSH_SG_ID", r"SSH_KNOWN_HOSTS"]
OLD_AWS_PATH = [r"\becr\b", r"codebuild", r"aws s3 ", r"ARTIFACT_BUCKET", r"MIGRATOR_PROJECT", r"STAGING_INSTANCE_ID", r"push-image\.sh", r"run-codebuild\.sh"]
RETIRED_SSM_COMMAND_PATH = [r"run-ssm-command\.sh", r"send-command", r"SSM_DEPLOY_DOCUMENT", r"SSM_ROLLBACK_DOCUMENT"]

for name, code in (("cd.yml", cd_code), ("rollback.yml", rb_code)):
    print(f"== {name}")
    check(f"{name}: SSH is reached only through deploy/ci/ssh-deploy.sh (no ssh, scp or key scanning in the workflow)", not re.search(DIRECT_SSH, code, re.M), "")
    check(f"{name}: host key checking is never weakened", not any(re.search(p, code) for p in WEAKENED_HOST_KEY_CHECKING), str([p for p in WEAKENED_HOST_KEY_CHECKING if re.search(p, code)]))
    check(f"{name}: no security group is ever opened for SSH", not any(re.search(p, code) for p in OPEN_SSH_TO_INTERNET), str([p for p in OPEN_SSH_TO_INTERNET if re.search(p, code)]))
    check(f"{name}: no stored AWS credential (no access keys)", "aws-access-key-id" not in code and "aws-secret-access-key" not in code and "AWS_SECRET_ACCESS_KEY" not in code and "AWS_ACCESS_KEY_ID" not in code)
    check(f"{name}: nothing of the retired ECR / CodeBuild / S3 path is used", not any(re.search(p, code, re.I) for p in OLD_AWS_PATH),
          str([p for p in OLD_AWS_PATH if re.search(p, code, re.I)]))
    check(f"{name}: nothing of the retired SSM Run Command path is used", not any(re.search(p, code) for p in RETIRED_SSM_COMMAND_PATH),
          str([p for p in RETIRED_SSM_COMMAND_PATH if re.search(p, code)]))
    check(f"{name}: the only secret is DEPLOY_SSH_KEY", sorted(set(re.findall(r"secrets\.(\w+)", code))) == ["DEPLOY_SSH_KEY"], str(set(re.findall(r"secrets\.(\w+)", code))))
    check(f"{name}: SSH_HOST_KEY (the pinned public host key) is a variable, not a secret", "vars.SSH_HOST_KEY" in code and "secrets.SSH_HOST_KEY" not in code)

for name, data, code in (("cd.yml", cd, cd_code), ("rollback.yml", rb, rb_code)):
    print(f"== {name}: permissions, pinning and the secret")
    check(f"{name}: no default token permissions", data.get("permissions") == {})
    uses = re.findall(r"^\s*-?\s*uses:\s*(\S+)", code, re.M)
    check(f"{name}: every action is pinned to a full commit SHA", all(re.match(r"^[\w.-]+/[\w.-]+@[0-9a-f]{40}$", u) for u in uses), str(uses))
    token_jobs = sorted(j for j, spec in data["jobs"].items() if (spec.get("permissions") or {}).get("id-token") == "write")
    expected = ["deploy-production", "deploy-staging"] if name == "cd.yml" else ["rollback"]
    check(f"{name}: id-token: write only on the jobs that deploy", token_jobs == expected, str(token_jobs))
    for job, spec in data["jobs"].items():
        steps = spec.get("steps", [])
        runs = [s.get("run", "") for s in steps]
        check(f"{name}: job {job}: no expression is expanded inside a script (everything goes through env)", not any("${{" in r for r in runs), str([r[:60] for r in runs if '${{' in r]))
        check(f"{name}: job {job}: no shell tracing (set -x) that could print a secret", not any(re.search(r"set\s+-[a-z]*x", r) for r in runs))
    aws_jobs = sorted(j for j, spec in data["jobs"].items() if any("configure-aws-credentials" in str(s.get("uses", "")) for s in spec.get("steps", [])))
    check(f"{name}: AWS access comes only from the OIDC action, in the deploying jobs", aws_jobs == token_jobs, str(aws_jobs))
    check(f"{name}: the OIDC session is short (one hour at most)", re.search(r"role-duration-seconds:\s*3600\b", code) is not None)
    group_jobs = list(token_jobs)
    check(f"{name}: every deploying job is in a per-environment lab concurrency group and never cancels a running deploy",
          all(str(data["jobs"][j]["concurrency"]["group"]).startswith("deploy-lab-") and data["jobs"][j]["concurrency"]["cancel-in-progress"] is False for j in group_jobs))
    check(f"{name}: no job uses the old single shared group (a production job waiting for its reviewer would block every staging deploy)",
          re.search(r"group:\s*deploy-lab\s*$", code, re.M) is None)
    for job in token_jobs:
        spec = data["jobs"][job]
        key_steps = [s for s in spec["steps"] if "secrets.DEPLOY_SSH_KEY" in str(s.get("env", ""))]
        check(f"{name}: job {job}: the SSH key reaches exactly one step, as an environment variable (never an argument)",
              len(key_steps) == 1 and "DEPLOY_SSH_KEY" in key_steps[0]["env"] and "$DEPLOY_SSH_KEY" not in key_steps[0].get("run", ""), str([s.get("name") for s in key_steps]))
        check(f"{name}: job {job}: the key is not in the job-level environment (other steps never see it)", "DEPLOY_SSH_KEY" not in str(spec.get("env", {})))
        check(f"{name}: job {job}: the pinned host key is a job variable and is checked before AWS is touched",
              "SSH_HOST_KEY" in spec.get("env", {}) and "SSH_HOST_KEY" in "\n".join(s.get("run", "") for s in spec["steps"][:3]))
        names = [s.get("name", "") for s in spec["steps"]]
        cleanup = [s for s in spec["steps"] if "AWS-StartPortForwardingSession" in s.get("run", "")]
        deploy_idx = [i for i, s in enumerate(spec["steps"]) if "ssh-deploy.sh" in s.get("run", "")]
        check(f"{name}: job {job}: a final always() step kills any tunnel that is left",
              len(cleanup) == 1 and "always()" in str(cleanup[0].get("if", "")) and len(deploy_idx) == 1 and spec["steps"].index(cleanup[0]) > deploy_idx[0], str(names))
        plugin_steps = [i for i, s in enumerate(spec["steps"]) if "install-ssm-plugin.sh" in s.get("run", "")]
        creds_step = [i for i, s in enumerate(spec["steps"]) if "configure-aws-credentials" in str(s.get("uses", ""))]
        check(f"{name}: job {job}: the pinned plugin is installed BEFORE the AWS credentials exist, then the SSH deploy, in that order",
              len(plugin_steps) == 1 and len(creds_step) == 1 and len(deploy_idx) == 1 and plugin_steps[0] < creds_step[0] < deploy_idx[0], str((plugin_steps, creds_step, deploy_idx)))
        cred_with = spec["steps"][creds_step[0]].get("with", {}) if len(creds_step) == 1 else {}
        check(f"{name}: job {job}: the AWS account id is masked in the logs", cred_with.get("mask-aws-account-id") is True, str(cred_with))

print("== cd.yml: the order of a deploy")
gate = cd["jobs"]["gate"]
check("the gate needs CD_ENABLED to be true", "vars.CD_ENABLED == 'true'" in str(gate["if"]))
check("the gate needs a successful CI run on main", "conclusion == 'success'" in str(gate["if"]) and "head_branch == 'main'" in str(gate["if"]))
check("every later job depends on the gate", all("gate" in needs_of(j) or n == "gate" for n, j in cd["jobs"].items()))
check("the jobs are exactly gate, publish-images, deploy-staging, deploy-production", sorted(cd["jobs"]) == ["deploy-production", "deploy-staging", "gate", "publish-images"], str(sorted(cd["jobs"])))

pub = cd["jobs"]["publish-images"]
check("publish-images needs the gate", needs_of(pub) == ["gate"])
check("publish-images is the only job that can write packages", [n for n, j in cd["jobs"].items() if (j.get("permissions") or {}).get("packages") == "write"] == ["publish-images"])
check("publish-images has no id-token (it cannot obtain AWS credentials)", "id-token" not in (pub.get("permissions") or {}))
check("publish-images never sees the SSH key", "DEPLOY_SSH_KEY" not in str(pub))
pub_runs = "\n".join(s.get("run", "") for s in pub["steps"])
check("images are pushed to GHCR with the run's own token, over stdin (no stored credential)",
      "docker login ghcr.io" in pub_runs and "--password-stdin" in pub_runs and "github.token" in str(pub["steps"]))
check("both images are tagged with the commit SHA and labelled with it", 'docker build' in pub_runs and "org.opencontainers.image.revision=${RELEASE_SHA}" in pub_runs and '"${image}:${RELEASE_SHA}"' in pub_runs)
check("the digest of each pushed image is read back (the deploy never uses a tag)", "RepoDigests" in pub_runs and "@sha256:" in pub_runs)
check("the packages are proven pullable without a credential before any deploy", "cannot be pulled anonymously" in pub_runs and "ghcr.io/token" in pub_runs)
check("publish-images exports both digests", set(pub.get("outputs", {})) == {"backend_ref", "frontend_ref"})

for name, env_name in (("deploy-staging", "staging"), ("deploy-production", "production")):
    job = cd["jobs"][name]
    steps = job["steps"]
    runs = "\n".join(s.get("run", "") for s in steps)
    print(f"== cd.yml: {name}")
    check(f"{name}: bound to the {env_name} Environment", job.get("environment") == env_name)
    check(f"{name}: waits for the gate and the published images", {"gate", "publish-images"} <= set(needs_of(job)))
    check(f"{name}: the deploy names its own environment, the commit and both image DIGESTS from the publish job",
          f"--environment {env_name}" in runs and '--sha "$RELEASE_SHA"' in runs and '--image-ref "$BACKEND_REF"' in runs and '--frontend-ref "$FRONTEND_REF"' in runs
          and "needs.publish-images.outputs.backend_ref" in str(job["env"]) and "needs.publish-images.outputs.frontend_ref" in str(job["env"])
          and "needs.gate.outputs.sha" in str(job["env"]))
    check(f"{name}: the instance and region come from Environment variables", "vars.LAB_INSTANCE_ID" in str(job["env"]) and "vars.AWS_REGION" in str(job["env"]))
    check(f"{name}: exit codes 1 and 3 are reported as such", "(exit 1)" in runs and "(exit 3)" in runs and 'exit "$rc"' in runs)
    check(f"{name}: the deploy log is uploaded even when the deploy fails", any("upload-artifact" in str(s.get("uses", "")) and "always()" in str(s.get("if", "")) for s in steps))
    check(f"{name}: no step can skip a failed deploy (no continue-on-error)", not any(s.get("continue-on-error") for s in steps))

stg, prod = cd["jobs"]["deploy-staging"], cd["jobs"]["deploy-production"]
stg_runs = "\n".join(s.get("run", "") for s in stg["steps"])
prod_runs = "\n".join(s.get("run", "") for s in prod["steps"])
check("staging loads the idempotent demo catalogue (--seed)", re.search(r"--seed\b", stg_runs) is not None)
check("production is NEVER seeded by a deploy (no --seed)", "--seed" not in prod_runs)
check("each environment deploys only itself (staging never names production and the reverse)", "--environment production" not in stg_runs and "--environment staging" not in prod_runs)
print("== cd.yml: production needs staging first and the Environment's approval")
prod_jobs = sorted(n for n, j in cd["jobs"].items() if j.get("environment") == "production")
check("exactly one job binds the production Environment: deploy-production", prod_jobs == ["deploy-production"], str(prod_jobs))
check("production waits for a successful staging deploy", "deploy-staging" in needs_of(prod))
check("production has no `if:` that could let it run without the staging deploy succeeding", "if" not in prod)
check("staging does not use the production Environment", stg.get("environment") == "staging" and "production" not in str(needs_of(stg)))
check("only deploy-production mentions the production Environment", cd_code.count("environment: production") == 1)

print("== rollback.yml: it fails closed, and it never touches the schema")
guard = rb["jobs"]["guard"]
guard_run = guard["steps"][0]["run"]
rbk = rb["jobs"]["rollback"]
rbk_runs = "\n".join(s.get("run", "") for s in rbk["steps"])
check("an environment other than staging or production is refused with an error", "staging | production" in guard_run and "exit 1" in guard_run)
check("a request while CD is disabled is refused, not skipped", 'CD_ENABLED" != "true"' in guard_run and "never silently ignored" in guard_run and "if" not in guard)
check("a request from any ref but main is refused", "refs/heads/main" in guard_run)
check("the guard has no permissions and checks nothing out", guard.get("permissions") == {} and not any("checkout" in str(s.get("uses", "")) for s in guard["steps"]))
check("validation waits for the guard, and the rollback waits for validation", rb["jobs"]["validate"]["needs"] == "guard" and rbk["needs"] == "validate")
check("the rollback is bound to the Environment that was chosen (so production needs its approval, and its own key is used)", rbk.get("environment") == "${{ inputs.environment }}")
check("the rollback names the chosen environment, the target and the current main as the tooling carrier",
      '--environment "$TARGET_ENV"' in rbk_runs and '--sha "$TARGET_SHA"' in rbk_runs and '--carrier-sha "$GITHUB_SHA"' in rbk_runs)
check("a rollback never starts a migration", not re.search(r"(?i)migrat(?!ions)", rb_code.replace("never runs migrations", "").replace("NEVER runs migrations", "").replace("no migrations", "").replace("a rollback never runs migrations", "")), "")
check("the rollback does not pass image references (it uses the digests recorded on the host)", "--image-ref" not in rbk_runs and "--frontend-ref" not in rbk_runs)
check("the target is checked to be an ancestor of main", "compare/${TARGET_SHA}...${GITHUB_SHA}" in rb_code)
check("the summary says the schema was not changed", "was NOT changed" in rb_code)

print("== deploy/ci/ssh-deploy.sh: the tunnel, the key and the host key")
check("host key checking is on and pinned (StrictHostKeyChecking=yes, a known_hosts file of its own, no global file)",
      "StrictHostKeyChecking=yes" in ssh_code and 'UserKnownHostsFile="$KNOWN_HOSTS"' in ssh_code and "GlobalKnownHostsFile=/dev/null" in ssh_code)
check("host key checking is never weakened anywhere in the script", not any(re.search(p, ssh_code) for p in (WEAKENED_HOST_KEY_CHECKING[0], WEAKENED_HOST_KEY_CHECKING[2], WEAKENED_HOST_KEY_CHECKING[3])))
check("the host key must be one ed25519 public key (validated before use)", r"^ssh-ed25519\ [A-Za-z0-9+/]{68}$" in ssh_code)
check("authentication is by key only: no passwords, no agent, no other identity files",
      all(o in ssh_code for o in ("BatchMode=yes", "PasswordAuthentication=no", "IdentitiesOnly=yes", "IdentityAgent=none")) and "-F /dev/null" in ssh_code)
check("the private key is written once to a mode 600 file in a mode 700 directory, never to an argument",
      "umask 077" in ssh_code and "chmod 700" in ssh_code and "chmod 600" in ssh_code and "printf '%s\\n' \"$DEPLOY_SSH_KEY\" > \"$KEY\"" in ssh_code)
check("the key is dropped from the environment right after it is written", "unset DEPLOY_SSH_KEY" in ssh_code)
check("the key is never printed (no echo, emit or tee of it) and tracing is off",
      "set +x" in ssh_code and not re.search(r"(echo|emit|tee)[^\n]*\$\{?(DEPLOY_SSH_KEY|KEY)\b", ssh_code))
check("only the PUBLIC fingerprint is logged", 'ssh-keygen -l -f "$TMP/id.pub"' in ssh_code)
check("it authenticates as the deploy user, to the tunnel's local end only", '"deploy@127.0.0.1"' in ssh_code and "[127.0.0.1]:" in ssh_code)
check("the tunnel is the AWS port-forwarding document to port 22 of the one instance",
      "AWS-StartPortForwardingSession" in ssh_code and '\\"portNumber\\":[\\"22\\"]' in ssh_code and '--target "$INSTANCE"' in ssh_code)
check("cleanup runs on every exit path (EXIT, INT, TERM, HUP)", "trap cleanup EXIT" in ssh_code and "trap 'exit 130' INT" in ssh_code and "trap 'exit 143' TERM HUP" in ssh_code)
check("cleanup ends the SSM session, stops the tunnel process group and deletes the key and the temporary directory",
      "terminate-session" in ssh_code and 'kill -TERM -- "-$TUNNEL_PID"' in ssh_code and "kill -KILL" in ssh_code and "shred -u" in ssh_code and 'rm -rf "$TMP"' in ssh_code)
check("cleanup keeps the exit code of the deployment", "local rc=$?" in ssh_code and 'exit "$rc"' in ssh_code)
check("the tunnel and pre-flight error text goes through redact() (no account or instance id in the log)", "redact() { sed -E" in ssh_code and ssh_code.count("| redact | tee -a") == 3)
check("a pre-flight --check runs before the real command", '${REMOTE} --check' in ssh_code and ssh_code.index("--check") < ssh_code.index('ssh_run "$REMOTE" 2>&1'))
check("a success is only reported when the host confirmed the commit and the digest-pinned images",
      "pulled from GHCR by digest and its revision label matches" in ssh_code and "is live on" in ssh_code and "unconfirmed" in ssh_code)
check("exit codes 1 and 3 pass through; anything else is 'unconfirmed' (4)", "1) exit 1" in ssh_code and "3) exit 3" in ssh_code and "exit 4" in ssh_code)
check("no secret or address is written in the script", not re.search(r"BEGIN [A-Z ]*PRIVATE KEY|AKIA[0-9A-Z]{16}|\bi-[0-9a-f]{17}\b|\b[0-9]{12}\b", ssh_deploy))

print("== deploy/ci/install-ssm-plugin.sh: pinned and verified")
check("one exact version is pinned (never 'latest')", re.search(r'^PLUGIN_VERSION="\d+(\.\d+){3}"$', plugin_code, re.M) is not None and "latest" not in plugin_code)
check("a SHA-256 is pinned", re.search(r'^PLUGIN_SHA256="[0-9a-f]{64}"$', plugin_code, re.M) is not None)
check("the download is HTTPS only", "--proto '=https'" in plugin_code and "tlsv1.2" in plugin_code)
check("the checksum is verified BEFORE the package is installed, and a mismatch stops the job",
      0 <= plugin_code.index("sha256sum") < plugin_code.index("dpkg --install") and "NOT installing it" in plugin_code)
check("the installed version is checked afterwards", "session-manager-plugin --version" in plugin_code)

print("== the contract between the workflows and the wrappers on the host")
owner = "exampleowner"
digest = "c" * 64


def host_regex(kind):
    m = re.search(r"\[\[ \$%s =~ (\^ghcr[^ ]*) \]\]" % kind, wrapper)
    return m.group(1).replace("${OWNER}", owner) if m else None


def ci_regex(var):
    m = re.search(r"\[\[ \$%s =~ (\^ghcr[^ ]*) \]\]" % var, ssh_deploy)
    return m.group(1) if m else None


host_backend, host_frontend = host_regex("IMAGE_REF"), host_regex("FRONTEND_REF")
ci_backend, ci_frontend = ci_regex("IMAGE_REF"), ci_regex("FRONTEND_REF")
backend_ref = f"ghcr.io/{owner}/shopnest-backend@sha256:{digest}"
frontend_ref = f"ghcr.io/{owner}/shopnest-frontend@sha256:{digest}"
check("both sides have an image pattern", all([host_backend, host_frontend, ci_backend, ci_frontend]))
if all([host_backend, host_frontend, ci_backend, ci_frontend]):
    check("a value the workflows send is accepted by the CI script and by the host wrapper",
          all(re.fullmatch(p, v) for p, v in ((host_backend, backend_ref), (host_frontend, frontend_ref), (ci_backend, backend_ref), (ci_frontend, frontend_ref))))
    for label, value in (("a tag instead of a digest", f"ghcr.io/{owner}/shopnest-backend:latest"), ("another owner", f"ghcr.io/someoneelse/shopnest-backend@sha256:{digest}"),
                         ("the frontend image as the backend", frontend_ref), ("a digest with extra text", backend_ref + ";id")):
        check(f"the host wrapper refuses: {label}", re.fullmatch(host_backend, value) is None)
        if label != "another owner":  # the CI script accepts any owner on purpose: the host wrapper pins the owner of THIS repository
            check(f"the CI script refuses: {label}", re.fullmatch(ci_backend, value) is None)
check("the CI script builds exactly the flags the wrapper accepts (deploy)",
      all(f in ssh_code for f in ("--env ${ENVIRONMENT}", "--sha ${SHA}", "--image-ref ${IMAGE_REF}", "--frontend-ref ${FRONTEND_REF}", "--seed", "--check")))
check("the CI script builds exactly the flags the wrapper accepts (rollback)", all(f in ssh_code for f in ("shopnest-rollback --env ${ENVIRONMENT}", "--carrier-sha ${CARRIER_SHA}")))
check("the wrapper accepts those flags", all(f in wrapper for f in ("--env)", "--sha)", "--image-ref)", "--frontend-ref)", "--carrier-sha)", "--seed)", "--check)")))
deploy_sources = "".join((ROOT / p).read_text(encoding="utf-8") for p in ("deploy/scripts/bluegreen-deploy.sh", "deploy/scripts/lib/bluegreen-lib.sh", "deploy/scripts/rollback.sh"))
check("the host confirmation lines the CI script waits for exist in the deploy scripts",
      all(t in deploy_sources for t in ("pulled from GHCR by digest and its revision label matches", "unpacked from the GHCR image (digest pinned, revision label matches)",
                                        "release $sha is live on", "ROLLBACK SUCCEEDED: $SHA is live on", "is already the live release on")))
check("each key is bound to one environment: the setup script writes a forced command per key and the entry point enforces it",
      'command=\\"$SBIN/$ENTRY $env\\"' in setup and 'die "this key may only act on $KEY_ENV"' in entry)
check("the entry point can start only the two wrappers", "shopnest-deploy | shopnest-rollback" in entry and 'exec sudo -n "$SBIN/${WORDS[0]}"' in entry)

print("== ssh-preflight.yml: a diagnostic that deploys nothing")
pf_text, pf = load("ssh-preflight.yml")
pf_code = uncommented(pf_text)
pf_on = pf.get("on", pf.get(True)) or {}
pf_job = pf["jobs"]["preflight"]
pf_steps = pf_job["steps"]
pf_runs = [s.get("run", "") for s in pf_steps]
check("ssh-preflight.yml: manual start only", list(pf_on) == ["workflow_dispatch"], str(list(pf_on)))
check("ssh-preflight.yml: no default token permissions, id-token only on the one job", pf.get("permissions") == {} and (pf_job.get("permissions") or {}).get("id-token") == "write" and list(pf["jobs"]) == ["preflight"])
check("ssh-preflight.yml: runs from main only", "github.ref == 'refs/heads/main'" in str(pf_job.get("if", "")))
check("ssh-preflight.yml: bound to the chosen Environment (production is held for its reviewer)", str(pf_job.get("environment")) == "${{ inputs.environment }}")
check("ssh-preflight.yml: the SSH client runs with --preflight-only and without --seed, so nothing can be deployed",
      sum("ssh-deploy.sh" in r for r in pf_runs) == 1 and all("--preflight-only" in r for r in pf_runs if "ssh-deploy.sh" in r) and "--seed" not in pf_code and "ssh-deploy.sh rollback" not in pf_code)
check("ssh-preflight.yml: the only secret is DEPLOY_SSH_KEY", sorted(set(re.findall(r"secrets\.(\w+)", pf_code))) == ["DEPLOY_SSH_KEY"])
pf_plugin = [i for i, s in enumerate(pf_steps) if "install-ssm-plugin.sh" in s.get("run", "")]
pf_creds = [i for i, s in enumerate(pf_steps) if "configure-aws-credentials" in str(s.get("uses", ""))]
pf_deploy = [i for i, s in enumerate(pf_steps) if "ssh-deploy.sh" in s.get("run", "")]
check("ssh-preflight.yml: the pinned plugin is installed BEFORE the AWS credentials, then the pre-flight",
      len(pf_plugin) == 1 and len(pf_creds) == 1 and len(pf_deploy) == 1 and pf_plugin[0] < pf_creds[0] < pf_deploy[0])
check("ssh-preflight.yml: the AWS account id is masked", (pf_steps[pf_creds[0]].get("with") or {}).get("mask-aws-account-id") is True if pf_creds else False)
check("ssh-preflight.yml: every action is pinned to a full commit SHA", all(re.match(r"^[\w.-]+/[\w.-]+@[0-9a-f]{40}$", u) for u in re.findall(r"^\s*-?\s*uses:\s*(\S+)", pf_code, re.M)))
check("ssh-preflight.yml: no expression is expanded inside a script and no shell tracing", not any("${{" in r for r in pf_runs) and not any(re.search(r"set\s+-[a-z]*x", r) for r in pf_runs))
check("ssh-preflight.yml: a final always() step kills any tunnel that is left", any("AWS-StartPortForwardingSession" in s.get("run", "") and "always()" in str(s.get("if", "")) for s in pf_steps))
check("ssh-preflight.yml: uses the per-environment lab concurrency group, so it never overlaps a deploy of that Environment", (pf_job.get("concurrency") or {}).get("group") == "deploy-lab-${{ inputs.environment }}")
check("ssh-preflight.yml: the deliberate failure replaces the host key with a throwaway one, never weakens checking", "wrong-host-key" in pf_code and "StrictHostKeyChecking=no" not in pf_code and "ssh-keygen -q -t ed25519" in pf_code)
check("ssh-deploy.sh has the --preflight-only mode and sends nothing after the pre-flight in it", "--preflight-only) PREFLIGHT_ONLY=1" in ssh_code and ssh_code.index('if [ "$PREFLIGHT_ONLY" = 1 ]') < ssh_code.index('emit "ssh-deploy: running: ${REMOTE}"'))

print("== staging-verify.yml: exercises staging through the tunnel, changes nothing, never touches production")
sv_text, sv = load("staging-verify.yml")
sv_code = uncommented(sv_text)
sv_on = sv.get("on", sv.get(True)) or {}
sv_job = sv["jobs"]["staging"]
sv_steps = sv_job["steps"]
sv_runs = [s.get("run", "") for s in sv_steps]
check("staging-verify.yml: manual start only, from main only", list(sv_on) == ["workflow_dispatch"] and "github.ref == 'refs/heads/main'" in str(sv_job.get("if", "")))
check("staging-verify.yml: bound to the staging Environment and to nothing else (never production)", str(sv_job.get("environment")) == "staging" and "production" not in sv_code.replace("never production", ""))
check("staging-verify.yml: no default token permissions, id-token only on the one job, no secret at all", sv.get("permissions") == {} and (sv_job.get("permissions") or {}).get("id-token") == "write" and "secrets." not in sv_code and "DEPLOY_SSH_KEY" not in sv_code)
check("staging-verify.yml: only the staging nginx port (8081) is forwarded, never port 22", '\\"portNumber\\":[\\"8081\\"]' in sv_code and '\\"22\\"' not in sv_code and "ssh " not in sv_code)
sv_plugin = [i for i, s in enumerate(sv_steps) if "install-ssm-plugin.sh" in s.get("run", "")]
sv_creds = [i for i, s in enumerate(sv_steps) if "configure-aws-credentials" in str(s.get("uses", ""))]
check("staging-verify.yml: the pinned plugin is installed BEFORE the AWS credentials, and the account id is masked", len(sv_plugin) == 1 and len(sv_creds) == 1 and sv_plugin[0] < sv_creds[0] and (sv_steps[sv_creds[0]].get("with") or {}).get("mask-aws-account-id") is True)
check("staging-verify.yml: every action is pinned to a full commit SHA", all(re.match(r"^[\w.-]+/[\w.-]+@[0-9a-f]{40}$", u) for u in re.findall(r"^\s*-?\s*uses:\s*(\S+)", sv_code, re.M)))
check("staging-verify.yml: no expression is expanded inside a script and no shell tracing", not any("${{" in r for r in sv_runs) and not any(re.search(r"set\s+-[a-z]*x", r) for r in sv_runs))
check("cd.yml: staging and production deploy jobs are in DIFFERENT groups, so a production job waiting for its reviewer cannot block a staging deploy", cd["jobs"]["deploy-staging"]["concurrency"]["group"] == "deploy-lab-staging" and cd["jobs"]["deploy-production"]["concurrency"]["group"] == "deploy-lab-production")
check("staging-verify.yml: runs in its OWN concurrency group, so it can run while a deploy is in progress", (sv_job.get("concurrency") or {}).get("group") == "staging-verify")
check("staging-verify.yml: the tunnel is always ended (session terminated, process group killed) and the evidence uploaded even on failure", "terminate-session" in sv_code and 'kill -TERM -- "-$TUNNEL_PID"' in sv_code and any("upload-artifact" in str(s.get("uses", "")) and "always()" in str(s.get("if", "")) for s in sv_steps))
check("staging-verify.yml: traffic mode uses request-loop.sh with a version URL and a JSON summary", "deploy/scripts/request-loop.sh" in sv_code and "--version-url" in sv_code and "--json" in sv_code)

print()
print(f"workflow checks: {passes} passed, {len(failures)} failed")
sys.exit(1 if failures else 0)
