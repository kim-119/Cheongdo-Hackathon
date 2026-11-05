# 05. Azure에서 LM Studio 운영하기

LM Studio는 서버용 **헤드리스 데몬(llmster) + `lms` CLI** 를 제공한다. Azure VM에 설치해 OpenAI 호환 API(`/v1`)로 쓴다.

## 1. VM 고르기
| 상황 | VM 크기 | 모델 |
|---|---|---|
| GPU 쿼터 있음 | `Standard_NC4as_T4_v3` (T4 16GB) | 7~8B Q4 |
| GPU 쿼터 없음 (학생/무료 구독 흔함) | `Standard_D8s_v5` (8 vCPU, 32GB) | 2.4~4B Q4 |
- OS: Ubuntu 22.04 LTS, 디스크 64GB+
- GPU는 기본 쿼터 0인 경우가 많음 → **포털 > 할당량 > 증가 요청을 미리** 넣을 것.

## 2. VM 생성 (Azure CLI)
```bash
az group create -n rg-garim -l koreacentral
az vm create -g rg-garim -n vm-garim \
  --image Ubuntu2204 --size Standard_D8s_v5 \
  --admin-username azureuser --generate-ssh-keys \
  --os-disk-size-gb 64 --public-ip-sku Standard
az vm open-port -g rg-garim -n vm-garim --port 443 --priority 1001
# 1234 포트는 열지 않는다
```

## 3. LM Studio 설치·실행 (VM 안에서)
```bash
ssh azureuser@<VM_IP>
curl -fsSL https://lmstudio.ai/install.sh | bash
source ~/.bashrc

lms daemon up
lms get qwen/qwen3-4b            # 모델 다운로드 (검색어/HF 경로 가능)
lms ls                           # 받은 모델 확인
lms load qwen/qwen3-4b --context-length 8192
lms server start --port 1234     # 기본 127.0.0.1 → 외부 노출 X

curl http://127.0.0.1:1234/v1/models   # 확인
```
> GPU VM이면 드라이버 먼저: `sudo apt install -y ubuntu-drivers-common && sudo ubuntu-drivers autoinstall && sudo reboot`

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
ExecStart=/bin/bash -lc 'lms daemon up && lms load qwen/qwen3-4b --context-length 8192 && lms server start --port 1234'
ExecStop=/bin/bash -lc 'lms server stop; lms daemon down'

[Install]
WantedBy=multi-user.target
```
```bash
sudo systemctl daemon-reload && sudo systemctl enable --now lmstudio
```

## 5. API 컨테이너에서 접근
컨테이너에서 호스트의 127.0.0.1에 붙으려면 `network_mode: host`.
```yaml
# infra/docker-compose.yml
services:
  api:
    image: ghcr.io/kim-119/garim-api:latest
    network_mode: host
    env_file: .env          # LOCAL_BASE_URL=http://127.0.0.1:1234/v1
    restart: always
  caddy:
    image: caddy:2
    network_mode: host
    volumes: [ "./Caddyfile:/etc/caddy/Caddyfile" ]
    restart: always
```
`Caddyfile` (도메인 없으면 nip.io로 자동 HTTPS)
```
api.<VM_IP>.nip.io {
  reverse_proxy 127.0.0.1:8080
}
```
※ 이 경우 NSG에 80 포트도 열어야 인증서 발급됨.

## 6. 보안 체크리스트
- [ ] NSG 인바운드: 22(내 IP만), 80, 443만
- [ ] LM Studio는 127.0.0.1 바인딩 (`--bind 0.0.0.0` 금지)
- [ ] 시크릿은 `.env`(권한 600) 또는 Key Vault
- [ ] 심사 끝나면 `az vm deallocate -g rg-garim -n vm-garim` 로 비용 차단

## 7. 로컬 개발
PC에 LM Studio 데스크톱 설치 → Developer 탭 → Start Server(1234) → 같은 `LOCAL_BASE_URL` 로 개발.
