# EvalPulse

EvalPulse is a black-box LLM quality monitoring SaaS. Customers register an HTTPS endpoint, define a golden test suite, and receive scheduled eval results plus alerts when quality, refusal behavior, latency, or reliability degrades.

This product is eval-first monitoring, not tracing. Do not build SDKs, request tracing, prompt playgrounds, agent observability, or full APM features in the MVP.

## MVP Positioning

One-sentence pitch:

Know when your LLM gets worse before your users do.

Primary wedge:

- No SDK or instrumentation.
- Customer provides an endpoint URL, auth header, request template, response path, and test cases.
- EvalPulse runs scheduled checks and alerts on drift.

## Stack

- Web app: Next.js 14 App Router, TypeScript, Tailwind, shadcn/ui.
- Auth: Clerk.
- Database: Supabase Postgres with RLS.
- Billing: Stripe subscriptions.
- Worker: FastAPI, Python, uv.
- Scheduling: worker polls `scheduled_jobs` or due suites from Supabase; keep orchestration simple for MVP.
- Email: Resend.
- Slack alerts: incoming webhook URL per project or alert rule.

Use pnpm workspaces:

- `apps/web`
- `apps/worker`
- `packages/shared` only if shared TypeScript types become useful.

## Product Scope

Build only these v1 features:

- Project CRUD.
- Endpoint configuration:
  - OpenAI-compatible chat mode.
  - Generic JSON request/response mode.
  - Auth header storage.
  - Request template.
  - Response JSON path.
- Test suite CRUD.
- CSV import for test cases.
- Test case editor.
- Scheduled runs.
- Run history.
- Per-case result detail.
- Side-by-side output diff against a previous run.
- Dashboard charts for correctness, refusal accuracy, latency, and error rate.
- Email and Slack alerts.
- Stripe plan gating.

Explicitly out of scope:

- SDKs.
- Tracing.
- Token-level observability.
- Prompt playground.
- Multi-model comparison UI.
- Teams/RBAC.
- On-prem deployment.
- Enterprise SSO.

## Core Metrics

Every run should aggregate these four metrics:

- Correctness or groundedness score: mean judge score from 0 to 1.
- Refusal accuracy: correct refusal behavior divided by applicable cases.
- Latency: p50 and p95 in milliseconds.
- Error rate: failed endpoint calls divided by total cases.

Store aggregate metrics on `runs` so dashboard queries do not scan all result rows.

## Judge Contract

Use a cheap LLM-as-judge model for MVP. The judge must return strict JSON only:

```json
{
  "score": 0.0,
  "verdict": "pass",
  "rationale": "Short explanation grounded in the criteria.",
  "refusal_observed": false,
  "refusal_correct": true
}
```

Rules:

- `score` is a number from 0 to 1.
- `verdict` is one of `pass`, `partial`, `fail`.
- `rationale` must be stored and shown in the UI.
- `refusal_observed` indicates whether the model refused.
- `refusal_correct` is nullable when the case has no refusal expectation.

If judge parsing fails, store `judge_error` on the result. Do not convert judge failures into customer endpoint failures.

## Security Rules

- Never expose customer auth headers to the browser after initial submission.
- Web clients can read projects, suites, cases, runs, and results they own.
- Only the service-role worker can insert run and result rows.
- Prefer Supabase Vault or encrypted server-side storage for endpoint auth headers before accepting real customers.
- Do not log customer auth headers, request templates containing secrets, or full request headers.
- Treat raw endpoint outputs as customer data.

## Data Model

Main entities:

- `projects`
- `endpoints`
- `test_suites`
- `test_cases`
- `runs`
- `run_results`
- `alert_rules`
- `alert_events`

Auth model:

- Clerk user id maps to `auth.jwt()->>'sub'`.
- `projects.owner_id` stores the Clerk user id.
- RLS policies use helper function `current_user_id()`.

If the Supabase Clerk integration emits a different claim, adjust only `current_user_id()`.

## Worker Behavior

The worker should:

1. Poll for due active test suites.
2. Create a `runs` row with status `running`.
3. Execute each test case against the configured endpoint with timeout and retry limits.
4. Evaluate each response with the judge.
5. Insert one `run_results` row per case.
6. Aggregate metrics and update the `runs` row.
7. Evaluate alert rules.
8. Send Slack/email alerts.
9. Mark the suite's next run time.

Use conservative defaults:

- Endpoint timeout: 30 seconds.
- Endpoint retries: 1 retry for network errors and 5xx.
- Judge timeout: 30 seconds.
- Run concurrency: low by default, configurable later.

## UI Principles

- Make the dashboard operational, not marketing-heavy.
- First screen after login should show projects and current health.
- Run detail should prioritize the diff view and judge rationale.
- Use charts only where they clarify trend or drift.
- Keep configuration forms explicit and boring; mistakes here break monitoring.

## Milestones

### Week 1

- Scaffold monorepo.
- Configure Next.js, Clerk, Supabase, Tailwind, shadcn/ui.
- Apply initial migration.
- Build CRUD for projects, endpoints, test suites, and test cases.
- Build CSV import.

### Week 2

- Build FastAPI worker.
- Implement endpoint caller.
- Implement judge adapter and strict parsing.
- Add tests for judge parsing and refusal classification.
- Produce a scored run against a real endpoint.

### Week 3

- Build dashboard charts.
- Build run history and per-case result pages.
- Build side-by-side diff view.
- Implement alert rules and Slack/email delivery.
- Verify alert by intentionally degrading a test endpoint.

### Week 4

- Add Stripe checkout and plan gating.
- Add landing page.
- Deploy web and worker.
- Recruit three design partners.

