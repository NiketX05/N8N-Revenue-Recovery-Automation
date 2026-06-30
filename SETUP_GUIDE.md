# ⚡ Failed Payments + Churn Saver v2.1 — Setup Guide

> **Total setup time:** ~60–90 minutes  
> **Prerequisites:** A Stripe account, a Supabase project, an n8n instance, SMTP credentials, and a Slack workspace (optional).

---

## 🎯 What This Does

Automatically recovers failed Stripe payments via an intelligently timed, multi-stage dunning sequence, handling webhook tracking, multi-channel alerting, and churn analytics tracking.

```
Stripe fires webhook
  ↓
Verify signature (reject if invalid)
  ↓
Idempotency check (skip if duplicate)
  ↓
Respond 200 to Stripe immediately
  ↓
Route by event type:
  ├── invoice.payment_failed ──► Classify ──► Save to DB ──► Route by stage:
  │     ├── 1st failure ──► Wait 4h ──► Email: Friendly Reminder ──► Slack ──► Finalize ──► Sheets
  │     ├── 2nd failure ──► Wait 1h ──► [Check if recovered] ──► Email: Update Card ──► ...
  │     ├── 3rd failure ──► Wait 24h ──► [Check if recovered] ──► Email: Urgent Warning ──► ...
  │     └── 4th failure ──► Wait 72h ──► [Check if recovered] ──► Email: Final / Win-Back ──► ...
  │
  ├── invoice.payment_succeeded ──► Check if was dunning ──► Slack celebration ──► Finalize ──► Sheets
  │
  └── customer.subscription.deleted ──► Process churn ──► Slack alert ──► Save to churn_events ──► Sheets
```

> **⚠️ Timing Note:** Stage 1 waits its configured duration after the `invoice.payment_failed` webhook fires. Stages 2–4 each wait their configured duration from the point the *previous stage's failure event* was received — not from when the previous email was sent. Because Stripe spaces its own automatic retries independently (typically 3, 5, and 7 days after the first failure), the actual gap between your dunning emails depends on both your wait values and Stripe's retry schedule. For predictable timing, set your `DUNNING_WAIT_STAGE_*` values to be shorter than Stripe's retry intervals, so your email always fires before Stripe's next automatic retry attempt. You can configure Stripe's retry schedule under **Settings → Subscriptions and emails → Manage failed payments**.

---

## 🛑 Before You Start (Checklist)

- [ ] You have access to your Stripe dashboard to get a Webhook Secret.
- [ ] You have a Supabase project created.
- [ ] You have an n8n instance running.
- [ ] You have SMTP credentials for sending emails.

---

## 🛠️ Step 1: Database Setup

**Goal:** Provide a reliable state management backend for the tracking sequence.

**Actions:**
1. Open your **Supabase Dashboard** -> **SQL Editor**.
2. Run the full contents of `supabase_schema.sql` (found in this repo folder).
3. Under **Project Settings -> API**, copy your `Project URL` and `service_role` secret key. Keep them safe.

**Verify:** Go to your Supabase Table Editor and confirm `payment_events`, `dunning_events`, `failed_integrations`, and `churn_events` exist. Look for two views `recovery_stats` and `churn_monthly_summary`.

**Troubleshoot:**
- *Errors in SQL execution:* Ensure you haven't run previous versions without dropping tables.
- *Error: function update_updated_at() does not exist:* The schema has a trigger ordering dependency. Run the full schema script again from scratch — all `CREATE TABLE` statements use `IF NOT EXISTS` so it is safe to re-run.

---

## ⚙️ Step 2: n8n Workflow Import

**Goal:** Import the workflow JSON logic into n8n.

**Actions:**
1. Open n8n and go to **Workflows**.
2. Click **Add Workflow** -> **Import from File**.
3. Select `workflows/failed_payments_churn_saver_v2.json`.
4. The workflow **"⚡ Failed Payments + Churn Saver v2.1"** will appear with all 55 nodes.

**Verify:** Look for the start node and any credential warnings.

**Troubleshoot:**
- *Failed to import:* Make sure you are using an n8n version that is up to date (1.x or higher). 

---

## 🔌 Step 3: Configure Variables

**Goal:** Map your environment variables directly into the n8n UI, without editing code nodes.

**Actions:**
1. Go to **Settings -> Variables** in n8n.
2. Add the following variables:

| Variable | Description | Example Format |
|---|---|---|
| `STRIPE_SIGNING_SECRET` | Stripe Webhook Signing Secret | `whsec_xxx` |
| `SUPABASE_URL` | Supabase Project URL | `https://xxx.supabase.co` |
| `SUPABASE_SERVICE_KEY` | Supabase Service Role Key | `eyJhbGciOiJIUz...` |
| `SENDER_EMAIL` | Address emails are sent from | `Billing Team <billing@you.com>` |
| `REPLY_TO_EMAIL` | Where replies go | `support@you.com` |
| `SLACK_BILLING_CHANNEL` | Slack channel for alerts | `#billing-alerts` |
| `STRIPE_PORTAL_URL` | Your Stripe Customer Portal URL | `https://billing.stripe.com/p/login/xxx` |
| `DUNNING_WAIT_STAGE_1` | Minutes before 1st email | `240` (4 hours) |
| `DUNNING_WAIT_STAGE_2` | Minutes before 2nd email | `60` (1 hour) |
| `DUNNING_WAIT_STAGE_3` | Minutes before 3rd email | `1440` (24 hours) |
| `DUNNING_WAIT_STAGE_4` | Minutes before 4th email | `4320` (72 hours) |

