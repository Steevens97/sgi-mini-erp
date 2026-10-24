-- Tests du module Absences et notes de frais sur la base d'ESSAI locale (jamais Supabase).
-- Usage : tests-reels/simulation/rejouer.sh tests-reels/simulation/tests_absences.sql
--         puis : select count(*) filter (where ok), count(*) from abse.resultats;
-- Les dépôts de justificatifs sont simulés par des lignes storage.objects (le contenu des fichiers est contrôlé par
-- le serveur, testé à part : tests_justificatifs.mts et le parcours navigateur).
\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
create schema abse;
create table abse.resultats (n serial, libelle text, ok boolean, detail text);
grant usage on schema abse to authenticated, anon, service_role;
grant all on all tables in schema abse to authenticated, anon, service_role;
grant usage on all sequences in schema abse to authenticated, anon, service_role;
create function abse.ok(p_libelle text, p_ok boolean, p_detail text default null) returns void language sql as $$
  insert into abse.resultats (libelle, ok, detail) values (p_libelle, coalesce(p_ok, false), p_detail);
$$;
-- Refus attendu ; p_motif : extrait du message (ou message EXACT si p_exact).
create function abse.refus(p_libelle text, p_sql text, p_motif text default null, p_exact boolean default false)
returns void language plpgsql as $$
begin
  execute p_sql;
  insert into abse.resultats (libelle, ok, detail) values (p_libelle, false, 'accepté alors qu''il devait être refusé');
exception when others then
  insert into abse.resultats (libelle, ok, detail)
  values (p_libelle, p_motif is null or (p_exact and sqlerrm = p_motif) or (not p_exact and sqlerrm ilike '%' || p_motif || '%'), sqlerrm);
end $$;
create function abse.passe(p_libelle text, p_sql text) returns void language plpgsql as $$
begin
  execute p_sql;
  insert into abse.resultats (libelle, ok, detail) values (p_libelle, true, null);
exception when others then
  insert into abse.resultats (libelle, ok, detail) values (p_libelle, false, 'refusé : ' || sqlerrm);
