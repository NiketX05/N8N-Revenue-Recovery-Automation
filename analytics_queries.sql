-- ============================================================
-- Failed Payments + Churn Saver v2.1 — Analytics Queries
-- ============================================================
-- Run these queries in the Supabase SQL Editor (Dashboard → SQL Editor)
-- to view the analytics views created by supabase_schema.sql.
-- These views are pre-built — no additional setup required.
-- ============================================================

-- Recovery Stats
-- Shows aggregated recovery/conversion metrics across dunning stages.
SELECT * FROM recovery_stats;

-- Churn Monthly Summary
-- Shows churn events grouped by month and customer revenue tier.
SELECT * FROM churn_monthly_summary;