> **⚠️ Security:** `SUPABASE_SERVICE_KEY` is a service role key with full database access that bypasses Row Level Security. Never put it in client-side code or commit it to a public repository. Store it only in n8n's encrypted variables store.

**Verify:** Double-check your Supabase service key is completely accurate. Do not use the `anon` key.

**Troubleshoot:**
- *N8n can't read variables:* Be sure to Save your variables setup.

---

## 🔑 Step 4: Connect Credentials

**Goal:** Connect third-party credentials directly in n8n.

**Actions:**

### 📧 SMTP (for 8 email nodes)
1. Click on any email node (e.g., "Email: Friendly Reminder (Variant A)").
2. In the **Credential** dropdown, click **Create New**.
3. Enter your SMTP details (Host, Port 587 or 465, User/Pass).
4. Save, then apply the **same credential** to all 8 email nodes:

   **Variant A (formal / professional tone):**
   - `Email: Friendly Reminder (Variant A)`
   - `Email: Update Card Request (Variant A)`
   - `Email: Urgent Warning (Variant A)`
   - `Email: Final / Win-Back (Variant A)`

   **Variant B (casual / conversational tone):**
   - `Email: Friendly Reminder (Variant B)`
   - `Email: Update Card Request (Variant B)`
   - `Email: Urgent Warning (Variant B)`
   - `Email: Final / Win-Back (Variant B)`

> 💡 Each customer is assigned to Variant A or B deterministically based on their Stripe customer ID — so the same customer always receives the same tone across every retry stage. This makes A/B results meaningful and prevents a customer from receiving mixed messaging.

### 💬 Slack (for 3 Slack nodes)
1. Click on any Slack node.
2. Connect your Slack OAuth2 credential. (Ensure your n8n OAuth Callback URL is registered in your Slack App).
3. Apply to all 3 Slack nodes.

### 📊 Google Sheets (Optional)
> **⏭️ Recommendation: Skip this entirely.** Most users should right-click all three Sheets nodes → Disable, and move on. Supabase is your audit log. Google Sheets adds auth complexity with no reliability benefit. Only set this up if a stakeholder specifically needs a spreadsheet view.
> **⚠️ Google Sheets is optional.** If you don't need a spreadsheet log, you can disable the three Sheets nodes in n8n (right-click → Disable) without affecting any other part of the workflow. All core data is already stored in Supabase.
> 
> **Known limitations of Google Sheets in this workflow:**
> - Google OAuth2 tokens expire and require periodic re-authentication — this can cause silent failures
> - Google Sheets API has a rate limit of 300 write requests per minute; high-volume billing events may hit this
> - If the "Recovery Tracker" tab is renamed or deleted, all three Sheets nodes will fail
> - Sheets is not a reliable audit log for compliance purposes — use the Supabase tables for that

1. Click on "Google Sheets: Log Event".
2. Create Google Sheets OAuth2 API Auth.
3. Apply to all 3 Sheets nodes and set your Spreadsheet ID.

**Verify:** No credential nodes show an error state.

---

## 🪝 Step 5: Webhook Setup

**Goal:** Link Stripe to n8n.

**Actions:**
1. In the n8n Webhook trigger node, get the **Production URL**.
2. Go to Stripe -> **Developers -> Webhooks**.
3. Add Endpoint -> Paste your n8n Production URL.
4. Listen to: `invoice.payment_failed`, `invoice.payment_succeeded`, `customer.subscription.deleted`.
5. Save, then grab the **Webhook Signing Secret** (`whsec_xxx`) from Stripe.
6. Make sure you set your `STRIPE_SIGNING_SECRET` variable in n8n.
7. Click **Activate** on your n8n workflow.

**Verify:** Workflow should display as "Active" in the n8n UI.

---

## 🧪 How to Know It's Working (Testing)

Follow this checklist:
- [ ] **Trigger a test event:** In Stripe (Test Mode), use a test card that declines, or trigger `invoice.payment_failed` manually via the Stripe CLI.
  - Use `4000 0000 0000 0341` — card attaches but payment fails
  - Use `4000 0000 0000 9995` — insufficient funds decline
  - Full list: https://stripe.com/docs/testing#cards
- [ ] **Check n8n Executions:** Look at the Executions tab. You should see a successful execution of the workflow.
- [ ] **Check Supabase:** Check your `payment_events` and `dunning_events` table for entries.
- [ ] **Recover the payment:** Trigger a successful payment (`invoice.payment_succeeded`).
- [ ] **Check Slack:** You should see alerts triggering in the channel you configured.

