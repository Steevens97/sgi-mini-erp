#!/bin/bash
# Pile LOCALE de test (jamais Supabase) : PostgREST + passerelle. Usage : pile_locale.sh start|stop
R="$(cd "$(dirname "$0")/../.." && pwd)"
PID=/var/tmp/pg-essai/passerelle.pid
case "$1" in
  start)
    "$R/tests-reels/simulation/postgrest_local.sh" start
    python3 -I -u "$R/tests-reels/simulation/passerelle_supabase.py" > /var/tmp/pg-essai/passerelle.log 2>&1 &
    echo $! > "$PID"
    for i in $(seq 1 20); do [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:54321/rest/v1/commercial_devis)" = 401 ] && break; sleep 0.5; done ;;
  stop)
    [ -f "$PID" ] && kill "$(cat "$PID")" 2>/dev/null; rm -f "$PID"
    "$R/tests-reels/simulation/postgrest_local.sh" stop ;;
esac
