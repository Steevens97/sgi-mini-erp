#!/bin/bash
# Dates des absences et des notes de frais en heure de Martinique, sur une base d'ESSAI à HORLOGE SIMULÉE (libfaketime).
# Usage : test_absences_martinique.sh '<instant UTC>' '<date attendue en Martinique>'
#   ex. : test_absences_martinique.sh '2027-01-01 02:30:00' 2026-12-31     (31/12 22 h 30 en Martinique)
# Lance la grappe /var/tmp/pg-faketime (port 5498) à l'instant donné, rejoue toutes les migrations, puis l'arrête.
F=/var/tmp/pg-faketime; P=5498; R="$(cd "$(dirname "$0")/../.." && pwd)"; INSTANT="$1"; ATTENDU="$2"
q() { psql -h /var/tmp/pg-essai -p $P -U postgres -d essai -qAtX "$@"; }
OKS=0; TOTAL=0
ok() { TOTAL=$((TOTAL+1)); if [ "$2" = "$3" ]; then OKS=$((OKS+1)); echo "  [OK ] $1 ($2)"; else echo "  [ÉCHEC] $1 : obtenu « $2 », attendu « $3 »"; fi; }
su postgres -c "LD_PRELOAD=$F/libfaketime.so.1 FAKETIME='@$INSTANT' FAKETIME_DONT_FAKE_MONOTONIC=1 /usr/lib/postgresql/16/bin/pg_ctl -D $F/data -o '-p $P -k /var/tmp/pg-essai -c listen_addresses=' -l $F/log start" >/dev/null
sleep 2
echo "== Horloge : $INSTANT UTC — attendu en Martinique : $ATTENDU"
PORT_ESSAI=$P bash "$R/tests-reels/simulation/rejouer.sh" | grep -E "ÉCHEC|20261028100000"
LEA=22222222-2222-2222-2222-222222222221; COMPTE=aaaaaaaa-0000-0000-0000-0000000000d1
q -c "insert into auth.users (id, email) values ('$COMPTE', 'lea-horloge@exemple.invalid')" >/dev/null
q -c "update public.profiles set collaborateur_id = '$LEA' where id = '$COMPTE'" >/dev/null
VEILLE=$(date -d "$ATTENDU - 1 day" +%F); LENDEMAIN=$(date -d "$ATTENDU + 1 day" +%F)
ok "date UTC de la base à cet instant" "$(q -c "select current_date")" "$(date -u -d "$INSTANT" +%F)"
ok "date du jour en Martinique" "$(q -c "select (now() at time zone 'America/Martinique')::date")" "$ATTENDU"
demande() { q -c "set role service_role; select public.abs_demander_conge('$COMPTE', '$LEA', 'sans_solde', '$1', '$1', $2, false, 0.5, null, null) is not null" 2>&1 | grep -E "^t$|ERROR" | head -1; }
ok "demande pour aujourd'hui (Martinique), après-midi : acceptée (pas rétroactive)" "$(demande $ATTENDU true)" "t"
ok "demande pour la veille (Martinique) : refusée, rétroactive" "$(demande $VEILLE false)" \
  "ERROR:  Une demande sur une date passée est réservée à l'administrateur (avec motif)."
note() {
  CH="$LEA/$(q -c "select gen_random_uuid()").pdf"
  q -c "insert into storage.objects (bucket_id, name, metadata) values ('justificatifs', '$CH', '{\"size\": 10, \"mimetype\": \"application/pdf\"}')" >/dev/null
  q -c "set role service_role; select public.abs_creer_note('$COMPTE', '$LEA', '$1', 5, 'repas', null, 'Horloge', '$CH', 'application/pdf', 10, repeat('a', 64)) is not null" 2>&1 | grep -E "^t$|ERROR" | head -1
}
ok "note de frais datée d'aujourd'hui (Martinique) : acceptée" "$(note $ATTENDU)" "t"
ok "note de frais datée du lendemain (Martinique) : refusée, future" "$(note $LENDEMAIN)" \
  "ERROR:  Date de la dépense refusée : elle ne peut pas être dans le futur."
su postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D $F/data -m fast stop" >/dev/null
echo "BILAN : $OKS/$TOTAL contrôles réussis"
