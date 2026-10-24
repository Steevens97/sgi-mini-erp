#!/bin/bash
# Émissions et changements de tarif SIMULTANÉS (base d'ESSAI locale, jamais Supabase).
# Recrée la base (rejouer.sh), prépare un client, deux projets au temps passé et des temps validés, puis :
#   A : double clic — deux émissions avec la MÊME clé → une seule facture, un seul numéro ;
#   B : deux émissions de la même sélection avec des clés différentes → une seule passe ;
#   C : changement de tarif rétroactif pendant une émission → refusé une fois l'émission validée ;
#   D : émission pendant un changement de tarif → refusée (aperçu périmé), jamais un mélange de tarifs.
H=/var/tmp/pg-essai; P=${PORT_ESSAI:-5499}; R="$(cd "$(dirname "$0")/../.." && pwd)"
q() { psql -h $H -p $P -U postgres -d essai -qAt "$@"; }
ok() { if [ "$2" = "$3" ]; then echo "  [OK ] $1 ($2)"; else echo "  [ÉCHEC] $1 : obtenu « $2 », attendu « $3 »"; fi; }
D=$(mktemp -d)
bash "$R/tests-reels/simulation/rejouer.sh" >/dev/null 2>&1 || { echo "rejouer.sh en échec"; exit 1; }
ADMIN=11111111-1111-1111-1111-111111111111; LEA=22222222-2222-2222-2222-222222222221
CLIENT=33333333-3333-3333-3333-3333333333c1
TVA='{"regime":"taxable","territoire":"MQ","taux":8.5,"criteres":{"nature_mission":"prestation_intellectuelle","statut_client":"assujetti_france"}}'
EMET='{"raison_sociale":"SIMULATION LOCALE — SANS VALEUR","forme_juridique":"SAS","capital_social":"SIMULATION","adresse":"SIMULATION","code_postal":"97200","ville":"Fort-de-France","siret":"00000000000000","immatriculation":"SIMULATION","tva_intracom":"SIMULATION"}'
COND='{"delai_paiement_jours":"30","penalites_retard":"SIMULATION","indemnite_recouvrement":"SIMULATION","escompte":"SIMULATION"}'
MOIS=$(q -c "select (date_trunc('month', (now() at time zone 'America/Martinique')::date) - interval '1 month')::date")
q -c "insert into public.collaborateurs (id, nom, prenom, taux_horaire) values ('22222222-2222-2222-2222-2222222222fb', 'Admin', 'Sgi', 0)" >/dev/null
q -c "update public.profiles set collaborateur_id = '22222222-2222-2222-2222-2222222222fb' where id = '$ADMIN'" >/dev/null
q -c "insert into public.clients (id, nom, adresse) values ('$CLIENT', 'Client concurrence', '1 rue Test')" >/dev/null
P1=$(q -c "insert into public.projets (nom, client_id) values ('Régie A', '$CLIENT') returning id" | head -1)
P2=$(q -c "insert into public.projets (nom, client_id) values ('Régie B', '$CLIENT') returning id" | head -1)
for p in $P1 $P2; do
  q -c "select public.finance_definir_mode('$ADMIN', '$p', 'temps_passe')" >/dev/null
  q -c "select public.finance_confirmer_tarif('$ADMIN', '$p', 50, '$MOIS', 'Contrat', public.finance_temps_concernes('$p', '$MOIS') ->> 'empreinte')" >/dev/null
done
temps() { q -c "select public.rh_enregistrer_temps('$ADMIN', null, '$LEA', '$1', '$2', $3, null, 'Concurrence')" | head -1; }
T1=$(temps $P1 "$(q -c "select '$MOIS'::date + 1")" 2); T2=$(temps $P1 "$(q -c "select '$MOIS'::date + 12")" 3)
T3=$(temps $P2 "$(q -c "select '$MOIS'::date + 2")" 1)
q -c "select public.rh_changer_statut_temps('$ADMIN', array['$T1','$T2','$T3']::uuid[], 'soumettre', null)" >/dev/null
q -c "select public.rh_changer_statut_temps('$ADMIN', array['$T1','$T2','$T3']::uuid[], 'valider', null)" >/dev/null
empreinte() { q -c "select public.finance_calculer('$CLIENT', '$MOIS', array[$1]::uuid[], '$TVA') ->> 'empreinte'"; }
emettre() { # clé projets empreinte pause
  q -c "set role service_role; begin; select public.finance_emettre_facture('$ADMIN', '$1', '$CLIENT', '$MOIS', array[$2]::uuid[], '$TVA', '$3', '$EMET', '$COND', 'facture-v1'); select pg_sleep($4); commit;" 2>&1
}

