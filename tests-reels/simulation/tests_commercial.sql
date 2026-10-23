-- Tests du module Commercial sur la base d'ESSAI locale (rôles et jetons simulés).
\set QUIET on
\pset tuples_only on
\pset format unaligned

create schema essai;
grant usage on schema essai to authenticated, anon, service_role;
create table essai.resultats (n serial, libelle text, ok boolean, detail text);
grant all on essai.resultats to authenticated, anon, service_role;
grant usage on sequence essai.resultats_n_seq to authenticated, anon, service_role;

create function essai.ok(p_libelle text, p_ok boolean, p_detail text default '') returns void
language sql as $$ insert into essai.resultats (libelle, ok, detail) values (p_libelle, coalesce(p_ok, false), p_detail) $$;
-- Exécute une requête qui DOIT échouer.
create function essai.refus(p_libelle text, p_sql text) returns void language plpgsql as $$
begin
  execute p_sql;
  perform essai.ok(p_libelle, false, 'accepté alors qu''il devait être refusé');
exception when others then
  perform essai.ok(p_libelle, true, left(sqlerrm, 90));
end $$;
-- Exécute une requête qui DOIT réussir.
create function essai.accepte(p_libelle text, p_sql text) returns void language plpgsql as $$
begin
  execute p_sql;
  perform essai.ok(p_libelle, true);
exception when others then
  perform essai.ok(p_libelle, false, left(sqlerrm, 120));
end $$;
create function essai.valeur(p_sql text) returns text language plpgsql as $$
declare v text;
begin execute p_sql into v; return v;
exception when others then return 'ERREUR: ' || left(sqlerrm, 80); end $$;
create function essai.emetteur() returns jsonb language sql as $$ select '{"raison_sociale":"SIMULATION SG Ingénierie","forme_juridique":"SAS","capital_social":"SIMULATION","adresse":"SIMULATION adresse","code_postal":"97200","ville":"Fort-de-France","siret":"00000000000000","immatriculation":"SIMULATION RCS","tva_intracom":"FR00000000000","validite_jours":"30","obligation_assurance":"non_requise"}'::jsonb $$;
create function essai.emetteur_assure() returns jsonb language sql as $$ select essai.emetteur() || '{"obligation_assurance":"obligatoire","assurance_assureur":"SIMULATION","assurance_contrat":"SIMULATION","assurance_couverture":"SIMULATION"}'::jsonb $$;
create function essai.emetteur_demo() returns jsonb language sql as $$ select essai.emetteur() || '{"raison_sociale":"[DÉMO] SG Ingénierie"}'::jsonb $$;
grant execute on all functions in schema essai to authenticated, anon, service_role;

-- Comptes : admin (sgi existant), manager, collaborateur, manager provisoire, collaborateur à jeton périmé
insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000002', 'manager@exemple.invalid'),
  ('aaaaaaaa-0000-0000-0000-000000000003', 'collab@exemple.invalid'),
  ('aaaaaaaa-0000-0000-0000-000000000004', 'provisoire@exemple.invalid'),
  ('aaaaaaaa-0000-0000-0000-000000000005', 'perime@exemple.invalid');
update public.profiles set role = 'manager' where email in ('manager@exemple.invalid', 'provisoire@exemple.invalid');
update public.profiles set role = 'collaborateur', collaborateur_id = '22222222-2222-2222-2222-222222222221'
 where email = 'collab@exemple.invalid';
update auth.users set raw_app_meta_data = '{"doit_changer_mot_de_passe": true}' where email = 'provisoire@exemple.invalid';
insert into auth.sessions (id, user_id) values
  ('bbbbbbbb-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000002'),
  ('bbbbbbbb-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000003'),
  ('bbbbbbbb-0000-0000-0000-000000000004', 'aaaaaaaa-0000-0000-0000-000000000004');
