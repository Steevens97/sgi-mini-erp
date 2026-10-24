-- Module RH, correctif : message de refus de suppression d'une fiche collaborateur.
-- Défaut constaté en ligne le 24/10/2026 (parcours RH) : la suppression d'une fiche qui porte des pièces était bien
-- REFUSÉE, mais avec un message technique (« malformed array literal: "des temps" ») au lieu du message prévu.
-- Cause : dans collaborateurs_avant_suppression(), « tableau || 'texte' » est lu par PostgreSQL comme la
-- concaténation de deux tableaux, et 'des temps' n'est pas un tableau valide. Correction : array_append.
-- Seule cette fonction change (même nom, même déclencheur, mêmes contrôles) ; aucune table, colonne, règle ni droit.

-- 1. Contrôles préalables -------------------------------------------------------------------------------------
do $$
declare
  v_nb integer;
begin
  select count(*) into v_nb from supabase_migrations.schema_migrations where version = '20261025100000';
  if v_nb <> 1 then
    raise exception 'Correctif RH : la migration RH 20261025100000 doit être appliquée avant';
  end if;
  select count(*) into v_nb from pg_trigger
   where tgrelid = 'public.collaborateurs'::regclass and tgname = 'collaborateurs_avant_suppression' and not tgisinternal;
  if v_nb <> 1 then
    raise exception 'Correctif RH : déclencheur collaborateurs_avant_suppression absent';
  end if;
end
$$;

-- 2. Fonction corrigée ----------------------------------------------------------------------------------------
create or replace function public.collaborateurs_avant_suppression()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_motifs text[] := '{}';
begin
  if exists (select 1 from public.temps where collaborateur_id = old.id) then v_motifs := array_append(v_motifs, 'des temps'); end if;
  if exists (select 1 from public.conges where collaborateur_id = old.id) then v_motifs := array_append(v_motifs, 'des congés'); end if;
  if exists (select 1 from public.conges where valide_par = old.id) then v_motifs := array_append(v_motifs, 'des congés qu''elle a validés'); end if;
  if exists (select 1 from public.notes_de_frais where collaborateur_id = old.id) then v_motifs := array_append(v_motifs, 'des notes de frais'); end if;
  if exists (select 1 from public.profiles where collaborateur_id = old.id) then v_motifs := array_append(v_motifs, 'un compte rattaché'); end if;
  if exists (select 1 from public.collaborateurs where manager_id = old.id) then v_motifs := array_append(v_motifs, 'une équipe (manager)'); end if;
  if cardinality(v_motifs) > 0 then
    raise exception 'Suppression refusée : la fiche % % porte %. Renseignez plutôt sa date de sortie.',
      coalesce(old.prenom, ''), old.nom, array_to_string(v_motifs, ', ');
  end if;
  return old;
end
$$;
-- Fonction de déclencheur : jamais appelable directement.
revoke all on function public.collaborateurs_avant_suppression() from public, anon, authenticated;

-- 3. Contrôles finaux et autotest (annulé) ----------------------------------------------------------------------
do $$
declare
  v_liste text;
  v_nb integer;
  v_admin uuid;
  v_admin_fiche uuid;
  v_client uuid;
  v_projet uuid;
  v_a uuid;  -- porte des temps, des congés, des notes de frais
  v_b uuid;  -- manager de A
  v_c uuid;  -- a validé un congé de A
  v_d uuid;  -- rattachée à un compte
  v_e uuid;  -- sans aucun lien : supprimable
  v_msg text;
  v_aujourdhui date := (now() at time zone 'America/Martinique')::date;
  v_avant text;
  v_apres text;
