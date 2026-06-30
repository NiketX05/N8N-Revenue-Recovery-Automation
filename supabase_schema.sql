-- ============================================================
-- ⚡ Failed Payments + Churn Saver — Supabase Schema
-- Run this SQL in your Supabase SQL Editor to create all tables.
-- ============================================================

-- Enable UUID generation
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================
-- 1. PAYMENT EVENTS (Idempotency — Task 2)
-- ============================================================
CREATE TABLE IF NOT EXISTS payment_events (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  stripe_event_id TEXT UNIQUE NOT NULL,
  event_type TEXT NOT NULL,
  status TEXT DEFAULT 'processing' CHECK (status IN ('processing', 'processed', 'failed')),
  customer_id TEXT,
  invoice_id TEXT,
  subscription_id TEXT,
  error_message TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_payment_events_stripe_id ON payment_events(stripe_event_id);
CREATE INDEX idx_payment_events_status ON payment_events(status);
CREATE INDEX idx_payment_events_customer ON payment_events(customer_id);

-- ============================================================
-- 2. DUNNING EVENTS (Core tracking — Tasks 3, 4, 8, 10)
-- ============================================================
CREATE TABLE IF NOT EXISTS dunning_events (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  stripe_invoice_id TEXT NOT NULL,
  stripe_subscription_id TEXT,
  stripe_customer_id TEXT,
  customer_email TEXT,
  customer_name TEXT,
  amount_due NUMERIC(10,2),
  currency TEXT DEFAULT 'USD',
  failure_stage TEXT CHECK (failure_stage IN ('first_failure', 'second_failure', 'third_failure', 'final_failure')),
  attempt_count INT DEFAULT 1,
  urgency_level TEXT DEFAULT 'low' CHECK (urgency_level IN ('low', 'medium', 'high', 'critical')),
  failure_reason TEXT,
  failure_code TEXT,
  revenue_tier TEXT DEFAULT 'low' CHECK (revenue_tier IN ('low', 'mid', 'high')),
  template_variant TEXT DEFAULT 'A',
  status TEXT DEFAULT 'PENDING_RECOVERY' CHECK (status IN ('PENDING_RECOVERY', 'RECOVERED')),
  last_email_sent_at TIMESTAMPTZ,
  last_dunning_stage_reached TEXT CHECK (last_dunning_stage_reached IN ('first_failure', 'second_failure', 'third_failure', 'final_failure')),
  stripe_event_id TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  -- IMPROVEMENT Issue 8: Email format validation at DB level
  -- Ensures customer_email is either NULL or a valid-looking email address
  CONSTRAINT dunning_events_email_format CHECK (
    customer_email IS NULL OR
    customer_email ~ '^[^\s@]+@[^\s@]+\.[^\s@]+$'
  )
);

CREATE INDEX idx_dunning_invoice ON dunning_events(stripe_invoice_id);
CREATE INDEX idx_dunning_subscription ON dunning_events(stripe_subscription_id);
CREATE INDEX idx_dunning_status ON dunning_events(status);
CREATE INDEX idx_dunning_customer ON dunning_events(stripe_customer_id);
CREATE INDEX idx_dunning_email ON dunning_events(customer_email);

-- ============================================================
-- 3. FAILED INTEGRATIONS (Error handling — Task 6)
-- ============================================================
CREATE TABLE IF NOT EXISTS failed_integrations (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  operation_type TEXT NOT NULL,
  node_name TEXT,
  error_message TEXT,
  payload JSONB,
  retry_count INT DEFAULT 0,
  status TEXT DEFAULT 'failed' CHECK (status IN ('failed', 'retried', 'resolved')),
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- 4. HELPER: Auto-update updated_at timestamp
-- ============================================================
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_payment_events_updated
  BEFORE UPDATE ON payment_events
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trg_dunning_events_updated
  BEFORE UPDATE ON dunning_events
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trg_failed_integrations_updated
  BEFORE UPDATE ON failed_integrations
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ============================================================
-- 5. CHURN EVENTS (separate from dunning_events — Task 6 / v2.1)
-- ============================================================
CREATE TABLE IF NOT EXISTS churn_events (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  stripe_subscription_id TEXT NOT NULL,
  stripe_customer_id TEXT,
  customer_email TEXT,
  customer_name TEXT,
  monthly_revenue_lost NUMERIC(10,2),
  currency TEXT DEFAULT 'USD',
  cancel_reason TEXT,
  revenue_tier TEXT DEFAULT 'low' CHECK (revenue_tier IN ('low', 'mid', 'high')),
  stripe_event_id TEXT,
  cancelled_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_churn_revenue ON churn_events(revenue_tier);
CREATE INDEX idx_churn_created ON churn_events(created_at);
CREATE INDEX idx_churn_cancel_reason ON churn_events(cancel_reason);

DROP TRIGGER IF EXISTS trg_churn_events_updated ON churn_events;
CREATE TRIGGER trg_churn_events_updated
  BEFORE UPDATE ON churn_events
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ============================================================
-- 6. ROW LEVEL SECURITY (recommended for production)
-- ============================================================
-- Enable RLS on all tables
ALTER TABLE payment_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE dunning_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE failed_integrations ENABLE ROW LEVEL SECURITY;
ALTER TABLE churn_events ENABLE ROW LEVEL SECURITY;

-- Service role can do everything (n8n uses service key)
CREATE POLICY "Service role full access" ON payment_events
  FOR ALL USING (auth.role() = 'service_role');
CREATE POLICY "Service role full access" ON dunning_events
  FOR ALL USING (auth.role() = 'service_role');
CREATE POLICY "Service role full access" ON failed_integrations
  FOR ALL USING (auth.role() = 'service_role');
CREATE POLICY "Service role full access" ON churn_events
  FOR ALL USING (auth.role() = 'service_role');

-- ============================================================
-- 7. DUNNING TABLE UPDATES (v2.1 — churn now tracked separately)
-- ============================================================
-- Update dunning_events: remove 'CHURNED' from status constraint
-- (Churn is now tracked in churn_events)
ALTER TABLE dunning_events DROP CONSTRAINT IF EXISTS dunning_events_status_check;
ALTER TABLE dunning_events ADD CONSTRAINT dunning_events_status_check
  CHECK (status IN ('PENDING_RECOVERY', 'RECOVERED'));

-- Add unique constraint to prevent duplicate dunning rows per invoice
ALTER TABLE dunning_events ADD CONSTRAINT uniq_dunning_per_event
  UNIQUE (stripe_event_id);

-- ============================================================
-- 8. EMAIL VALIDATION (IMPROVEMENT Issue 8)
-- ============================================================
-- The dunning_events table already has a CHECK constraint on customer_email
-- via the inline CONSTRAINT dunning_events_email_format defined in CREATE TABLE.
-- If you ran the schema before this update, apply the constraint manually:
-- ALTER TABLE dunning_events
--   ADD CONSTRAINT dunning_events_email_format
--   CHECK (customer_email IS NULL OR customer_email ~ '^[^\s@]+@[^\s@]+\.[^\s@]+$');

-- Same validation for churn_events customer_email
ALTER TABLE churn_events
  ADD CONSTRAINT churn_events_email_format
  CHECK (customer_email IS NULL OR customer_email ~ '^[^\s@]+@[^\s@]+\.[^\s@]+$');

-- NOTE: The n8n workflow also validates email format before inserting
-- (regex /^[^\s@]+@[^\s@]+\.[^\s@]+$/ in Classify Failure & Check: Still Unpaid? nodes)
-- DB constraint provides defence-in-depth if records are inserted via other means.

-- ============================================================
-- 9. ANALYTICS VIEWS (for buyer dashboards)
-- ============================================================

ALTER TABLE payment_events ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ DEFAULT NULL;
ALTER TABLE dunning_events ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ DEFAULT NULL;
ALTER TABLE churn_events ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ DEFAULT NULL;

CREATE OR REPLACE VIEW recovery_stats AS
SELECT 
  revenue_tier,
  template_variant,
  COUNT(*) as total_failed,
  COUNT(*) FILTER (WHERE status = 'RECOVERED') as recovered,
  ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'RECOVERED') / NULLIF(COUNT(*), 0), 2) as recovery_rate_pct,
  SUM(amount_due) FILTER (WHERE status = 'RECOVERED') as total_recovered_amount,
  AVG(EXTRACT(EPOCH FROM (updated_at - created_at))/3600) FILTER (WHERE status = 'RECOVERED') as avg_hours_to_recovery
FROM dunning_events
GROUP BY revenue_tier, template_variant;

CREATE OR REPLACE VIEW churn_monthly_summary AS
SELECT 
  DATE_TRUNC('month', cancelled_at) as month,
  COUNT(*) as churned_customers,
  SUM(monthly_revenue_lost) as total_monthly_revenue_lost,
  AVG(monthly_revenue_lost) as avg_revenue_per_churned_customer,
  revenue_tier
FROM churn_events
GROUP BY DATE_TRUNC('month', cancelled_at), revenue_tier
ORDER BY month DESC;

COMMENT ON VIEW recovery_stats IS 'Query this in Supabase SQL Editor or connect to Metabase/Retool for recovery analytics';
COMMENT ON VIEW churn_monthly_summary IS 'Monthly churn trends by revenue tier — useful for board reports';
