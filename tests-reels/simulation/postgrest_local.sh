#!/bin/bash
# Démarre / arrête le PostgREST local de la base d'essai. Usage : postgrest_local.sh start|stop
# Binaire téléchargé hors du dépôt (dossier de travail), configuration régénérée ici.
DL=${POSTGREST_DIR:-/tmp/claude-0/-home-user/6c3954aa-6bd6-52ab-a3fd-0a4e2c7ba790/scratchpad/telechargement-postgrest}
PID=/var/tmp/pg-essai/postgrest.pid
case "$1" in
  start)
    cat > "$DL/essai.conf" <<CONF
db-uri = "postgres://authenticator@/essai?host=/var/tmp/pg-essai&port=5499"
db-schemas = "public"
db-anon-role = "anon"
jwt-secret = "secret-essai-local-uniquement-0123456789abcdef"
server-port = 3999
server-host = "127.0.0.1"
CONF
    psql -h /var/tmp/pg-essai -p 5499 -U postgres -qAtc "do \$\$ begin if not exists (select 1 from pg_roles where rolname='authenticator') then create role authenticator login noinherit; end if; end \$\$;" -c "grant anon, authenticated, service_role to authenticator"
    "$DL/postgrest" "$DL/essai.conf" > "$DL/postgrest.log" 2>&1 &
    echo $! > "$PID"
    for i in $(seq 1 30); do [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3999/commercial_devis)" = 401 ] && break; sleep 0.5; done ;;
  stop)
    [ -f "$PID" ] && kill "$(cat "$PID")" 2>/dev/null; rm -f "$PID" ;;
esac
