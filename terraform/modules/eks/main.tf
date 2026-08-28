# ---- Cluster ----

data "aws_iam_policy_document" "eks_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.name_prefix}-eks-cluster"
  assume_role_policy = data.aws_iam_policy_document.eks_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "this" {
  name     = "${var.name_prefix}-cluster"
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    endpoint_private_access = true
    endpoint_public_access  = true # simplest for a take-home/demo cluster; a real prod cluster would likely restrict this to a VPN/bastion CIDR
  }

  # Modern IAM-based access control (EKS access entries) rather than the
  # legacy aws-auth ConfigMap - see aws_eks_access_entry below for whoever
  # actually gets cluster-admin.
  access_config {
    authentication_mode = "API"
  }

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]

  tags = merge(var.tags, { Name = "${var.name_prefix}-cluster" })
}

# Grants the identity that runs `terraform apply` (whichever IAM
# user/role is behind your configured AWS credentials - see
# deploy.env.example) cluster-admin. Add further access entries here for
# anyone else who needs kubectl/Helm access.
data "aws_caller_identity" "current" {}

resource "aws_eks_access_entry" "applier" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = data.aws_caller_identity.current.arn
}

resource "aws_eks_access_policy_association" "applier_admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = data.aws_caller_identity.current.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# conduit-platform's GitHub Actions role - the only CI identity that ever
# runs `helmfile apply` against this cluster (see live/main.tf's
# github_role_platform_ci). Cluster-admin at the k8s RBAC layer is
# deliberate here: helmfile manages namespaces, CRDs, and cluster-scoped
# resources across every add-on, so a narrower built-in policy
# (EKSEditPolicy etc.) would be fighting the tool. The actual restriction
# is at the IAM layer - only conduit-platform's own OIDC subject can ever
# assume this role in the first place.
resource "aws_eks_access_entry" "platform_ci" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.platform_ci_role_arn
}

resource "aws_eks_access_policy_association" "platform_ci_admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.platform_ci_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# ---- IRSA: the cluster's own OIDC provider, separate from the GitHub
# Actions one in iam-github-oidc-provider - this is what lets individual
# Kubernetes ServiceAccounts assume scoped IAM roles. ----

data "tls_certificate" "cluster_oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "cluster" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster_oidc.certificates[0].sha1_fingerprint]

  tags = var.tags
}

# ---- Node group ----

data "aws_iam_policy_document" "node_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.name_prefix}-eks-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr_readonly" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name_prefix}-nodes"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids

  instance_types = var.node_instance_types
  capacity_type  = var.node_capacity_type

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  # Propagates to the underlying (EKS-managed) ASG, which is how Cluster
  # Autoscaler auto-discovers this node group instead of needing it
  # hardcoded into the Helm release's values.
  tags = merge(var.tags, {
    "k8s.io/cluster-autoscaler/enabled"                      = "true"
    "k8s.io/cluster-autoscaler/${aws_eks_cluster.this.name}" = "owned"
  })

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr_readonly,
  ]
}

# ---- EKS-managed add-ons: these are AWS API-native, not Helm charts, so
# they stay in Terraform even though the other add-ons (LB Controller,
# ESO, Cluster Autoscaler, kube-prometheus-stack) are deliberately
# managed via Helmfile instead - see conduit-platform/helm/. ----

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "vpc-cni"
  tags         = var.tags

  # Without this, NetworkPolicy manifests (see the backend Helm chart)
  # apply cleanly but enforce nothing - the VPC CNI's policy enforcement
  # is opt-in, not the default.
  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
  })
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "coredns"
  tags         = var.tags

  # CoreDNS pods schedule onto nodes, so they need the node group to
  # exist first, or the addon can get stuck waiting for schedulable
  # capacity.
  depends_on = [aws_eks_node_group.this]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "kube-proxy"
  tags         = var.tags
}

resource "aws_eks_addon" "cloudwatch_observability" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "amazon-cloudwatch-observability"
  tags         = var.tags

  depends_on = [aws_eks_node_group.this]
}

# ---- Node <-> data tier: the security group RDS/ElastiCache actually
# grant ingress to. EKS creates and manages this one itself (the "cluster
# security group") - reusing it instead of hand-rolling a parallel one. ----

# (exposed via the cluster_security_group_id output below)
