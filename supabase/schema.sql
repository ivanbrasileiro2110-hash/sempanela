-- =====================================================================
-- SemPanela · banco de dados (fase 2: contas reais e peladas compartilhadas)
-- Rodar inteiro no SQL Editor do Supabase. Pode rodar de novo sem quebrar.
-- =====================================================================

-- ---------- utilitários ----------
create or replace function public.is_creator() returns boolean
language sql stable as $$
  select coalesce(lower(auth.jwt()->>'email'),'') = 'ivanbrasileiro2110@gmail.com'
$$;

create or replace function public.try_uuid(t text) returns uuid
language plpgsql immutable as $$
begin return t::uuid; exception when others then return null; end $$;

-- controle de versão: cada gravação manda version = anterior + 1.
-- Se outra pessoa gravou antes, dá conflito e o app mescla as mudanças.
create or replace function public.sp_version() returns trigger
language plpgsql as $$
begin
  if tg_op = 'UPDATE' and new.version is distinct from old.version + 1 then
    raise exception 'version_conflict' using errcode = '40001';
  end if;
  new.updated_at := now();
  return new;
end $$;

-- ---------- configuração do app (só o criador edita) ----------
create table if not exists public.app_config (
  id int primary key default 1 check (id = 1),
  doc jsonb not null default '{}'::jsonb,
  version int not null default 1,
  updated_at timestamptz not null default now()
);
insert into public.app_config (id, doc) values (1, '{
  "proEmails": ["libaniosamuel519@gmail.com", "gusbroliveira@gmail.com"],
  "price": "19,90", "freePlayers": 20, "freePeladas": 1, "pixFee": "1,49", "campPrice": "9,90"
}'::jsonb) on conflict (id) do nothing;

-- ---------- perfis ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  plan text not null default 'free' check (plan in ('free','pro')),
  doc jsonb not null default '{}'::jsonb,
  version int not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------- peladas ----------
