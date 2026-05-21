provider "aws" {
  region = "us-east-1"
}

data "aws_ami" "nxtcloud_ami" {
  most_recent = true
  owners      = ["self", "amazon", "730335373015"]

  filter {
    name   = "name"
    values = ["nxtcloud-ami*"]
  }
}

# -------------------------------------------------------------
# [최강 보안 우회] IAM 권한 수정 및 Access Key 발급이 불가능한 실습용 계정 최적화
# -------------------------------------------------------------
# 이미 샌드박스 내에 다 막강한 권한으로 주어져 있는 'LabRole'과 'LabInstanceProfile'을 재사용합니다.
locals {
  lab_role_arn     = "arn:aws:iam::730335373015:role/SafeRole-pj-kmuai-01"
  ec2_profile_name = "SafeInstanceProfile-pj-kmuai-01"
}

# -------------------------------------------------------------
# 1. Amazon S3 (자료 보관소 및 프론트엔드/백엔드 공용 빌드 버킷)
# -------------------------------------------------------------
resource "aws_s3_bucket" "raw_bucket" {
  bucket        = "pj-kmuai-01-exam4me-raw-files"
  force_destroy = true

  lifecycle {
    ignore_changes = [
      tags,
      tags_all
    ]
  }
}

resource "aws_s3_bucket" "converted_bucket" {
  bucket        = "pj-kmuai-01-exam4me-converted-files"
  force_destroy = true

  lifecycle {
    ignore_changes = [
      tags,
      tags_all
    ]
  }
}

resource "aws_s3_bucket" "frontend_builds" {
  bucket        = "pj-kmuai-01-exam4me-frontend-builds"
  force_destroy = true

  lifecycle {
    ignore_changes = [
      tags,
      tags_all
    ]
  }
}

# -------------------------------------------------------------
# 2. Amazon SQS (비동기 처리 버퍼용 큐)
# -------------------------------------------------------------
resource "aws_sqs_queue" "conversion_queue" {
  name                      = "pj-kmuai-01-doc-conversion-queue"
  message_retention_seconds = 86400

  lifecycle {
    ignore_changes = [
      tags,
      tags_all
    ]
  }
}

# -------------------------------------------------------------
# 3. Amazon DynamoDB (고속 작업 상태 캐시)
# -------------------------------------------------------------
resource "aws_dynamodb_table" "status_cache" {
  name         = "pj-kmuai-01-platform-status-cache"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  lifecycle {
    ignore_changes = [
      tags,
      tags_all
    ]
  }
}

# -------------------------------------------------------------
# 4. Amazon RDS (관계형 데이터베이스)
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

  lifecycle {
    ignore_changes = [
      tags,
      tags_all
    ]
  }
}

# -------------------------------------------------------------
# 5. Amazon SNS (오류 피드백 알림 채널)
# -------------------------------------------------------------
resource "aws_sns_topic" "feedback_topic" {
  name = "pj-kmuai-01-feedback-resolved-topic"

  lifecycle {
    ignore_changes = [
      tags,
      tags_all
    ]
  }
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
  function_name    = "pj-kmuai-01-doc-converter-worker"
  role             = local.lab_role_arn
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

resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = aws_sqs_queue.conversion_queue.arn
  function_name    = aws_lambda_function.converter_worker.arn
  batch_size       = 1
}

# -------------------------------------------------------------
# 7. AWS Lambda (100% 무키 GitOps 배포 중계기 추가)
# -------------------------------------------------------------
data "archive_file" "deployer_zip" {
  type        = "zip"
  source_dir  = "../backend-deployer"
  output_path = "deployer_function.zip"
}

resource "aws_lambda_function" "git_deployer" {
  filename         = data.archive_file.deployer_zip.output_path
  function_name    = "pj-kmuai-01-git-deployer"
  role             = local.lab_role_arn
  handler          = "index.handler"
  runtime          = "nodejs18.x"
  source_code_hash = data.archive_file.deployer_zip.output_base64sha256

  environment {
    variables = {
      BUILD_BUCKET_NAME    = aws_s3_bucket.frontend_builds.bucket
      WORKER_FUNCTION_NAME = aws_lambda_function.converter_worker.function_name
      GITHUB_TOKEN         = "ghp_your_optional_github_token_here"
    }
  }
}

# Lambda Gateway 트리거용 권한 선언
resource "aws_lambda_permission" "apigw_deployer" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.git_deployer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*/deploy"
}

