# Bootstrap: provisions ONLY the S3 bucket that every other root module
# (terraform/live/) uses as its remote state backend.
#
# This has to be its own tiny root module with local state - you can't
# store a bucket's state inside the bucket it's creating. It changes
# essentially never after the first apply, so keeping its state local is a
# deliberate, documented trade-off rather than more infrastructure to
# solve a one-time problem.
#
# Applied and used as the real backend for dev's entire build, deploy,
# and teardown - see docs/design-decisions.md and docs/cost-estimate.md.
# To bootstrap a fresh environment yourself:
#
#   cd terraform/bootstrap
#   terraform init
#   terraform apply -var="state_bucket_name=<something-globally-unique>"
#
# then point terraform/live/backend.hcl at the bucket name it outputs
# (see backend.hcl.example there) and uncomment the backend "s3" block in
# live/versions.tf.
#
# Tearing down: this bucket is deliberately not force_destroy - state
# history shouldn't be casually destroyable - so a plain `terraform
# destroy` here fails on a non-empty (versioned) bucket. Purge every
# object version and delete marker first (`aws s3api list-object-versions`
# / `delete-objects`, the same approach `docs/design-decisions.md`
# documents for the old CDN frontend bucket), confirm the bucket is
# actually empty, then destroy - and only ever as the true last step,
# once terraform/live/'s own destroy has already finished and been
# verified, since live/'s backend depends on this bucket existing for
# every command up to that point.

resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name

  # Deliberately no `force_destroy` - state history should not be
  # casually destroyable.

  tags = {
    Project   = "conduit"
    ManagedBy = "terraform"
    Purpose   = "terraform-remote-state"
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# State history is tiny and worth keeping longer than a frontend build's
# (it's the actual audit trail of every infra change), but still capped
# rather than growing forever.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
