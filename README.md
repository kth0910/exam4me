# Exam4Me 플랫폼 GitOps 무키(Keyless) 자동화 마스터 가이드

본 가이드는 **AWS IAM 권한 수정이 제한되고, Access Key 발급 자체가 불가능한 실습용/샌드박스 환경(예: AWS Academy 등)**에서 오직 **9가지 AWS 지정 서비스(`EC2, Lambda, RDS, DynamoDB, S3, API GW, Amplify, SQS, SNS`)**만을 조합하여, 백엔드와 프론트엔드 전체를 **`git push` 단 한 번만으로 완전 자동 배포**하는 무키(Keyless) GitOps 파이프라인 매뉴얼입니다.

---

## 1. 100% 무키(Keyless) 프론트/백엔드 통합 자동화 아키텍처

```mermaid
graph TD
    %% GitHub Push
    Dev[개발자 / 디자이너] -->|1. git push| Git[GitHub Repository]
    
    %% Amplify Flow (FrontEnd)
    Git -->|Push 감지 즉시 자동 갱신| Amplify[AWS Amplify: GitHub 로그인 직접 연동]
    Amplify -->|실시간 프론트엔드 배포 완료| User[사용자 브라우저]
    
    %% Webhook Flow (BackEnd)
    Git -->|2. Webhook POST 전송 (Key 필요 없음)| APIGW[AWS API Gateway]
    
    subgraph AWS 샌드박스 (100% 무키 & LabRole 활용)
        APIGW -->|3. 트리거| Deployer[배포 중계 Lambda: git-deployer]
        Deployer -->|4. GitHub 최신 소스 zip 다운로드| Deployer
        Deployer -->|5. S3 버킷에 zip 적재| S3[Amazon S3: 빌드 스토리지]
        Deployer -->|6. 워커 Lambda 코드 즉시 배포| Worker[Lambda: 문서 변환 워커]
        
        S3 -->|7. 1분 주기 무키 감시 동기화| EC2[EC2: API Server]
        EC2 -->|8. 최신 코드 자동 압축 해제 및 프로세스 재기동| EC2
    end
```

---

## 2. 프로젝트 폴더 구조 (`exam4me/`)

```text
exam4me/
├── frontend/
│   └── index.html           # 디자인 대기용 Placeholder HTML (추후 디자인 코드 반영 경로)
├── backend-api/             # EC2 API 서버 (Node.js/Express)
│   ├── package.json
│   └── server.js
├── backend-worker/          # Lambda 비동기 파일 변환 워커 (Node.js)
│   ├── package.json
│   └── index.js
├── backend-deployer/        # [NEW] GitOps 배포 중계 람다 (Access Key 대체)
│   ├── package.json
│   └── index.js
├── infra/                   # AWS 9개 자원 관리 IaC (Terraform)
│   └── main.tf              # 배포 중계기 및 EC2 동기화 데몬이 세팅된 테라폼
└── README.md                # 본 가이드라인
```

---

## 3. 배포 직전 단계: 실습실 100% 무키 자동화 3단계

### 1단계: GitHub에 소스 코드 Push
1. 본인의 **GitHub** 계정에 새로운 Private Repository를 생성합니다 (예: `exam4me-service`).
2. 로컬 터미널을 열고 `exam4me` 폴더로 진입하여 코드를 Push합니다.
   ```bash
   cd "c:\Users\kth_0\OneDrive\바탕 화면\학교자료\2026-1학기\AWSAI기초\exam4me"
   git init
   git add .
   git commit -m "feat: complete keyless front/backend GitOps"
   git branch -M main
   git remote add origin https://github.com/[YOUR_GITHUB_ID]/exam4me-service.git
   git push -u origin main
   ```

---

### 2단계: AWS CloudShell에서 인프라 배포 (최초 1회 및 변경 시)
AWS 웹 브라우저 내부에 내장된 **CloudShell** 터미널을 활용합니다. 웹 콘솔 로그인 자격 증명을 100% 그대로 이어받으므로 **Access Key 발급이나 입력이 전혀 필요하지 않습니다.**
1. AWS 웹 콘솔에 로그인한 뒤, 우측 상단 터미널 아이콘을 눌러 **AWS CloudShell**을 실행합니다.
2. CloudShell 터미널 창에 아래 명령어를 복사하여 실행합니다:
   ```bash
   # 1. 깃허브에서 프로젝트 클론
   git clone https://github.com/[YOUR_GITHUB_ID]/exam4me-service.git
   cd exam4me-service/infra

   # 2. Terraform 설치 및 실행
   # (main.tf는 샌드박스의 'LabRole'을 재사용하므로 IAM 권한 에러 없이 통과됩니다.)
   terraform init
   terraform apply -auto-approve
   ```
3. **결과**: API Gateway, EC2, Lambda(워커, 중계기), S3, DynamoDB 등 9개 자원이 자동으로 생성 및 구성됩니다.
4. **출력 확인**: 배포 성공 시 터미널 화면에 노출되는 `api_gateway_url` 주소를 메모합니다.

---

### 3단계: GitHub Webhook 및 Amplify GitHub 연동 (최초 1회)
어떠한 Key 발급 없이 웹 화면의 간편 연동만을 사용하여 CI/CD를 영구 활성화합니다.

#### ❶ 프론트엔드 연동 (Amplify)
1. AWS 웹 콘솔 ➔ **AWS Amplify** 서비스로 이동합니다.
2. 생성되어 있는 `exam4me-frontend` 앱을 클릭하여 진입합니다.
3. [GitHub과 연동]을 클릭한 후, 웹 팝업창에서 **본인의 GitHub 계정을 연동(승인)**하고 `main` 브랜치를 매핑합니다.
4. **결과**: `frontend/` 안의 파일들이 도메인으로 최초 자동 배포되며, 이후 `git push`마다 프론트엔드가 실시간 자동 리빌드됩니다.

#### ❷ 백엔드 연동 (GitHub Webhook ➔ API Gateway)
1. 본인의 **GitHub 저장소**(`exam4me-service`) ➔ **[Settings]** ➔ **[Webhooks]** ➔ **[Add webhook]**으로 이동합니다.
2. **Payload URL**: 2단계 테라폼 배포 완료 화면에서 획득한 `api_gateway_url` 뒤에 `/deploy`를 붙여 기입합니다.
   *   예: `https://[API_GW_ID].execute-api.ap-northeast-2.amazonaws.com/deploy`
3. **Content type**: `application/json` 선택 후 등록을 완료합니다.

---

### 💡 최종 작동 확인 및 개발자 경험
*   **프론트엔드**: 로컬에서 디자인 변경 후 `git push` ➔ Amplify가 깃웹훅을 수신해 웹 화면 실시간 자동 갱신! (Keyless)
*   **백엔드**: 백엔드 코드 수정 후 `git push` ➔ GitHub Webhook 전송 ➔ API Gateway ➔ 중계 Lambda(`git-deployer`)가 다운로드 후 **람다 워커 코드 자동 갱신** 및 **S3에 zip 적재** ➔ EC2 API 서버 내에 심어진 동기화 데몬이 **최신 zip을 감지하여 1분 내에 자동으로 풀(pull)받아 API 서비스 중단 없이 즉시 리스타트 및 갱신!** (Keyless)

로컬에 어떠한 AWS Access Key도 보관하지 않는 극한의 보안 조건 하에서도, 프론트엔드 디자인 및 백엔드 서버 기능 모두 완벽한 **자동 CI/CD 무키 파이프라인**을 확보했습니다.
