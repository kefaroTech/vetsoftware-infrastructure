data "aws_ssm_parameter" "ami" {
  name = var.ami_ssm_parameter
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name_prefix        = "${var.name}-${var.service_name}-"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/${var.name}/${var.service_name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

data "aws_iam_policy_document" "runtime" {
  statement {
    sid = "WriteServiceLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents"
    ]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }

  dynamic "statement" {
    for_each = length(var.secret_arns) > 0 ? [1] : []

    content {
      sid       = "ReadRuntimeSecrets"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = var.secret_arns
    }
  }
}

resource "aws_iam_role_policy" "runtime" {
  name   = "runtime"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.runtime.json
}

resource "aws_iam_instance_profile" "this" {
  name_prefix = "${var.name}-${var.service_name}-"
  role        = aws_iam_role.this.name
  tags        = var.tags
}

resource "aws_instance" "this" {
  count = var.instance_count

  ami                         = data.aws_ssm_parameter.ami.value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_ids[count.index % length(var.subnet_ids)]
  vpc_security_group_ids      = var.security_group_ids
  associate_public_ip_address = var.associate_public_ip_address
  iam_instance_profile        = aws_iam_instance_profile.this.name

  user_data                   = var.user_data
  user_data_replace_on_change = true

  monitoring              = var.detailed_monitoring
  ebs_optimized           = true
  disable_api_termination = var.disable_api_termination

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  root_block_device {
    encrypted             = true
    volume_size           = var.root_volume_size
    volume_type           = var.root_volume_type
    delete_on_termination = true
  }

  tags = merge(var.tags, {
    Name    = "${var.name}-${var.service_name}-${count.index + 1}"
    Service = var.service_name
  })

  volume_tags = merge(var.tags, {
    Name    = "${var.name}-${var.service_name}-${count.index + 1}"
    Service = var.service_name
  })

  lifecycle {
    create_before_destroy = true
  }
}
