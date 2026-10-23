#!/bin/bash
# Acceptations simultanées sur la base d'ESSAI (à lancer après tests_commercial.sql).
H=/var/tmp/pg-essai; P=5499
q() { psql -h $H -p $P -U postgres -d essai -qAt -v ON_ERROR_STOP=1 "$@"; }
q <<'SQL'
insert into public.prospects (id, nom, societe, email) values ('cccccccc-0000-0000-0000-0000000000c2', 'M. Concurrent', 'Concurrence SAS', 'concurrence@exemple.invalid');
insert into public.devis (id, prospect_id, regime_tva, territoire_tva, taux_tva, criteres_tva)
select ('dddddddd-0000-0000-0000-0000000000c' || n)::uuid, 'cccccccc-0000-0000-0000-0000000000c2', 'taxable', 'MQ', 8.5,
       '{"nature_mission":"prestation_intellectuelle","statut_client":"assujetti_france"}'
  from generate_series(1, 3) n;
insert into public.devis_lignes (devis_id, designation, quantite, prix_unitaire)
select ('dddddddd-0000-0000-0000-0000000000c' || n)::uuid, 'Mission', 1, 1000 from generate_series(1, 3) n;
select public.emettre_devis(('dddddddd-0000-0000-0000-0000000000c' || n)::uuid, 'aaaaaaaa-0000-0000-0000-000000000002', '{"raison_sociale":"SGI"}', 'v1') from generate_series(1, 3) n;
insert into storage.objects (bucket_id, name, metadata) select 'devis', id || '/' || numero || '.pdf', '{"size": 10}' from public.devis where prospect_id = 'cccccccc-0000-0000-0000-0000000000c2';
select public.enregistrer_pdf_devis(id, id || '/' || numero || '.pdf', repeat('f', 64), 10) from public.devis where prospect_id = 'cccccccc-0000-0000-0000-0000000000c2';
select public.declarer_envoi_devis(id, 'aaaaaaaa-0000-0000-0000-000000000002', now(), 'email', null) from public.devis where prospect_id = 'cccccccc-0000-0000-0000-0000000000c2';
SQL
echo "Cas 1 : deux devis du même prospect acceptés en même temps"
q -c "begin; update public.devis set statut='accepte' where id='dddddddd-0000-0000-0000-0000000000c1'; select pg_sleep(2); commit;" & 
sleep 0.5
q -c "begin; update public.devis set statut='accepte' where id='dddddddd-0000-0000-0000-0000000000c2'; commit;" &
wait
q -c "select '  clients créés pour ce prospect : ' || count(*) from public.clients where nom = 'Concurrence SAS'" \
  -c "select '  projets créés : ' || count(*) from public.projets p join public.devis d on d.id = p.devis_id where d.prospect_id = 'cccccccc-0000-0000-0000-0000000000c2'" \
  -c "select '  les deux projets pointent vers le même client : ' || (count(distinct p.client_id) = 1) from public.projets p join public.devis d on d.id = p.devis_id where d.prospect_id = 'cccccccc-0000-0000-0000-0000000000c2'"
echo "Cas 2 : le même devis accepté deux fois en même temps"
q -c "begin; update public.devis set statut='accepte' where id='dddddddd-0000-0000-0000-0000000000c3'; select pg_sleep(2); commit;" &
sleep 0.5
q -c "begin; update public.devis set statut='accepte' where id='dddddddd-0000-0000-0000-0000000000c3'; commit;" &
wait
q -c "select '  projets pour ce devis : ' || count(*) from public.projets where devis_id = 'dddddddd-0000-0000-0000-0000000000c3'" \
  -c "select '  clients pour ce prospect : ' || count(*) from public.clients where nom = 'Concurrence SAS'"
