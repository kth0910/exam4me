const { LambdaClient, UpdateFunctionCodeCommand } = require('@aws-sdk/client-lambda');
const { S3Client, PutObjectCommand } = require('@aws-sdk/client-s3');

const REGION = process.env.AWS_REGION || 'ap-northeast-2';
const lambdaClient = new LambdaClient({ region: REGION });
const s3Client = new S3Client({ region: REGION });

exports.handler = async (event) => {
    console.log('GitHub Webhook 수신 성공!', JSON.stringify(event));

    // GitHub Webhook Payload 파싱
    const body = typeof event.body === 'string' ? JSON.parse(event.body) : event.body;
    
    // main 브랜치 push 이벤트 확인
    if (body.ref !== 'refs/heads/main') {
        return { statusCode: 200, body: 'Not a push to main branch. Skiped.' };
    }

    const githubRepo = body.repository.full_name; // 예: "user/exam4me-service"
    const zipUrl = `https://api.github.com/repos/${githubRepo}/zipball/main`;
    
    // GitHub API 호출용 토큰 (Private Repository 연동 시 환경변수 등록하여 사용, Public은 불필요)
    const githubToken = process.env.GITHUB_TOKEN; 
    const headers = { 'User-Agent': 'AWS-Lambda-GitOps-Deployer' };
    if (githubToken) {
        headers['Authorization'] = `token ${githubToken}`;
    }

    try {
        console.log(`GitHub에서 최신 소스 다운로드 중... URL: ${zipUrl}`);
        
        // Node.js 18+ 내장 fetch API 사용
        const response = await fetch(zipUrl, { headers });
        if (!response.ok) {
            throw new Error(`GitHub 다운로드 실패: Status ${response.status}`);
        }
        
        const arrayBuffer = await response.arrayBuffer();
        const buffer = Buffer.from(arrayBuffer);

        // 1. S3 빌드 버킷에 최신 전체 소스 zip 업로드 (EC2 동기화용)
        const buildBucketName = process.env.BUILD_BUCKET_NAME || 'exam4me-frontend-builds';
        const s3Key = 'latest-source.zip';
        
        console.log(`S3 빌드 버킷에 전체 소스 적재 중... Bucket: ${buildBucketName}`);
        await s3Client.send(new PutObjectCommand({
            Bucket: buildBucketName,
            Key: s3Key,
            Body: buffer
        }));

        // 2. 비동기 변환 워커 Lambda 함수 코드 갱신
        // (실무 상 Lambda 코드가 S3에 통째로 압축되어 올라가 있으므로 직접 update 실행)
        const workerFunctionName = process.env.WORKER_FUNCTION_NAME || 'doc-converter-worker';
        console.log(`타겟 Lambda 함수(${workerFunctionName}) 코드 자동 갱신 트리거...`);
        
        await lambdaClient.send(new UpdateFunctionCodeCommand({
            FunctionName: workerFunctionName,
            S3Bucket: buildBucketName,
            S3Key: s3Key // S3에 업로드된 최신 깃허브 전체 zip에서 Lambda가 작동하도록 설정
        }));

        console.log('🎉 100% 무키 백엔드 배포 파이프라인 가동 완벽 성공!');
        return {
            statusCode: 200,
            body: JSON.stringify({ success: true, message: 'GitOps 백엔드 배포 성공!' })
        };

    } catch (error) {
        console.error('GitOps 배포 파이프라인 처리 중 에러:', error);
        return {
            statusCode: 500,
            body: JSON.stringify({ success: false, error: error.message })
        };
    }
};
