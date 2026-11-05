# 04. 플로우

## 1. 사용자 플로우
```mermaid
flowchart LR
  A[원문 붙여넣기] --> B[가림 결과 하이라이트]
  B --> C{작업 선택}
  C -->|답변 초안·요약·공문·할 일| D[전송본 미리보기]
  D -->|승인| E[AI 처리]
  D -->|수동 가림 추가| B
  E --> F[복원된 결과 + 에이전트 활동]
  F --> G[복사 / 할 일 보드 저장]
  U[PDF·Excel 업로드] --> V[가림·청크·임베딩 결과 요약]
  V --> Q[문서에 질문]
  Q --> E
```

## 2. 데이터 플로우 — 붙여넣기
```mermaid
sequenceDiagram
  participant U as Web
  participant C as core (Axum)
  participant A as ai (FastAPI)
  participant L as LM Studio
  participant X as Copilot 클라우드
  U->>C: POST /api/mask {원문}
  C->>A: /pii/mask
  A->>A: 정규식 탐지
  A->>L: 문맥형 PII 탐지
  A-->>C: {sessionId, masked, entities}
  C-->>U: 하이라이트
  U->>C: POST /api/run {sessionId, task} (승인)
  C->>A: /run
  A->>A: egress_guard
  alt 미가림 PII
    A-->>U: 422 차단 + 위치
  else 통과
    A->>X: 가린 텍스트 + 작업 프롬프트
    X-->>A: JSON (+ add_todo)
    A->>A: 검증 → 복원 → 매핑 폐기
    A-->>C: 결과 + todos
    C->>C: AuditLog · todos 저장
    C-->>U: 복원된 결과
  end
```

## 3. 데이터 플로우 — 문서 업로드·질의
```mermaid
sequenceDiagram
  participant U as Web
  participant C as core (Axum)
  participant A as ai (FastAPI)
  participant L as LM Studio
  participant P as Postgres+pgvector
  participant X as Copilot 클라우드
  U->>C: POST /api/documents (PDF/xlsx)
  C->>A: /ingest (메모리 바이트)
  A->>A: 파싱 → 정규식·헤더 힌트
  A->>L: 문맥형 PII
  A->>A: 가림 → 청크(토큰 보존)
  A->>L: /v1/embeddings
  A-->>C: chunks(가림)+embedding+mappingEnc
  C->>P: 저장 (원본 폐기)
  U->>C: POST /api/ask {question}
  C->>A: /query/prepare
  A-->>C: maskedQuestion + embedding
  C->>P: 코사인 top-5
  alt 근거 없음
    C-->>U: notFound (클라우드 호출 X)
  else 근거 있음
    C->>A: /ask {chunks, mappingEnc}
    A->>A: 매핑 복호화 → 토큰 재번호 → egress_guard
    A->>X: 가린 질문 + 가린 청크
    X-->>A: AskResponse JSON
    A->>A: 검증(인용 ID) → 복원
    A-->>C: 결과
    C->>C: AuditLog · todos
    C-->>U: 답변 + 인용(쪽/시트·행)
  end
```

## 4. 에러 플로우
| 상황 | 동작 |
|---|---|
| LM Studio 응답 없음 | 붙여넣기: 정규식만, 노란 배너 "문맥 탐지 꺼짐" / 업로드: "임베딩 서버 꺼짐" 안내 |
| egress_guard 차단 | 전송 안 함, 위치 빨간 표시, 수동 가림 버튼 |
| JSON 검증 실패 | 1회 재시도 → "답변 형식 오류, 다시 시도" |
| 클라우드 실패 | 1회 재시도 → 실패 안내, 매핑 유지(TTL 내 재시도) |
| 매핑표 만료 | "다시 가림 필요" 안내 |
| 지원 안 하는 파일 | 스캔 PDF·HWP·xls → 사유와 함께 거부 |

## 5. 화면
1. **작업대**: 좌 원문/가림 뷰 · 우 결과 · 상단 작업 버튼 4개 · 에이전트 활동 로그
2. **문서함**: 업로드 · 문서 목록(가린 항목 수, 청크 수) · 질문창 · 답변 + 인용 카드
3. **할 일 보드**: 오늘 / 이번 주 / 완료
4. **전송 기록**: 시각 · 종류(작업/질의/인덱싱) · 가린 항목 수 · 통과/차단
