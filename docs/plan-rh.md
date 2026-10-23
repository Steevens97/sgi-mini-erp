# Module RH — plan (branche `preparation-rh`, rien de déployé)

Préparé le 23/10/2026. Ce document ne modifie ni la base ni le site. Il sera transformé en migration et en
écrans seulement après le déploiement réussi du module Commercial et l'accord de l'utilisateur.

## 1. Périmètre

| Partie | Contenu |
|---|---|
| Fiches collaborateurs | Liste, création et modification des fiches (admin) ; consultation (manager : toutes, collaborateur : la sienne). |
| Taux horaires | Saisie et lecture **uniquement** sur l'écran d'édition admin, côté serveur avec la clé secrète, après `exigerAdmin()`. Jamais transmis ailleurs. |
| Projets | Consultation et changement de statut (en_cours → termine / annule). **Aucune création à partir d'un devis** : c'est déjà l'automatisme du module Commercial (déclencheur `devis_apres_modification`, un seul projet par devis, index `projets_un_par_devis`). |
| Saisie des temps | Le collaborateur saisit ses heures sur un projet en cours (brouillon), les soumet ; le manager valide ou renvoie ; l'admin voit tout. |

Hors périmètre (modules suivants) : congés et soldes (Absences), notes de frais, facturation des temps
(Finance, qui posera `temps.facture_id`), relances.

## 2. Ce qui existe déjà et qu'on ne refait pas

- Projets créés automatiquement à l'acceptation d'un devis (Commercial), clients créés de même.
- Règles RLS `collaborateurs` (migration 20261023100000) : je vois ma fiche, admin et manager voient tout,
  seul l'admin écrit ; droit de colonne `taux_horaire` retiré à `authenticated`.
- Fonctions de session : `acces_actif`, `mon_role`, `mon_collaborateur_id`, `est_admin` (seules appelables
  avec un jeton). Toute nouvelle fonction : `service_role` seulement.
- `projets` et `temps` : règle « admin seulement » (migration 20261023120000), à remplacer par balayage.

## 3. Règles proposées (une migration : `AAAAMMJJHHMMSS_rh_projets_temps.sql`)

### Projets
- Lecture : admin et manager, toutes les colonnes ; collaborateur, par une vue `rh_projets` (id, nom, statut)
  limitée aux projets **en cours** — ni client, ni devis, ni montants.
- Écriture : admin et manager peuvent changer le **statut** seulement (droit de colonne). Création directe
  d'un projet : voir question Q1. Suppression : refusée s'il existe du temps saisi.
- Les colonnes `client_id` et `devis_id` d'un projet créé par le Commercial ne sont jamais modifiables.

### Temps
- Statuts : brouillon → soumis → valide ; soumis → brouillon (renvoi par le manager) ; valide = figé.
  Imposé par déclencheur (aussi depuis le tableau de bord), comme pour les devis.
- Collaborateur : crée, modifie et supprime **ses** lignes en brouillon (`collaborateur_id = mon_collaborateur_id()`,
  imposé par la base et non par l'écran), sur un projet en cours, puis les soumet.
- Manager : lit et valide les temps de **son équipe** (`collaborateurs.manager_id = mon_collaborateur_id()`),
  pas les siens (voir Q3). Admin : tout.
- Contrôles en base : heures > 0 ; somme des heures d'un collaborateur sur une journée ≤ 24 ; date de saisie
  pas dans le futur ; projet en cours au moment de la saisie ; une fois `facture_id` posé (Finance),
  plus aucune modification.
- Un compte sans fiche (`collaborateur_id` vide) ne peut rien saisir : avertissement visible à l'écran.

### Taux horaires (règle de l'utilisateur, inchangée)
- Aucune fonction SQL appelable avec un jeton ne renvoie un taux ; l'assertion de 20261023130000 reste active.
- Écran admin « Modifier la fiche » : lecture et écriture du taux par une action serveur (clé secrète)
  après `exigerAdmin()` ; le taux n'apparaît sur aucun autre écran, ni dans les listes, ni dans les temps.
- Taux 0 accepté (cas réel « pas de taux »), négatif refusé.

## 4. Écrans

- **RH → Collaborateurs** : liste (nom, poste, manager, accès) ; fiche ; « Nouvelle fiche » et « Modifier »
  (admin) ; le taux uniquement sur l'écran de modification admin.
- **RH → Projets** : liste filtrable par statut, projets d'essai marqués ESSAI ; changement de statut
  (admin, manager).
- **RH → Mes temps** : semaine en cours, saisie par projet et par jour, total, bouton « Soumettre la semaine ».
- **RH → Validation** (manager, admin) : temps soumis de l'équipe, « Valider » / « Renvoyer ».

## 5. Vérifications avant d'écrire la migration

1. Résultat de `tests-reels/diagnostic_tables.sql` (lecture seule, dans le SQL Editor) pour connaître les
   types exacts de `temps.heures`, `projets`, `collaborateurs` et leurs contraintes — le socle d'essai sera
   aligné **avant** d'écrire la moindre règle (leçon de l'incident du 23/10).
2. Module Commercial déployé (les projets d'essai `[ESSAI]` servent aux tests de saisie des temps).

## 6. Tests prévus

- Base d'essai locale (schéma aligné) : rôles × actions (collaborateur, manager d'équipe, manager hors
  équipe, admin, admin provisoire, jeton révoqué), transitions de statut, 24 h/jour, projet terminé, temps
  facturé figé, taux illisible pour tous les jetons.
- `tests_verrouillage.py` étendu : `projets` et `temps` sortent des « modules fermés », tous les autres
  contrôles conservés (sessions révoquées, mots de passe provisoires, taux, Finance/Absences fermés).
- Navigateur local puis en ligne : comptes jetables `@exemple.invalid`, projets `[ESSAI]` uniquement,
  nettoyage complet ; `instantane.py` identique avant/après.

## 7. Déploiement (même méthode que le Commercial)

1. Commit sur `main` contenant uniquement la migration RH → « Supabase Preview » vert et version présente
   dans `migrations_appliquees()`.
2. Ensuite seulement, publication des écrans.
3. Trois contrôles simples donnés à l'utilisateur.

## 8. Questions pour l'utilisateur (aucune colonne ajoutée sans accord)

- **Q1** — Projets sans devis (projets internes, avant-vente) : faut-il permettre à l'admin d'en créer à la
  main ? (Sinon, seuls les devis acceptés créent des projets.)
- **Q2** — Traçabilité de la validation : ajouter `temps.valide_par` et `temps.valide_le` (nouvelles
  colonnes, à approuver) ou s'en passer ?
- **Q3** — Le manager valide-t-il ses propres temps, ou est-ce l'admin (ou son propre manager) ?
- **Q4** — Pas de saisie : au quart d'heure (0,25 h) ou libre (2 décimales) ? Saisie possible sur combien de
  jours en arrière ?
- **Q5** — Un collaborateur doit-il voir **tous** les projets en cours, ou seulement ceux auxquels il est
  affecté ? (La seconde option demande une table ou une colonne d'affectation : à approuver.)