create sequence if not exists public.pelada_code_seq start 1;
create table if not exists public.peladas (
  id text primary key,
  code text unique,
  owner uuid not null references auth.users(id) on delete cascade,
  doc jsonb not null,
  version int not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.pelada_members (
  pelada_id text not null references public.peladas(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  primary key (pelada_id, user_id)
);
create index if not exists pelada_members_user_idx on public.pelada_members(user_id);

-- ---------- campeonatos ----------
create table if not exists public.camps (
  id text primary key,
  owner uuid not null references auth.users(id) on delete cascade,
  pelada_code text,
  uids uuid[] not null default '{}',
  doc jsonb not null,
  version int not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists camps_pelada_idx on public.camps(pelada_code);

-- ---------- quadras ----------
create table if not exists public.quadras (
  id text primary key,
  owner uuid not null references auth.users(id) on delete cascade,
  doc jsonb not null,
  version int not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------- imagens (fotos, cartas, uniformes) ----------
create table if not exists public.images (
  key text primary key,
  owner uuid not null default auth.uid() references auth.users(id) on delete cascade,
  data text not null,
  updated_at timestamptz not null default now()
);

-- ---------- funções de acesso ----------
create or replace function public.is_member(pid text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from pelada_members where pelada_id = pid and user_id = auth.uid())
$$;

create or replace function public.shares_pelada(other uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from pelada_members a join pelada_members b on a.pelada_id = b.pelada_id
    where a.user_id = auth.uid() and b.user_id = other)
$$;

create or replace function public.camp_visible(c public.camps) returns boolean
language sql stable security definer set search_path = public as $$
  select c.owner = auth.uid()
      or auth.uid() = any(c.uids)
      or is_creator()
      or (c.pelada_code is not null and exists (
            select 1 from peladas p join pelada_members m on m.pelada_id = p.id
            where p.code = c.pelada_code and m.user_id = auth.uid()))
$$;

-- ---------- gatilhos ----------
-- novo usuário → cria o perfil
create or replace function public.sp_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare pro text[];
begin
  select array(select lower(jsonb_array_elements_text(doc->'proEmails'))) into pro from app_config where id = 1;
  insert into profiles (id, email, plan, doc) values (
    new.id, lower(new.email),
    case when lower(new.email) = 'ivanbrasileiro2110@gmail.com' or lower(new.email) = any(coalesce(pro, '{}')) then 'pro' else 'free' end,
    jsonb_build_object(
      'id', new.id::text, 'email', lower(new.email),
      'name', coalesce(nullif(new.raw_user_meta_data->>'name', ''), split_part(new.email, '@', 1)),
      'pos', 'AUTO', 'photo', null, 'roles', '[]'::jsonb,
      'createdAt', (extract(epoch from now()) * 1000)::bigint))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.sp_new_user();

-- perfil: e-mail e plano não são editáveis pelo próprio usuário
create or replace function public.sp_profiles_before() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then
    new.id := old.id; new.email := old.email;
    if new.plan is distinct from old.plan and not is_creator() then new.plan := old.plan; end if;
  end if;
  new.doc := new.doc || jsonb_build_object('id', new.id::text, 'email', new.email, 'plan', new.plan);
  return new;
end $$;

-- plano mudou → atualiza o plano das peladas dele
create or replace function public.sp_profiles_after() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.plan is distinct from old.plan then
    update peladas set version = version + 1 where owner = new.id;
  end if;
  return null;
end $$;

-- pelada: dono, código e plano são definidos pelo servidor
create or replace function public.sp_peladas_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare p text; nowner uuid;
begin
  if tg_op = 'INSERT' then
    new.owner := coalesce(auth.uid(), new.owner);
    if new.code is null or new.code = '' then
      new.code := 'SP' || lpad(nextval('pelada_code_seq')::text, 4, '0');
    end if;
  else
    new.code := old.code;
    nowner := try_uuid(new.doc->>'ownerUid');
    if nowner is not null and nowner is distinct from old.owner and (
         auth.uid() = old.owner or is_creator()
         or (nowner = auth.uid() and jsonb_typeof(old.doc->'state'->'transfer') = 'object')) then
      new.owner := nowner;
    else
      new.owner := old.owner;
    end if;
  end if;
  select plan into p from profiles where id = new.owner;
  new.doc := jsonb_set(jsonb_set(new.doc, '{code}', to_jsonb(new.code)), '{ownerUid}', to_jsonb(new.owner::text));
  if jsonb_typeof(new.doc->'state'->'pelada') = 'object' then
    new.doc := jsonb_set(new.doc, '{state,pelada,plan}', to_jsonb(coalesce(p, 'free')));
  end if;
  return new;
end $$;

-- pelada: lista de membros = dono + peladeiros com conta
create or replace function public.sp_peladas_members() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from pelada_members m
   where m.pelada_id = new.id and m.user_id <> new.owner
     and m.user_id not in (
       select try_uuid(x->>'uid') from jsonb_array_elements(coalesce(new.doc->'state'->'players', '[]')) x
        where try_uuid(x->>'uid') is not null);
  insert into pelada_members (pelada_id, user_id)
    select new.id, s.u from (
      select new.owner as u
      union select try_uuid(x->>'uid') from jsonb_array_elements(coalesce(new.doc->'state'->'players', '[]')) x
    ) s join auth.users au on au.id = s.u
  on conflict do nothing;
  return null;
end $$;

-- campeonato: dono fixo, pelada e participantes extraídos do documento
create or replace function public.sp_camps_before() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then new.owner := coalesce(auth.uid(), new.owner); else new.owner := old.owner; end if;
  new.pelada_code := nullif(new.doc->>'pel', '');
  new.uids := coalesce((select array_agg(distinct u) from (
      select try_uuid(v #>> '{}') u from jsonb_path_query(new.doc, 'lax $.**.uid') v) s where u is not null), '{}');
  new.doc := jsonb_set(new.doc, '{ownerUid}', to_jsonb(new.owner::text));
  return new;
end $$;

-- quadra: dono fixo
create or replace function public.sp_quadras_before() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then new.owner := coalesce(auth.uid(), new.owner); else new.owner := old.owner; end if;
  new.doc := jsonb_set(new.doc, '{ownerUid}', to_jsonb(new.owner::text));
  return new;
end $$;

-- configuração: e-mails Pro novos viram Pro na hora
create or replace function public.sp_config_after() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update profiles set plan = 'pro', version = version + 1
   where plan <> 'pro' and email in (select lower(jsonb_array_elements_text(coalesce(new.doc->'proEmails', '[]'))));
  return null;
end $$;

create or replace function public.sp_images_before() returns trigger
language plpgsql as $$
begin new.updated_at := now(); if tg_op = 'UPDATE' then new.owner := old.owner; end if; return new; end $$;

do $$
declare t text;
begin
  foreach t in array array['app_config','profiles','peladas','camps','quadras'] loop
    execute format('drop trigger if exists sp_00_version on public.%I', t);
    execute format('create trigger sp_00_version before update on public.%I for each row execute function public.sp_version()', t);
  end loop;
end $$;

drop trigger if exists sp_10_profiles on public.profiles;
create trigger sp_10_profiles before insert or update on public.profiles for each row execute function public.sp_profiles_before();
drop trigger if exists sp_20_profiles_after on public.profiles;
create trigger sp_20_profiles_after after update on public.profiles for each row execute function public.sp_profiles_after();
drop trigger if exists sp_10_peladas on public.peladas;
create trigger sp_10_peladas before insert or update on public.peladas for each row execute function public.sp_peladas_before();
drop trigger if exists sp_20_peladas_members on public.peladas;
create trigger sp_20_peladas_members after insert or update on public.peladas for each row execute function public.sp_peladas_members();
drop trigger if exists sp_10_camps on public.camps;
create trigger sp_10_camps before insert or update on public.camps for each row execute function public.sp_camps_before();
drop trigger if exists sp_10_quadras on public.quadras;
create trigger sp_10_quadras before insert or update on public.quadras for each row execute function public.sp_quadras_before();
drop trigger if exists sp_20_config_after on public.app_config;
create trigger sp_20_config_after after update on public.app_config for each row execute function public.sp_config_after();
drop trigger if exists sp_10_images on public.images;
create trigger sp_10_images before insert or update on public.images for each row execute function public.sp_images_before();

-- ---------- funções chamadas pelo app ----------
-- prévia do convite (sem precisar ser membro)
create or replace function public.find_pelada(p_code text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', p.id, 'code', p.code, 'ownerUid', p.owner::text,
    'ownerName', coalesce(pr.doc->>'nick', pr.doc->>'name', ''),
    'state', jsonb_build_object(
      'pelada', jsonb_build_object(
        'name', p.doc->'state'->'pelada'->'name', 'plan', p.doc->'state'->'pelada'->'plan',
        'weekday', p.doc->'state'->'pelada'->'weekday', 'time', p.doc->'state'->'pelada'->'time',
        'base', p.doc->'state'->'pelada'->'base'),
      'players', (select coalesce(jsonb_agg(jsonb_build_object('uid', x->'uid')), '[]'::jsonb)
                    from jsonb_array_elements(coalesce(p.doc->'state'->'players', '[]')) x)))
  from peladas p left join profiles pr on pr.id = p.owner
  where p.code = upper(trim(p_code)) and auth.uid() is not null
$$;

-- entrar na pelada pelo código
create or replace function public.join_pelada(p_code text, p_player jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r peladas; lim int;
begin
  if auth.uid() is null then raise exception 'auth_required'; end if;
  select * into r from peladas where code = upper(trim(p_code)) for update;
  if not found then return null; end if;
  if not exists (select 1 from jsonb_array_elements(coalesce(r.doc->'state'->'players', '[]')) x
                  where x->>'uid' = auth.uid()::text) then
    select coalesce((doc->>'freePlayers')::int, 20) into lim from app_config where id = 1;
    if coalesce(r.doc->'state'->'pelada'->>'plan', 'free') <> 'pro'
       and jsonb_array_length(coalesce(r.doc->'state'->'players', '[]')) >= coalesce(lim, 20) then
      raise exception 'free_limit';
    end if;
    update peladas set version = version + 1,
      doc = jsonb_set(doc, '{state,players}',
              coalesce(doc->'state'->'players', '[]') || jsonb_build_array(p_player || jsonb_build_object('uid', auth.uid()::text)))
     where id = r.id;
  end if;
  insert into pelada_members (pelada_id, user_id) values (r.id, auth.uid()) on conflict do nothing;
  return (select to_jsonb(p) from peladas p where p.id = r.id);
end $$;

-- excluir a própria conta (apaga perfil, peladas em que é dono, fotos)
create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'auth_required'; end if;
  delete from auth.users where id = auth.uid();
end $$;

-- ---------- segurança (RLS) ----------
alter table public.app_config enable row level security;
alter table public.profiles enable row level security;
alter table public.peladas enable row level security;
alter table public.pelada_members enable row level security;
alter table public.camps enable row level security;
alter table public.quadras enable row level security;
alter table public.images enable row level security;

drop policy if exists cfg_read on public.app_config;
create policy cfg_read on public.app_config for select to authenticated using (true);
drop policy if exists cfg_write on public.app_config;
create policy cfg_write on public.app_config for update to authenticated using (is_creator()) with check (is_creator());

drop policy if exists prof_read on public.profiles;
create policy prof_read on public.profiles for select to authenticated
  using (id = auth.uid() or is_creator() or shares_pelada(id));
drop policy if exists prof_insert on public.profiles;
create policy prof_insert on public.profiles for insert to authenticated with check (id = auth.uid());
drop policy if exists prof_update on public.profiles;
create policy prof_update on public.profiles for update to authenticated
  using (id = auth.uid() or is_creator()) with check (id = auth.uid() or is_creator());

drop policy if exists pel_read on public.peladas;
create policy pel_read on public.peladas for select to authenticated using (is_member(id) or owner = auth.uid() or is_creator());
drop policy if exists pel_insert on public.peladas;
create policy pel_insert on public.peladas for insert to authenticated with check (auth.uid() is not null);
drop policy if exists pel_update on public.peladas;
create policy pel_update on public.peladas for update to authenticated
  using (is_member(id) or owner = auth.uid()) with check (true);
drop policy if exists pel_delete on public.peladas;
create policy pel_delete on public.peladas for delete to authenticated using (owner = auth.uid() or is_creator());

drop policy if exists mem_read on public.pelada_members;
create policy mem_read on public.pelada_members for select to authenticated using (user_id = auth.uid() or is_member(pelada_id));

drop policy if exists camp_read on public.camps;
create policy camp_read on public.camps for select to authenticated using (camp_visible(camps));
drop policy if exists camp_insert on public.camps;
create policy camp_insert on public.camps for insert to authenticated with check (auth.uid() is not null);
drop policy if exists camp_update on public.camps;
create policy camp_update on public.camps for update to authenticated using (camp_visible(camps)) with check (true);
drop policy if exists camp_delete on public.camps;
create policy camp_delete on public.camps for delete to authenticated using (owner = auth.uid() or is_creator());

drop policy if exists q_read on public.quadras;
create policy q_read on public.quadras for select to authenticated using (true);
drop policy if exists q_insert on public.quadras;
create policy q_insert on public.quadras for insert to authenticated with check (auth.uid() is not null);
drop policy if exists q_update on public.quadras;
create policy q_update on public.quadras for update to authenticated using (owner = auth.uid() or is_creator()) with check (true);
drop policy if exists q_delete on public.quadras;
create policy q_delete on public.quadras for delete to authenticated using (owner = auth.uid() or is_creator());

drop policy if exists img_read on public.images;
create policy img_read on public.images for select to authenticated using (true);
drop policy if exists img_insert on public.images;
create policy img_insert on public.images for insert to authenticated with check (owner = auth.uid());
drop policy if exists img_update on public.images;
create policy img_update on public.images for update to authenticated using (owner = auth.uid()) with check (owner = auth.uid());
drop policy if exists img_delete on public.images;
create policy img_delete on public.images for delete to authenticated using (owner = auth.uid());

-- ---------- permissões da API ----------
revoke all on public.app_config, public.profiles, public.peladas, public.pelada_members,
              public.camps, public.quadras, public.images from anon;
grant select, update on public.app_config to authenticated;
grant select, insert, update on public.profiles to authenticated;
grant select, insert, update, delete on public.peladas, public.camps, public.quadras, public.images to authenticated;
grant select on public.pelada_members to authenticated;
revoke execute on all functions in schema public from anon, public;
grant execute on function public.find_pelada(text), public.join_pelada(text, jsonb),
  public.delete_my_account(), public.is_creator(), public.is_member(text),
  public.shares_pelada(uuid), public.camp_visible(public.camps), public.try_uuid(text) to authenticated;

-- ---------- tempo real ----------
do $$
declare t text;
begin
  foreach t in array array['app_config','profiles','peladas','camps','quadras'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
