create table if not exists public.host_link_codes (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  host_device_id text not null,
  host_public_key_b64 text not null,
  host_label text not null,
  host_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default timezone('utc', now()),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  claimed_user_id uuid references public.profiles (user_id) on delete set null,
  constraint host_link_codes_code_format check (code ~ '^[A-HJ-NP-Z2-9]{6}$'),
  constraint host_link_codes_expiry check (expires_at > created_at)
);

comment on table public.host_link_codes is 'Short-lived account-linking codes that let a signed-in user claim a host device.';

create index if not exists host_link_codes_host_recent_idx
  on public.host_link_codes (host_device_id, created_at desc);

create index if not exists host_link_codes_active_lookup_idx
  on public.host_link_codes (code, expires_at desc)
  where consumed_at is null;

create table if not exists public.device_approval_requests (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references public.profiles (user_id) on delete cascade,
  host_device_uuid uuid not null references public.devices (id) on delete cascade,
  requester_device_uuid uuid not null references public.devices (id) on delete cascade,
  requester_device_id text not null,
  requester_public_key_b64 text not null,
  requester_label text not null,
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'rejected', 'expired', 'cancelled')),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  responded_at timestamptz,
  constraint device_approval_requests_distinct_devices
    check (host_device_uuid <> requester_device_uuid)
);

comment on table public.device_approval_requests is 'One-time approval requests that let a signed-in browser/phone become trusted by a specific host.';

create unique index if not exists device_approval_requests_pending_unique_idx
  on public.device_approval_requests (host_device_uuid, requester_device_uuid)
  where status = 'pending';

create index if not exists device_approval_requests_owner_recent_idx
  on public.device_approval_requests (owner_user_id, created_at desc);

create index if not exists device_approval_requests_host_recent_idx
  on public.device_approval_requests (host_device_uuid, created_at desc);

drop trigger if exists set_device_approval_requests_updated_at on public.device_approval_requests;
create trigger set_device_approval_requests_updated_at
before update on public.device_approval_requests
for each row execute function public.set_updated_at();

alter table public.host_link_codes enable row level security;
alter table public.device_approval_requests enable row level security;
