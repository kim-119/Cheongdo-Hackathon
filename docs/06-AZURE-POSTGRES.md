# 06. Azure PostgreSQL + pgvector

AWS RDS에 해당하는 **Azure Database for PostgreSQL (Flexible Server)** 에 pgvector를 켜서 업무 DB와 벡터 DB를 하나로 쓴다.

| 항목 | 값 |
|---|---|
| SKU | Burstable `Standard_B1ms` (1 vCPU, 2GB) · 32GB · PG 16 · 월 ≈ $16 |
| 접근 | 공용 접근 + 방화벽 **VM IP만**, TLS 필수 |
| 확장 | `vector` (pgvector, HNSW·코사인) |
| 스키마 | `apps/core/migrations/0001_init.sql` (`documents`, `chunks`, `todos`, `audit_log`) |
| 저장 내용 | 가린 텍스트 · AES-GCM 암호화 매핑 · 임베딩(1024) · 메타데이터. **원문 PII 없음** |

## 1. 서버 생성 (Cloud Shell)
```bash
az account set --subscription a839a45e-8e7d-4ef3-8b04-0f3469eb98b6
az provider register -n Microsoft.DBforPostgreSQL --wait

PG=garim-pg-$RANDOM
PG_PW=$(openssl rand -base64 24 | tr -d '/+=')
echo "서버: $PG  비밀번호: $PG_PW"      # ← 반드시 따로 저장

az postgres flexible-server create -g rg-garim -n $PG -l koreacentral \
  --tier Burstable --sku-name Standard_B1ms --storage-size 32 --version 16 \
  --admin-user garimadmin --admin-password "$PG_PW" \
  --public-access <VM_공인IP> --yes

az postgres flexible-server db create -g rg-garim -s $PG -d garim
az postgres flexible-server parameter set -g rg-garim --server-name $PG \
  --name azure.extensions --value VECTOR
```
- `--public-access <VM_공인IP>` = 그 IP만 허용하는 방화벽 규칙 생성.
- 마지막 줄 = pgvector 허용 목록 등록. 빠지면 `CREATE EXTENSION vector` 실패.
- 지역 제한 에러(`LocationIsOfferRestricted`)면 `-l koreasouth` / `-l japaneast`.

## 2. 스키마 적용 (VM 안에서)
```bash
sudo apt-get install -y postgresql-client
export DATABASE_URL='postgres://garimadmin:<비밀번호>@<서버>.postgres.database.azure.com:5432/garim?sslmode=require'

curl -fsSL https://raw.githubusercontent.com/kim-119/Cheongdo-Hackathon/main/apps/core/migrations/0001_init.sql \
  | psql "$DATABASE_URL" -v ON_ERROR_STOP=1

psql "$DATABASE_URL" -c '\dx vector' -c '\dt'
```
`vector` 확장 + 테이블 4개가 보이면 완료. 이후에는 `core`가 시작할 때 sqlx 마이그레이션으로 관리한다(파일은 `IF NOT EXISTS`라 재실행 안전).

## 3. 연결
- VM: `.env.core`의 `DATABASE_URL`에 위 값 (권한 600).
- GitHub Actions 배포: Secrets `DATABASE_URL`.
- CI 테스트는 Azure DB가 아니라 `pgvector/pgvector:pg16` 서비스 컨테이너 사용.

## 4. 보안
- 방화벽은 VM IP 하나만. 내 PC에서 볼 때만 임시 추가 후 삭제:
  ```bash
  az postgres flexible-server firewall-rule create -g rg-garim -n $PG -r dev-pc --start-ip-address <내IP> --end-ip-address <내IP>
  az postgres flexible-server firewall-rule delete -g rg-garim -n $PG -r dev-pc --yes
  ```
- 원문·평문 매핑 저장 금지 (`AGENTS.md` 절대 규칙 2·3).

## 5. 비용
```bash
az postgres flexible-server stop  -g rg-garim -n $PG    # 정지 중엔 컴퓨팅 요금 없음, 7일 후 자동 재시작
az postgres flexible-server start -g rg-garim -n $PG
```
