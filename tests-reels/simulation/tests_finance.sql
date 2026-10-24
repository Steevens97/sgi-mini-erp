-- Tests du module Finance sur la base d'ESSAI locale (jamais Supabase). Socle aligné sur les 13 tables réelles.
-- Usage : tests-reels/simulation/rejouer.sh tests-reels/simulation/tests_finance.sql
--         puis : select count(*) filter (where ok), count(*) from fne.resultats;
-- La facture « réelle » de ce fichier n'existe que dans la base d'essai locale (coordonnées SIMULATION).
\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
create schema fne;
create table fne.resultats (n serial, libelle text, ok boolean, detail text);
grant usage on schema fne to authenticated, anon, service_role;
grant all on all tables in schema fne to authenticated, anon, service_role;
grant usage on all sequences in schema fne to authenticated, anon, service_role;
create function fne.ok(p_libelle text, p_ok boolean, p_detail text default null) returns void language sql as $$
  insert into fne.resultats (libelle, ok, detail) values (p_libelle, coalesce(p_ok, false), p_detail);
$$;
create function fne.refus(p_libelle text, p_sql text, p_motif text default null) returns void language plpgsql as $$
begin
  execute p_sql;
  insert into fne.resultats (libelle, ok, detail) values (p_libelle, false, 'accepté alors qu''il devait être refusé');
exception when others then
  insert into fne.resultats (libelle, ok, detail)
  values (p_libelle, p_motif is null or sqlerrm ilike '%' || p_motif || '%', sqlerrm);
end $$;
create function fne.passe(p_libelle text, p_sql text) returns void language plpgsql as $$
begin
  execute p_sql;
  insert into fne.resultats (libelle, ok, detail) values (p_libelle, true, null);
exception when others then
  insert into fne.resultats (libelle, ok, detail) values (p_libelle, false, 'refusé : ' || sqlerrm);
