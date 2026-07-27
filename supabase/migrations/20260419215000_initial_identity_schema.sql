create extension if not exists pgcrypto;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = timezone('utc', now());
  return new;
end;
$$;

create table if not exists public.profiles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  email text unique,
  display_name text,
  avatar_url text,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

comment on table public.profiles is 'One profile row per authenticated Glasstunnel account.';

create or replace function public.handle_auth_user_upsert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  raw_email text;
  derived_name text;
begin
  raw_email := nullif(trim(new.email), '');
  derived_name := coalesce(
    nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''),
    nullif(trim(new.raw_user_meta_data ->> 'name'), ''),
    case
      when raw_email is not null then split_part(raw_email, '@', 1)
      else null
    end
  );

  insert into public.profiles (user_id, email, display_name, avatar_url)
  values (
    new.id,
    lower(raw_email),
    derived_name,
    nullif(trim(new.raw_user_meta_data ->> 'avatar_url'), '')
  )
  on conflict (user_id) do update
  set
    email = excluded.email,
    display_name = coalesce(excluded.display_name, public.profiles.display_name),
    avatar_url = coalesce(excluded.avatar_url, public.profiles.avatar_url),
    updated_at = timezone('utc', now());

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert or update on auth.users
for each row execute function public.handle_auth_user_upsert();

insert into public.profiles (user_id, email, display_name, avatar_url)
select
  u.id,
  lower(nullif(trim(u.email), '')),
  coalesce(
    nullif(trim(u.raw_user_meta_data ->> 'full_name'), ''),
    nullif(trim(u.raw_user_meta_data ->> 'name'), ''),
    case
      when nullif(trim(u.email), '') is not null then split_part(u.email, '@', 1)
      else null
    end
  ),
  nullif(trim(u.raw_user_meta_data ->> 'avatar_url'), '')
from auth.users u
on conflict (user_id) do update
set
  email = excluded.email,
  display_name = coalesce(excluded.display_name, public.profiles.display_name),
  avatar_url = coalesce(excluded.avatar_url, public.profiles.avatar_url),
  updated_at = timezone('utc', now());

create table if not exists public.devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  device_id text not null unique,
  public_key_b64 text not null unique,
  label text not null,
  kind text not null check (kind in ('host', 'phone', 'browser')),
  platform text,
  app_version text,
  last_seen_at timestamptz,
  revoked_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  constraint devices_device_id_format check (device_id ~ '^gt-[0-9a-f]{16}$')
);

comment on table public.devices is 'Registered Mac and phone/browser devices for a Glasstunnel account.';

create index if not exists devices_user_created_idx
  on public.devices (user_id, created_at desc);

create index if not exists devices_user_kind_active_idx
  on public.devices (user_id, kind, last_seen_at desc)
  where revoked_at is null;

create table if not exists public.device_pairings (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references public.profiles (user_id) on delete cascade,
  host_device_uuid uuid not null references public.devices (id) on delete cascade,
  phone_device_uuid uuid not null references public.devices (id) on delete cascade,
  metadata jsonb not null default '{}'::jsonb,
  paired_at timestamptz not null default timezone('utc', now()),
  revoked_at timestamptz,
  updated_at timestamptz not null default timezone('utc', now()),
  constraint device_pairings_distinct_devices check (host_device_uuid <> phone_device_uuid)
);

comment on table public.device_pairings is 'Active or historical pairings between one host device and one phone/browser device.';

create unique index if not exists device_pairings_active_unique_idx
  on public.device_pairings (host_device_uuid, phone_device_uuid)
  where revoked_at is null;

create index if not exists device_pairings_owner_recent_idx
  on public.device_pairings (owner_user_id, paired_at desc);

create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  device_uuid uuid not null references public.devices (id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  user_agent text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  last_seen_at timestamptz not null default timezone('utc', now()),
  revoked_at timestamptz
);

comment on table public.push_subscriptions is 'Web Push endpoints associated with phone/browser devices.';

create index if not exists push_subscriptions_device_active_idx
  on public.push_subscriptions (device_uuid, last_seen_at desc)
  where revoked_at is null;

create index if not exists push_subscriptions_user_active_idx
  on public.push_subscriptions (user_id, last_seen_at desc)
  where revoked_at is null;

create or replace function public.enforce_device_ownership()
returns trigger
language plpgsql
as $$
declare
  owner_id uuid;
