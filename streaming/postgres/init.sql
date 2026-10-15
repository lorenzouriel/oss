-- Serving tables written by Flink sinks.
-- Primary keys make the sinks idempotent: replays/restarts upsert instead of duplicating.

CREATE TABLE IF NOT EXISTS market_metrics (
    symbol        TEXT           NOT NULL,
    window_start  TIMESTAMPTZ    NOT NULL,
    window_end    TIMESTAMPTZ    NOT NULL,
    last_price    NUMERIC(18, 6) NOT NULL,
    high          NUMERIC(18, 6) NOT NULL,
    low           NUMERIC(18, 6) NOT NULL,
    volume        BIGINT         NOT NULL,
    trade_count   INTEGER        NOT NULL,
    vwap          NUMERIC(18, 6) NOT NULL,
    updated_at    TIMESTAMPTZ    NOT NULL DEFAULT now(),
    PRIMARY KEY (symbol, window_start)
);

CREATE INDEX IF NOT EXISTS idx_market_metrics_window_start
    ON market_metrics (window_start DESC);

CREATE TABLE IF NOT EXISTS market_alerts (
    alert_id     TEXT        PRIMARY KEY,
    symbol       TEXT        NOT NULL,
    alert_type   TEXT        NOT NULL,
    severity     TEXT        NOT NULL,
    event_time   TIMESTAMPTZ NOT NULL,
    payload      JSONB       NOT NULL DEFAULT '{}'::jsonb,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_market_alerts_symbol_time
    ON market_alerts (symbol, event_time DESC);

-- Latest window per symbol, for "current state" Grafana panels
CREATE OR REPLACE VIEW market_metrics_latest AS
SELECT DISTINCT ON (symbol) *
FROM market_metrics
ORDER BY symbol, window_start DESC;
