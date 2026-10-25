#!/bin/bash
# Opérations SIMULTANÉES sur les relances (base d'ESSAI locale, aucun envoi : les réponses du fournisseur sont simulées).
# À lancer après : tests-reels/simulation/rejouer.sh
# L'horloge des relances est fixée (lundi 2/11/2026 15 h en Martinique) le temps du script, puis rétablie et contrôlée.
H=/var/tmp/pg-essai; P=${PORT_ESSAI:-5499}
q() { psql -h $H -p $P -U postgres -d essai -qAtX "$@"; }
OKS=0; TOTAL=0
ok() { TOTAL=$((TOTAL+1)); if [ "$2" = "$3" ]; then OKS=$((OKS+1)); echo "  [OK ] $1 ($2)"; else echo "  [ÉCHEC] $1 : obtenu « $2 », attendu « $3 »"; fi; }
T=/var/tmp/pg-essai/concurrence_rel; mkdir -p $T
ADMIN=11111111-1111-1111-1111-111111111111
COMPTE=resend-essai-1   # référence NON secrète du compte fournisseur
DEF=$(q -c "select md5(prosrc) from pg_proc where proname = 'relances_maintenant'")
q <<'SQL' >/dev/null
create schema if not exists relc;
create table if not exists relc.horloge (t timestamptz);
delete from relc.horloge; insert into relc.horloge values ('2026-11-02 19:00:00+00');
grant usage on schema relc to service_role; grant select on relc.horloge to service_role;
create or replace function public.relances_maintenant() returns timestamptz language sql stable
  as $f$ select coalesce((select t from relc.horloge), now()) $f$;
create or replace function public.relances_adresse_fictive(p_adresse text) returns boolean language sql immutable as $f$ select false $f$;
insert into public.clients (id, nom, email_contact) values ('55555555-0000-0000-0000-0000000000c1', '[ESSAI] Client concurrence', 'c@exemple.invalid')
  on conflict do nothing;
create or replace function relc.facture(p_num text) returns uuid language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  perform public.finance_contexte('emission', '{"action":"emission","test":"concurrence"}', v);
  insert into public.factures (id, client_id, numero, statut, essai, date_emission, date_echeance, total_ht, tva, total_ttc,
                               instantane_emission, cle_emission)
  values (v, '55555555-0000-0000-0000-0000000000c1', p_num, 'emise', true, date '2026-09-01', date '2026-10-01', 100, 8.5, 108.5, '{}', gen_random_uuid());
  perform public.finance_contexte('pdf', '{"action":"pdf_archive","test":"concurrence"}', v);
  update public.factures set pdf_statut = 'disponible', pdf_chemin = 'c/' || p_num || '.pdf',
         pdf_empreinte = encode(sha256(convert_to(p_num, 'UTF8')), 'hex'), pdf_taille = 10, pdf_archive_le = now() where id = v;
  perform public.finance_fin_contexte();
  return v;
end $$;
create or replace function relc.req(p_id uuid, p_facture uuid) returns jsonb language sql stable as $$
  select jsonb_build_object('fournisseur', 'resend', 'version', 1, 'from', 'SG [ESSAI] <e@exemple.invalid>',
    'to', 'd@exemple.invalid', 'reply_to', null, 'subject', '[ESSAI] Facture ' || numero || ' : rappel d''échéance',
    'text', 'Bonjour, la facture ' || numero || ' reste impayée. Cordialement.',
    'piece_jointe', jsonb_build_object('nom', numero || '.pdf', 'type', 'application/pdf', 'empreinte', pdf_empreinte),
    'tags', jsonb_build_array(jsonb_build_object('name', 'relance_id', 'value', p_id::text)))
  from public.factures where id = p_facture $$;
grant usage on schema relc to service_role; grant execute on all functions in schema relc to service_role;
SQL
reserver() { # relance facture pause
  q -c "set role service_role; begin; select public.relances_reserver('$1', '$2', 1, relc.req('$1', '$2')); select pg_sleep($3); commit;" 2>&1
}

echo "Cas A : deux réservations de la même facture (identifiants différents), envoyées en même temps"
FA=$(q -c "select relc.facture('ESSAI-FAC-2026-0801')")
reserver 88888888-0000-0000-0000-0000000000a1 $FA 2 > $T/a1 &
sleep 0.5
reserver 88888888-0000-0000-0000-0000000000a2 $FA 0 > $T/a2 &
wait
ok "une seule relance réservée" "$(q -c "select count(*) from public.relances where facture_id = '$FA'")" "1"
ok "la seconde refusée avec la raison (relance réservée non résolue)" "$(grep -c 'Relance n° 1 réservée (aucun envoi confirmé)' $T/a2)" "1"

