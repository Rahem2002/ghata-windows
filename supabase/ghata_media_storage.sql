-- Ghata private media storage
-- Profile photos + Customer photos
-- Files are private and scoped to the signed-in user's UID.

alter table public.profiles
  add column if not exists avatar_path text;

alter table public.customers
  add column if not exists photo_path text;

insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'ghata-media',
  'ghata-media',
  false,
  5242880,
  array[
    'image/jpeg',
    'image/png',
    'image/webp'
  ]
)
on conflict (id) do update
set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Ghata media select own" on storage.objects;
create policy "Ghata media select own"
on storage.objects
for select
to authenticated
using (
  bucket_id = 'ghata-media'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists "Ghata media insert own" on storage.objects;
create policy "Ghata media insert own"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'ghata-media'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists "Ghata media update own" on storage.objects;
create policy "Ghata media update own"
on storage.objects
for update
to authenticated
using (
  bucket_id = 'ghata-media'
  and (storage.foldername(name))[1] = auth.uid()::text
)
with check (
  bucket_id = 'ghata-media'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists "Ghata media delete own" on storage.objects;
create policy "Ghata media delete own"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'ghata-media'
  and (storage.foldername(name))[1] = auth.uid()::text
);
