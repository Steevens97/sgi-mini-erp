#!/bin/bash
# Concurrence et reprises sur la base d'ESSAI (à lancer après tests_commercial.sql).
H=/var/tmp/pg-essai; P=5499
q() { psql -h $H -p $P -U postgres -d essai -qAt -v ON_ERROR_STOP=1 "$@"; }
ok() { if [ "$2" = "$3" ]; then echo "  [OK ] $1 ($2)"; else echo "  [ÉCHEC] $1 : obtenu « $2 », attendu « $3 »"; fi; }
A=aaaaaaaa-0000-0000-0000-000000000002
q <<SQL
insert into public.prospects (id, nom, societe, email, adresse, code_postal, ville, pays) values
  ('cccccccc-0000-0000-0000-0000000000c2', 'M. Concurrent', 'Concurrence SAS', 'concurrence@exemple.invalid', '1 rue', '97200', 'Fort-de-France', 'MQ');
insert into public.devis (id, prospect_id, regime_tva, territoire_tva, taux_tva, criteres_tva)
select ('dddddddd-0000-0000-0000-0000000000c' || n)::uuid, 'cccccccc-0000-0000-0000-0000000000c2', 'taxable', 'MQ', 8.5,
       '{"nature_mission":"prestation_intellectuelle","statut_client":"assujetti_france"}' from generate_series(1, 4) n;
insert into public.devis_lignes (devis_id, designation, quantite, prix_unitaire)
select ('dddddddd-0000-0000-0000-0000000000c' || n)::uuid, 'Mission', 1, 1000 from generate_series(1, 4) n;
SQL
C=$(q -c "select valeur from public.compteurs where cle like 'devis_%'")

echo "Cas A : deux émissions simultanées du même devis"
q -c "begin; select public.emettre_devis('dddddddd-0000-0000-0000-0000000000c4','$A',essai.emetteur(),'v1'); select pg_sleep(2); commit;" > /tmp/e1 &
sleep 0.5
q -c "select public.emettre_devis('dddddddd-0000-0000-0000-0000000000c4','$A',essai.emetteur(),'v1');" > /tmp/e2 &
wait
ok "les deux appels renvoient le même numéro" "$(sort -u /tmp/e1 /tmp/e2 | grep -c DEV)" "1"
ok "un seul numéro consommé" "$(q -c "select valeur from public.compteurs where cle like 'devis_%'")" "$((C + 1))"

echo "Cas B : émission qui échoue après l'attribution du numéro (annulation de la transaction)"
q -c "begin; select public.emettre_devis('dddddddd-0000-0000-0000-0000000000c3','$A',essai.emetteur(),'v1'); rollback;" >/dev/null
ok "devis toujours brouillon, sans numéro" "$(q -c "select statut || '/' || coalesce(numero, 'aucun') from public.devis where id='dddddddd-0000-0000-0000-0000000000c3'")" "brouillon/aucun"
ok "compteur revenu à sa valeur (numéro non perdu)" "$(q -c "select valeur from public.compteurs where cle like 'devis_%'")" "$((C + 1))"

echo "Cas C : fichier stocké mais enregistrement de l'état en échec, puis reprise"
N=$(q -c "select numero from public.devis where id='dddddddd-0000-0000-0000-0000000000c4'")
q -c "insert into storage.objects (bucket_id, name, metadata) values ('devis', 'dddddddd-0000-0000-0000-0000000000c4/$N.pdf', '{\"size\": 4096}')"
q -c "begin; select public.enregistrer_pdf_devis('dddddddd-0000-0000-0000-0000000000c4','dddddddd-0000-0000-0000-0000000000c4/$N.pdf',repeat('1',64),4096); rollback;" >/dev/null
q -c "select public.signaler_echec_pdf_devis('dddddddd-0000-0000-0000-0000000000c4','enregistrement interrompu')" >/dev/null
ok "après l'échec : PDF non déclaré disponible, numéro conservé" "$(q -c "select pdf_statut || '/' || numero from public.devis where id='dddddddd-0000-0000-0000-0000000000c4'")" "echec/$N"
q -c "select public.enregistrer_pdf_devis('dddddddd-0000-0000-0000-0000000000c4','dddddddd-0000-0000-0000-0000000000c4/$N.pdf',repeat('1',64),4096)" >/dev/null
ok "reprise : même fichier, même numéro, disponible" "$(q -c "select pdf_statut || '/' || numero || '/' || pdf_empreinte from public.devis where id='dddddddd-0000-0000-0000-0000000000c4'")" "disponible/$N/$(printf '1%.0s' $(seq 64))"
q -c "select public.enregistrer_pdf_devis('dddddddd-0000-0000-0000-0000000000c4','dddddddd-0000-0000-0000-0000000000c4/$N.pdf',repeat('1',64),4096)" >/dev/null 2>&1 && R=sans_erreur || R=erreur
ok "reprise répétée : acceptée sans erreur et sans changement" "$R/$(q -c "select pdf_statut || '/' || numero from public.devis where id='dddddddd-0000-0000-0000-0000000000c4'")" "sans_erreur/disponible/$N"

