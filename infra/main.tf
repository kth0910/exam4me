provider "aws" {
  region = "ap-northeast-2"
}

# -------------------------------------------------------------
# 1. Amazon S3 (교육 자료 원본 및 가공물 보관소)
# -------------------------------------------------------------
resource "aws_s3_bucket" "raw_bucket" {
  bucket        = "exam4me-raw-files"
  force_destroy = true
}

resource "aws_s3_bucket" "converted_bucket" {
  bucket        = "exam4me-converted-files"
  force_destroy = true
}

# -------------------------------------------------------------
# 2. Amazon SQS (비동기 처리 버퍼용 큐)
# -------------------------------------------------------------
resource "aws_sqs_queue" "conversion_queue" {
  name                      = "doc-conversion-queue"
  message_retention_seconds = 86400
}

# -------------------------------------------------------------
# 3. Amazon DynamoDB (고속 작업 상태 캐시 및 메타데이터 캐시)
# -------------------------------------------------------------
resource "aws_dynamodb_table" "status_cache" {
  name         = "platform-status-cache"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }
}

# -------------------------------------------------------------
# 4. Amazon RDS (관계형 데이터베이스 - 유저 마케팅 정보 & 커뮤니티 데이터)
# -------------------------------------------------------------
resource "aws_db_instance" "core_db" {
  allocated_storage   = 20
  engine              = "mysql"
  engine_version      = "8.0"
  instance_class      = "db.t3.micro"
  db_name             = "exam4me"
  username            = "admin"
  password            = "exam4meSecurePassword2026!"
  skip_final_snapshot = true
}

# -------------------------------------------------------------
# 5. Amazon SNS (오류 피드백 알림 이메일 발송 채널)
# -------------------------------------------------------------
resource "aws_sns_topic" "feedback_topic" {
  name = "feedback-resolved-topic"
}

# -------------------------------------------------------------
# 6. AWS Lambda (비동기 문서 변환 서버리스 워커)
# -------------------------------------------------------------
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "../backend-worker"
  output_path = "lambda_function.zip"
}

resource "aws_lambda_function" "converter_worker" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "doc-converter-worker"
  role             = aws_iam_role.lambda_role.arn
  handler          = "index.handler"
  runtime          = "nodejs18.x"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      DYNAMODB_TABLE_NAME    = aws_dynamodb_table.status_cache.name
      S3_OUTPUT_BUCKET_NAME = aws_s3_bucket.converted_bucket.bucket
    }
  }
}

# Lambda SQS 이벤트 맵핑 (큐에 메시지 인입 시 람다 즉각 트리거)
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = aws_sqs_queue.conversion_queue.arn
  function_name    = aws_lambda_function.converter_worker.arn
  batch_size       = 1
}

# -------------------------------------------------------------
# 7. Amazon EC2 (코어 API 서버 - 24시간 가동 웹 앱)
# -------------------------------------------------------------
resource "aws_instance" "api_server" {
  ami           = "ami-0c55b159cbfafe1f0" # Amazon Linux 2 (ap-northeast-2 기준)
  instance_type = "t3.micro"
  
  # EC2 자체에 다른 AWS 자원을 무키로 제어할 수 있는 IAM 역할 부여
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name

  # 서버 부트스트랩 스크립트 (켜지는 즉시 Git에서 코드 받아 자동 실행)
  user_data = <<-EOF
              #!/bin/bash
              sudo yum update -y
              sudo yum install git nodejs -y
              git clone https://github.com/[YOUR_GITHUB_ID]/exam4me-service.git /app
              cd /app/backend-api
              npm install
              
              # 환경 변수 정의
              echo "PORT=80" >> .env
              echo "AWS_REGION=ap-northeast-2" >> .env
              echo "SQS_QUEUE_URL=${aws_sqs_queue.conversion_queue.url}" >> .env
              echo "DYNAMODB_TABLE_NAME=${aws_dynamodb_table.status_cache.name}" >> .env
              echo "S3_RAW_BUCKET_NAME=${aws_s3_bucket.raw_bucket.bucket}" >> .env
              echo "SNS_TOPIC_ARN=${aws_sns_topic.feedback_topic.arn}" >> .env
              
              npm run start &
              EOF

  tags = {
    Name = "exam4me-api-server"
  }
}

# -------------------------------------------------------------
# 8. Amazon API Gateway (프론트엔드 API 단일 접점)
# -------------------------------------------------------------
resource "aws_apigatewayv2_api" "http_api" {
  name          = "exam4me-api-gateway"
  protocol_type = "HTTP"
}

# -------------------------------------------------------------
# 9. AWS Amplify (프론트엔드 GitHub 웹훅 연동 호스팅)
# -------------------------------------------------------------
resource "aws_amplify_app" "frontend" {
  name       = "exam4me-frontend"
  repository = "https://github.com/[YOUR_GITHUB_ID]/exam4me-service"
  
  # GitHub Personal Access Token을 AWS 보안 정보 스토어 등에 임시 저장하여 인증
  oauth_token = "ghp_your_temporary_github_token_here_if_applicable"

  build_spec = <<-EOF
    version: 1
    frontend:
      phases:
        build:
          commands:
            - echo "Deploying static UI/UX build..."
      artifacts:
        baseDirectory: frontend
        files:
          - '**/*'
      cache:
        paths: []
  EOF
}

resource "aws_amplify_branch" "main" {
  app_id      = aws_amplify_app.frontend.id
  branch_name = "main"
}

# -------------------------------------------------------------
# [부속 보안 및 권한 설정 - IAM 역할]
# -------------------------------------------------------------
resource "aws_iam_role" "lambda_role" {
  name = "exam4me-lambda-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Lambda용 추가 권한 (SQS 수신, S3 및 DynamoDB 쓰기 권한)
resource "aws_iam_policy" "lambda_custom_policy" {
  name = "exam4me-lambda-custom-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.conversion_queue.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem"
        ]
        Resource = aws_dynamodb_table.status_cache.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_custom" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_custom_policy.arn
}

resource "aws_iam_role" "ec2_role" {
  name = "exam4me-ec2-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# EC2 권한 (S3 URL 발급, SQS 전송, DynamoDB 조회, SNS 발송 권한)
resource "aws_iam_policy" "ec2_custom_policy" {
  name = "exam4me-ec2-custom-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:SendMessage"
        ]
        Resource = aws_sqs_queue.conversion_queue.arn
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem"
        ]
        Resource = aws_dynamodb_table.status_cache.arn
      },
      {
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = aws_sns_topic.feedback_topic.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_custom" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.ec2_custom_policy.arn
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "exam4me-ec2-instance-profile"
  role = aws_iam_role.ec2_role.name
}

# -------------------------------------------------------------
# 아웃풋 출력 (배포 완료 시 터미널 화면에 노출)
# -------------------------------------------------------------
output "api_gateway_url" {
  value = aws_apigatewayv2_api.http_api.api_endpoint
}

output "amplify_default_domain" {
  value = aws_amplify_app.frontend.default_domain
}
