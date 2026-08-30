# One role per repo (backend/frontend get separate roles from separate
# calls to this module) so each pipeline only ever holds the permissions
# it actually needs - the backend's CI can never touch the frontend
# bucket, and vice versa.

locals {
  # Either "any ref on this repo" or "only this GitHub Environment", per
  # var.github_environment - see its description for when to use which.
  #
  # The `@*` after the org and after each repo name accounts for GitHub's
  # "immutable subject claims" format (shipped 2026-04-23: see
  # https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/),
  # which every repo created after 2026-07-15 uses automatically, with no
  # opt-out - the sub claim is `repo:OWNER@OWNER-ID/REPO@REPO-ID:...`, not
  # the classic `repo:OWNER/REPO:...` every existing example/tutorial
  # (and this pattern, until this fix) assumes. Confirmed live via
  # CloudTrail: a real `AssumeRoleWithWebIdentity` call's actual
  # `userIdentity.principalId` showed
  # `repo:octo-org@123456/octo-repo@456789:environment:dev` (GitHub's own
  # changelog example format, standing in here for the real org/repo/IDs
  # actually observed)
  # - the old pattern's `StringLike` match failed because the literal
  # text right after `repo:${org}` is `@<owner-id>`, not `/`, so the
  # match position never lines up. `@` can't appear in a GitHub username
  # or repo name, so `@*` only ever matches the numeric ID GitHub inserts
  # there - it doesn't loosen which org/repo name is trusted.
  trust_subjects = var.github_environment != null ? [
    for repo in var.github_repos : "repo:${var.github_org}@*/${repo}@*:environment:${var.github_environment}"
    ] : [
    for repo in var.github_repos : "repo:${var.github_org}@*/${repo}@*:*"
  ]
}

data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.trust_subjects
    }
  }
}

resource "aws_iam_role" "this" {
  name               = var.name
  assume_role_policy = data.aws_iam_policy_document.trust.json
  tags               = var.tags
}

data "aws_iam_policy_document" "permissions" {
  # ecr:GetAuthorizationToken has no resource-level permissions - it's
  # always "*", scoped only by the fact that this role trusts one
  # specific repo's OIDC subject in the first place.
  statement {
    sid       = "ECRAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = length(var.ecr_repository_arns) > 0 ? [1] : []
    content {
      sid    = "ECRPush"
      effect = "Allow"
      actions = [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
      ]
      resources = var.ecr_repository_arns
    }
  }

  dynamic "statement" {
    for_each = length(var.ecr_pull_only_repository_arns) > 0 ? [1] : []
    content {
      sid    = "ECRPullOnlyForPromotion"
      effect = "Allow"
      actions = [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
      ]
      resources = var.ecr_pull_only_repository_arns
    }
  }

  dynamic "statement" {
    for_each = var.eks_describe_cluster ? [1] : []
    content {
      sid       = "EKSDescribeForKubeconfig"
      effect    = "Allow"
      actions   = ["eks:DescribeCluster", "eks:ListClusters"]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = var.ssm_read_parameter_arn != null ? [1] : []
    content {
      sid       = "ReadRuntimeConfig"
      effect    = "Allow"
      actions   = ["ssm:GetParameter"]
      resources = [var.ssm_read_parameter_arn]
    }
  }

  dynamic "statement" {
    for_each = var.ssm_write_parameter_arn != null ? [1] : []
    content {
      sid       = "WriteRuntimeConfig"
      effect    = "Allow"
      actions   = ["ssm:PutParameter"]
      resources = [var.ssm_write_parameter_arn]
    }
  }
}

resource "aws_iam_role_policy" "this" {
  name   = "${var.name}-permissions"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.permissions.json
}

resource "aws_iam_role_policy_attachment" "admin" {
  count      = var.admin_access ? 1 : 0
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