echo "Cas B : la même réservation envoyée deux fois en même temps (double clic, même identifiant)"
FB=$(q -c "select relc.facture('ESSAI-FAC-2026-0802')")
reserver 88888888-0000-0000-0000-0000000000b1 $FB 2 > $T/b1 &
sleep 0.5
reserver 88888888-0000-0000-0000-0000000000b1 $FB 0 > $T/b2 &
wait
ok "une seule relance" "$(q -c "select count(*) from public.relances where facture_id = '$FB'")" "1"
ok "le second appel renvoie la même réservation (« déjà »)" "$(grep -c '"deja": true' $T/b2)" "1"

echo "Cas C : deux exécutions prennent la même demande en même temps"
prendre() { q -c "set role service_role; begin; select public.relances_prendre('$1', '$COMPTE') ->> 'action'; select pg_sleep($2); commit;" 2>&1; }
prendre 88888888-0000-0000-0000-0000000000a1 2 > $T/c1 &
sleep 0.5
prendre 88888888-0000-0000-0000-0000000000a1 0 > $T/c2 &
wait
ok "une seule tentative enregistrée" "$(q -c "select tentatives from public.relances where id = '88888888-0000-0000-0000-0000000000a1'")" "1"
ok "la première envoie, la seconde attend (aucun double appel au fournisseur)" "$(head -1 $T/c1),$(head -1 $T/c2)" "envoyer,attendre"

echo "Cas D : résolution de l'administrateur pendant une tentative"
q -c "update relc.horloge set t = t + interval '11 minutes'"
q -c "set role service_role; begin; select public.relances_prendre('88888888-0000-0000-0000-0000000000a1', '$COMPTE') ->> 'action'; select pg_sleep(2); commit;" > $T/d1 2>&1 &
sleep 0.5
q -c "set role service_role; select public.relances_resoudre('$ADMIN', '88888888-0000-0000-0000-0000000000a1', 'aucun_envoi', 'Constat pendant l''appel', null, null)" > $T/d2 2>&1
wait
ok "la tentative a lieu" "$(head -1 $T/d1)" "envoyer"
ok "la résolution attend puis est refusée (tentative peut-être en cours)" "$(grep -c 'une tentative est peut-être en cours' $T/d2)" "1"

echo "Cas E : réponse du fournisseur et événement « email.sent » SANS étiquette reçus en même temps"
q -c "set role service_role; begin; select public.relances_resultat('88888888-0000-0000-0000-0000000000a1', 2, 'acceptee', 'em-conc', null); select pg_sleep(2); commit;" > $T/e1 2>&1 &
sleep 0.5
q -c "set role service_role; select public.relances_recevoir_evenement('evt-conc', 'email.sent', 'em-conc', null, now(), null, '$COMPTE') ->> 'resultat'" > $T/e2 2>&1
wait
ok "aucune erreur des deux côtés" "$(cat $T/e1 $T/e2 | grep -c ERROR)" "0"
ok "acceptée une fois, identifiant unique, événement enregistré, rapproché et consigné une fois" \
  "$(q -c "select statut || ',' || fournisseur_id || ',' || (select count(*) from jsonb_array_elements(historique) e where e ->> 'action' = 'acceptation') || ',' || (select count(*) from jsonb_array_elements(historique) e where e ->> 'evenement_id' = 'evt-conc') || ',' || (select statut from public.relances_evenements where evenement_id = 'evt-conc') from public.relances where id = '88888888-0000-0000-0000-0000000000a1'")" \
  "acceptee,em-conc,1,1,rapproche"

echo "Cas E2 : le même événement reçu deux fois en même temps (renvoi du fournisseur)"
q -c "set role service_role; begin; select public.relances_recevoir_evenement('evt-double', 'email.delivered', 'em-conc', null, now(), null, '$COMPTE') ->> 'resultat'; select pg_sleep(2); commit;" > $T/g1 2>&1 &
sleep 0.5
q -c "set role service_role; select public.relances_recevoir_evenement('evt-double', 'email.delivered', 'em-conc', null, now(), null, '$COMPTE') ->> 'resultat'" > $T/g2 2>&1
wait
ok "le premier rapproche, le second répond « déjà » (une seule ligne, une seule application)" \
  "$(head -1 $T/g1),$(head -1 $T/g2),$(q -c "select count(*) from public.relances_evenements where evenement_id = 'evt-double'"),$(q -c "select count(*) from public.relances r, jsonb_array_elements(r.historique) e where e ->> 'evenement_id' = 'evt-double'")" \
  "rapproche,deja,1,1"

