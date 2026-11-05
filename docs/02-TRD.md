# 02. TRD — 기술 선택 · 정의 · 파이프라인

## 1. 기술 선택
| 영역 | 선택 | 이유 |
|---|---|---|
| 프론트 | React 18 + Vite + TypeScript + Tailwind + shadcn/ui | 빠른 개발 |
| 모바일 | Capacitor (Android) — **P2, 선택** | 웹 코드 재사용 |
| 공개 API | **Rust + Axum + sqlx** (`apps/core`) | DB·업무 로직, 타입 안전, 낮은 메모리 |
| AI 서비스 | **Python 3.11 + FastAPI** (`apps/ai`) | 파싱·임베딩·RAG 생태계 |
| AI 에이전트 | **`github-copilot-sdk` (Python)** | 세션·툴 호출·BYOK |
| 로컬 LLM | **LM Studio (llmster, headless)** + `qwen/qwen3-4b` (GPU 있으면 `qwen3-14b`) | OpenAI 호환, 한국어 |
| 임베딩 | **bge-m3** (GGUF, LM Studio `/v1/embeddings`, 1024차원) | 한국어·다국어 검색 성능, 로컬 |
| DB / 벡터DB | **Azure Database for PostgreSQL Flexible** (B1ms, PG16) **+ pgvector** | AWS RDS에 해당하는 관리형. 자동 백업, 업무 DB와 벡터 검색 통합. 월 ≈ $16 |
| 문서 파싱 | `pdfplumber`(PDF 텍스트·표), `openpyxl`(xlsx) | 순수 Python, 라이선스 무난 |
| PII 규칙 | 정규식 (`apps/ai/app/pii`) + 엑셀 헤더 힌트 | 결정적, 테스트 쉬움 |
| 테스트 | Vitest·Playwright / `cargo test` / pytest | 언어별 표준 |
| 배포 | Azure Static Web Apps(웹) + Azure VM `Standard_B2ms`(core+ai+LM Studio) + Azure PostgreSQL | 예산 5만 원 |
| CI/CD | GitHub Actions + GHCR | |

> Copilot SDK는 JSON-RPC로 Copilot 런타임을 띄운다 → 컨테이너 빌드 시 `python -m copilot download-runtime` 포함. 기술 프리뷰라 버전 고정.

## 2. 구성요소
| 컴포넌트 | 위치 | 책임 |
|---|---|---|
| `web` | SWA | 입력·하이라이트·승인·문서 업로드·질의·결과·할 일 보드·전송 기록 |
| `core` | VM :8080 (Caddy 뒤) | 공개 REST API, Postgres 읽기/쓰기, 벡터 검색, 할 일, 감사 로그, 업로드 크기 제한 |
| `ai` | VM 127.0.0.1:8000 | PII 탐지·가림·복원, 매핑 암복호화, egressGuard, 파싱, 청크, 임베딩, 클라우드 LLM 호출, JSON 검증 |
| **LocalAgent** | `ai` | Copilot SDK 세션, provider = LM Studio. 문맥형 PII 후보 JSON |
| **CloudAgent** | `ai` | Copilot SDK 세션, 기본 모델 + 툴(`add_todo`, `set_deadline`) |
| **egress_guard** | `ai` | 클라우드 전송 직전 정규식 재검사 + 매핑 원문 값 잔존 검사 → pass/block |
| **Embedder** | `ai` | LM Studio `/v1/embeddings` (httpx 직접 호출) |
| **AuditLog** | `core` | 전송 메타데이터만 Postgres 기록 (원문 X) |

**경계 규칙**: `core`는 평문 매핑을 볼 수 없다(암호문 blob만 저장). 클라우드 호출은 `ai`만 한다.

### Copilot SDK 세션 (요지 — 설치 버전의 실제 시그니처로 맞출 것)
```python
from copilot import CopilotClient
from copilot.session import PermissionHandler

client = CopilotClient(); await client.start()

local = await client.create_session(           # PII 탐지 (BYOK → LM Studio)
    model=settings.local_model,
    provider={"type": "openai", "base_url": settings.local_base_url,
              "api_key": "lm-studio", "wire_api": "completions"},
    on_permission_request=PermissionHandler.approve_all,
)
cloud = await client.create_session(           # 업무·RAG 답변
    model=settings.cloud_model,
    tools=[add_todo, set_deadline],
    on_permission_request=PermissionHandler.approve_all,
)
```
> 보안 파이프라인(가림→가드→전송)은 에이전트 판단이 아니라 **코드로 강제**.

