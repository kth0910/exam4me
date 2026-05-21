const express = require('express');
const cors = require('cors');
const jwt = require('jsonwebtoken');
const { S3Client, PutObjectCommand } = require('@aws-sdk/client-s3');
const { getSignedUrl } = require('@aws-sdk/s3-request-presigner');
const { SQSClient, SendMessageCommand } = require('@aws-sdk/client-sqs');
const { DynamoDBClient, GetItemCommand } = require('@aws-sdk/client-dynamodb');
const { SNSClient, PublishCommand } = require('@aws-sdk/client-sns');

const app = express();
app.use(cors());
app.use(express.json());

// 환경 변수 설정
const PORT = process.env.PORT || 5000;
const JWT_SECRET = process.env.JWT_SECRET || 'exam4me-super-secret-key-1357';
const REGION = process.env.AWS_REGION || 'ap-northeast-2';

// AWS SDK 클라이언트 초기화 (EC2 IAM Role 권한 연동으로 Key가 불필요)
const s3Client = new S3Client({ region: REGION });
const sqsClient = new SQSClient({ region: REGION });
const dynamoClient = new DynamoDBClient({ region: REGION });
const snsClient = new SNSClient({ region: REGION });

// 1. 사용자 인증 API (Cognito 배제 자체 JWT 발급)
app.post('/api/auth/login', (req, res) => {
    const { email, password } = req.body;
    
    // 임시 회원가입/로그인 검증 예시 (실제 서비스 시 RDS 데이터베이스 쿼리로 비밀번호 해시 대조 수행)
    if (email && password) {
        // 회원 정보를 페이로드에 담아 JWT 발급 (지역, 소속 학원명 등 마케팅 속성 반영)
        const token = jwt.sign({
            email: email,
            role: 'member',
            academy: 'ExamAcademy'
        }, JWT_SECRET, { expiresIn: '12h' });

        return res.json({ success: true, token });
    }
    
    return res.status(400).json({ success: false, message: '이메일과 비밀번호를 제공하십시오.' });
});

// JWT 인증 미들웨어
const authenticateJWT = (req, res, next) => {
    const authHeader = req.headers.authorization;
    if (authHeader) {
        const token = authHeader.split(' ')[1];
        jwt.verify(token, JWT_SECRET, (err, user) => {
            if (err) return res.sendStatus(403);
            req.user = user;
            next();
        });
    } else {
        res.sendStatus(401);
    }
};

// 2. S3 Presigned URL 발급 API (변환 대상 파일 안전 직접 업로드 지원)
app.post('/api/converter/presigned-url', authenticateJWT, async (req, res) => {
    const { filename, fileType } = req.body;
    const bucketName = process.env.S3_RAW_BUCKET_NAME || 'exam4me-raw-files';
    const key = `uploads/${Date.now()}-${filename}`;

    try {
        const command = new PutObjectCommand({
            Bucket: bucketName,
            Key: key,
            ContentType: fileType
        });

        // 5분간 유효한 S3 직접 업로드용 Signed URL 생성
        const uploadUrl = await getSignedUrl(s3Client, command, { expiresIn: 300 });
        
        res.json({ success: true, uploadUrl, fileKey: key });
    } catch (error) {
        console.error('Presigned URL 생성 실패:', error);
        res.status(500).json({ success: false, message: 'URL 발급에 실패했습니다.' });
    }
});

// 3. 비동기 변환 큐 등록 API (SQS 연동)
app.post('/api/converter/convert', authenticateJWT, async (req, res) => {
    const { fileKey, option } = req.body; // option: 'translation' (해석본) / 'vocabulary' (단어장)
    const queueUrl = process.env.SQS_QUEUE_URL || 'https://sqs.ap-northeast-2.amazonaws.com/123456789012/doc-conversion-queue';
    const jobId = `job-${Date.now()}`;

    try {
        const messageBody = JSON.stringify({ jobId, fileKey, option, userEmail: req.user.email });

        // SQS 큐로 작업 등록 메시지 전송
        await sqsClient.send(new SendMessageCommand({
            QueueUrl: queueUrl,
            MessageBody: messageBody
        }));

        res.json({ success: true, jobId, message: '변환 파이프라인에 등록되었습니다.' });
    } catch (error) {
        console.error('SQS 전송 오류:', error);
        res.status(500).json({ success: false, message: '작업 요청 처리에 실패했습니다.' });
    }
});

// 4. 변환 상태 조회 API (DynamoDB 캐시/상태 데이터 고속 조회)
app.get('/api/converter/status/:jobId', authenticateJWT, async (req, res) => {
    const { jobId } = req.params;
    const tableName = process.env.DYNAMODB_TABLE_NAME || 'platform-status-cache';

    try {
        // DynamoDB에서 해당 Job의 진행 상태 및 가공 파일 경로 검색
        const result = await dynamoClient.send(new GetItemCommand({
            TableName: tableName,
            Key: { pk: { S: jobId } }
        }));

        if (!result.Item) {
            return res.json({ success: true, status: 'PENDING', progress: 0 });
        }

        res.json({
            success: true,
            status: result.Item.status.S,         // PENDING, PROCESSING, SUCCESS, FAILED
            progress: parseInt(result.Item.progress.N || '0'), // 0 ~ 100%
            outputUrl: result.Item.outputUrl ? result.Item.outputUrl.S : null // S3 결과물 파일 다운로드 링크
        });
    } catch (error) {
        console.error('DynamoDB 상태 검색 오류:', error);
        res.status(500).json({ success: false, message: '상태 조회 중 오류가 발생했습니다.' });
    }
});

// 5. 오류 제보 게시판 피드백 알림 API (SNS 연동)
app.post('/api/community/feedback/resolve', authenticateJWT, async (req, res) => {
    const { feedbackId, userEmail, title } = req.body;
    const topicArn = process.env.SNS_TOPIC_ARN || 'arn:aws:sns:ap-northeast-2:123456789012:feedback-resolved-topic';

    try {
        // 이메일 수신 유저에게 배송될 알림 메시지 정의
        const message = `안녕하세요, Exam4Me 운영자입니다.\n\n제보해주신 오류 오류글 [${title}] (제보번호: ${feedbackId})에 대해 조치 및 파일 수정이 완료되었습니다.\n마이페이지에서 최신 버전의 자료를 다운로드해주시기 바랍니다.\n\n감사합니다.`;

        // SNS 게시글 발송
        await snsClient.send(new PublishCommand({
            TopicArn: topicArn,
            Message: message,
            Subject: '[Exam4Me] 제보해주신 교재 자료 수정 완료 안내'
        }));

        res.json({ success: true, message: '처리 알림이 발송되었습니다.' });
    } catch (error) {
        console.error('SNS 알림 발송 실패:', error);
        res.status(500).json({ success: false, message: '알림 전송 중 실패했습니다.' });
    }
});

app.listen(PORT, () => {
    console.log(`Exam4Me API Server running on port ${PORT}`);
});
