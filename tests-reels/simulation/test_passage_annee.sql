-- Passage d'année : à lancer sur la base d'essai à HORLOGE SIMULÉE (31/12/2026 22:30 en Martinique,
-- soit 01/01/2027 02:30 UTC). Session laissée en UTC, comme les connexions Supabase.
\pset tuples_only on
\pset format unaligned
select set_config('timezone', 'UTC', false);
select 'Session : ' || current_setting('timezone') || ' ; date de session ' || current_date;
select 'Appel DIRECT de prochain_numero (sans précaution) : ' || public.prochain_numero('demonstration', 'X')
       || '  ← année UTC';
insert into public.prospects (id, nom, societe, adresse, code_postal, ville, pays)
values ('cccccccc-0000-0000-0000-0000000000e1', 'Passage', 'Passage SARL', '1 rue', '97200', 'Fort-de-France', 'MQ');
insert into public.devis (id, prospect_id, regime_tva, territoire_tva, taux_tva, criteres_tva, type_mission)
values ('dddddddd-0000-0000-0000-0000000000e1', 'cccccccc-0000-0000-0000-0000000000e1', 'taxable', 'MQ', 8.5,
        '{"nature_mission":"prestation_intellectuelle","statut_client":"assujetti_france"}', 'conseil');
insert into public.devis_lignes (devis_id, designation, quantite, prix_unitaire) values ('dddddddd-0000-0000-0000-0000000000e1', 'Mission', 1, 100);
select public.emettre_devis('dddddddd-0000-0000-0000-0000000000e1', (select id from public.profiles where role = 'admin' limit 1),
  '{"raison_sociale":"SIMULATION","forme_juridique":"SAS","capital_social":"1","adresse":"x","code_postal":"97200","ville":"Fort-de-France","siret":"00000000000000","immatriculation":"x","tva_intracom":"x","validite_jours":"30","obligation_assurance":"non_requise"}', 'v1');
select 'Émission par la base : numéro ' || numero || ' ; date d''émission ' || date_emission
  || case when substr(numero, 5, 4) = to_char(date_emission, 'YYYY') then '  → année du numéro = année de la date : OK'
          else '  → ÉCHEC : année du numéro différente de la date' end
  from public.devis where id = 'dddddddd-0000-0000-0000-0000000000e1';
select 'Compteurs : ' || string_agg(cle || '=' || valeur, ', ' order by cle) from public.compteurs;
select 'Fuseau de la session après l''émission : ' || current_setting('timezone')
  || case when current_setting('timezone') = 'UTC' then '  → inchangé : OK' else '  → ÉCHEC' end;
