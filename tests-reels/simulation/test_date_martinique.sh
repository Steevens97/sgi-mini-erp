#!/bin/bash
# Date de saisie par défaut en heure de Martinique, sur une base d'ESSAI à HORLOGE SIMULÉE (libfaketime).
# Usage : test_date_martinique.sh '<instant UTC>' '<date attendue en Martinique>'
#   ex. : test_date_martinique.sh '2026-10-25 00:30:00' 2026-10-24     (20 h 30 en Martinique)
# Lance la grappe /var/tmp/pg-faketime (port 5498) à l'instant donné, rejoue les migrations, puis l'arrête.
F=/var/tmp/pg-faketime; P=5498; R="$(cd "$(dirname "$0")/../.." && pwd)"; INSTANT="$1"; ATTENDU="$2"
q() { psql -h /var/tmp/pg-essai -p $P -U postgres -d essai -qAtX "$@"; }
ok() { if [ "$2" = "$3" ]; then echo "  [OK ] $1 ($2)"; else echo "  [ÉCHEC] $1 : obtenu « $2 », attendu « $3 »"; fi; }
su postgres -c "LD_PRELOAD=$F/libfaketime.so.1 FAKETIME='@$INSTANT' FAKETIME_DONT_FAKE_MONOTONIC=1 /usr/lib/postgresql/16/bin/pg_ctl -D $F/data -o '-p $P -k /var/tmp/pg-essai -c listen_addresses=' -l $F/log start" >/dev/null
sleep 2
echo "== Horloge : $INSTANT UTC — attendu en Martinique : $ATTENDU"
# État AVANT la migration RH : dates des 3 temps existants.
PORT_ESSAI=$P JUSQUA=20261024100000 bash "$R/tests-reels/simulation/rejouer.sh" >/dev/null 2>&1
AVANT=$(q -c "select string_agg(id || '=' || date_saisie, ',' order by id) from public.temps")
q -v ON_ERROR_STOP=1 -1 -f "$R/supabase/migrations/20261025100000_rh_projets_temps.sql" >/dev/null 2>&1 \
  && q -c "insert into supabase_migrations.schema_migrations values ('20261025100000')" || echo "  [ÉCHEC] migration RH non appliquée"
ok "date UTC de la base à cet instant" "$(q -c "select current_date")" "$(date -u -d "$INSTANT" +%F)"
ok "date du jour en Martinique" "$(q -c "select (now() at time zone 'America/Martinique')::date")" "$ATTENDU"
ok "dates des 3 temps existants inchangées par la migration" "$(q -c "select string_agg(id || '=' || date_saisie, ',' order by id) from public.temps")" "$AVANT"
PROJET=$(q -c "select id from public.projets where nom = 'Projet démo 1'")
LEA=22222222-2222-2222-2222-222222222221
R1=$(q -c "insert into public.temps (collaborateur_id, projet_id, heures) values ('$LEA', '$PROJET', 1) returning date_saisie" 2>&1)
ok "ligne SANS date (tableau de bord) : acceptée, datée du jour en Martinique" "$R1" "$ATTENDU"
R2=$(q -c "set role service_role; select public.rh_enregistrer_temps('11111111-1111-1111-1111-111111111111', null, '$LEA', '$PROJET', '$ATTENDU', 1, null, null) is not null" 2>&1 | tail -1)
ok "saisie par l'application à la date du jour en Martinique : acceptée" "$R2" "t"
DEMAIN=$(date -d "$ATTENDU + 1 day" +%F)
R3=$(q -c "set role service_role; select public.rh_enregistrer_temps('11111111-1111-1111-1111-111111111111', null, '$LEA', '$PROJET', '$DEMAIN', 1, null, 'reprise')" 2>&1 | grep -c "Date future refusée")
ok "véritable date future ($DEMAIN) refusée, même pour l'admin avec motif" "$R3" "1"
R4=$(q -c "insert into public.temps (collaborateur_id, projet_id, heures, date_saisie) values ('$LEA', '$PROJET', 1, '$DEMAIN')" 2>&1 | grep -c "Date future refusée")
ok "véritable date future refusée aussi par le tableau de bord" "$R4" "1"
su postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D $F/data stop" >/dev/null