-- (perime : aucune session → jeton d'une session fermée)

create function essai.qui(p_user uuid, p_session uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated', 'session_id', p_session)::text, false);
$$;
grant execute on function essai.qui(uuid, uuid) to authenticated, anon, service_role;

alter table public.devis alter column type_mission set default 'conseil';

-- ===================== MANAGER : saisie d'un prospect et d'un devis =====================
select essai.qui('aaaaaaaa-0000-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-000000000002');
set role authenticated;
select essai.refus('manager : ne choisit pas l''identifiant d''un prospect',
  $q$insert into public.prospects (id, nom) values ('cccccccc-0000-0000-0000-000000000001','X')$q$);
reset role;
alter table public.prospects alter column id set default 'cccccccc-0000-0000-0000-000000000001'::uuid;
alter table public.devis alter column id set default 'dddddddd-0000-0000-0000-000000000001'::uuid;
set role authenticated;
select essai.accepte('manager : crée un prospect',
  $q$insert into public.prospects (nom, societe, email, telephone, adresse, ville, pays) values
     ('Mme Client','BTP Caraïbes','contact@exemple.invalid','0596000000','12 rue des Essais','Fort-de-France','MQ')$q$);
select essai.refus('manager : ne crée pas un prospect « gagné »',
  $q$insert into public.prospects (nom, statut) values ('X', 'gagne')$q$);
select essai.accepte('manager : crée un devis brouillon',
  $q$insert into public.devis (prospect_id) select id from public.prospects where email = 'contact@exemple.invalid'$q$);
reset role;
alter table public.prospects alter column id set default gen_random_uuid();
alter table public.devis alter column id set default gen_random_uuid();
set role authenticated;
select essai.refus('manager : ne crée pas un devis déjà émis',
  $q$insert into public.devis (prospect_id, statut) values ('cccccccc-0000-0000-0000-000000000001','emis')$q$);
select essai.refus('manager : ne saisit pas de numéro',
  $q$update public.devis set numero = 'DEV-2026-9999' where id = 'dddddddd-0000-0000-0000-000000000001'$q$);
select essai.refus('manager : ne change pas le statut lui-même',
  $q$update public.devis set statut = 'emis' where id = 'dddddddd-0000-0000-0000-000000000001'$q$);
select essai.refus('manager : ne saisit pas les totaux',
  $q$update public.devis set total_ht = 1 where id = 'dddddddd-0000-0000-0000-000000000001'$q$);
select essai.accepte('manager : ajoute des lignes',
  $q$insert into public.devis_lignes (devis_id, designation, quantite, prix_unitaire) values
     ('dddddddd-0000-0000-0000-000000000001','Diagnostic structure',2,450),
     ('dddddddd-0000-0000-0000-000000000001','Note de calcul',1,333.335)$q$);
select essai.refus('manager : ne force pas le montant d''une ligne',
  $q$update public.devis_lignes set montant_ht = 1 where devis_id = 'dddddddd-0000-0000-0000-000000000001'$q$);
select essai.refus('manager : pas de quantité négative hors avenant',
  $q$insert into public.devis_lignes (devis_id, designation, quantite, prix_unitaire) values ('dddddddd-0000-0000-0000-000000000001','Remise',-1,10)$q$);

-- Traitement fiscal : contrôles
select essai.refus('TVA : taux sans critères refusé',
  $q$update public.devis set regime_tva='taxable', territoire_tva='MQ', taux_tva=8.5 where id='dddddddd-0000-0000-0000-000000000001'$q$);
select essai.refus('TVA : taux réduit 2,1 % sans justification refusé',
  $q$update public.devis set regime_tva='taxable', territoire_tva='MQ', taux_tva=2.1,
     criteres_tva='{"nature_mission":"prestation_intellectuelle","statut_client":"assujetti_france"}' where id='dddddddd-0000-0000-0000-000000000001'$q$);
select essai.refus('TVA : Guyane « taxable » refusé (art. 294)',
  $q$update public.devis set regime_tva='taxable', territoire_tva='GF', taux_tva=8.5,
     criteres_tva='{"nature_mission":"prestation_intellectuelle","statut_client":"assujetti_france","justification_taux":"essai essai essai"}' where id='dddddddd-0000-0000-0000-000000000001'$q$);
select essai.refus('TVA : UE sans pays refusé',
  $q$update public.devis set regime_tva='autoliquidation', territoire_tva='UE', mention_tva='Autoliquidation',
     criteres_tva='{"nature_mission":"prestation_intellectuelle","statut_client":"assujetti_ue","numero_tva_client":"DE123"}' where id='dddddddd-0000-0000-0000-000000000001'$q$);
select essai.refus('TVA : « Europe » unique impossible (pays FR en UE refusé)',
  $q$update public.devis set regime_tva='autoliquidation', territoire_tva='UE', pays_tva='FR', mention_tva='Autoliquidation',
     criteres_tva='{"nature_mission":"prestation_intellectuelle","statut_client":"assujetti_ue","numero_tva_client":"FR123"}' where id='dddddddd-0000-0000-0000-000000000001'$q$);
select essai.refus('TVA : autoliquidation sans n° TVA client refusée',
  $q$update public.devis set regime_tva='autoliquidation', territoire_tva='UE', pays_tva='DE', mention_tva='Autoliquidation',
     criteres_tva='{"nature_mission":"prestation_intellectuelle","statut_client":"assujetti_ue"}' where id='dddddddd-0000-0000-0000-000000000001'$q$);
select essai.refus('TVA : exonération avec un taux refusée',
  $q$update public.devis set regime_tva='exoneration', territoire_tva='MQ', taux_tva=0, mention_tva='Exonération art. X',
     criteres_tva='{"nature_mission":"prestation_intellectuelle","statut_client":"assujetti_france"}' where id='dddddddd-0000-0000-0000-000000000001'$q$);
select essai.refus('TVA : mission sur immeuble sans lieu refusée',
  $q$update public.devis set regime_tva='taxable', territoire_tva='MQ', taux_tva=8.5,
     criteres_tva='{"nature_mission":"prestation_immeuble","statut_client":"assujetti_france"}' where id='dddddddd-0000-0000-0000-000000000001'$q$);
select essai.accepte('TVA : taux personnalisé 45 % justifié accepté (pas de plafond à 30 %)',
  $q$update public.devis set regime_tva='taxable', territoire_tva='UE', pays_tva='DK', taux_tva=45,
     criteres_tva='{"nature_mission":"prestation_immeuble","statut_client":"non_assujetti","lieu_immeuble":"DK","justification_taux":"essai de taux élevé justifié"}'
     where id='dddddddd-0000-0000-0000-000000000001'$q$);
select essai.accepte('TVA : Martinique 8,5 % prestation intellectuelle acceptée',
  $q$update public.devis set regime_tva='taxable', territoire_tva='MQ', pays_tva=null, taux_tva=8.5,
     criteres_tva='{"nature_mission":"prestation_intellectuelle","statut_client":"assujetti_france"}'
     where id='dddddddd-0000-0000-0000-000000000001'$q$);
select essai.ok('totaux recalculés par la base (1233,34 HT ; 104,83 TVA ; 1338,17 TTC)',
  (select total_ht = 1233.34 and tva = 104.83 and total_ttc = 1338.17 from public.devis where id='dddddddd-0000-0000-0000-000000000001'),
  (select total_ht || ' / ' || tva || ' / ' || total_ttc from public.devis where id='dddddddd-0000-0000-0000-000000000001'));
select essai.ok('manager : lit les clients', (select count(*) from public.clients) >= 2);
select essai.refus('manager : ne crée pas de client', $q$insert into public.clients (nom) values ('X')$q$);
select essai.refus('manager : ne lie pas le prospect gagné manuellement',
  $q$update public.prospects set statut='gagne' where id='cccccccc-0000-0000-0000-000000000001'$q$);
select essai.refus('manager : ne peut appeler emettre_devis avec son jeton',
  $q$select public.emettre_devis('dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002','{}','v1')$q$);
select essai.refus('manager : ne peut appeler prochain_numero',
  $q$select public.prochain_numero('devis_2026','DEV')$q$);
reset role;

-- ===================== SERVEUR (clé secrète) : émission =====================
set role service_role;
select essai.refus('émission refusée à un collaborateur (auteur vérifié en base)',
  $q$select public.emettre_devis('dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000003',essai.emetteur(),'v1')$q$);
select essai.refus('émission refusée à un manager devant changer son mot de passe',
  $q$select public.emettre_devis('dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000004',essai.emetteur(),'v1')$q$);
select essai.refus('émission sans coordonnées de l''émetteur refusée',
  $q$select public.emettre_devis('dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002',null,'v1')$q$);
select essai.refus('émission avec coordonnées incomplètes refusée (liste des champs manquants)',
  $q$select public.emettre_devis('dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002',
     essai.emetteur() - 'siret' - 'assurance_contrat','v1')$q$);
select essai.refus('coordonnées de démonstration [DÉMO] sur un devis réel : refusées',
  $q$select public.emettre_devis('dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002',essai.emetteur_demo(),'v1')$q$);
select essai.refus('assurance non déterminée pour la mission (« a_confirmer ») : émission refusée',
  $q$select public.emettre_devis('dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002',
     essai.emetteur() || '{"obligation_assurance":"a_confirmer"}','v1')$q$);
reset role;
update public.devis set type_mission = null where id = 'dddddddd-0000-0000-0000-000000000001';
set role service_role;
select essai.refus('type de mission non renseigné : émission refusée',
  $q$select public.emettre_devis('dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002',essai.emetteur(),'v1')$q$);
reset role;
update public.devis set type_mission = 'moex' where id = 'dddddddd-0000-0000-0000-000000000001';
set role service_role;
select essai.refus('MOEx sans assurance décennale déclarée obligatoire : émission refusée',
  $q$select public.emettre_devis('dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002',essai.emetteur(),'v1')$q$);
select essai.refus('MOEx avec assurance obligatoire mais contrat manquant : émission refusée',
  $q$select public.emettre_devis('dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002',essai.emetteur_assure() - 'assurance_contrat','v1')$q$);
reset role;
update public.devis set type_mission = 'conseil' where id = 'dddddddd-0000-0000-0000-000000000001';
set role service_role;
select essai.refus('émission avec SIRET invalide refusée',
  $q$select public.emettre_devis('dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002',
     essai.emetteur() || '{"siret":"123"}','v1')$q$);
select essai.refus('émission avec adresse du destinataire incomplète refusée (code postal manquant)',
  $q$select public.emettre_devis('dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002',essai.emetteur(),'v1')$q$);
reset role;
update public.prospects set code_postal = '97200' where id = 'cccccccc-0000-0000-0000-000000000001';
set role service_role;
select essai.ok('compteurs intacts après les émissions refusées',
  (select count(*) = 0 from public.compteurs));
select essai.ok('émission : numéro d''essai attribué',
  essai.valeur($q$select public.emettre_devis('dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002',essai.emetteur(),'v1')$q$) like 'DEV-____-0001',
  (select numero from public.devis where id='dddddddd-0000-0000-0000-000000000001'));
select essai.ok('nouvel essai d''émission : même numéro, aucun numéro consommé',
  essai.valeur($q$select public.emettre_devis('dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002',essai.emetteur(),'v1')$q$)
    = (select numero from public.devis where id='dddddddd-0000-0000-0000-000000000001')
  and (select valeur from public.compteurs where cle like 'devis_%') = 1);
select essai.ok('instantané figé : émetteur, adresse du destinataire, lignes, totaux, TVA',
  (select instantane_emission ->> 'numero' = numero and instantane_emission #>> '{emetteur,raison_sociale}' = 'SIMULATION SG Ingénierie'
          and instantane_emission #>> '{destinataire,prospect,code_postal}' = '97200'
          and instantane_emission #>> '{destinataire,prospect,adresse}' = '12 rue des Essais'
          and jsonb_array_length(instantane_emission -> 'lignes') = 2
          and instantane_emission #>> '{destinataire,prospect,societe}' = 'BTP Caraïbes'
          and (instantane_emission #>> '{tva,taux}')::numeric = 8.5
          and pdf_statut = 'a_generer' and emis_par_nom is not null
     from public.devis where id='dddddddd-0000-0000-0000-000000000001'));
select essai.refus('après émission : ligne non modifiable',
  $q$update public.devis_lignes set prix_unitaire = 1 where devis_id='dddddddd-0000-0000-0000-000000000001'$q$);
select essai.refus('après émission : TVA non modifiable',
  $q$update public.devis set taux_tva = 2.1 where id='dddddddd-0000-0000-0000-000000000001'$q$);
select essai.refus('après émission : suppression interdite',
  $q$delete from public.devis where id='dddddddd-0000-0000-0000-000000000001'$q$);
select essai.refus('envoi refusé tant que le PDF n''est pas archivé',
  $q$select public.declarer_envoi_devis('dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002',now(),'email','contact@exemple.invalid')$q$);
select essai.refus('PDF déclaré disponible alors qu''absent du stockage : refusé',
  $q$select public.enregistrer_pdf_devis('dddddddd-0000-0000-0000-000000000001','dddddddd-0000-0000-0000-000000000001/x.pdf',repeat('a',64),1000)$q$);
select public.signaler_echec_pdf_devis('dddddddd-0000-0000-0000-000000000001', 'Essai : génération interrompue');
select essai.ok('échec de génération : devis émis, numéro conservé, PDF « echec »',
  (select statut = 'emis' and numero like 'DEV-%' and pdf_statut = 'echec' from public.devis where id='dddddddd-0000-0000-0000-000000000001'));
insert into storage.objects (bucket_id, name, metadata)
select 'devis', id || '/' || numero || '.pdf', '{"size": 2048}' from public.devis where id='dddddddd-0000-0000-0000-000000000001';
select essai.refus('PDF : taille différente de celle stockée refusée',
  $q$select public.enregistrer_pdf_devis(d.id, d.id || '/' || d.numero || '.pdf', repeat('b',64), 999) from public.devis d where d.id='dddddddd-0000-0000-0000-000000000001'$q$);
select essai.accepte('PDF : archive vérifiée puis déclarée disponible',
  $q$select public.enregistrer_pdf_devis(d.id, d.id || '/' || d.numero || '.pdf', repeat('b',64), 2048) from public.devis d where d.id='dddddddd-0000-0000-0000-000000000001'$q$);
select essai.refus('PDF archivé : remplacement par un autre fichier refusé',
  $q$select public.enregistrer_pdf_devis(d.id, d.id || '/' || d.numero || '.pdf', repeat('c',64), 2048) from public.devis d where d.id='dddddddd-0000-0000-0000-000000000001'$q$);
select public.signaler_echec_pdf_devis('dddddddd-0000-0000-0000-000000000001', 'tardif');
select essai.ok('PDF archivé : un échec tardif ne le rend pas indisponible',
  (select pdf_statut = 'disponible' from public.devis where id='dddddddd-0000-0000-0000-000000000001'));
select essai.refus('acceptation directe d''un devis émis non envoyé refusée',
  $q$update public.devis set statut='accepte' where id='dddddddd-0000-0000-0000-000000000001'$q$);
select essai.accepte('envoi déclaré (date, canal, destinataire, auteur)',
  $q$select public.declarer_envoi_devis('dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002',now(),'email','contact@exemple.invalid')$q$);
select essai.ok('envoi : auteur et horodatage enregistrés ; prospect « devis envoyé »',
  (select statut = 'envoye' and canal_envoi = 'email' and envoi_declare_par = 'aaaaaaaa-0000-0000-0000-000000000002'
          and envoi_declare_par_nom is not null and envoi_declare_le is not null from public.devis where id='dddddddd-0000-0000-0000-000000000001')
  and (select statut = 'devis_envoye' from public.prospects where id='cccccccc-0000-0000-0000-000000000001'));
select essai.refus('envoi : canal inconnu refusé',
  $q$update public.devis set canal_envoi='pigeon' where id='dddddddd-0000-0000-0000-000000000001'$q$);

-- Nouvelle version d'un devis envoyé
select essai.ok('nouvelle version créée (brouillon, lignes copiées)',
  essai.valeur($q$select public.creer_nouvelle_version_devis('dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002')$q$) not like 'ERREUR%');
select essai.ok('nouvelle version : 2 lignes, lien vers l''original',
  (select count(*) = 2 from public.devis_lignes l join public.devis d on d.id = l.devis_id where d.remplace_devis_id='dddddddd-0000-0000-0000-000000000001'));
update public.devis_lignes set prix_unitaire = 500 from public.devis d
 where d.id = devis_lignes.devis_id and d.remplace_devis_id='dddddddd-0000-0000-0000-000000000001' and devis_lignes.designation = 'Diagnostic structure';
select essai.ok('émission de la version : nouveau numéro',
  essai.valeur($q$select public.emettre_devis(id,'aaaaaaaa-0000-0000-0000-000000000002',essai.emetteur(),'v1') from public.devis where remplace_devis_id='dddddddd-0000-0000-0000-000000000001'$q$) like 'DEV-____-0002');
select essai.ok('émission de la version : original passé à « remplacé », contenu et PDF intacts',
  (select statut = 'remplace' and total_ht = 1233.34 and pdf_statut = 'disponible' and pdf_empreinte = repeat('b',64)
     from public.devis where id='dddddddd-0000-0000-0000-000000000001'));
select essai.ok('version : mention du devis remplacé dans l''instantané',
  (select instantane_emission ->> 'remplace' = (select numero from public.devis where id='dddddddd-0000-0000-0000-000000000001')
     from public.devis where remplace_devis_id='dddddddd-0000-0000-0000-000000000001'));
select essai.refus('un devis remplacé ne peut plus être accepté',
  $q$update public.devis set statut='accepte' where id='dddddddd-0000-0000-0000-000000000001'$q$);
reset role;

-- ===================== ACCEPTATION depuis le « tableau de bord » (simple changement de statut) ====
-- Version 2 : PDF archivé, envoi déclaré, puis acceptation par UPDATE direct (comme Supabase).
insert into storage.objects (bucket_id, name, metadata)
select 'devis', id || '/' || numero || '.pdf', '{"size": 10}' from public.devis where remplace_devis_id='dddddddd-0000-0000-0000-000000000001';
set role service_role;
select public.enregistrer_pdf_devis(d.id, d.id || '/' || d.numero || '.pdf', repeat('d',64), 10) from public.devis d where d.remplace_devis_id='dddddddd-0000-0000-0000-000000000001';
select public.declarer_envoi_devis(d.id, 'aaaaaaaa-0000-0000-0000-000000000002', now(), 'main_propre', null) from public.devis d where d.remplace_devis_id='dddddddd-0000-0000-0000-000000000001';
reset role;
update public.devis set statut = 'accepte' where remplace_devis_id='dddddddd-0000-0000-0000-000000000001';
select essai.ok('acceptation (tableau de bord) : client créé depuis le prospect',
  (select c.nom = 'BTP Caraïbes' and c.email_contact = 'contact@exemple.invalid'
     from public.prospects p join public.clients c on c.id = p.client_id where p.id='cccccccc-0000-0000-0000-000000000001'));
select essai.ok('acceptation : un projet lié au devis, prospect « gagné », auteur « hors application »',
  (select count(*) = 1 from public.projets pj join public.devis d on d.id = pj.devis_id where d.remplace_devis_id='dddddddd-0000-0000-0000-000000000001')
  and (select statut = 'gagne' from public.prospects where id='cccccccc-0000-0000-0000-000000000001')
  and (select decision_par_nom like 'Hors application%' from public.devis where remplace_devis_id='dddddddd-0000-0000-0000-000000000001'));
select essai.refus('devis accepté : nouvelle version refusée (avenant obligatoire)',
  $q$select public.creer_nouvelle_version_devis(id,'aaaaaaaa-0000-0000-0000-000000000002') from public.devis where remplace_devis_id='dddddddd-0000-0000-0000-000000000001'$q$);
select essai.refus('devis accepté : passage à « remplacé » refusé',
  $q$update public.devis set statut='remplace' where remplace_devis_id='dddddddd-0000-0000-0000-000000000001'$q$);
select essai.refus('devis accepté : passage à « refusé » refusé (décision de l''utilisateur : avenant)',
  $q$update public.devis set statut='refuse' where remplace_devis_id='dddddddd-0000-0000-0000-000000000001'$q$);
select essai.refus('devis accepté : nouvelle décision « refusé » par la fonction de service refusée',
  $q$select public.decider_devis(id,'aaaaaaaa-0000-0000-0000-000000000002','refuse') from public.devis where remplace_devis_id='dddddddd-0000-0000-0000-000000000001'$q$);
select essai.refus('prospect gagné : repasser à « perdu » refusé',
  $q$update public.prospects set statut='perdu' where id='cccccccc-0000-0000-0000-000000000001'$q$);

-- Avenant (modification de mission après acceptation)
set role service_role;
select essai.ok('avenant créé sur le devis accepté',
  essai.valeur($q$select public.creer_avenant_devis(id,'aaaaaaaa-0000-0000-0000-000000000002') from public.devis where remplace_devis_id='dddddddd-0000-0000-0000-000000000001'$q$) not like 'ERREUR%');
insert into public.devis_lignes (devis_id, designation, quantite, prix_unitaire)
select id, 'Retrait de la note de calcul', -1, 333.34 from public.devis where avenant_du_devis_id is not null;
insert into public.devis_lignes (devis_id, designation, quantite, prix_unitaire)
select id, 'Mission complémentaire', 1, 800 from public.devis where avenant_du_devis_id is not null;
select essai.ok('avenant : lignes négatives permises, total recalculé (466,66 HT)',
  (select total_ht = 466.66 from public.devis where avenant_du_devis_id is not null),
  (select total_ht::text from public.devis where avenant_du_devis_id is not null));
select public.emettre_devis(id, 'aaaaaaaa-0000-0000-0000-000000000002', essai.emetteur(), 'v1') from public.devis where avenant_du_devis_id is not null;
reset role;
insert into storage.objects (bucket_id, name, metadata) select 'devis', id || '/' || numero || '.pdf', '{"size": 10}' from public.devis where avenant_du_devis_id is not null;
set role service_role;
select public.enregistrer_pdf_devis(d.id, d.id || '/' || d.numero || '.pdf', repeat('e',64), 10) from public.devis d where avenant_du_devis_id is not null;
select public.declarer_envoi_devis(d.id, 'aaaaaaaa-0000-0000-0000-000000000002', now(), 'email', null) from public.devis d where avenant_du_devis_id is not null;
select public.decider_devis(d.id, 'aaaaaaaa-0000-0000-0000-000000000002', 'accepte') from public.devis d where avenant_du_devis_id is not null;
reset role;
select essai.ok('avenant accepté : ni nouveau client ni nouveau projet',
  (select count(*) = 1 from public.clients where nom = 'BTP Caraïbes') and (select count(*) from public.projets) = 3);

-- Devis à montant nul : le taux reste conservé tel quel
alter table public.devis alter column id set default 'dddddddd-0000-0000-0000-000000000009'::uuid;
set role authenticated;
select essai.qui('aaaaaaaa-0000-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-000000000002');
insert into public.devis (prospect_id, regime_tva, territoire_tva, taux_tva, criteres_tva) values
  ('cccccccc-0000-0000-0000-000000000001', 'taxable', 'FR', 20,
   '{"nature_mission":"prestation_intellectuelle","statut_client":"assujetti_france"}');
insert into public.devis_lignes (devis_id, designation, quantite, prix_unitaire) values ('dddddddd-0000-0000-0000-000000000009', 'Visite gratuite', 1, 0);
reset role;
alter table public.devis alter column id set default gen_random_uuid();
set role service_role;
select public.emettre_devis('dddddddd-0000-0000-0000-000000000009', 'aaaaaaaa-0000-0000-0000-000000000002', essai.emetteur(), 'v1');
reset role;
select essai.ok('devis à montant nul : 20 % conservé, sans déduction depuis les montants',
  (select taux_tva = 20 and total_ttc = 0 and (instantane_emission #>> '{tva,taux}')::numeric = 20 from public.devis where id='dddddddd-0000-0000-0000-000000000009'));

-- ===================== COLLABORATEUR : consultation seulement =====================
select essai.qui('aaaaaaaa-0000-0000-0000-000000000003', 'bbbbbbbb-0000-0000-0000-000000000003');
set role authenticated;
select essai.ok('collaborateur : 0 ligne dans les tables prospects, devis, lignes, clients',
  (select count(*) from public.prospects) + (select count(*) from public.devis) + (select count(*) from public.devis_lignes) + (select count(*) from public.clients) = 0);
select essai.ok('collaborateur : consulte les prospects via la vue', (select count(*) from public.commercial_prospects) >= 3);
select essai.ok('collaborateur : consulte les devis et lignes via les vues',
  (select count(*) from public.commercial_devis) >= 4 and (select count(*) from public.commercial_devis_lignes) >= 4);
select essai.refus('collaborateur : pas d''email de prospect dans la vue', $q$select email from public.commercial_prospects$q$);
select essai.refus('collaborateur : pas de n° TVA client (critères) dans la vue', $q$select criteres_tva from public.commercial_devis$q$);
select essai.refus('collaborateur : pas d''instantané (coordonnées) dans la vue', $q$select instantane_emission from public.commercial_devis$q$);
select essai.refus('collaborateur : modification via la vue refusée', $q$update public.commercial_prospects set nom = 'Pirate'$q$);
select essai.refus('collaborateur : création via la vue refusée', $q$insert into public.commercial_prospects (nom) values ('Pirate')$q$);
select essai.refus('collaborateur : création de prospect refusée', $q$insert into public.prospects (nom) values ('Pirate')$q$);
select essai.ok('collaborateur : modification de devis sans effet',
  essai.valeur($q$with m as (update public.devis set mention_tva = 'x' returning 1) select count(*) from m$q$) = '0');
reset role;

-- ===================== Jetons inactifs et visiteur =====================
select essai.qui('aaaaaaaa-0000-0000-0000-000000000004', 'bbbbbbbb-0000-0000-0000-000000000004');
set role authenticated;
select essai.ok('manager provisoire : ne voit rien (tables et vues)',
  (select count(*) from public.prospects) + (select count(*) from public.devis) + (select count(*) from public.commercial_devis) = 0);
reset role;
select essai.qui('aaaaaaaa-0000-0000-0000-000000000005', 'bbbbbbbb-0000-0000-0000-000000000099');
set role authenticated;
select essai.ok('session fermée (ancien jeton) : ne voit rien',
  (select count(*) from public.commercial_prospects) + (select count(*) from public.commercial_devis) = 0);
reset role;
select set_config('request.jwt.claims', '', false);
set role anon;
select essai.refus('visiteur : vue des devis refusée', $q$select count(*) from public.commercial_devis$q$);
select essai.refus('visiteur : vue des prospects refusée', $q$select count(*) from public.commercial_prospects$q$);
reset role;


-- ===================== ESSAIS : séquence réservée, jamais choisie par un champ =====================
select essai.qui('aaaaaaaa-0000-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-000000000002');
set role authenticated;
select essai.refus('manager : ne peut pas créer un prospect d''essai (colonne non accessible)',
  $q$insert into public.prospects (nom, essai) values ('X', true)$q$);
select essai.refus('manager : ne peut pas appeler creer_prospect_essai',
  $q$select public.creer_prospect_essai('X','X','x','97200','FdF','MQ')$q$);
select essai.accepte('manager : prospect réel avec un email @exemple.invalid',
  $q$insert into public.prospects (nom, societe, email, adresse, code_postal, ville, pays)
     values ('Email trompeur','Trompe SARL','piege@exemple.invalid','1 rue','97200','Fort-de-France','MQ')$q$);
insert into public.devis (prospect_id, regime_tva, territoire_tva, taux_tva, criteres_tva)
select id, 'taxable', 'MQ', 8.5, '{"nature_mission":"prestation_intellectuelle","statut_client":"assujetti_france"}'
  from public.prospects where email = 'piege@exemple.invalid';
insert into public.devis_lignes (devis_id, designation, quantite, prix_unitaire)
select d.id, 'Mission', 1, 10 from public.devis d join public.prospects p on p.id = d.prospect_id where p.email = 'piege@exemple.invalid';
reset role;
set role service_role;
select public.emettre_devis(d.id, 'aaaaaaaa-0000-0000-0000-000000000002', essai.emetteur(), 'v1')
  from public.devis d join public.prospects p on p.id = d.prospect_id where p.email = 'piege@exemple.invalid';
select essai.ok('un email @exemple.invalid ne donne PAS la séquence d''essai (numéro réel DEV-)',
  (select d.numero like 'DEV-%' and not d.essai from public.devis d join public.prospects p on p.id = d.prospect_id where p.email = 'piege@exemple.invalid'),
  (select d.numero from public.devis d join public.prospects p on p.id = d.prospect_id where p.email = 'piege@exemple.invalid'));
select essai.ok('essai autorisé : prospect d''essai créé par la clé secrète',
  essai.valeur($q$select public.creer_prospect_essai('Essai','Essai SAS','1 rue','97200','Fort-de-France','MQ')$q$) not like 'ERREUR%');
insert into public.devis (prospect_id, regime_tva, territoire_tva, taux_tva, criteres_tva)
select id, 'taxable', 'MQ', 8.5, '{"nature_mission":"prestation_intellectuelle","statut_client":"assujetti_france"}'
  from public.prospects where essai;
insert into public.devis_lignes (devis_id, designation, quantite, prix_unitaire)
select d.id, 'Mission', 1, 10 from public.devis d where d.essai;
select public.emettre_devis(d.id, 'aaaaaaaa-0000-0000-0000-000000000002', essai.emetteur(), 'v1') from public.devis d where d.essai;
select essai.ok('devis d''essai : séquence ESSAI-DEV, instantané marqué « essai »',
  (select numero like 'ESSAI-DEV-%' and (instantane_emission ->> 'essai')::boolean from public.devis where essai),
  (select numero from public.devis where essai));
select essai.refus('le caractère essai d''un devis ne change pas (même clé secrète)',
  $q$update public.devis set essai = false where essai$q$);
select essai.refus('le caractère essai d''un prospect ne change pas (même clé secrète)',
  $q$update public.prospects set essai = false where essai$q$);
reset role;
select essai.qui('aaaaaaaa-0000-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-000000000002');
set role authenticated;
select essai.refus('manager : ne crée pas de devis pour un prospect d''essai',
  $q$insert into public.devis (prospect_id) select id from public.prospects where essai$q$);
select essai.refus('manager : ne modifie pas un prospect d''essai',
  $q$update public.prospects set nom = 'Réel' where essai$q$);
select essai.refus('manager : ne rattache pas un client réel à un prospect d''essai',
  $q$update public.prospects set client_id = '33333333-3333-3333-3333-333333333331' where essai$q$);
reset role;

-- ===================== AVENANTS : rattachement au projet, totaux négatifs =====================
select essai.ok('avenant visible depuis le projet du devis accepté',
  (select count(*) = 1 from public.projets pj
     join public.devis a on a.avenant_du_devis_id = pj.devis_id
    where pj.devis_id = (select id from public.devis where remplace_devis_id = 'dddddddd-0000-0000-0000-000000000001')));
set role service_role;
select public.creer_avenant_devis(id, 'aaaaaaaa-0000-0000-0000-000000000002') from public.devis where remplace_devis_id = 'dddddddd-0000-0000-0000-000000000001';
reset role;
-- Avenant 2 : moins-value de 2000 € HT alors que la mission vaut 1333,34 + 466,66 = 1800 € HT
insert into public.devis_lignes (devis_id, designation, quantite, prix_unitaire)
select id, 'Suppression de mission', -1, 2000 from public.devis
 where avenant_du_devis_id is not null and statut = 'brouillon';
set role service_role;
select essai.refus('avenant rendant la mission négative : émission refusée',
  $q$select public.emettre_devis(id, 'aaaaaaaa-0000-0000-0000-000000000002', essai.emetteur(), 'v1') from public.devis where avenant_du_devis_id is not null and statut = 'brouillon'$q$);
reset role;
update public.devis_lignes set prix_unitaire = 1500 from public.devis d
 where d.id = devis_lignes.devis_id and d.avenant_du_devis_id is not null and d.statut = 'brouillon';
set role service_role;
select essai.accepte('avenant à total négatif (-1500 € HT) mais mission positive : émission acceptée',
  $q$select public.emettre_devis(id, 'aaaaaaaa-0000-0000-0000-000000000002', essai.emetteur(), 'v1') from public.devis where avenant_du_devis_id is not null and statut = 'brouillon'$q$);
select essai.ok('avenant négatif : TVA négative calculée (-127,50), TTC -1627,50',
  (select tva = -127.50 and total_ttc = -1627.50 from public.devis where avenant_du_devis_id is not null and total_ht < 0),
  (select tva || ' / ' || total_ttc from public.devis where avenant_du_devis_id is not null and total_ht < 0));
reset role;
select essai.refus('un devis initial (non avenant) ne peut pas avoir un total négatif',
  $q$insert into public.devis_lignes (devis_id, designation, quantite, prix_unitaire) values ('dddddddd-0000-0000-0000-000000000009','Remise',-1,5)$q$);
select essai.ok('projets : toujours un seul pour la mission et ses avenants',
  (select count(*) = 1 from public.projets where devis_id = (select id from public.devis where remplace_devis_id = 'dddddddd-0000-0000-0000-000000000001')));

-- ===================== VUES : tentatives de contournement =====================
select essai.qui('aaaaaaaa-0000-0000-0000-000000000003', 'bbbbbbbb-0000-0000-0000-000000000003');
set role authenticated;
select essai.ok('jointure vue → table prospects : aucune coordonnée',
  essai.valeur($q$select count(*) from public.commercial_devis d join public.prospects p on p.id = d.prospect_id$q$) = '0');
select essai.ok('jointure vue → table clients : aucune ligne',
  essai.valeur($q$select count(*) from public.commercial_prospects v join public.clients c on true$q$) = '0');
select essai.ok('sous-requête sur la table prospects depuis la vue : vide',
  essai.valeur($q$select count(*) from public.commercial_devis where prospect_id in (select id from public.prospects)$q$) = '0');
select essai.refus('filtre sur une colonne cachée (email) : impossible',
  $q$select count(*) from public.commercial_prospects where email like '%@%'$q$);
select essai.refus('filtre sur une colonne cachée (critères TVA) : impossible',
  $q$select count(*) from public.commercial_devis where criteres_tva ? 'numero_tva_client'$q$);
select essai.ok('table projets : rien de lisible pour le collaborateur',
  essai.valeur($q$select count(*) from public.projets$q$) = '0');
reset role;
select essai.qui('aaaaaaaa-0000-0000-0000-000000000005', 'bbbbbbbb-0000-0000-0000-000000000099');
set role authenticated;
select essai.ok('session révoquée + filtre « piège » (erreur si une ligne cachée était lue) : aucune ligne, aucune erreur',
  essai.valeur($q$select count(*) from public.commercial_prospects where 1 / (length(nom) - length(nom)) = 1$q$) = '0',
  essai.valeur($q$select count(*) from public.commercial_prospects where 1 / (length(nom) - length(nom)) = 1$q$));
select essai.ok('session révoquée + filtre piège sur les lignes de devis : aucune ligne, aucune erreur',
  essai.valeur($q$select count(*) from public.commercial_devis_lignes where 1 / (montant_ht - montant_ht) = 1$q$) = '0');
reset role;


-- ===================== NUMÉROTATION (copie exacte de prochain_numero) =====================
select essai.ok('devis réels : compteur « devis_AAAA » (jamais « devis_AAAA_AAAA »)',
  (select count(*) from public.compteurs where cle ~ '^devis_[0-9]{4}$') = 1
  and (select count(*) from public.compteurs where cle ~ '^devis_[0-9]{4}_[0-9]{4}$') = 0,
  (select string_agg(cle || '=' || valeur, ', ' order by cle) from public.compteurs));
select essai.ok('devis d''essai : compteur distinct « essai_devis_AAAA »',
  (select count(*) from public.compteurs where cle ~ '^essai_devis_[0-9]{4}$') = 1);
select set_config('timezone', 'Pacific/Kiritimati', false);
insert into public.devis (id, prospect_id, regime_tva, territoire_tva, taux_tva, criteres_tva, type_mission)
values ('dddddddd-0000-0000-0000-0000000000a1', 'cccccccc-0000-0000-0000-000000000001', 'taxable', 'MQ', 8.5,
        '{"nature_mission":"prestation_intellectuelle","statut_client":"assujetti_france"}', 'conseil');
insert into public.devis_lignes (devis_id, designation, quantite, prix_unitaire) values ('dddddddd-0000-0000-0000-0000000000a1', 'Mission', 1, 100);
set role service_role;
select public.emettre_devis('dddddddd-0000-0000-0000-0000000000a1', 'aaaaaaaa-0000-0000-0000-000000000002', essai.emetteur(), 'v1');
reset role;
select essai.ok('session en fuseau UTC+14 : année et date d''émission prises en Martinique',
  (select numero like 'DEV-' || to_char(now() at time zone 'America/Martinique', 'YYYY') || '-%'
          and date_emission = (now() at time zone 'America/Martinique')::date from public.devis where id = 'dddddddd-0000-0000-0000-0000000000a1'),
  (select numero || ' / ' || date_emission from public.devis where id = 'dddddddd-0000-0000-0000-0000000000a1'));
select essai.ok('fuseau de la connexion inchangé après l''émission (Pacific/Kiritimati)', current_setting('timezone') = 'Pacific/Kiritimati');
select set_config('timezone', 'UTC', false);
-- Limite de 9 999 : blocage explicite, rien d'attribué
create table essai.compteur_sauve as select cle, valeur from public.compteurs where cle ~ '^devis_[0-9]{4}$';
update public.compteurs set valeur = 9999 where cle ~ '^devis_[0-9]{4}$';
insert into public.devis (id, prospect_id, regime_tva, territoire_tva, taux_tva, criteres_tva, type_mission)
values ('dddddddd-0000-0000-0000-0000000000a2', 'cccccccc-0000-0000-0000-000000000001', 'taxable', 'MQ', 8.5,
        '{"nature_mission":"prestation_intellectuelle","statut_client":"assujetti_france"}', 'conseil');
insert into public.devis_lignes (devis_id, designation, quantite, prix_unitaire) values ('dddddddd-0000-0000-0000-0000000000a2', 'Mission', 1, 100);
set role service_role;
select essai.refus('9 999e numéro atteint : émission refusée avec un message en français',
  $q$select public.emettre_devis('dddddddd-0000-0000-0000-0000000000a2','aaaaaaaa-0000-0000-0000-000000000002',essai.emetteur(),'v1')$q$);
reset role;
select essai.ok('message affiché : « limite de 9 999 documents »',
  (select detail like 'Numérotation impossible : la limite de 9 999 documents « DEV »%' from essai.resultats order by n desc limit 1),
  (select detail from essai.resultats order by n desc limit 1));
select essai.ok('après le refus : devis toujours brouillon, compteur toujours à 9999',
  (select statut = 'brouillon' and numero is null from public.devis where id = 'dddddddd-0000-0000-0000-0000000000a2')
  and (select valeur from public.compteurs where cle ~ '^devis_[0-9]{4}$') = 9999);
select essai.ok('compteur d''essai non concerné par la limite du compteur réel',
  (select valeur < 9999 from public.compteurs where cle ~ '^essai_devis_[0-9]{4}$'));
update public.compteurs c set valeur = s.valeur from essai.compteur_sauve s where c.cle = s.cle;
select essai.qui('aaaaaaaa-0000-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-000000000002');
set role authenticated;
select essai.refus('attribuer_numero non appelable avec un jeton', $q$select public.attribuer_numero('devis','DEV')$q$);
reset role;

-- ===================== Nettoyage des essais =====================
create table essai.avant_nettoyage as
  select (select count(*) from public.devis where not essai) as devis_reels,
         (select count(*) from public.devis_lignes l join public.devis d on d.id = l.devis_id where not d.essai) as lignes_reelles,
         (select count(*) from public.prospects where not essai) as prospects_reels,
         (select count(*) from public.clients where nom not like '[ESSAI]%') as clients_reels,
         (select count(*) from public.projets where nom not like '[ESSAI]%') as projets_reels,
         (select string_agg(cle || '=' || valeur, ',' order by cle) from public.compteurs where cle !~ '^essai_') as compteurs_reels;
select essai.qui('11111111-1111-1111-1111-111111111111', 'bbbbbbbb-0000-0000-0000-000000000001');
set role authenticated;
select essai.refus('nettoyage des essais non appelable avec un jeton (même admin)', $q$select public.supprimer_essais_commercial()$q$);
select essai.refus('devis d''essai émis : suppression refusée avec un jeton',
  $q$delete from public.devis where essai and statut <> 'brouillon'$q$);
reset role;
set role service_role;
select essai.refus('devis réel émis : suppression refusée même avec la clé secrète',
  $q$delete from public.devis where not essai and statut <> 'brouillon'$q$);
reset role;
-- Un projet d'essai sur lequel du temps réel a été saisi : le nettoyage refuse tout.
insert into public.projets (id, nom, devis_id) select 'eeeeeeee-0000-0000-0000-0000000000e1', '[ESSAI] Projet témoin', id
  from public.devis where essai and not exists (select 1 from public.projets p where p.devis_id = devis.id) limit 1;
insert into public.temps (id, collaborateur_id, projet_id, heures)
  values ('eeeeeeee-0000-0000-0000-0000000000e2', '22222222-2222-2222-2222-222222222221', 'eeeeeeee-0000-0000-0000-0000000000e1', 1);
set role service_role;
select essai.refus('nettoyage refusé si du temps est saisi sur un projet d''essai', $q$select public.supprimer_essais_commercial()$q$);
reset role;
select essai.ok('après ce refus : essais toujours présents (rien supprimé)',
  (select count(*) > 0 from public.devis where essai) and (select count(*) = 1 from public.temps where id = 'eeeeeeee-0000-0000-0000-0000000000e2'));
delete from public.temps where id = 'eeeeeeee-0000-0000-0000-0000000000e2';
set role service_role;
select essai.ok('nettoyage des essais avec la clé secrète', (select (public.supprimer_essais_commercial() ->> 'devis')::int > 0));
reset role;
select essai.ok('plus aucun prospect, devis, ligne, projet, client ni compteur d''essai',
  not exists (select 1 from public.prospects where essai) and not exists (select 1 from public.devis where essai)
  and not exists (select 1 from public.devis_lignes l where not exists (select 1 from public.devis d where d.id = l.devis_id))
  and not exists (select 1 from public.projets where nom like '[ESSAI]%')
  and not exists (select 1 from public.clients where nom like '[ESSAI]%')
  and not exists (select 1 from public.compteurs where cle ~ '^essai_'));
select essai.ok('données réelles et compteur réel inchangés par le nettoyage',
  (select (devis_reels, lignes_reelles, prospects_reels, clients_reels, projets_reels, compteurs_reels) =
          ((select count(*) from public.devis where not essai),
           (select count(*) from public.devis_lignes l join public.devis d on d.id = l.devis_id where not d.essai),
           (select count(*) from public.prospects where not essai),
           (select count(*) from public.clients where nom not like '[ESSAI]%'),
           (select count(*) from public.projets where nom not like '[ESSAI]%'),
           (select string_agg(cle || '=' || valeur, ',' order by cle) from public.compteurs where cle !~ '^essai_'))
     from essai.avant_nettoyage));

-- ===================== Données existantes =====================
select essai.ok('prospect de démonstration « gagné » sans devis : inchangé',
  (select statut = 'gagne' from public.prospects where nom = 'Prospect démo 2'));
select essai.ok('projets de démonstration : intacts',
  (select count(*) = 2 from public.projets where nom like 'Projet démo%' and devis_id is null));
