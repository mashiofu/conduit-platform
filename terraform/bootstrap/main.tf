# Bootstrap: provisions ONLY the S3 bucket that every other root module
# (terraform/envs/*) uses as its remote state backend.
#
# This has to be its own tiny root module with local state - you can't
# store a bucket's state inside the bucket it's creating. It changes
# essentially never after the first apply, so keeping its state local is a
# deliberate, documented trade-off rather than more infrastructure to
# solve a one-time problem.
#
# Not run yet as of this writing - see docs/design-decisions.md for why
# (the team deferred the real-AWS-apply decision independently of writing
# the code). To actually bootstrap an environment:
#
#   cd terraform/bootstrap
#   terraform init
#   terraform apply -var="state_bucket_name=<something-globally-unique>"
#
# then point terraform/live/backend.hcl at the bucket name it outputs
# (see backend.hcl.example there) and uncomment the backend "s3" block in
# live/versions.tf.

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
