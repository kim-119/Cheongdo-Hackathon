# AGENTS.md — 가림AI

코딩 에이전트(Copilot 등)가 이 저장소에서 작업할 때 지키는 규칙.

## 프로젝트 한 줄
공무원 개인 업무 비서. 원문 개인정보는 **로컬 LLM(LM Studio)** 이 가리고, **가린 텍스트만** 공용 API(Copilot SDK)로 보낸다.

## 문서 (먼저 읽을 것)
- `docs/00-POC.md` PoC 검증 기획서
- `docs/01-PRD.md` 무엇을 만드나
- `docs/02-TRD.md` 기술 선택·정의·파이프라인
- `docs/03-TDD.md` 테스트 설계
- `docs/04-FLOW.md` 사용자/데이터 플로우
- `docs/05-AZURE-LMSTUDIO.md` Azure에 LM Studio 올리기

## 구조
```
apps/web      React + Vite + TS + Tailwind, Capacitor(Android)
apps/api      Node 20 + Fastify + @github/copilot-sdk
packages/pii  정규식 탐지 + 마스킹/복원 (순수 함수, 테스트 필수)
infra/        docker-compose, Azure 스크립트
```

## 명령
```bash
pnpm i
pnpm dev            # web:5173, api:8080
pnpm test           # vitest 전체
pnpm -F pii test    # PII 모듈만
pnpm eval           # PII 재현율·유출 측정
pnpm build
npx cap sync android
```

## 절대 규칙 (보안)
1. 클라우드 세션으로 가는 모든 텍스트는 `egressGuard()`를 통과해야 한다. 우회 코드 금지.
2. 원문·매핑표(토큰↔원문)는 로그/외부 전송 금지. 메모리에서만 처리 후 폐기.
3. LM Studio는 `127.0.0.1` 또는 사설 IP에만 바인딩. 공인 IP 노출 금지.
4. API 키는 `.env` / Azure Key Vault. 커밋 금지.
5. 테스트·시연 데이터는 가상 데이터만 사용.

## 코딩 규칙
- TypeScript strict. `any` 금지.
- PII 탐지 로직 변경 시 `packages/pii/__tests__` 케이스 추가.
- 마스킹 토큰 형식 고정: `[이름_1]`, `[전화_2]`, `[주민번호_1]` …
- 응답·UI 문구는 한국어.
- 커밋: `feat|fix|docs|test|chore: 요약`
