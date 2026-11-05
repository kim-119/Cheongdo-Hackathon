# AGENTS.md — 가림AI

코딩 에이전트(Copilot 등)가 이 저장소에서 작업할 때 지키는 규칙.

## 프로젝트 한 줄
공무원 개인 업무 비서. 민원 원문·업로드 문서(PDF/Excel)의 개인정보는 **로컬 LLM(LM Studio)+정규식**이 가리고, **가린 텍스트만** 공용 API(Copilot SDK)로 보낸다. 문서는 청크·임베딩해 RAG로 질의응답한다.

## 문서 (먼저 읽을 것)
- `docs/00-POC.md` PoC 검증 기획서
- `docs/01-PRD.md` 무엇을 만드나
- `docs/02-TRD.md` 기술 선택·정의·파이프라인
- `docs/03-TDD.md` 테스트 설계
- `docs/04-FLOW.md` 사용자/데이터 플로우
- `docs/05-AZURE-LMSTUDIO.md` Azure에 LM Studio 올리기
- `docs/06-AZURE-POSTGRES.md` Azure PostgreSQL + pgvector

## 구조
```
apps/web    React + Vite + TS + Tailwind (Capacitor Android는 P2)
apps/core   Rust + Axum + sqlx — 공개 API, DB(Azure PostgreSQL+pgvector), 할 일, 감사 로그, 문서 메타. 스키마는 `apps/core/migrations`
apps/ai     Python 3.11 + FastAPI — PII(정규식+LLM)·egressGuard·파싱·청크·임베딩·RAG·Copilot SDK
eval/       PII·RAG 평가 (Python)
infra/      docker-compose, Caddyfile, Azure 스크립트
```
- 외부 공개는 `core`(Caddy 경유)만. `ai`·LM Studio는 `127.0.0.1` 전용. Azure PostgreSQL은 방화벽으로 VM IP만 허용.
- **클라우드로 나가는 경로는 `apps/ai` 한 곳뿐.** `core`는 클라우드 LLM을 직접 호출하지 않는다.
- PII 처리(가림·복원·매핑 암복호화·egressGuard)는 전부 `apps/ai`. `core`는 매핑을 **암호문 blob**으로만 저장한다.

## 명령
```bash
docker compose -f infra/docker-compose.dev.yml up -d postgres   # 로컬 개발용 pgvector (배포는 Azure PostgreSQL)
# web
pnpm -C apps/web i && pnpm -C apps/web dev        # :5173
pnpm -C apps/web test && pnpm -C apps/web build
# core (Rust)
cargo run --manifest-path apps/core/Cargo.toml    # :8080
cargo test --manifest-path apps/core/Cargo.toml
cargo clippy --manifest-path apps/core/Cargo.toml -- -D warnings
# ai (Python, uv)
cd apps/ai && uv sync && uv run fastapi dev app/main.py --port 8000
cd apps/ai && uv run pytest && uv run ruff check . && uv run mypy app
# eval
cd eval && uv run python -m eval.pii   # PII 재현율·유출
cd eval && uv run python -m eval.rag   # RAG hit@k·JSON 준수율
```

## 절대 규칙 (보안)
1. 클라우드 세션으로 가는 모든 텍스트는 `apps/ai`의 `egress_guard()`를 통과해야 한다. 우회 코드 금지.
2. 원문·평문 매핑표는 로그/외부 전송 금지.
   - 붙여넣기 텍스트의 매핑표: `ai` 메모리에만, TTL 10분 후 폐기.
   - 업로드 문서의 매핑표: `ai`가 AES-256-GCM으로 암호화한 blob만 DB 저장. 키(`MAPPING_KEY`)는 `ai`만 가진다.
   - 업로드 원본 파일은 파싱 후 즉시 폐기. 디스크·DB에 저장 금지.
3. 청크·임베딩은 **가린 텍스트** 기준으로만 만든다. 평문 청크 저장 금지.
4. LM Studio·FastAPI는 `127.0.0.1` 또는 사설 IP에만 바인딩. 공인 IP 노출 금지. Azure PostgreSQL은 VM IP 방화벽 + TLS.
5. API 키·`MAPPING_KEY`는 `.env` / Azure Key Vault. 커밋 금지.
6. 테스트·시연 데이터는 가상 데이터만 사용.

## 코딩 규칙
- TS: strict, `any` 금지. Rust: `clippy -D warnings`, 테스트 외 `unwrap()` 금지. Python: 타입 힌트 필수, `mypy` 통과, Pydantic으로 입출력 검증.
- PII 탐지 로직 변경 시 `apps/ai/tests/pii` 케이스 추가.
- 마스킹 토큰 형식 고정: `[이름_1]`, `[전화_2]`, `[주민번호_1]` … 청크 경계가 토큰을 자르면 안 된다.
- AI 응답은 JSON 스키마(`docs/02-TRD.md` 5절)로만 받는다. 검증 실패 시 1회 재시도.
- `core` ↔ `ai` 내부 호출은 `X-Internal-Token` 헤더로 인증.
- 응답·UI 문구는 한국어.
- 커밋: `feat|fix|docs|test|chore: 요약`
