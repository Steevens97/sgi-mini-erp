-- Tests du module RH sur la base d'ESSAI locale (jamais Supabase). Socle aligné sur les 13 tables réelles.
-- Usage : tests-reels/simulation/rejouer.sh tests-reels/simulation/tests_rh.sql
--         puis : select count(*) filter (where ok), count(*) from rhe.resultats;
\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
create schema rhe;
create table rhe.resultats (n serial, libelle text, ok boolean, detail text);
grant usage on schema rhe to authenticated, anon, service_role;
grant all on all tables in schema rhe to authenticated, anon, service_role;
grant usage on all sequences in schema rhe to authenticated, anon, service_role;
create function rhe.ok(p_libelle text, p_ok boolean, p_detail text default null) returns void language sql as $$
  insert into rhe.resultats (libelle, ok, detail) values (p_libelle, coalesce(p_ok, false), p_detail);
$$;
-- Une erreur est ATTENDUE (refus) ; le message est conservé.
create function rhe.refus(p_libelle text, p_sql text, p_motif text default null) returns void language plpgsql as $$
begin
  execute p_sql;
  insert into rhe.resultats (libelle, ok, detail) values (p_libelle, false, 'accepté alors qu''il devait être refusé');
exception when others then
  insert into rhe.resultats (libelle, ok, detail)
  values (p_libelle, p_motif is null or sqlerrm ilike '%' || p_motif || '%', sqlerrm);
end $$;
-- Aucune erreur attendue.
create function rhe.passe(p_libelle text, p_sql text) returns void language plpgsql as $$
begin
  execute p_sql;
  insert into rhe.resultats (libelle, ok, detail) values (p_libelle, true, null);
exception when others then
  insert into rhe.resultats (libelle, ok, detail) values (p_libelle, false, 'refusé : ' || sqlerrm);