echo "Cas D : deux enregistrements PDF simultanés avec des empreintes différentes"
q -c "select public.emettre_devis('dddddddd-0000-0000-0000-0000000000c3','$A',essai.emetteur(),'v1')" >/dev/null
N3=$(q -c "select numero from public.devis where id='dddddddd-0000-0000-0000-0000000000c3'")
q -c "insert into storage.objects (bucket_id, name, metadata) values ('devis', 'dddddddd-0000-0000-0000-0000000000c3/$N3.pdf', '{\"size\": 10}')"
q -c "begin; select public.enregistrer_pdf_devis('dddddddd-0000-0000-0000-0000000000c3','dddddddd-0000-0000-0000-0000000000c3/$N3.pdf',repeat('2',64),10); select pg_sleep(2); commit;" >/dev/null 2>/tmp/p1 &
sleep 0.5
q -c "select public.enregistrer_pdf_devis('dddddddd-0000-0000-0000-0000000000c3','dddddddd-0000-0000-0000-0000000000c3/$N3.pdf',repeat('3',64),10);" >/dev/null 2>/tmp/p2 &
wait
ok "le second est refusé (un seul document archivé)" "$(grep -c 'PDF différent' /tmp/p2)" "1"
ok "empreinte retenue : la première" "$(q -c "select left(pdf_empreinte, 4) from public.devis where id='dddddddd-0000-0000-0000-0000000000c3'")" "2222"

echo "Cas E : deux devis du même prospect acceptés en même temps"
for d in c1 c2; do
  q -c "select public.emettre_devis('dddddddd-0000-0000-0000-0000000000$d','$A',essai.emetteur(),'v1')" >/dev/null
  q -c "insert into storage.objects (bucket_id, name, metadata) select 'devis', id || '/' || numero || '.pdf', '{\"size\": 10}' from public.devis where id='dddddddd-0000-0000-0000-0000000000$d'"
  q -c "select public.enregistrer_pdf_devis(id, id || '/' || numero || '.pdf', repeat('f',64), 10) from public.devis where id='dddddddd-0000-0000-0000-0000000000$d'" >/dev/null
  q -c "select public.declarer_envoi_devis('dddddddd-0000-0000-0000-0000000000$d','$A',now(),'email',null)" >/dev/null
done
q -c "begin; update public.devis set statut='accepte' where id='dddddddd-0000-0000-0000-0000000000c1'; select pg_sleep(2); commit;" &
sleep 0.5
q -c "begin; update public.devis set statut='accepte' where id='dddddddd-0000-0000-0000-0000000000c2'; commit;" &
wait
ok "un seul client créé" "$(q -c "select count(*) from public.clients where nom = 'Concurrence SAS'")" "1"
ok "deux projets (un par devis), même client" "$(q -c "select count(*) || '/' || count(distinct p.client_id) from public.projets p join public.devis d on d.id = p.devis_id where d.prospect_id = 'cccccccc-0000-0000-0000-0000000000c2'")" "2/1"
ok "adresse du client reprise du prospect" "$(q -c "select replace(adresse, E'\n', ' | ') from public.clients where nom = 'Concurrence SAS'")" "1 rue | 97200 Fort-de-France | MQ"

echo "Cas F : le même devis accepté deux fois en même temps"
q -c "select public.declarer_envoi_devis('dddddddd-0000-0000-0000-0000000000c4','$A',now(),'email',null)" >/dev/null
q -c "begin; update public.devis set statut='accepte' where id='dddddddd-0000-0000-0000-0000000000c4'; select pg_sleep(2); commit;" &
sleep 0.5
q -c "begin; update public.devis set statut='accepte' where id='dddddddd-0000-0000-0000-0000000000c4'; commit;" &
wait
ok "un seul projet pour ce devis" "$(q -c "select count(*) from public.projets where devis_id = 'dddddddd-0000-0000-0000-0000000000c4'")" "1"

echo "Cas G : deux avenants négatifs d'une même mission acceptés en même temps"
# Mission c4 : 1000 € HT acceptée. Deux avenants de -700 € HT chacun : chacun seul laisse 300 €,
# ensemble ils rendraient la mission négative (-400 €).
for n in 1 2; do
  AV=$(q -c "select public.creer_avenant_devis('dddddddd-0000-0000-0000-0000000000c4','$A')")
  echo "$AV" > /tmp/av$n
  q -c "insert into public.devis_lignes (devis_id, designation, quantite, prix_unitaire) values ('$AV', 'Réduction $n', -1, 700)"
  q -c "select public.emettre_devis('$AV','$A',essai.emetteur(),'v1')" >/dev/null
  q -c "insert into storage.objects (bucket_id, name, metadata) select 'devis', id || '/' || numero || '.pdf', '{\"size\": 10}' from public.devis where id='$AV'"
  q -c "select public.enregistrer_pdf_devis(id, id || '/' || numero || '.pdf', repeat('a',64), 10) from public.devis where id='$AV'" >/dev/null
  q -c "select public.declarer_envoi_devis('$AV','$A',now(),'email',null)" >/dev/null
done
AV1=$(cat /tmp/av1); AV2=$(cat /tmp/av2)
q -c "begin; select public.decider_devis('$AV1','$A','accepte'); select pg_sleep(2); commit;" >/dev/null 2>/tmp/g1 &
sleep 0.5
q -c "select public.decider_devis('$AV2','$A','accepte');" >/dev/null 2>/tmp/g2 &
wait
ok "un seul des deux avenants accepté" "$(q -c "select count(*) from public.devis where id in ('$AV1','$AV2') and statut = 'accepte'")" "1"
ok "le second refusé : la mission deviendrait négative" "$(grep -c 'deviendrait négatif' /tmp/g2)" "1"
ok "montant de la mission resté positif (1000 - 700 = 300 € HT)" "$(q -c "select d.total_ht + coalesce((select sum(a.total_ht) from public.devis a where a.avenant_du_devis_id = d.id and a.statut = 'accepte'), 0) from public.devis d where d.id = 'dddddddd-0000-0000-0000-0000000000c4'")" "300.00"
ok "toujours un seul projet pour la mission" "$(q -c "select count(*) from public.projets where devis_id = 'dddddddd-0000-0000-0000-0000000000c4'")" "1"