### 💻 Stripe CLI Testing

If you have the [Stripe CLI](https://stripe.com/docs/stripe-cli) installed, you can trigger test events directly from your terminal without needing to create test subscriptions or use test cards:

```bash
stripe trigger invoice.payment_failed
stripe trigger invoice.payment_succeeded
stripe trigger customer.subscription.deleted
```

> **Note:** Make sure the Stripe CLI is listening to your n8n webhook URL first. Run `stripe listen --forward-to <your-n8n-webhook-url>` in a separate terminal before triggering events.

---

## 📈 Analytics & A/B Testing

### A/B Testing
The workflow deterministically splits audiences evenly across Variant A (Formal tone) and Variant B (Casual tone) based on Stripe Customer IDs. This means a customer always gets the corresponding email templates for their assigned variant, preventing mixed messaging.

### Analytics Views
We provide two pre-configured SQL views in Supabase for your dashboards:
- `recovery_stats` - Aggregated conversion recovery percentages.
- `churn_monthly_summary` - Segmented churn logs grouped by month and your customers' revenue tiers.
You can query these via Supabase's REST API or connect a BI tool to your postgres database directly.

---

## 🆘 Troubleshooting

| Issue | Solution |
|---|---|
| Slack not posting | Verify Slack credential and `SLACK_BILLING_CHANNEL` exists |
| Workflow not triggering | Make sure the workflow is **Active** (toggled on) |
| Missing `STRIPE_SIGNING_SECRET` | The webhook verify node will instantly fail requests |
| Google Sheets error | Verify the Sheet ID and that the "Recovery Tracker" tab exists |
| Google Sheets auth expired | Re-authenticate the Google Sheets OAuth2 credential in n8n Settings → Credentials. This happens periodically and must be done manually. Consider disabling Sheets nodes if uptime is critical. |
| Errors in `failed_integrations` | Check this table in Supabase — it logs any write failures for debugging |
| n8n restarts mid-dunning sequence | **Cloud / queue mode:** Wait nodes resume automatically after restart. **Basic self-hosted:** In-progress executions may be lost. Use n8n Cloud or enable queue mode (`EXECUTIONS_MODE=queue`) for production. |

---

## 📄 File Reference & Support Policy

- `failed_payments_churn_saver_v2.json` — The main logic block
- `supabase_schema.sql` — Run this to generate your database tables
- `SETUP_GUIDE.md` — This instruction set

> **Disclaimer:** This workflow handles billing actions and is meant to be a foundational template. Please thoroughly map edge cases, understand the system logic, and test entirely in Stripe Sandbox mode before using in a production capacity. You are fully responsible for ensuring it behaves correctly for your specific use-case and setup.


---

## 📋 Support Policy

This is a **self-serve template**, not a managed service.

- ✅ **Included:** Working workflow, comprehensive guide, analytics schema
- ❌ **Not included:** 1:1 setup calls, custom modifications, debugging your SMTP/Slack/Google auth

**Before seeking help:**
1. Re-read the relevant section of this guide
2. Check Troubleshooting table
3. Search your error in [n8n community forum](https://community.n8n.io/)

**Community resources:** n8n Discord, Supabase Discord, r/n8n

**Found a bug?** Email with specific error message, screenshot, and expected vs actual behavior.
---

## 📋 Changelog

### v2.1.0
- Separated churn tracking into dedicated `churn_events` table (previously mixed into `dunning_events`)
- Added deterministic A/B email variant system based on Stripe Customer ID
- Added `recovery_stats` and `churn_monthly_summary` analytics views
- Added email format validation at DB level and in workflow nodes
- Added `failed_integrations` error logging table
- Added Slack urgency emoji indicators per dunning stage (🟡 🟠 🔴 💀)
- Added global error workflow hook with setup instructions

---

### ⚠️ Production Reliability Note

This workflow relies on n8n's **Wait** nodes to schedule dunning emails at timed intervals (e.g., 4 hours, 24 hours, 72 hours). By default, n8n runs in `regular` execution mode, where in-progress executions — including pending Wait nodes — are stored **in memory only**.

This means that if your n8n instance restarts (server reboot, deployment, crash), **any in-flight dunning sequences will be lost** and those customers will never receive their follow-up emails.

**For high-volume or production use, you should run n8n in Queue Mode:**

```env
EXECUTIONS_MODE=queue
```

In queue mode, Wait node states are persisted to the database rather than held in memory. This ensures that dunning sequences **resume automatically** after a server restart, so no customer falls through the cracks.

> **How to enable:** Set the `EXECUTIONS_MODE=queue` environment variable in your n8n deployment configuration (e.g., `.env` file, Docker Compose, or hosting platform settings). See the [n8n Queue Mode documentation](https://docs.n8n.io/hosting/scaling/queue-mode/) for full setup instructions including the required Redis instance.