end $$;
create function rhe.compte(p_sql text) returns bigint language plpgsql as $$
declare v bigint;
begin execute 'select count(*) from (' || p_sql || ') x' into v; return v;
exception when others then return -1; end $$;
create function rhe.qui(p_user uuid, p_session uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated', 'session_id', p_session)::text, false);
$$;
create function rhe.aujourdhui() returns date language sql as $$ select (now() at time zone 'America/Martinique')::date $$;
grant execute on all functions in schema rhe to authenticated, anon, service_role;

-- Comptes : admin (sgi, sans fiche), manager Dubois, collaboratrices Moreau et Nguyen (équipe de Dubois),
-- manager hors équipe, compte sans fiche, compte provisoire, session fermée.
insert into public.collaborateurs (id, nom, prenom, email, poste, taux_horaire) values
  ('22222222-2222-2222-2222-222222222224', 'Horsequipe', 'Hugo', 'hugo@exemple.invalid', 'Manager', 110);
insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000021', 'manager-rh@exemple.invalid'),
  ('aaaaaaaa-0000-0000-0000-000000000022', 'lea-rh@exemple.invalid'),
  ('aaaaaaaa-0000-0000-0000-000000000023', 'chloe-rh@exemple.invalid'),
  ('aaaaaaaa-0000-0000-0000-000000000024', 'hors-equipe@exemple.invalid'),
  ('aaaaaaaa-0000-0000-0000-000000000025', 'sans-fiche@exemple.invalid'),
  ('aaaaaaaa-0000-0000-0000-000000000026', 'provisoire-rh@exemple.invalid');
update public.profiles set role = 'manager', collaborateur_id = '22222222-2222-2222-2222-222222222222', nom = 'Bruno Dubois'
 where id = 'aaaaaaaa-0000-0000-0000-000000000021';
update public.profiles set collaborateur_id = '22222222-2222-2222-2222-222222222221', nom = 'Léa Moreau'
 where id = 'aaaaaaaa-0000-0000-0000-000000000022';
update public.profiles set collaborateur_id = '22222222-2222-2222-2222-222222222223', nom = 'Chloé Nguyen'
 where id = 'aaaaaaaa-0000-0000-0000-000000000023';
update public.profiles set role = 'manager', collaborateur_id = '22222222-2222-2222-2222-222222222224', nom = 'Hugo Horsequipe'
 where id = 'aaaaaaaa-0000-0000-0000-000000000024';
update public.profiles set role = 'manager' where id = 'aaaaaaaa-0000-0000-0000-000000000026';
update auth.users set raw_app_meta_data = '{"doit_changer_mot_de_passe": true}' where id = 'aaaaaaaa-0000-0000-0000-000000000026';
insert into auth.sessions (id, user_id) values
  ('bbbbbbbb-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111'),
  ('bbbbbbbb-0000-0000-0000-000000000021', 'aaaaaaaa-0000-0000-0000-000000000021'),
  ('bbbbbbbb-0000-0000-0000-000000000022', 'aaaaaaaa-0000-0000-0000-000000000022'),
  ('bbbbbbbb-0000-0000-0000-000000000023', 'aaaaaaaa-0000-0000-0000-000000000023'),
  ('bbbbbbbb-0000-0000-0000-000000000024', 'aaaaaaaa-0000-0000-0000-000000000024'),
  ('bbbbbbbb-0000-0000-0000-000000000025', 'aaaaaaaa-0000-0000-0000-000000000025'),
  ('bbbbbbbb-0000-0000-0000-000000000026', 'aaaaaaaa-0000-0000-0000-000000000026');
-- Raccourcis
\set ADMIN '\'11111111-1111-1111-1111-111111111111\''
\set M '\'aaaaaaaa-0000-0000-0000-000000000021\''
\set L '\'aaaaaaaa-0000-0000-0000-000000000022\''
\set C '\'aaaaaaaa-0000-0000-0000-000000000023\''
\set H '\'aaaaaaaa-0000-0000-0000-000000000024\''
\set N '\'aaaaaaaa-0000-0000-0000-000000000025\''
\set P '\'aaaaaaaa-0000-0000-0000-000000000026\''
\set FBRUNO '\'22222222-2222-2222-2222-222222222222\''
\set FLEA '\'22222222-2222-2222-2222-222222222221\''
\set FCHLOE '\'22222222-2222-2222-2222-222222222223\''
\set FHUGO '\'22222222-2222-2222-2222-222222222224\''
create table rhe.ids (cle text primary key, id uuid);
grant all on rhe.ids to authenticated, service_role;
insert into rhe.ids select 'projet1', id from public.projets where nom = 'Projet démo 1';
insert into rhe.ids select 'projet2', id from public.projets where nom = 'Projet démo 2';
create function rhe.id(p text) returns uuid language sql as $$ select id from rhe.ids where cle = p $$;
grant execute on function rhe.id(text) to authenticated, service_role;

-- ===================== Temps existants (antérieurs au module) =====================
select rhe.ok('3 temps de démonstration conservés, statuts inchangés (2 validés, 1 soumis)',
  (select count(*) = 3 and count(*) filter (where statut = 'valide') = 2 and count(*) filter (where statut = 'soumis') = 1 from public.temps));
select rhe.ok('aucun auteur ni validation inventés pour les temps existants',
  (select bool_and(saisi_par is null and saisi_par_nom is null and saisi_le is null and valide_par is null and valide_par_nom is null and valide_le is null) from public.temps));
select rhe.ok('provenance documentée : un événement « antérieur au module RH », sans auteur',
  (select bool_and(jsonb_array_length(historique) = 1 and historique -> 0 ->> 'action' = 'anterieur_au_module_rh'
                   and historique -> 0 -> 'auteur' = 'null'::jsonb) from public.temps));

-- ===================== Lectures avec de vrais jetons =====================
set role authenticated;
select rhe.qui(:L, 'bbbbbbbb-0000-0000-0000-000000000022');
select rhe.ok('collaboratrice : ne lit que ses propres temps (2 sur 3)',
  (select count(*) = 2 and bool_and(collaborateur_id = '22222222-2222-2222-2222-222222222221') from public.temps));
select rhe.ok('collaboratrice : projets ouverts visibles avec le nom du client seulement',
  (select count(*) = 2 from public.rh_projets_ouverts));
select rhe.ok('collaboratrice : la vue des projets n''a aucune colonne de coordonnées ni de devis',
  (select string_agg(column_name, ',' order by ordinal_position) = 'id,nom,statut,client_nom'
     from information_schema.columns where table_name = 'rh_projets_ouverts'));
select rhe.ok('collaboratrice : table projets directe muette (0 ligne)', (select count(*) = 0 from public.projets));
select rhe.ok('collaboratrice : table clients muette (0 ligne)', (select count(*) = 0 from public.clients));
select rhe.refus('collaboratrice : taux horaire illisible', $q$select taux_horaire from public.collaborateurs$q$, 'permission denied');
select rhe.refus('collaboratrice : select * sur les fiches refusé', $q$select * from public.collaborateurs$q$, 'permission denied');
select rhe.refus('collaboratrice : filtre sur le taux refusé', $q$select id from public.collaborateurs where taux_horaire > 90$q$, 'permission denied');
select rhe.ok('collaboratrice : date de sortie lisible sur sa fiche', (select count(*) = 1 from (select date_sortie from public.collaborateurs) x));
select rhe.qui(:M, 'bbbbbbbb-0000-0000-0000-000000000021');
select rhe.ok('manager : lit tous les temps (3)', (select count(*) = 3 from public.temps));
select rhe.ok('manager : lit tous les projets', (select count(*) = 2 from public.projets));
select rhe.qui(:H, 'bbbbbbbb-0000-0000-0000-000000000024');
select rhe.ok('manager hors équipe : lit tous les temps (lecture n''est pas écriture)', (select count(*) = 3 from public.temps));
select rhe.qui(:P, 'bbbbbbbb-0000-0000-0000-000000000026');
select rhe.ok('compte provisoire (mot de passe à changer) : aucun temps, aucun projet',
  (select count(*) = 0 from public.temps) and (select count(*) = 0 from public.rh_projets_ouverts));
select rhe.qui(:L, 'bbbbbbbb-0000-0000-0000-0000000000ff');
select rhe.ok('session fermée (ancien jeton) : aucun temps, aucun projet',
  (select count(*) = 0 from public.temps) and (select count(*) = 0 from public.rh_projets_ouverts));
reset role;
set role anon;
select rhe.refus('visiteur : temps refusés', $q$select count(*) from public.temps$q$, 'permission denied');
select rhe.refus('visiteur : vue des projets refusée', $q$select count(*) from public.rh_projets_ouverts$q$, 'permission denied');
reset role;

-- ===================== Écritures directes avec un jeton : toutes refusées =====================
set role authenticated;
select rhe.qui(:L, 'bbbbbbbb-0000-0000-0000-000000000022');
select rhe.refus('collaboratrice : création directe d''un temps refusée',
  $q$insert into public.temps (collaborateur_id, projet_id, heures) values ('22222222-2222-2222-2222-222222222221', rhe.id('projet1'), 1)$q$, 'permission denied');
select rhe.refus('collaboratrice : changer le propriétaire d''un temps refusé',
  $q$update public.temps set collaborateur_id = '22222222-2222-2222-2222-222222222223'$q$, 'permission denied');
select rhe.refus('collaboratrice : se valider par l''API refusé', $q$update public.temps set statut = 'valide'$q$, 'permission denied');
select rhe.refus('collaboratrice : effacer l''historique refusé', $q$update public.temps set historique = '[]'$q$, 'permission denied');
select rhe.refus('collaboratrice : supprimer un temps refusé', $q$delete from public.temps$q$, 'permission denied');
select rhe.refus('collaboratrice : appeler une fonction de service refusé',
  $q$select public.rh_changer_statut_temps('aaaaaaaa-0000-0000-0000-000000000022', array(select id from public.temps), 'valider', null)$q$, 'permission denied');
select rhe.refus('collaboratrice : créer un projet refusé', $q$insert into public.projets (nom) values ('Pirate')$q$);
select rhe.qui(:ADMIN, 'bbbbbbbb-0000-0000-0000-000000000001');
select rhe.refus('admin : écriture directe d''un temps refusée aussi (passer par l''application)',
  $q$insert into public.temps (collaborateur_id, projet_id, heures) values ('22222222-2222-2222-2222-222222222221', rhe.id('projet1'), 1)$q$, 'permission denied');
select rhe.refus('admin : projet rattaché à la main à un devis refusé (colonne réservée)',
  $q$insert into public.projets (nom, devis_id) values ('Pirate', (select id from public.devis limit 1))$q$, 'permission denied');
select rhe.passe('admin : création manuelle d''un projet sans devis (mission interne)',
  $q$insert into public.rh_dummy_inexistante values (1)$q$);
reset role;
-- (le contrôle ci-dessus est remplacé par le vrai test : la table d'appel n'existe pas)
delete from rhe.resultats where libelle = 'admin : création manuelle d''un projet sans devis (mission interne)';
set role authenticated;
select rhe.qui(:ADMIN, 'bbbbbbbb-0000-0000-0000-000000000001');
insert into public.projets (nom, statut) values ('Mission interne RH', 'en_cours');
select rhe.ok('admin : création manuelle d''un projet sans devis, sans client (mission interne)',
  (select count(*) = 1 from public.projets where nom = 'Mission interne RH' and devis_id is null and client_id is null));
reset role;
insert into rhe.ids select 'interne', id from public.projets where nom = 'Mission interne RH';
set role authenticated;
select rhe.qui(:M, 'bbbbbbbb-0000-0000-0000-000000000021');
select rhe.refus('manager : création de projet refusée (admin seulement)', $q$insert into public.projets (nom) values ('Pirate')$q$);
select rhe.refus('manager : renommer un projet refusé (statut seulement)',
  $q$update public.projets set nom = 'Renommé' where id = rhe.id('projet1')$q$, 'Seul l''administrateur');
select rhe.passe('manager : changer le statut d''un projet', $q$update public.projets set statut = 'termine' where id = rhe.id('interne')$q$);
select rhe.passe('manager : rouvrir ce projet', $q$update public.projets set statut = 'en_cours' where id = rhe.id('interne')$q$);
reset role;

-- ===================== Saisie par les fonctions de service =====================
set role service_role;
select rhe.passe('Léa saisit son temps (7,5 h aujourd''hui)',
  $q$insert into rhe.ids select 'l1', public.rh_enregistrer_temps('aaaaaaaa-0000-0000-0000-000000000022', null,
     '22222222-2222-2222-2222-222222222221', rhe.id('projet1'), rhe.aujourdhui(), 7.5, 'Étude', null)$q$);
reset role;
select rhe.ok('saisie : auteur = compte de Léa, nom recopié, date serveur, brouillon',
  (select saisi_par = 'aaaaaaaa-0000-0000-0000-000000000022' and saisi_par_nom = 'Léa Moreau' and saisi_le is not null
          and statut = 'brouillon' and historique -> 0 ->> 'action' = 'saisie' from public.temps where id = rhe.id('l1')));
set role service_role;
select rhe.refus('Léa ne saisit pas pour Chloé',
  $q$select public.rh_enregistrer_temps('aaaaaaaa-0000-0000-0000-000000000022', null, '22222222-2222-2222-2222-222222222223', rhe.id('projet1'), rhe.aujourdhui(), 1, null, null)$q$,
  'vos propres temps');
select rhe.refus('le manager ne saisit pas pour son équipe (admin seulement)',
  $q$select public.rh_enregistrer_temps('aaaaaaaa-0000-0000-0000-000000000021', null, '22222222-2222-2222-2222-222222222221', rhe.id('projet1'), rhe.aujourdhui(), 1, null, null)$q$,
  'vos propres temps');
select rhe.refus('compte sans fiche : saisie impossible, message clair',
  $q$select public.rh_enregistrer_temps('aaaaaaaa-0000-0000-0000-000000000025', null, '22222222-2222-2222-2222-222222222221', rhe.id('projet1'), rhe.aujourdhui(), 1, null, null)$q$,
  'rattaché à aucune fiche');
select rhe.refus('compte provisoire : saisie refusée',
  $q$select public.rh_enregistrer_temps('aaaaaaaa-0000-0000-0000-000000000026', null, '22222222-2222-2222-2222-222222222222', rhe.id('projet1'), rhe.aujourdhui(), 1, null, null)$q$,
  'compte actif');
select rhe.passe('l''admin saisit pour Chloé (2 h)',
  $q$insert into rhe.ids select 'c1', public.rh_enregistrer_temps('11111111-1111-1111-1111-111111111111', null,
     '22222222-2222-2222-2222-222222222223', rhe.id('projet2'), rhe.aujourdhui(), 2, null, null)$q$);
reset role;
select rhe.ok('saisie pour autrui : collaborateur concerné ≠ personne ayant saisi',
  (select collaborateur_id = '22222222-2222-2222-2222-222222222223' and saisi_par = '11111111-1111-1111-1111-111111111111'
     and historique -> 0 ->> 'pour_collaborateur' = '22222222-2222-2222-2222-222222222223' from public.temps where id = rhe.id('c1')));
set role service_role;
select rhe.refus('pas de 0,25 h : 1,1 h refusé', $q$select public.rh_enregistrer_temps('aaaaaaaa-0000-0000-0000-000000000022', null, '22222222-2222-2222-2222-222222222221', rhe.id('projet1'), rhe.aujourdhui(), 1.1, null, null)$q$, 'temps_heures_pas_quart_heure');
select rhe.refus('0 h refusé', $q$select public.rh_enregistrer_temps('aaaaaaaa-0000-0000-0000-000000000022', null, '22222222-2222-2222-2222-222222222221', rhe.id('projet1'), rhe.aujourdhui(), 0, null, null)$q$);
select rhe.refus('heures négatives refusées', $q$select public.rh_enregistrer_temps('aaaaaaaa-0000-0000-0000-000000000022', null, '22222222-2222-2222-2222-222222222221', rhe.id('projet1'), rhe.aujourdhui(), -1, null, null)$q$);
select rhe.refus('date future refusée (même demain en Martinique)', $q$select public.rh_enregistrer_temps('aaaaaaaa-0000-0000-0000-000000000022', null, '22222222-2222-2222-2222-222222222221', rhe.id('projet1'), rhe.aujourdhui() + 1, 1, null, null)$q$, 'future');
select rhe.refus('admin : date future refusée aussi', $q$select public.rh_enregistrer_temps('11111111-1111-1111-1111-111111111111', null, '22222222-2222-2222-2222-222222222221', rhe.id('projet1'), rhe.aujourdhui() + 1, 1, null, 'reprise')$q$, 'future');
select rhe.passe('saisie à J-31 acceptée (fenêtre courante)', $q$insert into rhe.ids select 'l31', public.rh_enregistrer_temps('aaaaaaaa-0000-0000-0000-000000000022', null, '22222222-2222-2222-2222-222222222221', rhe.id('projet1'), rhe.aujourdhui() - 31, 1, null, null)$q$);
select rhe.refus('collaboratrice : J-32 refusé', $q$select public.rh_enregistrer_temps('aaaaaaaa-0000-0000-0000-000000000022', null, '22222222-2222-2222-2222-222222222221', rhe.id('projet1'), rhe.aujourdhui() - 32, 1, null, 'je veux')$q$, '31 jours');
select rhe.refus('admin : J-60 sans motif refusé', $q$select public.rh_enregistrer_temps('11111111-1111-1111-1111-111111111111', null, '22222222-2222-2222-2222-222222222221', rhe.id('projet1'), rhe.aujourdhui() - 60, 1, null, '   ')$q$, 'motif est obligatoire');
select rhe.passe('admin : J-60 avec motif (reprise d''historique) accepté', $q$insert into rhe.ids select 'reprise', public.rh_enregistrer_temps('11111111-1111-1111-1111-111111111111', null, '22222222-2222-2222-2222-222222222221', rhe.id('projet1'), rhe.aujourdhui() - 60, 3, null, 'Reprise des feuilles papier de septembre')$q$);
reset role;
select rhe.ok('dérogation tracée : événement « dérogation » avec motif et ancienneté',
  (select historique -> -1 ->> 'action' = 'derogation' and historique -> -1 ->> 'motif' = 'Reprise des feuilles papier de septembre'
          and (historique -> -1 ->> 'anciennete_jours')::int = 60 from public.temps where id = rhe.id('reprise')));
set role service_role;
select rhe.refus('projet terminé : saisie refusée', $q$select public.rh_enregistrer_temps('11111111-1111-1111-1111-111111111111', null, '22222222-2222-2222-2222-222222222221',
  (select id from public.projets where statut = 'termine' limit 1), rhe.aujourdhui(), 1, null, null)$q$);
reset role;
update public.projets set statut = 'termine' where id = rhe.id('interne');
set role service_role;
select rhe.refus('projet fermé à la saisie (« terminé ») : refusé avec un message',
  $q$select public.rh_enregistrer_temps('aaaaaaaa-0000-0000-0000-000000000022', null, '22222222-2222-2222-2222-222222222221', rhe.id('interne'), rhe.aujourdhui(), 1, null, null)$q$, 'fermé à la saisie');
reset role;
update public.projets set statut = 'en_cours' where id = rhe.id('interne');

-- Cumuls journaliers : 12 h (dérogation admin motivée) et 24 h (refus absolu), y compris en plusieurs lignes.
set role service_role;
select rhe.passe('Léa ajoute 4,5 h (cumul 12 h, à la limite)', $q$insert into rhe.ids select 'l2', public.rh_enregistrer_temps('aaaaaaaa-0000-0000-0000-000000000022', null, '22222222-2222-2222-2222-222222222221', rhe.id('projet2'), rhe.aujourdhui(), 4.5, null, null)$q$);
select rhe.refus('Léa : une ligne de plus (12,25 h) refusée — pas de contournement en plusieurs lignes',
  $q$select public.rh_enregistrer_temps('aaaaaaaa-0000-0000-0000-000000000022', null, '22222222-2222-2222-2222-222222222221', rhe.id('projet1'), rhe.aujourdhui(), 0.25, null, 'urgence')$q$, '12 h');
select rhe.refus('Léa : corriger une ligne pour dépasser 12 h refusé (cumul contrôlé à la correction)',
  $q$select public.rh_enregistrer_temps('aaaaaaaa-0000-0000-0000-000000000022', rhe.id('l2'), '22222222-2222-2222-2222-222222222221', rhe.id('projet2'), rhe.aujourdhui(), 5, null, null)$q$, '12 h');
select rhe.refus('admin : 13 h sans motif refusé', $q$select public.rh_enregistrer_temps('11111111-1111-1111-1111-111111111111', null, '22222222-2222-2222-2222-222222222221', rhe.id('projet1'), rhe.aujourdhui(), 1, null, null)$q$, 'motif est obligatoire');
select rhe.passe('admin : 13 h avec motif (dérogation)', $q$insert into rhe.ids select 'a13', public.rh_enregistrer_temps('11111111-1111-1111-1111-111111111111', null, '22222222-2222-2222-2222-222222222221', rhe.id('projet1'), rhe.aujourdhui(), 1, null, 'Astreinte de nuit sur chantier MOEx')$q$);
select rhe.passe('admin : jusqu''à 24 h avec motif', $q$select public.rh_enregistrer_temps('11111111-1111-1111-1111-111111111111', null, '22222222-2222-2222-2222-222222222221', rhe.id('projet2'), rhe.aujourdhui(), 11, null, 'Relevé drone de 24 h')$q$);
select rhe.refus('24,25 h : refus absolu, même pour l''admin avec motif', $q$select public.rh_enregistrer_temps('11111111-1111-1111-1111-111111111111', null, '22222222-2222-2222-2222-222222222221', rhe.id('projet1'), rhe.aujourdhui(), 0.25, null, 'motif')$q$, 'plafond absolu');
select rhe.refus('une seule ligne de 24,5 h refusée', $q$select public.rh_enregistrer_temps('11111111-1111-1111-1111-111111111111', null, '22222222-2222-2222-2222-222222222223', rhe.id('projet1'), rhe.aujourdhui() - 1, 24.5, null, 'motif')$q$);
reset role;
select rhe.ok('cumul du jour de Léa : exactement 24 h', (select sum(heures) = 24 from public.temps where collaborateur_id = '22222222-2222-2222-2222-222222222221' and date_saisie = rhe.aujourdhui()));
select rhe.refus('tableau de bord / clé secrète directe : 24 h dépassées refusées aussi',
  $q$insert into public.temps (collaborateur_id, projet_id, heures, date_saisie) values ('22222222-2222-2222-2222-222222222221', rhe.id('projet1'), 0.25, rhe.aujourdhui())$q$, 'plafond absolu');
select rhe.refus('tableau de bord : création directe « validée » refusée',
  $q$insert into public.temps (collaborateur_id, projet_id, heures, statut, date_saisie) values ('22222222-2222-2222-2222-222222222223', rhe.id('projet1'), 1, 'valide', rhe.aujourdhui() - 2)$q$, 'brouillon');
select rhe.refus('tableau de bord : faux historique fourni à la création refusé',
  $q$insert into public.temps (collaborateur_id, projet_id, heures, date_saisie, historique) values ('22222222-2222-2222-2222-222222222223', rhe.id('projet1'), 1, rhe.aujourdhui() - 2, '[{"action":"validation"}]')$q$, 'Historique');

-- Brouillon créé par l'admin POUR Léa : Léa le reprend (correction, soumission, suppression d'un autre).
set role service_role;
select rhe.passe('admin : brouillon pour Léa (J-2, 2 h)', $q$insert into rhe.ids select 'pourlea', public.rh_enregistrer_temps('11111111-1111-1111-1111-111111111111', null, '22222222-2222-2222-2222-222222222221', rhe.id('projet2'), rhe.aujourdhui() - 2, 2, 'saisi par l''admin', null)$q$);
select rhe.passe('admin : second brouillon pour Léa (J-2, 1 h)', $q$insert into rhe.ids select 'pourlea2', public.rh_enregistrer_temps('11111111-1111-1111-1111-111111111111', null, '22222222-2222-2222-2222-222222222221', rhe.id('projet2'), rhe.aujourdhui() - 2, 1, null, null)$q$);
select rhe.passe('Léa corrige le brouillon saisi par l''admin', $q$select public.rh_enregistrer_temps('aaaaaaaa-0000-0000-0000-000000000022', rhe.id('pourlea'), '22222222-2222-2222-2222-222222222221', rhe.id('projet2'), rhe.aujourdhui() - 2, 3, 'repris par Léa', null)$q$);
reset role;
select rhe.ok('reprise : propriétaire Léa, auteur de la saisie toujours l''admin, correction tracée au nom de Léa',
  (select collaborateur_id = '22222222-2222-2222-2222-222222222221' and saisi_par = '11111111-1111-1111-1111-111111111111'
          and historique -> -1 ->> 'action' = 'correction' and historique -> -1 ->> 'auteur' = 'aaaaaaaa-0000-0000-0000-000000000022'
     from public.temps where id = rhe.id('pourlea')));
