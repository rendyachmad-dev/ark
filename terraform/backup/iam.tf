# The VPS is not an EC2 instance, so it cannot assume an instance role.
# It needs long-lived credentials — which makes scoping them tightly the whole
# point of this file.
#
# The backup identity can write objects and list its own prefix. It cannot
# delete, cannot change the bucket configuration, and cannot touch anything
# outside var.backup_prefix.

resource "aws_iam_user" "backup_agent" {
  name = "${var.project}-backup-agent"
  path = "/${var.project}/"
}

resource "aws_iam_access_key" "backup_agent" {
  user = aws_iam_user.backup_agent.name
}

data "aws_iam_policy_document" "backup_agent" {
  # Discovery: the agent needs to list only its own prefix, not the bucket.
  statement {
    sid    = "ListOwnPrefix"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation"
    ]
    resources = [aws_s3_bucket.backups.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.backup_prefix}*", var.backup_prefix]
    }
  }

  # Write and read back, for restores. No DeleteObject: lifecycle rules handle
  # expiry, so a compromised VPS cannot wipe the backup history.
  statement {
    sid    = "WriteAndReadBackups"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts"
    ]
    resources = ["${aws_s3_bucket.backups.arn}/${var.backup_prefix}*"]
  }

  # Restoring from Glacier requires an explicit restore request.
  statement {
    sid       = "RestoreFromGlacier"
    effect    = "Allow"
    actions   = ["s3:RestoreObject"]
    resources = ["${aws_s3_bucket.backups.arn}/${var.backup_prefix}*"]
  }
}

resource "aws_iam_user_policy" "backup_agent" {
  name   = "${var.project}-backup-agent-policy"
  user   = aws_iam_user.backup_agent.name
  policy = data.aws_iam_policy_document.backup_agent.json
}
