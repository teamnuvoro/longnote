-- Private bucket `uploads` for audio waiting to be transcribed.
-- Path: <user_id>/<client_note_id>.m4a. A user may write/read/delete only
-- inside their own folder. Objects are deleted by the server as soon as the
-- transcription ends, and in any case after 24 h (cleanup function).
--
-- Size cap 500 MB per file. The project-wide upload limit (Pro plan) was
-- raised to the same value via the Management API (storage config
-- fileSizeLimit). The binding length limit is Soniox's 300 min per file,
-- not this cap (300 min at 32 kbps is about 72 MB).

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('uploads', 'uploads', false, 524288000,
        array['audio/mp4', 'audio/m4a', 'audio/x-m4a', 'audio/aac'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

create policy uploads_insert_own on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'uploads'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and name ~ '^[0-9a-f-]{36}/[A-Za-z0-9_-]{1,64}\.m4a$'
  );

-- select + update are needed for upsert (x-upsert: true) and TUS resume.
create policy uploads_select_own on storage.objects
  for select to authenticated
  using (bucket_id = 'uploads' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy uploads_update_own on storage.objects
  for update to authenticated
  using (bucket_id = 'uploads' and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (
    bucket_id = 'uploads'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and name ~ '^[0-9a-f-]{36}/[A-Za-z0-9_-]{1,64}\.m4a$'
  );

create policy uploads_delete_own on storage.objects
  for delete to authenticated
  using (bucket_id = 'uploads' and (storage.foldername(name))[1] = (select auth.uid())::text);