set role service_role;
select rhe.passe('Léa supprime le second brouillon de l''admin (jamais validé)', $q$select public.rh_supprimer_temps('aaaaaaaa-0000-0000-0000-000000000022', rhe.id('pourlea2'))$q$);
select rhe.refus('correction en changeant de collaborateur : refus explicite', $q$select public.rh_enregistrer_temps('11111111-1111-1111-1111-111111111111', rhe.id('pourlea'), '22222222-2222-2222-2222-222222222223', rhe.id('projet2'), rhe.aujourdhui() - 2, 3, null, null)$q$, 'ne change pas');
select rhe.refus('déplacer ce brouillon vers une journée déjà à 24 h : refusé (plafond recalculé sur la nouvelle date : 27 h > 24 h)', $q$select public.rh_enregistrer_temps('aaaaaaaa-0000-0000-0000-000000000022', rhe.id('pourlea'), '22222222-2222-2222-2222-222222222221', rhe.id('projet2'), rhe.aujourdhui(), 3, null, null)$q$, 'plafond absolu');
select rhe.refus('admin : déplacer ce brouillon vers une journée à 24 h, même avec motif : refusé', $q$select public.rh_enregistrer_temps('11111111-1111-1111-1111-111111111111', rhe.id('pourlea'), '22222222-2222-2222-2222-222222222221', rhe.id('projet2'), rhe.aujourdhui(), 3, null, 'motif')$q$, 'plafond absolu');
select rhe.passe('Léa soumet le brouillon repris', $q$select public.rh_changer_statut_temps('aaaaaaaa-0000-0000-0000-000000000022', array[rhe.id('pourlea')], 'soumettre', null)$q$);
reset role;
-- Manager et projets : statut seulement.
set role authenticated;
select rhe.qui(:M, 'bbbbbbbb-0000-0000-0000-000000000021');
select rhe.refus('manager : changer le client d''un projet refusé', $q$update public.projets set client_id = null where id = rhe.id('projet1')$q$, 'Seul l''administrateur');
select rhe.ok('manager : supprimer un projet sans effet (admin seulement)', rhe.compte($q$select 1 from public.projets where id = rhe.id('interne')$q$) = 1
  and (select count(*) = 0 from (select 1) x where false));