# -------------------------------------------------------------
# 8. Amazon EC2 (코어 API 서버 - 100% 무키 Git 배포 자동 동기화 에이전트 탑재)
# -------------------------------------------------------------
resource "aws_instance" "api_server" {
  ami           = data.aws_ami.nxtcloud_ami.id
  instance_type = "t3.micro"
  
  iam_instance_profile = local.ec2_profile_name

  # EC2 켜질때 기본 세팅 및 백그라운드 깃 동기화 데몬 구동 (Key가 불필요)
  user_data = <<-EOF
              #!/bin/bash
              sudo yum update -y
              sudo yum install git nodejs unzip -y
              git clone https://github.com/[YOUR_GITHUB_ID]/exam4me-service.git /app
              cd /app/backend-api
              npm install
              
              # 1. API 서버 구동 환경 변수
              echo "PORT=80" >> .env
              echo "AWS_REGION=ap-northeast-2" >> .env
              echo "SQS_QUEUE_URL=${aws_sqs_queue.conversion_queue.url}" >> .env
              echo "DYNAMODB_TABLE_NAME=${aws_dynamodb_table.status_cache.name}" >> .env
              echo "S3_RAW_BUCKET_NAME=${aws_s3_bucket.raw_bucket.bucket}" >> .env
              echo "SNS_TOPIC_ARN=${aws_sns_topic.feedback_topic.arn}" >> .env
              
              npm run start &
              
              # 2. 1분마다 S3의 최신 zip 파일 배포를 감시하는 무키 GitOps 동기화 스크립트 작성
              cat << 'OUTER' > /usr/local/bin/sync-gitops.sh
              #!/bin/bash
              BUCKET="${aws_s3_bucket.frontend_builds.bucket}"
              LOCAL_DIR="/app"
              
              # S3의 최신 코드 MD5 헤더 대조
              LATEST_HASH=$(aws s3api head-object --bucket $BUCKET --key latest-source.zip --query ETag --output text 2>/dev/null || echo "none")
              LAST_KNOWN_HASH=$(cat /var/tmp/last-gitops-hash.txt 2>/dev/null || echo "none")
              
              if [ "$LATEST_HASH" != "$LAST_KNOWN_HASH" ] && [ "$LATEST_HASH" != "none" ]; then
                  echo "🚀 최신 백엔드 코드 감지됨! 배포 업데이트 중..."
                  aws s3 cp s3://$BUCKET/latest-source.zip /var/tmp/latest-source.zip
                  
                  # 무중단 압축 해제 및 EC2 백엔드 리스타트
                  unzip -o /var/tmp/latest-source.zip -d /var/tmp/extracted-source
                  cp -rf /var/tmp/extracted-source/*/backend-api/* $LOCAL_DIR/
                  
                  cd $LOCAL_DIR
                  npm install
                  
                  # 기존 API Node 프로세스 리스타트
                  PID=$(lsof -t -i:80)
                  if [ ! -z "$PID" ]; then
                      kill -9 $PID
                  fi
                  npm run start &
                  
                  echo "$LATEST_HASH" > /var/tmp/last-gitops-hash.txt
                  echo "🎉 EC2 백엔드 API 무키 자동 업데이트 완료!"
              fi
              OUTER

              chmod +x /usr/local/bin/sync-gitops.sh
              
              # 크론탭에 1분 주기 등록하여 무인 기동
              echo "* * * * * /usr/local/bin/sync-gitops.sh >> /var/log/sync-gitops.log 2>&1" | crontab -
              EOF

  tags = {
    Name = "pj-kmuai-01-exam4me-api-server"
  }
}

# -------------------------------------------------------------
# 9. Amazon API Gateway (API Endpoint 및 배포 중계 웹훅 연동)
# -------------------------------------------------------------
resource "aws_apigatewayv2_api" "http_api" {
  name          = "pj-kmuai-01-exam4me-api-gateway"
  protocol_type = "HTTP"
}

# GitHub Webhook 수신을 위한 /deploy 경로 라우팅
resource "aws_apigatewayv2_integration" "deploy_integration" {
  api_id           = aws_apigatewayv2_api.http_api.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.git_deployer.arn
}

resource "aws_apigatewayv2_route" "deploy_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "POST /deploy"
  target    = "integrations/${aws_apigatewayv2_integration.deploy_integration.id}"
}

resource "aws_apigatewayv2_stage" "default_stage" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true
}

# -------------------------------------------------------------
# 10. AWS Amplify (OAuth 키 발급이 불필요한 웹 콘솔 GitHub 직접 바인딩용 템플릿)
# -------------------------------------------------------------
resource "aws_amplify_app" "frontend" {
  name       = "pj-kmuai-01-exam4me-frontend"
}

# resource "aws_amplify_branch" "main" {
#   app_id      = aws_amplify_app.frontend.id
#   branch_name = "main"
# }

# -------------------------------------------------------------
# 아웃풋 출력 (배포 완료 시 터미널 화면에 노출)
# -------------------------------------------------------------
output "api_gateway_url" {
  value = aws_apigatewayv2_api.http_api.api_endpoint
}

output "amplify_default_domain" {
  value = aws_amplify_app.frontend.default_domain
}
