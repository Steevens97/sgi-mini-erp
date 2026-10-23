#!/bin/bash
# Vérifie que la migration REFUSE de se déployer si prochain_numero n'est pas transactionnel,
# même déguisé (le mot « compteurs » présent, une séquence appelée indirectement).
H=/var/tmp/pg-essai; P=5499; R="$(cd "$(dirname "$0")/../.." && pwd)"
q() { psql -h $H -p $P -U postgres -d essai -qAt "$@"; }
psql -h $H -p $P -U postgres -qAtc "drop database if exists essai" -c "create database essai" >/dev/null
for role in anon authenticated service_role supabase_auth_admin; do psql -h $H -p $P -U postgres -qAtc "drop role if exists $role" 2>/dev/null; done
q -v ON_ERROR_STOP=1 -f "$R/tests-reels/simulation/socle_simule.sql" >/dev/null
q <<'SQL'
create sequence public.piege_seq;
create or replace function public.prochain_numero(p_cle text, p_prefixe text) returns text
language plpgsql as $$
declare v bigint;
begin
  -- semble utiliser la table compteurs, mais ne le fait pas
  execute 'select next' || 'val(''public.piege_seq'')' into v;
  return p_prefixe || '-' || to_char(now(), 'YYYY') || '-' || lpad(v::text, 4, '0');
end $$;
SQL
for f in "$R"/supabase/migrations/2026102[23]*.sql; do
  q -v ON_ERROR_STOP=1 -1 -f "$f" >/dev/null 2>&1 || { echo "échec inattendu sur $f"; exit 1; }
  q -c "insert into supabase_migrations.schema_migrations values ('$(basename "$f" | cut -d_ -f1)')"
done
echo "Séquence piégée avant : $(q -c "select coalesce(last_value, 0) from pg_sequences where sequencename='piege_seq'")"
# La migration n'appelle PAS prochain_numero (l'autotest utilise le compteur d'essai) : elle ne doit
# donc faire avancer AUCUNE séquence, même si prochain_numero en utilise une en cachette.
q -v ON_ERROR_STOP=1 -1 -f "$R/supabase/migrations/20261024100000_commercial_devis.sql" >/dev/null 2>/tmp/piege.err \
  && echo "  migration appliquée (le contrôle textuel ne détecte pas le piège : seul l'examen de la définition réelle le peut)" \
  || echo "  migration refusée : $(grep -o 'Commercial :.*' /tmp/piege.err | head -1)"
A=$(q -c "select coalesce(last_value, 0) from pg_sequences where sequencename='piege_seq'")
[ "$A" = "0" ] && echo "  [OK ] séquence intacte après la migration et son autotest ($A) : prochain_numero n'a pas été appelé" \
               || echo "  [ÉCHEC] la séquence a avancé ($A) : la migration a appelé prochain_numero"