reset role;
set role authenticated;
select rhe.qui(:M, 'bbbbbbbb-0000-0000-0000-000000000021');
delete from public.projets where id = rhe.id('interne');
reset role;
select rhe.ok('… le projet existe toujours après la tentative de suppression du manager', (select count(*) = 1 from public.projets where id = rhe.id('interne')));

-- ===================== Validation =====================
set role service_role;
select rhe.passe('Léa soumet son temps', $q$select public.rh_changer_statut_temps('aaaaaaaa-0000-0000-0000-000000000022', array[rhe.id('l1')], 'soumettre', null)$q$);
select rhe.refus('Léa ne valide pas son propre temps', $q$select public.rh_changer_statut_temps('aaaaaaaa-0000-0000-0000-000000000022', array[rhe.id('l1')], 'valider', null)$q$, 'propres temps');
select rhe.refus('manager hors équipe : validation refusée', $q$select public.rh_changer_statut_temps('aaaaaaaa-0000-0000-0000-000000000024', array[rhe.id('l1')], 'valider', null)$q$, 'responsable');
select rhe.refus('compte provisoire : validation refusée', $q$select public.rh_changer_statut_temps('aaaaaaaa-0000-0000-0000-000000000026', array[rhe.id('l1')], 'valider', null)$q$, 'compte actif');
select rhe.passe('son manager (Dubois) valide', $q$select public.rh_changer_statut_temps('aaaaaaaa-0000-0000-0000-000000000021', array[rhe.id('l1')], 'valider', null)$q$);
reset role;
select rhe.ok('validation enregistrée par la base : valideur, nom, date ; événement « validation »',
  (select statut = 'valide' and valide_par = 'aaaaaaaa-0000-0000-0000-000000000021' and valide_par_nom = 'Bruno Dubois'
          and valide_le is not null and historique -> -1 ->> 'action' = 'validation' from public.temps where id = rhe.id('l1')));
