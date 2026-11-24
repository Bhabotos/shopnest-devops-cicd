# GitHub Actions deploy identity (OIDC). No access keys exist anywhere: a workflow exchanges its short-lived OIDC token for a role's
# temporary credentials. Everything here is created only when enable_cicd is true.
#
# One role per environment. Each role can be assumed ONLY by a job that runs in that GitHub Environment (an exact subject; the
# production role therefore needs the production Environment's approval to be reachable at all), and it can do ONE thing: open an
# SSM port-forwarding session to the lab instance (the deploy then speaks SSH through that tunnel, as an unprivileged user that can
# start only two root-owned wrappers) and close its own session. It cannot send a command, read a secret, change infrastructure or
# touch IAM. (Images are published to GHCR with the workflow's own GITHUB_TOKEN, not with AWS.)
# The two roles differ only in who may assume them; what separates staging from production on the host is the SSH key (each key is
# bound to one environment in authorized_keys), see deploy/host/setup-deploy-host.sh.

locals {
  github_oidc_provider_arn = var.create_github_oidc_provider ? one(aws_iam_openid_connect_provider.github[*].arn) : var.github_oidc_provider_arn
}

resource "aws_iam_openid_connect_provider" "github" {
  count = local.cicd && var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  tags = { Name = "${var.project}-github-oidc" }
}

# Trust: only a token from GitHub, for the STS audience, whose subject is EXACTLY the approved one for that environment.
# StringEquals, never a wildcard.
data "aws_iam_policy_document" "github_trust" {
  for_each = local.cicd ? toset(local.environments) : toset([])

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [lookup(var.github_oidc_subjects, each.key, "")]
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  for_each = local.cicd ? toset(local.environments) : toset([])

  name                 = "${local.name}-github-deploy-${each.key}"
  description          = "GitHub Actions deploy role for ${each.key}: open an SSM port-forwarding session to the lab instance. No secret access."
  assume_role_policy   = data.aws_iam_policy_document.github_trust[each.key].json
  max_session_duration = 3600

  lifecycle {
    precondition {
      condition     = var.github_repository != "" && contains(keys(var.github_oidc_subjects), each.key)
      error_message = "enable_cicd needs github_repository and a github_oidc_subjects entry for ${each.key} (the real OIDC claim, captured from a workflow run)."
    }
    # The role may be assumed only by a job that runs in THIS role's GitHub Environment: a branch, or the other environment,
    # can never assume it. The repository part of the subject is not checked here (it must be captured from the real token).
    precondition {
      condition     = startswith(lookup(var.github_oidc_subjects, each.key, ""), "repo:") && endswith(lookup(var.github_oidc_subjects, each.key, ""), ":environment:${each.key}")
      error_message = "The ${each.key} subject must start with 'repo:' and end with ':environment:${each.key}'. A branch or another environment must never be able to assume this role."
    }
    precondition {
      condition     = var.create_github_oidc_provider != (var.github_oidc_provider_arn != "")
      error_message = "Set exactly one of create_github_oidc_provider = true or github_oidc_provider_arn (an account can hold only one GitHub OIDC provider)."
    }
  }
}

data "aws_iam_policy_document" "github_deploy" {
  for_each = local.cicd ? toset(local.environments) : toset([])

  # Open a port-forwarding session to exactly the lab instance, with exactly the AWS-owned port-forwarding document, and nothing
  # else: the workflow then speaks SSH through the tunnel to the unprivileged deploy user (see deploy/ci/ssh-deploy.sh). The role
  # cannot start a shell session or any other document, and cannot send a command. IAM cannot restrict the forwarded PORT (the
  # host's SSH key restrictions and the root-owned wrappers are what bound what a tunnel can do).
  statement {
    sid     = "StartPortForwardingToTheLabInstance"
    effect  = "Allow"
    actions = ["ssm:StartSession"]
    resources = [
      aws_instance.lab.arn,
      "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}::document/AWS-StartPortForwardingSession",
    ]

    # The caller must also be allowed to use the document it names: no session on this instance without the listed document.
    condition {
      test     = "BoolIfExists"
      variable = "ssm:SessionDocumentAccessCheck"
      values   = ["true"]
    }
  }

  # Use and close only the sessions this role's own job started, so the tunnel is gone even if the job fails. This is the form AWS
  # documents ("Example 4: Allow users to resume and end only sessions they started", Method 1): Session Manager tags every session with
  # aws:ssmmessages:session-id = the caller's user id, which is the aws:userid policy variable ("<role id>:<role session name>" for a
  # role session). A session ARN with aws:userid in it would NOT match: the session ID of a role session begins with the role SESSION
  # NAME, not with aws:userid. ssmmessages:OpenDataChannel is listed with the same condition in every AWS example policy for session
  # users. (&{...} is how the policy document data source writes an IAM policy variable.)
  statement {
    sid       = "UseAndEndOwnSessions"
    effect    = "Allow"
    actions   = ["ssm:TerminateSession", "ssmmessages:OpenDataChannel"]
    resources = ["arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:session/*"]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/aws:ssmmessages:session-id"
      values   = ["&{aws:userid}"]
    }
  }

  # Checking that the instance is registered has no resource-level scope in IAM; this is read-only.
  statement {
    sid       = "CheckTheInstanceIsOnline"
    effect    = "Allow"
    actions   = ["ssm:DescribeInstanceInformation"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  for_each = local.cicd ? toset(local.environments) : toset([])

  name   = "deploy-${each.key}"
  role   = aws_iam_role.github_deploy[each.key].id
  policy = data.aws_iam_policy_document.github_deploy[each.key].json
}