echo "Cas E3 : classement « sans suite » pendant un rapprochement du même événement"
FG=$(q -c "select relc.facture('ESSAI-FAC-2026-0804')")
reserver 88888888-0000-0000-0000-0000000000d9 $FG 0 > /dev/null
q -c "set role service_role; select public.relances_prendre('88888888-0000-0000-0000-0000000000d9', '$COMPTE') ->> 'action'" > /dev/null
q -c "set role service_role; select public.relances_recevoir_evenement('evt-g', 'email.delivered', 'em-g', null, now(), null, '$COMPTE') ->> 'resultat'" > /dev/null
q -c "set role service_role; begin; select public.relances_resultat('88888888-0000-0000-0000-0000000000d9', 1, 'acceptee', 'em-g', null) ->> 'evenements_rapproches'; select pg_sleep(2); commit;" > $T/h1 2>&1 &
sleep 0.5
q -c "set role service_role; select public.relances_classer_evenement('$ADMIN', 'evt-g', 'Classement concurrent')" > $T/h2 2>&1
wait
ok "le classement attend le rapprochement, puis est refusé (événement déjà rapproché)" \
  "$(head -1 $T/h1),$(grep -c 'seul un événement en attente' $T/h2),$(q -c "select statut from public.relances_evenements where evenement_id = 'evt-g'")" \
  "1,1,rapproche"

echo "Cas E4 : événement SANS étiquette en cours d'enregistrement quand la réponse du fournisseur arrive"
FH=$(q -c "select relc.facture('ESSAI-FAC-2026-0805')")
reserver 88888888-0000-0000-0000-0000000000d8 $FH 0 > /dev/null
q -c "set role service_role; select public.relances_prendre('88888888-0000-0000-0000-0000000000d8', '$COMPTE') ->> 'action'" > /dev/null
q -c "set role service_role; begin; select public.relances_recevoir_evenement('evt-h', 'email.delivered', 'em-h4', null, now(), null, '$COMPTE') ->> 'resultat'; select pg_sleep(2); commit;" > $T/i1 2>&1 &
sleep 0.5
q -c "set role service_role; select public.relances_resultat('88888888-0000-0000-0000-0000000000d8', 1, 'acceptee', 'em-h4', null) ->> 'evenements_rapproches'" > $T/i2 2>&1
wait
ok "la réponse attend l'enregistrement de l'événement, puis le rapproche aussitôt" \
  "$(head -1 $T/i1),$(head -1 $T/i2),$(q -c "select statut from public.relances_evenements where evenement_id = 'evt-h'"),$(q -c "select livre_le is not null from public.relances where id = '88888888-0000-0000-0000-0000000000d8'")" \
  "en_attente,1,rapproche,t"

echo "Cas F : règlement de la facture pendant une réservation"
FF=$(q -c "select relc.facture('ESSAI-FAC-2026-0803')")
reserver 88888888-0000-0000-0000-0000000000f1 $FF 2 > $T/f1 &
sleep 0.5
q -c "do \$\$ begin
  perform public.finance_contexte('envoi', '{\"action\":\"envoi\",\"test\":\"concurrence\"}', '$FF');
  update public.factures set statut = 'envoyee', date_envoi = now() where id = '$FF';
  perform public.finance_contexte('reglement', '{\"action\":\"reglement\",\"test\":\"concurrence\"}', '$FF');
  update public.factures set statut = 'payee', date_reglement = current_date, mode_reglement = 'virement' where id = '$FF';
  perform public.finance_fin_contexte(); end \$\$" > $T/f2 2>&1
wait
ok "le règlement attend la fin de la réservation, puis passe" "$(q -c "select statut from public.factures where id = '$FF'")" "payee"
ok "la réservation faite avant le règlement est abandonnée à la prise, sans envoi" \
  "$(q -c "set role service_role; select public.relances_prendre('88888888-0000-0000-0000-0000000000f1', '$COMPTE') ->> 'statut'")" "abandonnee"

echo "Nettoyage et rétablissement"
q -c "set role service_role; select public.supprimer_essais_finance()" >/dev/null
q <<'SQL' >/dev/null
create or replace function public.relances_maintenant()
returns timestamptz
language sql
stable
as $$
  select now();
$$;
create or replace function public.relances_adresse_fictive(p_adresse text)
returns boolean
language sql
immutable
as $$
  select coalesce(lower(split_part(p_adresse, '@', 2)), '') ~
         '(^|\.)(exemple\.invalid|example\.(com|net|org)|resend\.dev)$|\.(invalid|test|example|localhost)$|^localhost$|^$';
$$;
drop schema relc cascade;
delete from public.clients where id = '55555555-0000-0000-0000-0000000000c1';
SQL
ok "heure réelle rétablie (empreinte d'origine)" "$(q -c "select md5(prosrc) from pg_proc where proname = 'relances_maintenant'")" "$DEF"
ok "aucune relance, facture d'essai ni événement restant" "$(q -c "select (select count(*) from public.relances) + (select count(*) from public.factures where essai) + (select count(*) from public.relances_evenements)")" "0"
rm -rf $T
echo "BILAN : $OKS/$TOTAL contrôles réussis"
