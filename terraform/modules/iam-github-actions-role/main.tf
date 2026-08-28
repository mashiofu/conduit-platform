# One role per repo (backend/frontend get separate roles from separate
# calls to this module) so each pipeline only ever holds the permissions
# it actually needs - the backend's CI can never touch the frontend
# bucket, and vice versa.

locals {
  # Either "any ref on this repo" or "only this GitHub Environment", per
  # var.github_environment - see its description for when to use which.
  trust_subjects = var.github_environment != null ? [
    for repo in var.github_repos : "repo:${var.github_org}/${repo}:environment:${var.github_environment}"
    ] : [
    for repo in var.github_repos : "repo:${var.github_org}/${repo}:*"
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
    for_each = var.frontend_bucket_arn != null ? [1] : []
    content {
      sid    = "FrontendBucketSync"
      effect = "Allow"
      actions = [
        "s3:ListBucket",
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
      ]
      resources = [var.frontend_bucket_arn, "${var.frontend_bucket_arn}/*"]
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
    for_each = var.s3_read_bucket_arn != null ? [1] : []
    content {
      sid       = "S3ReadOnlyForPromotion"
      effect    = "Allow"
      actions   = ["s3:ListBucket", "s3:GetObject"]
      resources = [var.s3_read_bucket_arn, "${var.s3_read_bucket_arn}/*"]
    }
  }

  dynamic "statement" {
    for_each = var.cloudfront_distribution_arn != null ? [1] : []
    content {
      sid       = "CloudFrontInvalidate"
      effect    = "Allow"
      actions   = ["cloudfront:CreateInvalidation"]
      resources = [var.cloudfront_distribution_arn]
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
