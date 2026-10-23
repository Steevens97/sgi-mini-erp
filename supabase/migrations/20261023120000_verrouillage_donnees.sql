-- Module verrouillage : la sécurité est imposée par la base, quel que soit le client
-- (application, appel direct à l'API, ancien jeton).
--   1. Accès « actif » vérifié en base : compte existant, non banni, mot de passe provisoire
--      remplacé, session encore ouverte (un jeton d'une session fermée ne vaut plus rien).
--   2. Les 11 tables métier : admin seulement, en attendant les règles de chaque module.
--   3. collaborateurs.taux_horaire : illisible par les comptes connectés (droit de colonne) ;
--      seul un admin actif le lit, via taux_horaires_collaborateurs().
--   4. Visiteurs anonymes : plus aucun droit sur les 13 tables.
--   5. Bucket « justificatifs » : admin seulement.

-- 1. Accès actif ---------------------------------------------------------------------------
create or replace function public.acces_actif()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_session text := auth.jwt() ->> 'session_id';
  v_ok boolean;
begin
  if v_uid is null or v_session is null then
    return false;
  end if;

  -- Compte existant (non révoqué), non banni, sans mot de passe provisoire à remplacer.
  select true into v_ok
    from auth.users u
   where u.id = v_uid
     and (u.banned_until is null or u.banned_until <= now())
     and coalesce((u.raw_app_meta_data ->> 'doit_changer_mot_de_passe')::boolean, false) = false;
  if v_ok is null then
    return false;
  end if;

  -- Session du jeton toujours ouverte (déconnexion, réinitialisation, révocation la ferment).
  perform 1
     from auth.sessions s
    where s.id::text = v_session
      and s.user_id = v_uid
      and (s.not_after is null or s.not_after > now());
  if not found then
    return false;
  end if;

  -- Profil présent.
  perform 1 from public.profiles p where p.id = v_uid;
  return found;
end
$$;

-- Les fonctions d'identité ne renvoient plus rien pour un accès inactif.
create or replace function public.mon_role()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select p.role from public.profiles p where p.id = auth.uid() and public.acces_actif();
$$;

create or replace function public.mon_collaborateur_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select p.collaborateur_id from public.profiles p where p.id = auth.uid() and public.acces_actif();
$$;

create or replace function public.est_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public.mon_role() = 'admin', false);
$$;

-- Taux horaires : réservés à un admin actif.
create or replace function public.taux_horaires_collaborateurs()
returns table (collaborateur_id uuid, taux_horaire numeric)
language sql
stable
security definer
set search_path = public
as $$
  select c.id, c.taux_horaire from public.collaborateurs c where public.est_admin();
$$;

revoke all on function public.acces_actif() from public, anon;
revoke all on function public.mon_role() from public, anon;
revoke all on function public.mon_collaborateur_id() from public, anon;
revoke all on function public.est_admin() from public, anon;
revoke all on function public.taux_horaires_collaborateurs() from public, anon;
grant execute on function public.acces_actif() to authenticated, service_role;
grant execute on function public.mon_role() to authenticated, service_role;
grant execute on function public.mon_collaborateur_id() to authenticated, service_role;
grant execute on function public.est_admin() to authenticated, service_role;
grant execute on function public.taux_horaires_collaborateurs() to authenticated, service_role;

-- prochain_numero : jamais pour les visiteurs. S'il contourne la RLS (SECURITY DEFINER),
-- il est réservé à la clé secrète (le module Finance l'exposera proprement) ; sinon la RLS
-- de compteurs (admin seulement) suffit.
do $$
declare
  v_definer boolean;
begin
  select p.prosecdef into v_definer
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'prochain_numero'
     and pg_get_function_identity_arguments(p.oid) = 'p_cle text, p_prefixe text';
  execute 'revoke all on function public.prochain_numero(text, text) from public, anon';
  if v_definer then
    execute 'revoke all on function public.prochain_numero(text, text) from authenticated';
  else
    execute 'grant execute on function public.prochain_numero(text, text) to authenticated';
  end if;
  execute 'grant execute on function public.prochain_numero(text, text) to service_role';
end
$$;

-- 2. Règles RLS : balayage complet des 13 tables puis recréation --------------------------
do $$
declare
  v_regle record;
  v_table text;
begin
  for v_regle in
    select policyname, tablename from pg_policies
     where schemaname = 'public'
       and tablename in ('clients', 'prospects', 'devis', 'devis_lignes', 'collaborateurs', 'projets',
                         'factures', 'temps', 'relances', 'conges', 'notes_de_frais', 'compteurs', 'profiles')
  loop
    execute format('drop policy if exists %I on public.%I', v_regle.policyname, v_regle.tablename);
  end loop;

  foreach v_table in array array['clients', 'prospects', 'devis', 'devis_lignes', 'projets', 'factures',
                                 'temps', 'relances', 'conges', 'notes_de_frais', 'compteurs'] loop
    execute format('alter table public.%I enable row level security', v_table);
    execute format(
      'create policy %I on public.%I for all to authenticated '
      'using ((select public.est_admin())) with check ((select public.est_admin()))',
      v_table || '_admin_seulement', v_table);
  end loop;
end
$$;

create policy "profiles_lecture_soi_ou_admin" on public.profiles
  for select to authenticated
  using ((id = auth.uid() and (select public.acces_actif())) or (select public.est_admin()));

create policy "profiles_modification_admin" on public.profiles
  for update to authenticated
  using ((select public.est_admin()))
  with check ((select public.est_admin()));

create policy "collaborateurs_lecture" on public.collaborateurs
  for select to authenticated
  using (id = (select public.mon_collaborateur_id())
         or (select public.mon_role()) in ('admin', 'manager'));

create policy "collaborateurs_creation_admin" on public.collaborateurs
  for insert to authenticated
  with check ((select public.est_admin()));

create policy "collaborateurs_modification_admin" on public.collaborateurs
  for update to authenticated
  using ((select public.est_admin()))
  with check ((select public.est_admin()));

create policy "collaborateurs_suppression_admin" on public.collaborateurs
  for delete to authenticated
  using ((select public.est_admin()));

-- 3 et 4. Droits de table et de colonne ---------------------------------------------------
do $$
declare
  v_table text;
  v_colonnes text;
begin
  foreach v_table in array array['clients', 'prospects', 'devis', 'devis_lignes', 'collaborateurs',
                                 'projets', 'factures', 'temps', 'relances', 'conges', 'notes_de_frais',
                                 'compteurs', 'profiles'] loop
    execute format('revoke all on public.%I from anon', v_table);
  end loop;

  -- Lecture de collaborateurs : toutes les colonnes sauf taux_horaire.
  select string_agg(quote_ident(column_name), ', ' order by ordinal_position) into v_colonnes
    from information_schema.columns
   where table_schema = 'public' and table_name = 'collaborateurs' and column_name <> 'taux_horaire';
  execute 'revoke select on public.collaborateurs from authenticated';
  execute format('grant select (%s) on public.collaborateurs to authenticated', v_colonnes);
end
$$;

-- 5. Bucket « justificatifs » : admin seulement -------------------------------------------
do $$
declare
  v_regle record;
begin
  for v_regle in
    select policyname from pg_policies where schemaname = 'storage' and tablename = 'objects'
       and (coalesce(qual, '') || coalesce(with_check, '')) like '%justificatifs%'
        or (schemaname = 'storage' and tablename = 'objects'
            and (qual = 'true' or with_check = 'true'
                 or coalesce(qual, '') like '%auth.role()%' or coalesce(with_check, '') like '%auth.role()%'))
  loop
    execute format('drop policy if exists %I on storage.objects', v_regle.policyname);
  end loop;
end
$$;

create policy "justificatifs_admin_seulement" on storage.objects
  for all to authenticated
  using (bucket_id = 'justificatifs' and (select public.est_admin()))
  with check (bucket_id = 'justificatifs' and (select public.est_admin()));

-- 6. Contrôles : le déploiement échoue si l'un d'eux ne passe pas -------------------------
do $$
declare
  v_table text;
  v_fonction text;
  v_nb integer;
  v_texte text;
  v_definer boolean;
  v_admin uuid;
  v_vu boolean;
begin
  foreach v_fonction in array array['acces_actif', 'mon_role', 'mon_collaborateur_id', 'est_admin',
                                    'taux_horaires_collaborateurs'] loop
    select p.prosecdef into v_definer
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_fonction and p.pronargs = 0;
    if v_definer is null or not v_definer then
      raise exception 'Verrouillage : public.%() absente ou pas SECURITY DEFINER', v_fonction;
    end if;
    if has_function_privilege('anon', format('public.%I()', v_fonction), 'execute') then
      raise exception 'Verrouillage : public.%() exécutable par un visiteur', v_fonction;
    end if;
  end loop;

  if has_function_privilege('anon', 'public.prochain_numero(text, text)', 'execute') then
    raise exception 'Verrouillage : prochain_numero exécutable par un visiteur';
  end if;

  foreach v_table in array array['clients', 'prospects', 'devis', 'devis_lignes', 'collaborateurs',
                                 'projets', 'factures', 'temps', 'relances', 'conges', 'notes_de_frais',
                                 'compteurs', 'profiles'] loop
    select count(*) into v_nb from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relname = v_table and c.relrowsecurity;
    if v_nb <> 1 then
      raise exception 'Verrouillage : RLS inactive sur %', v_table;
    end if;
    if has_table_privilege('anon', format('public.%I', v_table), 'select, insert, update, delete') then
      raise exception 'Verrouillage : le visiteur anonyme a encore des droits sur %', v_table;
    end if;
    select count(*) into v_nb from pg_policies
     where schemaname = 'public' and tablename = v_table
       and (qual = 'true' or with_check = 'true' or 'public' = any(roles) or 'anon' = any(roles));
    if v_nb > 0 then
      raise exception 'Verrouillage : règle trop permissive sur %', v_table;
    end if;
  end loop;

  foreach v_table in array array['clients', 'prospects', 'devis', 'devis_lignes', 'projets', 'factures',
                                 'temps', 'relances', 'conges', 'notes_de_frais', 'compteurs'] loop
    select string_agg(policyname, ', ') into v_texte from pg_policies
     where schemaname = 'public' and tablename = v_table;
    if v_texte is distinct from v_table || '_admin_seulement' then
      raise exception 'Verrouillage : règles inattendues sur % : %', v_table, coalesce(v_texte, 'aucune');
    end if;
  end loop;

  if has_column_privilege('authenticated', 'public.collaborateurs', 'taux_horaire', 'select') then
    raise exception 'Verrouillage : taux_horaire encore lisible par les comptes connectés';
  end if;
  if not has_column_privilege('authenticated', 'public.collaborateurs', 'nom', 'select') then
    raise exception 'Verrouillage : collaborateurs.nom n''est plus lisible';
  end if;

  select count(*) into v_nb from pg_policies
   where schemaname = 'storage' and tablename = 'objects' and policyname = 'justificatifs_admin_seulement';
  if v_nb <> 1 then
    raise exception 'Verrouillage : règle du bucket justificatifs absente';
  end if;
  select count(*) into v_nb from pg_policies
   where schemaname = 'storage' and tablename = 'objects' and (qual = 'true' or with_check = 'true');
  if v_nb > 0 then
    raise exception 'Verrouillage : règle trop permissive sur storage.objects';
  end if;

  -- Essai réel : un jeton de l'admin existant mais avec une session inconnue (ancien jeton,
  -- session fermée) ne doit donner AUCUN droit.
  select id into v_admin from public.profiles where role = 'admin' limit 1;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin, 'role', 'authenticated',
                      'session_id', '00000000-0000-0000-0000-000000000000')::text, true);
  execute 'set local role authenticated';
  select public.est_admin() into v_vu;
  select count(*) into v_nb from public.profiles;
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  if v_vu then
    raise exception 'Verrouillage : une session inconnue est encore reconnue comme admin';
  end if;
  if v_nb <> 0 then
    raise exception 'Verrouillage : une session inconnue lit encore % profil(s)', v_nb;
  end if;
end
$$;
