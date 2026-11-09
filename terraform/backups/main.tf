# Off-server copies of the Postgres backups (every 3 days, k8s/platform/60-backups.yaml).
# Private, encrypted, TLS only. The uploader may only add files under postgres/: it can't read or
# delete earlier copies, so a leaked key can't destroy the history. S3 itself expires old copies.

data "aws_caller_identity" "me" {}

resource "aws_s3_bucket" "backups" {
  # A short hash instead of the account ID, since the name shows up in job logs on the Pulse page.
  bucket = "qwenops-pg-backups-${substr(sha1(data.aws_caller_identity.me.account_id), 0, 10)}"
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule { object_ownership = "BucketOwnerEnforced" } # no ACLs at all
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration { status = "Enabled" } # an overwrite keeps the earlier version
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket     = aws_s3_bucket.backups.id
  depends_on = [aws_s3_bucket_versioning.backups]
  rule {
    id     = "expire-old-copies"
    status = "Enabled"
    filter { prefix = "postgres/" }
    expiration { days = var.keep_days }
    noncurrent_version_expiration { noncurrent_days = 7 }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
}

resource "aws_s3_bucket_policy" "backups" {
  bucket     = aws_s3_bucket.backups.id
  depends_on = [aws_s3_bucket_public_access_block.backups]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "TLSOnly"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.backups.arn, "${aws_s3_bucket.backups.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

# ---------------------------------------------------------------- write-only uploader
resource "aws_iam_user" "uploader" {
  name = "qwenops-backup-uploader"
}

resource "aws_iam_user_policy" "uploader" {
  name = "add-backups-only"
  user = aws_iam_user.uploader.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AddCopies"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.backups.arn}/postgres/*"
      },
      {
        Sid       = "ListToVerifyUpload"
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = aws_s3_bucket.backups.arn
        Condition = { StringLike = { "s3:prefix" = ["postgres/*"] } }
      },
    ]
  })
}