end $$;
create function abse.qui(p_user uuid, p_session uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated', 'session_id', p_session)::text, false);
$$;
create function abse.j(n integer) returns date language sql as $$ select (now() at time zone 'America/Martinique')::date + n $$;
create table abse.v (cle text primary key, val text);
create function abse.get(p text) returns text language sql as $$ select val from abse.v where cle = p $$;
create function abse.put(p text, v text) returns void language sql as $$
  insert into abse.v values (p, v) on conflict (cle) do update set val = excluded.val $$;
-- Dépôt simulé dans le bucket (comme le ferait le lien signé) ; renvoie le chemin.
create function abse.depot(p_collab uuid, p_ext text, p_type text, p_taille bigint, p_age interval default '0') returns text
language plpgsql as $$
declare v_chemin text := p_collab || '/' || gen_random_uuid() || '.' || p_ext;
begin
  insert into storage.objects (bucket_id, name, metadata, created_at)
  values ('justificatifs', v_chemin, jsonb_build_object('size', p_taille, 'mimetype', p_type), now() - p_age);
  return v_chemin;
end $$;
create function abse.solde(p uuid) returns numeric language sql as $$ select solde_conges from public.collaborateurs where id = p $$;
create function abse.rtt(p uuid) returns numeric language sql as $$ select solde_rtt from public.collaborateurs where id = p $$;
-- Même définition que la colonne droits_rtt_renseignes de la vue (la vue elle-même exige une session utilisateur).
create function abse.rtt_renseignes(p uuid) returns boolean language sql as $$
  select exists (select 1 from public.collaborateurs c, jsonb_array_elements(c.historique_soldes) e
                  where c.id = p and e ->> 'type' = 'rtt' and e ->> 'action' = 'ajustement') $$;
grant execute on all functions in schema abse to authenticated, anon, service_role;
grant all on abse.v to authenticated, service_role;

\set ADMIN '\'11111111-1111-1111-1111-111111111111\''
\set M '\'aaaaaaaa-0000-0000-0000-000000000041\''
\set L '\'aaaaaaaa-0000-0000-0000-000000000042\''
\set N '\'aaaaaaaa-0000-0000-0000-000000000043\''
\set K '\'aaaaaaaa-0000-0000-0000-000000000044\''
\set H '\'aaaaaaaa-0000-0000-0000-000000000045\''
\set O '\'aaaaaaaa-0000-0000-0000-000000000046\''
\set P '\'aaaaaaaa-0000-0000-0000-000000000047\''
\set B '\'aaaaaaaa-0000-0000-0000-000000000048\''
\set FDUB '\'22222222-2222-2222-2222-222222222222\''
\set FLEA '\'22222222-2222-2222-2222-222222222221\''
\set FNGU '\'22222222-2222-2222-2222-222222222223\''
\set FADM '\'22222222-2222-2222-2222-2222222222fa\''
\set FKAR '\'22222222-2222-2222-2222-2222222222c1\''
\set FHUG '\'22222222-2222-2222-2222-2222222222c2\''
\set FJET '\'22222222-2222-2222-2222-2222222222e1\''
\set SL '\'bbbbbbbb-0000-0000-0000-000000000042\''

-- ===================== Comptes et fiches de TEST (base locale) =====================
select abse.ok('soldes existants : congés payés inchangés (25), RTT à 0, 2 événements initiaux par fiche',
  (select bool_and(solde_conges = 25 and solde_rtt = 0 and jsonb_array_length(historique_soldes) = 2
                   and (historique_soldes -> 0 ->> 'apres')::numeric = 25 and historique_soldes -> 0 ->> 'action' = 'initial'
                   and historique_soldes -> 1 ->> 'type' = 'rtt' and historique_soldes -> 1 ->> 'motif' like 'Droits RTT non renseignés%')
     from public.collaborateurs) and (select count(*) = 3 from public.collaborateurs));
insert into public.collaborateurs (id, nom, prenom, email, poste, taux_horaire) values
  (:FADM, 'Admin', 'Sgi', 'sgi-fiche@exemple.fr', 'Gérant', 0),
  (:FKAR, 'Petit', 'Karim', 'karim@exemple.fr', 'Manager', 0),
  (:FHUG, 'Martin', 'Hugo', 'hugo@exemple.fr', 'Consultant', 0),
  (:FJET, 'Jetable-Absences', 'J', 'jetable-abs@exemple.invalid', 'Essai', 0);
update public.profiles set collaborateur_id = :FADM where id = :ADMIN;
insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000041', 'bruno-abs@exemple.invalid'),
  ('aaaaaaaa-0000-0000-0000-000000000042', 'lea-abs@exemple.invalid'),
  ('aaaaaaaa-0000-0000-0000-000000000043', 'chloe-abs@exemple.invalid'),
  ('aaaaaaaa-0000-0000-0000-000000000044', 'karim-abs@exemple.invalid'),
  ('aaaaaaaa-0000-0000-0000-000000000045', 'hugo-abs@exemple.invalid'),
  ('aaaaaaaa-0000-0000-0000-000000000046', 'orphelin-abs@exemple.invalid'),
  ('aaaaaaaa-0000-0000-0000-000000000047', 'provisoire-abs@exemple.invalid'),
  ('aaaaaaaa-0000-0000-0000-000000000048', 'banni-abs@exemple.invalid');
update public.profiles set role = 'manager', collaborateur_id = :FDUB where id = :M;
update public.profiles set collaborateur_id = :FLEA where id = :L;
update public.profiles set collaborateur_id = :FNGU where id = :N;
update public.profiles set role = 'manager', collaborateur_id = :FKAR where id = :K;
update public.profiles set collaborateur_id = :FHUG where id = :H;
update public.profiles set role = 'admin' where id = :P;
update auth.users set raw_app_meta_data = '{"doit_changer_mot_de_passe": true}' where id = :P;
update public.profiles set collaborateur_id = :FJET where id = :B;
update auth.users set banned_until = now() + interval '1 day' where id = :B;
insert into auth.sessions (id, user_id) values
  ('bbbbbbbb-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111'),
  ('bbbbbbbb-0000-0000-0000-000000000041', 'aaaaaaaa-0000-0000-0000-000000000041'),
  ('bbbbbbbb-0000-0000-0000-000000000042', 'aaaaaaaa-0000-0000-0000-000000000042'),
  ('bbbbbbbb-0000-0000-0000-000000000043', 'aaaaaaaa-0000-0000-0000-000000000043'),
  ('bbbbbbbb-0000-0000-0000-000000000044', 'aaaaaaaa-0000-0000-0000-000000000044'),
  ('bbbbbbbb-0000-0000-0000-000000000047', 'aaaaaaaa-0000-0000-0000-000000000047');

select abse.ok('nouvelle fiche : congés payés à la valeur de création (défaut 25 de la table), RTT 0 non renseignés',
  (select solde_conges = 25 and solde_rtt = 0 and jsonb_array_length(historique_soldes) = 2
          and historique_soldes -> 0 ->> 'motif' = 'Solde à la création de la fiche.'
     from public.collaborateurs where id = :FHUG));
select abse.refus('fiche créée avec un solde RTT : refusée',
  $q$insert into public.collaborateurs (nom, solde_rtt) values ('X', 2)$q$,
  'Une nouvelle fiche démarre avec un solde RTT à 0 (droits non renseignés) ; renseignez-le ensuite par un ajustement motivé.', true);
select abse.refus('clé secrète : solde modifié directement, refusé',
  $q$update public.collaborateurs set solde_conges = 30 where id = '22222222-2222-2222-2222-222222222221'$q$,
  'Soldes de congés : modification directe interdite ; utilisez un ajustement motivé (administrateur).', true);
select abse.refus('clé secrète : historique des soldes effacé, refusé',
  $q$update public.collaborateurs set historique_soldes = '[]' where id = '22222222-2222-2222-2222-222222222221'$q$,
  'Historique des soldes : alimenté par la base seulement, ni modifiable ni effaçable.', true);
select abse.passe('modification ordinaire d''une fiche (poste) toujours possible',
  $q$update public.collaborateurs set poste = 'Consultante senior' where id = '22222222-2222-2222-2222-222222222221'$q$);

-- ===================== Confidentialité : lectures avec les jetons =====================
set role authenticated;
select abse.qui(:L, 'bbbbbbbb-0000-0000-0000-000000000042');
select abse.refus('collaboratrice : solde_conges illisible dans les fiches', $q$select solde_conges from public.collaborateurs$q$, 'permission denied');
select abse.refus('collaboratrice : select=* des fiches refusé', $q$select * from public.collaborateurs$q$, 'permission denied');
select abse.refus('collaboratrice : filtre sur solde_conges refusé', $q$select id from public.collaborateurs where solde_conges > 0$q$, 'permission denied');
select abse.refus('collaboratrice : historique_soldes illisible', $q$select historique_soldes from public.collaborateurs$q$, 'permission denied');
select abse.ok('collaboratrice : vue des soldes = sa seule fiche',
  (select array_agg(id::text) = array['22222222-2222-2222-2222-222222222221'] from public.absences_soldes));
select abse.passe('collaboratrice : lectures existantes des fiches (nom, date de sortie) inchangées',
  $q$select nom, prenom, manager_id, date_sortie from public.collaborateurs$q$);
select abse.refus('collaboratrice : création directe d''un congé refusée',
  $q$insert into public.conges (collaborateur_id, date_debut, date_fin) values ('22222222-2222-2222-2222-222222222221', current_date + 30, current_date + 30)$q$,
  'permission denied');
select abse.refus('collaboratrice : fonction de service inaccessible',
  $q$select public.abs_demander_conge('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', 'rtt', current_date + 30, current_date + 30, false, false, 1, null, null)$q$,
  'permission denied');
select abse.qui(:M, 'bbbbbbbb-0000-0000-0000-000000000041');
select abse.refus('manager : lecture de solde_conges fermée (ouverte jusqu''ici à tous les managers)',
  $q$select nom, solde_conges from public.collaborateurs$q$, 'permission denied');
select abse.ok('manager : vue des soldes = lui et son équipe directe (Moreau, Nguyen), rien d''autre',
  (select array_agg(nom order by nom) = array['Dubois', 'Moreau', 'Nguyen'] from public.absences_soldes));
select abse.qui(:K, 'bbbbbbbb-0000-0000-0000-000000000044');
select abse.ok('manager hors équipe : sa seule fiche', (select array_agg(nom) = array['Petit'] from public.absences_soldes));
select abse.qui(:ADMIN, 'bbbbbbbb-0000-0000-0000-000000000001');
select abse.ok('admin : vue globale des soldes', (select count(*) = 7 from public.absences_soldes));
select abse.ok('admin : droits RTT « non renseignés » sur toutes les fiches au départ',
  (select bool_and(not droits_rtt_renseignes) from public.absences_soldes));
select abse.refus('admin (jeton) : solde_conges non modifiable directement',
  $q$update public.collaborateurs set solde_conges = 40 where id = '22222222-2222-2222-2222-222222222221'$q$, 'permission denied');
select abse.refus('admin (jeton) : création de fiche avec un solde refusée',
  $q$insert into public.collaborateurs (nom, taux_horaire, solde_conges) values ('X', 0, 40)$q$, 'permission denied');
select abse.passe('admin (jeton) : création de fiche de l''écran Utilisateurs (nom, prénom, email, poste, entrée, taux) possible',
  $q$insert into public.collaborateurs (nom, prenom, email, poste, date_entree, taux_horaire) values ('Compat-Utilisateurs', 'U', 'compat-abs@exemple.invalid', 'Essai', current_date, 1)$q$);
select abse.refus('admin (jeton) : décision directe sur un congé refusée',
  $q$update public.conges set statut = 'validee'$q$, 'permission denied');
select abse.qui(:P, 'bbbbbbbb-0000-0000-0000-000000000047');
select abse.ok('admin provisoire (mot de passe à changer) : aucune fiche, aucun solde', (select count(*) = 0 from public.absences_soldes));
reset role;
set role anon;
select abse.refus('visiteur : vue des soldes refusée', $q$select * from public.absences_soldes$q$, 'permission denied');
select abse.refus('visiteur : congés refusés', $q$select id from public.conges$q$, 'permission denied');
select abse.refus('visiteur : notes de frais refusées', $q$select id from public.notes_de_frais$q$, 'permission denied');
reset role;
delete from public.collaborateurs where nom = 'Compat-Utilisateurs';
select abse.ok('fonctions appelables avec un jeton : exactement les 4 fonctions d''identité',
  (select string_agg(p.proname, ', ' order by p.proname) = 'acces_actif, est_admin, mon_collaborateur_id, mon_role'
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f' and p.prorettype <> 'trigger'::regtype
      and has_function_privilege('authenticated', p.oid, 'execute')));

-- ===================== Demandes de congé =====================
select abse.put('c_lea', public.abs_demander_conge(:L, :FLEA, 'conges_payes', abse.j(20), abse.j(21), false, true, 1.5, '  Vacances  ', 'ignoré')::text);
select abse.ok('collaboratrice : demande de 1,5 jour (J+20 matin → J+21 midi), « demandée », tracée',
  (select statut = 'demandee' and demande_par = :L and demande_par_nom = 'lea-abs@exemple.invalid' and demande_le is not null
          and motif = 'Vacances' and motif_retroactif is null and not essai and jsonb_array_length(historique) = 1
          and historique -> 0 ->> 'action' = 'demande' and decide_par is null and solde_preleve is null
     from public.conges where id = abse.get('c_lea')::uuid));
select abse.refus('demande pour une autre personne (collaboratrice) : refusée',
  $q$select public.abs_demander_conge('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222223', 'rtt', current_date + 60, current_date + 60, false, false, 1, null, null)$q$,
  'Vous ne pouvez demander des congés que pour vous-même.', true);
select abse.refus('compte sans fiche rattachée : demande refusée',
  $q$select public.abs_demander_conge('aaaaaaaa-0000-0000-0000-000000000046', '22222222-2222-2222-2222-222222222221', 'rtt', current_date + 60, current_date + 60, false, false, 1, null, null)$q$,
  'Votre compte n''est rattaché à aucune fiche collaborateur : demande impossible.', true);
select abse.refus('compte provisoire (mot de passe à changer) : refusé',
  $q$select public.abs_demander_conge('aaaaaaaa-0000-0000-0000-000000000047', '22222222-2222-2222-2222-222222222221', 'rtt', current_date + 60, current_date + 60, false, false, 1, null, null)$q$,
  'Action RH réservée à un compte actif.', true);
select abse.refus('compte banni : refusé',
  $q$select public.abs_demander_conge('aaaaaaaa-0000-0000-0000-000000000048', '22222222-2222-2222-2222-2222222222e1', 'rtt', current_date + 60, current_date + 60, false, false, 1, null, null)$q$,
  'Action RH réservée à un compte actif.', true);
select abse.refus('un seul jour, début l''après-midi et fin à midi : refusé',
  $q$select public.abs_demander_conge('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', 'conges_payes', current_date + 60, current_date + 60, true, true, 0.5, null, null)$q$,
  'Demi-journées incohérentes : une absence d''un seul jour ne peut pas commencer l''après-midi et finir à midi.', true);
select abse.refus('0 jour : refusé',
  $q$select public.abs_demander_conge('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', 'conges_payes', current_date + 60, current_date + 60, false, false, 0, null, null)$q$,
  'Le nombre de jours doit être strictement positif.', true);
select abse.refus('jours négatifs : refusés',
  $q$select public.abs_demander_conge('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', 'conges_payes', current_date + 60, current_date + 60, false, false, -1, null, null)$q$,
  'Le nombre de jours doit être strictement positif.', true);
select abse.refus('0,25 jour (hors pas de 0,5) : refusé',
  $q$select public.abs_demander_conge('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', 'conges_payes', current_date + 60, current_date + 60, false, false, 0.25, null, null)$q$,
  'Le nombre de jours se saisit par demi-journée (pas de 0,5).', true);
select abse.refus('0,333 jour (la colonne arrondirait) : refusé',
  $q$select public.abs_demander_conge('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', 'conges_payes', current_date + 60, current_date + 60, false, false, 0.333, null, null)$q$,
  'Le nombre de jours se saisit par demi-journée (pas de 0,5).', true);
select abse.refus('3 jours sur une période de 2 jours : refusé (limite de la période)',
  $q$select public.abs_demander_conge('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', 'conges_payes', current_date + 60, current_date + 61, false, false, 3, null, null)$q$,
  'Le nombre de jours (3) dépasse la période demandée (2 jour(s) au plus, demi-journées comprises).', true);
select abse.refus('2 jours de J+60 après-midi à J+61 : refusé (1,5 au plus)',
  $q$select public.abs_demander_conge('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', 'conges_payes', current_date + 60, current_date + 61, true, false, 2, null, null)$q$,
  'Le nombre de jours (2) dépasse la période demandée (1,5 jour(s) au plus, demi-journées comprises).', true);
select abse.refus('demi-journée seule (0,5) sur une journée entière : la limite est un maximum, 0,5 accepté ; fin avant début refusée',
  $q$select public.abs_demander_conge('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', 'conges_payes', current_date + 61, current_date + 60, false, false, 1, null, null)$q$,
  'La date de fin précède la date de début.', true);
select abse.passe('nombre inférieur à la période (1 jour sur 2, jour non travaillé) : accepté (saisie manuelle)',
  $q$select abse.put('c_lea2', public.abs_demander_conge('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', 'sans_solde', current_date + 60, current_date + 61, false, false, 1, null, null)::text)$q$);
select abse.passe('J+70 après-midi → J+71 : 1,5 jour accepté',
  $q$select public.abs_demander_conge('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', 'sans_solde', current_date + 70, current_date + 71, true, false, 1.5, null, null)$q$);
select abse.passe('une seule demi-journée (J+75 après-midi) : 0,5 accepté',
  $q$select public.abs_demander_conge('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', 'sans_solde', current_date + 75, current_date + 75, true, false, 0.5, null, null)$q$);
-- Chevauchements à la demi-journée près.
select abse.passe('J+21 après-midi (la demande existante finit à midi) : acceptée',
  $q$select abse.put('c_lea3', public.abs_demander_conge('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', 'sans_solde', current_date + 21, current_date + 21, true, false, 0.5, null, null)::text)$q$);
select abse.refus('J+21 matin (chevauche J+20 → J+21 midi) : refusé',
  $q$select public.abs_demander_conge('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', 'rtt', current_date + 21, current_date + 21, false, true, 0.5, null, null)$q$,
  'Chevauchement : une demande en attente existe déjà du ' || to_char(abse.j(20), 'DD/MM/YYYY') || ' au ' || to_char(abse.j(21), 'DD/MM/YYYY') || ' (demi-journées comprises).', true);
select abse.refus('J+75 matin → J+75 après-midi chevauche la demi-journée J+75 après-midi : refusé',
  $q$select public.abs_demander_conge('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', 'rtt', current_date + 75, current_date + 75, false, false, 1, null, null)$q$,
  'Chevauchement');
select abse.passe('J+75 matin seul : accepté (l''après-midi est déjà demandé)',
  $q$select public.abs_demander_conge('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', 'sans_solde', current_date + 75, current_date + 75, false, true, 0.5, null, null)$q$);
-- Rétroactivité.
select abse.refus('collaboratrice : demande sur une date passée refusée',
  $q$select public.abs_demander_conge('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', 'conges_payes', current_date - 40, current_date - 40, false, false, 1, null, 'Oubli')$q$,
  'Une demande sur une date passée est réservée à l''administrateur (avec motif).', true);
select abse.refus('admin : demande rétroactive sans motif refusée',
  $q$select public.abs_demander_conge('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222221', 'conges_payes', current_date - 40, current_date - 40, false, false, 1, null, '  ')$q$,
  'Demande rétroactive : un motif est obligatoire.', true);
select abse.put('c_retro', public.abs_demander_conge(:ADMIN, :FLEA, 'conges_payes', abse.j(-40), abse.j(-40), false, false, 1, null, ' Régularisation papier ')::text);
select abse.ok('admin : demande rétroactive pour autrui, motif conservé, auteur tracé',
  (select motif_retroactif = 'Régularisation papier' and demande_par = :ADMIN and historique -> 0 ->> 'motif' = 'Régularisation papier'
          and (historique -> 0 ->> 'pour_collaborateur')::uuid = :FLEA
     from public.conges where id = abse.get('c_retro')::uuid));
-- Entrée, sortie.
update public.collaborateurs set date_sortie = abse.j(50) where id = :FNGU;
select abse.refus('absence après la date de sortie : refusée',
  $q$select public.abs_demander_conge('aaaaaaaa-0000-0000-0000-000000000043', '22222222-2222-2222-2222-222222222223', 'conges_payes', current_date + 49, current_date + 51, false, false, 2, null, null)$q$,
  'Absence refusée : le collaborateur quitte l''entreprise le ' || to_char(abse.j(50), 'DD/MM/YYYY') || ' ; aucune absence ne peut être posée après.', true);
select abse.passe('absence jusqu''au jour de sortie inclus : acceptée',
  $q$select abse.put('c_ngu', public.abs_demander_conge('aaaaaaaa-0000-0000-0000-000000000043', '22222222-2222-2222-2222-222222222223', 'conges_payes', current_date + 49, current_date + 50, false, false, 2, null, null)::text)$q$);
select abse.refus('date de sortie avancée avant une absence demandée : refusée',
  $q$update public.collaborateurs set date_sortie = current_date + 45 where id = '22222222-2222-2222-2222-222222222223'$q$,
  'Date de sortie refusée : une absence (demandée ou validée) court jusqu''au ' || to_char(abse.j(50), 'DD/MM/YYYY') || '.', true);
update public.collaborateurs set date_entree = abse.j(5) where id = :FHUG;
select abse.refus('absence avant la date d''entrée : refusée',
  $q$select public.abs_demander_conge('aaaaaaaa-0000-0000-0000-000000000045', '22222222-2222-2222-2222-2222222222c2', 'sans_solde', current_date + 3, current_date + 6, false, false, 1, null, null)$q$,
  'Absence refusée : elle commence avant l''entrée du collaborateur');
select abse.refus('type inconnu : refusé',
  $q$select public.abs_demander_conge('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', 'maladie', current_date + 90, current_date + 90, false, false, 1, null, null)$q$,
  'Type d''absence inconnu : congés payés, RTT ou sans solde.', true);
-- Écritures hors application.
select abse.refus('clé secrète : congé créé directement, refusé',
  $q$insert into public.conges (collaborateur_id, date_debut, date_fin, nb_jours) values ('22222222-2222-2222-2222-222222222221', current_date + 90, current_date + 90, 1)$q$,
  'Congés : écriture directe interdite ; passez par l''application.', true);
select abse.refus('clé secrète : statut changé directement, refusé',
  $q$update public.conges set statut = 'validee' where id = abse.get('c_lea')::uuid$q$,
  'Congés : écriture directe interdite ; passez par l''application.', true);
select abse.refus('contenu d''une demande modifié (même avec un contexte) : refusé',
  $q$select public.abs_contexte('11111111-1111-1111-1111-111111111111', 'decider_conge', null); update public.conges set nb_jours = 1 where id = abse.get('c_lea')::uuid$q$,
  'Le contenu d''une demande de congé ne se modifie pas : faites une nouvelle demande.', true);
select abse.refus('historique d''une demande modifié : refusé',
  $q$select public.abs_contexte('11111111-1111-1111-1111-111111111111', 'decider_conge', null); update public.conges set historique = '[]' where id = abse.get('c_lea')::uuid$q$,
  'Historique : alimenté par la base seulement, ni modifiable ni effaçable.', true);
select abse.refus('décision écrite directement (decide_par) : refusée',
  $q$select public.abs_contexte('11111111-1111-1111-1111-111111111111', 'decider_conge', null); update public.conges set decide_par = '11111111-1111-1111-1111-111111111111' where id = abse.get('c_lea')::uuid$q$,
  'La décision et le prélèvement sont enregistrés par la base seulement.', true);
select abse.refus('suppression d''une demande : refusée', $q$delete from public.conges where id = abse.get('c_lea')::uuid$q$,
  'Une demande de congé ne se supprime pas (historique conservé).', true);
select abse.refus('suppression d''une demande réelle avec l''opération de nettoyage : refusée',
  $q$select set_config('sgi.abs_operation', 'nettoyage_essais', true); delete from public.conges where id = abse.get('c_lea')::uuid$q$,
  'Une demande de congé ne se supprime pas (historique conservé).', true);

-- ===================== Décisions et soldes =====================
select abse.refus('la collaboratrice décide de sa propre demande : refusé',
  $q$select public.abs_decider_conge('aaaaaaaa-0000-0000-0000-000000000042', abse.get('c_lea')::uuid, 'valider', null)$q$,
  'Personne ne décide de ses propres congés (administrateur compris).', true);
select abse.refus('un collègue (sans équipe) décide : refusé',
  $q$select public.abs_decider_conge('aaaaaaaa-0000-0000-0000-000000000043', abse.get('c_lea')::uuid, 'valider', null)$q$,
  'Seul le responsable hiérarchique du collaborateur (ou l''administrateur) décide de cette demande.', true);
select abse.refus('un manager hors équipe décide : refusé',
  $q$select public.abs_decider_conge('aaaaaaaa-0000-0000-0000-000000000044', abse.get('c_lea')::uuid, 'valider', null)$q$,
  'Seul le responsable hiérarchique du collaborateur (ou l''administrateur) décide de cette demande.', true);
select abse.put('d1', public.abs_decider_conge(:M, abse.get('c_lea')::uuid, 'valider', null)::text);
select abse.ok('manager de l''équipe : validation, 1,5 jour prélevé une fois (25 → 23,5)',
  abse.solde(:FLEA) = 23.5 and (abse.get('d1')::jsonb ->> 'deja_decide')::boolean = false
  and (select statut = 'validee' and solde_preleve = 1.5 and valide_par = :FDUB and decide_par = :M
              and decide_par_nom = 'bruno-abs@exemple.invalid' and historique -> -1 ->> 'action' = 'validation'
         from public.conges where id = abse.get('c_lea')::uuid));
select abse.ok('historique des soldes : prélèvement 25 → 23,5, demande et auteur indiqués',
  (select e ->> 'type' = 'conges_payes' and (e ->> 'avant')::numeric = 25 and (e ->> 'apres')::numeric = 23.5
          and (e ->> 'jours')::numeric = 1.5 and e ->> 'conge' = abse.get('c_lea') and (e ->> 'auteur')::uuid = :M
     from (select historique_soldes -> -1 as e from public.collaborateurs where id = :FLEA) x));
select abse.put('d2', public.abs_decider_conge(:M, abse.get('c_lea')::uuid, 'valider', null)::text);
select abse.ok('deuxième validation (double clic) : sans effet, aucun second prélèvement',
  abse.solde(:FLEA) = 23.5 and (abse.get('d2')::jsonb ->> 'deja_decide')::boolean
  and (select jsonb_array_length(historique_soldes) = 3 from public.collaborateurs where id = :FLEA));
select abse.refus('congé validé ensuite refusé : impossible (ni annulation dans cette version)',
  $q$select public.abs_decider_conge('11111111-1111-1111-1111-111111111111', abse.get('c_lea')::uuid, 'refuser', 'Erreur')$q$,
  'Décision déjà prise (demande validée) : une demande validée ou refusée ne change plus.', true);
select abse.refus('refus sans motif : refusé',
  $q$select public.abs_decider_conge('aaaaaaaa-0000-0000-0000-000000000041', abse.get('c_lea3')::uuid, 'refuser', '  ')$q$,
  'Refus : un motif est obligatoire.', true);
select abse.passe('refus motivé', $q$select public.abs_decider_conge('aaaaaaaa-0000-0000-0000-000000000041', abse.get('c_lea3')::uuid, 'refuser', 'Réunion client')$q$);
select abse.ok('refus : motif enregistré, aucun prélèvement',
  abse.solde(:FLEA) = 23.5 and (select statut = 'refusee' and motif_decision = 'Réunion client' and solde_preleve is null
                                  from public.conges where id = abse.get('c_lea3')::uuid));
select abse.passe('une demande refusée ne bloque plus ses dates (J+21 après-midi redemandé)',
  $q$select public.abs_demander_conge('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', 'sans_solde', current_date + 21, current_date + 21, true, false, 0.5, null, null)$q$);
select abse.refus('refusé puis validé : impossible',
  $q$select public.abs_decider_conge('aaaaaaaa-0000-0000-0000-000000000041', abse.get('c_lea3')::uuid, 'valider', null)$q$,
  'Décision déjà prise (demande refusée) : une demande validée ou refusée ne change plus.', true);
select abse.passe('congé sans solde validé', $q$select public.abs_decider_conge('aaaaaaaa-0000-0000-0000-000000000041', abse.get('c_lea2')::uuid, 'valider', null)$q$);
select abse.ok('sans solde : aucun prélèvement (0), aucun événement de solde',
  abse.solde(:FLEA) = 23.5 and abse.rtt(:FLEA) = 0
  and (select solde_preleve = 0 from public.conges where id = abse.get('c_lea2')::uuid)
  and (select jsonb_array_length(historique_soldes) = 3 from public.collaborateurs where id = :FLEA));
-- RTT : droits non renseignés.
select abse.put('c_rtt', public.abs_demander_conge(:L, :FLEA, 'rtt', abse.j(80), abse.j(80), false, false, 1, null, null)::text);
select abse.refus('RTT sans droits renseignés : validation refusée, message explicite',
  $q$select public.abs_decider_conge('aaaaaaaa-0000-0000-0000-000000000041', abse.get('c_rtt')::uuid, 'valider', null)$q$,
  'Solde RTT insuffisant : 0 jour(s) disponible(s), 1 demandé(s) (droits RTT non renseignés). Validation refusée.', true);
select abse.ok('après le refus de validation : demande toujours « demandée »',
  (select statut = 'demandee' from public.conges where id = abse.get('c_rtt')::uuid));
select abse.refus('ajustement par un manager : refusé',
  $q$select public.abs_ajuster_solde('aaaaaaaa-0000-0000-0000-000000000041', '22222222-2222-2222-2222-222222222221', 'rtt', 0, 5, 'Droits')$q$,
  'Ajustement des soldes réservé à l''administrateur.', true);
select abse.refus('ajustement sans motif : refusé',
  $q$select public.abs_ajuster_solde('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222221', 'rtt', 0, 5, ' ')$q$,
  'Ajustement : un motif est obligatoire.', true);
select abse.refus('ajustement sur une valeur affichée périmée : refusé',
  $q$select public.abs_ajuster_solde('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222221', 'conges_payes', 25, 30, 'Report')$q$,
  'Le solde a changé entre-temps (23,5 au lieu de 25) : rechargez la page avant d''ajuster.', true);
select abse.refus('solde négatif : refusé',
  $q$select public.abs_ajuster_solde('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222221', 'rtt', 0, -1, 'Erreur')$q$,
  'Un solde est positif ou nul.', true);
select abse.refus('solde à 3 décimales : refusé',
  $q$select public.abs_ajuster_solde('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222221', 'rtt', 0, 1.555, 'Erreur')$q$,
  'Solde : au plus 2 décimales et moins de 10 000 jours.', true);
select abse.refus('admin : ajustement de son propre solde refusé',
  $q$select public.abs_ajuster_solde('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-2222222222fa', 'conges_payes', 25, 40, 'Pour moi')$q$,
  'Vous ne pouvez pas ajuster votre propre solde.', true);
select abse.passe('admin : droits RTT renseignés (0 → 3), motivés',
  $q$select public.abs_ajuster_solde('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222221', 'rtt', 0, 3, 'Accord RTT 2026')$q$);
select abse.ok('ajustement tracé (avant, après, auteur, motif) ; droits RTT renseignés dans la vue',
  abse.rtt(:FLEA) = 3
  and (select e ->> 'action' = 'ajustement' and e ->> 'type' = 'rtt' and (e ->> 'avant')::numeric = 0 and (e ->> 'apres')::numeric = 3
              and e ->> 'motif' = 'Accord RTT 2026' and (e ->> 'auteur')::uuid = :ADMIN and e ->> 'auteur_nom' = 'sgi@gmx.fr'
         from (select historique_soldes -> -1 as e from public.collaborateurs where id = :FLEA) x)
  and abse.rtt_renseignes(:FLEA));
select abse.passe('RTT validée après renseignement des droits', $q$select public.abs_decider_conge('aaaaaaaa-0000-0000-0000-000000000041', abse.get('c_rtt')::uuid, 'valider', null)$q$);
select abse.ok('RTT : 3 → 2 ; congés payés inchangés (23,5) : jamais de prélèvement croisé', abse.rtt(:FLEA) = 2 and abse.solde(:FLEA) = 23.5);
select abse.passe('droits RTT renseignés à 0 (valeur identique) : événement inscrit',
  $q$select public.abs_ajuster_solde('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-2222222222c2', 'rtt', 0, 0, 'Pas de RTT pour ce contrat')$q$);
select abse.ok('droits RTT à 0 désormais « renseignés » (distinct de « non renseignés »)',
  abse.rtt_renseignes(:FHUG) and abse.rtt(:FHUG) = 0);
set role authenticated;
select abse.qui(:ADMIN, 'bbbbbbbb-0000-0000-0000-000000000001');
select abse.ok('vue des soldes (jeton admin) : droits RTT renseignés pour Léa et Hugo seulement',
  (select array_agg(nom order by nom) = array['Martin', 'Moreau'] from public.absences_soldes where droits_rtt_renseignes));
reset role;
-- Solde insuffisant (congés payés).
select abse.put('c_long', public.abs_demander_conge(:L, :FLEA, 'conges_payes', abse.j(100), abse.j(130), false, false, 24, null, null)::text);
select abse.refus('congés payés au-delà du solde (24 > 23,5) : validation refusée',
  $q$select public.abs_decider_conge('aaaaaaaa-0000-0000-0000-000000000041', abse.get('c_long')::uuid, 'valider', null)$q$,
  'Solde de congés payés insuffisant : 23,5 jour(s) disponible(s), 24 demandé(s). Validation refusée.', true);
-- Deux demandes distinctes : la seconde ne passe pas sous zéro.
select public.abs_ajuster_solde(:ADMIN, :FNGU, 'conges_payes', 25, 2.5, 'Solde réel transmis');
select abse.put('c_n1', public.abs_demander_conge(:N, :FNGU, 'conges_payes', abse.j(30), abse.j(31), false, false, 2, null, null)::text);
select public.abs_decider_conge(:M, abse.get('c_n1')::uuid, 'valider', null);
select abse.refus('deux demandes successives : la seconde (2 jours sur 0,5 restant) est refusée',
  $q$select public.abs_decider_conge('aaaaaaaa-0000-0000-0000-000000000041', abse.get('c_ngu')::uuid, 'valider', null)$q$,
  'Solde de congés payés insuffisant : 0,5 jour(s) disponible(s), 2 demandé(s). Validation refusée.', true);
select abse.ok('solde jamais négatif (0,5)', abse.solde(:FNGU) = 0.5);
-- Ses propres congés : jamais, même l'administrateur.
select abse.put('c_adm', public.abs_demander_conge(:ADMIN, :FADM, 'conges_payes', abse.j(40), abse.j(40), false, false, 1, null, null)::text);
select abse.refus('admin : validation de son propre congé refusée',
  $q$select public.abs_decider_conge('11111111-1111-1111-1111-111111111111', abse.get('c_adm')::uuid, 'valider', null)$q$,
  'Personne ne décide de ses propres congés (administrateur compris).', true);
select abse.refus('admin : refus de son propre congé refusé aussi',
  $q$select public.abs_decider_conge('11111111-1111-1111-1111-111111111111', abse.get('c_adm')::uuid, 'refuser', 'Test')$q$,
  'Personne ne décide de ses propres congés (administrateur compris).', true);
select abse.refus('un manager sans lien hiérarchique avec l''admin : refusé',
  $q$select public.abs_decider_conge('aaaaaaaa-0000-0000-0000-000000000041', abse.get('c_adm')::uuid, 'valider', null)$q$,
  'Seul le responsable hiérarchique du collaborateur (ou l''administrateur) décide de cette demande.', true);
select abse.ok('congé de l''admin : reste « demandée », aucun compte fictif', (select statut = 'demandee' from public.conges where id = abse.get('c_adm')::uuid));
select abse.put('c_dub', public.abs_demander_conge(:M, :FDUB, 'conges_payes', abse.j(40), abse.j(40), false, false, 1, null, null)::text);
select abse.refus('manager : validation de son propre congé refusée',
  $q$select public.abs_decider_conge('aaaaaaaa-0000-0000-0000-000000000041', abse.get('c_dub')::uuid, 'valider', null)$q$,
  'Personne ne décide de ses propres congés (administrateur compris).', true);
select abse.passe('congé du manager validé par l''admin', $q$select public.abs_decider_conge('11111111-1111-1111-1111-111111111111', abse.get('c_dub')::uuid, 'valider', null)$q$);
select abse.refus('décision inconnue : refusée',
  $q$select public.abs_decider_conge('11111111-1111-1111-1111-111111111111', abse.get('c_adm')::uuid, 'annuler', null)$q$,
  'Décision inconnue : annuler.', true);
begin;
select public.abs_decider_conge(:ADMIN, abse.get('c_ngu')::uuid, 'refuser', 'Solde insuffisant');
select abse.ok('contexte remis à zéro après une fonction de service (même transaction)',
  coalesce(current_setting('sgi.abs_operation', true), '') = '' and coalesce(current_setting('sgi.abs_auteur', true), '') = ''
  and coalesce(current_setting('sgi.abs_evenement', true), '') = '');
commit;

-- Lectures des congés avec les jetons : soi, équipe directe, admin.
select abse.put('nb_conges', (select count(*)::text from public.conges));
set role authenticated;
select abse.qui(:L, 'bbbbbbbb-0000-0000-0000-000000000042');
select abse.ok('collaboratrice : ses seuls congés', (select bool_and(collaborateur_id = :FLEA) and count(*) > 0 from public.conges));
select abse.qui(:M, 'bbbbbbbb-0000-0000-0000-000000000041');
select abse.ok('manager : ses congés et ceux de son équipe, pas ceux de l''admin',
  (select bool_and(collaborateur_id in (:FDUB, :FLEA, :FNGU)) and count(*) filter (where collaborateur_id = :FADM) = 0
          and count(*) filter (where collaborateur_id = :FLEA) > 0 from public.conges));
select abse.qui(:K, 'bbbbbbbb-0000-0000-0000-000000000044');
select abse.ok('manager hors équipe : aucun congé de Léa', (select count(*) = 0 from public.conges where collaborateur_id = :FLEA));
select abse.qui(:ADMIN, 'bbbbbbbb-0000-0000-0000-000000000001');
select abse.ok('admin : tous les congés', (select count(*) = abse.get('nb_conges')::int from public.conges), (select count(*)::text from public.conges));
reset role;
delete from auth.sessions where id = :SL;
set role authenticated;
select abse.qui(:L, 'bbbbbbbb-0000-0000-0000-000000000042');
select abse.ok('ancienne session (déconnexion, révocation) : aucun congé, aucun solde',
  (select count(*) = 0 from public.conges) and (select count(*) = 0 from public.absences_soldes));
reset role;
insert into auth.sessions (id, user_id) values (:SL, :L);

-- ===================== Notes de frais et justificatifs =====================
select abse.put('f1', abse.depot(:FLEA, 'pdf', 'application/pdf', 2048));
select abse.put('n1', (public.abs_creer_note(:L, :FLEA, abse.j(-2), 42.5, 'repas', null, '  Déjeuner chantier  ', abse.get('f1'),
  'application/pdf', 2048, repeat('a', 64)) ->> 'id'));
select abse.ok('note créée : « soumise », objet nettoyé, justificatif rattaché, auteur tracé',
  (select statut = 'soumise' and objet = 'Déjeuner chantier' and justificatif_url = abse.get('f1') and justificatif_taille = 2048
          and justificatif_type = 'application/pdf' and justificatif_depose_le is not null and soumise_par = :L and not essai
          and historique -> 0 ->> 'action' = 'soumission' and historique -> 0 ->> 'justificatif_empreinte' = repeat('a', 64)
     from public.notes_de_frais where id = abse.get('n1')::uuid));
select abse.ok('même création rejouée (réponse perdue) : même note, aucun doublon',
  (public.abs_creer_note(:L, :FLEA, abse.j(-2), 42.5, 'repas', null, 'Déjeuner chantier', abse.get('f1'), 'application/pdf', 2048, repeat('a', 64))
     ->> 'id') = abse.get('n1') and (select count(*) = 1 from public.notes_de_frais));
select abse.refus('même fichier, empreinte différente : refusé',
  $q$select public.abs_creer_note('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', current_date - 2, 42.5, 'repas', null, 'X', abse.get('f1'), 'application/pdf', 2048, repeat('b', 64))$q$,
  'Justificatif déjà rattaché à une autre note de frais.', true);
select abse.refus('fichier du dossier de Léa pour la fiche de Nguyen (admin) : refusé',
  $q$select public.abs_creer_note('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222223', current_date - 2, 10, 'repas', null, 'X', abse.depot('22222222-2222-2222-2222-222222222221', 'pdf', 'application/pdf', 10), 'application/pdf', 10, repeat('c', 64))$q$,
  'Justificatif : emplacement non conforme (dossier du collaborateur concerné uniquement).', true);
select abse.refus('chemin hors format (remontée de dossier) : refusé',
  $q$select public.abs_creer_note('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', current_date - 2, 10, 'repas', null, 'X', '22222222-2222-2222-2222-222222222221/../autre.pdf', 'application/pdf', 10, repeat('c', 64))$q$,
  'Justificatif : emplacement non conforme (dossier du collaborateur concerné uniquement).', true);
select abse.refus('type texte : refusé',
  $q$select public.abs_creer_note('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', current_date - 2, 10, 'repas', null, 'X', abse.depot('22222222-2222-2222-2222-222222222221', 'pdf', 'text/plain', 10), 'text/plain', 10, repeat('c', 64))$q$,
  'Justificatif : format refusé (PDF, JPEG ou PNG uniquement).', true);
select abse.refus('extension .png déclarée PDF : refusée',
  $q$select public.abs_creer_note('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', current_date - 2, 10, 'repas', null, 'X', abse.depot('22222222-2222-2222-2222-222222222221', 'png', 'application/pdf', 10), 'application/pdf', 10, repeat('c', 64))$q$,
  'Justificatif : extension et format incohérents.', true);
select abse.refus('fichier vide : refusé',
  $q$select public.abs_creer_note('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', current_date - 2, 10, 'repas', null, 'X', abse.depot('22222222-2222-2222-2222-222222222221', 'pdf', 'application/pdf', 0), 'application/pdf', 0, repeat('c', 64))$q$,
  'Justificatif : fichier vide ou de plus de 10 Mo.', true);
select abse.refus('10 Mo + 1 octet : refusé',
  $q$select public.abs_creer_note('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', current_date - 2, 10, 'repas', null, 'X', abse.depot('22222222-2222-2222-2222-222222222221', 'pdf', 'application/pdf', 10485761), 'application/pdf', 10485761, repeat('c', 64))$q$,
  'Justificatif : fichier vide ou de plus de 10 Mo.', true);
select abse.passe('10 Mo exactement : accepté',
  $q$select abse.put('n10mo', public.abs_creer_note('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', current_date - 3, 10, 'fournitures', null, 'Classeurs', abse.depot('22222222-2222-2222-2222-222222222221', 'pdf', 'application/pdf', 10485760), 'application/pdf', 10485760, repeat('e', 64)) ->> 'id')$q$);
select abse.refus('empreinte mal formée : refusée',
  $q$select public.abs_creer_note('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', current_date - 2, 10, 'repas', null, 'X', abse.depot('22222222-2222-2222-2222-222222222221', 'pdf', 'application/pdf', 10), 'application/pdf', 10, 'ABC')$q$,
  'Justificatif : empreinte SHA-256 absente ou mal formée.', true);
select abse.refus('fichier absent du stockage (dépôt échoué) : refusé',
  $q$select public.abs_creer_note('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', current_date - 2, 10, 'repas', null, 'X', '22222222-2222-2222-2222-222222222221/' || gen_random_uuid() || '.pdf', 'application/pdf', 10, repeat('c', 64))$q$,
  'Justificatif absent du stockage : déposez le fichier à nouveau.', true);
select abse.refus('taille déclarée différente de la taille stockée : refusée',
  $q$select public.abs_creer_note('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', current_date - 2, 10, 'repas', null, 'X', abse.depot('22222222-2222-2222-2222-222222222221', 'pdf', 'application/pdf', 11), 'application/pdf', 10, repeat('c', 64))$q$,
  'Justificatif : la taille stockée diffère de la taille contrôlée par le serveur.', true);
select abse.refus('type stocké différent du type contrôlé : refusé',
  $q$select public.abs_creer_note('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', current_date - 2, 10, 'repas', null, 'X', abse.depot('22222222-2222-2222-2222-222222222221', 'pdf', 'image/png', 10), 'application/pdf', 10, repeat('c', 64))$q$,
  'Justificatif : le type stocké diffère du type contrôlé par le serveur.', true);
select abse.refus('dépôt de plus de 30 minutes : refusé (le nettoyage peut le viser)',
  $q$select public.abs_creer_note('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', current_date - 2, 10, 'repas', null, 'X', abse.depot('22222222-2222-2222-2222-222222222221', 'pdf', 'application/pdf', 10, '31 minutes'), 'application/pdf', 10, repeat('c', 64))$q$,
  'Justificatif déposé il y a plus de 30 minutes : déposez le fichier à nouveau.', true);
select abse.refus('catégorie inconnue : refusée',
  $q$select public.abs_creer_note('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', current_date - 2, 10, 'cadeau', null, 'X', abse.depot('22222222-2222-2222-2222-222222222221', 'pdf', 'application/pdf', 10), 'application/pdf', 10, repeat('c', 64))$q$,
  'Catégorie inconnue : déplacement, repas, hébergement, carburant, fournitures ou autre.', true);
select abse.refus('« autre » sans précision : refusé',
  $q$select public.abs_creer_note('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', current_date - 2, 10, 'autre', '   ', 'X', abse.depot('22222222-2222-2222-2222-222222222221', 'pdf', 'application/pdf', 10), 'application/pdf', 10, repeat('c', 64))$q$,
  'Catégorie « autre » : la précision est obligatoire.', true);
select abse.refus('objet vide (espaces) : refusé',
  $q$select public.abs_creer_note('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', current_date - 2, 10, 'repas', null, '   ', abse.depot('22222222-2222-2222-2222-222222222221', 'pdf', 'application/pdf', 10), 'application/pdf', 10, repeat('c', 64))$q$,
  'L''objet de la dépense est obligatoire.', true);
select abse.refus('objet de 301 caractères : refusé',
  $q$select public.abs_creer_note('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', current_date - 2, 10, 'repas', null, repeat('x', 301), abse.depot('22222222-2222-2222-2222-222222222221', 'pdf', 'application/pdf', 10), 'application/pdf', 10, repeat('c', 64))$q$,
  'L''objet de la dépense est limité à 300 caractères.', true);
select abse.refus('montant nul : refusé',
  $q$select public.abs_creer_note('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', current_date - 2, 0, 'repas', null, 'X', abse.depot('22222222-2222-2222-2222-222222222221', 'pdf', 'application/pdf', 10), 'application/pdf', 10, repeat('c', 64))$q$,
  'Le montant TTC doit être strictement positif.', true);
select abse.refus('montant à 3 décimales : refusé (pas d''arrondi silencieux)',
  $q$select public.abs_creer_note('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', current_date - 2, 10.005, 'repas', null, 'X', abse.depot('22222222-2222-2222-2222-222222222221', 'pdf', 'application/pdf', 10), 'application/pdf', 10, repeat('c', 64))$q$,
  'Montant : au plus 2 décimales (la base arrondirait en silence) et moins de 100 000 000 €.', true);
select abse.refus('dépense datée dans le futur : refusée',
  $q$select public.abs_creer_note('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', current_date + 2, 10, 'repas', null, 'X', abse.depot('22222222-2222-2222-2222-222222222221', 'pdf', 'application/pdf', 10), 'application/pdf', 10, repeat('c', 64))$q$,
  'Date de la dépense refusée : elle ne peut pas être dans le futur.', true);
select abse.refus('dépense avant l''entrée : refusée',
  $q$select public.abs_creer_note('aaaaaaaa-0000-0000-0000-000000000045', '22222222-2222-2222-2222-2222222222c2', current_date - 1, 10, 'repas', null, 'X', abse.depot('22222222-2222-2222-2222-2222222222c2', 'pdf', 'application/pdf', 10), 'application/pdf', 10, repeat('c', 64))$q$,
  'Date de la dépense refusée : antérieure à l''entrée du collaborateur');
select abse.refus('collaboratrice : note pour Nguyen refusée',
  $q$select public.abs_creer_note('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222223', current_date - 2, 10, 'repas', null, 'X', abse.depot('22222222-2222-2222-2222-222222222223', 'pdf', 'application/pdf', 10), 'application/pdf', 10, repeat('c', 64))$q$,
  'Vous ne pouvez déposer des notes de frais que pour vous-même.', true);
select abse.refus('compte sans fiche : note refusée',
  $q$select public.abs_creer_note('aaaaaaaa-0000-0000-0000-000000000046', '22222222-2222-2222-2222-222222222221', current_date - 2, 10, 'repas', null, 'X', abse.depot('22222222-2222-2222-2222-222222222221', 'pdf', 'application/pdf', 10), 'application/pdf', 10, repeat('c', 64))$q$,
  'Votre compte n''est rattaché à aucune fiche collaborateur : note de frais impossible.', true);
select abse.refus('clé secrète : note créée directement, refusée',
  $q$insert into public.notes_de_frais (collaborateur_id, montant, categorie, objet, justificatif_url, justificatif_type, justificatif_taille, justificatif_empreinte) values ('22222222-2222-2222-2222-222222222221', 10, 'repas', 'X', 'a', 'application/pdf', 1, repeat('a', 64))$q$,
  'Notes de frais : écriture directe interdite ; passez par l''application.', true);
select abse.put('n2', (public.abs_creer_note(:ADMIN, :FLEA, abse.j(-1), 18, 'autre', ' Péage ', 'Autoroute', abse.depot(:FLEA, 'jpg', 'image/jpeg', 500),
  'image/jpeg', 500, repeat('f', 64)) ->> 'id'));
select abse.ok('admin : note pour autrui (« autre » + précision), auteur tracé',
  (select soumise_par = :ADMIN and categorie_precision = 'Péage' from public.notes_de_frais where id = abse.get('n2')::uuid));
-- Modification tant que « soumise ».
select abse.refus('modification par un collègue : refusée',
  $q$select public.abs_modifier_note('aaaaaaaa-0000-0000-0000-000000000043', abse.get('n1')::uuid, current_date - 2, 40, 'repas', null, 'Déjeuner', null, null, null, null)$q$,
  'Vous ne pouvez modifier que vos propres notes de frais.', true);
select abse.refus('modification par le manager : refusée (il décide, il ne corrige pas)',
  $q$select public.abs_modifier_note('aaaaaaaa-0000-0000-0000-000000000041', abse.get('n1')::uuid, current_date - 2, 40, 'repas', null, 'Déjeuner', null, null, null, null)$q$,
  'Vous ne pouvez modifier que vos propres notes de frais.', true);
select abse.put('f1b', abse.depot(:FLEA, 'png', 'image/png', 777));
select abse.passe('collaboratrice : montant corrigé et justificatif remplacé (note soumise)',
  $q$select public.abs_modifier_note('aaaaaaaa-0000-0000-0000-000000000042', abse.get('n1')::uuid, current_date - 2, 40, 'repas', null, 'Déjeuner chantier', abse.get('f1b'), 'image/png', 777, repeat('b', 64))$q$);
select abse.ok('modification tracée : valeurs et justificatif précédents dans l''historique ; ancien fichier toujours rattaché',
  (select montant = 40 and justificatif_url = abse.get('f1b') and historique -> -1 ->> 'action' = 'modification'
          and (historique -> -1 -> 'avant' ->> 'montant')::numeric = 42.5 and historique -> -1 -> 'avant' ->> 'justificatif_url' = abse.get('f1')
     from public.notes_de_frais where id = abse.get('n1')::uuid)
  and public.abs_justificatif_rattache(abse.get('f1')) and public.abs_justificatif_rattache(abse.get('f1b')));
select abse.refus('ancien justificatif réutilisé pour une autre note : refusé',
  $q$select public.abs_creer_note('aaaaaaaa-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222221', current_date - 2, 10, 'repas', null, 'X', abse.get('f1'), 'application/pdf', 2048, repeat('a', 64))$q$,
  'Justificatif déjà rattaché à une autre note de frais.', true);
-- Décisions.
select abse.refus('la collaboratrice valide sa propre note : refusé',
  $q$select public.abs_decider_note('aaaaaaaa-0000-0000-0000-000000000042', abse.get('n1')::uuid, 'valider', null)$q$,
  'Personne ne décide de ses propres notes de frais (administrateur compris).', true);
select abse.refus('manager hors équipe : refusé',
  $q$select public.abs_decider_note('aaaaaaaa-0000-0000-0000-000000000044', abse.get('n1')::uuid, 'valider', null)$q$,
  'Seul le responsable hiérarchique du collaborateur (ou l''administrateur) décide de cette note.', true);
select abse.passe('manager de l''équipe : note validée', $q$select public.abs_decider_note('aaaaaaaa-0000-0000-0000-000000000041', abse.get('n1')::uuid, 'valider', null)$q$);
select abse.ok('validation rejouée : sans effet', (public.abs_decider_note(:M, abse.get('n1')::uuid, 'valider', null) ->> 'deja_decide')::boolean
  and (select statut = 'validee' and decide_par = :M from public.notes_de_frais where id = abse.get('n1')::uuid));
select abse.refus('note validée : contenu non modifiable',
  $q$select public.abs_modifier_note('aaaaaaaa-0000-0000-0000-000000000042', abse.get('n1')::uuid, current_date - 2, 45, 'repas', null, 'Déjeuner chantier', null, null, null, null)$q$,
  'Note validée : son contenu et son justificatif ne se modifient plus.', true);
select abse.refus('note validée : justificatif non remplaçable',
  $q$select public.abs_modifier_note('aaaaaaaa-0000-0000-0000-000000000042', abse.get('n1')::uuid, current_date - 2, 40, 'repas', null, 'Déjeuner chantier', abse.depot('22222222-2222-2222-2222-222222222221', 'pdf', 'application/pdf', 5), 'application/pdf', 5, repeat('9', 64))$q$,
  'Note validée : son contenu et son justificatif ne se modifient plus.', true);
select abse.refus('note validée : empreinte modifiée directement (même avec un contexte), refusée',
  $q$select public.abs_contexte('11111111-1111-1111-1111-111111111111', 'modifier_note', null); update public.notes_de_frais set justificatif_empreinte = repeat('0', 64) where id = abse.get('n1')::uuid$q$,
  'Note validée : son contenu et son justificatif ne se modifient plus.', true);
select abse.refus('clé secrète : statut d''une note changé directement, refusé',
  $q$update public.notes_de_frais set statut = 'remboursee' where id = abse.get('n1')::uuid$q$,
  'Notes de frais : écriture directe interdite ; passez par l''application.', true);
select abse.refus('historique d''une note modifié : refusé',
  $q$select public.abs_contexte('11111111-1111-1111-1111-111111111111', 'rembourser', null); update public.notes_de_frais set historique = '[]' where id = abse.get('n1')::uuid$q$,
  'Historique : alimenté par la base seulement, ni modifiable ni effaçable.', true);
select abse.refus('refus de note sans motif : refusé',
  $q$select public.abs_decider_note('aaaaaaaa-0000-0000-0000-000000000041', abse.get('n10mo')::uuid, 'refuser', '')$q$,
  'Refus : un motif est obligatoire.', true);
select abse.passe('refus de note motivé', $q$select public.abs_decider_note('aaaaaaaa-0000-0000-0000-000000000041', abse.get('n10mo')::uuid, 'refuser', 'Justificatif illisible')$q$);
select abse.refus('note refusée : plus de validation',
  $q$select public.abs_decider_note('aaaaaaaa-0000-0000-0000-000000000041', abse.get('n10mo')::uuid, 'valider', null)$q$,
  'Décision déjà prise : cette note n''est plus « soumise ».', true);
select abse.refus('note refusée : pas de remboursement',
  $q$select public.abs_declarer_remboursement('11111111-1111-1111-1111-111111111111', abse.get('n10mo')::uuid, current_date, null)$q$,
  'Seule une note validée se rembourse.', true);
select abse.refus('note refusée : contenu non modifiable',
  $q$select public.abs_modifier_note('aaaaaaaa-0000-0000-0000-000000000042', abse.get('n10mo')::uuid, current_date - 3, 11, 'fournitures', null, 'Classeurs', null, null, null, null)$q$,
  'Note refusée : son contenu et son justificatif ne se modifient plus.', true);
-- Remboursement déclaré, corrections motivées.
select abse.refus('remboursement d''une note soumise : refusé',
  $q$select public.abs_declarer_remboursement('11111111-1111-1111-1111-111111111111', abse.get('n2')::uuid, current_date, null)$q$,
  'Seule une note validée se rembourse.', true);
select abse.refus('remboursement déclaré par le manager : refusé',
  $q$select public.abs_declarer_remboursement('aaaaaaaa-0000-0000-0000-000000000041', abse.get('n1')::uuid, current_date, 'VIR-1')$q$,
  'Seul l''administrateur déclare un remboursement.', true);
select abse.refus('date de remboursement future : refusée',
  $q$select public.abs_declarer_remboursement('11111111-1111-1111-1111-111111111111', abse.get('n1')::uuid, current_date + 5, 'VIR-1')$q$,
  'Date de remboursement obligatoire, ni future ni antérieure à la dépense.', true);
select abse.refus('date de remboursement antérieure à la dépense : refusée',
  $q$select public.abs_declarer_remboursement('11111111-1111-1111-1111-111111111111', abse.get('n1')::uuid, current_date - 30, 'VIR-1')$q$,
  'Date de remboursement obligatoire, ni future ni antérieure à la dépense.', true);
select abse.passe('remboursement déclaré par l''admin',
  $q$select public.abs_declarer_remboursement('11111111-1111-1111-1111-111111111111', abse.get('n1')::uuid, current_date, ' VIR-2026-001 ')$q$);
select abse.ok('remboursement : date, référence, déclarant ; montant et justificatif inchangés',
  (select statut = 'remboursee' and rembourse_le = abse.j(0) and reference_remboursement = 'VIR-2026-001'
          and rembourse_declare_par = :ADMIN and montant = 40 and justificatif_url = abse.get('f1b')
     from public.notes_de_frais where id = abse.get('n1')::uuid));
select abse.ok('déclaration rejouée à l''identique : sans effet',
  (public.abs_declarer_remboursement(:ADMIN, abse.get('n1')::uuid, abse.j(0), 'VIR-2026-001') ->> 'deja_declare')::boolean);
select abse.refus('nouvelle déclaration différente : refusée (correction motivée obligatoire)',
  $q$select public.abs_declarer_remboursement('11111111-1111-1111-1111-111111111111', abse.get('n1')::uuid, current_date, 'VIR-AUTRE')$q$,
  'Remboursement déjà déclaré : utilisez la correction motivée.', true);
select abse.refus('note remboursée : contenu non modifiable',
  $q$select public.abs_modifier_note('aaaaaaaa-0000-0000-0000-000000000042', abse.get('n1')::uuid, current_date - 2, 41, 'repas', null, 'Déjeuner chantier', null, null, null, null)$q$,
  'Note remboursée : son contenu et son justificatif ne se modifient plus.', true);
select abse.refus('correction sans motif : refusée',
  $q$select public.abs_corriger_remboursement('11111111-1111-1111-1111-111111111111', abse.get('n1')::uuid, 'corriger', current_date, 'VIR-X', ' ')$q$,
  'Correction : un motif est obligatoire.', true);
select abse.refus('correction par le manager : refusée',
  $q$select public.abs_corriger_remboursement('aaaaaaaa-0000-0000-0000-000000000041', abse.get('n1')::uuid, 'annuler', null, null, 'Erreur')$q$,
  'Seul l''administrateur corrige une déclaration de remboursement.', true);
select abse.refus('correction sans changement : refusée',
  $q$select public.abs_corriger_remboursement('11111111-1111-1111-1111-111111111111', abse.get('n1')::uuid, 'corriger', current_date, 'VIR-2026-001', 'Rien')$q$,
  'Correction : aucune valeur ne change.', true);
select abse.passe('correction de la référence, motivée',
  $q$select public.abs_corriger_remboursement('11111111-1111-1111-1111-111111111111', abse.get('n1')::uuid, 'corriger', current_date, 'VIR-2026-002', 'Référence mal recopiée')$q$);
select abse.passe('annulation de la déclaration, motivée',
  $q$select public.abs_corriger_remboursement('11111111-1111-1111-1111-111111111111', abse.get('n1')::uuid, 'annuler', null, null, 'Virement rejeté par la banque')$q$);
select abse.ok('après annulation : « validée », champs de remboursement vides, historique complet et intact',
  (select statut = 'validee' and rembourse_le is null and reference_remboursement is null and rembourse_declare_par is null
          and montant = 40
          and (select string_agg(e ->> 'action', ',' order by o) from jsonb_array_elements(historique) with ordinality x(e, o))
              = 'soumission,modification,validation,remboursement_declare,remboursement_corrige,remboursement_annule'
          and historique -> 4 -> 'avant' ->> 'reference' = 'VIR-2026-001' and historique -> 4 -> 'apres' ->> 'reference' = 'VIR-2026-002'
          and historique -> 5 -> 'avant' ->> 'reference' = 'VIR-2026-002' and historique -> 5 ->> 'motif' = 'Virement rejeté par la banque'
     from public.notes_de_frais where id = abse.get('n1')::uuid));
select abse.refus('annulation sur une note non remboursée : refusée',
  $q$select public.abs_corriger_remboursement('11111111-1111-1111-1111-111111111111', abse.get('n1')::uuid, 'annuler', null, null, 'Encore')$q$,
  'Aucun remboursement déclaré sur cette note.', true);
-- Ses propres notes : jamais, même l'administrateur.
select abse.put('n_adm', (public.abs_creer_note(:ADMIN, :FADM, abse.j(-1), 25, 'carburant', null, 'Plein', abse.depot(:FADM, 'pdf', 'application/pdf', 300),
  'application/pdf', 300, repeat('1', 64)) ->> 'id'));
select abse.refus('admin : validation de sa propre note refusée',
  $q$select public.abs_decider_note('11111111-1111-1111-1111-111111111111', abse.get('n_adm')::uuid, 'valider', null)$q$,
  'Personne ne décide de ses propres notes de frais (administrateur compris).', true);
select abse.passe('note de Léa validée par l''admin (pour la suite)', $q$select public.abs_decider_note('11111111-1111-1111-1111-111111111111', abse.get('n2')::uuid, 'valider', null)$q$);
update public.profiles set collaborateur_id = :FLEA where id = :P;
update auth.users set raw_app_meta_data = '{}' where id = :P;
select abse.refus('un admin ne déclare pas le remboursement de sa propre note',
  $q$select public.abs_declarer_remboursement('aaaaaaaa-0000-0000-0000-000000000047', abse.get('n2')::uuid, current_date, null)$q$,
  'Personne ne déclare le remboursement de ses propres notes de frais.', true);
update public.profiles set collaborateur_id = null where id = :P;
update auth.users set raw_app_meta_data = '{"doit_changer_mot_de_passe": true}' where id = :P;
select abse.refus('suppression d''une note : refusée', $q$delete from public.notes_de_frais where id = abse.get('n1')::uuid$q$,
  'Une note de frais ne se supprime pas (historique conservé).', true);
-- Lectures des notes avec les jetons.
set role authenticated;
select abse.qui(:L, 'bbbbbbbb-0000-0000-0000-000000000042');
select abse.ok('collaboratrice : ses seules notes', (select bool_and(collaborateur_id = :FLEA) and count(*) = 3 from public.notes_de_frais));
select abse.refus('collaboratrice : modification directe d''une note refusée', $q$update public.notes_de_frais set montant = 1$q$, 'permission denied');
select abse.qui(:M, 'bbbbbbbb-0000-0000-0000-000000000041');
select abse.ok('manager : notes de son équipe, pas celle de l''admin',
  (select count(*) filter (where collaborateur_id = :FLEA) = 3 and count(*) filter (where collaborateur_id = :FADM) = 0 from public.notes_de_frais));
select abse.qui(:K, 'bbbbbbbb-0000-0000-0000-000000000044');
select abse.ok('manager hors équipe : aucune note de Léa', (select count(*) = 0 from public.notes_de_frais where collaborateur_id = :FLEA));
select abse.qui(:H, 'bbbbbbbb-0000-0000-0000-000000000045');
select abse.ok('compte sans session enregistrée : rien', (select count(*) = 0 from public.notes_de_frais));
reset role;
-- Dépôts abandonnés.
select abse.put('orph_vieux', abse.depot(:FLEA, 'pdf', 'application/pdf', 10, '2 hours'));
select abse.put('orph_recent', abse.depot(:FLEA, 'pdf', 'application/pdf', 10, '10 minutes'));
update storage.objects set created_at = now() - interval '3 hours' where name = abse.get('f1');
select abse.ok('dépôts abandonnés : le vieux dépôt non rattaché est listé ; ni le dépôt récent, ni un justificatif (même ancien, même remplacé)',
  abse.get('orph_vieux') in (select public.abs_fichiers_orphelins()) and abse.get('orph_recent') not in (select public.abs_fichiers_orphelins())
  and abse.get('f1') not in (select public.abs_fichiers_orphelins()) and abse.get('f1b') not in (select public.abs_fichiers_orphelins()));

-- ===================== Essais, nettoyage, protections RH =====================
select abse.put('c_jet', public.abs_demander_conge(:ADMIN, :FJET, 'conges_payes', abse.j(10), abse.j(10), false, false, 1, null, null)::text);
select abse.put('f_jet', abse.depot(:FJET, 'pdf', 'application/pdf', 64));
select abse.put('n_jet', (public.abs_creer_note(:ADMIN, :FJET, abse.j(0), 9.99, 'repas', null, 'Essai', abse.get('f_jet'), 'application/pdf', 64, repeat('7', 64)) ->> 'id'));
select abse.ok('fiche d''essai (@exemple.invalid) : congé et note marqués essai ; fiches réelles non',
  (select essai from public.conges where id = abse.get('c_jet')::uuid) and (select essai from public.notes_de_frais where id = abse.get('n_jet')::uuid)
  and (select count(*) = 0 from public.conges where essai and collaborateur_id <> :FJET));
select abse.refus('email d''une fiche réelle portant des absences changé en adresse d''essai : refusé',
  $q$update public.collaborateurs set email = 'lea@exemple.invalid' where id = '22222222-2222-2222-2222-222222222221'$q$,
  'Email refusé : passer d''une adresse d''essai (@exemple.invalid) à une adresse réelle, ou l''inverse, est impossible quand la fiche porte des absences ou des notes de frais.', true);
select abse.refus('email d''une fiche d''essai changé en adresse réelle : refusé',
  $q$update public.collaborateurs set email = 'vrai@exemple.fr' where id = '22222222-2222-2222-2222-2222222222e1'$q$, 'Email refusé');
select abse.refus('suppression de la fiche de Léa : refusée, message exact (congés et notes de frais)',
  $q$delete from public.collaborateurs where id = '22222222-2222-2222-2222-222222222221'$q$,
  'Suppression refusée : la fiche Lea Moreau porte des temps, des congés, des notes de frais, un compte rattaché. Renseignez plutôt sa date de sortie.', true);
select abse.refus('suppression de la fiche du manager validateur : refusée (congés validés par lui)',
  $q$delete from public.collaborateurs where id = '22222222-2222-2222-2222-222222222222'$q$, 'des congés qu''elle a validés');
set role authenticated;
select abse.qui(:ADMIN, 'bbbbbbbb-0000-0000-0000-000000000001');
select abse.refus('nettoyage des essais avec un jeton (même admin) : refusé', $q$select public.supprimer_essais_absences()$q$, 'permission denied');
reset role;
select count(*) as nb_reels_avant from public.conges where not essai \gset
select abse.put('net', public.supprimer_essais_absences()::text);
select abse.ok('nettoyage : congé et note d''essai supprimés, données réelles intactes, fichier d''essai rendu',
  (select count(*) = 0 from public.conges where essai) and (select count(*) = 0 from public.notes_de_frais where essai)
  and (select count(*) from public.conges) = :nb_reels_avant
  and abse.get('net')::jsonb -> 'chemins' = jsonb_build_array(abse.get('f_jet'))
  and (abse.get('net')::jsonb ->> 'conges')::int = 1 and (abse.get('net')::jsonb ->> 'notes')::int = 1, abse.get('net'));
select abse.passe('fiche d''essai ensuite supprimable', $q$delete from public.profiles where collaborateur_id = '22222222-2222-2222-2222-2222222222e1'; delete from public.collaborateurs where id = '22222222-2222-2222-2222-2222222222e1'$q$);

select n || '. [' || case when ok then 'OK ' else 'ÉCHEC' end || '] ' || libelle || coalesce('  (' || left(detail, 220) || ')', '') from abse.resultats order by n;
select 'BILAN : ' || count(*) filter (where ok) || '/' || count(*) || ' contrôles réussis' from abse.resultats;
