-- 가림AI 초기 스키마 (docs/02-TRD.md 7절)
-- 규칙: 원문 PII 저장 금지. 텍스트는 가린 텍스트, 매핑은 ai가 암호화한 blob만.

CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS documents (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name           TEXT        NOT NULL,
  kind           TEXT        NOT NULL CHECK (kind IN ('pdf', 'xlsx')),
  page_or_rows   INT         NOT NULL,
  entity_counts  JSONB       NOT NULL DEFAULT '{}'::jsonb,
  mapping_enc    BYTEA       NOT NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS chunks (
  id           UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id  UUID         NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  ord          INT          NOT NULL,
  loc          JSONB        NOT NULL,
  text_masked  TEXT         NOT NULL,
  embedding    vector(1024) NOT NULL,
  UNIQUE (document_id, ord)
);
CREATE INDEX IF NOT EXISTS chunks_embedding_hnsw
  ON chunks USING hnsw (embedding vector_cosine_ops);

CREATE TABLE IF NOT EXISTS todos (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  title_masked  TEXT        NOT NULL,
  due           DATE,
  status        TEXT        NOT NULL DEFAULT 'todo' CHECK (status IN ('todo', 'doing', 'done')),
  source        TEXT        NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS todos_status_due_idx ON todos (status, due);

CREATE TABLE IF NOT EXISTS audit_log (
  id             BIGSERIAL   PRIMARY KEY,
  at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  kind           TEXT        NOT NULL CHECK (kind IN ('run', 'ask', 'ingest')),
  task           TEXT,
  model          TEXT,
  masked_counts  JSONB       NOT NULL DEFAULT '{}'::jsonb,
  decision       TEXT        NOT NULL,
  latency_ms     INT
);
CREATE INDEX IF NOT EXISTS audit_log_at_idx ON audit_log (at DESC);
