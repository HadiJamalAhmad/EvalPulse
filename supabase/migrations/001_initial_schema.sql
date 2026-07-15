create extension if not exists pgcrypto;

create or replace function public.current_user_id()
returns text
language sql
stable
as $$
  select auth.jwt()->>'sub'
$$;

create type public.endpoint_mode as enum ('openai_chat', 'generic_json');
create type public.run_status as enum ('queued', 'running', 'succeeded', 'failed', 'canceled');
create type public.result_status as enum ('succeeded', 'endpoint_error', 'judge_error');
create type public.alert_channel as enum ('email', 'slack');
create type public.alert_metric as enum ('correctness', 'refusal_accuracy', 'latency_p95_ms', 'error_rate');
create type public.alert_operator as enum ('below', 'above', 'drops_by_percent');

create table public.projects (
  id uuid primary key default gen_random_uuid(),
  owner_id text not null,
  name text not null,
  stripe_customer_id text,
  stripe_subscription_id text,
  plan text not null default 'free',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.endpoints (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  name text not null,
  mode public.endpoint_mode not null default 'generic_json',
  url text not null,
  auth_header_name text,
  auth_header_secret_ref text,
  request_template jsonb not null default '{}'::jsonb,
  response_path text not null default 'choices.0.message.content',
  timeout_ms integer not null default 30000,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint endpoints_timeout_positive check (timeout_ms > 0 and timeout_ms <= 120000)
);

create table public.test_suites (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  endpoint_id uuid not null references public.endpoints(id) on delete cascade,
  name text not null,
  schedule_cron text not null default '0 8 * * *',
  timezone text not null default 'UTC',
  is_active boolean not null default true,
  next_run_at timestamptz,
  baseline_window_days integer not null default 7,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint test_suites_baseline_window_positive check (baseline_window_days > 0 and baseline_window_days <= 90)
);

create table public.test_cases (
  id uuid primary key default gen_random_uuid(),
  suite_id uuid not null references public.test_suites(id) on delete cascade,
  name text not null,
  prompt text not null,
  evaluation_criteria text not null,
  expected_facts text[] not null default array[]::text[],
  forbidden_content text[] not null default array[]::text[],
  should_refuse boolean,
  metadata jsonb not null default '{}'::jsonb,
  position integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.runs (
  id uuid primary key default gen_random_uuid(),
  suite_id uuid not null references public.test_suites(id) on delete cascade,
  endpoint_id uuid not null references public.endpoints(id) on delete restrict,
  status public.run_status not null default 'queued',
  started_at timestamptz,
  finished_at timestamptz,
  total_cases integer not null default 0,
  succeeded_cases integer not null default 0,
  failed_cases integer not null default 0,
  correctness_score numeric(5,4),
  refusal_accuracy numeric(5,4),
  latency_p50_ms integer,
  latency_p95_ms integer,
  error_rate numeric(5,4),
  error text,
  created_at timestamptz not null default now()
);

create table public.run_results (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references public.runs(id) on delete cascade,
  test_case_id uuid not null references public.test_cases(id) on delete cascade,
  status public.result_status not null default 'succeeded',
  output text,
  previous_output text,
  endpoint_status_code integer,
  latency_ms integer,
  judge_score numeric(5,4),
  judge_verdict text,
  judge_rationale text,
  refusal_observed boolean,
  refusal_correct boolean,
  error text,
  judge_error text,
  created_at timestamptz not null default now(),
  constraint run_results_score_range check (judge_score is null or (judge_score >= 0 and judge_score <= 1))
);

create table public.alert_rules (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  suite_id uuid references public.test_suites(id) on delete cascade,
  name text not null,
  metric public.alert_metric not null,
  operator public.alert_operator not null,
  threshold numeric(10,4) not null,
  channel public.alert_channel not null,
  destination text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.alert_events (
  id uuid primary key default gen_random_uuid(),
  alert_rule_id uuid not null references public.alert_rules(id) on delete cascade,
  run_id uuid not null references public.runs(id) on delete cascade,
  metric public.alert_metric not null,
  observed_value numeric(10,4),
  baseline_value numeric(10,4),
  message text not null,
  delivered_at timestamptz,
  delivery_error text,
  created_at timestamptz not null default now()
);

create index projects_owner_id_idx on public.projects(owner_id);
create index endpoints_project_id_idx on public.endpoints(project_id);
create index test_suites_project_id_idx on public.test_suites(project_id);
create index test_suites_due_idx on public.test_suites(next_run_at)
  where is_active = true and next_run_at is not null;
create index test_cases_suite_id_position_idx on public.test_cases(suite_id, position);
create index runs_suite_id_created_at_idx on public.runs(suite_id, created_at desc);
create index run_results_run_id_idx on public.run_results(run_id);
create index alert_rules_project_id_idx on public.alert_rules(project_id);
create index alert_events_rule_id_created_at_idx on public.alert_events(alert_rule_id, created_at desc);

alter table public.projects enable row level security;
alter table public.endpoints enable row level security;
alter table public.test_suites enable row level security;
alter table public.test_cases enable row level security;
alter table public.runs enable row level security;
alter table public.run_results enable row level security;
alter table public.alert_rules enable row level security;
alter table public.alert_events enable row level security;

create policy "owners can manage projects"
on public.projects
for all
using (owner_id = public.current_user_id())
with check (owner_id = public.current_user_id());

create policy "owners can manage endpoints"
on public.endpoints
for all
using (
  exists (
    select 1 from public.projects p
    where p.id = endpoints.project_id
      and p.owner_id = public.current_user_id()
  )
)
with check (
  exists (
    select 1 from public.projects p
    where p.id = endpoints.project_id
      and p.owner_id = public.current_user_id()
  )
);

create policy "owners can manage test suites"
on public.test_suites
for all
using (
  exists (
    select 1 from public.projects p
    where p.id = test_suites.project_id
      and p.owner_id = public.current_user_id()
  )
)
with check (
  exists (
    select 1 from public.projects p
    where p.id = test_suites.project_id
      and p.owner_id = public.current_user_id()
  )
);

create policy "owners can manage test cases"
on public.test_cases
for all
using (
  exists (
    select 1
    from public.test_suites s
    join public.projects p on p.id = s.project_id
    where s.id = test_cases.suite_id
      and p.owner_id = public.current_user_id()
  )
)
with check (
  exists (
    select 1
    from public.test_suites s
    join public.projects p on p.id = s.project_id
    where s.id = test_cases.suite_id
      and p.owner_id = public.current_user_id()
  )
);

create policy "owners can read runs"
on public.runs
for select
using (
  exists (
    select 1
    from public.test_suites s
    join public.projects p on p.id = s.project_id
    where s.id = runs.suite_id
      and p.owner_id = public.current_user_id()
  )
);

create policy "owners can read run results"
on public.run_results
for select
using (
  exists (
    select 1
    from public.runs r
    join public.test_suites s on s.id = r.suite_id
    join public.projects p on p.id = s.project_id
    where r.id = run_results.run_id
      and p.owner_id = public.current_user_id()
  )
);

create policy "owners can manage alert rules"
on public.alert_rules
for all
using (
  exists (
    select 1 from public.projects p
    where p.id = alert_rules.project_id
      and p.owner_id = public.current_user_id()
  )
)
with check (
  exists (
    select 1 from public.projects p
    where p.id = alert_rules.project_id
      and p.owner_id = public.current_user_id()
  )
);

create policy "owners can read alert events"
on public.alert_events
for select
using (
  exists (
    select 1
    from public.alert_rules ar
    join public.projects p on p.id = ar.project_id
    where ar.id = alert_events.alert_rule_id
      and p.owner_id = public.current_user_id()
  )
);