## 3. API 계약
### 3.1 `core` 공개 API (`/api`)
| 메서드 | 경로 | 설명 |
|---|---|---|
| POST | `/mask` `{text}` | → `{sessionId, masked, entities[{type,start,end,token}], warnings[]}` |
| POST | `/mask/{sessionId}/manual` `{start,end,type}` | 수동 가림 추가 |
| POST | `/run` `{sessionId, task}` | task = `reply\|summary\|official\|todo`. 만료 410, 차단 422+hits |
| POST | `/documents` (multipart, ≤10MB, pdf/xlsx) | 인덱싱 → `{documentId, chunks, entityCounts, warnings}` |
| GET / DELETE | `/documents`, `/documents/{id}` | 목록 / 삭제(청크·매핑 동시 삭제) |
| POST | `/ask` `{question, documentIds?}` | RAG 답변 (5절 스키마, 복원본) |
| GET / POST / PATCH | `/todos` | 할 일 보드 |
| GET | `/audit` | 전송 기록 (메타데이터만) |

### 3.2 `ai` 내부 API (127.0.0.1, `X-Internal-Token` 필수)
| 경로 | 입력 → 출력 |
|---|---|
| `/pii/mask`, `/pii/manual` | 원문 → 가린 텍스트 (매핑은 `ai` 메모리, TTL 10분) |
| `/run` | `{sessionId, task}` → 복원된 결과 + todos |
| `/ingest` | 파일 바이트 → `{chunks[{ord, loc, textMasked, embedding}], mappingEnc, entityCounts}` |
| `/query/prepare` | `{question}` → `{querySessionId, maskedQuestion, embedding}` |
| `/ask` | `{querySessionId, chunks[{id, documentId, textMasked}], mappings{documentId: mappingEnc}}` → 복원된 AskResponse |

## 4. 배포 구조 (Azure)
```
[Browser] ─HTTPS─▶ [Static Web Apps (web)]
    │ HTTPS
    ▼
[Azure VM Standard_B2ms, Ubuntu 24.04]
 ├─ Caddy :443 ──▶ core :8080 (Docker)
 │                  ├─▶ Azure PostgreSQL Flexible + pgvector (TLS, 방화벽 = VM IP만)
 │                  └─▶ ai 127.0.0.1:8000 (Docker)
 │                         ├─▶ LM Studio 127.0.0.1:1234 (LLM + 임베딩)
 │                         └─▶ Copilot 클라우드 (가린 텍스트만, egress_guard 통과분)
```
- 원문·매핑·임베딩 생성이 모두 **VM 안**에서 끝남 = 보안 스토리의 핵심.
- DB에는 가린 텍스트·암호화 매핑·임베딩만 저장 → 원문은 여전히 VM 밖으로 안 나감.
- 메모리 예산(8GB): qwen3-4b Q4 ≈3GB, bge-m3 ≈1.2GB, ai ≈0.8GB, core ≈0.1GB. 부족하면 `D4s_v5`(16GB).

## 5. AI 응답 JSON 규칙
모든 LLM 응답은 Pydantic 모델로 검증한다. 검증 실패 → 1회 재시도 → 실패 시 오류 응답(원문 노출 없이).

**LocalAgent (PII 후보)**
```json
{"entities": [{"type": "이름|주소|기타", "text": "원문 그대로"}]}
```
오프셋은 LLM에게 받지 않는다. `ai`가 원문에서 직접 찾아 계산한다.

**AskResponse (`/ask`)**
```json
{
  "answer": "string",
  "citations": [{"chunkId": "string", "quote": "string"}],
  "confidence": "high|medium|low",
  "notFound": false,
  "todos": [{"title": "string", "due": "YYYY-MM-DD|null"}]
}
```
**TaskResponse (`/run`)**
```json
{"task": "reply|summary|official|todo", "output": "string", "todos": [{"title": "string", "due": "YYYY-MM-DD|null"}]}
```
**프롬프트 규칙 (CloudAgent 시스템 프롬프트에 고정)**
1. 제공된 컨텍스트 청크로만 답한다. 근거가 없으면 `notFound: true`, `answer`는 "문서에서 근거를 찾지 못했습니다."
2. `citations[].chunkId`는 제공된 ID 중에서만. 아니면 검증 실패로 처리.
3. `[이름_1]` 같은 토큰은 바꾸거나 추측하지 말고 그대로 쓴다.
4. JSON 외 텍스트 출력 금지.

## 6. 문서 RAG 파이프라인
### 6.1 범위
- **IN**: 텍스트 PDF(≤50쪽), xlsx(시트당 ≤5,000행), 파일 ≤10MB
- **OUT**: 스캔 PDF(OCR), HWP/HWPX, xls(구형), 이미지

