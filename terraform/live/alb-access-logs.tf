# S3 bucket for both ALBs' access logs (backend + frontend Ingresses -
# see helm/backend-chart and helm/frontend-chart's ingress.yaml). The one
# tier's log ALB's own request log wasn't going anywhere until this - see
# docs/design-decisions.md. AWS only supports ALB access-log delivery to
# S3, never straight to CloudWatch, which is the whole reason this bucket
# exists at all in an architecture that otherwise has no application use
# for one (see the S3 entry in docs/design-decisions.md).

resource "aws_s3_bucket" "alb_access_logs" {
  bucket = "${local.name_prefix}-alb-logs-${data.aws_caller_identity.live.account_id}"
  tags   = local.common_tags

  # Everything in this bucket is auto-generated (ALB's own delivery, plus
  # the AWS-written ELBAccessLogTestFile) and already expires in 30 days
  # on its own - nothing here is worth a manual "empty the bucket first"
  # step before `terraform destroy`, unlike the old CDN frontend bucket
  # this project used to have (see docs/design-decisions.md's teardown
  # note). Set here instead of hit live during an actual teardown.
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "alb_access_logs" {
  bucket = aws_s3_bucket.alb_access_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Access logs are useful for a while, not forever - expire rather than
# let this grow unbounded. 30 days regardless of environment: unlike
# Prometheus's retention (which scales with how long an environment is
# expected to run), there's no real argument for prod needing a longer
# access-log window than dev in this project.
resource "aws_s3_bucket_lifecycle_configuration" "alb_access_logs" {
  bucket = aws_s3_bucket.alb_access_logs.id

  rule {
    id     = "expire-after-30-days"
    status = "Enabled"

    filter {}

    expiration {
      days = 30
    }
  }
}

# The regional ELB log-delivery service account - resolved via this
# data source rather than hardcoding the per-region account ID AWS
# publishes for this (127311923021 for us-east-1), so this keeps
# working correctly if aws_region ever changes.
data "aws_elb_service_account" "this" {}

data "aws_iam_policy_document" "alb_access_logs" {
  # The classic, still-required grant: the regional ELB service account
  # writing log objects directly.
  statement {
    effect  = "Allow"
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.alb_access_logs.arn}/*",
    ]

    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.this.arn]
    }
  }

  # The newer delivery.logs service-principal grant AWS added for the
  # same feature - both statements are included together because AWS's
  # own documentation for this bucket policy still shows them side by
  # side; a missing one either way is a silent AccessDenied on log
  # delivery, not a loud failure anywhere.
  statement {
    effect  = "Allow"
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.alb_access_logs.arn}/*",
    ]

    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket_policy" "alb_access_logs" {
  bucket = aws_s3_bucket.alb_access_logs.id
  policy = data.aws_iam_policy_document.alb_access_logs.json
}
