# IRSA roles for the three add-ons that get installed via Helmfile (see
# conduit-platform/helm/), not Terraform. Terraform's job stops at "the
# IAM role exists and trusts the right ServiceAccount" - the Helm release
# itself is what actually creates that ServiceAccount and annotates it
# with the role ARN (via each chart's serviceAccount.annotations values).

data "aws_region" "current" {}
data "aws_caller_identity" "irsa" {}

# ---- AWS Load Balancer Controller ----
# Namespace/name match the chart's defaults (kube-system/aws-load-balancer-controller).

data "aws_iam_policy_document" "lb_controller_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.cluster.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lb_controller" {
  name               = "${var.name_prefix}-lb-controller"
  assume_role_policy = data.aws_iam_policy_document.lb_controller_trust.json
  tags               = var.tags
}

# Verbatim from https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
# (fetched 2026-08-26) rather than hand-reconstructed - this policy is
# long, AWS-maintained, and easy to get subtly wrong by hand.
resource "aws_iam_policy" "lb_controller" {
  name   = "${var.name_prefix}-lb-controller"
  policy = file("${path.module}/policies/aws-load-balancer-controller-iam-policy.json")
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.lb_controller.name
  policy_arn = aws_iam_policy.lb_controller.arn
}

# ---- External Secrets Operator ----
# Namespace/name match the chart's defaults (external-secrets/external-secrets).

data "aws_iam_policy_document" "external_secrets_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.cluster.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:external-secrets:external-secrets"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "external_secrets" {
  name               = "${var.name_prefix}-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.external_secrets_trust.json
  tags               = var.tags
}

data "aws_iam_policy_document" "external_secrets_permissions" {
  statement {
    # Scoped by RDS's own naming convention for auto-managed secrets
    # ("rds!db-...") rather than this environment's exact secret ARN -
    # passing that ARN in directly would make this module depend on the
    # rds module's output while rds/elasticache already depend on THIS
    # module's cluster_security_group_id output, i.e. a circular
    # dependency. Fine in a single-RDS-instance-per-account setup like
    # this one; tighten with a resource tag condition if that ever
    # changes.
    sid       = "ReadRDSManagedSecrets"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = ["arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.irsa.account_id}:secret:rds!*"]
  }

  statement {
    sid    = "ReadAppSSMParameters"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = [
      "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.irsa.account_id}:parameter${var.ssm_parameter_path_prefix}/*"
    ]
  }
}

resource "aws_iam_role_policy" "external_secrets" {
  name   = "${var.name_prefix}-external-secrets-permissions"
  role   = aws_iam_role.external_secrets.id
  policy = data.aws_iam_policy_document.external_secrets_permissions.json
}

# ---- Cluster Autoscaler ----
# Namespace/name match the chart's defaults (kube-system/cluster-autoscaler).

data "aws_iam_policy_document" "cluster_autoscaler_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.cluster.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:cluster-autoscaler"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster_autoscaler" {
  name               = "${var.name_prefix}-cluster-autoscaler"
  assume_role_policy = data.aws_iam_policy_document.cluster_autoscaler_trust.json
  tags               = var.tags
}

data "aws_iam_policy_document" "cluster_autoscaler_permissions" {
  statement {
    sid    = "Describe"
    effect = "Allow"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeTags",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:DescribeInstanceTypes",
    ]
    resources = ["*"]
  }

  # Mutating actions scoped to only the ASGs behind THIS cluster's node
  # groups, via the same discovery tag the node group is tagged with
  # (k8s.io/cluster-autoscaler/<cluster-name> = owned) - not every ASG in
  # the account.
  statement {
    sid    = "MutateOwnedAsgsOnly"
    effect = "Allow"
    actions = [
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
      "autoscaling:UpdateAutoScalingGroup",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/${aws_eks_cluster.this.name}"
      values   = ["owned"]
    }
  }
}

resource "aws_iam_role_policy" "cluster_autoscaler" {
  name   = "${var.name_prefix}-cluster-autoscaler-permissions"
  role   = aws_iam_role.cluster_autoscaler.id
  policy = data.aws_iam_policy_document.cluster_autoscaler_permissions.json
}
