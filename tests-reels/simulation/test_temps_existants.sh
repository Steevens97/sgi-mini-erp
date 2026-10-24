#!/bin/bash
# Temps existants avant/après la migration RH (base d'ESSAI locale) : anciennes colonnes STRICTEMENT inchangées,
# nouveaux champs comparés à part (auteur et validation vides, un seul événement « antérieur au module RH »).
H=/var/tmp/pg-essai; P=${PORT_ESSAI:-5499}; R="$(cd "$(dirname "$0")/../.." && pwd)"
q() { psql -h $H -p $P -U postgres -d essai -qAtX "$@"; }
ok() { if [ "$2" = "$3" ]; then echo "  [OK ] $1"; else echo "  [ÉCHEC] $1 : obtenu « $2 », attendu « $3 »"; fi; }
ANCIENNES="id, collaborateur_id, projet_id, date_saisie, heures, commentaire, statut, facture_id, created_at"
# La base est recréée : PostgREST et l'application locale doivent être arrêtés (sinon la recréation échoue).
JUSQUA=20261024100000 bash "$R/tests-reels/simulation/rejouer.sh" >/dev/null 2>&1 || { echo "  [ÉCHEC] base non recréée (arrêter pile_locale.sh et le serveur local)"; exit 1; }
ok "point de départ : 7 migrations, RH absente" "$(q -c "select count(*) from supabase_migrations.schema_migrations")" "7"
AVANT=$(q -c "select string_agg(t::text, E'\n' order by id) from (select $ANCIENNES from public.temps) t")
q -v ON_ERROR_STOP=1 -1 -f "$R/supabase/migrations/20261025100000_rh_projets_temps.sql" >/dev/null 2>&1 \
  && q -c "insert into supabase_migrations.schema_migrations values ('20261025100000')" && echo "  migration RH appliquée"
APRES=$(q -c "select string_agg(t::text, E'\n' order by id) from (select $ANCIENNES from public.temps) t")
echo "Anciennes colonnes ($ANCIENNES) :"
ok "valeurs identiques, ligne par ligne, avant et après" "$( [ "$AVANT" = "$APRES" ] && echo identique || echo différent)" "identique"
ok "toujours 3 temps (2 validés, 1 soumis)" "$(q -c "select count(*) || '/' || count(*) filter (where statut='valide') || '/' || count(*) filter (where statut='soumis') from public.temps")" "3/2/1"
echo "Nouveaux champs (comparés séparément) :"
ok "auteur de la saisie : vide (inconnu, non inventé)" "$(q -c "select count(*) from public.temps where saisi_par is null and saisi_par_nom is null and saisi_le is null")" "3"
ok "validation passée : vide (aucune validation inventée)" "$(q -c "select count(*) from public.temps where valide_par is null and valide_par_nom is null and valide_le is null")" "3"
ok "motif de dérogation : vide" "$(q -c "select count(*) from public.temps where motif_derogation is null")" "3"
ok "historique : un seul événement « antérieur au module RH », sans auteur" \
  "$(q -c "select count(*) from public.temps where jsonb_array_length(historique) = 1 and historique -> 0 ->> 'action' = 'anterieur_au_module_rh' and historique -> 0 -> 'auteur' = 'null'::jsonb and historique -> 0 -> 'auteur_nom' = 'null'::jsonb")" "3"
ok "l'événement rappelle le statut d'origine" "$(q -c "select count(*) from public.temps where historique -> 0 ->> 'motif' like '%Statut d''origine : ' || statut || '.'")" "3"
echo "Détail des nouveaux champs :"
q -c "select date_saisie || ' | ' || statut || ' | saisi_par=' || coalesce(saisi_par::text, 'vide') || ' | valide_par=' || coalesce(valide_par::text, 'vide') || ' | ' || (historique -> 0 ->> 'action') from public.temps order by date_saisie"
