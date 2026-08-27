-- ============================================================
--  Доправка №1: выдать права ролям
--  Вставить в Supabase → SQL Editor → New query → Run
--
--  Зачем: RLS решает, КАКИЕ СТРОКИ видит человек, но поверх неё
--  работает обычный GRANT — есть ли у роли доступ к таблице вообще.
--  Supabase не выдал его автоматически, поэтому даже владелец
--  своих строк получал "permission denied for table profiles".
--
--  Анонимным (роль anon) не даём НИЧЕГО: до входа читать нечего.
-- ============================================================

grant usage on schema public to anon, authenticated;

grant select, update          on public.profiles to authenticated;
grant select, insert, update  on public.progress to authenticated;
grant select, insert, delete  on public.friends  to authenticated;

-- На будущее: чтобы новые таблицы получали права сами
alter default privileges in schema public
  grant select, insert, update, delete on tables to authenticated;

-- ---------- Проверка ----------
-- Должно вернуть три строки с ролью authenticated.
select table_name, privilege_type
from information_schema.role_table_grants
where grantee = 'authenticated'
  and table_schema = 'public'
  and table_name in ('profiles','progress','friends')
order by table_name, privilege_type;
