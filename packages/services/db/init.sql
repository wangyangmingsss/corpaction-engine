-- CorpAction Engine Database Schema
-- PostgreSQL 16+

-- Core types
CREATE TYPE source_type AS ENUM (
    'SEC_EDGAR', 'DTCC', 'EOD_HISTORICAL', 'POLYGON',
    'ALPHA_VANTAGE', 'BLOOMBERG', 'MANUAL'
);

CREATE TYPE action_type AS ENUM (
    'DIVIDEND', 'FORWARD_SPLIT', 'REVERSE_SPLIT',
    'MERGER_CASH', 'MERGER_STOCK', 'MERGER_HYBRID',
    'SPINOFF', 'DELISTING', 'LIQUIDATION', 'TICKER_CHANGE'
);

CREATE TYPE event_status AS ENUM (
    'INGESTED', 'CLASSIFIED', 'DEDUPLICATED',
    'INTENT_BUILT', 'SUBMITTED', 'CONFIRMED', 'FAILED'
);

CREATE TYPE confidence_level AS ENUM ('LOW', 'MEDIUM', 'HIGH');

-- Raw events from external sources
CREATE TABLE raw_events (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source          source_type NOT NULL,
    source_id       TEXT NOT NULL,
    source_url      TEXT,
    content_hash    BYTEA NOT NULL,
    raw_data        JSONB NOT NULL,
    ticker          TEXT,
    isin            TEXT,
    detected_type   action_type,
    confidence      confidence_level DEFAULT 'LOW',
    status          event_status DEFAULT 'INGESTED',
    ingested_at     TIMESTAMPTZ DEFAULT NOW(),
    processed_at    TIMESTAMPTZ,
    UNIQUE(source, source_id)
);

-- Deduplicated and classified corporate actions
CREATE TABLE corporate_actions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    action_type     action_type NOT NULL,
    ticker          TEXT NOT NULL,
    isin            TEXT,
    company_name    TEXT,
    effective_date  DATE NOT NULL,
    record_date     DATE,
    ex_date         DATE,
    params          JSONB NOT NULL,
    confidence      confidence_level DEFAULT 'LOW',
    source_count    INT DEFAULT 1,
    intent_id       BYTEA,
    on_chain_status TEXT DEFAULT 'PENDING',
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(ticker, action_type, effective_date)
);

-- Linking table: raw events to corporate actions
CREATE TABLE event_sources (
    corporate_action_id UUID REFERENCES corporate_actions(id),
    raw_event_id        UUID REFERENCES raw_events(id),
    PRIMARY KEY (corporate_action_id, raw_event_id)
);

-- Merkle trees for dividend/spinoff distributions
CREATE TABLE merkle_trees (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    intent_id       BYTEA NOT NULL UNIQUE,
    merkle_root     BYTEA NOT NULL,
    snapshot_block  BIGINT NOT NULL,
    total_holders   INT NOT NULL,
    total_amount    NUMERIC(78, 0) NOT NULL,
    tree_data       JSONB NOT NULL,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- Individual holder entitlements (for proof generation)
CREATE TABLE merkle_leaves (
    tree_id         UUID REFERENCES merkle_trees(id),
    holder_address  TEXT NOT NULL,
    amount          NUMERIC(78, 0) NOT NULL,
    leaf_index      INT NOT NULL,
    proof           JSONB NOT NULL,
    claimed         BOOLEAN DEFAULT FALSE,
    PRIMARY KEY (tree_id, holder_address)
);

-- On-chain execution audit trail
CREATE TABLE execution_log (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    intent_id       BYTEA NOT NULL,
    tx_hash         BYTEA NOT NULL,
    block_number    BIGINT NOT NULL,
    gas_used        BIGINT,
    status          TEXT NOT NULL,
    error_message   TEXT,
    executed_at     TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_raw_events_ticker ON raw_events(ticker);
CREATE INDEX idx_raw_events_status ON raw_events(status);
CREATE INDEX idx_raw_events_ingested ON raw_events(ingested_at);
CREATE INDEX idx_corp_actions_ticker ON corporate_actions(ticker);
CREATE INDEX idx_corp_actions_date ON corporate_actions(effective_date);
CREATE INDEX idx_corp_actions_status ON corporate_actions(on_chain_status);
CREATE INDEX idx_execution_log_intent ON execution_log(intent_id);

-- Validator attestation records
CREATE TABLE validator_attestations (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    validator_addr  TEXT NOT NULL,
    intent_id       BYTEA NOT NULL,
    attested_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    signature       BYTEA NOT NULL,
    verified        BOOLEAN DEFAULT FALSE
);

-- Fee tracking per corporate action
CREATE TABLE fee_tracking (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    intent_id       BYTEA NOT NULL,
    action_type     action_type NOT NULL,
    fee_amount      NUMERIC(78, 0) NOT NULL,
    holder_count    INT NOT NULL DEFAULT 0,
    collected_at    TIMESTAMPTZ DEFAULT NOW()
);

-- Token registry mapping tickers to on-chain addresses
CREATE TABLE token_registry (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    ticker          TEXT NOT NULL,
    token_address   TEXT NOT NULL,
    chain_id        INT NOT NULL,
    isin            TEXT,
    active          BOOLEAN DEFAULT TRUE,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(token_address, chain_id)
);

-- Holder balance snapshots for record-date calculations
CREATE TABLE holder_snapshots (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    token_address   TEXT NOT NULL,
    block_number    BIGINT NOT NULL,
    holder_address  TEXT NOT NULL,
    balance         NUMERIC(78, 0) NOT NULL,
    snapshot_at     TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(token_address, block_number, holder_address)
);

-- Additional indexes
CREATE INDEX idx_corporate_actions_intent_id ON corporate_actions(intent_id);
CREATE INDEX idx_execution_log_status ON execution_log(status);
CREATE INDEX idx_validator_attestations_intent ON validator_attestations(intent_id);
CREATE INDEX idx_fee_tracking_intent ON fee_tracking(intent_id);
CREATE INDEX idx_token_registry_ticker ON token_registry(ticker);
CREATE INDEX idx_holder_snapshots_token_block ON holder_snapshots(token_address, block_number);
