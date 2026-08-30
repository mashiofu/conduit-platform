# EKS Pod Identity for the "Amazon CloudWatch Observability" addon -
# deliberately not IRSA like iam-irsa.tf's three roles. Those three are
# for Helmfile-installed charts, where the chart's own
# serviceAccount.annotations sets the eks.amazonaws.com/role-arn
# annotation IRSA needs - Terraform's job there stops at "the role
# exists." This addon's ServiceAccount (cloudwatch-agent, in the
# amazon-cloudwatch namespace) is created by the EKS addon itself, not
# by a Helm chart Terraform has values access to - annotating it after
# the fact would mean Terraform reaching into a live Kubernetes object,
# which is exactly the Terraform/Helm boundary this project deliberately
# keeps separate (see docs/design-decisions.md). Pod Identity sidesteps
# that entirely: the association below is a pure EKS/IAM API call, no
# Kubernetes object mutation involved.
#
# Found live, not caught by inspection: this addon had been running
# with zero IAM permissions wired up for this whole project's testing -
# fluent-bit/cloudwatch-agent were up and "Running" the entire time,
# but every log write failed with AccessDeniedException, so no logs
# ever actually reached CloudWatch. Confirmed via `aws logs
# describe-log-groups` returning empty and reading the pods' own error
# logs directly.

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "eks-pod-identity-agent"
  tags         = var.tags

  # The agent is a DaemonSet - same reasoning as coredns above, needs
  # schedulable nodes to actually come up.
  depends_on = [aws_eks_node_group.this]
}

data "aws_iam_policy_document" "cloudwatch_observability_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cloudwatch_observability" {
  name               = "${var.name_prefix}-cloudwatch-observability"
  assume_role_policy = data.aws_iam_policy_document.cloudwatch_observability_trust.json
  tags               = var.tags
}

# AWS-managed policy, not hand-rolled - this is exactly what it's for
# (CloudWatchAgent's own logs/metrics writes), and matches what AWS's
# own setup docs for this addon specify.
resource "aws_iam_role_policy_attachment" "cloudwatch_observability" {
  role       = aws_iam_role.cloudwatch_observability.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_eks_pod_identity_association" "cloudwatch_observability" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "amazon-cloudwatch"
  service_account = "cloudwatch-agent"
  role_arn        = aws_iam_role.cloudwatch_observability.arn

  depends_on = [aws_eks_addon.pod_identity_agent]
}