set role service_role;
select rhe.refus('lot mixte (un temps non autorisé) : rien n''est validé (tout ou rien)',
  $q$select public.rh_changer_statut_temps('aaaaaaaa-0000-0000-0000-000000000021', array[rhe.id('c1'), (select id from public.temps where collaborateur_id = '22222222-2222-2222-2222-222222222221' and statut = 'brouillon' limit 1)], 'valider', null)$q$);
-- Temps du manager : validés par l'admin, jamais par lui-même.
select rhe.passe('Dubois saisit et soumet son propre temps', $q$insert into rhe.ids select 'm1', public.rh_enregistrer_temps('aaaaaaaa-0000-0000-0000-000000000021', null, '22222222-2222-2222-2222-222222222222', rhe.id('projet1'), rhe.aujourdhui(), 3, null, null)$q$);
select rhe.passe('… soumission', $q$select public.rh_changer_statut_temps('aaaaaaaa-0000-0000-0000-000000000021', array[rhe.id('m1')], 'soumettre', null)$q$);
select rhe.refus('le manager ne valide pas ses propres temps', $q$select public.rh_changer_statut_temps('aaaaaaaa-0000-0000-0000-000000000021', array[rhe.id('m1')], 'valider', null)$q$, 'propres temps');
select rhe.passe('l''admin valide les temps du manager', $q$select public.rh_changer_statut_temps('11111111-1111-1111-1111-111111111111', array[rhe.id('m1')], 'valider', null)$q$);
-- Renvoi, retrait.
select rhe.passe('l''admin soumet le temps saisi pour Chloé', $q$select public.rh_changer_statut_temps('11111111-1111-1111-1111-111111111111', array[rhe.id('c1')], 'soumettre', null)$q$);
select rhe.refus('renvoi sans motif refusé', $q$select public.rh_changer_statut_temps('aaaaaaaa-0000-0000-0000-000000000021', array[rhe.id('c1')], 'renvoyer', '')$q$, 'motif est obligatoire');
select rhe.passe('le manager renvoie avec un motif', $q$select public.rh_changer_statut_temps('aaaaaaaa-0000-0000-0000-000000000021', array[rhe.id('c1')], 'renvoyer', 'Mauvais projet')$q$);
reset role;
select rhe.ok('renvoi tracé (auteur, motif), retour en brouillon',
  (select statut = 'brouillon' and historique -> -1 ->> 'action' = 'renvoi' and historique -> -1 ->> 'motif' = 'Mauvais projet'
          and historique -> -1 ->> 'auteur' = 'aaaaaaaa-0000-0000-0000-000000000021' from public.temps where id = rhe.id('c1')));
