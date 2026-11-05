# 05. Azure에서 LM Studio · 서비스 운영하기

LM Studio는 서버용 **헤드리스 데몬(llmster) + `lms` CLI** 를 제공한다. Azure VM 한 대에 LM Studio(LLM+임베딩), Postgres+pgvector, core(Axum), ai(FastAPI), Caddy를 올린다.

## 1. VM 고르기 (예산 5만 원 기준)
| 상황 | VM 크기 | 메모리 | 모델 | 대략 비용 |
|---|---|---|---|---|
| **기본 (추천)** | `Standard_B2ms` | 8GB | qwen3-4b Q4 + bge-m3 | 시간당 ≈ $0.09 |
| 메모리 부족 시 | `Standard_D4s_v5` | 16GB | qwen3-4b/8b Q4 + bge-m3 | 시간당 ≈ $0.24 |
| GPU 쿼터·예산 있음 | `Standard_NC4as_T4_v3` | T4 16GB | qwen3-14b Q4 + bge-m3 | 시간당 ≈ $0.5+ |
- OS: Ubuntu 24.04 LTS, 디스크 64GB, 지역 **Korea Central**
- 포털의 "월 예상 비용"은 24시간×30일 기준. **개발은 PC의 LM Studio로, VM은 배포·심사 때만 켠다.**
- 관리 탭 → **자동 종료** 켜기. 구독 → 예산 50,000원 + 50/80/100% 경고.

## 2. VM 생성 (Azure CLI)
```bash
az group create -n rg-garim -l koreacentral
az vm create -g rg-garim -n vm-garim \
  --image Ubuntu2404 --size Standard_B2ms \
  --admin-username azureuser --generate-ssh-keys \
  --os-disk-size-gb 64 --public-ip-sku Standard \
  --public-ip-address-dns-name garim-api
az vm open-port -g rg-garim -n vm-garim --port 80,443 --priority 1001
# 22는 내 IP만, 1234·5432·8000·8080은 열지 않는다
```
→ API 주소: `garim-api.koreacentral.cloudapp.azure.com`

## 3. LM Studio 설치·실행 (VM 안에서)
```bash
ssh azureuser@garim-api.koreacentral.cloudapp.azure.com
curl -fsSL https://lmstudio.ai/install.sh | bash
source ~/.bashrc

lms daemon up
lms get qwen/qwen3-4b            # LLM
lms get bge-m3                   # 임베딩 (검색어/HF 경로 가능, GGUF)
lms ls                           # 받은 모델·ID 확인 → .env의 LOCAL_MODEL/EMBED_MODEL
lms load qwen/qwen3-4b --context-length 8192
lms load <bge-m3 모델 ID>
lms server start --port 1234     # 기본 127.0.0.1 → 외부 노출 X

curl http://127.0.0.1:1234/v1/models
curl http://127.0.0.1:1234/v1/embeddings -H 'Content-Type: application/json' \
  -d '{"model":"<bge-m3 모델 ID>","input":"테스트"}'   # 1024차원 확인
```

## 4. 재부팅 시 자동 시작 (systemd)
`/etc/systemd/system/lmstudio.service`
```ini
[Unit]
Description=LM Studio headless
After=network-online.target

[Service]
User=azureuser
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -lc 'lms daemon up && lms load qwen/qwen3-4b --context-length 8192 && lms load <bge-m3 모델 ID> && lms server start --port 1234'
ExecStop=/bin/bash -lc 'lms server stop; lms daemon down'

[Install]
WantedBy=multi-user.target
```
```bash
sudo systemctl daemon-reload && sudo systemctl enable --now lmstudio
```

## 5. 서비스 컨테이너
```bash
curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker $USER
```
모든 컨테이너는 `network_mode: host` 로 두고, 각 서비스가 `127.0.0.1`에만 바인딩한다(Caddy만 80/443).
```yaml
# infra/docker-compose.yml
services:
  postgres:
    image: pgvector/pgvector:pg16
    command: ["postgres", "-c", "listen_addresses=127.0.0.1"]
    network_mode: host
    environment: { POSTGRES_USER: garim, POSTGRES_PASSWORD: "${PG_PASSWORD}", POSTGRES_DB: garim }
    volumes: [ "pgdata:/var/lib/postgresql/data" ]
    restart: always
  ai:
    image: ghcr.io/kim-119/garim-ai:latest     # uvicorn --host 127.0.0.1 --port 8000
    network_mode: host
    env_file: .env.ai
    restart: always
  core:
    image: ghcr.io/kim-119/garim-core:latest   # 127.0.0.1:8080
    network_mode: host
    env_file: .env.core
    depends_on: [ postgres, ai ]
    restart: always
  caddy:
    image: caddy:2
    network_mode: host
    volumes: [ "./Caddyfile:/etc/caddy/Caddyfile", "caddy_data:/data" ]
    restart: always
volumes: { pgdata: {}, caddy_data: {} }
```
`Caddyfile`
```
garim-api.koreacentral.cloudapp.azure.com {
  reverse_proxy 127.0.0.1:8080
}
```

## 6. 웹 (Azure Static Web Apps, Free)
- 리소스 그룹 `rg-garim`, 이름 `swa-garim`, 지역 East Asia, 원본 GitHub `kim-119/Cheongdo-Hackathon` `main`
- 빌드: 앱 위치 `apps/web`, 출력 `dist`. `VITE_API_BASE=https://garim-api.koreacentral.cloudapp.azure.com`
- core의 `CORS_ORIGIN`에 SWA 주소 등록

## 7. 보안 체크리스트
- [ ] NSG 인바운드: 22(내 IP만), 80, 443만
- [ ] LM Studio·ai·Postgres·core는 127.0.0.1 바인딩 (`--bind 0.0.0.0` 금지)
- [ ] `.env.*` 권한 600, `MAPPING_KEY`는 ai 쪽에만
- [ ] 심사 끝나면 `az vm deallocate -g rg-garim -n vm-garim`

## 8. 로컬 개발
PC에 LM Studio 데스크톱 → Developer 탭 → qwen3-4b·bge-m3 로드 → Start Server(1234).
`docker compose -f infra/docker-compose.dev.yml up -d postgres` 후 core·ai를 로컬 실행.
