#!/bin/bash
# Horaires des relances avec la VRAIE horloge (relances_maintenant() d'origine), sur la grappe à horloge simulée
# (libfaketime, port 5498). Rejoue toutes les migrations à cet instant (l'autotest doit passer à toute heure).
# Usage : test_relances_martinique.sh '<instant UTC>' '<blocage attendu : « due » ou début du message>'
F=/var/tmp/pg-faketime; P=5498; R="$(cd "$(dirname "$0")/../.." && pwd)"; INSTANT="$1"; ATTENDU="$2"
q() { psql -h /var/tmp/pg-essai -p $P -U postgres -d essai -qAtX "$@"; }
OKS=0; TOTAL=0
ok() { TOTAL=$((TOTAL+1)); if [ "$2" = "$3" ]; then OKS=$((OKS+1)); echo "  [OK ] $1 ($2)"; else echo "  [ÉCHEC] $1 : obtenu « $2 », attendu « $3 »"; fi; }
su postgres -c "LD_PRELOAD=$F/libfaketime.so.1 FAKETIME='@$INSTANT' FAKETIME_DONT_FAKE_MONOTONIC=1 /usr/lib/postgresql/16/bin/pg_ctl -D $F/data -o '-p $P -k /var/tmp/pg-essai -c listen_addresses=' -l $F/log start" >/dev/null
sleep 2
echo "== Horloge : $INSTANT UTC"
RES=$(PORT_ESSAI=$P bash "$R/tests-reels/simulation/rejouer.sh" | grep -E "ÉCHEC|20261029100000")
echo "$RES"
ok "migration Relances appliquée à cet instant (autotest indépendant de l'heure)" "$(echo "$RES" | grep -c '\[OK \] 20261029100000')" "1"
ok "heure de la base = instant simulé" "$(q -c "select to_char(now() at time zone 'UTC', 'YYYY-MM-DD HH24:MI')")" "$(date -u -d "$INSTANT" '+%Y-%m-%d %H:%M')"
ok "relances_maintenant() = heure réelle (définition d'origine)" "$(q -c "select public.relances_maintenant() = now()")" "t"
FACT=$(q -c "do \$\$ declare v uuid := '99999999-0000-0000-0000-000000000001'; c uuid := '99999999-0000-0000-0000-0000000000c1'; begin
  insert into public.clients (id, nom, email_contact) values (c, '[ESSAI] Client horloge', 'h@exemple.invalid');
  perform public.finance_contexte('emission', '{\"action\":\"emission\",\"test\":\"horloge\"}', v);
  insert into public.factures (id, client_id, numero, statut, essai, date_emission, date_echeance, total_ht, tva, total_ttc,
    instantane_emission, cle_emission) values (v, c, 'ESSAI-FAC-H-1', 'emise', true, current_date - 60, current_date - 20, 1, 0, 1, '{}', gen_random_uuid());
  perform public.finance_contexte('pdf', '{\"action\":\"pdf_archive\",\"test\":\"horloge\"}', v);
  update public.factures set pdf_statut = 'disponible', pdf_chemin = 'h.pdf', pdf_empreinte = repeat('a', 64), pdf_taille = 1, pdf_archive_le = now() where id = v;
  perform public.finance_fin_contexte(); end \$\$; select '99999999-0000-0000-0000-000000000001'")
SIT=$(q -c "select coalesce(case when (public.relances_situation('$FACT') ->> 'rang') is not null then 'due' end, public.relances_situation('$FACT') ->> 'blocage')")
ok "situation à cet instant (Martinique)" "${SIT:0:${#ATTENDU}}" "$ATTENDU"
ok "jour en Martinique" "$(q -c "select public.relances_jour(now())")" "$(TZ=America/Martinique date -d "$INSTANT UTC" +%F)"
su postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D $F/data -m fast stop" >/dev/null
echo "BILAN : $OKS/$TOTAL contrôles réussis"