echo "Cas A : double clic — deux émissions simultanées avec la même clé"
E=$(empreinte "'$P1'")
emettre cccccccc-0000-0000-0000-00000000000a "'$P1'" "$E" 2 > $D/a1 &
sleep 0.5
emettre cccccccc-0000-0000-0000-00000000000a "'$P1'" "$E" 0 > $D/a2 &
wait
ok "une seule facture" "$(q -c "select count(*) from public.factures")" "1"
ok "un seul numéro consommé" "$(q -c "select valeur from public.compteurs where cle like 'facture_%'")" "1"
ok "les deux appels renvoient la même facture" "$(grep -ho '"facture_id": "[^"]*"' $D/a1 $D/a2 | sort -u | wc -l)" "1"
ok "le second appel sait qu'elle était déjà émise" "$(grep -c '"deja_emise": true' $D/a2)" "1"

echo "Cas B : même sélection, deux clés différentes, en même temps"
E=$(empreinte "'$P2'")
emettre cccccccc-0000-0000-0000-00000000000b "'$P2'" "$E" 2 > $D/b1 &
sleep 0.5
emettre cccccccc-0000-0000-0000-00000000000c "'$P2'" "$E" 0 > $D/b2 &
wait
ok "une seule facture pour ces temps" "$(q -c "select count(distinct facture_id) from public.temps where id = '$T3'")/$(q -c "select count(*) from public.factures")" "1/2"
ok "la seconde émission est refusée (plus rien à facturer)" "$(grep -c 'Aucun temps validé et non facturé' $D/b2)" "1"
ok "aucun numéro perdu (2 factures, compteur 2)" "$(q -c "select valeur from public.compteurs where cle like 'facture_%'")" "2"

echo "Cas C : tarif rétroactif demandé PENDANT une émission"
T4=$(temps $P1 "$(q -c "select '$MOIS'::date + 14")" 4)
q -c "select public.rh_changer_statut_temps('$ADMIN', array['$T4']::uuid[], 'soumettre', null)" >/dev/null
q -c "select public.rh_changer_statut_temps('$ADMIN', array['$T4']::uuid[], 'valider', null)" >/dev/null
E=$(empreinte "'$P1'"); EC=$(q -c "select public.finance_temps_concernes('$P1', '$MOIS'::date + 13) ->> 'empreinte'")
emettre cccccccc-0000-0000-0000-00000000000d "'$P1'" "$E" 2 > $D/c1 &
sleep 0.5
q -c "set role service_role; select public.finance_confirmer_tarif('$ADMIN', '$P1', 70, '$MOIS'::date + 13, 'Avenant', '$EC')" > $D/c2 2>&1 &
wait
ok "l'émission passe au tarif en vigueur (4 h × 50 €)" "$(q -c "select taux_facture || '/' || montant_facture_ht from public.temps where id = '$T4'")" "50.00/200.00"
ok "le changement de tarif, mis en attente, est ensuite refusé" "$(grep -cE 'déjà facturés|Confirmation périmée' $D/c2)" "1"
ok "aucune période à 70 € enregistrée" "$(q -c "select count(*) from public.projets p, jsonb_array_elements(p.tarif_historique) e where p.id = '$P1' and e ->> 'tarif' = '70'")" "0"

echo "Cas D : émission demandée PENDANT un changement de tarif"
T5=$(temps $P1 "$(q -c "select '$MOIS'::date + 20")" 1)
q -c "select public.rh_changer_statut_temps('$ADMIN', array['$T5']::uuid[], 'soumettre', null)" >/dev/null
q -c "select public.rh_changer_statut_temps('$ADMIN', array['$T5']::uuid[], 'valider', null)" >/dev/null
E=$(empreinte "'$P1'"); EC=$(q -c "select public.finance_temps_concernes('$P1', '$MOIS'::date + 19) ->> 'empreinte'")
q -c "set role service_role; begin; select public.finance_confirmer_tarif('$ADMIN', '$P1', 60, '$MOIS'::date + 19, 'Avenant 2', '$EC'); select pg_sleep(2); commit;" > $D/d1 2>&1 &
sleep 0.5
emettre cccccccc-0000-0000-0000-00000000000e "'$P1'" "$E" 0 > $D/d2 &
wait
ok "le nouveau tarif est enregistré" "$(q -c "select tarif_vente_ht from public.projets where id = '$P1'")" "60.00"
ok "l'émission, mise en attente, est refusée : aperçu périmé" "$(grep -c 'Aperçu périmé' $D/d2)" "1"
ok "le temps n'est pas facturé (aucun mélange de tarifs)" "$(q -c "select coalesce(facture_id::text, 'non facturé') from public.temps where id = '$T5'")" "non facturé"
E=$(empreinte "'$P1'")
emettre cccccccc-0000-0000-0000-00000000000f "'$P1'" "$E" 0 > $D/d3
ok "avec un aperçu actualisé : facturé au nouveau tarif (1 h × 60 €)" "$(q -c "select taux_facture || '/' || montant_facture_ht from public.temps where id = '$T5'")" "60.00/60.00"
ok "numérotation sans trou (FAC-…-0001 à 0004)" "$(q -c "select string_agg(right(numero, 4), ',' order by numero) from public.factures")" "0001,0002,0003,0004"
rm -rf $D