begin
  -- Fonctions appelables avec un jeton : toujours exactement les 4 fonctions d'identité ; aucune pour le visiteur.
  select string_agg(p.proname, ', ' order by p.proname) into v_liste
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f' and p.prorettype <> 'trigger'::regtype
     and has_function_privilege('authenticated', p.oid, 'execute');
  if v_liste is distinct from 'acces_actif, est_admin, mon_collaborateur_id, mon_role' then
    raise exception 'Correctif RH : fonctions exécutables par un compte connecté : %', coalesce(v_liste, 'aucune');
  end if;
  select string_agg(p.proname, ', ') into v_liste
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f' and p.prorettype <> 'trigger'::regtype
     and has_function_privilege('anon', p.oid, 'execute');
  if v_liste is not null then
    raise exception 'Correctif RH : fonctions exécutables par un visiteur : %', v_liste;
  end if;
  -- La fonction corrigée : SECURITY DEFINER, plus aucune concaténation « tableau || texte ».
  select count(*) into v_nb from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'collaborateurs_avant_suppression' and p.prosecdef
     and p.prosrc like '%array_append(v_motifs%' and p.prosrc not like '%v_motifs ||%';
  if v_nb <> 1 then
    raise exception 'Correctif RH : fonction collaborateurs_avant_suppression non corrigée';
  end if;

  -- Autotest : messages exacts, annulé à la fin. Empreinte avant/après des tables touchées.
  select md5(coalesce((select string_agg(t::text, '|' order by t.id) from public.temps t), '')
          || coalesce((select string_agg(c.id || c.nom || coalesce(c.manager_id::text, '') || coalesce(c.date_sortie::text, ''), '|' order by c.id)
                         from public.collaborateurs c), '')
          || coalesce((select string_agg(p::text, '|' order by p.id) from public.projets p), '')
          || coalesce((select string_agg(c::text, '|' order by c.id) from public.clients c), '')
          || coalesce((select string_agg(g::text, '|' order by g.id) from public.conges g), '')
          || coalesce((select string_agg(f::text, '|' order by f.id) from public.notes_de_frais f), '')
          || coalesce((select string_agg(p::text, '|' order by p.id) from public.profiles p), '')
          || coalesce((select string_agg(k::text, '|' order by k.cle) from public.compteurs k), ''))
    into v_avant;
  select id, collaborateur_id into v_admin, v_admin_fiche from public.profiles where role = 'admin' order by created_at limit 1;
  if v_admin is null then
    raise exception 'Correctif RH : aucun compte admin, autotest impossible';
  end if;
  begin
    insert into public.clients (nom) values ('Autotest correctif RH') returning id into v_client;
    insert into public.projets (nom, client_id) values ('Autotest correctif RH', v_client) returning id into v_projet;
    insert into public.collaborateurs (nom, prenom, taux_horaire) values ('Autotest-Manager', 'B', 0) returning id into v_b;
    insert into public.collaborateurs (nom, prenom, taux_horaire, manager_id) values ('Autotest-Collab', 'A', 0, v_b) returning id into v_a;
    insert into public.collaborateurs (nom, prenom, taux_horaire) values ('Autotest-Valideur', null, 0) returning id into v_c;
    insert into public.collaborateurs (nom, prenom, taux_horaire) values ('Autotest-Compte', 'D', 0) returning id into v_d;
    insert into public.collaborateurs (nom, prenom, taux_horaire) values ('Autotest-Libre', 'E', 0) returning id into v_e;
    perform public.rh_enregistrer_temps(v_admin, null, v_a, v_projet, v_aujourdhui, 1, 'Autotest', null);
    insert into public.conges (collaborateur_id, date_debut, date_fin, statut, valide_par)
      values (v_a, v_aujourdhui, v_aujourdhui, 'validee', v_c);
    insert into public.notes_de_frais (collaborateur_id, montant) values (v_a, 1);
    update public.profiles set collaborateur_id = v_d where id = v_admin;

    v_msg := null;
    begin delete from public.collaborateurs where id = v_a; exception when others then v_msg := sqlerrm; end;
    if v_msg is distinct from 'Suppression refusée : la fiche A Autotest-Collab porte des temps, des congés, des notes de frais. Renseignez plutôt sa date de sortie.' then
      raise exception 'AUTOTEST: message fiche A : %', coalesce(v_msg, 'suppression acceptée');
    end if;
    v_msg := null;
    begin delete from public.collaborateurs where id = v_b; exception when others then v_msg := sqlerrm; end;
    if v_msg is distinct from 'Suppression refusée : la fiche B Autotest-Manager porte une équipe (manager). Renseignez plutôt sa date de sortie.' then
      raise exception 'AUTOTEST: message fiche B : %', coalesce(v_msg, 'suppression acceptée');
    end if;
    v_msg := null;
    begin delete from public.collaborateurs where id = v_c; exception when others then v_msg := sqlerrm; end;
    if v_msg is distinct from 'Suppression refusée : la fiche  Autotest-Valideur porte des congés qu''elle a validés. Renseignez plutôt sa date de sortie.' then
      raise exception 'AUTOTEST: message fiche C : %', coalesce(v_msg, 'suppression acceptée');
    end if;
    v_msg := null;
    begin delete from public.collaborateurs where id = v_d; exception when others then v_msg := sqlerrm; end;
    if v_msg is distinct from 'Suppression refusée : la fiche D Autotest-Compte porte un compte rattaché. Renseignez plutôt sa date de sortie.' then
      raise exception 'AUTOTEST: message fiche D : %', coalesce(v_msg, 'suppression acceptée');
    end if;
    -- Les fiches refusées sont toujours là, avec leurs pièces ; une fiche sans lien se supprime.
    select count(*) into v_nb from public.collaborateurs where id in (v_a, v_b, v_c, v_d);
    if v_nb <> 4 then
      raise exception 'AUTOTEST: % fiches restantes sur 4', v_nb;
    end if;
    select count(*) into v_nb from public.temps where collaborateur_id = v_a;
    if v_nb <> 1 then
      raise exception 'AUTOTEST: temps de A effacés';
    end if;
    delete from public.collaborateurs where id = v_e;
    if found is not true then
      raise exception 'AUTOTEST: fiche sans lien non supprimée';
    end if;
    raise exception 'AUTOTEST_TERMINE';
  exception when others then
    if sqlerrm <> 'AUTOTEST_TERMINE' then
      raise exception 'Correctif RH : autotest en échec : %', sqlerrm;
    end if;
  end;
  select md5(coalesce((select string_agg(t::text, '|' order by t.id) from public.temps t), '')
          || coalesce((select string_agg(c.id || c.nom || coalesce(c.manager_id::text, '') || coalesce(c.date_sortie::text, ''), '|' order by c.id)
                         from public.collaborateurs c), '')
          || coalesce((select string_agg(p::text, '|' order by p.id) from public.projets p), '')
          || coalesce((select string_agg(c::text, '|' order by c.id) from public.clients c), '')
          || coalesce((select string_agg(g::text, '|' order by g.id) from public.conges g), '')
          || coalesce((select string_agg(f::text, '|' order by f.id) from public.notes_de_frais f), '')
          || coalesce((select string_agg(p::text, '|' order by p.id) from public.profiles p), '')
          || coalesce((select string_agg(k::text, '|' order by k.cle) from public.compteurs k), ''))
    into v_apres;
  if v_apres is distinct from v_avant then
    raise exception 'Correctif RH : l''autotest a modifié des données réelles';
  end if;
  if current_setting('sgi.rh_auteur', true) is distinct from '' and current_setting('sgi.rh_auteur', true) is not null then
    raise exception 'Correctif RH : contexte d''auteur resté actif après l''autotest';
  end if;
end
$$;
