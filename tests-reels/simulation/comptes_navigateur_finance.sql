-- Données du test navigateur Finance (base d'ESSAI locale uniquement ; à rejouer APRÈS comptes_navigateur.sql).
-- Client et projets de test (sans mode ni tarif : l'écran les définit), temps validés du mois précédent pour la
-- collaboratrice d'essai (fiche Moreau), un temps en brouillon, et une chaîne d'ESSAI (devis d'essai accepté).
\set ON_ERROR_STOP 1
insert into public.collaborateurs (id, nom, prenom, taux_horaire) values ('22222222-2222-2222-2222-2222222222fa', 'Admin', 'Sgi', 37);
update public.profiles set collaborateur_id = '22222222-2222-2222-2222-2222222222fa' where email = 'sgi@gmx.fr';
insert into public.clients (id, nom, adresse) values
  ('33333333-3333-3333-3333-3333333333b1', 'Client navigateur', E'5 rue du Navigateur\n97200 Fort-de-France\nMQ');
insert into public.projets (id, nom, client_id) values
  ('44444444-4444-4444-4444-4444444444b1', 'Régie navigateur', '33333333-3333-3333-3333-3333333333b1'),
  ('44444444-4444-4444-4444-4444444444b2', 'Régie navigateur 2', '33333333-3333-3333-3333-3333333333b1'),
  ('44444444-4444-4444-4444-4444444444b3', 'Forfait navigateur', '33333333-3333-3333-3333-3333333333b1');
create temp table mois as select (date_trunc('month', (now() at time zone 'America/Martinique')::date) - interval '1 month')::date as d;
create temp table t as
select public.rh_enregistrer_temps('11111111-1111-1111-1111-111111111111', null, '22222222-2222-2222-2222-222222222221',
         p::uuid, (select d from mois) + j, h, null, 'Régularisation (essai navigateur)') as id, k
  from (values ('44444444-4444-4444-4444-4444444444b1', 1, 0.25, 'a'), ('44444444-4444-4444-4444-4444444444b1', 2, 0.25, 'b'),
               ('44444444-4444-4444-4444-4444444444b1', 3, 0.25, 'c'), ('44444444-4444-4444-4444-4444444444b1', 14, 2.5, 'd'),
               ('44444444-4444-4444-4444-4444444444b2', 4, 1, 'e'), ('44444444-4444-4444-4444-4444444444b1', 19, 1, 'brouillon'))
       as v(p, j, h, k);
select public.rh_changer_statut_temps('11111111-1111-1111-1111-111111111111', array(select id from t where k <> 'brouillon'), 'soumettre', null);
select public.rh_changer_statut_temps('11111111-1111-1111-1111-111111111111', array(select id from t where k <> 'brouillon'), 'valider', null);
-- Chaîne d'ESSAI : prospect d'essai → devis d'essai émis, envoyé, accepté → client et projet [ESSAI].
create temp table pe as select public.creer_prospect_essai('Navigateur', 'Navigateur Essai SARL', '1 rue de l''Essai', '97200',
  'Fort-de-France', 'MQ') as id;
insert into public.devis (id, prospect_id) select '55555555-5555-5555-5555-5555555555b1', id from pe;
insert into public.devis_lignes (devis_id, designation, quantite, prix_unitaire) values ('55555555-5555-5555-5555-5555555555b1', 'Régie', 1, 100);
update public.devis set regime_tva = 'taxable', territoire_tva = 'MQ', taux_tva = 8.5, type_mission = 'conseil',
       criteres_tva = '{"nature_mission":"prestation_intellectuelle","statut_client":"assujetti_france"}'
 where id = '55555555-5555-5555-5555-5555555555b1';
select public.emettre_devis('55555555-5555-5555-5555-5555555555b1', '11111111-1111-1111-1111-111111111111',
  '{"raison_sociale":"[DÉMO] SG Ingénierie","forme_juridique":"SAS","capital_social":"[DÉMO]","adresse":"[DÉMO] adresse","code_postal":"97200","ville":"Fort-de-France","siret":"00000000000000","immatriculation":"[DÉMO]","tva_intracom":"[DÉMO]","validite_jours":"30","obligation_assurance":"non_requise"}',
  'devis-v1');
update public.devis set pdf_statut = 'disponible', pdf_chemin = id || '/' || numero || '.pdf', pdf_empreinte = repeat('e', 64),
       pdf_taille = 1, pdf_archive_le = now() where id = '55555555-5555-5555-5555-5555555555b1';
select public.declarer_envoi_devis('55555555-5555-5555-5555-5555555555b1', '11111111-1111-1111-1111-111111111111', now(), 'autre', null);
select public.decider_devis('55555555-5555-5555-5555-5555555555b1', '11111111-1111-1111-1111-111111111111', 'accepte');
select public.finance_definir_mode('11111111-1111-1111-1111-111111111111', p.id, 'temps_passe'),
       public.finance_confirmer_tarif('11111111-1111-1111-1111-111111111111', p.id, 50, (select d from mois), 'Essai',
         public.finance_temps_concernes(p.id, (select d from mois)) ->> 'empreinte')
  from public.projets p where p.devis_id = '55555555-5555-5555-5555-5555555555b1';
select public.rh_changer_statut_temps('11111111-1111-1111-1111-111111111111', array[x], 'soumettre', null),
       public.rh_changer_statut_temps('11111111-1111-1111-1111-111111111111', array[x], 'valider', null)
  from (select public.rh_enregistrer_temps('11111111-1111-1111-1111-111111111111', null, '22222222-2222-2222-2222-222222222221',
          p.id, (select d from mois) + 5, 2, null, 'Essai') as x from public.projets p
         where p.devis_id = '55555555-5555-5555-5555-5555555555b1') s;