end $$;
create function fne.qui(p_user uuid, p_session uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated', 'session_id', p_session)::text, false);
$$;
create function fne.jour(n integer) returns date language sql as $$
  select (date_trunc('month', (now() at time zone 'America/Martinique')::date) - interval '1 month')::date + n - 1 $$;
create function fne.aujourdhui() returns date language sql as $$ select (now() at time zone 'America/Martinique')::date $$;
create table fne.v (cle text primary key, val text);
create function fne.get(p text) returns text language sql as $$ select val from fne.v where cle = p $$;
create function fne.put(p text, v text) returns void language sql as $$
  insert into fne.v values (p, v) on conflict (cle) do update set val = excluded.val $$;
grant execute on all functions in schema fne to authenticated, anon, service_role;
grant all on fne.v to authenticated, service_role;

\set ADMIN '\'11111111-1111-1111-1111-111111111111\''
\set M '\'aaaaaaaa-0000-0000-0000-000000000031\''
\set L '\'aaaaaaaa-0000-0000-0000-000000000032\''
\set P '\'aaaaaaaa-0000-0000-0000-000000000033\''
\set FLEA '\'22222222-2222-2222-2222-222222222221\''
\set FADM '\'22222222-2222-2222-2222-2222222222fa\''
\set CR '\'33333333-3333-3333-3333-3333333333a1\''
\set TVA_MQ '\'{"regime":"taxable","territoire":"MQ","taux":8.5,"criteres":{"nature_mission":"prestation_intellectuelle","statut_client":"assujetti_france"}}\''
\set DEMO '\'{"raison_sociale":"[DÉMO] SG Ingénierie","forme_juridique":"SAS","capital_social":"[DÉMO]","adresse":"[DÉMO] adresse","code_postal":"97200","ville":"Fort-de-France","siret":"00000000000000","immatriculation":"[DÉMO] immatriculation","tva_intracom":"[DÉMO]"}\''
\set COND_DEMO '\'{"delai_paiement_jours":"30","penalites_retard":"[DÉMO] pénalités","indemnite_recouvrement":"[DÉMO] indemnité","escompte":"[DÉMO] escompte"}\''
\set SIMU '\'{"raison_sociale":"SIMULATION LOCALE — SANS VALEUR","forme_juridique":"SAS","capital_social":"SIMULATION","adresse":"SIMULATION","code_postal":"97200","ville":"Fort-de-France","siret":"00000000000000","immatriculation":"SIMULATION","tva_intracom":"SIMULATION"}\''
\set COND_SIMU '\'{"delai_paiement_jours":"30","penalites_retard":"SIMULATION","indemnite_recouvrement":"SIMULATION","escompte":"SIMULATION"}\''
\set VIDE '\'{"raison_sociale":"","forme_juridique":"","capital_social":"","adresse":"","code_postal":"","ville":"","siret":"","immatriculation":"","tva_intracom":""}\''
\set COND_VIDE '\'{"delai_paiement_jours":"","penalites_retard":"","indemnite_recouvrement":"","escompte":""}\''

-- ===================== Comptes, fiches et données réelles de TEST (base locale) =====================
insert into public.collaborateurs (id, nom, prenom, email, poste, taux_horaire) values
  ('22222222-2222-2222-2222-2222222222fa', 'Admin', 'Sgi', 'sgi-fiche@exemple.invalid', 'Gérant', 0);
update public.profiles set collaborateur_id = :FADM where id = :ADMIN;
insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000031', 'manager-fin@exemple.invalid'),
  ('aaaaaaaa-0000-0000-0000-000000000032', 'lea-fin@exemple.invalid'),
  ('aaaaaaaa-0000-0000-0000-000000000033', 'provisoire-fin@exemple.invalid');
update public.profiles set role = 'manager', collaborateur_id = '22222222-2222-2222-2222-222222222222' where id = :M;
update public.profiles set collaborateur_id = :FLEA where id = :L;
update public.profiles set role = 'admin' where id = :P;
update auth.users set raw_app_meta_data = '{"doit_changer_mot_de_passe": true}' where id = :P;
insert into auth.sessions (id, user_id) values
  ('bbbbbbbb-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111'),
  ('bbbbbbbb-0000-0000-0000-000000000031', 'aaaaaaaa-0000-0000-0000-000000000031'),
  ('bbbbbbbb-0000-0000-0000-000000000032', 'aaaaaaaa-0000-0000-0000-000000000032');
insert into public.clients (id, nom, adresse) values (:CR, 'Client Finance test', E'5 rue du Test\n97200 Fort-de-France\nMQ');
insert into public.projets (nom, client_id) values ('Mission régie', :CR) returning id as pr1 \gset
insert into public.projets (nom, client_id) values ('Mission régie 2', :CR) returning id as pr2 \gset
insert into public.projets (nom, client_id) values ('Mission forfait', :CR) returning id as pf \gset

select fne.ok('aucune facture, aucun compteur de facture au départ',
  (select count(*) = 0 from public.factures) and (select count(*) = 0 from public.compteurs where cle like '%facture%'));
select fne.ok('projets existants : mode et tarif vides (rien n''est déduit, même d''un devis)',
  (select bool_and(mode_facturation is null and tarif_vente_ht is null and tarif_historique = '[]'::jsonb) from public.projets));

-- Temps (saisis par l'admin pour Léa, dérogation motivée car le mois précédent dépasse 31 jours).
select public.rh_enregistrer_temps(:ADMIN, null, :FLEA, :'pr1', fne.jour(2), 0.25, null, 'Régularisation test') as t1 \gset
select public.rh_enregistrer_temps(:ADMIN, null, :FLEA, :'pr1', fne.jour(3), 0.25, null, 'Régularisation test') as t2 \gset
select public.rh_enregistrer_temps(:ADMIN, null, :FLEA, :'pr1', fne.jour(4), 0.25, null, 'Régularisation test') as t3 \gset
select public.rh_enregistrer_temps(:ADMIN, null, :FLEA, :'pr1', fne.jour(15), 2.5, null, 'Régularisation test') as t4 \gset
select public.rh_enregistrer_temps(:ADMIN, null, :FLEA, :'pr2', fne.jour(5), 1, null, 'Régularisation test') as t5 \gset
select public.rh_enregistrer_temps(:ADMIN, null, :FLEA, :'pf', fne.jour(6), 1, null, 'Régularisation test') as t6 \gset
select public.rh_enregistrer_temps(:ADMIN, null, :FLEA, :'pr1', fne.jour(20), 1, null, 'Régularisation test') as tb \gset
select public.rh_enregistrer_temps(:ADMIN, null, :FLEA, :'pr1', date_trunc('month', fne.aujourdhui())::date, 1, null, 'Test') as tmois \gset
-- Temps de l'administrateur lui-même : soumis et attesté, jamais validé.
select public.rh_enregistrer_temps(:ADMIN, null, :FADM, :'pr1', fne.jour(7), 3, null, 'Régularisation test') as ta \gset
select public.rh_changer_statut_temps(:ADMIN, array[:'t1', :'t2', :'t3', :'t4', :'t5', :'t6', :'tmois', :'ta']::uuid[], 'soumettre', null);
select public.rh_changer_statut_temps(:ADMIN, array[:'t1', :'t2', :'t3', :'t4', :'t5', :'t6', :'tmois']::uuid[], 'valider', null);
select public.rh_changer_statut_temps(:ADMIN, array[:'ta']::uuid[], 'attester', 'J''atteste mes heures');
select fne.ok('temps de l''administrateur : soumis et attesté, non validé',
  (select statut = 'soumis' and valide_par is null from public.temps where id = :'ta'));

-- ===================== Droits : jetons utilisateurs =====================
set role authenticated;
select fne.qui(:ADMIN, 'bbbbbbbb-0000-0000-0000-000000000001');
select fne.refus('jeton admin : tarif de vente illisible', $q$select tarif_vente_ht from public.projets$q$, 'permission denied');
select fne.refus('jeton admin : historique des tarifs illisible', $q$select tarif_historique from public.projets$q$, 'permission denied');
select fne.refus('jeton admin : « select * » sur projets refusé', $q$select * from public.projets$q$, 'permission denied');
select fne.refus('jeton admin : filtre sur le tarif refusé', $q$select id from public.projets where tarif_vente_ht > 0$q$, 'permission denied');
select fne.refus('jeton admin : tri sur la date d''effet refusé', $q$select id from public.projets order by tarif_date_effet$q$, 'permission denied');
select fne.refus('jeton admin : taux facturé d''un temps illisible', $q$select taux_facture from public.temps$q$, 'permission denied');
select fne.refus('jeton admin : montant facturé filtré refusé', $q$select id from public.temps where montant_facture_ht > 0$q$, 'permission denied');
select fne.refus('jeton admin : « select * » sur temps refusé', $q$select * from public.temps$q$, 'permission denied');
select fne.refus('jeton admin : factures illisibles (écrans Finance = clé secrète)', $q$select id from public.factures$q$, 'permission denied');
select fne.refus('jeton admin : création de facture refusée', $q$insert into public.factures (client_id) values ('33333333-3333-3333-3333-3333333333a1')$q$, 'permission denied');
select fne.refus('jeton admin : mode de facturation non modifiable directement', $q$update public.projets set mode_facturation = 'temps_passe'$q$, 'permission denied');
select fne.refus('jeton admin : fonction de calcul inaccessible', $q$select public.finance_calculer(null, null, null, null)$q$, 'permission denied');
select fne.refus('jeton admin : fonction d''émission inaccessible', $q$select public.finance_emettre_facture(null, null, null, null, null, null, null, null, null, null)$q$, 'permission denied');
select fne.ok('jeton admin : lectures existantes des projets intactes (colonnes nommées)',
  (select count(*) >= 5 from public.projets where id is not null and nom is not null and devis_id is null));
select fne.qui(:L, 'bbbbbbbb-0000-0000-0000-000000000032');
select fne.ok('jeton collaboratrice : ses temps lisibles avec les colonnes de l''écran RH',
  (select count(*) >= 7 from public.temps where historique is not null and facture_id is null));
select fne.refus('jeton collaboratrice : taux facturé illisible', $q$select taux_facture from public.temps$q$, 'permission denied');
select fne.refus('jeton collaboratrice : factures illisibles', $q$select numero from public.factures$q$, 'permission denied');
select fne.qui(:M, 'bbbbbbbb-0000-0000-0000-000000000031');
select fne.refus('jeton manager : tarif illisible', $q$select tarif_reference from public.projets$q$, 'permission denied');
select fne.refus('jeton manager : factures illisibles', $q$select total_ht from public.factures$q$, 'permission denied');
reset role;
select set_config('request.jwt.claims', '', false);
select fne.refus('auteur manager : action Finance refusée', format($q$select public.finance_definir_mode('%s', '%s', 'temps_passe')$q$, :M, :'pr1'), 'administrateur actif');
select fne.refus('auteur admin provisoire (mot de passe à changer) : refusé', format($q$select public.finance_definir_mode('%s', '%s', 'temps_passe')$q$, :P, :'pr1'), 'administrateur actif');

-- ===================== Mode de facturation et tarifs à date d'effet =====================
select fne.refus('écriture directe du tarif refusée (même hors application)', format($q$update public.projets set tarif_vente_ht = 50 where id = '%s'$q$, :'pr1'), 'uniquement par l''écran Finance');
select fne.refus('écriture directe du mode refusée', format($q$update public.projets set mode_facturation = 'temps_passe' where id = '%s'$q$, :'pr1'), 'uniquement par l''écran Finance');
select fne.refus('mode inconnu refusé', format($q$select public.finance_definir_mode('%s', '%s', 'regie')$q$, :ADMIN, :'pr1'), 'inconnu');
set role service_role;
select public.finance_definir_mode(:ADMIN, :'pr1', 'temps_passe');
select public.finance_definir_mode(:ADMIN, :'pr2', 'temps_passe');
select public.finance_definir_mode(:ADMIN, :'pf', 'forfait');
reset role;
select fne.refus('tarif nul refusé', format($q$select public.finance_confirmer_tarif('%s', '%s', 0, '%s', 'Contrat', '%s')$q$,
  :ADMIN, :'pr1', fne.jour(1), public.finance_temps_concernes(:'pr1', fne.jour(1)) ->> 'empreinte'), 'strictement positif');
select fne.refus('tarif vide refusé', format($q$select public.finance_confirmer_tarif('%s', '%s', null, '%s', 'Contrat', '%s')$q$,
  :ADMIN, :'pr1', fne.jour(1), public.finance_temps_concernes(:'pr1', fne.jour(1)) ->> 'empreinte'), 'strictement positif');
select fne.refus('tarif à 3 décimales refusé', format($q$select public.finance_confirmer_tarif('%s', '%s', 10.005, '%s', 'Contrat', '%s')$q$,
  :ADMIN, :'pr1', fne.jour(1), public.finance_temps_concernes(:'pr1', fne.jour(1)) ->> 'empreinte'), '2 décimales');
select fne.refus('référence du contrat obligatoire', format($q$select public.finance_confirmer_tarif('%s', '%s', 10, '%s', ' ', '%s')$q$,
  :ADMIN, :'pr1', fne.jour(1), public.finance_temps_concernes(:'pr1', fne.jour(1)) ->> 'empreinte'), 'Référence du contrat');
select fne.refus('date d''effet obligatoire', format($q$select public.finance_confirmer_tarif('%s', '%s', 10, null, 'Contrat', 'x')$q$,
  :ADMIN, :'pr1'), 'Date d''effet obligatoire');
set role service_role;
select public.finance_confirmer_tarif(:ADMIN, :'pr1', 10.01, fne.jour(1), 'Contrat régie 2026',
  public.finance_temps_concernes(:'pr1', fne.jour(1)) ->> 'empreinte');
select public.finance_confirmer_tarif(:ADMIN, :'pr2', 100, fne.jour(1), 'Contrat régie 2',
  public.finance_temps_concernes(:'pr2', fne.jour(1)) ->> 'empreinte');
reset role;

-- Confirmation rétroactive (2e période au 11) : l'empreinte couvre identité, date et heures des temps concernés.
select fne.put('e1', public.finance_temps_concernes(:'pr1', fne.jour(11)) ->> 'empreinte');
select fne.ok('temps concernés par un tarif au 11 : T4, le brouillon et le temps du mois en cours (3 temps, 4,5 h)',
  (select (c ->> 'nb')::int = 3 and (c ->> 'heures')::numeric = 4.5 from (select public.finance_temps_concernes(:'pr1', fne.jour(11)) c) x));
select public.rh_enregistrer_temps(:ADMIN, :'tb', :FLEA, :'pr1', fne.jour(20), 2, null, 'Régularisation test');
select fne.refus('confirmation périmée : heures d''un temps modifiées (même nombre de lignes)', format($q$select public.finance_confirmer_tarif('%s', '%s', 90, '%s', 'Avenant 1', '%s')$q$,
  :ADMIN, :'pr1', fne.jour(11), fne.get('e1')), 'Confirmation périmée');
select fne.put('e2', public.finance_temps_concernes(:'pr1', fne.jour(11)) ->> 'empreinte');
select public.rh_enregistrer_temps(:ADMIN, :'tb', :FLEA, :'pr1', fne.jour(21), 2, null, 'Régularisation test');
select fne.refus('confirmation périmée : date d''un temps modifiée (même nombre de lignes)', format($q$select public.finance_confirmer_tarif('%s', '%s', 90, '%s', 'Avenant 1', '%s')$q$,
  :ADMIN, :'pr1', fne.jour(11), fne.get('e2')), 'Confirmation périmée');
select fne.put('e3', public.finance_temps_concernes(:'pr1', fne.jour(11)) ->> 'empreinte');
select public.rh_supprimer_temps(:ADMIN, :'tb');
select public.rh_enregistrer_temps(:ADMIN, null, :FLEA, :'pr1', fne.jour(21), 2, null, 'Régularisation test') as tb2 \gset
select fne.ok('même nombre, mêmes dates et heures, autre temps : la liste a pourtant changé',
  (select (c ->> 'nb')::int = 3 and c ->> 'empreinte' <> fne.get('e3') from (select public.finance_temps_concernes(:'pr1', fne.jour(11)) c) x));
select fne.refus('confirmation périmée : un temps remplacé par un autre identique (identité vérifiée)', format($q$select public.finance_confirmer_tarif('%s', '%s', 90, '%s', 'Avenant 1', '%s')$q$,
  :ADMIN, :'pr1', fne.jour(11), fne.get('e3')), 'Confirmation périmée');
set role service_role;
select fne.passe('confirmation rétroactive à jour : 90 € au 11', format($q$select public.finance_confirmer_tarif('%s', '%s', 90, '%s', 'Avenant 1', '%s')$q$,
  :ADMIN, :'pr1', fne.jour(11), public.finance_temps_concernes(:'pr1', fne.jour(11)) ->> 'empreinte'));
reset role;
select fne.ok('événement de période : nombre et heures des temps concernés conservés',
  (select e ->> 'temps_concernes' = '3' and (e ->> 'heures_concernees')::numeric = 5.5
     from public.projets p, jsonb_array_elements(p.tarif_historique) e where p.id = :'pr1' and e ->> 'tarif' = '90'));
select fne.refus('date d''effet antérieure ou égale au dernier tarif refusée', format($q$select public.finance_confirmer_tarif('%s', '%s', 95, '%s', 'Avenant 2', '%s')$q$,
  :ADMIN, :'pr1', fne.jour(11), public.finance_temps_concernes(:'pr1', fne.jour(11)) ->> 'empreinte'), 'postérieure au');

-- Correction du dernier tarif (erreur de saisie) : nouvel événement, l'ancien intact et ignoré.
select fne.put('p90', (select e ->> 'id' from public.projets p, jsonb_array_elements(p.tarif_historique) e where p.id = :'pr1' and e ->> 'tarif' = '90'));
select fne.put('p10', (select e ->> 'id' from public.projets p, jsonb_array_elements(p.tarif_historique) e where p.id = :'pr1' and e ->> 'tarif' = '10.01'));
select fne.put('h_avant', (select tarif_historique::text from public.projets where id = :'pr1'));
select fne.refus('seul le dernier tarif se corrige', format($q$select public.finance_corriger_tarif('%s', '%s', '%s', 11, 'Contrat', 'Erreur de saisie', '%s')$q$,
  :ADMIN, :'pr1', fne.get('p10'), public.finance_temps_concernes(:'pr1', fne.jour(1)) ->> 'empreinte'), 'dernier tarif');
select fne.refus('correction sans motif refusée', format($q$select public.finance_corriger_tarif('%s', '%s', '%s', 80, 'Avenant 1', '', '%s')$q$,
  :ADMIN, :'pr1', fne.get('p90'), public.finance_temps_concernes(:'pr1', fne.jour(11)) ->> 'empreinte'), 'motif');
set role service_role;
select public.finance_corriger_tarif(:ADMIN, :'pr1', fne.get('p90'), 80, 'Avenant 1', 'Erreur de saisie : 80 € au contrat',
  public.finance_temps_concernes(:'pr1', fne.jour(11)) ->> 'empreinte');
reset role;
select fne.ok('correction : l''historique garde l''ancien événement à l''identique et ajoute la correction',
  (select left(tarif_historique::text, length(fne.get('h_avant')) - 1) = left(fne.get('h_avant'), length(fne.get('h_avant')) - 1)
          and jsonb_array_length(tarif_historique) = 3
          and tarif_historique -> 2 ->> 'remplace' = fne.get('p90') from public.projets where id = :'pr1'));
select fne.ok('période remplacée ignorée : 80 € appliqué au 15, 10,01 € au 2',
  (select (public.finance_tarif_a_date(tarif_historique, fne.jour(15)) ->> 'tarif')::numeric = 80
      and (public.finance_tarif_a_date(tarif_historique, fne.jour(2)) ->> 'tarif')::numeric = 10.01
      and public.finance_tarif_a_date(tarif_historique, fne.jour(1) - 1) is null from public.projets where id = :'pr1'));
select fne.refus('historique des tarifs : modification d''un ancien événement refusée (même par une fonction Finance)', format($q$do $x$ begin
  perform public.finance_contexte('tarif', null, null);
  update public.projets set tarif_historique = jsonb_set(tarif_historique, '{0,tarif}', '1') || '[{"type":"x"}]'::jsonb where id = '%s';
end $x$$q$, :'pr1'), 'ajout seul');
select fne.refus('historique des tarifs : suppression d''un événement refusée', format($q$do $x$ begin
  perform public.finance_contexte('tarif', null, null);
  update public.projets set tarif_historique = (tarif_historique - 0) || '[{"type":"x"},{"type":"y"}]'::jsonb where id = '%s';
end $x$$q$, :'pr1'), 'ajout seul');

-- Tarif futur : récapitulatif = DERNIER tarif confirmé (avec sa date d'effet), pas le tarif applicable aujourd'hui.
set role service_role;
select public.finance_confirmer_tarif(:ADMIN, :'pr2', 120, fne.aujourdhui() + 30, 'Avenant 2027',
  public.finance_temps_concernes(:'pr2', fne.aujourdhui() + 30) ->> 'empreinte');
reset role;
select fne.ok('tarif futur : dernier tarif confirmé 120 € à compter de J+30 ; applicable aujourd''hui : 100 €',
  (select tarif_vente_ht = 120 and tarif_date_effet = fne.aujourdhui() + 30
          and (public.finance_tarif_a_date(tarif_historique, fne.aujourdhui()) ->> 'tarif')::numeric = 100
     from public.projets where id = :'pr2'));

-- ===================== Aperçu : sélection, arrondis, exclusions =====================
select public.finance_calculer(:CR, fne.jour(1), array[:'pr1', :'pr2']::uuid[], :TVA_MQ) as calc \gset
select fne.put('E', :'calc'::jsonb ->> 'empreinte');
select fne.ok('aperçu sans blocage', jsonb_array_length(:'calc'::jsonb -> 'blocages') = 0, :'calc'::jsonb ->> 'blocages');
select fne.ok('temps facturés : T1, T2, T3 (10,01 €), T4 (80 €), T5 (100 €) — ni le brouillon, ni le mois en cours, ni le forfait, ni mes temps',
  (select string_agg(e ->> 'id', ',' order by e ->> 'id') from jsonb_array_elements(:'calc'::jsonb -> 'temps') e)
  = (select string_agg(x::text, ',' order by x::text) from unnest(array[:'t1', :'t2', :'t3', :'t4', :'t5']::uuid[]) x));
select fne.ok('lignes par projet et tarif, écart d''arrondi montré sans modifier le total',
  (select string_agg((l ->> 'projet_nom') || ' ' || (l ->> 'tarif') || ' ' || (l ->> 'heures') || 'h ' || (l ->> 'montant_ht')
                     || ' (théorique ' || (l ->> 'montant_theorique') || ', écart ' || (l ->> 'ecart_arrondi') || ')', ' | '
                     order by l ->> 'projet_nom', l ->> 'date_effet') from jsonb_array_elements(:'calc'::jsonb -> 'lignes') l)
  = 'Mission régie 10.01 0.75h 7.50 (théorique 7.51, écart -0.01) | Mission régie 80 2.50h 200.00 (théorique 200.00, écart 0.00) | Mission régie 2 100 1.00h 100.00 (théorique 100.00, écart 0.00)',
  :'calc'::jsonb ->> 'lignes');
select fne.ok('totaux : HT 307,50 ; TVA 8,5 % 26,14 (26,1375) ; TTC 333,64',
  (:'calc'::jsonb -> 'totaux') = '{"heures": 4.25, "total_ht": 307.50, "tva": 26.14, "total_ttc": 333.64}'::jsonb, :'calc'::jsonb ->> 'totaux');
select fne.ok('sélection d''un seul projet : seuls ses temps (207,50 € HT)',
  (public.finance_calculer(:CR, fne.jour(1), array[:'pr1']::uuid[], :TVA_MQ) -> 'totaux' ->> 'total_ht')::numeric = 207.50);
select fne.ok('projet au forfait sélectionné : bloqué, message clair',
  (public.finance_calculer(:CR, fne.jour(1), array[:'pr1', :'pf']::uuid[], :TVA_MQ) -> 'blocages')
  @> '["Projet « Mission forfait » : mode de facturation « forfait » ; seuls les projets au temps passé sont facturables dans cette version."]');
select fne.ok('projet sans tarif : « Tarif de vente non confirmé »',
  (public.finance_calculer('33333333-3333-3333-3333-333333333331', fne.jour(1),
     array[(select id from public.projets where nom = 'Projet démo 1')], :TVA_MQ) -> 'blocages')::text like '%Tarif de vente non confirmé pour le projet « Projet démo 1 »%');
select fne.ok('client sans adresse : bloqué', (public.finance_calculer('33333333-3333-3333-3333-333333333331', fne.jour(1),
     array[(select id from public.projets where nom = 'Projet démo 1')], :TVA_MQ) -> 'blocages')::text like '%Adresse du client manquante%');
select fne.ok('mois futur : bloqué', (public.finance_calculer(:CR, fne.aujourdhui() + 40, array[:'pr1']::uuid[], :TVA_MQ) -> 'blocages')::text like '%Mois futur%');
select fne.ok('TVA absente : bloqué', (public.finance_calculer(:CR, fne.jour(1), array[:'pr1']::uuid[], '{}') -> 'blocages')::text like '%Traitement de TVA à renseigner%');
select fne.ok('TVA incohérente (taux réduit sans justification) : bloqué',
  (public.finance_calculer(:CR, fne.jour(1), array[:'pr1']::uuid[],
     '{"regime":"taxable","territoire":"MQ","taux":2.1,"criteres":{"nature_mission":"prestation_intellectuelle","statut_client":"assujetti_france"}}') -> 'blocages')::text like '%justification obligatoire%');
select fne.ok('aperçu sans écriture : aucun numéro, aucune facture, aucun temps réservé',
  (select count(*) = 0 from public.factures) and (select count(*) = 0 from public.compteurs where cle like '%facture%')
  and (select count(*) = 0 from public.temps where facture_id is not null));

-- ===================== Émission (facture « réelle » de la base locale) =====================
\set CLE1 '\'cccccccc-0000-0000-0000-000000000001\''
select fne.refus('émission réelle : coordonnées et conditions vides → bloquée', format($q$select public.finance_emettre_facture('%s', '%s', '%s', '%s', array['%s', '%s']::uuid[], '%s', '%s', '%s', '%s', 'facture-v1')$q$,
  :ADMIN, :CLE1, :CR, fne.jour(1), :'pr1', :'pr2', :TVA_MQ, fne.get('E'), :VIDE, :COND_VIDE), 'incomplètes');
select fne.refus('émission réelle : coordonnées [DÉMO] interdites', format($q$select public.finance_emettre_facture('%s', '%s', '%s', '%s', array['%s', '%s']::uuid[], '%s', '%s', '%s', '%s', 'facture-v1')$q$,
  :ADMIN, :CLE1, :CR, fne.jour(1), :'pr1', :'pr2', :TVA_MQ, fne.get('E'), :DEMO, :COND_DEMO), 'démonstration interdites');
select fne.ok('refus avant numéro : aucun compteur consommé', (select count(*) = 0 from public.compteurs where cle like 'facture_%'));
-- Aperçu périmé : un temps rouvert (puis revalidé : même sélection, même empreinte).
select public.rh_changer_statut_temps(:ADMIN, array[:'t5']::uuid[], 'rouvrir', 'Vérification test');
select fne.refus('aperçu périmé (un temps n''est plus validé) : émission refusée, rien d''émis', format($q$select public.finance_emettre_facture('%s', '%s', '%s', '%s', array['%s', '%s']::uuid[], '%s', '%s', '%s', '%s', 'facture-v1')$q$,
  :ADMIN, :CLE1, :CR, fne.jour(1), :'pr1', :'pr2', :TVA_MQ, fne.get('E'), :SIMU, :COND_SIMU), 'Aperçu périmé');
select public.rh_changer_statut_temps(:ADMIN, array[:'t5']::uuid[], 'soumettre', null);
select public.rh_changer_statut_temps(:ADMIN, array[:'t5']::uuid[], 'valider', null);
select fne.ok('même sélection retrouvée : même empreinte',
  public.finance_calculer(:CR, fne.jour(1), array[:'pr1', :'pr2']::uuid[], :TVA_MQ) ->> 'empreinte' = fne.get('E'));
-- Aperçu périmé : tarif corrigé entre l'aperçu et l'émission.
set role service_role;
select public.finance_corriger_tarif(:ADMIN, :'pr1', (select id from public.finance_periodes_actives((select tarif_historique from public.projets where id = :'pr1')) order by date_effet desc limit 1),
  85, 'Avenant 1', 'Essai de correction', public.finance_temps_concernes(:'pr1', fne.jour(11)) ->> 'empreinte');
reset role;
select fne.refus('aperçu périmé (tarif corrigé) : émission refusée', format($q$select public.finance_emettre_facture('%s', '%s', '%s', '%s', array['%s', '%s']::uuid[], '%s', '%s', '%s', '%s', 'facture-v1')$q$,
  :ADMIN, :CLE1, :CR, fne.jour(1), :'pr1', :'pr2', :TVA_MQ, fne.get('E'), :SIMU, :COND_SIMU), 'Aperçu périmé');
set role service_role;
select public.finance_corriger_tarif(:ADMIN, :'pr1', (select id from public.finance_periodes_actives((select tarif_historique from public.projets where id = :'pr1')) order by date_effet desc limit 1),
  80, 'Avenant 1', 'Retour au tarif du contrat', public.finance_temps_concernes(:'pr1', fne.jour(11)) ->> 'empreinte');
reset role;
select public.finance_calculer(:CR, fne.jour(1), array[:'pr1', :'pr2']::uuid[], :TVA_MQ) as calc \gset
select fne.put('E', :'calc'::jsonb ->> 'empreinte');
-- Panne simulée APRÈS l'attribution du numéro : tout est annulé, le numéro est rendu.
create function fne.panne() returns trigger language plpgsql as $$ begin raise exception 'PANNE SIMULÉE'; end $$;
create trigger zz_panne before insert on public.factures for each row execute function fne.panne();
select fne.refus('panne pendant l''émission : erreur remontée', format($q$select public.finance_emettre_facture('%s', '%s', '%s', '%s', array['%s', '%s']::uuid[], '%s', '%s', '%s', '%s', 'facture-v1')$q$,
  :ADMIN, :CLE1, :CR, fne.jour(1), :'pr1', :'pr2', :TVA_MQ, fne.get('E'), :SIMU, :COND_SIMU), 'PANNE SIMULÉE');
drop trigger zz_panne on public.factures;
select fne.ok('après la panne : aucun numéro consommé, aucune facture, aucun temps rattaché',
  (select coalesce(max(valeur), 0) = 0 from public.compteurs where cle like 'facture_%')
  and (select count(*) = 0 from public.factures) and (select count(*) = 0 from public.temps where facture_id is not null));
set role service_role;
select public.finance_emettre_facture(:ADMIN, :CLE1, :CR, fne.jour(1), array[:'pr1', :'pr2']::uuid[], :TVA_MQ, fne.get('E'), :SIMU, :COND_SIMU, 'facture-v1') as em1 \gset
select public.finance_emettre_facture(:ADMIN, :CLE1, :CR, fne.jour(1), array[:'pr1', :'pr2']::uuid[], :TVA_MQ, fne.get('E'), :SIMU, :COND_SIMU, 'facture-v1') as em2 \gset
reset role;
select (:'em1'::jsonb ->> 'facture_id') as f1 \gset
select fne.ok('émission : numéro FAC-AAAA-0001 (année de la Martinique)',
  :'em1'::jsonb ->> 'numero' = 'FAC-' || to_char(fne.aujourdhui(), 'YYYY') || '-0001', :'em1');
select fne.ok('double clic / coupure réseau : même clé → même facture, aucun second numéro',
  :'em2'::jsonb ->> 'facture_id' = :'f1' and (:'em2'::jsonb ->> 'deja_emise')::boolean
  and (select count(*) = 1 from public.factures) and (select valeur = 1 from public.compteurs where cle like 'facture_%'));
select fne.refus('même clé pour une autre sélection : refusée', format($q$select public.finance_emettre_facture('%s', '%s', '%s', '%s', array['%s']::uuid[], '%s', 'autre', '%s', '%s', 'facture-v1')$q$,
  :ADMIN, :CLE1, :CR, fne.jour(1), :'pr1', :TVA_MQ, :SIMU, :COND_SIMU), 'déjà servi');
select fne.ok('facture : totaux, période, échéance (+30 j), statut émise, PDF à générer',
  (select total_ht = 307.50 and tva = 26.14 and total_ttc = 333.64 and periode_debut = fne.jour(1)
          and periode_fin = (date_trunc('month', fne.jour(1)) + interval '1 month - 1 day')::date
          and date_emission = fne.aujourdhui() and date_echeance = fne.aujourdhui() + 30 and statut = 'emise'
          and pdf_statut = 'a_generer' and not essai and emise_par = '11111111-1111-1111-1111-111111111111'
     from public.factures where id = :'f1'));
select fne.ok('aperçu = instantané = facture = somme des temps (mêmes montants)',
  (select instantane_emission -> 'lignes' = :'calc'::jsonb -> 'lignes' and instantane_emission -> 'totaux' = :'calc'::jsonb -> 'totaux'
          and instantane_emission -> 'temps' = :'calc'::jsonb -> 'temps'
          and (select sum(montant_facture_ht) from public.temps where facture_id = :'f1') = total_ht
          and (select sum((l ->> 'montant_ht')::numeric) from jsonb_array_elements(instantane_emission -> 'lignes') l) = total_ht
     from public.factures where id = :'f1'));
select fne.ok('temps rattachés avec le tarif contractuel de leur date (10,01 / 80 / 100) et leur montant arrondi',
  (select string_agg(taux_facture || '=' || montant_facture_ht, ' ' order by date_saisie) from public.temps where facture_id = :'f1')
  = '10.01=2.50 10.01=2.50 10.01=2.50 100.00=100.00 80.00=200.00');
select fne.ok('instantané : émetteur, conditions, client, TVA et gabarit figés',
  (select instantane_emission -> 'emetteur' = :SIMU::jsonb and instantane_emission -> 'conditions' = :COND_SIMU::jsonb
          and instantane_emission -> 'client' ->> 'adresse' like '5 rue du Test%' and instantane_emission ->> 'gabarit' = 'facture-v1'
          and instantane_emission -> 'tva' ->> 'regime' = 'taxable' from public.factures where id = :'f1'));
select fne.ok('historique du temps : événement « facturation » sans montant ni tarif',
  (select bool_and(e ->> 'facture' = :'f1' and not (e ? 'montant') and not (e ? 'tarif') and not (e ? 'taux'))
     from public.temps t, jsonb_array_elements(t.historique) e where t.facture_id = :'f1' and e ->> 'action' = 'facturation'));

-- ===================== Double facturation impossible ; facture et temps figés =====================
select fne.ok('nouvel aperçu : plus rien à facturer', (public.finance_calculer(:CR, fne.jour(1), array[:'pr1', :'pr2']::uuid[], :TVA_MQ) -> 'blocages')::text like '%Aucun temps validé et non facturé%');
select fne.refus('nouvelle émission (autre clé) sur les mêmes temps : refusée', format($q$select public.finance_emettre_facture('%s', '%s', '%s', '%s', array['%s', '%s']::uuid[], '%s', '%s', '%s', '%s', 'facture-v1')$q$,
  :ADMIN, 'cccccccc-0000-0000-0000-000000000002', :CR, fne.jour(1), :'pr1', :'pr2', :TVA_MQ, fne.get('E'), :SIMU, :COND_SIMU), 'Aucun temps validé');
set role service_role;
select fne.refus('temps facturé : rattachement à une autre facture refusé', format($q$update public.temps set facture_id = null, taux_facture = null, montant_facture_ht = null where id = '%s'$q$, :'t1'), 'facturé');
select fne.refus('temps facturé : taux modifié refusé', format($q$update public.temps set taux_facture = 1, montant_facture_ht = 0.25 where id = '%s'$q$, :'t1'), 'facturé');
select fne.refus('temps facturé : suppression refusée (même clé secrète)', format($q$delete from public.temps where id = '%s'$q$, :'t1'), 'facturé');
select fne.refus('temps facturé : réouverture refusée', format($q$select public.rh_changer_statut_temps('%s', array['%s']::uuid[], 'rouvrir', 'motif')$q$, :ADMIN, :'t4'), 'facturé');
reset role;
select fne.refus('facture : montant modifié refusé (tableau de bord)', format($q$update public.factures set total_ht = 1, total_ttc = 27.14 where id = '%s'$q$, :'f1'), 'ne se modifie jamais');
select fne.refus('facture : numéro modifié refusé', format($q$update public.factures set numero = 'FAC-X' where id = '%s'$q$, :'f1'), 'ne se modifie jamais');
select fne.refus('facture : instantané modifié refusé', format($q$update public.factures set instantane_emission = '{}' where id = '%s'$q$, :'f1'), 'ne se modifie jamais');
select fne.refus('facture : statut changé directement refusé (aucune correction par statut)', format($q$update public.factures set statut = 'brouillon' where id = '%s'$q$, :'f1'), 'réservée à l''écran Finance');
select fne.refus('facture : historique réécrit refusé', format($q$update public.factures set historique = '[]' where id = '%s'$q$, :'f1'), 'alimenté par la base');
select fne.refus('facture : suppression refusée', format($q$delete from public.factures where id = '%s'$q$, :'f1'), 'ne se supprime jamais');
select fne.refus('facture réelle : suppression refusée même avec le contexte de nettoyage', format($q$do $x$ begin
  perform public.finance_contexte('nettoyage_essais', null, null); delete from public.factures where id = '%s'; end $x$$q$, :'f1'), 'ne se supprime jamais');
select fne.refus('facture créée hors émission refusée', format($q$insert into public.factures (client_id) values ('%s')$q$, :CR), 'naît uniquement de l''émission');
select fne.refus('après facturation : nouveau tarif rétroactif couvrant des temps facturés refusé', format($q$select public.finance_confirmer_tarif('%s', '%s', 99, '%s', 'Avenant 3', '%s')$q$,
  :ADMIN, :'pr1', fne.jour(12), public.finance_temps_concernes(:'pr1', fne.jour(12)) ->> 'empreinte'), 'déjà facturés');
select fne.refus('après facturation : correction du tarif appliqué refusée', format($q$select public.finance_corriger_tarif('%s', '%s', '%s', 81, 'Avenant 1', 'Erreur', '%s')$q$,
  :ADMIN, :'pr1', (select id from public.finance_periodes_actives((select tarif_historique from public.projets where id = :'pr1')) order by date_effet desc limit 1),
  public.finance_temps_concernes(:'pr1', fne.jour(11)) ->> 'empreinte'), 'déjà facturés');
select fne.refus('après facturation : mode du projet figé', format($q$select public.finance_definir_mode('%s', '%s', 'forfait')$q$, :ADMIN, :'pr1'), 'Mode figé');
set role service_role;
select fne.passe('nouveau tarif à date d''effet future (temps facturés non touchés)', format($q$select public.finance_confirmer_tarif('%s', '%s', 95, '%s', 'Avenant 3', '%s')$q$,
  :ADMIN, :'pr1', fne.aujourdhui() + 1, public.finance_temps_concernes(:'pr1', fne.aujourdhui() + 1) ->> 'empreinte'));
reset role;
select fne.ok('temps facturés inchangés après le nouveau tarif',
  (select string_agg(taux_facture || '=' || montant_facture_ht, ' ' order by date_saisie) from public.temps where facture_id = :'f1')
  = '10.01=2.50 10.01=2.50 10.01=2.50 100.00=100.00 80.00=200.00');

-- ===================== PDF, envoi déclaré, règlement intégral =====================
select fne.refus('envoi déclaré avant le PDF : refusé', format($q$select public.finance_declarer_envoi('%s', '%s', now(), 'email', 'compta@exemple.invalid')$q$, :ADMIN, :'f1'), 'pas encore disponible');
select fne.put('chemin', :'f1' || '/' || (:'em1'::jsonb ->> 'numero') || '.pdf');
insert into storage.objects (bucket_id, name, metadata) values ('factures', fne.get('chemin'), '{"size": 1234}');
select fne.refus('PDF : taille différente du fichier stocké refusée', format($q$select public.finance_enregistrer_pdf('%s', '%s', '%s', 99)$q$, :'f1', fne.get('chemin'), repeat('c', 64)), 'taille différente');
select public.finance_signaler_echec_pdf(:'f1', 'Échec simulé');
select fne.ok('échec du PDF signalé : numéro et instantané conservés, reprise possible',
  (select pdf_statut = 'echec' and numero = :'em1'::jsonb ->> 'numero' and instantane_emission is not null from public.factures where id = :'f1'));
set role service_role;
select public.finance_enregistrer_pdf(:'f1', fne.get('chemin'), repeat('c', 64), 1234);
select fne.passe('PDF : nouvel enregistrement identique sans effet (reprise)', format($q$select public.finance_enregistrer_pdf('%s', '%s', '%s', 1234)$q$, :'f1', fne.get('chemin'), repeat('c', 64)));
select fne.refus('PDF : un autre fichier ne remplace pas l''archive', format($q$select public.finance_enregistrer_pdf('%s', '%s', '%s', 1234)$q$, :'f1', fne.get('chemin'), repeat('d', 64)), 'différent');
select fne.refus('canal d''envoi inconnu refusé', format($q$select public.finance_declarer_envoi('%s', '%s', now(), 'pigeon', null)$q$, :ADMIN, :'f1'), 'Canal');
select fne.refus('règlement avant l''envoi refusé', format($q$select public.finance_enregistrer_reglement('%s', '%s', '%s', 'virement', null, true)$q$, :ADMIN, :'f1', fne.aujourdhui()), 'Déclarez d''abord l''envoi');
select public.finance_declarer_envoi(:ADMIN, :'f1', now(), 'email', 'compta@exemple.invalid');
select fne.refus('second envoi refusé', format($q$select public.finance_declarer_envoi('%s', '%s', now(), 'email', null)$q$, :ADMIN, :'f1'), 'déjà déclaré');
select fne.refus('paiement partiel : rien n''est enregistré, message explicite', format($q$select public.finance_enregistrer_reglement('%s', '%s', '%s', 'virement', null, false)$q$, :ADMIN, :'f1', fne.aujourdhui()), 'Paiement partiel non géré dans cette version');
select fne.ok('après le refus du paiement partiel : facture toujours « envoyée », aucun règlement',
  (select statut = 'envoyee' and date_reglement is null from public.factures where id = :'f1'));
select fne.refus('règlement daté dans le futur refusé', format($q$select public.finance_enregistrer_reglement('%s', '%s', '%s', 'virement', null, true)$q$, :ADMIN, :'f1', fne.aujourdhui() + 1), 'future');
select public.finance_enregistrer_reglement(:ADMIN, :'f1', fne.aujourdhui(), 'cheque', 'CHQ 123', true);
select fne.refus('second règlement refusé', format($q$select public.finance_enregistrer_reglement('%s', '%s', '%s', 'virement', null, true)$q$, :ADMIN, :'f1', fne.aujourdhui()), 'déjà enregistré');
select fne.refus('correction du règlement sans motif refusée', format($q$select public.finance_corriger_reglement('%s', '%s', 'modifier', '%s', 'virement', null, 'x')$q$, :ADMIN, :'f1', fne.aujourdhui()), 'motif');
select public.finance_corriger_reglement(:ADMIN, :'f1', 'modifier', fne.aujourdhui(), 'virement', 'VIR 456', 'Mode saisi par erreur');
select fne.ok('correction « modifier » : nouveau mode, ancienne déclaration conservée dans l''historique',
  (select mode_reglement = 'virement' and historique -> -1 ->> 'action' = 'reglement_corrige'
          and historique -> -1 -> 'precedent' ->> 'mode' = 'cheque' and historique -> -1 ->> 'motif' = 'Mode saisi par erreur'
     from public.factures where id = :'f1'));
select public.finance_corriger_reglement(:ADMIN, :'f1', 'annuler', null, null, null, 'Règlement déclaré par erreur');
reset role;
select fne.ok('correction « annuler » : facture « envoyée », contenu et montants inchangés, historique complet',
  (select statut = 'envoyee' and date_reglement is null and total_ttc = 333.64 and instantane_emission -> 'totaux' ->> 'total_ttc' = '333.64'
          and (select string_agg(e ->> 'action', ',' order by o) from jsonb_array_elements(historique) with ordinality x(e, o))
              = 'emission,pdf_echec,pdf_archive,envoi_declare,reglement_integral,reglement_corrige,reglement_annule'
     from public.factures where id = :'f1'));

-- ===================== Essais : TVA incompatible, mélange, séquence indépendante, nettoyage =====================
select public.creer_prospect_essai('Finance', 'Finance Essai SARL', '1 rue de l''Essai', '97200', 'Fort-de-France', 'MQ') as pe \gset
insert into public.devis (prospect_id) values (:'pe') returning id as d1 \gset
insert into public.devis_lignes (devis_id, designation, quantite, prix_unitaire) values (:'d1', 'Régie', 1, 100);
update public.devis set regime_tva = 'taxable', territoire_tva = 'MQ', taux_tva = 8.5, type_mission = 'conseil',
       criteres_tva = '{"nature_mission":"prestation_intellectuelle","statut_client":"assujetti_france"}' where id = :'d1';
insert into public.devis (prospect_id) values (:'pe') returning id as d2 \gset
insert into public.devis_lignes (devis_id, designation, quantite, prix_unitaire) values (:'d2', 'Régie métropole', 1, 100);
update public.devis set regime_tva = 'taxable', territoire_tva = 'FR', taux_tva = 20, type_mission = 'conseil',
       criteres_tva = '{"nature_mission":"prestation_intellectuelle","statut_client":"assujetti_france","lieu_client":"FR"}' where id = :'d2';
select public.emettre_devis(:'d1', :ADMIN, :DEMO::jsonb || '{"validite_jours":"30","obligation_assurance":"non_requise"}', 'devis-v1');
select public.emettre_devis(:'d2', :ADMIN, :DEMO::jsonb || '{"validite_jours":"30","obligation_assurance":"non_requise"}', 'devis-v1');
update public.devis set pdf_statut = 'disponible', pdf_chemin = id || '/' || numero || '.pdf', pdf_empreinte = repeat('e', 64),
       pdf_taille = 1, pdf_archive_le = now() where id in (:'d1', :'d2');
select public.declarer_envoi_devis(:'d1', :ADMIN, now(), 'autre', null);
select public.declarer_envoi_devis(:'d2', :ADMIN, now(), 'autre', null);
select public.decider_devis(:'d1', :ADMIN, 'accepte');
select public.decider_devis(:'d2', :ADMIN, 'accepte');
select id as pe1, client_id as ce from public.projets where devis_id = :'d1' \gset
select id as pe2 from public.projets where devis_id = :'d2' \gset
select public.finance_definir_mode(:ADMIN, :'pe1', 'temps_passe');
select public.finance_definir_mode(:ADMIN, :'pe2', 'temps_passe');
select public.finance_confirmer_tarif(:ADMIN, :'pe1', 50, fne.jour(1), 'Essai', public.finance_temps_concernes(:'pe1', fne.jour(1)) ->> 'empreinte');
select public.finance_confirmer_tarif(:ADMIN, :'pe2', 50, fne.jour(1), 'Essai', public.finance_temps_concernes(:'pe2', fne.jour(1)) ->> 'empreinte');
select public.rh_enregistrer_temps(:ADMIN, null, :FLEA, :'pe1', fne.jour(8), 1, null, 'Essai') as te1 \gset
select public.rh_enregistrer_temps(:ADMIN, null, :FLEA, :'pe2', fne.jour(9), 1, null, 'Essai') as te2 \gset
select public.rh_changer_statut_temps(:ADMIN, array[:'te1', :'te2']::uuid[], 'soumettre', null);
select public.rh_changer_statut_temps(:ADMIN, array[:'te1', :'te2']::uuid[], 'valider', null);
select fne.ok('TVA incompatible entre projets (devis MQ 8,5 % et FR 20 %) : regroupement refusé',
  (public.finance_calculer(:'ce', fne.jour(1), array[:'pe1', :'pe2']::uuid[], :TVA_MQ) -> 'blocages')::text like '%TVA incompatible : le projet « [ESSAI] Projet ESSAI-DEV-%');
select fne.ok('projet d''essai et projet réel mélangés : refusé',
  (public.finance_calculer(:'ce', fne.jour(1), array[:'pe1', :'pr1']::uuid[], :TVA_MQ) -> 'blocages')::text like '%mélangés%');
select public.finance_calculer(:'ce', fne.jour(1), array[:'pe1']::uuid[], :TVA_MQ) ->> 'empreinte' as ee \gset
select fne.refus('facture d''essai : coordonnées vides refusées aussi', format($q$select public.finance_emettre_facture('%s', 'cccccccc-0000-0000-0000-0000000000e1', '%s', '%s', array['%s']::uuid[], '%s', '%s', '%s', '%s', 'facture-v1')$q$,
  :ADMIN, :'ce', fne.jour(1), :'pe1', :TVA_MQ, :'ee', :VIDE, :COND_VIDE), 'incomplètes');
select public.finance_emettre_facture(:ADMIN, 'cccccccc-0000-0000-0000-0000000000e1', :'ce', fne.jour(1), array[:'pe1']::uuid[], :TVA_MQ, :'ee', :DEMO, :COND_DEMO, 'facture-v1') as eme \gset
select (:'eme'::jsonb ->> 'facture_id') as fe \gset
select fne.ok('facture d''essai : ESSAI-FAC-AAAA-0001, compteur séparé, compteur réel inchangé (1)',
  :'eme'::jsonb ->> 'numero' = 'ESSAI-FAC-' || to_char(fne.aujourdhui(), 'YYYY') || '-0001'
  and (select essai from public.factures where id = :'fe')
  and (select valeur = 1 from public.compteurs where cle = 'facture_' || to_char(fne.aujourdhui(), 'YYYY'))
  and (select valeur = 1 from public.compteurs where cle = 'essai_facture_' || to_char(fne.aujourdhui(), 'YYYY')));
insert into public.relances (facture_id, message) values (:'fe', 'Essai de liaison');
select fne.refus('nettoyage refusé si une donnée est liée à une facture d''essai (relance) ; rien supprimé', $q$select public.supprimer_essais_finance()$q$, 'Nettoyage refusé');
select fne.ok('après le refus : facture d''essai toujours présente', (select count(*) = 1 from public.factures where essai));
delete from public.relances where facture_id = :'fe';
set role service_role;
select public.supprimer_essais_finance() as net \gset
reset role;
select fne.ok('nettoyage : facture d''essai, ses temps et le compteur d''essai supprimés ; la facture réelle intacte',
  (select count(*) = 0 from public.factures where essai) and (select count(*) = 0 from public.temps where id = :'te1')
  and (select count(*) = 0 from public.compteurs where cle like 'essai_facture_%')
  and (select count(*) = 1 from public.factures where id = :'f1') and (:'net'::jsonb ->> 'factures')::int = 1, :'net');
select fne.passe('nettoyages RH puis Commercial ensuite possibles', $q$select public.supprimer_essais_rh(), public.supprimer_essais_commercial()$q$);
select fne.ok('essais Commercial disparus, données réelles intactes',
  (select count(*) = 0 from public.devis where essai) and (select count(*) = 1 from public.factures)
  and (select count(*) = 5 from public.temps where facture_id = :'f1'));

select n || '. [' || case when ok then 'OK ' else 'ÉCHEC' end || '] ' || libelle || coalesce('  (' || left(detail, 200) || ')', '') from fne.resultats order by n;
select 'BILAN : ' || count(*) filter (where ok) || '/' || count(*) || ' contrôles réussis' from fne.resultats;
