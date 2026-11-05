# 02. TRD — 기술 선택 · 정의 · 파이프라인

## 1. 기술 선택
| 영역 | 선택 | 이유 |
|---|---|---|
| 프론트 | React 18 + Vite + TypeScript | 빠른 개발, Capacitor 호환 |
| UI | Tailwind + shadcn/ui | 디자인 시간 절약 |
| 모바일 | **Capacitor** (Android) | 웹 코드 재사용 |
| 백엔드 | Node 20 + Fastify | Copilot SDK가 Node 런타임 필요 |
| AI 에이전트 | **@github/copilot-sdk** | 세션·툴 호출·BYOK 지원 |
| 로컬 LLM | **LM Studio (llmster, headless)** | OpenAI 호환 API, 모델 교체 쉬움 |
| 로컬 모델 | Qwen3-4B / Gemma-3-4B-it / EXAONE-3.5-2.4B (GGUF Q4) 중 eval로 선택 | 한국어, CPU에서도 동작 |
| 공용 API | Copilot 기본 모델 (대체: Azure OpenAI BYOK) | 품질 |
| PII 규칙 | 정규식 (`packages/pii`) | 결정적, 빠름, 테스트 쉬움 |
| 저장 | SQLite(better-sqlite3) 서버 / IndexedDB 클라이언트 | 설치 無 |
| 테스트 | Vitest + Playwright | TS 통일 |
| 배포 | Azure Static Web Apps(웹) + Azure VM(API+LM Studio) | 아래 3절 |
| CI/CD | GitHub Actions | |

> Copilot SDK는 Node 서버 전용 → 앱(Capacitor)은 반드시 API 서버를 경유.

## 2. 구성요소 정의
| 컴포넌트 | 책임 | 입력 → 출력 |
|---|---|---|
| `web` | 입력·하이라이트·승인·결과·할 일 보드 | 사용자 텍스트 → 화면 |
| `api /mask` | 정규식 + 로컬 LLM으로 PII 탐지·치환 | 원문 → `{sessionId, masked, entities}` (매핑표는 서버 메모리, TTL 10분) |
| `api /run` | 승인된 가린 텍스트로 클라우드 세션 실행 | `{sessionId, task}` → 복원된 결과 |
| **LocalAgent** | Copilot SDK 세션, `provider` = LM Studio | PII 후보 JSON |
| **CloudAgent** | Copilot SDK 세션, 기본 모델 + 툴 `add_todo` | 업무 결과 |
| **egressGuard** | 클라우드 전송 직전 정규식 재검사, 미가림 PII 있으면 **차단** | 텍스트 → pass/block |
| **AuditLog** | 전송 메타데이터 기록 (원문 X) | 이벤트 → SQLite |

### Copilot SDK 세션 설정 (요지)
```ts
import { CopilotClient, approveAll, defineTool } from "@github/copilot-sdk";

const client = new CopilotClient(); await client.start();

// 로컬: PII 탐지 (BYOK → LM Studio)
const local = await client.createSession({
  model: process.env.LOCAL_MODEL,
  provider: { type: "openai", baseUrl: process.env.LOCAL_BASE_URL,
              apiKey: "lm-studio", wireApi: "completions" },
  onPermissionRequest: approveAll,
});

// 클라우드: 업무 실행 (Copilot 기본 모델, COPILOT_GITHUB_TOKEN 필요)
const cloud = await client.createSession({
  model: process.env.CLOUD_MODEL,
  tools: [addTodoTool],
  onPermissionRequest: approveAll,
});
```
> LM Studio는 `/v1/chat/completions` 기준 → `wireApi: "completions"`. SDK는 기술 프리뷰라 API가 바뀔 수 있으니 버전 고정.
> 보안 파이프라인(마스킹→가드→전송)은 **에이전트 판단에 맡기지 않고 코드로 강제**. 에이전트는 업무 처리·툴 호출만 담당.

## 3. 배포 구조 (Azure)
```
[Browser / Capacitor App]
        │ HTTPS
[Azure Static Web Apps] ──▶ [Azure VM (Ubuntu)]
                             ├─ Caddy :443 (TLS)
                             ├─ api (Docker) :8080
                             └─ LM Studio 127.0.0.1:1234  ← 외부 노출 X
                                    │
                             api ──▶ Copilot 클라우드 (가린 텍스트만)
```
- LM Studio와 API를 **같은 VM**에 둬서 원문이 VM 밖으로 안 나감 = 보안 스토리의 핵심.

## 4. 파이프라인
### 4.1 데이터 파이프라인 (요청 1건)
```
원문 → [1] 정규식 탐지 → [2] LocalAgent 탐지(이름·주소 등 문맥형)
     → [3] 병합·치환(매핑표 메모리) → [4] 사용자 승인
     → [5] egressGuard → [6] CloudAgent 실행 → [7] AuditLog
     → [8] 복원 → [9] 매핑표 폐기 → 화면/할 일 보드
```
### 4.2 CI/CD (GitHub Actions)
| 트리거 | 잡 | 내용 |
|---|---|---|
| PR | `ci` | lint → typecheck → vitest → `pnpm eval`(재현율 <95% 또는 유출 >0 이면 실패) |
| main push | `deploy-web` | `vite build` → Azure Static Web Apps |
| main push | `deploy-api` | Docker build → GHCR push → VM SSH `docker compose pull && up -d` |
| tag `v*` | `android` | `cap sync` → Gradle `assembleDebug` → APK 아티팩트 |

### 4.3 환경변수
```
LOCAL_BASE_URL=http://127.0.0.1:1234/v1
LOCAL_MODEL=qwen/qwen3-4b
CLOUD_MODEL=gpt-4.1
COPILOT_GITHUB_TOKEN=***        # GitHub Secrets / Key Vault
```
