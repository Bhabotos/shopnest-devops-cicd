"""Extracts the shell scripts embedded in the SSM command documents (infra/terraform/ssm_documents.tf) as plain files.

    python ssm_scripts_extract.py <path to ssm_documents.tf> <output directory>

It writes deploy.sh and rollback.sh: the text of the Terraform locals deploy_script and rollback_script, with the two kinds of
placeholder resolved the way they will be at run time:
  - Terraform interpolations (the shared fetch-and-verify block, the environment, the region, the bucket) are replaced by the
    values of the staging design;
  - Systems Manager parameters ({{ Sha }} and so on) are replaced by sample values that satisfy each parameter's allowedPattern.
Blank lines are dropped, as Terraform's compact() drops them, so the first line of the file is exactly the first line SSM receives.
It fails if any placeholder is left unresolved. It reads the .tf source only: no Terraform, no AWS.
"""

import re
import sys
from pathlib import Path

SHA = "a" * 40
SAMPLE_VALUES = {
    "Sha": SHA,
    "ImageRef": "111122223333.dkr.ecr.ap-south-1.amazonaws.com/shopnest/staging/backend@sha256:" + "c" * 64,
    "BundleKey": f"deploy/staging/{SHA}/bundle.tar.gz",
    "BundleSha256": "d" * 64,
    "TargetSha": "b" * 40,
    "CarrierSha": "e" * 40,
    "CarrierBundleKey": f"deploy/staging/{'e' * 40}/bundle.tar.gz",
    "CarrierBundleSha256": "f" * 64,
}
TERRAFORM_VALUES = {
    "${var.environment}": "staging",
    "${var.aws_region}": "ap-south-1",
    "${aws_s3_bucket.artifacts.bucket}": "example-artifact-bucket",
}


def heredoc(tf_text, name):
    """The body of `name = <<-EOT ... EOT`, with the common leading indentation removed (what <<- does)."""
    match = re.search(r"^\s*%s = <<-EOT\n(.*?)\n\s*EOT\s*$" % re.escape(name), tf_text, re.S | re.M)
    if not match:
        raise SystemExit(f"could not find the heredoc {name} in the Terraform source")
    lines = match.group(1).split("\n")
    indent = min(len(line) - len(line.lstrip()) for line in lines if line.strip())
    return "\n".join(line[indent:] for line in lines)


def resolve(body, fetch_block):
    body = body.replace("${local.fetch_and_verify}", fetch_block)
    for placeholder, value in TERRAFORM_VALUES.items():
        body = body.replace(placeholder, value)
    body = re.sub(r"\{\{ (\w+) \}\}", lambda m: SAMPLE_VALUES[m.group(1)], body)
    left = re.findall(r"\$\{[^}]*\}|\{\{[^}]*\}\}", body)
    if left:
        raise SystemExit(f"unresolved placeholders left in a script: {left}")
    return "\n".join(line for line in body.split("\n") if line != "") + "\n"


def main():
    tf_path, out_dir = Path(sys.argv[1]), Path(sys.argv[2])
    tf_text = tf_path.read_text(encoding="utf-8")
    fetch_block = heredoc(tf_text, "fetch_and_verify")
    out_dir.mkdir(parents=True, exist_ok=True)
    for local, filename in (("deploy_script", "deploy.sh"), ("rollback_script", "rollback.sh")):
        (out_dir / filename).write_text(resolve(heredoc(tf_text, local), fetch_block), encoding="utf-8", newline="\n")
    print(f"extracted deploy.sh and rollback.sh into {out_dir}")


if __name__ == "__main__":
    main()