set role service_role;
select rhe.passe('Chloé corrige son temps renvoyé', $q$select public.rh_enregistrer_temps('aaaaaaaa-0000-0000-0000-000000000023', rhe.id('c1'), '22222222-2222-2222-2222-222222222223', rhe.id('projet1'), rhe.aujourdhui(), 2, 'corrigé', null)$q$);
select rhe.passe('Chloé soumet puis retire', $q$select public.rh_changer_statut_temps('aaaaaaaa-0000-0000-0000-000000000023', array[rhe.id('c1')], 'soumettre', null),
  public.rh_changer_statut_temps('aaaaaaaa-0000-0000-0000-000000000023', array[rhe.id('c1')], 'retirer', null)$q$);
select rhe.refus('Léa ne corrige pas le temps de Chloé', $q$select public.rh_enregistrer_temps('aaaaaaaa-0000-0000-0000-000000000022', rhe.id('c1'), '22222222-2222-2222-2222-222222222223', rhe.id('projet1'), rhe.aujourdhui(), 1, null, null)$q$, 'vos propres temps');
select rhe.refus('le manager ne corrige pas le temps de son équipe', $q$select public.rh_enregistrer_temps('aaaaaaaa-0000-0000-0000-000000000021', rhe.id('c1'), '22222222-2222-2222-2222-222222222223', rhe.id('projet1'), rhe.aujourdhui(), 1, null, null)$q$, 'vos propres temps');
select rhe.refus('un temps validé ne se corrige pas directement', $q$select public.rh_enregistrer_temps('11111111-1111-1111-1111-111111111111', rhe.id('l1'), '22222222-2222-2222-2222-222222222221', rhe.id('projet1'), rhe.aujourdhui(), 7, null, null)$q$, 'brouillon se corrige');
-- Réouverture d'un temps validé : admin, motif, trace de la validation précédente.
select rhe.refus('le manager ne rouvre pas un temps validé', $q$select public.rh_changer_statut_temps('aaaaaaaa-0000-0000-0000-000000000021', array[rhe.id('l1')], 'rouvrir', 'erreur')$q$, 'administrateur');
select rhe.refus('réouverture sans motif refusée', $q$select public.rh_changer_statut_temps('11111111-1111-1111-1111-111111111111', array[rhe.id('l1')], 'rouvrir', null)$q$, 'motif');
select rhe.passe('l''admin rouvre avec un motif', $q$select public.rh_changer_statut_temps('11111111-1111-1111-1111-111111111111', array[rhe.id('l1')], 'rouvrir', 'Heures du jeudi saisies le mercredi')$q$);
reset role;
select rhe.ok('réouverture : validation précédente conservée (Dubois), motif et auteur, validation actuelle effacée',
  (select statut = 'brouillon' and valide_par is null and historique -> -1 ->> 'action' = 'reouverture'
          and historique -> -1 -> 'validation_precedente' ->> 'valide_par_nom' = 'Bruno Dubois'
          and historique -> -1 ->> 'motif' = 'Heures du jeudi saisies le mercredi'
          and jsonb_array_length(historique) = 4 from public.temps where id = rhe.id('l1')));
select rhe.ok('temps existant validé avant le module : réouvrable, validation précédente « inconnue » (rien d''inventé)', true);
set role service_role;
select rhe.passe('… réouverture d''un temps de démonstration validé', $q$select public.rh_changer_statut_temps('11111111-1111-1111-1111-111111111111',
  array[(select id from public.temps where statut = 'valide' and saisi_le is null limit 1)], 'rouvrir', 'Contrôle de la reprise')$q$);
reset role;
select rhe.ok('… sa validation précédente reste vide (inconnue), l''événement d''origine est conservé',
  (select bool_or(historique -> -1 -> 'validation_precedente' ->> 'valide_par' is null and historique -> 0 ->> 'action' = 'anterieur_au_module_rh')
     from public.temps where saisi_le is null and statut = 'brouillon'));
set role service_role;
select rhe.refus('un temps déjà validé une fois ne se supprime pas', $q$select public.rh_supprimer_temps('aaaaaaaa-0000-0000-0000-000000000022', rhe.id('l1'))$q$, 'déjà été validé');
select rhe.refus('Léa ne supprime pas le temps de Chloé', $q$select public.rh_supprimer_temps('aaaaaaaa-0000-0000-0000-000000000022', rhe.id('c1'))$q$, 'propres temps');
select rhe.passe('Chloé supprime son brouillon jamais validé', $q$select public.rh_supprimer_temps('aaaaaaaa-0000-0000-0000-000000000023', rhe.id('c1'))$q$);
select rhe.refus('un temps soumis ne se supprime pas', $q$select public.rh_supprimer_temps('11111111-1111-1111-1111-111111111111', rhe.id('m1'))$q$, 'brouillon');
reset role;
-- Historique : jamais écrit directement, même par la clé secrète ou le tableau de bord.
set role service_role;
select rhe.refus('clé secrète : modifier l''historique refusé', $q$update public.temps set historique = historique || '[{"action":"validation"}]' where id = rhe.id('l1')$q$, 'Historique');
select rhe.refus('clé secrète : changer un statut sans passer par l''application refusé', $q$update public.temps set statut = 'soumis' where id = rhe.id('l1')$q$, 'application');
select rhe.refus('clé secrète : poser un valideur à la main refusé', $q$update public.temps set valide_par = '11111111-1111-1111-1111-111111111111' where id = rhe.id('l1')$q$, 'base seulement');
select rhe.refus('clé secrète : changer le collaborateur d''un temps refusé', $q$update public.temps set collaborateur_id = '22222222-2222-2222-2222-222222222223' where id = rhe.id('l1')$q$, 'ne changent pas');
reset role;
select rhe.refus('tableau de bord : effacer un événement refusé', $q$update public.temps set historique = historique - 0 where id = rhe.id('l1')$q$, 'Historique');

