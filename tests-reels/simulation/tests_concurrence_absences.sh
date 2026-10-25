#!/bin/bash
# Opérations SIMULTANÉES (base d'ESSAI locale) : demandes qui se chevauchent, validations, ajustement, notes de frais.
# À lancer après : rejouer.sh tests-reels/simulation/tests_absences.sql
# Option ATTENDU_SANS_VERROU=1 : démonstration sur une migration privée de son verrou de fiche (les deux passent).
H=/var/tmp/pg-essai; P=${PORT_ESSAI:-5499}
q() { psql -h $H -p $P -U postgres -d essai -qAt "$@"; }
OKS=0; TOTAL=0
ok() { TOTAL=$((TOTAL+1)); if [ "$2" = "$3" ]; then OKS=$((OKS+1)); echo "  [OK ] $1 ($2)"; else echo "  [ÉCHEC] $1 : obtenu « $2 », attendu « $3 »"; fi; }
ADMIN=11111111-1111-1111-1111-111111111111
KARIM_COMPTE=aaaaaaaa-0000-0000-0000-000000000044
HUGO_COMPTE=aaaaaaaa-0000-0000-0000-000000000045
HUGO=22222222-2222-2222-2222-2222222222c2
j() { q -c "select (now() at time zone 'America/Martinique')::date + $1"; }
T=/var/tmp/pg-essai/concurrence_abs; mkdir -p $T
# Karim devient le manager de Hugo : deux valideurs distincts (Karim, admin) peuvent agir en même temps.
q -c "update public.collaborateurs set manager_id = '22222222-2222-2222-2222-2222222222c1', date_entree = (now() at time zone 'America/Martinique')::date - 30 where id = '$HUGO'"
# Nouvelle fiche : solde à 0 « à renseigner » ; l'admin le confirme à 25 jours avant les essais de validation.
q -c "set role service_role; select public.abs_ajuster_solde('$ADMIN', '$HUGO', 'conges_payes', (select solde_conges from public.collaborateurs where id = '$HUGO'), 25, 'Essai de concurrence')" >/dev/null
demande() { # debut fin apres_midi fin_midi jours pause
  q -c "set role service_role; begin; select public.abs_demander_conge('$HUGO_COMPTE', '$HUGO', 'sans_solde', '$1', '$2', $3, $4, $5, null, null); select pg_sleep($6); commit;" 2>&1
}

echo "Cas A : deux demandes qui se chevauchent (J+200 → J+201 et J+201 → J+202), envoyées en même temps"
demande "$(j 200)" "$(j 201)" false false 2 2 > $T/a1 &
sleep 0.5
demande "$(j 201)" "$(j 202)" false false 2 0 > $T/a2 &
wait
N=$(q -c "select count(*) from public.conges where collaborateur_id = '$HUGO' and date_debut between '$(j 200)' and '$(j 202)'")
if [ "$ATTENDU_SANS_VERROU" = 1 ]; then
  ok "SANS verrou de fiche : les deux demandes passent (preuve que le verrou est nécessaire)" "$N" "2"
else
  ok "une seule demande retenue" "$N" "1"
  ok "la seconde refusée : chevauchement, message en français" "$(cat $T/a1 $T/a2 | grep -c 'Chevauchement : une demande en attente existe déjà')" "1"
fi

echo "Cas B : deux demandes identiques d'une demi-journée (J+210 après-midi), double clic"
demande "$(j 210)" "$(j 210)" true false 0.5 2 > $T/b1 &
sleep 0.5
demande "$(j 210)" "$(j 210)" true false 0.5 0 > $T/b2 &
wait
N=$(q -c "select count(*) from public.conges where collaborateur_id = '$HUGO' and date_debut = '$(j 210)'")
[ "$ATTENDU_SANS_VERROU" = 1 ] && ok "SANS verrou : doublon enregistré" "$N" "2" || ok "une seule demande retenue" "$N" "1"

if [ "$ATTENDU_SANS_VERROU" != 1 ]; then
echo "Cas C : la même demande de congés payés (2 jours) validée en même temps par Karim et par l'admin"
SOLDE0=$(q -c "select solde_conges from public.collaborateurs where id = '$HUGO'")
C=$(q -c "set role service_role; select public.abs_demander_conge('$HUGO_COMPTE', '$HUGO', 'conges_payes', '$(j 220)', '$(j 221)', false, false, 2, null, null)" | tail -1)
valider() { q -c "set role service_role; begin; select public.abs_decider_conge('$1', '$2', 'valider', null); select pg_sleep($3); commit;" 2>&1; }
valider $KARIM_COMPTE $C 2 > $T/c1 &
sleep 0.5
valider $ADMIN $C 0 > $T/c2 &
wait
ok "solde prélevé UNE fois ($SOLDE0 − 2)" "$(q -c "select solde_conges from public.collaborateurs where id = '$HUGO'")" "$(q -c "select $SOLDE0 - 2")"
ok "un seul événement de prélèvement pour cette demande" "$(q -c "select count(*) from public.collaborateurs c, jsonb_array_elements(c.historique_soldes) e where c.id = '$HUGO' and e ->> 'conge' = '$C'")" "1"
ok "le second appel renvoie « déjà décidée », sans erreur" "$(grep -c '"deja_decide": true' $T/c2)" "1"
ok "décision attribuée au premier valideur (Karim)" "$(q -c "select decide_par from public.conges where id = '$C'")" "$KARIM_COMPTE"

