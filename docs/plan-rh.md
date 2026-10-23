# Module RH — plan (branche `preparation-rh-main`, issue de main ; rien de déployé)

Mis à jour le 23/10/2026 à partir de `main` (43de3ce : 7 migrations appliquées, Commercial déployé).
Première version conservée dans l'historique de la branche `preparation-rh`. Aucune migration ni écran
ne sera écrit avant l'accord de l'utilisateur sur les décisions de la section 6.

## 1. État constaté (lecture seule, 23/10/2026)

- Fiches : Dubois (Manager), Moreau et Nguyen (rattachées à un manager). Le compte `sgi@gmx.fr` (admin)
  n'est rattaché à **aucune** fiche.
- Projets : « Refonte Axians » et « Audit Bertin », en cours, **sans devis** (démonstration).
- Temps : 3 lignes de démonstration (2 validées, 1 soumise), aucune facturée.
- Règles en place : `collaborateurs` lisible par soi / manager / admin, écrite par l'admin, colonne
  `taux_horaire` retirée du droit SELECT de `authenticated` ; `projets` et `temps` « admin seulement » ;
  `clients` lecture admin/manager, écriture admin (Commercial).
- Automatisme Commercial en place : devis accepté → client si besoin → projet lié (un seul par devis,
  index `projets_un_par_devis`) → prospect gagné ; seconde acceptation sans effet ; avenant rattaché au
  projet du devis initial. **Le module RH ne crée aucun second mécanisme.**
