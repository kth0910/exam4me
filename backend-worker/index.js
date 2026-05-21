const { S3Client, GetObjectCommand, PutObjectCommand } = require('@aws-sdk/client-s3');
const { DynamoDBClient, PutItemCommand } = require('@aws-sdk/client-dynamodb');

const REGION = process.env.AWS_REGION || 'ap-northeast-2';
const s3Client = new S3Client({ region: REGION });
const dynamoClient = new DynamoDBClient({ region: REGION });

exports.handler = async (event) => {
    // SQS로부터 전달받은 레코드 순회 처리
    for (const record of event.Records) {
        const { jobId, fileKey, option, userEmail } = JSON.parse(record.body);
        const tableName = process.env.DYNAMODB_TABLE_NAME || 'platform-status-cache';

        try {
            console.log(`[Job ${jobId}] 비동기 파일 변환 처리 시작... Target File: ${fileKey}`);

            // 1. DynamoDB에 PROCESSING 상태 및 진행률 30% 기록 (스피너용)
            await updateJobStatus(tableName, jobId, 'PROCESSING', '30');

            // 2. S3에서 사용자가 업로드한 원본 문서 로드
            // const s3Object = await s3Client.send(new GetObjectCommand({ Bucket: 'exam4me-raw-files', Key: fileKey }));
            // const rawText = await parseFileContent(s3Object);
            
            console.log(`[Job ${jobId}] 원문 파싱 성공. 외부 AI API 호출 대기 중...`);
            await updateJobStatus(tableName, jobId, 'PROCESSING', '60');

            // 3. 외부 AI API 호출 수행 (질문에서 언급된 것처럼 AI는 API를 활용)
            // const aiResponse = await callExternalAI_API(rawText, option);
            // const processedDocumentBuffer = await generateFormattedDocument(aiResponse, option);
            
            // AI 호출 및 변환 지연 시간 모사 (3초)
            await new Promise(resolve => setTimeout(resolve, 3000));

            // 4. 변환 결과물(Word/PDF) S3 결과 버킷에 업로드
            const outputBucket = process.env.S3_OUTPUT_BUCKET_NAME || 'exam4me-converted-files';
            const outputKey = `converted/${jobId}-final.docx`;
            
            await s3Client.send(new PutObjectCommand({
                Bucket: outputBucket,
                Key: outputKey,
                Body: Buffer.from('가공 완료된 학원 레이아웃 문서 데이터 (AI API 결과 접목)'),
                ContentType: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
            }));

            // 5. DynamoDB에 완료 상태(100%) 및 최종 결과물 다운로드 URL 기록
            const finalDownloadUrl = `https://${outputBucket}.s3.${REGION}.amazonaws.com/${outputKey}`;
            await updateJobStatus(tableName, jobId, 'SUCCESS', '100', finalDownloadUrl);
            
            console.log(`[Job ${jobId}] 변환 및 S3 가공 파일 업로드 완벽 성공! URL: ${finalDownloadUrl}`);

        } catch (error) {
            console.error(`[Job ${jobId}] 파일 가공 처리 중 실패:`, error);
            await updateJobStatus(tableName, jobId, 'FAILED', '0');
        }
    }
    
    return { statusCode: 200, body: 'Batch SQS Messages processed.' };
};

// DynamoDB 진행 상태 갱신 공통 함수
async function updateJobStatus(tableName, jobId, status, progress, outputUrl = '') {
    const item = {
        pk: { S: jobId },
        status: { S: status },
        progress: { N: progress },
        updatedAt: { S: new Date().toISOString() }
    };

    if (outputUrl) {
        item.outputUrl = { S: outputUrl };
    }

    await dynamoClient.send(new PutItemCommand({
        TableName: tableName,
        Item: item
    }));
}
