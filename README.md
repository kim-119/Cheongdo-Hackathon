# 가림AI — 개인정보는 가리고, 일은 AI가

청도군 공무원용 개인 업무 비서 (2026 청도 바이브코딩 해커톤)

| | |
|---|---|
| **문제** | 민원 원문·업무 문서의 개인정보 때문에 공무원이 생성형 AI를 못 쓰거나, 유출 위험을 안고 씀 |
| **해법** | LM Studio(로컬 LLM)+정규식이 개인정보를 가림 → 가린 텍스트만 공용 AI(Copilot SDK)로 → 결과 복원. PDF·Excel은 가린 채로 임베딩해 RAG 질의 |
| **기능** | 민원 답변 초안 · 요약 · 공문 초안 · 할 일 추출 · 문서 질의응답(인용 포함) · 전송 기록 |
| **스택** | React+Vite / Rust Axum(core) / Python FastAPI(ai)+Copilot SDK / Azure PostgreSQL+pgvector / LM Studio(qwen3-4b, bge-m3) / Azure |
| **지표** | PII 재현율 ≥95% · 외부 유출 0건 · RAG hit@5 ≥0.8 · 1건 ≤10초 |
| **배포** | _(TBD)_ |

<!-- EVAL:START -->
<!-- EVAL:END -->

## 문서
- [AGENTS.md](AGENTS.md) · [PoC](docs/00-POC.md) · [PRD](docs/01-PRD.md) · [TRD](docs/02-TRD.md) · [TDD](docs/03-TDD.md) · [Flow](docs/04-FLOW.md) · [Azure+LM Studio](docs/05-AZURE-LMSTUDIO.md) · [Azure PostgreSQL+pgvector](docs/06-AZURE-POSTGRES.md)
