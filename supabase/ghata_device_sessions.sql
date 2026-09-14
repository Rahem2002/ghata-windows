create table if not exists public.user_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id text not null,
  device_name text not null default 'Unknown device',
  platform text not null default 'unknown',
  last_seen timestamptz not null default now(),
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint user_devices_user_device_unique
    unique (user_id, device_id)
);

create index if not exists user_devices_user_id_idx
  on public.user_devices(user_id);

create index if not exists user_devices_last_seen_idx
  on public.user_devices(user_id, last_seen desc);

alter table public.user_devices enable row level security;

drop policy if exists "Users can read own devices"
  on public.user_devices;

create policy "Users can read own devices"
on public.user_devices
for select
to authenticated
using (auth.uid() = user_id);

drop policy if exists "Users can add own devices"
  on public.user_devices;

create policy "Users can add own devices"
on public.user_devices
for insert
to authenticated
with check (auth.uid() = user_id);

drop policy if exists "Users can update own devices"
  on public.user_devices;

create policy "Users can update own devices"
on public.user_devices
for update
to authenticated
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

drop policy if exists "Users can delete own devices"
  on public.user_devices;

create policy "Users can delete own devices"
on public.user_devices
for delete
to authenticated
using (auth.uid() = user_id);

do $$
declare
  t text;
begin
  foreach t in array array[
    'customers',
    'transactions',
    'exchanges',
    'exchange_entries',
    'profiles',
    'user_devices'
  ]
  loop
    if not exists (
      select 1
      from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = t
    ) then
      execute format(
        'alter publication supabase_realtime add table public.%I',
        t
      );
    end if;
  end loop;
end
$$;

select
  schemaname,
  tablename
from pg_publication_tables
where pubname = 'supabase_realtime'
  and schemaname = 'public'
  and tablename in (
    'customers',
    'transactions',
    'exchanges',
    'exchange_entries',
    'profiles',
    'user_devices'
  )
order by tablename;
