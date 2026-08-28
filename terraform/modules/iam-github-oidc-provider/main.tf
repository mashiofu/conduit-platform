# One OIDC identity provider per AWS account for GitHub Actions - this is
# a singleton (AWS rejects a second provider for the same URL), so it's
# its own tiny module instantiated once from envs/dev, while individual
# roles that trust it (one per repo, least privilege) live in the
# iam-github-actions-role module and can be instantiated as many times as
# needed.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # GitHub's documented OIDC thumbprint. AWS validates the actual TLS
  # certificate chain for this well-known endpoint regardless of this
  # value, but the resource schema still requires one.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = var.tags
}