begin
  select d.user_id into owner_id
  from public.devices d
  where d.id = new.device_uuid;

  if owner_id is null then
    raise exception 'push subscription device % not found', new.device_uuid;
  end if;

  if owner_id <> new.user_id then
    raise exception 'push subscription device % does not belong to user %', new.device_uuid, new.user_id;
  end if;

  return new;
end;
$$;

create or replace function public.enforce_pairing_ownership()
returns trigger
language plpgsql
as $$
declare
  host_user_id uuid;
  phone_user_id uuid;
  host_kind text;
  phone_kind text;
begin
  select d.user_id, d.kind
  into host_user_id, host_kind
  from public.devices d
  where d.id = new.host_device_uuid;

  select d.user_id, d.kind
  into phone_user_id, phone_kind
  from public.devices d
  where d.id = new.phone_device_uuid;

  if host_user_id is null or phone_user_id is null then
    raise exception 'pairing devices must exist';
  end if;

  if host_user_id <> new.owner_user_id or phone_user_id <> new.owner_user_id then
    raise exception 'paired devices must belong to owner_user_id %', new.owner_user_id;
  end if;

  if host_kind <> 'host' then
    raise exception 'host_device_uuid must reference a host device';
  end if;

  if phone_kind not in ('phone', 'browser') then
    raise exception 'phone_device_uuid must reference a phone/browser device';
  end if;

  return new;
end;
$$;

drop trigger if exists set_profiles_updated_at on public.profiles;
create trigger set_profiles_updated_at
before update on public.profiles
for each row execute function public.set_updated_at();

drop trigger if exists set_devices_updated_at on public.devices;
create trigger set_devices_updated_at
before update on public.devices
for each row execute function public.set_updated_at();

drop trigger if exists set_device_pairings_updated_at on public.device_pairings;
create trigger set_device_pairings_updated_at
before update on public.device_pairings
for each row execute function public.set_updated_at();

drop trigger if exists set_push_subscriptions_updated_at on public.push_subscriptions;
create trigger set_push_subscriptions_updated_at
before update on public.push_subscriptions
for each row execute function public.set_updated_at();

drop trigger if exists enforce_push_subscription_ownership on public.push_subscriptions;
create trigger enforce_push_subscription_ownership
before insert or update on public.push_subscriptions
for each row execute function public.enforce_device_ownership();

drop trigger if exists enforce_device_pairing_ownership on public.device_pairings;
create trigger enforce_device_pairing_ownership
before insert or update on public.device_pairings
for each row execute function public.enforce_pairing_ownership();

alter table public.profiles enable row level security;
alter table public.devices enable row level security;
alter table public.device_pairings enable row level security;
alter table public.push_subscriptions enable row level security;

create policy "profiles_select_own"
on public.profiles
for select
to authenticated
using (user_id = auth.uid());

create policy "profiles_update_own"
on public.profiles
for update
to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

create policy "devices_select_own"
on public.devices
for select
to authenticated
using (user_id = auth.uid());

create policy "devices_insert_own"
on public.devices
for insert
to authenticated
with check (user_id = auth.uid());

create policy "devices_update_own"
on public.devices
for update
to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

create policy "devices_delete_own"
on public.devices
for delete
to authenticated
using (user_id = auth.uid());

create policy "pairings_select_own"
on public.device_pairings
for select
to authenticated
using (owner_user_id = auth.uid());

create policy "pairings_insert_own"
on public.device_pairings
for insert
to authenticated
with check (owner_user_id = auth.uid());

create policy "pairings_update_own"
on public.device_pairings
for update
to authenticated
using (owner_user_id = auth.uid())
with check (owner_user_id = auth.uid());

create policy "pairings_delete_own"
on public.device_pairings
for delete
to authenticated
using (owner_user_id = auth.uid());

create policy "push_subscriptions_select_own"
on public.push_subscriptions
for select
to authenticated
using (user_id = auth.uid());

create policy "push_subscriptions_insert_own"
on public.push_subscriptions
for insert
to authenticated
with check (user_id = auth.uid());

create policy "push_subscriptions_update_own"
on public.push_subscriptions
for update
to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

create policy "push_subscriptions_delete_own"
on public.push_subscriptions
for delete
to authenticated
using (user_id = auth.uid());
