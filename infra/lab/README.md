# infra/lab: the minimal AWS lab instance

Status: **written and statically validated (`terraform fmt`, `terraform validate`, the static checks in `deploy/tests/lab.test.sh`). Not planned, not applied. No AWS resource exists.**
Passing validation does not mean AWS will accept the configuration. Applying anything needs the owner's explicit approval in that turn.

This directory is a **separate Terraform root**. It does not read, import or change `infra/terraform/` (the earlier, larger design with RDS, ECR, a NAT Gateway, a load balancer and CodeBuild, kept for reference). The saved plan files
in `infra/terraform/` are stale and must never be applied; nothing here uses them.

## What it creates

| Resource | Setting |
|---|---|
| Region | `ap-south-1` (fixed by a validation) |
| VPC | one dedicated VPC with DNS support; the range (`vpc_cidr`, a private /16) is supplied from the untracked `lab.tfvars` and the subnet is its second /24 |
| Subnet and routing | **one public subnet**, an Internet Gateway, one route table with a default route to the Internet Gateway. **No NAT Gateway.** |
| Security group | **inbound: TCP 80 from `0.0.0.0/0` only. No SSH (22), no HTTPS, no 5432.** Outbound: TCP 443 and 80 only. The default security group is emptied |
| EC2 | **one `t3.small`**, Ubuntu 24.04, encrypted `gp3` root volume (20 GiB), IMDSv2 required with hop limit 1, a public IPv4 address, **no key pair** |
| Public address | an Elastic IP (`use_elastic_ip`, default true) so the live URL survives a stop and start; the same price as an auto-assigned public IPv4 address while the instance runs |
| Instance role | by default a **new** role and instance profile, `AmazonSSMManagedInstanceCore` only (Session Manager and Run Command; no ECR, S3, Secrets Manager or EC2 permission). Or, when `existing_instance_profile` is set, a **pre-provisioned profile that Terraform only reads** (see [below](#reusing-a-pre-provisioned-instance-profile)) |
| Bootstrap (`user_data.sh.tftpl`) | installs Docker, the Compose plugin and git; a swap file (1 GiB); the SSM agent is preinstalled on the AMI; writes `/var/lib/shopnest/bootstrap-complete` |
| CI/CD (optional, `enable_cicd = false` by default) | one GitHub OIDC deploy role **per environment**, and four fixed SSM command documents (deploy and rollback, staging and production) |

**Not created, on purpose:** NAT Gateway, load balancer, RDS, ECR, a state bucket, a key pair, an access key, an IAM user, an inbound SSH rule, any database port.

## How the application runs on it

Both environments run on this one instance as **separate Compose projects** (`shopnest-staging`, `shopnest-production`), each with its own nginx, blue and green backends and its own **PostgreSQL container**
on an `internal: true` Docker network (no published port, no route to the outside; the security group would not admit it anyway).

| | staging | production |
|---|---|---|
| nginx listens on | `127.0.0.1:8081` (loopback only) | `0.0.0.0:80` (the live URL) |
| reach it | Session Manager port forwarding | `http://<public address>/` |
| configuration | `deploy/env/staging.env` | `deploy/env/production.env` |
| demo catalogue | loaded by the staging deploy (idempotent) | **never by a deploy**: an explicit operator choice |

Images are **built by GitHub Actions, pushed to GHCR tagged with the commit SHA, and deployed by DIGEST**. The deploy and rollback run through the four fixed SSM documents (no SSH, no inbound port 22): the instance fetches this
public repository at the exact commit, pulls both images by digest (the packages must be **public**), runs the migrations, and does the blue/green deploy with automatic rollback. The database passwords are **generated on the
host** at the first deploy (`/opt/shopnest/<environment>/secrets.env`, mode 600), never printed and never stored anywhere else. Details and diagrams: [`docs/LAB_DEPLOYMENT.md`](../../docs/LAB_DEPLOYMENT.md).

## Files

| File | Purpose |
|---|---|
| `versions.tf` | Terraform and provider constraints; the S3 backend (key `terraform/shopnest/terraform.tfstate`, `encrypt = true`, `use_lockfile = true`); **no bucket name** |
| `provider.tf` | profile `devops`, `allowed_account_ids`, default tags |
| `variables.tf` | every configurable value, with validations |
| `main.tf` | account and root-user guard, shared locals |
| `networking.tf`, `security_groups.tf`, `iam.tf`, `ec2.tf` | the network, the firewall, the instance role, the instance and its address |
| `github_oidc.tf`, `ssm_documents.tf` | optional CI/CD identities and the four fixed documents (`deploy.sh.tftpl`, `rollback.sh.tftpl` are their only commands) |
| `outputs.tf` | instance ID, region, public address, role ARNs, document names. No secret |
| `backend.hcl.example`, `lab.tfvars.example` | placeholders only; copy to the git-ignored `backend.hcl` and `lab.tfvars` |
| `.terraform.lock.hcl` | provider lock (AWS provider 6.73.0), copied from `infra/terraform` |

## Prerequisites (none of these has been done)

1. The AWS CLI profile `devops` with short-lived credentials (never root, never an access key).
2. The existing lab state bucket, **verified first** (read-only): versioning, default encryption, public access block, and that nothing already exists at the state key. This configuration never creates or deletes it.
3. `backend.hcl` (the bucket name) and `lab.tfvars` (`allowed_account_ids` and `vpc_cidr`) created locally from the examples. **They hold your account ID and bucket name: never commit them** (both are git-ignored and a CI check fails if one is tracked).
4. The identity running Terraform needs, at least: S3 list/get/put/delete on the state key and its `.tflock` object; create and delete rights for VPC, subnet, internet gateway, route table, security group, EC2 instance, Elastic IP and
   tags; `iam:CreateRole`, `AttachRolePolicy`, `PutRolePolicy`, `CreateInstanceProfile`, `PassRole` for the lab role (and `CreateOpenIDConnectProvider` if CI/CD is enabled); `ssm:CreateDocument` if CI/CD is enabled.
   **Not verified**: use the policy simulator before the first plan.
5. For `enable_cicd`: whether the account already holds a GitHub OIDC provider (an account can hold only one), and the **real** OIDC `sub` claims captured from a workflow run (see `docs/LAB_DEPLOYMENT.md`).

## Reusing a pre-provisioned instance profile

If creating IAM roles is not permitted for the applying identity, name an instance profile that already exists. Terraform then **only reads it** (a data source, `iam:GetInstanceProfile`): it creates no role, creates no instance profile,
attaches and detaches no policy, and changes nothing in IAM.

| | existing profile (`existing_instance_profile = "<profile name>"`) | default (`existing_instance_profile = ""`) |
|---|---|---|
| `aws_iam_role.instance` | not created | created (`shopnest-lab-instance`) |
| `aws_iam_role_policy_attachment.ssm_core` | not created | created (`AmazonSSMManagedInstanceCore` only) |
| `aws_iam_instance_profile.instance` | not created | created (`shopnest-lab-instance`) |
| `data.aws_iam_instance_profile.existing` | read | not read |
| `aws_instance.lab` uses | the existing profile | the lab's own profile |

Set it in your untracked `lab.tfvars` (the profile name is not a secret, but keep it out of tracked files like the account ID): `existing_instance_profile = "<name>"`. Leave it empty or unset for the default path. The default behaviour and the resource
names are unchanged by this option, and `enable_cicd` stays false (the reuse option is unrelated to CI/CD).

**What must already be true of the existing profile** (Terraform will not fix it): its role trusts `ec2.amazonaws.com`, carries `AmazonSSMManagedInstanceCore` (otherwise the instance never registers with Systems Manager), and is not broader than that.

**Still required: `iam:PassRole`.** Attaching a profile to an instance needs the applying identity to be allowed `iam:PassRole` on the profile's role (with `iam:PassedToService = ec2.amazonaws.com`). This cannot be read or simulated with the
current identity: it is **unverified** and only a real apply (or an administrator) can settle it. `iam:GetInstanceProfile` is verified as allowed.

**Security limits of reuse.**
- Only the role's **managed** policies can be listed (`iam:ListAttachedRolePolicies`, verified allowed). **Inline policies cannot be inspected** with this identity (`iam:ListRolePolicies` is denied), and neither can the contents of AWS-managed policies. A wildcard,
  an IAM-write or an S3-write permission in an inline policy would therefore go unnoticed; ask the owner of the role to confirm there is none.
- Anything running on the instance can use the role (the metadata hop limit of 1 keeps containers from reaching it, but the host and the SSM agent can).
- The role is shared with whatever else uses it: it is not created or tagged by this stack, so `terraform destroy` will not delete it, and a change made to it elsewhere affects this instance.

## Safe sequence (each step that touches AWS needs your approval)

```bash
cd infra/lab
cp backend.hcl.example backend.hcl        # then set the bucket name (untracked)
cp lab.tfvars.example lab.tfvars          # then set allowed_account_ids and vpc_cidr (untracked)
terraform init -backend-config=backend.hcl            # contacts the S3 backend
terraform plan -var-file=lab.tfvars -out=lab.tfplan   # REVIEW it: one instance, no NAT, ALB, RDS or ECR, one inbound rule
terraform apply lab.tfplan                            # only after explicit approval, only this reviewed plan
terraform output -raw public_ip                       # the live URL is http://<this address>/
terraform destroy -var-file=lab.tfvars                # only after explicit approval; releases the address and stops the billing
```

Use the **default workspace** (a named workspace would move the state to a different key). Local, offline validation needs no AWS and no bucket:

```bash
terraform init -backend=false -lockfile=readonly
terraform fmt -check -recursive && terraform validate
bash ../../deploy/tests/lab.test.sh
```

## Cost (an estimate, not a quote; Mumbai, running 24/7)

| Item | About per month |
|---|---|
| `t3.small` | $15 to $18 |
| EBS `gp3`, 20 GiB | $2 |
| One public IPv4 address (the Elastic IP, attached) | $3.65 |
| Data transfer, image pulls, Session Manager | $0 to $2 |
| **Total** | **about $21 to $26, roughly $0.03 an hour** |

An Elastic IP keeps billing when it is not attached to a running instance, so run `terraform destroy` after grading. `t3` instances default to unlimited CPU credits, so a long CPU-heavy burst can add a small charge.

## Limits and risks (do not weaken)

- One instance is one failure domain: an instance or Availability Zone failure takes both environments down, and both databases live on its disk. No backup exists (the data is demo data).
- Both environments share 2 GiB of memory (a swap file is added). Not measured.
- The public address serves **plain HTTP** (the approved decision); there is no domain or certificate.
- The instance has outbound access to the whole internet on 80 and 443. The application role cannot reach AWS APIs: the metadata hop limit is 1, so no container can obtain the instance role.
- The two deploy roles can only send their environment's fixed documents; the documents run one fixed script each. A repository writer can still change that script by changing the repository, so the real control is branch protection on `main` and the production Environment's required reviewer.
- GHCR packages must be public (one manual step); the code and the images are therefore public, which is already true of the repository.