-- Temps de l'admin seul : soumis, jamais auto-validé ; attestation distincte.
update public.collaborateurs set taux_horaire = taux_horaire where false;
insert into public.collaborateurs (id, nom, prenom, email, taux_horaire) values ('22222222-2222-2222-2222-2222222222aa', 'Admin', 'Seul', 'admin-seul@exemple.invalid', 0);
update public.profiles set collaborateur_id = '22222222-2222-2222-2222-2222222222aa' where id = '11111111-1111-1111-1111-111111111111';
set role service_role;
select rhe.passe('l''admin saisit et soumet ses propres temps', $q$insert into rhe.ids select 'adm', public.rh_enregistrer_temps('11111111-1111-1111-1111-111111111111', null, '22222222-2222-2222-2222-2222222222aa', rhe.id('projet1'), rhe.aujourdhui(), 6, null, null);
  select public.rh_changer_statut_temps('11111111-1111-1111-1111-111111111111', array[rhe.id('adm')], 'soumettre', null)$q$);
select rhe.refus('l''admin ne valide pas ses propres temps', $q$select public.rh_changer_statut_temps('11111111-1111-1111-1111-111111111111', array[rhe.id('adm')], 'valider', null)$q$, 'propres temps');
select rhe.passe('attestation de l''intéressé (information distincte)', $q$select public.rh_changer_statut_temps('11111111-1111-1111-1111-111111111111', array[rhe.id('adm')], 'attester', 'Travail seul ce jour')$q$);
select rhe.refus('un autre ne peut pas attester à la place de l''intéressé', $q$select public.rh_changer_statut_temps('aaaaaaaa-0000-0000-0000-000000000021', array[rhe.id('adm')], 'attester', 'x')$q$, 'collaborateur concerné');
reset role;
select rhe.ok('attestation : statut toujours « soumis », aucun valideur, événement distinct',
  (select statut = 'soumis' and valide_par is null and historique -> -1 ->> 'action' = 'attestation_interesse' from public.temps where id = rhe.id('adm')));
update public.profiles set collaborateur_id = null where id = '11111111-1111-1111-1111-111111111111';

-- ===================== Facturation (préparation Finance) =====================
insert into public.clients (id, nom) values ('33333333-3333-3333-3333-3333333333f1', 'Client facturation essai');
insert into public.factures (id, client_id) values ('44444444-4444-4444-4444-4444444444f1', '33333333-3333-3333-3333-3333333333f1');
set role service_role;
select rhe.refus('rattacher une facture à un temps non validé refusé', $q$update public.temps set facture_id = '44444444-4444-4444-4444-4444444444f1' where id = rhe.id('adm')$q$, 'validé');
select rhe.passe('rattacher une facture à un temps validé (module Finance, clé secrète)', $q$update public.temps set facture_id = '44444444-4444-4444-4444-4444444444f1' where id = rhe.id('m1')$q$);
select rhe.refus('temps facturé : modification refusée', $q$update public.temps set commentaire = 'x' where id = rhe.id('m1')$q$, 'facturé');
select rhe.refus('temps facturé : changer de facture refusé', $q$update public.temps set facture_id = null where id = rhe.id('m1')$q$, 'facturé');
select rhe.refus('temps facturé : réouverture refusée', $q$select public.rh_changer_statut_temps('11111111-1111-1111-1111-111111111111', array[rhe.id('m1')], 'rouvrir', 'motif')$q$, 'facturé');
select rhe.refus('temps facturé : suppression refusée', $q$delete from public.temps where id = rhe.id('m1')$q$, 'facturé');
reset role;
select rhe.refus('toute facture : suppression refusée, même par le tableau de bord', $q$delete from public.factures where id = '44444444-4444-4444-4444-4444444444f1'$q$, 'ne se supprime jamais');
insert into public.factures (id, client_id) values ('44444444-4444-4444-4444-4444444444f2', '33333333-3333-3333-3333-3333333333f1');
select rhe.refus('facture vide (sans temps ni relance) : suppression refusée aussi', $q$delete from public.factures where id = '44444444-4444-4444-4444-4444444444f2'$q$, 'ne se supprime jamais');

-- ===================== Fiches : hiérarchie, départs, suppressions =====================
select rhe.refus('être son propre manager : refusé en base', $q$update public.collaborateurs set manager_id = id where id = '22222222-2222-2222-2222-222222222222'$q$, 'son propre manager');
select rhe.refus('boucle A → B → A refusée', $q$update public.collaborateurs set manager_id = '22222222-2222-2222-2222-222222222221' where id = '22222222-2222-2222-2222-222222222222'$q$, 'boucle');
update public.collaborateurs set manager_id = '22222222-2222-2222-2222-222222222224' where id = '22222222-2222-2222-2222-222222222222';
select rhe.refus('boucle à trois niveaux refusée', $q$update public.collaborateurs set manager_id = '22222222-2222-2222-2222-222222222221' where id = '22222222-2222-2222-2222-222222222224'$q$, 'boucle');
update public.collaborateurs set manager_id = null where id = '22222222-2222-2222-2222-222222222222';
select rhe.refus('taux horaire négatif refusé', $q$update public.collaborateurs set taux_horaire = -1 where id = '22222222-2222-2222-2222-222222222224'$q$, 'collaborateurs_taux_positif');
select rhe.refus('date de sortie avant des temps enregistrés refusée', $q$update public.collaborateurs set date_sortie = rhe.aujourdhui() - 10 where id = '22222222-2222-2222-2222-222222222221'$q$, 'temps sont enregistrés');
select rhe.passe('date de sortie de Chloé à hier', $q$update public.collaborateurs set date_sortie = rhe.aujourdhui() - 1 where id = '22222222-2222-2222-2222-222222222223'$q$);
select rhe.ok('date de sortie : le compte de Chloé n''est ni révoqué ni modifié',
  (select count(*) = 1 from auth.users where id = 'aaaaaaaa-0000-0000-0000-000000000023')
  and (select role = 'collaborateur' and collaborateur_id = '22222222-2222-2222-2222-222222222223' from public.profiles where id = 'aaaaaaaa-0000-0000-0000-000000000023'));
