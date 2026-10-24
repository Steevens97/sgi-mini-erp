#!/bin/bash
# Passage d'année des factures, base d'ESSAI à HORLOGE SIMULÉE (libfaketime, grappe /var/tmp/pg-faketime, port 5498).
# 01/01/2027 02:30 UTC = 31/12/2026 22:30 en Martinique : la facture doit être FAC-2026, datée du 31/12/2026.
F=/var/tmp/pg-faketime; P=5498; R="$(cd "$(dirname "$0")/../.." && pwd)"; INSTANT="${1:-2027-01-01 02:30:00}"
q() { psql -h /var/tmp/pg-essai -p $P -U postgres -d essai -qAtX "$@"; }
ok() { if [ "$2" = "$3" ]; then echo "  [OK ] $1 ($2)"; else echo "  [ÉCHEC] $1 : obtenu « $2 », attendu « $3 »"; fi; }
su postgres -c "LD_PRELOAD=$F/libfaketime.so.1 FAKETIME='@$INSTANT' FAKETIME_DONT_FAKE_MONOTONIC=1 /usr/lib/postgresql/16/bin/pg_ctl -D $F/data -o '-p $P -k /var/tmp/pg-essai -c listen_addresses=' -l $F/log start" >/dev/null
sleep 2
echo "== Horloge : $INSTANT UTC"
PORT_ESSAI=$P bash "$R/tests-reels/simulation/rejouer.sh" >/dev/null 2>&1 || echo "  [ÉCHEC] migrations non appliquées"
ADMIN=11111111-1111-1111-1111-111111111111; LEA=22222222-2222-2222-2222-222222222221
TVA='{"regime":"taxable","territoire":"MQ","taux":8.5,"criteres":{"nature_mission":"prestation_intellectuelle","statut_client":"assujetti_france"}}'
EMET='{"raison_sociale":"SIMULATION LOCALE — SANS VALEUR","forme_juridique":"SAS","capital_social":"SIMULATION","adresse":"SIMULATION","code_postal":"97200","ville":"Fort-de-France","siret":"00000000000000","immatriculation":"SIMULATION","tva_intracom":"SIMULATION"}'
COND='{"delai_paiement_jours":"30","penalites_retard":"SIMULATION","indemnite_recouvrement":"SIMULATION","escompte":"SIMULATION"}'
JOUR=$(q -c "select (now() at time zone 'America/Martinique')::date")
q -c "insert into public.collaborateurs (id, nom, prenom, taux_horaire) values ('22222222-2222-2222-2222-2222222222fb', 'Admin', 'Sgi', 0)" >/dev/null
q -c "update public.profiles set collaborateur_id = '22222222-2222-2222-2222-2222222222fb' where id = '$ADMIN'" >/dev/null
q -c "insert into public.clients (id, nom, adresse) values ('33333333-3333-3333-3333-3333333333d1', 'Client année', '1 rue')" >/dev/null
PR=$(q -c "insert into public.projets (nom, client_id) values ('Régie année', '33333333-3333-3333-3333-3333333333d1') returning id" | head -1)
q -c "select public.finance_definir_mode('$ADMIN', '$PR', 'temps_passe')" >/dev/null
q -c "select public.finance_confirmer_tarif('$ADMIN', '$PR', 50, '$JOUR'::date - 30, 'Contrat', public.finance_temps_concernes('$PR', '$JOUR'::date - 30) ->> 'empreinte')" >/dev/null
T=$(q -c "select public.rh_enregistrer_temps('$ADMIN', null, '$LEA', '$PR', '$JOUR', 2, null, null)" | head -1)
q -c "select public.rh_changer_statut_temps('$ADMIN', array['$T']::uuid[], 'soumettre', null)" >/dev/null
q -c "select public.rh_changer_statut_temps('$ADMIN', array['$T']::uuid[], 'valider', null)" >/dev/null
ok "date UTC de la base" "$(q -c "select current_date")" "2027-01-01"
ok "jour en Martinique (temps saisi ce jour-là)" "$JOUR" "2026-12-31"
E=$(q -c "select public.finance_calculer('33333333-3333-3333-3333-3333333333d1', '$JOUR', array['$PR']::uuid[], '$TVA') ->> 'empreinte'")
R1=$(q -c "set timezone = 'UTC'; select public.finance_emettre_facture('$ADMIN', 'cccccccc-0000-0000-0000-0000000000a9', '33333333-3333-3333-3333-3333333333d1', '$JOUR', array['$PR']::uuid[], '$TVA', '$E', '$EMET', '$COND', 'facture-v1') ->> 'numero'" | tail -1)
ok "numéro de l'année de la Martinique (session en UTC)" "$R1" "FAC-2026-0001"
ok "date d'émission et échéance (+30 j)" "$(q -c "select date_emission || ' / ' || date_echeance from public.factures")" "2026-12-31 / 2027-01-30"
ok "période facturée : décembre 2026" "$(q -c "select periode_debut || ' → ' || periode_fin from public.factures")" "2026-12-01 → 2026-12-31"
ok "compteur de 2026, aucun compteur 2027" "$(q -c "select string_agg(cle || '=' || valeur, ',') from public.compteurs where cle like 'facture_%'")" "facture_2026=1"
su postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D $F/data stop" >/dev/null
