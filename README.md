# Exam4Me 플랫폼 GitOps 배포 프로젝트 구성 안내

본 가이드는 오직 **9가지 AWS 지정 서비스(`EC2, Lambda, RDS, DynamoDB, S3, API GW, Amplify, SQS, SNS`)**를 활용하며, 장기 Access Key 노출 없이 **OIDC(OpenID Connect)** 및 **Amplify GitHub 웹훅**만을 사용해 배포하는 완전 무키(Keyless) 프로젝트 스켈레톤 구축 매뉴얼입니다.

---

## 1. 프로젝트 폴더 구조 (`exam4me/`)

본 디렉토리 하위에 다음과 같이 완벽한 배포 스켈레톤이 구성되었습니다.

```text
exam4me/
├── .github/
│   └── workflows/
│       └── deploy.yml       # GitHub Actions OIDC 무키 배포 워크플로우
├── frontend/
│   └── index.html           # Amplify와 최초 연동될 디자인 대기용 Placeholder HTML
├── backend-api/             # EC2 API 서버 (Node.js/Express)
│   ├── package.json
│   └── server.js
├── backend-worker/          # Lambda 비동기 파일 변환 워커 (Node.js)
│   ├── package.json
│   └── index.js
├── infra/                   # AWS 9개 자원 관리 IaC (Terraform)
│   └── main.tf
└── README.md                # 본 마스터 가이드
```

---

## 2. 배포 직전 단계: 로컬에서 배포 완료까지의 3단계 가이드

이제 이 `exam4me` 프로젝트 코드를 배포 완료하기 위해 **최초 1회만 설정해주면 되는 3가지 절차**입니다.

### 1단계: GitHub 저장소 생성 및 코드 Push
1. 본인의 **GitHub** 계정에 새로운 Private 또는 Public Repository를 생성합니다 (예: `exam4me-service`).
2. 로컬 터미널을 열고 `exam4me` 폴더로 진입하여 아래 명령으로 코드를 Push합니다.
   ```bash
   cd "c:\Users\kth_0\OneDrive\바탕 화면\학교자료\2026-1학기\AWSAI기초\exam4me"
   git init
   git add .
   git commit -m "feat: init GitOps skeleton with 9 AWS services"
   git branch -M main
   git remote add origin https://github.com/[YOUR_GITHUB_ID]/exam4me-service.git
   git push -u origin main
   ```

---

### 2단계: AWS IAM OIDC 공급자 및 역할 생성 (최초 1회, Access Key 불필요)
GitHub Actions가 AWS에 안전하게 임시 접속할 수 있도록 AWS 콘솔에서 연동 설정을 해 줍니다.
1. **AWS 웹 콘솔** 로그인 ➔ **IAM** 서비스로 이동합니다.
2. [자격 증명 공급자 (Identity Providers)] ➔ [공급자 추가]를 선택합니다.
   *   **공급자 유형**: `OpenID Connect`
   *   **공급자 URL**: `https://token.actions.githubusercontent.com` (대상 검색 클릭)
   *   **대상(Audience)**: `sts.amazonaws.com`
3. [역할 (Roles)] ➔ [역할 생성]을 클릭합니다.
   *   **신뢰할 수 있는 엔티티 유형**: `웹 자격 증명 (Web Identity)`
   *   **자격 증명 공급자**: 위에서 생성한 공급자 URL 선택
   *   **대상**: `sts.amazonaws.com` 선택
   *   **조건 설정**: GitHub 계정 및 Repository명을 입력합니다. (예: `repo:[본인ID]/exam4me-service:*`)
4. **권한 정책**: 리소스를 프로비저닝해야 하므로 `AdministratorAccess` 또는 인프라 생성에 적합한 강력한 배포 권한을 바인딩합니다.
5. 생성된 역할의 **ARN** 주소(예: `arn:aws:iam::123456789012:role/GitHubActionsWorkflowRole`)를 복사하여 `.github/workflows/deploy.yml` 파일 내 `role-to-assume` 경로에 적어줍니다.

---

### 3단계: AWS Amplify 콘솔에서 GitHub 웹훅 연동 (최초 1회)
프론트엔드 디자인 코드가 실시간 반영되도록 연결합니다.
1. **AWS 웹 콘솔** ➔ **AWS Amplify** 서비스로 이동합니다.
2. [시작하기] ➔ [새 앱 호스팅] 또는 [GitHub과 연동]을 선택합니다.
3. GitHub 계정을 연동(인증 완료)하고, 위에서 생성한 `exam4me-service` 레포지토리를 지정합니다.
4. 빌드 설정 단계에서 빌드할 폴더 경로를 `/frontend`로 매핑하고 완료를 누릅니다.
5. **결과**: 연동 즉시 최초로 `index.html`(임시 화면)이 호스팅 도메인으로 자동 배포됩니다. 
6. **추후 업데이트**: 이후 디자이너가 실물 디자인 웹 파일들을 `/frontend` 폴더에 추가하여 `git push`를 실행하기만 하면, Amplify가 Git 웹훅을 감지하여 100% 무수동으로 실시간 자동 배포를 지속 수행합니다.