set role service_role;
select rhe.refus('après la sortie : saisie pour aujourd''hui refusée', $q$select public.rh_enregistrer_temps('aaaaaaaa-0000-0000-0000-000000000023', null, '22222222-2222-2222-2222-222222222223', rhe.id('projet1'), rhe.aujourdhui(), 1, null, null)$q$, 'quitté');
select rhe.passe('après la sortie : régularisation d''une journée antérieure acceptée', $q$select public.rh_enregistrer_temps('aaaaaaaa-0000-0000-0000-000000000023', null, '22222222-2222-2222-2222-222222222223', rhe.id('projet1'), rhe.aujourdhui() - 2, 1, 'régularisation', null)$q$);
reset role;
select rhe.refus('manager sorti : ne reçoit pas de nouvelle équipe', $q$update public.collaborateurs set manager_id = '22222222-2222-2222-2222-222222222223' where id = '22222222-2222-2222-2222-222222222224'$q$, 'quitté');
update public.collaborateurs set date_sortie = null where id = '22222222-2222-2222-2222-222222222223';
-- Suppressions (même avec les droits les plus élevés : tableau de bord).
select rhe.refus('fiche avec temps : suppression refusée', $q$delete from public.collaborateurs where id = '22222222-2222-2222-2222-222222222221'$q$, 'des temps');
insert into public.collaborateurs (id, nom, taux_horaire) values ('22222222-2222-2222-2222-2222222222c1', 'Conge', 0),
  ('22222222-2222-2222-2222-2222222222c2', 'Frais', 0), ('22222222-2222-2222-2222-2222222222c3', 'Valideur', 0),
  ('22222222-2222-2222-2222-2222222222c4', 'Libre', 0), ('22222222-2222-2222-2222-2222222222c5', 'Chef', 0);
insert into public.conges (collaborateur_id, date_debut, date_fin) values ('22222222-2222-2222-2222-2222222222c1', '2026-11-02', '2026-11-03');
insert into public.notes_de_frais (collaborateur_id, montant) values ('22222222-2222-2222-2222-2222222222c2', 12.5);
insert into public.conges (collaborateur_id, date_debut, date_fin, statut, valide_par) values ('22222222-2222-2222-2222-2222222222c4', '2026-11-02', '2026-11-03', 'validee', '22222222-2222-2222-2222-2222222222c3');
select rhe.refus('fiche avec congés : suppression refusée', $q$delete from public.collaborateurs where id = '22222222-2222-2222-2222-2222222222c1'$q$, 'des congés');
select rhe.refus('fiche avec notes de frais : suppression refusée', $q$delete from public.collaborateurs where id = '22222222-2222-2222-2222-2222222222c2'$q$, 'notes de frais');
select rhe.refus('fiche ayant validé un congé : suppression refusée (trace du valideur)', $q$delete from public.collaborateurs where id = '22222222-2222-2222-2222-2222222222c3'$q$, 'validés');
select rhe.refus('fiche rattachée à un compte : suppression refusée', $q$delete from public.collaborateurs where id = '22222222-2222-2222-2222-222222222224'$q$, 'compte rattaché');
update public.collaborateurs set manager_id = '22222222-2222-2222-2222-2222222222c5' where id = '22222222-2222-2222-2222-2222222222c2';
select rhe.refus('fiche qui manage quelqu''un : suppression refusée', $q$delete from public.collaborateurs where id = '22222222-2222-2222-2222-2222222222c5'$q$, 'équipe');
delete from public.conges where collaborateur_id = '22222222-2222-2222-2222-2222222222c4';
select rhe.passe('contrôle positif : fiche sans aucune pièce ni lien supprimable', $q$delete from public.collaborateurs where id = '22222222-2222-2222-2222-2222222222c4'$q$);
select rhe.ok('congés, notes de frais et validations toujours présents', (select count(*) = 1 from public.conges) and (select count(*) = 1 from public.notes_de_frais));
select rhe.refus('projet avec temps : suppression refusée', $q$delete from public.projets where id = rhe.id('projet1')$q$, 'temps enregistrés');
select rhe.refus('client lié à un projet : suppression refusée', $q$delete from public.clients where id = (select client_id from public.projets where id = rhe.id('projet1'))$q$, 'lié');
select rhe.refus('client lié à une facture : suppression refusée', $q$delete from public.clients where id = '33333333-3333-3333-3333-3333333333f1'$q$, 'lié');
select rhe.passe('contrôle positif : projet interne sans temps supprimable par l''admin', $q$delete from public.projets where id = rhe.id('interne')$q$);
-- Révocation d'un compte : ses temps et leur historique restent.
delete from auth.users where id = 'aaaaaaaa-0000-0000-0000-000000000022';
select rhe.ok('compte de Léa révoqué : ses temps, auteurs et historique conservés',
  (select count(*) = 3 and bool_and(collaborateur_id = '22222222-2222-2222-2222-222222222221') from public.temps where saisi_par = 'aaaaaaaa-0000-0000-0000-000000000022')
  and (select saisi_par_nom = 'Léa Moreau' and jsonb_array_length(historique) = 4 from public.temps where id = rhe.id('l1')));
select rhe.ok('fiche de Léa conservée (révocation ≠ départ, date de sortie vide)',
  (select date_sortie is null from public.collaborateurs where id = '22222222-2222-2222-2222-222222222221'));

-- ===================== Lien avec le Commercial =====================
select rhe.ok('projets issus de devis : un seul par devis (index en place)',
  (select count(*) = 1 from pg_indexes where indexname = 'projets_un_par_devis'));
insert into public.prospects (id, nom, societe, adresse, code_postal, ville, pays) values
  ('cccccccc-0000-0000-0000-0000000000a9', 'Prospect RH', 'RH SARL', '1 rue', '97200', 'Fort-de-France', 'MQ');
insert into public.devis (id, prospect_id) values ('dddddddd-0000-0000-0000-0000000000a9', 'cccccccc-0000-0000-0000-0000000000a9');
select rhe.refus('projet rattaché à un devis brouillon (non accepté) : refusé, même par le tableau de bord',
  $q$insert into public.projets (nom, devis_id) values ('Pirate', 'dddddddd-0000-0000-0000-0000000000a9')$q$, 'acceptation');
select rhe.ok('aucun second déclencheur de création de projet (seul l''automatisme Commercial insère des projets liés)',
  (select count(*) = 0 from pg_proc where prosrc ilike '%insert into public.projets%' and proname not in ('devis_apres_modification')));

select n || '. [' || case when ok then 'OK ' else 'ÉCHEC' end || '] ' || libelle || coalesce('  (' || left(detail, 160) || ')', '') from rhe.resultats order by n;
select 'BILAN : ' || count(*) filter (where ok) || '/' || count(*) || ' contrôles réussis' from rhe.resultats;
