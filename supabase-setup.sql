-- ============================================================
--  Летняя тетрадь — настройка базы
--  Вставить целиком в Supabase → SQL Editor → New query → Run
--  Запускается один раз. Повторный запуск безопасен.
-- ============================================================

-- ---------- 1. Таблицы ----------

create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  name       text        not null default 'Ученик',
  color      smallint    not null default 0,
  code       text        not null unique,
  share      boolean     not null default true,
  updated_at timestamptz not null default now()
);

create table if not exists public.progress (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  data       jsonb       not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

-- кого я добавил себе по коду (односторонне)
create table if not exists public.friends (
  user_id    uuid not null references auth.users(id) on delete cascade,
  friend_id  uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, friend_id)
);

-- ---------- 2. Код для обмена ----------
-- Шесть символов без похожих друг на друга (нет 0/O и 1/I).

create or replace function public.gen_code()
returns text
language plpgsql
as $$
declare
  alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  res text;
  free boolean;
begin
  loop
    res := '';
    for i in 1..6 loop
      res := res || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    select not exists (select 1 from public.profiles where code = res) into free;
    exit when free;
  end loop;
  return res;
end;
$$;

-- ---------- 3. Заводим профиль при регистрации ----------

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, name, code)
  values (new.id,
          coalesce(nullif(trim(new.raw_user_meta_data->>'name'), ''), 'Ученик'),
          public.gen_code())
  on conflict (id) do nothing;

  insert into public.progress (user_id) values (new.id)
  on conflict (user_id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- 4. Права доступа ----------
-- Каждый видит и меняет только своё. Данные друзей отдаются
-- исключительно через функции ниже, которые сами проверяют,
-- кто спрашивает.

alter table public.profiles enable row level security;
alter table public.progress enable row level security;
alter table public.friends  enable row level security;

drop policy if exists "профиль: свой виден"    on public.profiles;
drop policy if exists "профиль: свой меняется" on public.profiles;
create policy "профиль: свой виден" on public.profiles
  for select using (auth.uid() = id);
create policy "профиль: свой меняется" on public.profiles
  for update using (auth.uid() = id) with check (auth.uid() = id);

drop policy if exists "прогресс: свой виден"     on public.progress;
drop policy if exists "прогресс: свой меняется"  on public.progress;
drop policy if exists "прогресс: свой создаётся" on public.progress;
create policy "прогресс: свой виден" on public.progress
  for select using (auth.uid() = user_id);
create policy "прогресс: свой меняется" on public.progress
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "прогресс: свой создаётся" on public.progress
  for insert with check (auth.uid() = user_id);

drop policy if exists "друзья: свои видны"    on public.friends;
drop policy if exists "друзья: своих добавляю" on public.friends;
drop policy if exists "друзья: своих удаляю"   on public.friends;
create policy "друзья: свои видны" on public.friends
  for select using (auth.uid() = user_id);
create policy "друзья: своих добавляю" on public.friends
  for insert with check (auth.uid() = user_id);
create policy "друзья: своих удаляю" on public.friends
  for delete using (auth.uid() = user_id);

-- ---------- 5. Добавить друга по коду ----------

create or replace function public.add_friend(p_code text)
returns table (friend_id uuid, friend_name text, friend_color smallint)
language plpgsql
security definer set search_path = public
as $$
declare f record;
begin
  select p.id, p.name, p.color into f
  from public.profiles p
  where p.code = upper(trim(p_code)) and p.share = true;

  if not found then
    raise exception 'Код не найден';
  end if;
  if f.id = auth.uid() then
    raise exception 'Это твой собственный код';
  end if;

  insert into public.friends (user_id, friend_id)
  values (auth.uid(), f.id)
  on conflict do nothing;

  return query select f.id, f.name, f.color;
end;
$$;

-- ---------- 6. Прогресс всех моих друзей ----------

create or replace function public.friends_progress()
returns table (
  friend_id    uuid,
  friend_name  text,
  friend_color smallint,
  data         jsonb,
  updated_at   timestamptz
)
language sql
security definer set search_path = public
as $$
  select p.id, p.name, p.color, g.data, g.updated_at
  from public.friends f
  join public.profiles p on p.id = f.friend_id
  join public.progress g on g.user_id = f.friend_id
  where f.user_id = auth.uid() and p.share = true;
$$;

-- ---------- 7. Кто может вызывать функции ----------

revoke all on function public.add_friend(text)   from public, anon;
revoke all on function public.friends_progress() from public, anon;
grant execute on function public.add_friend(text)   to authenticated;
grant execute on function public.friends_progress() to authenticated;

-- ---------- Готово ----------
-- Проверить: Table Editor → должны появиться profiles, progress, friends.