echo "Cas D : deux demandes distinctes (2 jours chacune) validées en même temps, solde de 3 jours"
S=$(q -c "select solde_conges from public.collaborateurs where id = '$HUGO'")
q -c "set role service_role; select public.abs_ajuster_solde('$ADMIN', '$HUGO', 'conges_payes', $S, 3, 'Essai de concurrence')" >/dev/null
D1=$(q -c "set role service_role; select public.abs_demander_conge('$HUGO_COMPTE', '$HUGO', 'conges_payes', '$(j 230)', '$(j 231)', false, false, 2, null, null)" | tail -1)
D2=$(q -c "set role service_role; select public.abs_demander_conge('$HUGO_COMPTE', '$HUGO', 'conges_payes', '$(j 240)', '$(j 241)', false, false, 2, null, null)" | tail -1)
valider $KARIM_COMPTE $D1 2 > $T/d1 &
sleep 0.5
valider $ADMIN $D2 0 > $T/d2 &
wait
ok "une seule validée, l'autre toujours demandée" "$(q -c "select string_agg(statut, ',' order by statut) from public.conges where id in ('$D1', '$D2')")" "demandee,validee"
ok "solde jamais négatif (3 − 2 = 1)" "$(q -c "select solde_conges from public.collaborateurs where id = '$HUGO'")" "1.00"
ok "refus explicite : solde insuffisant" "$(cat $T/d2 | grep -c 'Solde de congés payés insuffisant : 1 jour(s) disponible(s), 2 demandé(s)')" "1"

echo "Cas E : ajustement de l'admin pendant une validation (valeur affichée avant la validation)"
E1=$(q -c "set role service_role; select public.abs_demander_conge('$HUGO_COMPTE', '$HUGO', 'conges_payes', '$(j 250)', '$(j 250)', false, false, 1, null, null)" | tail -1)
valider $KARIM_COMPTE $E1 2 > $T/e1 &
sleep 0.5
q -c "set role service_role; select public.abs_ajuster_solde('$ADMIN', '$HUGO', 'conges_payes', 1, 10, 'Report validé')" > $T/e2 2>&1
wait
ok "ajustement sur une valeur périmée refusé (le solde est passé à 0 entre-temps)" "$(grep -c 'Le solde a changé entre-temps (0 au lieu de 1)' $T/e2)" "1"
ok "solde final cohérent avec le dernier événement de l'historique" \
  "$(q -c "select solde_conges = (e ->> 'apres')::numeric from public.collaborateurs c, lateral (select e from jsonb_array_elements(c.historique_soldes) e where e ->> 'type' = 'conges_payes' order by (e ->> 'le')::timestamptz desc limit 1) x where c.id = '$HUGO'")" "t"

echo "Cas F : la même note de frais créée deux fois en même temps (même fichier déposé)"
CHEMIN="$HUGO/$(q -c "select gen_random_uuid()").pdf"
q -c "insert into storage.objects (bucket_id, name, metadata) values ('justificatifs', '$CHEMIN', '{\"size\": 321, \"mimetype\": \"application/pdf\"}')"
creer() { q -c "set role service_role; begin; select public.abs_creer_note('$HUGO_COMPTE', '$HUGO', '$(j -1)', 15.5, 'repas', null, 'Concurrence', '$CHEMIN', 'application/pdf', 321, '$(printf '5%.0s' $(seq 64))'); select pg_sleep($1); commit;" 2>&1; }
creer 2 > $T/f1 &
sleep 0.5
creer 0 > $T/f2 &
wait
ok "une seule note" "$(q -c "select count(*) from public.notes_de_frais where justificatif_url = '$CHEMIN'")" "1"
ok "le second appel renvoie la même note (« déjà créée »), sans erreur" "$(grep -c '"deja_creee": true' $T/f2)" "1"
NOTE=$(q -c "select id from public.notes_de_frais where justificatif_url = '$CHEMIN'")

echo "Cas G : remboursement déclaré deux fois en même temps"
q -c "set role service_role; select public.abs_decider_note('$KARIM_COMPTE', '$NOTE', 'valider', null)" >/dev/null
rembourser() { q -c "set role service_role; begin; select public.abs_declarer_remboursement('$ADMIN', '$NOTE', '$(j 0)', 'VIR-CONC'); select pg_sleep($1); commit;" 2>&1; }
rembourser 2 > $T/g1 &
sleep 0.5
rembourser 0 > $T/g2 &
wait
ok "un seul événement de remboursement" "$(q -c "select count(*) from public.notes_de_frais n, jsonb_array_elements(n.historique) e where n.id = '$NOTE' and e ->> 'action' = 'remboursement_declare'")" "1"
ok "le second appel renvoie « déjà déclaré »" "$(grep -c '"deja_declare": true' $T/g2)" "1"
fi
rm -rf $T
echo "BILAN : $OKS/$TOTAL contrôles réussis"
