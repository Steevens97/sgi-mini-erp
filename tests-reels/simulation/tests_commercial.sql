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
  $q$insert into public.prospects (nom, societe, email, telephone) values
     ('Mme Client','BTP Caraïbes','contact@exemple.invalid','0596000000')$q$);
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
  $q$select public.emettre_devis('dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000003','{"raison_sociale":"SGI"}','v1')$q$);
select essai.refus('émission refusée à un manager devant changer son mot de passe',
  $q$select public.emettre_devis('dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000004','{"raison_sociale":"SGI"}','v1')$q$);
select essai.refus('émission sans coordonnées de l''émetteur refusée',
  $q$select public.emettre_devis('dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002',null,'v1')$q$);
select essai.ok('compteur intact après les émissions refusées',
  (select count(*) = 0 from public.compteurs where cle like 'essai_devis_%'));
select essai.ok('émission : numéro d''essai attribué',
  essai.valeur($q$select public.emettre_devis('dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002','{"raison_sociale":"SG Ingénierie","adresse":"Fort-de-France"}','v1')$q$) like 'ESSAI-DEV-____-0001',
  (select numero from public.devis where id='dddddddd-0000-0000-0000-000000000001'));
select essai.ok('nouvel essai d''émission : même numéro, aucun numéro consommé',
  essai.valeur($q$select public.emettre_devis('dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002','{"raison_sociale":"autre"}','v1')$q$)
    = (select numero from public.devis where id='dddddddd-0000-0000-0000-000000000001')
  and (select valeur from public.compteurs where cle like 'essai_devis_%') = 1);
select essai.ok('instantané figé : émetteur, destinataire, lignes, totaux, TVA',
  (select instantane_emission ->> 'numero' = numero and instantane_emission #>> '{emetteur,raison_sociale}' = 'SG Ingénierie'
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
  (select statut = 'emis' and numero like 'ESSAI-DEV-%' and pdf_statut = 'echec' from public.devis where id='dddddddd-0000-0000-0000-000000000001'));
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
  essai.valeur($q$select public.creer_nouvelle_version_devis('dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002')$q$) is not null);
select essai.ok('nouvelle version : 2 lignes, lien vers l''original',
  (select count(*) = 2 from public.devis_lignes l join public.devis d on d.id = l.devis_id where d.remplace_devis_id='dddddddd-0000-0000-0000-000000000001'));
update public.devis_lignes set prix_unitaire = 500 from public.devis d
 where d.id = devis_lignes.devis_id and d.remplace_devis_id='dddddddd-0000-0000-0000-000000000001' and devis_lignes.designation = 'Diagnostic structure';
select essai.ok('émission de la version : nouveau numéro',
  essai.valeur($q$select public.emettre_devis(id,'aaaaaaaa-0000-0000-0000-000000000002','{"raison_sociale":"SG Ingénierie"}','v1') from public.devis where remplace_devis_id='dddddddd-0000-0000-0000-000000000001'$q$) like 'ESSAI-DEV-____-0002');
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
select essai.refus('prospect gagné : repasser à « perdu » refusé',
  $q$update public.prospects set statut='perdu' where id='cccccccc-0000-0000-0000-000000000001'$q$);

-- Avenant (modification de mission après acceptation)
set role service_role;
select essai.ok('avenant créé sur le devis accepté',
  essai.valeur($q$select public.creer_avenant_devis(id,'aaaaaaaa-0000-0000-0000-000000000002') from public.devis where remplace_devis_id='dddddddd-0000-0000-0000-000000000001'$q$) is not null);
insert into public.devis_lignes (devis_id, designation, quantite, prix_unitaire)
select id, 'Retrait de la note de calcul', -1, 333.34 from public.devis where avenant_du_devis_id is not null;
insert into public.devis_lignes (devis_id, designation, quantite, prix_unitaire)
select id, 'Mission complémentaire', 1, 800 from public.devis where avenant_du_devis_id is not null;
select essai.ok('avenant : lignes négatives permises, total recalculé (466,66 HT)',
  (select total_ht = 466.66 from public.devis where avenant_du_devis_id is not null),
  (select total_ht::text from public.devis where avenant_du_devis_id is not null));
select public.emettre_devis(id, 'aaaaaaaa-0000-0000-0000-000000000002', '{"raison_sociale":"SG Ingénierie"}', 'v1') from public.devis where avenant_du_devis_id is not null;
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
select public.emettre_devis('dddddddd-0000-0000-0000-000000000009', 'aaaaaaaa-0000-0000-0000-000000000002', '{"raison_sociale":"SG Ingénierie"}', 'v1');
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

-- ===================== Données existantes =====================
select essai.ok('prospect de démonstration « gagné » sans devis : inchangé',
  (select statut = 'gagne' from public.prospects where nom = 'Prospect démo 2'));
select essai.ok('projets de démonstration : intacts',
  (select count(*) = 2 from public.projets where nom like 'Projet démo%' and devis_id is null));
