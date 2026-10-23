#!/bin/bash
# Recrée la base d'essai locale et rejoue toutes les migrations dans l'ordre.
# Usage : tests-reels/simulation/rejouer.sh [fichier de tests SQL...]
set -e
H=/var/tmp/pg-essai; P=5499; R="$(cd "$(dirname "$0")/../.." && pwd)"
psql -h $H -p $P -U postgres -qAtc "drop database if exists essai" -c "create database essai" >/dev/null
for role in anon authenticated service_role supabase_auth_admin; do
  psql -h $H -p $P -U postgres -qAtc "drop role if exists $role" 2>/dev/null || true
done
psql -h $H -p $P -U postgres -d essai -q -v ON_ERROR_STOP=1 -f "$R/tests-reels/simulation/socle_simule.sql" >/dev/null
for f in "$R"/supabase/migrations/*.sql; do
  v=$(basename "$f" | cut -d_ -f1)
  if psql -h $H -p $P -U postgres -d essai -q -v ON_ERROR_STOP=1 -1 -f "$f" >/dev/null 2>/tmp/err.$$; then
    psql -h $H -p $P -U postgres -d essai -qAtc "insert into supabase_migrations.schema_migrations values ('$v')"
    echo "  [OK ] $(basename "$f")"
  else
    echo "  [ÉCHEC] $(basename "$f")"; sed 's/^/        /' /tmp/err.$$; rm -f /tmp/err.$$; exit 1
  fi
done
rm -f /tmp/err.$$
for t in "$@"; do
  echo "== $(basename "$t")"
  psql -h $H -p $P -U postgres -d essai -q -v ON_ERROR_STOP=1 -f "$t"
done
