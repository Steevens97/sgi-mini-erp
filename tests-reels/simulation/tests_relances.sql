-- Tests des relances automatiques des factures sur la base d'ESSAI locale (jamais Supabase). AUCUN envoi : le
-- fournisseur n'est jamais appelé ici (ses réponses sont simulées par les appels à relances_resultat).
-- Usage : tests-reels/simulation/rejouer.sh tests-reels/simulation/tests_relances.sql
--         puis : select count(*) filter (where ok), count(*) from rele.resultats;
-- Horloge : relances_maintenant() est remplacée le temps des tests par une horloge simulée (rele.horloge), puis
-- rétablie et contrôlée par empreinte à la fin. Les adresses réservées (exemple.invalid) sont permises le temps des
-- scénarios seulement (la règle réelle est testée d'abord, puis rétablie et retestée).
\set ON_ERROR_STOP 1
\pset tuples_only on
\set QUIET on
\pset format unaligned
create schema rele;
create table rele.resultats (n serial, libelle text, ok boolean, detail text);
create table rele.horloge (t timestamptz);
insert into rele.horloge values (null);
create table rele.v (cle text primary key, val text);
grant usage on schema rele to authenticated, anon, service_role;
grant all on all tables in schema rele to authenticated, anon, service_role;
grant usage on all sequences in schema rele to authenticated, anon, service_role;
create function rele.ok(p_libelle text, p_ok boolean, p_detail text default null) returns void language sql as $$
  insert into rele.resultats (libelle, ok, detail) values (p_libelle, coalesce(p_ok, false), p_detail);
$$;
create function rele.refus(p_libelle text, p_sql text, p_motif text default null) returns void language plpgsql as $$
begin
  execute p_sql;
  insert into rele.resultats (libelle, ok, detail) values (p_libelle, false, 'accepté alors qu''il devait être refusé');
exception when others then
  insert into rele.resultats (libelle, ok, detail) values (p_libelle, p_motif is null or sqlerrm ilike '%' || p_motif || '%', sqlerrm);
end $$;
create function rele.heure(p text) returns void language sql as $$ update rele.horloge set t = p::timestamptz $$;
create function rele.maintenant() returns timestamptz language sql stable as $$ select t from rele.horloge $$;
create function rele.put(p text, v text) returns void language sql as $$
  insert into rele.v values (p, v) on conflict (cle) do update set val = excluded.val $$;
create function rele.get(p text) returns text language sql as $$ select val from rele.v where cle = p $$;
create function rele.r(p uuid) returns public.relances language sql as $$ select * from public.relances where id = p $$;
-- Facture posée comme le fait l'émission (contexte Finance), PDF « archivé » sans fichier (la base ne lit pas le PDF).
create function rele.facture(p_num text, p_essai boolean, p_echeance date, p_pdf boolean, p_client uuid) returns uuid
language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  perform public.finance_contexte('emission', jsonb_build_object('action', 'emission', 'test', 'tests_relances'), v);
  insert into public.factures (id, client_id, numero, statut, essai, date_emission, date_echeance, total_ht, tva, total_ttc,
                               instantane_emission, cle_emission)
  values (v, p_client, p_num, 'emise', p_essai, p_echeance - 30, p_echeance, 1000, 85, 1085, '{}', gen_random_uuid());
  if p_pdf then
    perform public.finance_contexte('pdf', jsonb_build_object('action', 'pdf_archive', 'test', 'tests_relances'), v);
    update public.factures set pdf_statut = 'disponible', pdf_chemin = 'essais/' || p_num || '.pdf',
           pdf_empreinte = encode(sha256(convert_to(p_num, 'UTF8')), 'hex'), pdf_taille = 100, pdf_archive_le = now()
     where id = v;
  end if;
  perform public.finance_fin_contexte();
  return v;
end $$;
create function rele.regler(p_facture uuid) returns void language plpgsql as $$
begin
  perform public.finance_contexte('envoi', '{"action":"envoi","test":"tests_relances"}', p_facture);
  update public.factures set statut = 'envoyee', date_envoi = now() where id = p_facture;
  perform public.finance_contexte('reglement', '{"action":"reglement","test":"tests_relances"}', p_facture);
  update public.factures set statut = 'payee', date_reglement = current_date, mode_reglement = 'virement' where id = p_facture;
  perform public.finance_fin_contexte();
end $$;
-- Demande conforme (comme la construit l'application) ; p_modif : champs remplacés pour les cas de refus.
create function rele.req(p_id uuid, p_facture uuid, p_rang integer, p_modif jsonb default '{}') returns jsonb
language sql stable as $$
  select (jsonb_build_object('fournisseur', 'resend', 'version', 1,
           'from', case when f.essai then 'SG Ingénierie [ESSAI] <essai@exemple.invalid>' else 'SG Ingénierie <facturation@domaine-a-choisir.invalid>' end,
           'to', case when f.essai then 'destinataire-essai@exemple.invalid' else lower(c.email_contact) end,
           'reply_to', null,
           'subject', case when f.essai then '[ESSAI] ' else '' end || 'Facture ' || f.numero
                      || case p_rang when 1 then ' : rappel d''échéance' when 2 then ' : second rappel' else ' : dernier rappel avant contact direct' end,
           'text', 'Bonjour, sauf erreur de notre part, la facture ' || f.numero || ' ne semble pas encore réglée. Cordialement.',
           'piece_jointe', jsonb_build_object('nom', f.numero || '.pdf', 'type', 'application/pdf', 'empreinte', f.pdf_empreinte),
           'tags', jsonb_build_array(jsonb_build_object('name', 'relance_id', 'value', p_id::text)))) || p_modif
    from public.factures f join public.clients c on c.id = f.client_id where f.id = p_facture;
$$;
create function rele.reserver(p_id uuid, p_facture uuid, p_rang integer, p_modif jsonb default '{}') returns jsonb
language sql as $$ select public.relances_reserver(p_id, p_facture, p_rang, rele.req(p_id, p_facture, p_rang, p_modif)) $$;
grant execute on all functions in schema rele to authenticated, anon, service_role;

\set ADMIN '\'11111111-1111-1111-1111-111111111111\''
\set COMPTE '\'0123456789abcdef0123456789abcdef\''
\set AUTRE_COMPTE '\'fedcba9876543210fedcba9876543210\''
-- Lundi 2 novembre 2026, 15 h en Martinique (19 h UTC).
\set LUNDI '\'2026-11-02 19:00:00+00\''

-- ===================== Structure, droits, outils =====================
select rele.ok('date_envoi facultative et sans valeur par défaut',
  (select is_nullable = 'YES' and column_default is null from information_schema.columns
    where table_schema = 'public' and table_name = 'relances' and column_name = 'date_envoi'));
select rele.ok('aucun droit sur relances pour un jeton (connecté ou visiteur)',
  not has_table_privilege('authenticated', 'public.relances', 'select') and not has_table_privilege('authenticated', 'public.relances', 'insert')
  and not has_table_privilege('anon', 'public.relances', 'select'));
select rele.ok('déclenchement : exécutable par postgres seulement (ni jetons, ni clé secrète)',
  has_function_privilege('postgres', 'public.relances_declencher()', 'execute')
  and not has_function_privilege('service_role', 'public.relances_declencher()', 'execute')
  and not has_function_privilege('authenticated', 'public.relances_declencher()', 'execute')
  and not has_function_privilege('anon', 'public.relances_declencher()', 'execute'));
select rele.ok('fonctions de service exécutables avec la clé secrète, pas avec un jeton',
  has_function_privilege('service_role', 'public.relances_prendre(uuid, text)', 'execute')
  and not has_function_privilege('authenticated', 'public.relances_prendre(uuid, text)', 'execute')
  and not has_function_privilege('authenticated', 'public.relances_apercu()', 'execute'));
set role service_role;
select rele.refus('clé secrète : déclenchement refusé', $q$select public.relances_declencher()$q$, 'permission denied');
reset role;
set role authenticated;
select rele.refus('jeton : lecture des relances refusée', $q$select count(*) from public.relances$q$, 'permission denied');
select rele.refus('jeton : aperçu refusé', $q$select public.relances_apercu()$q$, 'permission denied');
reset role;
-- Déclenchement sans dépendances : échec explicite, sans appel réseau.
select rele.refus('déclenchement sans Vault : échec explicite', $q$select public.relances_declencher()$q$, 'Vault n''est pas installé');
create schema vault;
create table vault.decrypted_secrets (name text, decrypted_secret text);
select rele.refus('déclenchement sans pg_net : échec explicite', $q$select public.relances_declencher()$q$, 'pg_net n''est pas installé');
create schema net;
create table net.appels (id bigserial, url text, body jsonb, headers jsonb, timeout_milliseconds int);
create function net.http_post(url text, body jsonb default '{}', params jsonb default '{}', headers jsonb default '{}',
  timeout_milliseconds int default 5000) returns bigint language sql as $$
  insert into net.appels (url, body, headers, timeout_milliseconds) values (url, body, headers, timeout_milliseconds) returning id $$;
select rele.refus('déclenchement sans secret dans Vault : refusé', $q$select public.relances_declencher()$q$, 'relances_secret_cron');
insert into vault.decrypted_secrets values ('relances_secret_cron', 'secret-de-test-local-' || repeat('x', 20));
select rele.refus('déclenchement sans adresse dans Vault : refusé', $q$select public.relances_declencher()$q$, 'relances_url');
insert into vault.decrypted_secrets values ('relances_url', 'https://evil.example/api/relances/executer?jeton=1');
select rele.refus('adresse non conforme (paramètres d''URL) : refusée', $q$select public.relances_declencher()$q$, 'non conforme');
update vault.decrypted_secrets set decrypted_secret = 'http://127.0.0.1:3200/api/relances/executer' where name = 'relances_url';
select public.relances_declencher() as appel \gset
select rele.ok('déclenchement : un seul appel, secret dans l''en-tête seulement (ni URL ni corps)',
  (select count(*) = 1 and bool_and(url = 'http://127.0.0.1:3200/api/relances/executer' and body = '{}'
     and headers ->> 'Authorization' = 'Bearer secret-de-test-local-' || repeat('x', 20) and timeout_milliseconds = 60000)
     from net.appels));
select rele.ok('le secret n''apparaît dans aucune table publique',
  not exists (select 1 from public.relances r where r::text like '%secret-de-test-local%'));
drop schema net cascade;
drop schema vault cascade;
select rele.ok('adresses fictives ou réservées refusées (exemple.invalid, example.com, .test, resend.dev, vide)',
  public.relances_adresse_fictive('a@exemple.invalid') and public.relances_adresse_fictive('a@example.com')
  and public.relances_adresse_fictive('a@client.test') and public.relances_adresse_fictive('delivered@resend.dev')
  and public.relances_adresse_fictive('') and not public.relances_adresse_fictive('compta@client-reel.fr'));
select rele.ok('horaires : lundi 8 h 00 et 16 h 59 oui ; 7 h 59, 17 h 00, samedi 10 h non (Martinique)',
  public.relances_horaire_ouvre('2026-11-02 12:00:00+00') and public.relances_horaire_ouvre('2026-11-02 20:59:00+00')
  and not public.relances_horaire_ouvre('2026-11-02 11:59:00+00') and not public.relances_horaire_ouvre('2026-11-02 21:00:00+00')
  and not public.relances_horaire_ouvre('2026-11-07 14:00:00+00'));
select rele.ok('jour en Martinique : 1er janvier 2 h UTC = 31 décembre',
  public.relances_jour('2027-01-01 02:00:00+00') = date '2026-12-31');
select rele.ok('secrets reconnus (re_…, Bearer, whsec_, Authorization), texte ordinaire accepté',
  public.relances_contient_secret('clé re_1234567890ab') and public.relances_contient_secret('Bearer abc')
  and public.relances_contient_secret('whsec_abc') and public.relances_contient_secret('Authorization: x')
  and not public.relances_contient_secret('Bonjour, la facture FAC-2026-0001 reste impayée.'));

-- ===================== Données d'essai et horloge simulée =====================
select md5(prosrc) as def_maintenant from pg_proc where proname = 'relances_maintenant' \gset
select md5(prosrc) as def_fictive from pg_proc where proname = 'relances_adresse_fictive' \gset
create or replace function public.relances_maintenant() returns timestamptz language sql stable
  as $f$ select coalesce((select t from rele.horloge), now()) $f$;
select rele.heure(:LUNDI);
insert into public.clients (id, nom, email_contact) values
  ('55555555-0000-0000-0000-0000000000e1', '[ESSAI] Client relances', 'client-essai@exemple.invalid'),
  ('55555555-0000-0000-0000-0000000000e2', '[ESSAI] Client sans email', null),
  ('55555555-0000-0000-0000-0000000000a1', 'Client réel relances', 'Compta@Client-Reel.fr');
select rele.put('fa', rele.facture('ESSAI-FAC-2026-0101', true, date '2026-11-02' - 40, true, '55555555-0000-0000-0000-0000000000e1')::text);
select rele.put('fb', rele.facture('ESSAI-FAC-2026-0102', true, date '2026-11-02' - 3, true, '55555555-0000-0000-0000-0000000000e1')::text);
select rele.put('fc', rele.facture('ESSAI-FAC-2026-0103', true, date '2026-11-02' - 20, false, '55555555-0000-0000-0000-0000000000e1')::text);
select rele.put('fd', rele.facture('ESSAI-FAC-2026-0104', true, date '2026-11-02' - 20, true, '55555555-0000-0000-0000-0000000000e2')::text);
-- Facture RÉELLE : échéance future normale (aucune échéance réelle n'est avancée pour un test) ; seules ses règles de
-- demande sont vérifiées, sans aucune relance. Les scénarios d'échéance passée n'utilisent que des factures d'ESSAI.
select rele.put('fr', rele.facture('FAC-2026-0901', false, date '2026-11-02' + 30, true, '55555555-0000-0000-0000-0000000000a1')::text);
select rele.put('fk', rele.facture('ESSAI-FAC-2026-0112', true, date '2026-11-02' - 10, true, '55555555-0000-0000-0000-0000000000e1')::text);
select rele.put('fe', rele.facture('ESSAI-FAC-2026-0105', true, date '2026-11-02' - 12, true, '55555555-0000-0000-0000-0000000000e1')::text);
select rele.put('ff', rele.facture('ESSAI-FAC-2026-0106', true, date '2026-11-02' - 12, true, '55555555-0000-0000-0000-0000000000e1')::text);
select rele.put('fg', rele.facture('ESSAI-FAC-2026-0107', true, date '2026-11-02' - 12, true, '55555555-0000-0000-0000-0000000000e1')::text);
select rele.put('fh', rele.facture('ESSAI-FAC-2026-0108', true, date '2026-11-02' - 12, true, '55555555-0000-0000-0000-0000000000e1')::text);
select rele.put('fi', rele.facture('ESSAI-FAC-2026-0109', true, date '2026-11-02' - 12, true, '55555555-0000-0000-0000-0000000000e1')::text);
select rele.put('fj', rele.facture('ESSAI-FAC-2026-0110', true, date '2026-11-02' - 12, true, '55555555-0000-0000-0000-0000000000e1')::text);
select rele.get('fk') as fk, rele.get('fa') as fa, rele.get('fb') as fb, rele.get('fc') as fc, rele.get('fd') as fd, rele.get('fr') as fr,
       rele.get('fe') as fe, rele.get('ff') as ff, rele.get('fg') as fg, rele.get('fh') as fh, rele.get('fi') as fi,
       rele.get('fj') as fj \gset

-- Avant tout scénario : la vraie règle refuse un destinataire fictif, même pour une facture d'essai.
set role service_role;
select rele.refus('règle réelle : destinataire en exemple.invalid refusé',
  format($q$select rele.reserver('66666666-0000-0000-0000-000000000000', '%s', 1)$q$, :'fa'), 'destinataire fictif');
select rele.refus('règle réelle : adresse de simulation de Resend refusée (non autorisée par l''utilisateur)',
  format($q$select rele.reserver('66666666-0000-0000-0000-000000000000', '%s', 1, '{"to":"delivered@resend.dev"}')$q$, :'fa'), 'destinataire fictif');
reset role;
create or replace function public.relances_adresse_fictive(p_adresse text) returns boolean language sql immutable
  as $f$ select false $f$;

-- ===================== Aperçu (lecture seule) =====================
set role service_role;
select public.relances_apercu() as apercu \gset
reset role;
create function rele.ap(p_facture uuid, p_cle text) returns text language sql as $$
  select e ->> p_cle from jsonb_array_elements(public.relances_apercu()) e where e ->> 'facture_id' = p_facture::text $$;
select rele.ok('aperçu : J+40, relance n° 1 due (une seule, jamais trois rapprochées)', rele.ap(:'fa', 'rang') = '1');
select rele.ok('aperçu : J+3, relance n° 1 prévue à J+7 avec sa date', rele.ap(:'fb', 'blocage') = 'Relance n° 1 prévue à J+7 (le 06/11/2026).');
select rele.ok('aperçu : facture sans PDF archivé signalée à part', rele.ap(:'fc', 'blocage') like 'PDF archivé indisponible%'
  and rele.ap(:'fc', 'pdf_disponible') = 'false');
select rele.ok('aperçu : client sans email signalé à part', rele.ap(:'fd', 'blocage') like 'Client sans email%'
  and rele.ap(:'fd', 'email_client') = 'false');
select rele.ok('facture réelle non échue : absente de l''aperçu, « Facture non échue. »',
  rele.ap(:'fr', 'numero') is null and public.relances_situation(:'fr') ->> 'blocage' = 'Facture non échue.');
select rele.ok('aperçu : aucune écriture', (select count(*) = 0 from public.relances));

-- ===================== Réservation : règles et demande figée =====================
set role service_role;
\set R1 '\'77777777-0000-0000-0000-000000000001\''
select rele.refus('relance n° 2 demandée alors que la n° 1 est due : refusée',
  format($q$select rele.reserver(%L, '%s', 2)$q$, :R1, :'fa'), 'la relance due est la n° 1');
select rele.refus('champ supplémentaire (en-têtes) refusé', format($q$select rele.reserver(%L, '%s', 1, '{"headers":{"X-Test":"1"}}')$q$, :R1, :'fa'), 'champs de la demande inattendus');
select rele.refus('secret dans le texte refusé', format($q$select rele.reserver(%L, '%s', 1, '{"text":"ESSAI-FAC-2026-0101 clé re_abcdefghijklmnop"}')$q$, :R1, :'fa'), 'secret');
select rele.refus('« Authorization » dans l''objet refusé', format($q$select rele.reserver(%L, '%s', 1, '{"subject":"[ESSAI] ESSAI-FAC-2026-0101 Authorization"}')$q$, :R1, :'fa'), 'secret');
select rele.refus('retour à la ligne dans l''objet (injection d''en-tête) refusé', format($q$select rele.reserver(%L, '%s', 1, %L)$q$, :R1, :'fa',
  jsonb_build_object('subject', E'[ESSAI] ESSAI-FAC-2026-0101\nBcc: x@y.fr')), 'retour à la ligne');
select rele.refus('relance d''essai sans « [ESSAI] » dans l''objet refusée', format($q$select rele.reserver(%L, '%s', 1, '{"subject":"Facture ESSAI-FAC-2026-0101"}')$q$, :R1, :'fa'), '[ESSAI]');
select rele.refus('pièce jointe différente du PDF archivé refusée', format($q$select rele.reserver(%L, '%s', 1, %L)$q$, :R1, :'fa',
  jsonb_build_object('piece_jointe', jsonb_build_object('nom', 'ESSAI-FAC-2026-0101.pdf', 'type', 'application/pdf', 'empreinte', repeat('0', 64)))), 'pièce jointe');
select rele.refus('étiquette d''une autre relance refusée', format($q$select rele.reserver(%L, '%s', 1, '{"tags":[{"name":"relance_id","value":"x"}]}')$q$, :R1, :'fa'), 'étiquette');
select rele.refus('numéro de facture absent du texte refusé', format($q$select rele.reserver(%L, '%s', 1, '{"text":"Bonjour, une facture reste impayée chez nous."}')$q$, :R1, :'fa'), 'numéro de la facture');
select rele.reserver(:R1, :'fa', 1) as res \gset
select rele.ok('réservation : statut « réservée », AUCUNE date d''envoi, ni tentative ni acceptation',
  (:'res'::jsonb ->> 'reservee')::boolean and (rele.r(:R1)).statut = 'reservee' and (rele.r(:R1)).date_envoi is null
  and (rele.r(:R1)).tentatives = 0 and (rele.r(:R1)).accepte_le is null and (rele.r(:R1)).jour_relance = date '2026-11-02');
select rele.ok('réservation : clé anti-doublon et empreinte de la demande posées par la base',
  (rele.r(:R1)).cle_idempotence = 'sgi-relance-' || :R1
  and (rele.r(:R1)).requete_empreinte = encode(sha256(convert_to((rele.r(:R1)).requete_fournisseur::text, 'UTF8')), 'hex')
  and (rele.r(:R1)).destinataire = 'destinataire-essai@exemple.invalid' and (rele.r(:R1)).essai);
select rele.ok('réservation rejouée (réponse perdue) : la même, sans doublon',
  (rele.reserver(:R1, :'fa', 1) ->> 'deja')::boolean and (select count(*) = 1 from public.relances where facture_id = :'fa'));
select rele.refus('même identifiant, autre demande : refusé', format($q$select rele.reserver(%L, '%s', 1, '{"text":"Autre texte pour ESSAI-FAC-2026-0101, merci."}')$q$, :R1, :'fa'), 'autre demande');
select rele.ok('seconde réservation de la même facture : refusée tant que la première n''est pas résolue',
  rele.reserver('77777777-0000-0000-0000-0000000000ff', :'fa', 1) ->> 'motif' like 'Relance n° 1 réservée (aucun envoi confirmé)%');
reset role;
select rele.refus('écriture directe (postgres, sans l''application) refusée',
  format($q$insert into public.relances (facture_id, rang, requete_fournisseur) values ('%s', 1, '{}')$q$, :'fb'), 'naît uniquement de la réservation');
select rele.refus('modification directe refusée', format($q$update public.relances set statut = 'acceptee' where id = %L$q$, :R1), 'réservée à l''application');
select rele.refus('suppression refusée', format($q$delete from public.relances where id = %L$q$, :R1), 'ne se supprime jamais');
select rele.refus('demande figée : modification refusée même dans un contexte de l''application',
  format($q$do $x$ begin perform public.relances_contexte('evenement');
     update public.relances set objet = 'autre', historique = historique || '[{}]' where id = %L; end $x$$q$, :R1), 'demande figée');
select rele.refus('historique réécrit refusé', format($q$do $x$ begin perform public.relances_contexte('evenement');
     update public.relances set historique = '[{"action":"faux"},{}]' where id = %L; end $x$$q$, :R1), 'ajout seul');

-- Relance réelle : règles de la demande vérifiées directement (destinataire = email du client, expéditeur de test interdit,
-- aucune mention d'essai), sans aucune réservation réelle.
set role service_role;
\set RR '\'77777777-0000-0000-0000-0000000000a1\''
\set RX '\'77777777-0000-0000-0000-0000000000a9\''
select rele.ok('relance réelle : autre destinataire que le client refusé',
  public.relances_controle_requete(rele.req(:RX, :'fr', 1, '{"to":"autre@client-reel.fr"}'), :RX, :'fr') like '%email du client%');
select rele.ok('relance réelle : expéditeur onboarding@resend.dev refusé',
  public.relances_controle_requete(rele.req(:RX, :'fr', 1, '{"from":"SG <onboarding@resend.dev>"}'), :RX, :'fr') like '%expéditeur de test%');
select rele.ok('relance réelle : mention [ESSAI] refusée',
  public.relances_controle_requete(rele.req(:RX, :'fr', 1, '{"subject":"[ESSAI] Facture FAC-2026-0901"}'), :RX, :'fr') like '%mention d''essai%');
select rele.ok('relance réelle conforme : demande acceptée (destinataire en minuscules), mais facture non échue : aucune réservation',
  public.relances_controle_requete(rele.req(:RX, :'fr', 1), :RX, :'fr') is null
  and rele.req(:RX, :'fr', 1) ->> 'to' = 'compta@client-reel.fr'
  and rele.reserver(:RX, :'fr', 1) ->> 'motif' = 'Facture non échue.' and (rele.r(:RX)).id is null);
select rele.ok('réservation d''essai (facture d''essai J+10)', (rele.reserver(:RR, :'fk', 1) ->> 'reservee')::boolean and (rele.r(:RR)).essai);

-- ===================== Tentative, reprise, acceptation =====================
select public.relances_prendre(:R1, :COMPTE) as p \gset
select rele.ok('tentative 1 : enregistrée AVANT l''appel, limite = première tentative + 20 h ; toujours aucune date d''envoi',
  :'p'::jsonb ->> 'action' = 'envoyer' and (:'p'::jsonb ->> 'tentative')::int = 1 and (rele.r(:R1)).statut = 'en_cours'
  and (rele.r(:R1)).limite_reprise = :LUNDI::timestamptz + interval '20 hours' and (rele.r(:R1)).date_envoi is null
  and (rele.r(:R1)).compte_fournisseur = :COMPTE);
select rele.ok('la demande envoyée est exactement la demande figée (texte et empreinte)',
  :'p'::jsonb ->> 'requete_texte' = (rele.r(:R1)).requete_fournisseur::text
  and :'p'::jsonb ->> 'requete_empreinte' = (rele.r(:R1)).requete_empreinte
  and :'p'::jsonb ->> 'cle_idempotence' = 'sgi-relance-' || :R1);
select rele.ok('aucun secret dans la demande renvoyée', not public.relances_contient_secret(:'p'));
select rele.ok('reprise immédiate : attendre 10 minutes', public.relances_prendre(:R1, :COMPTE) ->> 'action' = 'attendre');
select rele.ok('réponse temporaire (429) : reste en cours, erreur conservée',
  public.relances_resultat(:R1, 1, 'temporaire', null, 'HTTP 429 trop de demandes') ->> 'statut' = 'en_cours'
  and (rele.r(:R1)).erreur = 'HTTP 429 trop de demandes');
select rele.ok('message d''erreur ressemblant à un secret : masqué',
  public.relances_resultat(:R1, 1, 'temporaire', null, 'clé re_abcdefghijklmnop refusée') is not null
  and (rele.r(:R1)).erreur like 'Message d''erreur masqué%' and (rele.r(:R1)).historique::text not like '%re_abcdefghijklmnop%');
select rele.ok('résultat d''une tentative dépassée (sans acceptation) : ignoré',
  (public.relances_resultat(:R1, 0, 'refus', null, 'HTTP 422') ->> 'ignore')::boolean and (rele.r(:R1)).statut = 'en_cours');
select rele.heure('2026-11-02 19:11:00+00');
select public.relances_prendre(:R1, :COMPTE) as p2 \gset
select rele.ok('reprise après 10 minutes : même demande, même clé, limite inchangée (jamais renouvelée)',
  (:'p2'::jsonb ->> 'tentative')::int = 2 and :'p2'::jsonb ->> 'requete_texte' = :'p'::jsonb ->> 'requete_texte'
  and :'p2'::jsonb ->> 'cle_idempotence' = :'p'::jsonb ->> 'cle_idempotence'
  and (rele.r(:R1)).limite_reprise = :LUNDI::timestamptz + interval '20 hours'
  and (rele.r(:R1)).premiere_tentative_le = :LUNDI::timestamptz);
select rele.refus('acceptation sans identifiant du fournisseur refusée', format($q$select public.relances_resultat(%L, 2, 'acceptee', '', null)$q$, :R1), 'sans identifiant');
select rele.ok('acceptation : date_envoi et accepte_le à l''heure de l''acceptation',
  public.relances_resultat(:R1, 2, 'acceptee', 'em-0001', null) ->> 'statut' = 'acceptee'
  and (rele.r(:R1)).date_envoi = '2026-11-02 19:11:00+00' and (rele.r(:R1)).accepte_le = '2026-11-02 19:11:00+00'
  and (rele.r(:R1)).fournisseur_id = 'em-0001');
select rele.ok('acceptation rejouée : « déjà », rien ne change ; autre identifiant : anomalie signalée, rien ne change',
  (public.relances_resultat(:R1, 2, 'acceptee', 'em-0001', null) ->> 'deja')::boolean
  and (public.relances_resultat(:R1, 2, 'acceptee', 'em-9999', null) ->> 'anomalie')::boolean
  and (rele.r(:R1)).fournisseur_id = 'em-0001');
select rele.ok('après acceptation : écart minimal de 8 jours affiché avec la date possible',
  public.relances_situation(:'fa') ->> 'blocage' = 'Écart minimal de 8 jours depuis la dernière relance acceptée : relance n° 2 possible le 10/11/2026.');
select rele.refus('valeur constatée (date d''envoi) : jamais modifiée', format($q$do $x$ begin perform public.relances_contexte('evenement');
     update public.relances set date_envoi = now(), historique = historique || '[{}]' where id = %L; end $x$$q$, :R1), 'ne change jamais');

-- Garde-fou quotidien et reprise le lendemain (précision n° 1 de l'utilisateur).
\set RE '\'77777777-0000-0000-0000-0000000000e1\''
select rele.heure('2026-11-02 20:00:00+00');   -- lundi 16 h
select (rele.reserver(:RE, :'fe', 1) ->> 'reservee')::boolean as ok_e \gset
select public.relances_prendre(:RE, :COMPTE) is not null as t1 \gset
-- Arrêt après l'appel : aucun résultat enregistré. Mardi 9 h : la MÊME demande est reprise (pas une nouvelle relance).
select rele.heure('2026-11-03 13:00:00+00');
select rele.ok('lendemain : reprise de la même demande permise (même clé), limite non dépassée (mardi 12 h)',
  public.relances_prendre(:RE, :COMPTE) ->> 'action' = 'envoyer' and (rele.r(:RE)).tentatives = 2
  and (rele.r(:RE)).limite_reprise = '2026-11-03 16:00:00+00');
select rele.ok('le lendemain, une NOUVELLE relance de cette facture reste refusée (relance en cours)',
  rele.reserver('77777777-0000-0000-0000-0000000000e2', :'fe', 1) ->> 'motif' like 'Relance n° 1 en cours%');
select public.relances_resultat(:RE, 2, 'acceptee', 'em-0002', null) is not null as acc \gset
select rele.ok('acceptée aujourd''hui (mardi) : compte pour aujourd''hui (date_envoi mardi), aucune autre relance aujourd''hui',
  public.relances_jour((rele.r(:RE)).date_envoi) = date '2026-11-03'
  and (public.relances_situation(:'fe') ->> 'rang') is null);
-- Clause « tentée aujourd'hui » seule : relance tentée puis constatée « aucun envoi » le même jour.
\set RG '\'77777777-0000-0000-0000-0000000000f1\''
select (rele.reserver(:RG, :'fg', 1) ->> 'reservee')::boolean as ok_g \gset
select public.relances_prendre(:RG, :COMPTE) is not null as tg \gset
select rele.heure('2026-11-03 13:20:00+00');
reset role;
select public.relances_resoudre(:ADMIN, :RG, 'aucun_envoi', 'Aucun email visible chez le fournisseur', null, null) is not null as res_g \gset
set role service_role;
select rele.ok('tentative aujourd''hui puis « aucun envoi » : aucune nouvelle relance le même jour',
  public.relances_situation(:'fg') ->> 'blocage' = 'Une relance a déjà été réservée, tentée ou acceptée aujourd''hui pour cette facture.');
select rele.heure('2026-11-04 13:00:00+00');
select rele.ok('le lendemain : la relance n° 1 se refait (l''abandonnée ne compte pas)',
  public.relances_situation(:'fg') ->> 'rang' = '1'
  and (rele.reserver('77777777-0000-0000-0000-0000000000f2', :'fg', 1) ->> 'reservee')::boolean);

-- Limite de reprise, compte fournisseur, nombre de tentatives, facture réglée, réservation expirée.
\set RH '\'77777777-0000-0000-0000-0000000000b1\''
select rele.heure('2026-11-02 19:30:00+00');
select (rele.reserver(:RH, :'fh', 1) ->> 'reservee')::boolean as ok_h \gset
select public.relances_prendre(:RH, :COMPTE) is not null as th \gset
select rele.heure('2026-11-03 14:00:00+00');   -- mardi 10 h, < limite (11 h 30)
select rele.ok('autre compte fournisseur : aucune reprise, « à vérifier »',
  public.relances_prendre(:RH, :AUTRE_COMPTE) ->> 'statut' = 'a_verifier'
  and (rele.r(:RH)).erreur like 'Compte fournisseur différent%' and (rele.r(:RH)).tentatives = 1);
select rele.ok('à vérifier : bloque toute nouvelle relance, même la semaine suivante',
  rele.reserver('77777777-0000-0000-0000-0000000000b2', :'fh', 1) ->> 'motif' like 'Relance n° 1 à vérifier (envoi incertain)%');
select rele.heure('2026-11-10 14:00:00+00');
select rele.ok('… toujours bloquée 7 jours plus tard', public.relances_situation(:'fh') ->> 'blocage' like 'Relance n° 1 à vérifier%');
\set RI '\'77777777-0000-0000-0000-0000000000c1\''
select rele.heure('2026-11-02 19:30:00+00');
select (rele.reserver(:RI, :'fi', 1) ->> 'reservee')::boolean as ok_i \gset
select public.relances_prendre(:RI, :COMPTE) is not null as ti \gset
select rele.heure('2026-11-03 15:30:00+00');   -- exactement première tentative + 20 h
select rele.ok('limite de reprise atteinte (première tentative + 20 h) : « à vérifier », aucun appel',
  public.relances_prendre(:RI, :COMPTE) ->> 'statut' = 'a_verifier' and (rele.r(:RI)).erreur like 'Limite de reprise atteinte%');
\set RJ '\'77777777-0000-0000-0000-0000000000d1\''
select rele.heure('2026-11-02 12:00:00+00');   -- lundi 8 h
select (rele.reserver(:RJ, :'fj', 1) ->> 'reservee')::boolean as ok_j \gset
do $$ declare i int; begin
  for i in 1..5 loop
    perform rele.heure(('2026-11-02 12:00:00+00'::timestamptz + make_interval(mins => (i - 1) * 11))::text);
    perform public.relances_prendre('77777777-0000-0000-0000-0000000000d1', '0123456789abcdef0123456789abcdef');
    perform public.relances_resultat('77777777-0000-0000-0000-0000000000d1', i, 'temporaire', null, 'HTTP 503');
  end loop;
end $$;
select rele.heure('2026-11-02 13:00:00+00');
select rele.ok('5 tentatives sans réponse définitive : la 6e est refusée, « à vérifier »',
  public.relances_prendre(:RJ, :COMPTE) ->> 'statut' = 'a_verifier' and (rele.r(:RJ)).tentatives = 5);
-- Facture réglée : avant toute tentative → abandonnée ; pendant une reprise → à vérifier.
\set RB '\'77777777-0000-0000-0000-0000000000b9\''
select rele.heure('2026-11-06 14:00:00+00');   -- vendredi 10 h : J+7 de fb
select (rele.reserver(:RB, :'fb', 1) ->> 'reservee')::boolean as ok_b \gset
reset role;
select rele.regler(:'fb');
set role service_role;
select rele.ok('facture réglée avant toute tentative : réservation abandonnée, aucun envoi',
  public.relances_prendre(:RB, :COMPTE) ->> 'statut' = 'abandonnee' and (rele.r(:RB)).date_envoi is null);
select rele.ok('facture réglée : plus aucune relance', public.relances_situation(:'fb') ->> 'blocage' like 'Facture non émise ou réglée%');
select rele.heure('2026-11-03 16:00:00+00');   -- 21 h après la réservation réelle, jamais tentée
select rele.ok('réservation expirée sans tentative (> 20 h) : abandonnée, aucun envoi',
  public.relances_prendre(:RR, :COMPTE) ->> 'statut' = 'abandonnee' and (rele.r(:RR)).tentatives = 0
  and (rele.r(:RR)).date_envoi is null);

-- Horaires et week-end.
select rele.heure('2026-11-07 14:00:00+00');   -- samedi 10 h
select rele.ok('samedi : aucune relance due (hors horaires), message explicite',
  public.relances_situation(:'fk') ->> 'blocage' = 'Hors des horaires d''envoi (du lundi au vendredi, de 8 h à 17 h, heure de Martinique).');
select rele.ok('samedi : réservation refusée', not (rele.reserver('77777777-0000-0000-0000-0000000000a2', :'fk', 1) ->> 'reservee')::boolean);
\set RL '\'77777777-0000-0000-0000-0000000000a3\''
select rele.heure('2026-11-06 20:50:00+00');   -- vendredi 16 h 50
select (rele.reserver(:RL, :'fk', 1, '{}') ->> 'reservee')::boolean as ok_l \gset
select rele.heure('2026-11-06 21:05:00+00');   -- vendredi 17 h 05 : la tentative attend lundi
select rele.ok('réservée à 16 h 50, prise à 17 h 05 : la tentative attend (hors horaires), aucune tentative comptée',
  public.relances_prendre(:RL, :COMPTE) ->> 'action' = 'attendre' and (rele.r(:RL)).tentatives = 0);
reset role;

-- ===================== Résolution par l'administrateur =====================
insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-0000000000c9', 'collab-relances@exemple.invalid');
set role service_role;
select rele.heure('2026-11-10 14:00:00+00');
select rele.refus('résolution par un compte non administrateur refusée',
  format($q$select public.relances_resoudre('aaaaaaaa-0000-0000-0000-0000000000c9', %L, 'aucun_envoi', 'Motif valable', null, null)$q$, :RH), 'administrateur actif');
select rele.refus('résolution sans motif refusée', format($q$select public.relances_resoudre(%L, %L, 'aucun_envoi', '  ', null, null)$q$, :ADMIN, :RH), 'motif obligatoire');
select rele.refus('« email accepté » daté avant la première tentative refusé',
  format($q$select public.relances_resoudre(%L, %L, 'email_accepte', 'Vu chez Resend', '2026-11-01 12:00:00+00', null)$q$, :ADMIN, :RH), 'incohérente');
select rele.refus('« email accepté » daté dans le futur refusé',
  format($q$select public.relances_resoudre(%L, %L, 'email_accepte', 'Vu chez Resend', '2026-12-01 12:00:00+00', null)$q$, :ADMIN, :RH), 'incohérente');
select rele.refus('« traitée » sur une relance à vérifier refusé (constat d''envoi exigé)',
  format($q$select public.relances_resoudre(%L, %L, 'traitee', 'Motif valable', null, null)$q$, :ADMIN, :RH), 'refusée ou rejetée');
select rele.ok('« email accepté » constaté : date_envoi = date constatée, résolution et statut précédent tracés',
  public.relances_resoudre(:ADMIN, :RH, 'email_accepte', 'Email visible dans le tableau de bord Resend', '2026-11-02 19:31:00+00', 'em-h')
    ->> 'statut' = 'acceptee'
  and (rele.r(:RH)).date_envoi = '2026-11-02 19:31:00+00' and (rele.r(:RH)).resolu_par = :ADMIN
  and (rele.r(:RH)).historique -> -1 ->> 'statut_precedent' = 'a_verifier'
  and (rele.r(:RH)).historique -> -1 ->> 'motif' = 'Email visible dans le tableau de bord Resend');
select rele.refus('résolution d''une relance déjà résolue refusée',
  format($q$select public.relances_resoudre(%L, %L, 'aucun_envoi', 'Encore une fois', null, null)$q$, :ADMIN, :RH), 'ne bloque rien');
select public.relances_resoudre(:ADMIN, :RI, 'aucun_envoi', 'Aucun email chez le fournisseur', null, null) ->> 'statut' as st_i \gset
select rele.ok('« aucun envoi » constaté : abandonnée, la facture est débloquée',
  :'st_i' = 'abandonnee' and public.relances_situation(:'fi') ->> 'rang' = '1', public.relances_situation(:'fi')::text);
-- Tentative en cours : jamais de résolution pendant un appel possible.
\set RF '\'77777777-0000-0000-0000-0000000000c2\''
select rele.heure('2026-11-10 15:00:00+00');
select (rele.reserver(:RF, :'ff', 1) ->> 'reservee')::boolean as ok_f \gset
select public.relances_prendre(:RF, :COMPTE) is not null as tf \gset
select rele.heure('2026-11-10 15:05:00+00');
select rele.refus('résolution pendant une tentative récente (5 min) refusée',
  format($q$select public.relances_resoudre(%L, %L, 'aucun_envoi', 'Trop tôt', null, null)$q$, :ADMIN, :RF), 'peut-être en cours');
-- Refus certain du fournisseur (422) : « refusée », bloque ; résolution « traitée » ; la n° 1 se refait le lendemain.
select public.relances_resultat(:RF, 1, 'refus', null, 'HTTP 422 adresse invalide') ->> 'statut' as st_f \gset
select rele.ok('refus du fournisseur (422) : « refusée », bloquante',
  :'st_f' = 'refusee' and public.relances_situation(:'ff') ->> 'blocage' like 'Relance n° 1 refusée par le fournisseur%',
  public.relances_situation(:'ff')::text);
select rele.ok('résolution « traitée » d''un refus', public.relances_resoudre(:ADMIN, :RF, 'traitee', 'Adresse du client corrigée', null, null) ->> 'statut' = 'refusee');
select rele.ok('… même jour : aucune nouvelle relance (tentée aujourd''hui)',
  public.relances_situation(:'ff') ->> 'blocage' = 'Une relance a déjà été réservée, tentée ou acceptée aujourd''hui pour cette facture.');
select rele.heure('2026-11-11 15:00:00+00');
select rele.ok('… le lendemain : la relance n° 1 se refait (un refus certain ne compte pas)',
  (rele.reserver('77777777-0000-0000-0000-0000000000c3', :'ff', 1) ->> 'reservee')::boolean);

-- ===================== Événements de livraison : doubles, retards, désordre =====================
select rele.ok('événement d''un email inconnu : ignoré',
  public.relances_evenement_livraison('evt-x', 'email.delivered', 'em-inconnu', null, now(), null) ->> 'resultat' = 'inconnu');
select rele.refus('événement incomplet refusé', $q$select public.relances_evenement_livraison('', 'email.sent', 'em-0001', null, now(), null)$q$, 'incomplet');
-- Arrêt après acceptation, avant l'enregistrement de la réponse : l'événement (étiquette de la relance) la confirme.
\set RC '\'77777777-0000-0000-0000-0000000000c4\''
select rele.heure('2026-11-12 14:00:00+00');
select (rele.reserver(:RC, :'fi', 1) ->> 'reservee')::boolean as ok_c \gset
select public.relances_prendre(:RC, :COMPTE) is not null as tc \gset
select rele.ok('arrêt après acceptation : l''événement « email.sent » retrouvé par l''étiquette confirme l''acceptation',
  public.relances_evenement_livraison('evt-c1', 'email.sent', 'em-c', :RC, '2026-11-12 14:00:05+00', null) ->> 'statut' = 'acceptee'
  and (rele.r(:RC)).fournisseur_id = 'em-c' and (rele.r(:RC)).date_envoi = '2026-11-12 14:00:05+00');
select rele.ok('reprise après cette confirmation : rien à envoyer', public.relances_prendre(:RC, :COMPTE) ->> 'action' = 'rien');
select rele.ok('réponse du fournisseur arrivée ensuite (même identifiant) : « déjà », rien ne change',
  (public.relances_resultat(:RC, 1, 'acceptee', 'em-c', null) ->> 'deja')::boolean and (rele.r(:RC)).date_envoi = '2026-11-12 14:00:05+00');
select rele.ok('étiquette de cette relance mais AUTRE email : anomalie consignée, rien ne change',
  public.relances_evenement_livraison('evt-c2', 'email.bounced', 'em-autre', :RC, now(), null) ->> 'statut' = 'acceptee'
  and (rele.r(:RC)).rebond_le is null and (rele.r(:RC)).fournisseur_id = 'em-c'
  and ((rele.r(:RC)).historique -> -1 ->> 'anomalie')::boolean);
-- Livré puis rejeté : le rejet l'emporte, la livraison constatée reste ; rejet en double ignoré ; « sent » tardif sans effet.
select rele.ok('livré : livre_le posé', public.relances_evenement_livraison('evt-e1', 'email.delivered', 'em-0002', null, '2026-11-03 13:01:00+00', null) is not null
  and (rele.r(:RE)).livre_le = '2026-11-03 13:01:00+00' and (rele.r(:RE)).statut = 'acceptee');
select rele.ok('rejet définitif ensuite : « rejetée », livraison antérieure conservée, motif enregistré',
  public.relances_evenement_livraison('evt-e2', 'email.bounced', 'em-0002', null, '2026-11-03 13:05:00+00', 'Boîte inexistante') ->> 'statut' = 'rejetee'
  and (rele.r(:RE)).rebond_le = '2026-11-03 13:05:00+00' and (rele.r(:RE)).livre_le is not null and (rele.r(:RE)).rebond_motif = 'Boîte inexistante');
select rele.ok('même événement reçu deux fois : ignoré (aucun ajout à l''historique)',
  public.relances_evenement_livraison('evt-e2', 'email.bounced', 'em-0002', null, '2026-11-03 13:05:00+00', 'Boîte inexistante') ->> 'resultat' = 'deja'
  and (select count(*) = 1 from jsonb_array_elements((rele.r(:RE)).historique) e where e ->> 'evenement_id' = 'evt-e2'));
select rele.ok('« sent » et « delivered » tardifs après le rejet : toujours « rejetée », rien d''effacé',
  public.relances_evenement_livraison('evt-e3', 'email.sent', 'em-0002', null, '2026-11-03 13:00:00+00', null) ->> 'statut' = 'rejetee'
  and public.relances_evenement_livraison('evt-e4', 'email.delivered', 'em-0002', null, '2026-11-03 13:10:00+00', null) ->> 'statut' = 'rejetee'
  and (rele.r(:RE)).livre_le = '2026-11-03 13:01:00+00' and (rele.r(:RE)).rebond_le = '2026-11-03 13:05:00+00');
select rele.ok('rejet : bloque les relances suivantes de la facture, même 9 jours plus tard',
  public.relances_situation(:'fe') ->> 'blocage' like 'Relance n° 1 rejetée par le serveur du destinataire%');
-- Désordre : rejet reçu AVANT la livraison : la livraison tardive n'est pas enregistrée comme livrée.
\set RM '\'77777777-0000-0000-0000-0000000000c6\''
select rele.put('fm', rele.facture('ESSAI-FAC-2026-0111', true, date '2026-11-12' - 12, true, '55555555-0000-0000-0000-0000000000e1')::text);
select rele.get('fm') as fm \gset
select (rele.reserver(:RM, :'fm', 1) ->> 'reservee')::boolean as ok_m \gset
select public.relances_prendre(:RM, :COMPTE) is not null as tm \gset
select public.relances_resultat(:RM, 1, 'acceptee', 'em-m', null) is not null as am \gset
select rele.ok('désordre : rejet avant livraison, puis livraison tardive : « rejetée », livre_le vide',
  public.relances_evenement_livraison('evt-m1', 'email.bounced', 'em-m', null, '2026-11-12 14:02:00+00', null) ->> 'statut' = 'rejetee'
  and public.relances_evenement_livraison('evt-m2', 'email.delivered', 'em-m', null, '2026-11-12 14:01:00+00', null) ->> 'statut' = 'rejetee'
  and (rele.r(:RM)).livre_le is null);
select rele.ok('détail ressemblant à un secret : masqué',
  public.relances_evenement_livraison('evt-m3', 'email.delivery_delayed', 'em-m', null, now(), 'Bearer abcdef') is not null
  and (rele.r(:RM)).historique::text not like '%Bearer abcdef%');
-- Rejet APRÈS une résolution « email accepté » : bloque de nouveau (le rejet n'est jamais effacé).
select public.relances_evenement_livraison('evt-h1', 'email.bounced', 'em-h', null, '2026-11-12 14:03:00+00', null) ->> 'statut' as st_h \gset
select rele.ok('rejet après un constat « email accepté » : bloque de nouveau la facture',
  :'st_h' = 'rejetee' and public.relances_situation(:'fh') ->> 'blocage' like 'Relance n° 1 rejetée%', public.relances_situation(:'fh')::text);
select rele.ok('… nouvelle résolution « traitée » : tracée avec la résolution précédente',
  public.relances_resoudre(:ADMIN, :RH, 'traitee', 'Adresse vérifiée avec le client', null, null) ->> 'statut' = 'rejetee'
  and (rele.r(:RH)).historique -> -1 -> 'resolution_precedente' ->> 'motif' = 'Email visible dans le tableau de bord Resend');
-- Événements sur une relance jamais tentée ou refusée : seulement consignés (anomalie), aucun changement d'état.
select rele.ok('événement sur une relance seulement réservée : consigné comme anomalie, toujours « réservée »',
  public.relances_evenement_livraison('evt-l1', 'email.sent', 'em-l', :RL, now(), null) ->> 'statut' = 'reservee'
  and (rele.r(:RL)).fournisseur_id is null and (rele.r(:RL)).date_envoi is null
  and ((rele.r(:RL)).historique -> -1 ->> 'anomalie')::boolean);
select rele.ok('événement sur une relance refusée : anomalie, toujours « refusée »',
  public.relances_evenement_livraison('evt-f1', 'email.bounced', 'em-f', :RF, now(), null) ->> 'statut' = 'refusee'
  and (rele.r(:RF)).rebond_le is null);
-- Valeur constatée : livre_le jamais modifiée.
reset role;
select rele.refus('livraison constatée : jamais modifiée', format($q$do $x$ begin perform public.relances_contexte('evenement');
     update public.relances set livre_le = now(), historique = historique || '[{}]' where id = %L; end $x$$q$, :RE), 'ne change jamais');
select rele.refus('limite de reprise : jamais renouvelée', format($q$do $x$ begin perform public.relances_contexte('prendre');
     update public.relances set limite_reprise = limite_reprise + interval '1 day', historique = historique || '[{}]' where id = %L; end $x$$q$, :RJ), 'ne change jamais');
select rele.refus('rejet : jamais effacé (retour à « acceptée » interdit)', format($q$do $x$ begin perform public.relances_contexte('evenement');
     update public.relances set statut = 'acceptee', historique = historique || '[{}]' where id = %L; end $x$$q$, :RE), 'changement d''état interdit');

-- ===================== Calendrier : rattrapage d'une facture découverte à J+40 =====================
set role service_role;
\set R2 '\'77777777-0000-0000-0000-000000000002\''
\set R3 '\'77777777-0000-0000-0000-000000000003\''
select rele.heure('2026-11-09 14:00:00+00');
select rele.ok('J+47, 7 jours après la n° 1 : pas encore (écart de 8 jours), date indiquée',
  public.relances_situation(:'fa') ->> 'blocage' like 'Écart minimal de 8 jours%possible le 10/11/2026.');
select rele.heure('2026-11-10 14:00:00+00');
select rele.ok('8 jours après : relance n° 2 due', public.relances_situation(:'fa') ->> 'rang' = '2');
select (rele.reserver(:R2, :'fa', 2) ->> 'reservee')::boolean as ok2 \gset
select public.relances_prendre(:R2, :COMPTE) is not null as t2 \gset
select public.relances_resultat(:R2, 1, 'acceptee', 'em-a2', null) is not null as a2 \gset
select rele.heure('2026-11-17 14:00:00+00');
select rele.ok('7 jours après la n° 2 : pas encore', public.relances_situation(:'fa') ->> 'blocage' like 'Écart minimal de 8 jours%');
select rele.heure('2026-11-18 14:00:00+00');
select rele.ok('8 jours après : relance n° 3 due', public.relances_situation(:'fa') ->> 'rang' = '3');
select (rele.reserver(:R3, :'fa', 3) ->> 'reservee')::boolean as ok3 \gset
select public.relances_prendre(:R3, :COMPTE) is not null as t3 \gset
select public.relances_resultat(:R3, 1, 'acceptee', 'em-a3', null) is not null as a3 \gset
select rele.heure('2026-12-01 14:00:00+00');
select rele.ok('après la n° 3 : « Relances terminées : suivi manuel », plus aucune relance',
  public.relances_situation(:'fa') ->> 'blocage' = 'Relances terminées : suivi manuel.');
select rele.ok('rattrapage : 3 relances espacées de 8 jours (02/11, 10/11, 18/11), jamais rapprochées',
  (select string_agg(to_char(public.relances_jour(date_envoi), 'DD/MM'), ',' order by rang) from public.relances where facture_id = :'fa')
  = '02/11,10/11,18/11');
select rele.ok('chaque relance n° 1, 2, 3 au plus une fois', (select count(distinct rang) = count(*) from public.relances where facture_id = :'fa'));
reset role;

-- ===================== Nettoyage des essais =====================
select count(*) as reelles from public.relances where not essai \gset
set role service_role;
select public.supprimer_essais_finance() as net \gset
reset role;
select rele.ok('nettoyage : factures d''essai et TOUTES leurs relances supprimées',
  (select count(*) = 0 from public.relances where essai) and (select count(*) = 0 from public.factures where essai)
  and (:'net'::jsonb ->> 'relances')::int > 0);
select rele.ok('aucune relance réelle n''a existé dans ces tests (0 avant et après le nettoyage)',
  :reelles = 0 and (select count(*) from public.relances where not essai) = 0);

-- ===================== Définitions d'origine rétablies =====================
create or replace function public.relances_maintenant()
returns timestamptz
language sql
stable
as $$
  select now();
$$;
create or replace function public.relances_adresse_fictive(p_adresse text)
returns boolean
language sql
immutable
as $$
  select coalesce(lower(split_part(p_adresse, '@', 2)), '') ~
         '(^|\.)(exemple\.invalid|example\.(com|net|org)|resend\.dev)$|\.(invalid|test|example|localhost)$|^localhost$|^$';
$$;
select rele.ok('heure réelle et règle des adresses fictives rétablies (empreintes d''origine)',
  (select md5(prosrc) from pg_proc where proname = 'relances_maintenant') = :'def_maintenant'
  and (select md5(prosrc) from pg_proc where proname = 'relances_adresse_fictive') = :'def_fictive'
  and public.relances_adresse_fictive('a@exemple.invalid'));
select rele.ok('aucun contexte resté actif', coalesce(current_setting('sgi.rel_operation', true), '') = '');
select rele.ok('aucun secret enregistré dans les relances restantes',
  not exists (select 1 from public.relances r where public.relances_contient_secret(r.requete_fournisseur::text)
              or public.relances_contient_secret(r.historique::text) or public.relances_contient_secret(r.erreur)));
select format('BILAN : %s/%s contrôles réussis', count(*) filter (where ok), count(*)) from rele.resultats;
select format('  [ÉCHEC] %s : %s', libelle, detail) from rele.resultats where not ok order by n;
