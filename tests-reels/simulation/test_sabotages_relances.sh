#!/bin/bash
# Sabotages volontaires de la migration Relances : chacun doit FAIRE ÉCHOUER son application (rien n'est appliqué).
# Base d'ESSAI locale seulement. Le fichier d'origine est remis en place à la fin, même en cas d'interruption.
R="$(cd "$(dirname "$0")/../.." && pwd)"; M="$R/supabase/migrations/20261029100000_relances_factures.sql"
SAUVE=$(mktemp); cp "$M" "$SAUVE"; trap 'cp "$SAUVE" "$M"; rm -f "$SAUVE"' EXIT
OKS=0; TOTAL=0
saboter() { # libellé, texte d'origine, texte saboté, extrait attendu du refus
  cp "$SAUVE" "$M"
  python3 - "$M" "$2" "$3" <<'PY' || { echo "  [ÉCHEC] $1 : texte d'origine introuvable"; TOTAL=$((TOTAL+1)); return; }
import sys
p, a, b = sys.argv[1:4]
s = open(p, encoding='utf-8').read()
if s.count(a) != 1: sys.exit(1)
open(p, 'w', encoding='utf-8').write(s.replace(a, b))
PY
  TOTAL=$((TOTAL+1))
  SORTIE=$(bash "$R/tests-reels/simulation/rejouer.sh" 2>&1)
  if echo "$SORTIE" | grep -q "\[ÉCHEC\] 20261029100000" && echo "$SORTIE" | grep -q -- "$4"; then
    OKS=$((OKS+1)); echo "  [OK ] $1 → arrêté : $(echo "$SORTIE" | grep -o 'ERROR: .*' | head -1 | cut -c1-150)"
  else
    echo "  [ÉCHEC] $1 : non arrêté ou pour une autre raison"; echo "$SORTIE" | grep -E "ÉCHEC|ERROR" | head -3
  fi
}
saboter "écart de 7 jours au lieu de 8" "'ecart_min_jours', 8," "'ecart_min_jours', 7," "écart minimal non appliqué"
saboter "relance n° 1 à J+6 au lieu de J+7" "jsonb_build_array(7, 15, 30)" "jsonb_build_array(6, 15, 30)" "seuil J+7"
saboter "limite de reprise de 24 h (sans marge)" "'limite_reprise_heures', 20," "'limite_reprise_heures', 24," "tentative mal enregistrée"
saboter "contrôle du compte fournisseur retiré" "  elsif v.tentatives > 0 and v.compte_fournisseur is distinct from p_compte then" "  elsif false then" "autre compte"
saboter "garde-fou « tentée ou acceptée aujourd'hui » retiré" "               and (r.jour_relance = v_jour or public.relances_jour(r.derniere_tentative_le) = v_jour" "               and (false and r.jour_relance = v_jour or false and public.relances_jour(r.derniere_tentative_le) = v_jour" "garde-fou quotidien"
saboter "relance non résolue non bloquante" "          or (r.statut = 'rejetee' and (r.resolu_le is null or r.resolu_le < r.rebond_le)))
   limit 1;" "          or (r.statut = 'rejetee' and (r.resolu_le is null or r.resolu_le < r.rebond_le))) and false
   limit 1;" "autotest en échec"
saboter "reprise permise hors des horaires" "  if not public.relances_horaire_ouvre(v_maintenant) then
    return jsonb_build_object('action', 'attendre', 'statut', v.statut, 'motif', 'Hors des horaires d''envoi.');" "  if false then
    return jsonb_build_object('action', 'attendre', 'statut', v.statut, 'motif', 'Hors des horaires d''envoi.');" "hors des horaires"
saboter "secret accepté dans la demande" "  if public.relances_contient_secret(p_requete::text) then
    return 'la demande contient" "  if false then
    return 'la demande contient" "premier bloc"
saboter "historique réécrit permis" "  if jsonb_array_length(new.historique) <= v_ancien
     or (v_ancien > 0" "  if false and (v_ancien > 0" "historique réécrit"
saboter "valeur constatée (date d'envoi) modifiable" "     or (old.date_envoi is not null and new.date_envoi is distinct from old.date_envoi)" "     or false" "date d'envoi modifiée"
saboter "« sent » tardif efface un rejet" "    if p_type in ('email.sent', 'email.delivered', 'email.bounced') and v.statut in ('en_cours', 'a_verifier', 'abandonnee') then" "    if p_type in ('email.sent', 'email.delivered', 'email.bounced') and v.statut in ('en_cours', 'a_verifier', 'abandonnee', 'rejetee') then" "autotest en échec"
saboter "date_envoi gardant sa valeur par défaut now()" "alter table public.relances alter column date_envoi drop default;" "" "date_envoi doit être facultative"
saboter "adresses fictives permises" "  select coalesce(lower(split_part(p_adresse, '@', 2)), '') ~" "  select false and coalesce(lower(split_part(p_adresse, '@', 2)), '') ~" "définitions d'origine non rétablies"
saboter "déclenchement ouvert à la clé secrète" "  execute 'revoke all on function public.relances_declencher() from service_role';" "  execute 'grant execute on function public.relances_declencher() to service_role';" "droits d'exécution de relances_declencher"
saboter "lecture des relances ouverte aux jetons" "revoke all on public.relances from anon, authenticated;" "revoke all on public.relances from anon, authenticated; grant select on public.relances to authenticated;" "droits sur la table relances"
saboter "fonction de service ouverte aux jetons" "    execute format('revoke all on function public.%s from public, anon, authenticated', v_fonction);
    if v_fonction not in ('relances_controle()', 'relances_declencher()') then" "    execute format('revoke all on function public.%s from public, anon', v_fonction);
    if v_fonction not in ('relances_controle()', 'relances_declencher()') then" "fonctions exécutables par un compte connecté"
saboter "déclenchement sans contrôle explicite des dépendances" "  if to_regclass('vault.decrypted_secrets') is null then
    raise exception 'Relances : Vault n''est pas installé ; déclenchement impossible.';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'net' and p.proname = 'http_post') then
    raise exception 'Relances : pg_net n''est pas installé ; déclenchement impossible.';
  end if;" "" "message inattendu sans dépendance"
saboter "version inconnue de supprimer_essais_finance écrasée" "is distinct from 'bd3538340aaedcb37811c2b975708957'" "is distinct from '00000000000000000000000000000000'" "supprimer_essais_finance absente ou différente"
saboter "demande figée modifiable" "     is distinct from
     (old.id, old.facture_id, old.rang, old.jour_relance, old.essai, old.destinataire, old.objet, old.message, old.canal," "     is distinct from
     (new.id, new.facture_id, new.rang, new.jour_relance, new.essai, new.destinataire, new.objet, new.message, new.canal," "demande figée modifiée"
saboter "événement précoce sans étiquette déclaré « inconnu » (perdu)" "      return jsonb_build_object('resultat', 'en_attente');" "      return jsonb_build_object('resultat', 'inconnu');" "événement précoce sans étiquette mal traité"
cp "$SAUVE" "$M"
bash "$R/tests-reels/simulation/rejouer.sh" >/dev/null 2>&1 && echo "  migration d'origine remise en place et appliquée"
echo "BILAN : $OKS/$TOTAL sabotages arrêtés"
