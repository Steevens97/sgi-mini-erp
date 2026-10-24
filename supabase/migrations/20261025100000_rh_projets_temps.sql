-- Module RH : fiches collaborateurs, projets, saisie et validation des temps.
-- Décisions de l'utilisateur du 23/10/2026 (docs/plan-rh.md, sections 6 et 8) :
--   - écriture des temps UNIQUEMENT par la base, via des fonctions réservées à la clé secrète (appelées par
--     les actions serveur après vérification des droits) ; les jetons utilisateurs ne font que LIRE ;
--   - historique des temps alimenté exclusivement par la base, en ajout seul ;
--   - aucune suppression destructrice par cascade (fiches, projets, clients, factures) ;
--   - plafonds : 0,25 h ; fenêtre de 31 jours ; 12 h/jour = dérogation admin motivée ; 24 h/jour = refus absolu ;
--   - personne ne valide ses propres temps (l'admin compris) ; temps facturé figé.
-- Compatible avec le site en ligne (écrans Utilisateurs, RH en lecture, Commercial) : aucune colonne existante
-- n'est modifiée ni supprimée, aucune clé étrangère n'est retouchée.

-- 1. Contrôles préalables -------------------------------------------------------------------------------------
do $$
declare
  v_nb integer;
begin
  select count(*) into v_nb from supabase_migrations.schema_migrations where version = '20261024100000';
  if v_nb <> 1 then
    raise exception 'RH : la migration Commercial 20261024100000 doit être appliquée avant';
  end if;
  -- Données existantes compatibles avec les nouvelles règles (sinon : arrêt, rien n'est appliqué).
  select count(*) into v_nb from public.temps where heures <= 0 or heures > 24 or heures * 4 <> trunc(heures * 4);
  if v_nb > 0 then
    raise exception 'RH : % temps existants ne respectent pas le pas de 0,25 h (entre 0 et 24 h) ; examen nécessaire', v_nb;
  end if;
  select count(*) into v_nb from public.collaborateurs where manager_id = id or taux_horaire < 0;
  if v_nb > 0 then
    raise exception 'RH : % fiches sont leur propre manager ou ont un taux négatif ; examen nécessaire', v_nb;
  end if;
  select count(*) into v_nb from (
    select collaborateur_id, date_saisie from public.temps group by 1, 2 having sum(heures) > 24) j;
  if v_nb > 0 then
    raise exception 'RH : % journées dépassent déjà 24 h ; examen nécessaire', v_nb;
  end if;
end
$$;

-- 2. Nouvelles colonnes (approuvées par l'utilisateur, plan 8.3) ------------------------------------------------
alter table public.temps
  add column if not exists saisi_par uuid,              -- compte qui a saisi (sans lien : un compte révoqué est supprimé)
  add column if not exists saisi_par_nom text,          -- nom recopié au moment de la saisie
  add column if not exists saisi_le timestamptz,
  add column if not exists valide_par uuid,             -- compte du valideur (même principe)
  add column if not exists valide_par_nom text,
  add column if not exists valide_le timestamptz,
  add column if not exists motif_derogation text,       -- obligatoire au-delà de 12 h/jour ou de 31 jours
  add column if not exists historique jsonb not null default '[]'::jsonb;
alter table public.collaborateurs
  add column if not exists date_sortie date;            -- distincte de la révocation du compte

-- 3. Temps existants : aucune information inventée ---------------------------------------------------------------
-- Auteur de la saisie et validation antérieures : inconnus, laissés vides. Un seul événement documente la
-- provenance. Fait AVANT la pose du déclencheur qui interdit toute écriture directe de l'historique.
update public.temps
   set historique = jsonb_build_array(jsonb_build_object(
         'action', 'anterieur_au_module_rh', 'le', now(), 'auteur', null, 'auteur_nom', null,
         'motif', 'Ligne existante avant le module RH (migration 20261025100000) : auteur de la saisie et '
                  || 'validation antérieure inconnus, non reconstitués. Statut d''origine : ' || statut || '.'))
 where historique = '[]'::jsonb and saisi_le is null;

-- 4. Contraintes et paramètres de gestion -------------------------------------------------------------------------
alter table public.temps drop constraint if exists temps_heures_pas_quart_heure;
alter table public.temps add constraint temps_heures_pas_quart_heure
  check (heures > 0 and heures <= 24 and heures * 4 = trunc(heures * 4));
alter table public.temps drop constraint if exists temps_historique_liste;
alter table public.temps add constraint temps_historique_liste check (jsonb_typeof(historique) = 'array');
alter table public.collaborateurs drop constraint if exists collaborateurs_pas_son_propre_manager;
alter table public.collaborateurs add constraint collaborateurs_pas_son_propre_manager
  check (manager_id is null or manager_id <> id);
alter table public.collaborateurs drop constraint if exists collaborateurs_taux_positif;
alter table public.collaborateurs add constraint collaborateurs_taux_positif check (taux_horaire >= 0);
alter table public.collaborateurs drop constraint if exists collaborateurs_sortie_apres_entree;
alter table public.collaborateurs add constraint collaborateurs_sortie_apres_entree
  check (date_sortie is null or date_entree is null or date_sortie >= date_entree);

-- Paramètres de gestion de SG Ingénierie (pas des règles de droit du travail). Les changer = nouvelle migration.
create or replace function public.rh_parametres()
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object('pas_heures', 0.25, 'fenetre_jours', 31, 'seuil_derogation_jour', 12, 'plafond_absolu_jour', 24,
                            'fuseau', 'America/Martinique');
$$;

-- 5. Protections contre les suppressions destructrices -------------------------------------------------------------
-- Fiche collaborateur : jamais supprimée dès qu'elle porte des pièces ou des liens (utiliser date_sortie).
create or replace function public.collaborateurs_avant_suppression()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_motifs text[] := '{}';
begin
  if exists (select 1 from public.temps where collaborateur_id = old.id) then v_motifs := v_motifs || 'des temps'; end if;
  if exists (select 1 from public.conges where collaborateur_id = old.id) then v_motifs := v_motifs || 'des congés'; end if;
  if exists (select 1 from public.conges where valide_par = old.id) then v_motifs := v_motifs || 'des congés qu''elle a validés'; end if;
  if exists (select 1 from public.notes_de_frais where collaborateur_id = old.id) then v_motifs := v_motifs || 'des notes de frais'; end if;
  if exists (select 1 from public.profiles where collaborateur_id = old.id) then v_motifs := v_motifs || 'un compte rattaché'; end if;
  if exists (select 1 from public.collaborateurs where manager_id = old.id) then v_motifs := v_motifs || 'une équipe (manager)'; end if;
  if cardinality(v_motifs) > 0 then
    raise exception 'Suppression refusée : la fiche % % porte %. Renseignez plutôt sa date de sortie.',
      coalesce(old.prenom, ''), old.nom, array_to_string(v_motifs, ', ');
  end if;
  return old;
end
$$;
drop trigger if exists collaborateurs_avant_suppression on public.collaborateurs;
create trigger collaborateurs_avant_suppression before delete on public.collaborateurs
  for each row execute function public.collaborateurs_avant_suppression();

-- Projet : jamais supprimé s'il a des temps, ni s'il est issu d'un devis (sauf nettoyage des ESSAIS, clé secrète).
create or replace function public.projets_avant_suppression()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (select 1 from public.temps where projet_id = old.id) then
    raise exception 'Suppression refusée : le projet « % » a des temps enregistrés. Passez-le en « terminé » ou « annulé ».', old.nom;
  end if;
  if old.devis_id is not null
     and not (not public.appel_utilisateur()
              and exists (select 1 from public.devis where id = old.devis_id and essai)) then
    raise exception 'Suppression refusée : le projet « % » est issu d''un devis accepté (lien commercial).', old.nom;
  end if;
  return old;
end
$$;
drop trigger if exists projets_avant_suppression on public.projets;
create trigger projets_avant_suppression before delete on public.projets
  for each row execute function public.projets_avant_suppression();

-- Client : jamais supprimé s'il est lié à un prospect, un projet ou une facture (les liens seraient effacés).
create or replace function public.clients_avant_suppression()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (select 1 from public.prospects where client_id = old.id)
     or exists (select 1 from public.projets where client_id = old.id)
     or exists (select 1 from public.factures where client_id = old.id) then
    raise exception 'Suppression refusée : le client « % » est lié à des prospects, projets ou factures.', old.nom;
  end if;
  return old;
end
$$;
drop trigger if exists clients_avant_suppression on public.clients;
create trigger clients_avant_suppression before delete on public.clients
  for each row execute function public.clients_avant_suppression();

-- Facture : aucune suppression, jamais (règle conservée pour le module Finance).
create or replace function public.factures_avant_suppression()
returns trigger
language plpgsql
as $$
begin
  raise exception 'Suppression refusée : une facture ne se supprime jamais (règle de gestion de SG Ingénierie).';
end
$$;
drop trigger if exists factures_avant_suppression on public.factures;
create trigger factures_avant_suppression before delete on public.factures
  for each row execute function public.factures_avant_suppression();

-- 6. Fiches collaborateurs et projets ----------------------------------------------------------------------------
-- Hiérarchie : pas de boucle (A → B → A) ; un manager sorti ne reçoit pas de nouvelle équipe ;
-- la date de sortie ne peut pas laisser des temps après elle.
create or replace function public.collaborateurs_avant_ecriture()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_courant uuid := new.manager_id;
  v_profondeur integer := 0;
  v_sortie date;
  v_dernier date;
begin
  if new.manager_id is not null and (tg_op = 'INSERT' or new.manager_id is distinct from old.manager_id) then
    if new.manager_id = new.id then
      raise exception 'Hiérarchie refusée : une personne ne peut pas être son propre manager.';
    end if;
    while v_courant is not null loop
      if v_courant = new.id then
        raise exception 'Hiérarchie refusée : ce rattachement créerait une boucle de managers.';
      end if;
      v_profondeur := v_profondeur + 1;
      if v_profondeur > 100 then
        raise exception 'Hiérarchie refusée : chaîne de managers trop longue (boucle probable).';
      end if;
      select manager_id into v_courant from public.collaborateurs where id = v_courant;
    end loop;
    select date_sortie into v_sortie from public.collaborateurs where id = new.manager_id;
    if v_sortie is not null and v_sortie < (now() at time zone 'America/Martinique')::date then
      raise exception 'Hiérarchie refusée : le manager choisi a quitté l''entreprise le %.', to_char(v_sortie, 'DD/MM/YYYY');
    end if;
  end if;
  if tg_op = 'UPDATE' and new.date_sortie is not null and new.date_sortie is distinct from old.date_sortie then
    select max(date_saisie) into v_dernier from public.temps where collaborateur_id = new.id;
    if v_dernier is not null and v_dernier > new.date_sortie then
      raise exception 'Date de sortie refusée : des temps sont enregistrés jusqu''au %.', to_char(v_dernier, 'DD/MM/YYYY');
    end if;
  end if;
  return new;
end
$$;
drop trigger if exists collaborateurs_avant_ecriture on public.collaborateurs;
create trigger collaborateurs_avant_ecriture before insert or update on public.collaborateurs
  for each row execute function public.collaborateurs_avant_ecriture();

-- Projets : un projet lié à un devis naît uniquement de l'acceptation du devis (automatisme Commercial
-- existant, non dupliqué) ; ses liens devis et client ne changent plus. Manager : statut seulement.
create or replace function public.projets_avant_ecriture()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if new.devis_id is not null then
      if public.appel_utilisateur() or not exists (
           select 1 from public.devis where id = new.devis_id and statut = 'accepte' and avenant_du_devis_id is null) then
        raise exception 'Un projet lié à un devis est créé uniquement par l''acceptation de ce devis.';
      end if;
    end if;
    return new;
  end if;
  -- Lien devis : figé (seule la remise à vide par la base, à la suppression d'un devis d'essai, est admise).
  if new.devis_id is distinct from old.devis_id
     and not (new.devis_id is null and not exists (select 1 from public.devis where id = old.devis_id)) then
    raise exception 'Le devis d''origine d''un projet ne se modifie pas.';
  end if;
  if old.devis_id is not null and new.client_id is distinct from old.client_id then
    raise exception 'Le client d''un projet issu d''un devis ne se modifie pas.';
  end if;
  if public.appel_utilisateur() and not (select public.est_admin())
     and (new.nom is distinct from old.nom or new.client_id is distinct from old.client_id) then
    raise exception 'Seul l''administrateur modifie le nom ou le client d''un projet ; le manager change le statut.';
  end if;
  return new;
end
$$;
drop trigger if exists projets_avant_ecriture on public.projets;
create trigger projets_avant_ecriture before insert or update on public.projets
  for each row execute function public.projets_avant_ecriture();

-- 7. Temps : toutes les règles, quel que soit le chemin d'écriture -------------------------------------------------
-- Contexte posé par les fonctions de service (variables locales à la transaction, inaccessibles aux jetons) :
--   sgi.rh_auteur (compte vérifié), sgi.rh_action (intention), sgi.rh_motif (motif saisi).
-- Sans contexte (tableau de bord, clé secrète directe) : auteur « Hors application », droits minimaux.
create or replace function public.rh_est_valideur(p_role text, p_collaborateur_auteur uuid, p_collaborateur_temps uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  -- Jamais ses propres temps ; admin : ceux des autres ; manager : ceux de son équipe directe.
  select p_collaborateur_auteur is distinct from p_collaborateur_temps
     and (p_role = 'admin'
          or (p_role = 'manager' and p_collaborateur_auteur is not null and exists (
                select 1 from public.collaborateurs c where c.id = p_collaborateur_temps and c.manager_id = p_collaborateur_auteur)));
$$;

create or replace function public.temps_controle()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auteur uuid := nullif(current_setting('sgi.rh_auteur', true), '')::uuid;
  v_action text := nullif(current_setting('sgi.rh_action', true), '');
  v_motif text := nullif(btrim(coalesce(current_setting('sgi.rh_motif', true), '')), '');
  v_role text;
  v_collab_auteur uuid;
  v_nom text;
  v_aujourdhui date := (now() at time zone 'America/Martinique')::date;
  v_sortie date;
  v_total numeric;
  v_statut_projet text;
  v_contenu boolean;
  v_evenements jsonb := '[]'::jsonb;
  v_hors_app boolean;
  v_essai boolean;
begin
  if public.appel_utilisateur() then
    raise exception 'Temps : écriture directe interdite ; passez par l''application.';
  end if;
  v_hors_app := v_auteur is null;
  if not v_hors_app then
    select role, collaborateur_id, coalesce(nullif(nom, ''), email) into v_role, v_collab_auteur, v_nom
      from public.profiles where id = v_auteur;
    if v_role is null then
      raise exception 'Temps : auteur inconnu.';
    end if;
  else
    v_nom := 'Hors application (tableau de bord ou clé secrète)';
  end if;

  -- Suppression -----------------------------------------------------------------------------------------------
  if tg_op = 'DELETE' then
    if old.facture_id is not null then
      raise exception 'Temps facturé : suppression impossible.';
    end if;
    select coalesce(d.essai, false) into v_essai
      from public.projets p left join public.devis d on d.id = p.devis_id where p.id = old.projet_id;
    if v_hors_app and coalesce(v_essai, false) then
      return old;   -- nettoyage des essais (temps sur un projet d'ESSAI), clé secrète
    end if;
    if old.statut <> 'brouillon' then
      raise exception 'Seul un temps en brouillon se supprime (statut : %).', old.statut;
    end if;
    if exists (select 1 from jsonb_array_elements(old.historique) e
                where e ->> 'action' in ('validation', 'reouverture', 'anterieur_au_module_rh')) then
      raise exception 'Ce temps a déjà été validé une fois : corrigez-le au lieu de le supprimer (l''historique est conservé).';
    end if;
    if not v_hors_app and v_role <> 'admin' and v_collab_auteur is distinct from old.collaborateur_id then
      raise exception 'Vous ne pouvez supprimer que vos propres temps.';
    end if;
    return old;
  end if;

  -- Création ----------------------------------------------------------------------------------------------------
  if tg_op = 'INSERT' then
    if new.statut <> 'brouillon' or new.facture_id is not null or new.valide_par is not null
       or new.valide_par_nom is not null or new.valide_le is not null then
      raise exception 'Un temps est créé en brouillon, non validé et non facturé.';
    end if;
    if new.historique is distinct from '[]'::jsonb then
      raise exception 'Historique : alimenté par la base seulement.';
    end if;
    if not v_hors_app and v_role <> 'admin' then
      if v_collab_auteur is null then
        raise exception 'Votre compte n''est rattaché à aucune fiche collaborateur : saisie impossible.';
      end if;
      if new.collaborateur_id <> v_collab_auteur then
        raise exception 'Vous ne pouvez saisir que vos propres temps.';
      end if;
    end if;
    new.saisi_par := v_auteur;
    new.saisi_par_nom := v_nom;
    new.saisi_le := now();
    v_contenu := true;
    v_evenements := jsonb_build_array(jsonb_build_object('action', 'saisie', 'le', now(), 'auteur', v_auteur,
      'auteur_nom', v_nom, 'pour_collaborateur', new.collaborateur_id, 'motif', null));
  else
  -- Modification ------------------------------------------------------------------------------------------------
    if old.facture_id is not null then
      raise exception 'Temps facturé : plus aucune modification possible.';
    end if;
    if new.historique is distinct from old.historique then
      raise exception 'Historique : alimenté par la base seulement, ni modifiable ni effaçable.';
    end if;
    if (new.id, new.collaborateur_id, new.saisi_par, new.saisi_par_nom, new.saisi_le, new.created_at)
       is distinct from (old.id, old.collaborateur_id, old.saisi_par, old.saisi_par_nom, old.saisi_le, old.created_at) then
      raise exception 'Le collaborateur, l''auteur de la saisie et la date de création d''un temps ne changent pas.';
    end if;
    if (new.valide_par, new.valide_par_nom, new.valide_le) is distinct from (old.valide_par, old.valide_par_nom, old.valide_le) then
      raise exception 'La validation est enregistrée par la base seulement.';
    end if;
    v_contenu := (new.projet_id, new.date_saisie, new.heures, new.commentaire, new.motif_derogation)
                 is distinct from (old.projet_id, old.date_saisie, old.heures, old.commentaire, old.motif_derogation);

    -- Facturation (futur module Finance, clé secrète) : une seule fois, sur un temps validé, sans autre changement.
    if new.facture_id is not null then
      if not v_hors_app or old.statut <> 'valide' or new.statut <> 'valide' or v_contenu then
        raise exception 'Un temps est rattaché à une facture une seule fois, validé et inchangé, par le module Finance.';
      end if;
      new.historique := old.historique || jsonb_build_array(jsonb_build_object('action', 'facturation', 'le', now(),
        'auteur', null, 'auteur_nom', v_nom, 'facture', new.facture_id, 'motif', null));
      return new;
    end if;

    if new.statut is distinct from old.statut or v_action = 'attester' then
      if v_contenu then
        raise exception 'Changer le statut et le contenu d''un temps en même temps est interdit.';
      end if;
      if v_hors_app then
        raise exception 'Les changements de statut passent par l''application (auteur identifié).';
      end if;
      if old.statut = 'brouillon' and new.statut = 'soumis' then
        if v_role <> 'admin' and v_collab_auteur is distinct from old.collaborateur_id then
          raise exception 'Vous ne pouvez soumettre que vos propres temps.';
        end if;
        v_evenements := jsonb_build_array(jsonb_build_object('action', 'soumission', 'le', now(), 'auteur', v_auteur,
          'auteur_nom', v_nom, 'motif', null));
      elsif old.statut = 'soumis' and new.statut = 'brouillon' then
        if v_collab_auteur is not distinct from old.collaborateur_id and coalesce(v_action, 'retirer') = 'retirer' then
          v_evenements := jsonb_build_array(jsonb_build_object('action', 'retrait', 'le', now(), 'auteur', v_auteur,
            'auteur_nom', v_nom, 'motif', v_motif));
        elsif public.rh_est_valideur(v_role, v_collab_auteur, old.collaborateur_id) then
          if v_motif is null then
            raise exception 'Renvoi : un motif est obligatoire.';
          end if;
          v_evenements := jsonb_build_array(jsonb_build_object('action', 'renvoi', 'le', now(), 'auteur', v_auteur,
            'auteur_nom', v_nom, 'motif', v_motif));
        else
          raise exception 'Seul le responsable du collaborateur (ou l''administrateur) peut renvoyer ce temps.';
        end if;
      elsif old.statut = 'soumis' and new.statut = 'valide' then
        if v_collab_auteur is not distinct from old.collaborateur_id then
          raise exception 'Personne ne valide ses propres temps.';
        end if;
        if not public.rh_est_valideur(v_role, v_collab_auteur, old.collaborateur_id) then
          raise exception 'Seul le responsable hiérarchique du collaborateur (ou l''administrateur) valide ce temps.';
        end if;
        new.valide_par := v_auteur;
        new.valide_par_nom := v_nom;
        new.valide_le := now();
        v_evenements := jsonb_build_array(jsonb_build_object('action', 'validation', 'le', now(), 'auteur', v_auteur,
          'auteur_nom', v_nom, 'motif', null));
      elsif old.statut = 'valide' and new.statut = 'brouillon' then
        if v_role <> 'admin' then
          raise exception 'Seul l''administrateur rouvre un temps validé.';
        end if;
        if v_motif is null then
          raise exception 'Réouverture : un motif de correction est obligatoire.';
        end if;
        v_evenements := jsonb_build_array(jsonb_build_object('action', 'reouverture', 'le', now(), 'auteur', v_auteur,
          'auteur_nom', v_nom, 'motif', v_motif,
          'validation_precedente', jsonb_build_object('valide_par', old.valide_par, 'valide_par_nom', old.valide_par_nom,
                                                      'valide_le', old.valide_le)));
        new.valide_par := null;
        new.valide_par_nom := null;
        new.valide_le := null;
      elsif old.statut = 'soumis' and new.statut = 'soumis' and v_action = 'attester' then
        -- Attestation de l'intéressé : information distincte, pas une validation ; le statut reste « soumis ».
        if v_collab_auteur is distinct from old.collaborateur_id then
          raise exception 'Seul le collaborateur concerné atteste ses propres temps.';
        end if;
        v_evenements := jsonb_build_array(jsonb_build_object('action', 'attestation_interesse', 'le', now(),
          'auteur', v_auteur, 'auteur_nom', v_nom, 'motif', v_motif));
      else
        raise exception 'Changement de statut interdit : % → %.', old.statut, new.statut;
      end if;
    elsif v_contenu then
      if old.statut <> 'brouillon' then
        raise exception 'Seul un temps en brouillon se corrige (statut : %).', old.statut;
      end if;
      if not v_hors_app and v_role <> 'admin' and v_collab_auteur is distinct from old.collaborateur_id then
        raise exception 'Vous ne pouvez corriger que vos propres temps.';
      end if;
      v_evenements := jsonb_build_array(jsonb_build_object('action', 'correction', 'le', now(), 'auteur', v_auteur,
        'auteur_nom', v_nom, 'motif', null));
    else
      return new;   -- aucune modification réelle
    end if;
  end if;

  -- Contrôles de contenu (création ou correction) ------------------------------------------------------------------
  if v_contenu then
    -- Verrou sur la fiche : les saisies simultanées d'une même personne passent l'une après l'autre (cumuls exacts).
    select date_sortie into v_sortie from public.collaborateurs where id = new.collaborateur_id for update;
    if not found then
      raise exception 'Fiche collaborateur introuvable.';
    end if;
    if new.date_saisie > v_aujourdhui then
      raise exception 'Date future refusée (%).', to_char(new.date_saisie, 'DD/MM/YYYY');
    end if;
    if v_sortie is not null and new.date_saisie > v_sortie then
      raise exception 'Date refusée : le collaborateur a quitté l''entreprise le % (régularisation possible pour les journées antérieures).',
        to_char(v_sortie, 'DD/MM/YYYY');
    end if;
    if tg_op = 'INSERT' or new.projet_id is distinct from old.projet_id then
      select statut into v_statut_projet from public.projets where id = new.projet_id;
      if v_statut_projet is distinct from 'en_cours' then
        raise exception 'Projet fermé à la saisie (statut : %).', coalesce(v_statut_projet, 'introuvable');
      end if;
    end if;
    select coalesce(sum(heures), 0) + new.heures into v_total
      from public.temps where collaborateur_id = new.collaborateur_id and date_saisie = new.date_saisie
       and id is distinct from new.id;
    if v_total > 24 then
      raise exception 'Refusé : % h le % pour ce collaborateur ; le plafond absolu est de 24 h par jour.',
        replace(v_total::text, '.', ','), to_char(new.date_saisie, 'DD/MM/YYYY');
    end if;
    if v_total > 12 or new.date_saisie < v_aujourdhui - 31 then
      if not v_hors_app and v_role <> 'admin' then
        raise exception '%', case when v_total > 12
          then 'Au-delà de 12 h par jour (' || replace(v_total::text, '.', ',') || ' h), seul l''administrateur peut enregistrer, avec un motif.'
          else 'Saisie au-delà de 31 jours : seul l''administrateur peut enregistrer, avec un motif.' end;
      end if;
      if nullif(btrim(coalesce(new.motif_derogation, '')), '') is null then
        raise exception 'Dérogation : un motif est obligatoire (au-delà de 12 h par jour ou de 31 jours).';
      end if;
      v_evenements := v_evenements || jsonb_build_array(jsonb_build_object('action', 'derogation', 'le', now(),
        'auteur', v_auteur, 'auteur_nom', v_nom, 'motif', new.motif_derogation,
        'cumul_jour', v_total, 'anciennete_jours', v_aujourdhui - new.date_saisie));
    end if;
  end if;

  new.historique := case when tg_op = 'INSERT' then '[]'::jsonb else old.historique end || v_evenements;
  return new;
end
$$;
drop trigger if exists temps_controle on public.temps;
create trigger temps_controle before insert or update or delete on public.temps
  for each row execute function public.temps_controle();

-- 8. Fonctions de service (clé secrète seulement, appelées par les actions serveur après vérification) -----------
create or replace function public.verifier_auteur_rh(p_auteur uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role text;
begin
  select p.role into v_role
    from public.profiles p join auth.users u on u.id = p.id
   where p.id = p_auteur
     and (u.banned_until is null or u.banned_until <= now())
     and coalesce((u.raw_app_meta_data ->> 'doit_changer_mot_de_passe')::boolean, false) = false;
  if v_role is null then
    raise exception 'Action RH réservée à un compte actif.';
  end if;
  return v_role;
end
$$;

create or replace function public.rh_contexte(p_auteur uuid, p_action text, p_motif text)
returns void
language plpgsql
set search_path = public
as $$
begin
  perform public.verifier_auteur_rh(p_auteur);
  perform set_config('sgi.rh_auteur', coalesce(p_auteur::text, ''), true);
  perform set_config('sgi.rh_action', coalesce(p_action, ''), true);
  perform set_config('sgi.rh_motif', coalesce(p_motif, ''), true);
end
$$;

create or replace function public.rh_fin_contexte()
returns void
language sql
as $$
  select set_config('sgi.rh_auteur', '', true), set_config('sgi.rh_action', '', true), set_config('sgi.rh_motif', '', true);
$$;

-- Création (p_temps_id null) ou correction d'un temps en brouillon.
create or replace function public.rh_enregistrer_temps(p_auteur uuid, p_temps_id uuid, p_collaborateur_id uuid,
  p_projet_id uuid, p_date date, p_heures numeric, p_commentaire text, p_motif_derogation text)
returns uuid
language plpgsql
set search_path = public
as $$
declare
  v_id uuid;
begin
  perform public.rh_contexte(p_auteur, 'enregistrer', null);
  if p_temps_id is null then
    insert into public.temps (collaborateur_id, projet_id, date_saisie, heures, commentaire, motif_derogation)
    values (p_collaborateur_id, p_projet_id, p_date, p_heures, nullif(btrim(p_commentaire), ''),
            nullif(btrim(p_motif_derogation), ''))
    returning id into v_id;
  else
    -- Le collaborateur concerné ne change jamais : une demande contraire est refusée explicitement.
    if exists (select 1 from public.temps where id = p_temps_id and collaborateur_id is distinct from p_collaborateur_id) then
      raise exception 'Le collaborateur d''un temps ne change pas : créez un nouveau temps pour l''autre personne.';
    end if;
    update public.temps
       set projet_id = p_projet_id, date_saisie = p_date, heures = p_heures,
           commentaire = nullif(btrim(p_commentaire), ''), motif_derogation = nullif(btrim(p_motif_derogation), '')
     where id = p_temps_id
    returning id into v_id;
    if v_id is null then
      raise exception 'Temps introuvable.';
    end if;
  end if;
  perform public.rh_fin_contexte();
  return v_id;
end
$$;

create or replace function public.rh_supprimer_temps(p_auteur uuid, p_temps_id uuid)
returns void
language plpgsql
set search_path = public
as $$
begin
  perform public.rh_contexte(p_auteur, 'supprimer', null);
  delete from public.temps where id = p_temps_id;
  if not found then
    raise exception 'Temps introuvable.';
  end if;
  perform public.rh_fin_contexte();
end
$$;

-- Actions : soumettre, retirer, renvoyer (motif), valider, rouvrir (admin, motif), attester (intéressé).
-- Tout ou rien : si un seul temps est refusé, aucun n'est modifié.
create or replace function public.rh_changer_statut_temps(p_auteur uuid, p_temps_ids uuid[], p_action text, p_motif text)
returns integer
language plpgsql
set search_path = public
as $$
declare
  v_cible text;
  v_nb integer;
begin
  v_cible := case p_action when 'soumettre' then 'soumis' when 'retirer' then 'brouillon' when 'renvoyer' then 'brouillon'
                           when 'valider' then 'valide' when 'rouvrir' then 'brouillon' when 'attester' then 'soumis' end;
  if v_cible is null then
    raise exception 'Action inconnue : %.', p_action;
  end if;
  if coalesce(cardinality(p_temps_ids), 0) = 0 then
    raise exception 'Aucun temps sélectionné.';
  end if;
  perform public.rh_contexte(p_auteur, p_action, p_motif);
  update public.temps set statut = v_cible where id = any(p_temps_ids);
  get diagnostics v_nb = row_count;
  if v_nb <> cardinality(p_temps_ids) then
    raise exception 'Temps introuvable(s) : % demandé(s), % trouvé(s).', cardinality(p_temps_ids), v_nb;
  end if;
  perform public.rh_fin_contexte();
  return v_nb;
end
$$;

-- Nettoyage des essais RH : temps saisis sur des projets d'ESSAI (issus de devis d'essai). Rien de réel.
create or replace function public.supprimer_essais_rh()
returns integer
language plpgsql
set search_path = public
as $$
declare
  v_nb integer;
begin
  if public.appel_utilisateur() then
    raise exception 'Réservé aux essais autorisés (clé secrète)';
  end if;
  perform public.rh_fin_contexte();
  delete from public.temps t
   using public.projets p, public.devis d
   where p.id = t.projet_id and d.id = p.devis_id and d.essai and t.facture_id is null;
  get diagnostics v_nb = row_count;
  return v_nb;
end
$$;

do $$
declare
  v_fonction text;
begin
  foreach v_fonction in array array[
    'rh_parametres()', 'rh_est_valideur(text, uuid, uuid)', 'verifier_auteur_rh(uuid)',
    'rh_contexte(uuid, text, text)', 'rh_fin_contexte()',
    'rh_enregistrer_temps(uuid, uuid, uuid, uuid, date, numeric, text, text)', 'rh_supprimer_temps(uuid, uuid)',
    'rh_changer_statut_temps(uuid, uuid[], text, text)', 'supprimer_essais_rh()'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', v_fonction);
    execute format('grant execute on function public.%s to service_role', v_fonction);
  end loop;
end
$$;

-- 9. Droits ------------------------------------------------------------------------------------------------------------
-- Règles RLS de projets et temps : balayage puis recréation (la règle « admin seulement » disparaît).
do $$
declare
  v_regle record;
begin
  for v_regle in select policyname, tablename from pg_policies
                  where schemaname = 'public' and tablename in ('projets', 'temps') loop
    execute format('drop policy if exists %I on public.%I', v_regle.policyname, v_regle.tablename);
  end loop;
end
$$;
create policy "projets_lecture_admin_manager" on public.projets for select to authenticated
  using ((select public.mon_role()) in ('admin', 'manager'));
create policy "projets_creation_admin" on public.projets for insert to authenticated
  with check ((select public.est_admin()));
create policy "projets_modification_admin_manager" on public.projets for update to authenticated
  using ((select public.mon_role()) in ('admin', 'manager'))
  with check ((select public.mon_role()) in ('admin', 'manager'));
create policy "projets_suppression_admin" on public.projets for delete to authenticated
  using ((select public.est_admin()));
create policy "temps_lecture_soi_admin_manager" on public.temps for select to authenticated
  using (collaborateur_id = (select public.mon_collaborateur_id())
         or (select public.mon_role()) in ('admin', 'manager'));

-- Projets : lecture complète admin/manager ; création admin (nom, client, statut ; jamais de devis) ;
-- modification : statut (admin, manager), nom et client (admin, contrôlé par déclencheur).
revoke all on public.projets from anon, authenticated;
grant select on public.projets to authenticated;
grant insert (nom, client_id, statut) on public.projets to authenticated;
grant update (nom, client_id, statut) on public.projets to authenticated;
grant delete on public.projets to authenticated;
-- Temps : LECTURE seule pour les jetons ; toute écriture passe par les fonctions de service.
revoke all on public.temps from anon, authenticated;
grant select on public.temps to authenticated;
-- Fiches : la nouvelle colonne date_sortie rejoint les colonnes lisibles (le taux reste exclu).
grant select (date_sortie) on public.collaborateurs to authenticated;

-- Projets ouverts à la saisie, pour tous les utilisateurs métier en session active : nom du client seulement,
-- aucune coordonnée, aucun lien vers le devis.
drop view if exists public.rh_projets_ouverts;
create view public.rh_projets_ouverts with (security_barrier = true) as
  select p.id, p.nom, p.statut, c.nom as client_nom
    from public.projets p left join public.clients c on c.id = p.client_id
   where p.statut = 'en_cours'
     and (select public.mon_role()) in ('admin', 'manager', 'collaborateur');
revoke all on public.rh_projets_ouverts from public, anon, authenticated;
grant select on public.rh_projets_ouverts to authenticated, service_role;

-- 10. Contrôles finaux et autotest (annulé) ------------------------------------------------------------------------------
do $$
declare
  v_liste text;
  v_nb integer;
  v_ok boolean;
  v_admin uuid;
  v_admin_fiche uuid;
  v_client uuid;
  v_projet uuid;
  v_projet_ferme uuid;
  v_a uuid;  -- collaborateur
  v_b uuid;  -- son manager
  v_t1 uuid;
  v_t2 uuid;
  v_facture uuid;
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
    raise exception 'RH : fonctions exécutables par un compte connecté : %', coalesce(v_liste, 'aucune');
  end if;
  select string_agg(p.proname, ', ') into v_liste
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f' and p.prorettype <> 'trigger'::regtype
     and has_function_privilege('anon', p.oid, 'execute');
  if v_liste is not null then
    raise exception 'RH : fonctions exécutables par un visiteur : %', v_liste;
  end if;
  -- Taux horaire : aucune fonction ni vue ne le mentionne ; colonne toujours illisible avec un jeton.
  select string_agg(p.proname, ', ') into v_liste
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prosrc ilike '%taux_horaire%';
  if v_liste is not null then
    raise exception 'RH : fonction(s) manipulant taux_horaire : %', v_liste;
  end if;
  select string_agg(viewname, ', ') into v_liste from pg_views
   where schemaname = 'public' and definition ilike '%taux_horaire%';
  if v_liste is not null then
    raise exception 'RH : vue(s) exposant taux_horaire : %', v_liste;
  end if;
  if has_column_privilege('authenticated', 'public.collaborateurs', 'taux_horaire', 'select')
     or not has_column_privilege('authenticated', 'public.collaborateurs', 'date_sortie', 'select') then
    raise exception 'RH : droits de colonnes des fiches incorrects (taux lisible ou date de sortie illisible)';
  end if;
  -- Temps : aucune écriture possible avec un jeton.
  if has_table_privilege('authenticated', 'public.temps', 'insert')
     or has_table_privilege('authenticated', 'public.temps', 'update')
     or has_table_privilege('authenticated', 'public.temps', 'delete')
     or has_table_privilege('anon', 'public.temps', 'select')
     or has_column_privilege('authenticated', 'public.projets', 'devis_id', 'insert')
     or has_column_privilege('authenticated', 'public.projets', 'devis_id', 'update') then
    raise exception 'RH : droits d''écriture trop larges sur temps ou projets';
  end if;
  -- Toutes les règles passent par le contrôle de session active.
  select string_agg(tablename || '.' || policyname, ', ') into v_liste
    from pg_policies
   where schemaname = 'public'
     and (coalesce(qual, '') || ' ' || coalesce(with_check, '')) !~ '(est_admin|mon_role|mon_collaborateur_id|acces_actif)\(\)';
  if v_liste is not null then
    raise exception 'RH : règles sans contrôle de session active : %', v_liste;
  end if;
  -- Déclencheurs posés.
  select count(*) into v_nb from pg_trigger
   where not tgisinternal and tgname in ('collaborateurs_avant_suppression', 'projets_avant_suppression',
     'clients_avant_suppression', 'factures_avant_suppression', 'collaborateurs_avant_ecriture',
     'projets_avant_ecriture', 'temps_controle');
  if v_nb <> 7 then
    raise exception 'RH : % déclencheurs sur 7 posés', v_nb;
  end if;

  -- Autotest complet, annulé à la fin. Empreinte avant/après de toutes les tables touchées.
  select md5(coalesce((select string_agg(t::text, '|' order by t.id) from public.temps t), '')
          || coalesce((select string_agg(c.id || c.nom || coalesce(c.manager_id::text, '') || coalesce(c.date_sortie::text, ''), '|' order by c.id)
                         from public.collaborateurs c), '')
          || coalesce((select string_agg(p::text, '|' order by p.id) from public.projets p), '')
          || coalesce((select string_agg(c::text, '|' order by c.id) from public.clients c), '')
          || coalesce((select string_agg(f::text, '|' order by f.id) from public.factures f), '')
          || coalesce((select string_agg(p::text, '|' order by p.id) from public.profiles p), '')
          || coalesce((select string_agg(k::text, '|' order by k.cle) from public.compteurs k), ''))
    into v_avant;
  select id, collaborateur_id into v_admin, v_admin_fiche from public.profiles where role = 'admin' order by created_at limit 1;
  if v_admin is not null then
  begin
    insert into public.clients (nom) values ('Autotest RH') returning id into v_client;
    insert into public.projets (nom, client_id) values ('Autotest RH ouvert', v_client) returning id into v_projet;
    insert into public.projets (nom, client_id, statut) values ('Autotest RH fermé', v_client, 'termine') returning id into v_projet_ferme;
    insert into public.collaborateurs (nom, prenom, taux_horaire) values ('Autotest-Manager', 'B', 0) returning id into v_b;
    insert into public.collaborateurs (nom, prenom, taux_horaire, manager_id) values ('Autotest-Collab', 'A', 0, v_b) returning id into v_a;

    -- Hiérarchie : pas son propre manager, pas de boucle.
    begin
      update public.collaborateurs set manager_id = v_b where id = v_b;
      raise exception 'AUTOTEST: propre manager accepté';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    begin
      update public.collaborateurs set manager_id = v_a where id = v_b;
      raise exception 'AUTOTEST: boucle de managers acceptée';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;

    -- Saisie par l'admin pour A : auteur distinct du collaborateur concerné.
    v_t1 := public.rh_enregistrer_temps(v_admin, null, v_a, v_projet, v_aujourdhui, 7.5, 'Autotest', null);
    select saisi_par = v_admin and collaborateur_id = v_a and statut = 'brouillon' and jsonb_array_length(historique) = 1
      into v_ok from public.temps where id = v_t1;
    if not v_ok then raise exception 'AUTOTEST: saisie pour autrui mal tracée'; end if;
    -- Pas de 0,25 h ; projet fermé ; date future ; 24 h absolu ; > 12 h sans motif.
    begin
      perform public.rh_enregistrer_temps(v_admin, null, v_a, v_projet, v_aujourdhui, 1.1, null, null);
      raise exception 'AUTOTEST: pas de 0,25 h non respecté';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    begin
      perform public.rh_enregistrer_temps(v_admin, null, v_a, v_projet_ferme, v_aujourdhui, 1, null, null);
      raise exception 'AUTOTEST: projet fermé accepté';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    begin
      perform public.rh_enregistrer_temps(v_admin, null, v_a, v_projet, v_aujourdhui + 1, 1, null, null);
      raise exception 'AUTOTEST: date future acceptée';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    begin
      perform public.rh_enregistrer_temps(v_admin, null, v_a, v_projet, v_aujourdhui, 5, null, null);
      raise exception 'AUTOTEST: plus de 12 h sans motif accepté';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    v_t2 := public.rh_enregistrer_temps(v_admin, null, v_a, v_projet, v_aujourdhui, 5, null, 'Autotest : astreinte chantier');
    begin
      perform public.rh_enregistrer_temps(v_admin, null, v_a, v_projet, v_aujourdhui, 12, null, 'Autotest');
      raise exception 'AUTOTEST: plus de 24 h accepté';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;

    -- Historique : jamais écrit directement ; validation par l'admin (temps d'autrui) ; réouverture tracée.
    begin
      update public.temps set historique = '[]'::jsonb where id = v_t1;
      raise exception 'AUTOTEST: historique effacé';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    perform public.rh_changer_statut_temps(v_admin, array[v_t1], 'soumettre', null);
    perform public.rh_changer_statut_temps(v_admin, array[v_t1], 'valider', null);
    select statut = 'valide' and valide_par = v_admin and valide_le is not null into v_ok from public.temps where id = v_t1;
    if not v_ok then raise exception 'AUTOTEST: validation non enregistrée'; end if;
    begin
      perform public.rh_changer_statut_temps(v_admin, array[v_t1], 'rouvrir', null);
      raise exception 'AUTOTEST: réouverture sans motif acceptée';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    perform public.rh_changer_statut_temps(v_admin, array[v_t1], 'rouvrir', 'Autotest : erreur de projet');
    select statut = 'brouillon' and valide_par is null
       and historique -> -1 ->> 'action' = 'reouverture'
       and (historique -> -1 -> 'validation_precedente' ->> 'valide_par')::uuid = v_admin
      into v_ok from public.temps where id = v_t1;
    if not v_ok then raise exception 'AUTOTEST: réouverture sans trace de la validation précédente'; end if;
    begin
      perform public.rh_supprimer_temps(v_admin, v_t1);
      raise exception 'AUTOTEST: temps déjà validé supprimé';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;

    -- Personne ne valide ses propres temps : l'admin rattaché à la fiche A tente de valider A.
    update public.profiles set collaborateur_id = v_a where id = v_admin;
    perform public.rh_changer_statut_temps(v_admin, array[v_t1], 'soumettre', null);
    begin
      perform public.rh_changer_statut_temps(v_admin, array[v_t1], 'valider', null);
      raise exception 'AUTOTEST: auto-validation acceptée';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    perform public.rh_changer_statut_temps(v_admin, array[v_t1], 'attester', 'Autotest : travail seul');
    select statut = 'soumis' and valide_par is null and historique -> -1 ->> 'action' = 'attestation_interesse'
      into v_ok from public.temps where id = v_t1;
    if not v_ok then raise exception 'AUTOTEST: attestation mal enregistrée'; end if;
    update public.profiles set collaborateur_id = v_admin_fiche where id = v_admin;

    -- Protections contre les suppressions.
    begin
      delete from public.collaborateurs where id = v_a;
      raise exception 'AUTOTEST: fiche avec temps supprimée';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    begin
      delete from public.projets where id = v_projet;
      raise exception 'AUTOTEST: projet avec temps supprimé';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    begin
      delete from public.clients where id = v_client;
      raise exception 'AUTOTEST: client lié supprimé';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    insert into public.factures (client_id) values (v_client) returning id into v_facture;
    begin
      delete from public.factures where id = v_facture;
      raise exception 'AUTOTEST: facture supprimée';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    -- Temps facturé figé.
    perform public.rh_changer_statut_temps(v_admin, array[v_t2], 'soumettre', null);
    perform public.rh_changer_statut_temps(v_admin, array[v_t2], 'valider', null);
    update public.temps set facture_id = v_facture where id = v_t2;
    begin
      update public.temps set heures = 4 where id = v_t2;
      raise exception 'AUTOTEST: temps facturé modifié';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    begin
      update public.temps set facture_id = null where id = v_t2;
      raise exception 'AUTOTEST: temps facturé détaché';
    exception when others then if sqlerrm like 'AUTOTEST:%' then raise; end if; end;
    raise exception 'AUTOTEST_TERMINE';
  exception when others then
    if sqlerrm <> 'AUTOTEST_TERMINE' then
      raise exception 'RH : autotest en échec : %', sqlerrm;
    end if;
  end;
  end if;
  select md5(coalesce((select string_agg(t::text, '|' order by t.id) from public.temps t), '')
          || coalesce((select string_agg(c.id || c.nom || coalesce(c.manager_id::text, '') || coalesce(c.date_sortie::text, ''), '|' order by c.id)
                         from public.collaborateurs c), '')
          || coalesce((select string_agg(p::text, '|' order by p.id) from public.projets p), '')
          || coalesce((select string_agg(c::text, '|' order by c.id) from public.clients c), '')
          || coalesce((select string_agg(f::text, '|' order by f.id) from public.factures f), '')
          || coalesce((select string_agg(p::text, '|' order by p.id) from public.profiles p), '')
          || coalesce((select string_agg(k::text, '|' order by k.cle) from public.compteurs k), ''))
    into v_apres;
  if v_apres is distinct from v_avant then
    raise exception 'RH : l''autotest a modifié des données réelles';
  end if;
  if current_setting('sgi.rh_auteur', true) is distinct from '' and current_setting('sgi.rh_auteur', true) is not null then
    raise exception 'RH : contexte d''auteur resté actif après l''autotest';
  end if;
end
$$;