- Relations réelles : supprimer un projet ou une fiche **efface ses temps en cascade** (ON DELETE CASCADE).
- Écran Utilisateurs actuel : un taux laissé vide devient 0 → à corriger (aucun taux attribué à la place
  de l'utilisateur).
- Inventaire terminé (diagnostic exécuté par l'utilisateur, 23/10/2026) : les 13 tables sont relevées et
  la base d'essai les reproduit exactement (voir section 8).

## 2. Plan en cinq lignes

1. Relever (lecture seule) les 4 dernières tables, aligner la base d'essai, puis écrire UNE migration RH
   compatible avec le site actuel : règles RLS de `projets` et `temps`, protections en base (pas de
   suppression d'un projet ou d'une fiche ayant des temps, pas d'auto-management ni de boucle hiérarchique,
   cycle de vie des temps, temps facturé figé, cumul journalier), autotest annulé à la fin.
2. Écrans RH : fiches (création et modification admin, manager en liste déroulante filtrée, taux
   obligatoire lu et écrit côté serveur avec la clé secrète uniquement sur l'écran d'édition admin),
   projets (liste, statut, création manuelle admin si retenue), « Mes temps », « Validation ».
3. Votre fiche personnelle et le rattachement de `sgi@gmx.fr` sans passer par une fiche de démonstration.
4. Preuves : base d'essai (rôles, fraudes de propriétaire/projet/statut, cascades, taux, sessions
   révoquées, lien Commercial), appels directs à Supabase, navigateur local puis en ligne ; non-régression
   Utilisateurs et Commercial ; comparaison complète des données avant/après.
5. Déploiement en deux temps (migration vérifiée, puis écrans), nettoyage des seuls éléments de test,
   trois vérifications manuelles dont une requête exécutée avec la vraie session d'un collaborateur.

## 3. Protections en base prévues (sans nouvelle colonne)

| Protection | Moyen |
|---|---|
| Pas son propre manager | contrainte `manager_id <> id` |
| Pas de boucle hiérarchique (A → B → A) | déclencheur qui remonte la chaîne des managers |
| Suppression d'une fiche ou d'un projet ayant des temps | déclencheur BEFORE DELETE qui refuse, même depuis le tableau de bord ou la clé secrète |
| Taux horaire | droits de colonnes inchangés ; aucune vue ni fonction appelable avec un jeton ne le renvoie (assertion) ; taux obligatoire et ≥ 0 à l'écran |
| Temps : propriétaire | `collaborateur_id = mon_collaborateur_id()` imposé par la règle, sauf exception validée (D2) |
| Temps : changement de projet, de collaborateur ou de facture | interdit après soumission ; `facture_id` posé uniquement par le futur module Finance (clé secrète) ; temps facturé non modifiable ni supprimable |
| Temps : projet | seulement un projet `en_cours` (un projet terminé ou annulé n'accepte plus de temps) |
| Auto-validation | refusée en base : le valideur n'est jamais le collaborateur du temps |
| Projets lus par un collaborateur | vue à colonnes explicites (id, nom, statut, nom du client si D1 le retient) ; aucune coordonnée client |

## 4. Projets et lien Commercial (vérifications prévues)

- Deux acceptations du même devis : un seul client, un seul projet (déjà prouvé en ligne, rejoué ici).
- Avenant : reste lié au projet du devis initial.
- Devis accepté : jamais repassé à refusé.
- Aucune action RH ne modifie `projets.devis_id`, `projets.client_id` d'un projet issu d'un devis, ni un
  document commercial.

## 5. Écrans

- RH → Collaborateurs : liste sans taux ; fiche ; « Nouvelle fiche » / « Modifier » (admin) ; taux
  uniquement sur l'écran de modification admin.
- RH → Projets : liste filtrable par statut ; changement de statut ; « Nouveau projet » (admin, si D1).
- RH → Mes temps : saisie (projet en liste déroulante limitée aux projets ouverts), soumission.
- RH → Validation (valideurs) : temps soumis, « Valider » / « Renvoyer ».

## 6. Décisions métier à prendre (propositions pour SG Ingénierie)

- **D1 — Projets sans devis et liste visible.** Proposition : création manuelle **par l'admin seulement**
  (missions internes, avant-vente, projets historiques comme les deux projets de démonstration) ; chaque
  collaborateur voit **tous les projets en cours** avec le nom du client (sans coordonnées), sans table
  d'affectation.
- **D2 — Saisie pour autrui et corrections.** Proposition : chacun saisit ses propres temps ; l'admin peut
  saisir pour un collaborateur (absence, régularisation) ; le manager ne saisit pas pour autrui. Brouillon
  : modifiable par son auteur ; soumis : le valideur peut le **renvoyer** en brouillon (correction par
  l'auteur) ; validé : seul l'admin peut le **dévalider** s'il n'est pas facturé ; facturé : figé.
- **D3 — Qui valide.** Proposition : le manager direct (`manager_id`) valide les temps de son équipe ; les
  temps d'un manager sont validés par son propre manager, à défaut par l'admin ; personne ne valide ses
  propres temps — les temps de l'admin (seul admin aujourd'hui) seraient validés par un manager désigné
  comme son manager sur sa fiche, sinon restent soumis.
- **D4 — Pas de saisie, rétroactivité, cumul.** Proposition : pas de 0,25 h ; saisie de J-31 à aujourd'hui
  (au-delà : admin) ; jamais dans le futur ; au plus 12 h par jour et par collaborateur, toutes lignes
  confondues (missions de chantier, MOEx ou drone comprises), refus au-delà avec un message en français.
- **D5 — Traçabilité et départs (nouvelles colonnes, à approuver).** Proposition : `temps.valide_par`
  (→ collaborateurs) et `temps.valide_le` (date et heure) posés par la base à la validation ;
  `collaborateurs.date_sortie` (facultative) : après cette date, plus de nouveaux temps et la fiche
  disparaît des listes de saisie, **au lieu de la supprimer**. Les projets n'ont pas besoin de champ
  d'archivage : les statuts `termine` / `annule` existants suffisent.

## 7. Tests et livraison prévus

- Base d'essai alignée sur Supabase (13 tables relevées) : rôles × actions, fraudes (changer le
  propriétaire, le projet, le statut, la facture par l'API), cascades refusées, taux illisible
  (colonne, `select=*`, filtre, tri, jointure, vue) pour tous les jetons, sessions révoquées et mot de
  passe provisoire, lien Commercial.
- `tests_verrouillage.py` étendu (projets et temps sortent des « modules fermés », Finance et Absences
  restent fermés) ; parcours Commercial rejoué (non-régression) ; écran Utilisateurs 45/45.
- Preuve « vraie session collaborateur » : une page de contrôle dans l'application exécute, avec la
  session de la personne connectée, une lecture de `taux_horaire` et affiche le refus de la base.
- Supabase : vérification d'un temps par le Table Editor (liens `collaborateur_id` et `projet_id`).

## 8. Analyse du schéma (13 tables relevées) et ajustements à approuver

Décisions D1 à D5 approuvées le 23/10/2026 avec les précisions de l'utilisateur. Cette section liste ce
que leur mise en œuvre exige. **Rien n'est encore écrit dans une migration.**

### 8.1 Ce que le diagnostic révèle

| Lien réel | Effet aujourd'hui si on supprime la ligne référencée |
|---|---|
| temps.collaborateur_id, conges.collaborateur_id, notes_de_frais.collaborateur_id → CASCADE | supprimer une fiche efface **sans message** ses temps, congés et notes de frais (démontré sur la base d'essai) |
| conges.valide_par → SET NULL | supprimer la fiche d'un manager efface **qui a validé** ses congés (démontré) |
| profiles.collaborateur_id → SET NULL | supprimer une fiche détache le compte qui y était rattaché |
| collaborateurs.manager_id → SET NULL | supprimer un manager efface la hiérarchie de son équipe |
| temps.projet_id → CASCADE | supprimer un projet efface ses temps |
| projets.devis_id, projets.client_id, prospects.client_id → SET NULL | supprimer un client ou un devis efface les liens commerciaux |
| temps.facture_id → SET NULL ; relances.facture_id → CASCADE | supprimer une facture « défacture » ses temps et efface ses relances |
| factures.client_id → RESTRICT | seul lien déjà protégé |

Aucun déclencheur préexistant sur ces tables, hormis ceux de nos migrations (profils : auto-rétrogradation,
dernier admin ; Commercial).

### 8.2 Protections proposées (déclencheurs, sans toucher aux clés étrangères existantes)

Refus de la suppression, avec un message en français, **même depuis le tableau de bord ou la clé secrète** :

- **fiche collaborateur** dès qu'elle a des temps, des congés, des notes de frais, qu'elle a validé un
  congé ou un temps, qu'un compte y est rattaché ou qu'elle manage quelqu'un → utiliser `date_sortie` ;
- **projet** dès qu'il a des temps ou qu'il est issu d'un devis (lien commercial) ;
- **client** dès qu'il est lié à un prospect, un projet ou une facture ;
- **facture** dès qu'elle porte des temps ou des relances (préparation du module Finance ; table vide).

Choix des déclencheurs plutôt que de modifier les clés étrangères : aucune contrainte existante n'est
retouchée, le message est compréhensible, et la protection couvre aussi la clé secrète.

### 8.3 Nouvelles colonnes à approuver (aucune n'est ajoutée sans accord)

| Colonne | Pourquoi |
|---|---|
| `temps.saisi_par` (identifiant du compte), `temps.saisi_par_nom`, `temps.saisi_le` | D2 : distinguer le collaborateur concerné de la personne qui a saisi (l'admin pour autrui). Identifiant du **compte** et non de la fiche, car l'admin n'a pas encore de fiche ; nom recopié car un compte révoqué est supprimé (même méthode que `devis.emis_par` / `emis_par_nom`). Posés par la base. |
| `temps.valide_par`, `temps.valide_par_nom`, `temps.valide_le` | D5 approuvé (`valide_par`, `valide_le`) ; `valide_par_nom` ajouté pour la même raison que ci-dessus. Posés par la base à la validation, effacés seulement par une réouverture tracée. |
| `temps.historique` (liste d'événements, ajout seul) | D2 : à chaque réouverture d'un temps validé, la base y recopie la validation précédente (qui, quand), le motif obligatoire et l'auteur de la réouverture ; aussi les renvois et les dérogations. Aucun événement ne peut être modifié ni effacé. *Alternative* : une table `temps_historique` (nouvelle table, à approuver) — plus classique mais plus lourde ; je recommande la colonne. |
| `temps.motif_derogation` | D4 : justification obligatoire quand l'admin dépasse 12 h dans la journée ou saisit au-delà de la fenêtre de 31 jours. |
| `collaborateurs.date_sortie` | D5 approuvé. Distincte de la révocation du compte (qui reste dans l'écran Utilisateurs). |

### 8.4 Règles de gestion retenues (paramètres, modifiables par une nouvelle migration)

Présentés à l'écran comme des **paramètres de gestion de SG Ingénierie**, sans référence au droit du travail :

- pas de saisie : 0,25 h ; heures > 0 ; une ligne ne dépasse pas 24 h ;
- fenêtre courante : de J-31 à aujourd'hui (heure de Martinique) ; jamais de date future ; au-delà de
  31 jours : admin seulement, avec motif ;
- seuil d'alerte : 12 h par jour et par collaborateur (toutes lignes) ; l'écran prévient avant
  l'enregistrement ; au-delà, seul l'admin enregistre, avec motif ;
- départ : après `date_sortie`, plus de saisie pour une journée postérieure ; une régularisation portant
  sur une journée **antérieure ou égale** à la sortie reste possible (dans la fenêtre, ou par l'admin avec
  motif) ; la fiche reste consultable, l'historique est conservé.

### 8.5 Validation (D3) et réouverture (D2)

- Le responsable hiérarchique (`manager_id`) valide les temps de son équipe ; l'admin valide ceux des
  autres ; personne ne valide ses propres temps (contrôle en base, y compris pour l'admin).
- Réouverture d'un temps validé non facturé : admin seulement, motif obligatoire ; le temps repasse en
  brouillon pour correction par son auteur, la validation précédente est conservée dans `historique`.
- Temps facturé : figé (ni modification, ni suppression, ni changement de facture, projet ou collaborateur).

**Vos propres temps quand vous travaillez seul — deux options explicites (point non bloquant) :**

1. *(recommandée)* désigner une **personne réelle** extérieure à la saisie (associé, expert-comptable,
   assistante) comme responsable sur votre fiche, avec un compte manager : elle valide vos temps ;
2. *si personne ne peut valider* : vos temps restent **« soumis »** et peuvent recevoir une
   **attestation de l'intéressé**, enregistrée dans `historique` (qui, quand, motif) et affichée partout
   comme « Attesté par l'intéressé — non validé par un tiers ». Ce n'est pas une validation : le statut
   reste « soumis », et le futur module Finance décidera, avec votre accord, s'il facture ces temps.

Aucun compte fictif, aucune exception cachée.

### 8.6 Projets (D1)

- Statuts réels : `en_cours` (ouvert à la saisie), `termine`, `annule`.
- Création manuelle : admin seulement ; client facultatif (missions internes, prospection) ; reprise
  d'historique possible (comme les deux projets de démonstration, sans devis).
- Collaborateurs : vue à colonnes explicites des projets `en_cours` (identifiant, nom, nom du client) ;
  aucune coordonnée client, aucun lien vers le devis.

### 8.7 Déjà fait sur la branche (testé localement, non déployé)

- Base d'essai : les 4 dernières tables alignées ; non-régression Commercial 134/134, concurrence 17/17,
  compatibilité Utilisateurs 17/17.
- Écran Utilisateurs : le taux n'est plus prérempli à 0 ni remplacé par 0 ; champ obligatoire ; refus
  serveur clair si vide ou à plus de 2 décimales ; 0 accepté seulement s'il est saisi
  (`tests-reels/simulation/taux_obligatoire.mjs`, 7/7 en navigateur local).
