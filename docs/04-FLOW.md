# 04. 플로우

## 1. 사용자 플로우
```mermaid
flowchart LR
  A[원문 붙여넣기] --> B[가림 결과 하이라이트]
  B --> C{작업 선택}
  C -->|답변 초안| D[전송본 미리보기]
  C -->|요약| D
  C -->|공문 초안| D
  C -->|할 일 추출| D
  D -->|승인| E[AI 처리]
  D -->|수동 가림 추가| B
  E --> F[복원된 결과]
  F --> G[복사 / 할 일 보드 저장]
```

## 2. 데이터 플로우
```mermaid
sequenceDiagram
  participant U as 사용자(Web/App)
  participant API as API (Azure VM)
  participant L as LocalAgent→LM Studio(127.0.0.1)
  participant G as egressGuard
  participant C as CloudAgent→Copilot

  U->>API: POST /mask {원문}
  API->>API: 정규식 탐지
  API->>L: 문맥형 PII 탐지
  L-->>API: entities JSON
  API-->>U: {sessionId, masked, entities}
  U->>API: POST /run {sessionId, task} (승인)
  API->>G: masked 재검사
  alt 미가림 PII 발견
    G-->>U: 차단 + 위치 표시
  else 통과
    API->>C: 가린 텍스트 + 작업 프롬프트
    C-->>API: 가린 결과 (+ add_todo 호출)
    API->>API: AuditLog(원문 X) → 복원 → 매핑표 폐기
    API-->>U: 복원된 결과
  end
```

## 3. 에러 플로우
| 상황 | 동작 |
|---|---|
| LM Studio 응답 없음 | 정규식만 적용, 노란 배너 "문맥 탐지 꺼짐" |
| egressGuard 차단 | 전송 안 함, 위치 빨간 표시, 수동 가림 버튼 |
| 클라우드 실패 | 1회 재시도 → 실패 안내, 매핑표 유지(TTL 내 재시도) |
| 매핑표 만료 | "다시 가림 필요" 안내 |

## 4. 화면
1. **작업대**: 좌 원문/가림 뷰 · 우 결과 · 상단 작업 버튼 4개
2. **할 일 보드**: 오늘 / 이번 주 / 완료
3. **전송 기록**: 시각 · 작업 · 가린 항목 수 · 통과/차단
