-- Module sécurité : fonctions d'identité et règles RLS de profiles et collaborateurs.
-- Remplace, sur ces deux tables seulement, la règle provisoire « tout connecté lit/écrit tout ».

-- 1. Fonctions d'identité.
-- SECURITY DEFINER obligatoire : elles lisent profiles en contournant la RLS,
-- sinon une règle de profiles qui les appelle relirait profiles en boucle.

create or replace function public.mon_role()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select role from public.profiles where id = auth.uid();
$$;

create or replace function public.mon_collaborateur_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select collaborateur_id from public.profiles where id = auth.uid();
$$;

create or replace function public.est_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select role = 'admin' from public.profiles where id = auth.uid()), false);
$$;

revoke all on function public.mon_role() from public, anon;
revoke all on function public.mon_collaborateur_id() from public, anon;
revoke all on function public.est_admin() from public, anon;
grant execute on function public.mon_role() to authenticated, service_role;
grant execute on function public.mon_collaborateur_id() to authenticated, service_role;
grant execute on function public.est_admin() to authenticated, service_role;

-- 2. Suppression de toutes les règles existantes sur les deux tables (par balayage).
do $$
declare
  v_regle record;
begin
  for v_regle in
    select policyname, tablename
      from pg_policies
     where schemaname = 'public' and tablename in ('profiles', 'collaborateurs')
  loop
    execute format('drop policy if exists %I on public.%I', v_regle.policyname, v_regle.tablename);
  end loop;
end
$$;

alter table public.profiles enable row level security;
alter table public.collaborateurs enable row level security;

-- 3. profiles : chacun lit sa fiche, l'admin lit tout ; seul l'admin modifie (rôles, rattachement).
-- Aucune règle d'insertion ni de suppression : le déclencheur de création de compte et la clé
-- secrète (côté serveur) s'en chargent.
create policy "profiles_lecture_soi_ou_admin" on public.profiles
  for select to authenticated
  using (id = auth.uid() or public.est_admin());

create policy "profiles_modification_admin" on public.profiles
  for update to authenticated
  using (public.est_admin())
  with check (public.est_admin());

-- Garde-fou en base : un admin ne peut pas se retirer lui-même le rôle admin.
create or replace function public.empecher_auto_retrogradation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is not null
     and old.id = auth.uid()
     and old.role = 'admin'
     and new.role is distinct from 'admin' then
    raise exception 'Un administrateur ne peut pas se retirer lui-même le rôle admin';
  end if;
  return new;
end
$$;

drop trigger if exists profiles_empecher_auto_retrogradation on public.profiles;
create trigger profiles_empecher_auto_retrogradation
  before update on public.profiles
  for each row execute function public.empecher_auto_retrogradation();

-- 4. collaborateurs : je vois ma fiche, admin et manager voient tout ; seul l'admin écrit.
create policy "collaborateurs_lecture" on public.collaborateurs
  for select to authenticated
  using (id = public.mon_collaborateur_id() or public.mon_role() in ('admin', 'manager'));

create policy "collaborateurs_creation_admin" on public.collaborateurs
  for insert to authenticated
  with check (public.est_admin());

create policy "collaborateurs_modification_admin" on public.collaborateurs
  for update to authenticated
  using (public.est_admin())
  with check (public.est_admin());

create policy "collaborateurs_suppression_admin" on public.collaborateurs
  for delete to authenticated
  using (public.est_admin());

-- 5. Contrôles : le déploiement échoue si l'un d'eux ne passe pas.
do $$
declare
  v_fonction text;
  v_definer boolean;
  v_nb integer;
  v_liste text;
begin
  foreach v_fonction in array array['mon_role', 'mon_collaborateur_id', 'est_admin'] loop
    select p.prosecdef into v_definer
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_fonction and p.pronargs = 0;
    if v_definer is null then
      raise exception 'Sécurité : la fonction public.%() est introuvable', v_fonction;
    end if;
    if not v_definer then
      raise exception 'Sécurité : public.%() doit être SECURITY DEFINER', v_fonction;
    end if;
    if has_function_privilege('anon', format('public.%I()', v_fonction), 'execute') then
      raise exception 'Sécurité : public.%() ne doit pas être exécutable par un visiteur', v_fonction;
    end if;
  end loop;

  select count(*) into v_nb
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname in ('profiles', 'collaborateurs') and c.relrowsecurity;
  if v_nb <> 2 then
    raise exception 'Sécurité : la RLS doit être active sur profiles et collaborateurs';
  end if;

  select string_agg(tablename || '.' || policyname, ', ' order by tablename, policyname) into v_liste
    from pg_policies
   where schemaname = 'public' and tablename in ('profiles', 'collaborateurs');
  if v_liste is distinct from
     'collaborateurs.collaborateurs_creation_admin, collaborateurs.collaborateurs_lecture, '
     'collaborateurs.collaborateurs_modification_admin, collaborateurs.collaborateurs_suppression_admin, '
     'profiles.profiles_lecture_soi_ou_admin, profiles.profiles_modification_admin' then
    raise exception 'Sécurité : règles inattendues sur profiles/collaborateurs : %', coalesce(v_liste, 'aucune');
  end if;

  select count(*) into v_nb
    from pg_policies
   where schemaname = 'public' and tablename in ('profiles', 'collaborateurs')
     and (qual = 'true' or with_check = 'true' or 'public' = any(roles) or 'anon' = any(roles));
  if v_nb > 0 then
    raise exception 'Sécurité : % règle(s) trop permissive(s) restent sur profiles/collaborateurs', v_nb;
  end if;

  select count(*) into v_nb
    from pg_trigger
   where tgrelid = 'public.profiles'::regclass and tgname = 'profiles_empecher_auto_retrogradation';
  if v_nb <> 1 then
    raise exception 'Sécurité : le garde-fou anti-rétrogradation est absent';
  end if;

  -- Le compte admin existant doit le rester.
  select count(*) into v_nb from public.profiles where role = 'admin';
  if v_nb < 1 then
    raise exception 'Sécurité : aucun administrateur dans profiles';
  end if;
end
$$;