### 6.2 인덱싱 (`/ingest`)
```
파일(메모리) → [1] 파싱 → [2] 문서 단위 PII 탐지·가림(정규식 + 헤더 힌트 + LocalAgent)
 → [3] 가린 텍스트 청크 분할 → [4] 임베딩(bge-m3) → [5] 매핑 AES-GCM 암호화
 → core: documents·chunks 저장 → 원본 바이트 폐기
```
| 단계 | PDF | Excel |
|---|---|---|
| 파싱 | 페이지별 텍스트 + 표는 행 텍스트로 | 시트별, 첫 행 = 헤더 |
| 헤더 힌트 | — | 헤더가 `성명/이름/연락처/전화/주소/주민번호/계좌` 등이면 해당 열 전체를 그 유형으로 가림 |
| 청크 | 문단 기준 ~800자, 겹침 100자, 페이지 넘지 않음 | 행을 `헤더: 값 \| 헤더: 값` 로 직렬화, ~800자 단위로 행 묶음 |
| `loc` | `{page}` | `{sheet, rowStart, rowEnd}` |

- 가림은 **문서 전체에서 한 번** 한다 → 같은 사람은 문서 안 모든 청크에서 같은 토큰.
- 청크 분할기는 `[...]` 토큰을 절대 자르지 않는다.

### 6.3 질의 (`/ask`)
```
질문 → ai /query/prepare: 질문 가림 + 임베딩
 → core: pgvector 코사인 top-k=5 (documentIds 필터, 유사도 < 0.35 제외)
 → 결과 0건이면 클라우드 호출 없이 notFound 응답
 → ai /ask: 문서별 매핑 복호화 → **요청 단위 토큰 재번호**(문서 A·B의 `[이름_1]` 충돌 방지, 같은 값은 같은 토큰)
 → egress_guard → CloudAgent(JSON) → 검증 → 복원 → core: AuditLog·todos 저장
```

## 7. 데이터 모델 (Postgres, `core` 마이그레이션 `apps/core/migrations/0001_init.sql`)
```sql
CREATE EXTENSION IF NOT EXISTS vector;
documents(id uuid pk, name text, kind text, page_or_rows int, entity_counts jsonb,
          mapping_enc bytea, created_at timestamptz)
chunks(id uuid pk, document_id uuid fk on delete cascade, ord int, loc jsonb,
       text_masked text, embedding vector(1024))
  -- CREATE INDEX ON chunks USING hnsw (embedding vector_cosine_ops);
todos(id uuid pk, title_masked text, due date, status text, source text, created_at timestamptz)
audit_log(id bigserial pk, at timestamptz, kind text,  -- run|ask|ingest
          task text, model text, masked_counts jsonb, decision text, latency_ms int)
```
- 할 일은 가린 상태로 저장. 복원본은 응답으로만 전달하고 클라이언트 IndexedDB에 캐시.

## 8. 파이프라인
### 8.1 붙여넣기 요청 1건
```
원문 → [1] 정규식 → [2] LocalAgent(문맥형) → [3] 병합·치환(매핑 메모리)
     → [4] 사용자 승인 → [5] egress_guard → [6] CloudAgent → [7] AuditLog
     → [8] 복원 → [9] 매핑 폐기 → 화면/할 일 보드
```
### 8.2 CI/CD (GitHub Actions)
| 트리거 | 잡 | 내용 |
|---|---|---|
| PR | `web` | lint → typecheck → vitest |
| PR | `core` | fmt → clippy → `cargo test` (Postgres+pgvector 서비스 컨테이너) |
| PR | `ai` | ruff → mypy → pytest |
| PR | `eval` | PII(재현율 ≥95%, 유출 0) · RAG(hit@5 ≥0.8, JSON 준수 100%). LLM·임베딩 응답은 녹화 fixture 재생 |
| main push | `deploy-web` | `vite build` → Azure Static Web Apps |
| main push | `deploy-api` | core·ai Docker build → GHCR → VM SSH `docker compose pull && up -d` |
| tag `v*` | `android` (P2) | `cap sync` → `assembleDebug` → APK |

### 8.3 환경변수
```
# ai
LOCAL_BASE_URL=http://127.0.0.1:1234/v1
LOCAL_MODEL=qwen/qwen3-4b
EMBED_MODEL=bge-m3            # LM Studio에 로드된 실제 ID로
EMBED_DIM=1024
CLOUD_MODEL=gpt-4.1
COPILOT_GITHUB_TOKEN=***
MAPPING_KEY=***               # base64 32바이트, ai만 보유
INTERNAL_TOKEN=***
# core
DATABASE_URL=postgres://garimadmin:<PASSWORD>@<SERVER>.postgres.database.azure.com:5432/garim?sslmode=require
AI_BASE_URL=http://127.0.0.1:8000
INTERNAL_TOKEN=***
CORS_ORIGIN=https://<swa>.azurestaticapps.net
```
