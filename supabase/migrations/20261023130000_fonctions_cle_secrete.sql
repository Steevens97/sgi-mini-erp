-- Module fonctions : aucune fonction sensible appelable avec un jeton utilisateur.
--   - Taux horaires : lecture uniquement côté serveur avec la clé secrète, après vérification des
--     droits dans l'action serveur. La fonction taux_horaires_collaborateurs() est supprimée.
--   - prochain_numero : réservé à la clé secrète (un admin ne peut plus consommer un numéro
--     depuis le navigateur ; les modules l'appelleront via des fonctions serveur dédiées).
--   - Inventaire : seules les 4 fonctions d'identité (qui appliquent acces_actif) restent
--     exécutables par un compte connecté ; aucune par un visiteur.
--   - Toutes les règles RLS (tables et stockage) doivent passer par le contrôle de session active.

drop function if exists public.taux_horaires_collaborateurs();

revoke all on function public.prochain_numero(text, text) from public, anon, authenticated;
grant execute on function public.prochain_numero(text, text) to service_role;

-- Contrôles : le déploiement échoue si l'un d'eux ne passe pas.
do $$
declare
  v_liste text;
  v_nb integer;
begin
  -- Plus aucune fonction publique (hors déclencheurs) exécutable par un visiteur.
  select string_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')', ', ')
    into v_liste
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f' and p.prorettype <> 'trigger'::regtype
     and has_function_privilege('anon', p.oid, 'execute');
  if v_liste is not null then
    raise exception 'Fonctions : exécutables par un visiteur : %', v_liste;
  end if;

  -- Compte connecté : exactement les 4 fonctions d'identité.
  select string_agg(p.proname, ', ' order by p.proname) into v_liste
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f' and p.prorettype <> 'trigger'::regtype
     and has_function_privilege('authenticated', p.oid, 'execute');
  if v_liste is distinct from 'acces_actif, est_admin, mon_collaborateur_id, mon_role' then
    raise exception 'Fonctions : exécutables par un compte connecté (attendu les 4 fonctions d''identité) : %',
      coalesce(v_liste, 'aucune');
  end if;

  -- Ces 4 fonctions appliquent le contrôle de session active.
  select count(*) into v_nb
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and ((p.proname in ('mon_role', 'mon_collaborateur_id') and p.prosrc like '%acces_actif()%')
       or (p.proname = 'est_admin' and p.prosrc like '%mon_role()%')
       or (p.proname = 'acces_actif' and p.prosrc like '%auth.sessions%'));
  if v_nb <> 4 then
    raise exception 'Fonctions : une fonction d''identité n''applique plus le contrôle de session active';
  end if;

  -- Aucune fonction restante ne renvoie de taux horaire.
  select string_agg(p.proname, ', ') into v_liste
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prosrc ilike '%taux_horaire%';
  if v_liste is not null then
    raise exception 'Fonctions : fonction(s) manipulant taux_horaire : %', v_liste;
  end if;

  -- Toute règle RLS (13 tables + stockage) passe par une fonction de contrôle de session.
  select string_agg(schemaname || '.' || tablename || '.' || policyname, ', ') into v_liste
    from pg_policies
   where ((schemaname = 'public'
           and tablename in ('clients', 'prospects', 'devis', 'devis_lignes', 'collaborateurs', 'projets',
                             'factures', 'temps', 'relances', 'conges', 'notes_de_frais', 'compteurs',
                             'profiles'))
          or (schemaname = 'storage' and tablename = 'objects'))
     and (coalesce(qual, '') || ' ' || coalesce(with_check, ''))
         !~ '(est_admin|mon_role|mon_collaborateur_id|acces_actif)\(\)';
  if v_liste is not null then
    raise exception 'Règles sans contrôle de session active : %', v_liste;
  end if;

  -- Toutes les règles du stockage sont réservées à l'admin actif.
  select string_agg(policyname, ', ') into v_liste
    from pg_policies
   where schemaname = 'storage' and tablename = 'objects'
     and (coalesce(qual, '') || ' ' || coalesce(with_check, '')) not like '%est_admin()%';
  if v_liste is not null then
    raise exception 'Stockage : règle(s) non réservée(s) à l''admin actif : %', v_liste;
  end if;
end
$$;
