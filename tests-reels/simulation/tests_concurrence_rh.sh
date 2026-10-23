#!/bin/bash
# Saisies SIMULTANÉES d'une même personne (base d'ESSAI locale) : les plafonds de 12 h et 24 h tiennent.
# À lancer après : rejouer.sh tests-reels/simulation/tests_rh.sql
# Option ATTENDU_SANS_VERROU=1 : démonstration sur une migration privée de son verrou (les deux passent).
H=/var/tmp/pg-essai; P=${PORT_ESSAI:-5499}
q() { psql -h $H -p $P -U postgres -d essai -qAt "$@"; }
ok() { if [ "$2" = "$3" ]; then echo "  [OK ] $1 ($2)"; else echo "  [ÉCHEC] $1 : obtenu « $2 », attendu « $3 »"; fi; }
CHLOE_COMPTE=aaaaaaaa-0000-0000-0000-000000000023; CHLOE=22222222-2222-2222-2222-222222222223
ADMIN=11111111-1111-1111-1111-111111111111
PROJET=$(q -c "select id from public.projets where nom = 'Projet démo 1'")
J6=$(q -c "select (now() at time zone 'America/Martinique')::date - 6")
J7=$(q -c "select (now() at time zone 'America/Martinique')::date - 7")
saisie() { # auteur date heures motif pause
  q -c "set role service_role; begin; select public.rh_enregistrer_temps('$1', null, '$CHLOE', '$PROJET', '$2', $3, 'concurrence', $4); select pg_sleep($5); commit;" 2>&1
}

echo "Cas A : Chloé enregistre 7 h deux fois en même temps (cumul 14 h > 12 h)"
saisie $CHLOE_COMPTE $J6 7 null 2 > /tmp/rh_a1 &
sleep 0.5
saisie $CHLOE_COMPTE $J6 7 null 0 > /tmp/rh_a2 &
wait
N=$(q -c "select count(*) from public.temps where collaborateur_id = '$CHLOE' and date_saisie = '$J6'")
T=$(q -c "select coalesce(sum(heures), 0) from public.temps where collaborateur_id = '$CHLOE' and date_saisie = '$J6'")
if [ "$ATTENDU_SANS_VERROU" = 1 ]; then
  ok "SANS verrou : les deux saisies passent (preuve que le verrou est nécessaire)" "$N/$T" "2/14.00"
else
  ok "une seule saisie retenue, la seconde refusée (12 h sans dérogation)" "$N/$T" "1/7.00"
  ok "message du refus en français" "$(cat /tmp/rh_a1 /tmp/rh_a2 | grep -c '12 h')" "1"
fi

echo "Cas B : l'admin enregistre deux dérogations de 13 h en même temps (cumul 26 h > 24 h)"
saisie $ADMIN $J7 13 "'Dérogation A'" 2 > /tmp/rh_b1 &
sleep 0.5
saisie $ADMIN $J7 13 "'Dérogation B'" 0 > /tmp/rh_b2 &
wait
N=$(q -c "select count(*) from public.temps where collaborateur_id = '$CHLOE' and date_saisie = '$J7'")
T=$(q -c "select coalesce(sum(heures), 0) from public.temps where collaborateur_id = '$CHLOE' and date_saisie = '$J7'")
if [ "$ATTENDU_SANS_VERROU" = 1 ]; then
  ok "SANS verrou : 26 h enregistrées (preuve que le verrou est nécessaire)" "$N/$T" "2/26.00"
else
  ok "une seule dérogation retenue, plafond absolu de 24 h respecté" "$N/$T" "1/13.00"
  ok "message du refus : plafond absolu" "$(cat /tmp/rh_b1 /tmp/rh_b2 | grep -c 'plafond absolu')" "1"
fi
rm -f /tmp/rh_a1 /tmp/rh_a2 /tmp/rh_b1 /tmp/rh_b2
