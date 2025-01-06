provider "aws" {
  region = "eu-west-1"
  profile = "terraform-user"
}

# Key Pair
resource "aws_key_pair" "key" {
  key_name   = "ledger-key-pair"
  public_key = file("~/.ssh/LedgerKeyPair.pub")
}

# Security Group
resource "aws_security_group" "ledger_app_sg" {
  name_prefix = "ledger-app-sg"

  ingress {
    description = "Allow HTTP traffic"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow MySQL traffic (restricted)"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["18.200.97.133/32"]
  }

  ingress {
    description = "Allow SSH traffic"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["18.200.97.133/32"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# EC2 Instance
resource "aws_instance" "ledger_app" {
  ami           = "ami-0a094c309b87cc107"
  instance_type = "t2.micro"
  key_name      = aws_key_pair.key.key_name

  security_groups = [aws_security_group.ledger_app_sg.name]

  user_data = <<-EOF
    #!/bin/bash
    set -e
    yum update -y
    yum install -y docker git unzip
    systemctl start docker
    systemctl enable docker
    usermod -aG docker ec2-user
    curl -L "https://github.com/docker/compose/releases/download/2.10.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    git clone https://github.com/bulutaysarac/LedgerApp.git /var/www/laravel
    cd /var/www/laravel
    cp .env.example .env
    /usr/local/bin/docker-compose up -d
    docker exec app-container-name php artisan key:generate
    docker exec app-container-name php artisan migrate --force
  EOF

  tags = {
    Name        = "ledger-app-server"
    Environment = "Development"
    Project     = "LedgerApp"
  }

  depends_on = [aws_security_group.ledger_app_sg]
}

# SQS Queue
resource "aws_sqs_queue" "face_api_queue" {
  name                      = "FaceAPIQueue"
  delay_seconds             = 0
  visibility_timeout_seconds = 30
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda_execution_role" {
  name = "lambda_execution_role"

  assume_role_policy = <<-EOF
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Action": "sts:AssumeRole",
          "Principal": {
            "Service": "lambda.amazonaws.com"
          },
          "Effect": "Allow",
          "Sid": ""
        }
      ]
    }
  EOF
}

resource "aws_iam_policy" "lambda_policy" {
  name = "lambda_policy"

  policy = <<-EOF
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Action": [
            "sqs:SendMessage",
            "sqs:ReceiveMessage",
            "sqs:DeleteMessage",
            "sqs:GetQueueAttributes"
          ],
          "Effect": "Allow",
          "Resource": "${aws_sqs_queue.face_api_queue.arn}"
        },
        {
          "Action": "logs:*",
          "Effect": "Allow",
          "Resource": "arn:aws:logs:*"
        }
      ]
    }
  EOF
}

resource "aws_iam_role_policy_attachment" "lambda_policy_attach" {
  role       = aws_iam_role.lambda_execution_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

# Lambda Function
resource "aws_lambda_function" "face_api" {
  function_name = "FaceAPIProcessor"
  role          = aws_iam_role.lambda_execution_role.arn
  runtime       = "nodejs16.x"
  handler       = "index.handler"

  # Specify the local zip file for deployment
  filename      = "${path.module}/lambda.zip"

  # Ensure the zip file changes trigger redeployment
  source_code_hash = filebase64sha256("${path.module}/lambda.zip")

  # Environment variables for Lambda
  environment {
    variables = {
      SQS_QUEUE_URL = aws_sqs_queue.face_api_queue.url
    }
  }

  # Ensure Terraform waits for the Lambda function to be ready
  depends_on = [aws_iam_role_policy_attachment.lambda_policy_attach]
}

resource "aws_lambda_event_source_mapping" "sqs_event" {
  event_source_arn = aws_sqs_queue.face_api_queue.arn
  function_name    = aws_lambda_function.face_api.arn
  batch_size       = 10
  enabled          = true
}

# API Gateway
resource "aws_api_gateway_rest_api" "face_api" {
  name        = "FaceAPIRequestQueue"
  description = "API Gateway for Face API requests"
}

resource "aws_api_gateway_resource" "face_api_resource" {
  rest_api_id = aws_api_gateway_rest_api.face_api.id
  parent_id   = aws_api_gateway_rest_api.face_api.root_resource_id
  path_part   = "face"
}

resource "aws_api_gateway_method" "face_api_method" {
  rest_api_id   = aws_api_gateway_rest_api.face_api.id
  resource_id   = aws_api_gateway_resource.face_api_resource.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "face_api_integration" {
  rest_api_id = aws_api_gateway_rest_api.face_api.id
  resource_id = aws_api_gateway_resource.face_api_resource.id
  http_method = aws_api_gateway_method.face_api_method.http_method

  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.face_api.invoke_arn

  request_templates = {
    "application/json" = <<-EOF
      {
        "body": $input.body
      }
    EOF
  }
}

resource "aws_api_gateway_deployment" "face_api_deployment" {
  rest_api_id = aws_api_gateway_rest_api.face_api.id
  stage_name  = "dev"

  depends_on = [aws_api_gateway_integration.face_api_integration]
}

# Outputs
output "instance_public_ip" {
  value = aws_instance.ledger_app.public_ip
}

output "instance_public_dns" {
  value = aws_instance.ledger_app.public_dns
}

output "api_gateway_url" {
  value = aws_api_gateway_deployment.face_api_deployment.invoke_url
}

output "sqs_queue_url" {
  value = aws_sqs_queue.face_api_queue.url
}

output "ssh_instructions" {
  value = "Use 'ssh -i ~/.ssh/LedgerKeyPair.pem ec2-user@${aws_instance.ledger_app.public_ip}' to connect to your instance."
}