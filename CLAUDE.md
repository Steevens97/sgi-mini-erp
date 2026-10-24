# Mini-ERP SGI — règles du projet (à relire à chaque demande)

L'utilisateur est en formation, **pas développeur** : chemins de clic exacts, texte exact à copier,
toutes les commandes exécutées par Claude, tout vérifié en conditions réelles (comptes jetables
créés puis supprimés), erreurs expliquées en français simple AVANT de corriger.
Avancer étape par étape et s'arrêter à la fin de chaque étape.

## Pile technique
- Next.js (App Router) + TypeScript + Tailwind + `@supabase/supabase-js` / `@supabase/ssr`.
- Tout en français : interface, noms de fichiers, de variables, de fonctions.
- Supabase : projet `cvlbyydgiyrsitxddsdv`. Dépôt GitHub : `Steevens97/sgi-mini-erp`.
- Clés dans `.env.local` (jamais commité) :
  `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`.

## Schéma — 13 tables, NE PAS MODIFIER
Ne créer aucune table, n'en renommer aucune, n'ajouter aucune colonne sans demander.

- clients (id, nom, email_contact, telephone, adresse, created_at)
- prospects (id, nom, societe, email, telephone, source, statut ∈ contacte/devis_envoye/gagne/perdu, client_id→clients, created_at)
- devis (id, prospect_id→prospects, numero, date_emission, statut ∈ brouillon/envoye/accepte/refuse, total_ht, tva, total_ttc, created_at)
- devis_lignes (id, devis_id→devis, designation, quantite, prix_unitaire, montant_ht, created_at)
- collaborateurs (id, nom, prenom, email, poste, date_entree, manager_id→collaborateurs, taux_horaire NOT NULL, solde_conges, created_at)
- projets (id, nom, client_id→clients, devis_id→devis, statut ∈ en_cours/termine/annule, created_at)
- factures (id, client_id→clients, numero, date_emission, date_echeance, periode_debut, periode_fin, total_ht, tva, total_ttc, statut ∈ brouillon/emise/envoyee/payee, date_envoi, created_at)
- temps (id, collaborateur_id→collaborateurs, projet_id→projets, date_saisie, heures, commentaire, statut ∈ brouillon/soumis/valide, facture_id→factures, created_at)
- relances (id, facture_id→factures, date_envoi, canal, message, created_at)
- conges (id, collaborateur_id→collaborateurs, type ∈ conges_payes/rtt/sans_solde, date_debut, date_fin, nb_jours, motif, statut ∈ demandee/validee/refusee, valide_par→collaborateurs, created_at)
- notes_de_frais (id, collaborateur_id→collaborateurs, date_depense, montant, categorie, justificatif_url, statut ∈ soumise/validee/remboursee, created_at)
- compteurs (cle, valeur)
- profiles (id→auth.users, email, nom, role ∈ admin/manager/collaborateur, collaborateur_id→collaborateurs, created_at)

## Déjà en place dans la base (ne pas réinventer)
- `prochain_numero(p_cle text, p_prefixe text)` → numéro sans trou type `FAC-2026-0001`.
  Les paramètres s'appellent EXACTEMENT `p_cle` et `p_prefixe` (sinon PGRST202).
  Ne jamais l'appeler pour « tester » : chaque appel consomme un numéro.
- Bucket de stockage PRIVÉ `justificatifs`.
- Déclencheur sur `auth.users` : crée une ligne `profiles` à chaque nouveau compte ; le TOUT
  PREMIER compte reçoit le rôle admin.
- Règle RLS provisoire « tout connecté lit/écrit tout » : remplacée table par table, module par module.
- Jeu de données de démonstration.
- `collaborateurs.taux_horaire` est NOT NULL : un taux « absent » n'existe pas, le cas réel est 0.
- Confirmation par email ACTIVE : créer les comptes côté serveur (clé secrète, `email_confirm: true`).

## Migrations — jamais de SQL collé à la main
- Fichiers : `supabase/migrations/AAAAMMJJHHMMSS_description.sql`.
- `supabase/config.toml` MINIMAL : `project_id` et RIEN d'autre (surtout aucune section `[auth]`,
  qui pourrait rouvrir l'inscription publique).
- Appliquées par l'intégration GitHub de Supabase à chaque push sur `main`
  (« Deploy to production », working directory `.`, pas de branches de prévisualisation).
  L'intégration ne réagit qu'aux push faits APRÈS son activation (constaté le 22/10/2026).
  Après un push : check « Supabase Preview » sur le commit GitHub (≈1 min).
- Témoin : `public.migrations_appliquees()` (clé secrète uniquement) liste les versions appliquées.
  Sans clé secrète : un appel avec la clé publique répond 42501 si la fonction existe, PGRST202 sinon.
- UNE MIGRATION S'APPLIQUE UNE SEULE FOIS : modifier un fichier déjà appliqué ne le rejoue pas →
  toujours un NOUVEAU fichier.
- Un seul fichier par module.
- Rejouable quand même : `create or replace`, `drop policy if exists`, suppression des règles par
  balayage de `pg_policies` plutôt que par nom.
- AUTO-VÉRIFIANTE PAR ASSERTION : chaque migration se termine par un bloc
  `do $$ ... raise exception ... $$` qui fait ÉCHOUER le déploiement si un contrôle ne passe pas.
- Dans un bloc plpgsql, jamais de sous-requête en argument de `raise exception` : passer par une variable.

## Sécurité
- Fonctions `mon_role()`, `mon_collaborateur_id()`, `est_admin()` : TOUJOURS `security definer`
  (+ `set search_path = public`), sinon les règles qui les appellent relisent `profiles` en boucle
  et bloquent toute l'application.
- profiles : chacun lit sa fiche, l'admin lit tout ; seul l'admin attribue les rôles.
- collaborateurs : je vois ma fiche, admin et manager voient tout ; seul l'admin crée/modifie.
- Inscription publique FERMÉE : interrupteur Supabase + page supprimée, prouvé par un essai réel.
- La vérification « admin ? » est refaite dans chaque action serveur, pas seulement à l'affichage.
- Un admin ne peut ni se rétrograder ni se révoquer lui-même.

## Verrouillage en base (migration 20261023120000) — à respecter dans chaque module
- `acces_actif()` : compte existant, non banni, `doit_changer_mot_de_passe` levé, session du jeton
  encore présente dans auth.sessions. `mon_role()`, `mon_collaborateur_id()`, `est_admin()` renvoient
  null/faux sinon. Toute nouvelle règle RLS doit passer par ces fonctions, écrites `(select public.f())`.
- Les 11 tables métier sont « admin seulement » (règle `<table>_admin_seulement`) : chaque module
  remplace cette règle par les siennes (balayage pg_policies), sans jamais revenir à `true`.
- Visiteur anonyme : aucun droit sur les 13 tables.
- `collaborateurs.taux_horaire` : droit de colonne retiré à `authenticated` → toujours lister les
  colonnes (jamais `select=*`, jamais `return=representation` sans `select=`).
- RÈGLE DE L'UTILISATEUR — taux horaires : lecture UNIQUEMENT côté serveur avec la clé secrète
  (`creerClientAdmin()`), après `exigerAdmin()` dans l'action serveur ou la page ; valeurs transmises
  seulement à l'écran d'édition admin. AUCUNE fonction SQL appelable avec un jeton utilisateur (même
  admin) ne doit renvoyer un taux (`taux_horaires_collaborateurs()` a été supprimée, migration
  20261023130000 ; une assertion échoue si une fonction mentionne taux_horaire).
- Fonctions appelables avec un jeton utilisateur : EXACTEMENT `acces_actif`, `mon_role`,
  `mon_collaborateur_id`, `est_admin` (elles ne renseignent que sur soi et appliquent le contrôle de
  session). Aucune pour anon. Toute fonction métier : `service_role` seulement, appelée par une action
  serveur après vérification des droits. L'assertion de la migration 20261023130000 l'impose : toute
  nouvelle fonction devra être ajoutée consciemment à cette liste (ou révoquée).
- `prochain_numero` : `service_role` seulement (même un admin ne peut plus consommer un numéro depuis
  le navigateur). Fonction SECURITY INVOKER (constaté : un appel non admin échouait sur la RLS de compteurs).
- Bucket `justificatifs` : admin seulement (règle `justificatifs_admin_seulement`).
- Toute règle RLS (13 tables + storage.objects) doit appeler une fonction de contrôle de session
  (`est_admin|mon_role|mon_collaborateur_id|acces_actif`) : assertion dans 20261023130000.
- Résultats vérifiés le 23/10/2026 par appels directs (`tests-reels/tests_verrouillage.py`, 135/135) :
  anonyme refusé partout (13 tables, fonctions, stockage) ; collaborateur/manager : 0 ligne sur les
  11 tables, écritures refusées ; taux illisible (colonne, select=*, filtre, tri) pour tous les jetons,
  même admin ; aucune fonction de taux ; prochain_numero refusé même à l'admin ; admin provisoire (jeton
  valide, mot de passe à changer) : tables, fonctions d'identité et stockage muets ; anciens jetons
  après révocation (admin et collaborateur), déconnexion, réinitialisation, bannissement : tables,
  fonctions d'identité et stockage muets ; données réelles identiques (instantane.py).
- Tests : `tests-reels/tests_verrouillage.py` + `instantane.py` (empreinte des données) à relancer après
  chaque module. `instantane_complet.py <après.json> <avant.json>` : comparaison sans aucune exclusion
  (13 tables en colonnes d'origine, comptes, espaces de stockage et fichiers).

## Module Commercial (migration 20261024100000) — DÉPLOYÉ (temps 1 et 2, 23/10/2026) ; émission réelle bloquée
- Ne jamais fusionner dans `main` sans l'accord explicite de l'utilisateur (fusion = déploiement).
- Incident du 23/10/2026 : 1re tentative (fusion 92ba664) refusée par l'autotest (« totaux du brouillon
  incorrects ») → rien appliqué en base ; le code était pourtant publié sur Vercel. Annulé par le commit
  29c13b6 (git revert, historique conservé ; contenu = d1876d4). Vérifié : 44/44 écran Utilisateurs,
  135/135 verrouillage, données identiques. Cause recherchée avec `tests-reels/diagnostic_totaux_devis.sql`
  (lecture seule, exécutée par l'utilisateur dans le SQL Editor ; jamais de diagnostic publié sur GitHub).
- CAUSE ÉTABLIE (diagnostic exécuté par l'utilisateur) : aucun déclencheur ni fonction préexistants sur
  devis/devis_lignes ; colonnes réelles `quantite numeric(10,2)`, `prix_unitaire|montant_ht|total_ht|tva|
  total_ttc numeric(12,2)`, `UNIQUE (numero)`, `devis.prospect_id` et `devis_lignes.devis_id` ON DELETE CASCADE.
  L'autotest saisissait 100,333 € → stocké 100,33 € → 300,99 ≠ 301,00. Reproduit à l'identique localement.
  Correction : socle simulé aligné EXACTEMENT ; autotest avec des valeurs à 2 décimales qui testent toujours
  l'arrondi (0,33 × 100,01 → 33,00), + contrôle « valeurs non modifiées à l'enregistrement », + contrôle des
  montants de ligne, + contrôle de la précision des 6 colonnes (le déploiement s'arrête si elle change).
  Prouvé : l'autotest échoue sur l'ancien socle, sur un arrondi de ligne faussé et sur une TVA tronquée.
  Application : prix/quantité à plus de 2 décimales refusés avec un message (la base arrondirait en silence).
  Autres tables relevées ensuite (`tests-reels/diagnostic_tables.sql`) : aucun déclencheur sur prospects,
  clients, projets, factures, compteurs, temps, collaborateurs ; `temps.heures numeric(5,2)`,
  `collaborateurs.taux_horaire numeric(10,2)`, `solde_conges numeric(6,2)`, `factures.* numeric(12,2)`,
  `UNIQUE (factures.numero)` ; ON DELETE : prospects.client_id, projets.client_id, projets.devis_id et
  temps.facture_id SET NULL ; temps.projet_id et temps.collaborateur_id CASCADE (supprimer un projet ou une
  fiche efface ses temps !) ; factures.client_id RESTRICT ; collaborateurs.manager_id SET NULL.
  Fonction du déclencheur de auth.users : `creer_profil_a_inscription()` (on conflict do nothing).
  Le socle simulé reprend tout cela exactement. Dernières tables relevées (`diagnostic_tables_rh.sql`) :
  conges.collaborateur_id et notes_de_frais.collaborateur_id CASCADE, conges.valide_par SET NULL,
  profiles.collaborateur_id SET NULL, profiles.id → auth.users CASCADE, relances.facture_id CASCADE ;
  conges.nb_jours numeric(5,2), notes_de_frais.montant numeric(10,2). Les 13 tables sont alignées.
- Compatibilité de l'écran Utilisateurs ACTUEL avec la migration seule : `JUSQUA=20261023130000 rejouer.sh
  tests_compat_utilisateurs.sql` puis sans JUSQUA → 17/17 dans les deux cas, résultats identiques
  (la migration ne touche ni `collaborateurs` ni `profiles`). L'écran actuel crée des fiches mais n'en
  modifie pas (édition prévue au module RH).
- Résidus d'essai : le 23/10, `ecran_utilisateurs.mjs` en ligne avait laissé 2 fiches « Jetable- » (supprimées,
  vérifiées sans lien). Corrigé : le script supprime ses comptes ET ses fiches et le vérifie ; `instantane.py`
  compte les « résidus d'essai » (exemple.invalid, [ESSAI]) au lieu de les masquer — attendu 0.
- ORDRE DE DÉPLOIEMENT : 1) commit sur `main` contenant UNIQUEMENT la migration (le code en ligne reste
  compatible) ; 2) attendre « Supabase Preview » vert ET la version dans migrations_appliquees() ;
  3) seulement ensuite publier le code qui en dépend. Comme 92ba664 a été annulé, la nouvelle tentative
  passe par de nouveaux commits (pas de nouvelle fusion de l'ancienne branche telle quelle).
- Ne jamais supprimer un déclencheur existant sur une hypothèse ; ne jamais affaiblir l'autotest des totaux.
- TEMPS 1 FAIT (accord de l'utilisateur) : commit 6f237c8 sur main = migration seule (code du site inchangé).
  Supabase Preview vert ; 20261024100000 dans migrations_appliquees() ; bucket privé `devis` (PDF, 10 Mo) ;
  tests_verrouillage.py (mode déployé) 189/189 ; ecran_utilisateurs.mjs en ligne 45/45 (dont nettoyage) ;
  site toujours en ancienne version (Commercial « Module à venir ») ; `instantane_complet.py` (rien exclu) :
  tout identique sauf le nouvel espace `devis` (vide) ; aucun compteur, aucun compte ni fichier jetable restant.
- TEMPS 2 FAIT (accord de l'utilisateur) : commit 4f7246b sur main (écrans ; migration inchangée, aucune nouvelle).
  1er passage du parcours : arrêt à l'archivage du PDF — défaut du SCRIPT (il attendait le message « PDF archivé et
  disponible », qui disparaît avec le bouton remplacé par le lien « Télécharger ») ; l'archivage avait réussi.
  Script corrigé (attente de l'état en base puis du lien) et complété ; 2e passage : 57/57 sur le site — TVA MQ
  8,5 % (400 → 34 → 434), émission ESSAI-DEV, PDF archivé par le site, téléchargé = stocké (SHA-256, taille),
  contenu du PDF vérifié, envoi déclaré, acceptation : 1 client + 1 projet, seconde acceptation idempotente (HTTP 204)
  sans doublon ni modification, accepté → refusé interdit, avenant -100 € archivé/envoyé/accepté sans nouveau
  client ni projet, avenant rendant la mission négative refusé, écrans collaborateur (consultation, pas de PDF,
  pas de coordonnées, pas d'actions), bandeau d'émission bloquée ; nettoyage complet ; tests_verrouillage 189/189 ;
  instantane_complet identique (seul ajout depuis le temps 1 : espace `devis`, vide) ; aucun compteur.
- RÉCEPTION TECHNIQUE VALIDÉE par l'utilisateur (23/10/2026), émission réelle toujours bloquée.
- POINTS À TRAITER (Commercial) :
  1. Coordonnées réelles de SG Ingénierie (COORDONNEES_SG_INGENIERIE) à fournir par l'utilisateur.
  2. Obligations d'assurance par type de mission (OBLIGATIONS_ASSURANCE, « a_confirmer ») à valider avec l'assureur.
  3. Défaut mineur, essais seulement : le client créé à l'acceptation d'un devis d'essai s'appelle
     « [ESSAI] [ESSAI] Société ». Décision de l'utilisateur : AUCUNE migration pour ce seul défaut ; à corriger
     plus tard, dans une migration qui aura d'autres raisons d'exister.

### Arbitrages DÉFINITIFS de l'utilisateur (23/10/2026) — ne plus les redemander
- `devis.type_mission` approuvé (conseil, amo, moex, opc, donnees, drone, autre).
- TVA : Martinique 8,5 % par défaut ; France métropolitaine et autres pays de l'UE gérés.
- `devis.tva` = MONTANT de TVA en euros (pas un taux ; le taux est dans `taux_tva`).
- Un devis accepté ne passe jamais à « refusé » (ni à « remplacé ») : on fait un avenant.
- Évolutions A–F approuvées, numérotation à l'émission ; colonnes d'adresse du prospect approuvées.
- Données de démonstration (dont Cabinet Fabre) : inchangées.

### Numérotation (définition réelle de `prochain_numero` examinée le 23/10/2026)
- `prochain_numero(p_cle, p_prefixe)` : SECURITY INVOKER, clé = `p_cle || '_' || AAAA` (année de
  `current_date`), `insert … on conflict do nothing` puis `update … returning` → transactionnelle
  (annulation = numéro rendu ; appels simultanés sérialisés). Format `PREFIXE-AAAA-NNNN` (`lpad` 4).
- La migration vérifie l'EMPREINTE de cette définition (md5 du texte normalisé) et ÉCHOUE si elle a changé.
- Ne jamais appeler `prochain_numero` directement : passer par `attribuer_numero(p_cle, p_prefixe)`
  (service_role seulement), qui : n'accepte que les clés prévues (`devis`, `essai_devis` ; ajouter
  `facture` au module Finance) ; fixe `timezone = America/Martinique` pour la SEULE durée de l'appel
  (la session n'est pas modifiée ; prouvé avec libfaketime : 2026-12-31 22:30 en Martinique → DEV-2026) ;
  bloque AVANT dépassement : à 9 999, refus avec « Numérotation impossible : la limite de 9 999
  documents « DEV » pour l'année AAAA est atteinte… » (sinon `lpad` tronquerait → doublons).
  Même limite pour les futures factures.
- Devis réel : `attribuer_numero('devis','DEV')` → DEV-AAAA-NNNN. Devis d'essai :
  `attribuer_numero('essai_devis','ESSAI-DEV')` → compteur `essai_devis_AAAA`, jamais le compteur réel.
- Numérotation sans trou garantie SEULEMENT si : numéro attribué dans la transaction d'émission
  (déclencheur), un devis émis ne se supprime pas, et personne n'appelle `prochain_numero` hors de ces
  opérations (la clé secrète le pourrait : ne jamais le faire, même pour tester).

### Règles
- Statuts du devis : brouillon → emis → envoye → accepte | refuse ; emis|envoye → remplace (à l'émission
  de la nouvelle version) ; un devis accepté ne se remplace pas : avenant. Tout est imposé par
  déclencheurs (aussi depuis le tableau de bord). Numéro, statut, totaux, instantané : écrits par la base.
- Essais : indicateur `essai` (prospects, devis) posé uniquement par `creer_prospect_essai` (clé secrète),
  non modifiable ; l'email ne joue aucun rôle. Clients/projets d'essai préfixés [ESSAI], PDF « ESSAI — SANS VALEUR ».
  Un devis d'essai n'est modifiable qu'avec la clé secrète (à l'écran : lecture seule, sauf « Régénérer le PDF »).
- Nettoyage : `supprimer_essais_commercial()` (clé secrète) supprime prospects, devis (tous statuts), lignes,
  projets et clients d'ESSAI et le compteur essai_devis ; refuse tout si une donnée réelle y est rattachée
  (temps saisi, facture, devis réel lié…) ; renvoie `pdf_chemins` à supprimer du bucket `devis`.
  Seule exception à « un devis émis ne se supprime pas » : devis d'essai, clé secrète.
- Destinataire : `prospects.adresse, code_postal, ville, pays` obligatoires à l'émission, figés dans
  `instantane_emission`.
- Émetteur : `src/lib/entreprise.ts` (COORDONNEES_SG_INGENIERIE, VIDES tant que l'utilisateur ne les a pas
  fournies) ; `controle_emetteur` bloque en base ; coordonnées [DÉMO] interdites sur un devis réel ;
  coordonnées « SIMULATION LOCALE » seulement si l'URL Supabase est 127.0.0.1 et SIMULATION_LOCALE=1.
- Assurance exigée selon OBLIGATIONS_ASSURANCE (à fournir par l'utilisateur/l'assureur ; « a_confirmer »
  bloque l'émission) ; MOEx = décennale obligatoire, imposée en base. Aucune couverture inventée.
  À l'écran (formulaire et fiche devis) : « Assurance : couverture à vérifier selon la mission et le contrat. »
  (MENTION_ASSURANCE) — l'étiquette de mission n'est jamais présentée comme une validation.
- TVA : 6 champs (devis, factures), `controle_traitement_tva` par déclencheur ; proposition affichée,
  jamais appliquée seule ; taux réduit/personnalisé = justification ; mentions sourcées seulement
  (« Autoliquidation », « TVA non applicable – art. 294 du CGI »), le reste saisi par l'utilisateur.
- Avenants : lignes négatives permises ; cumul mission (initial + avenants acceptés) >= 0, vérifié à
  l'émission et à l'acceptation APRÈS verrou du devis initial (prouvé : sans verrou, -400 €).
- PDF : pdf-lib, gabarit `devis-v1` jamais modifié ; généré depuis l'instantané ; archivé une fois dans le
  bucket privé `devis` (clé secrète) ; le fichier stocké fait foi (reprise, concurrence) ; téléchargement
  vérifié par SHA-256 ; brouillon généré à la volée, jamais stocké. Le collaborateur n'a pas accès aux PDF.
- Droits : admin/manager sur prospects, devis, lignes (droits de colonnes) ; clients lecture admin/manager,
  écriture admin ; collaborateur via vues `commercial_prospects|devis|devis_lignes` (colonnes explicites).

### Tests (base d'ESSAI locale, jamais Supabase) — résultats du 23/10/2026
- `tests-reels/simulation/rejouer.sh tests-reels/simulation/tests_commercial.sql` puis
  `select count(*) filter (where ok), count(*) from essai.resultats` : 134/134 (socle aligné sur Supabase).
- `tests_concurrence.sh` : 17/17. `test_numerotation_piegee.sh` : refus par empreinte, rien appliqué.
- Passage d'année : 2e grappe libfaketime `/var/tmp/pg-faketime` (port 5498),
  `PORT_ESSAI=5498 rejouer.sh test_passage_annee.sql`.
- `postgrest_local.sh start` + `python3 -I tests_vues_api.py` : 30/30 (puis `postgrest_local.sh stop`).
- `node --experimental-strip-types tests-reels/tests_pdf_archivage.mts` : 14/14.
- Navigateur : `pile_locale.sh start`, build avec l'URL 127.0.0.1:54321, `navigateur_commercial.mjs`
  (modes simulation 26/26, limite 2/2, reel 4/4 — le mode reel exige un brouillon réel « conseil »).
- Production (après déploiement) : `tests_verrouillage.py` détecte le module (migrations_appliquees) et
  vérifie les droits Commercial en plus des contrôles d'origine ; `parcours_essai_commercial.mjs <url>`
  (Playwright, depuis scratchpad/essais) : parcours complet avec données d'essai, nettoyage intégré.

## Pièges
- Compte sans `collaborateur_id` = ne voit rien, sans erreur → afficher un avertissement VISIBLE.
- `SUPABASE_SERVICE_ROLE_KEY` est SECRÈTE : jamais de préfixe `NEXT_PUBLIC_`, jamais commitée,
  utilisée seulement dans du code serveur (`import "server-only"`).
- Un fichier `"use server"` n'exporte QUE des fonctions asynchrones ; les constantes partagées vont
  dans un fichier ordinaire.
- Ne jamais lancer `npm run build` pendant que `npm run dev` tourne.

## Application
- Connexion, déconnexion. Toutes les pages sauf la connexion sont protégées (redirection).
- Menu latéral dans cet ordre : Accueil, Commercial, RH, Finance, Absences, Utilisateurs.
  Finance et Utilisateurs visibles par l'admin seulement. Email + rôle affichés en bas du menu.
- Écran Utilisateurs (admin) : liste des collaborateurs + état de l'accès ; « Créer l'accès »
  (email de la fiche, rattachement, rôle, mot de passe provisoire affiché UNE fois) ; changer un
  rôle ; réinitialiser un mot de passe ; révoquer sans supprimer la fiche ; rattacher un compte
  existant à une fiche.

## État d'avancement (à tenir à jour)
- Étape 1 FAITE : outillage, migrations 20261022120000 (vérif. socle) et 20261022130000 (témoin) appliquées.
- Étape 2 FAITE : squelette Next.js 16.4 (cacheComponents désactivé), /connexion, proxy.ts de
  redirection, menu, bandeaux « profil illisible » / « non rattaché ». Testé : redirections + mauvais
  identifiants. PAS encore testé connecté (le 1er compte créé devient admin : ne pas créer de compte
  jetable avant celui de l'utilisateur).
- Étape 3 FAITE : compte admin de l'utilisateur créé (sgi@gmx.fr) via /inscription à usage unique,
  page supprimée ensuite ; inscription publique coupée dans Supabase (disable_signup = true).
  Contrôle à refaire si besoin : GET /auth/v1/settings → disable_signup, et un vrai POST /auth/v1/signup refusé.
  Site en ligne sur Vercel (variables d'environnement saisies dans Vercel).
- Étape 4 FAITE : migration 20261023100000 (mon_role, mon_collaborateur_id, est_admin en SECURITY
  DEFINER ; RLS profiles/collaborateurs ; trigger anti-auto-rétrogradation). 42/42 contrôles API +
  test navigateur sur https://sgi-mini-erp.vercel.app (anonyme, collaborateur, orphelin, manager, admin).
  Comptes jetables : domaine @exemple.invalid, supprimés après tests ; ne jamais toucher sgi@gmx.fr.
- Étape 5 FAITE (code) : migration 20261023110000 (trigger « dernier admin » sur profiles, update et delete) ;
  écran /utilisateurs (exigerAdmin dans chaque action, refus sur soi, sur COMPTES_PROTEGES = sgi@gmx.fr,
  et sur le dernier admin) ; mot de passe provisoire affiché une fois, jamais journalisé ;
  changement obligatoire via app_metadata.doit_changer_mot_de_passe (proxy + /changer-mot-de-passe) ;
  révocation = suppression du compte auth (profil supprimé en cascade, fiche conservée).
  Tests : 44/44 écran (local + en ligne), 42/42 RLS. Reste : l'utilisateur crée sa fiche, puis un manager
  et un collaborateur, et se reconnecte en collaborateur.

- Module Commercial : DÉPLOYÉ (23/10/2026), émission réelle bloquée (coordonnées et assurances à fournir) — voir la section dédiée.
- Module RH : DÉPLOYÉ (temps 1 et 2, 24/10/2026) ; correctif du message de suppression de fiche DÉPLOYÉ
  (migration 20261026100000, commit 2a566fa sur main) — voir la section « Module RH ».
  Fiche réelle de l'utilisateur : attend ses informations et son taux confirmé.
- Module Finance : DÉPLOYÉ (temps 1 et 2, 24/10/2026) ; émission réelle bloquée (coordonnées et conditions de paiement
  à confirmer ; facturation électronique : documentation provisoire). Absences et relances : pas commencés (accord requis).

## Module RH (migration 20261025100000) — DÉPLOYÉ (temps 1 et 2, 24/10/2026)
- RÉCEPTION TECHNIQUE VALIDÉE par l'utilisateur (24/10/2026) : module RH et correctif 20261026100000.
- TEMPS 1 FAIT (accord de l'utilisateur, 24/10/2026) : commit 312b7e1 sur main (remplace 402a4ef ; migration
  seule, date par défaut en Martinique incluse ; code du site inchangé). Supabase Preview vert ; 8 migrations ;
  colonnes, défaut, vue et paramètres présents ; `verifier_temps_existants.py` 10/10 (anciennes colonnes
  identiques, nouveaux champs vides + 1 événement) ; `tests_verrouillage.py` (mode RH) 204/204 ;
  `ecran_utilisateurs.mjs` en ligne 45/45 ; `instantane_complet.py` identique ; 0 résidu ; site : ancien écran
  RH, /rh/temps introuvable (écrans non publiés), Commercial en place.
- TEMPS 2 FAIT (accord de l'utilisateur, 24/10/2026) : commit 127b824 sur main (écrans ; code = version testée,
  migration 20261025100000 inchangée, empreinte vérifiée). Vercel et Supabase Preview verts. Parcours en ligne
  `tests-reels/parcours_rh_en_ligne.mjs <url>` (comptes et fiches jetables, temps sur projet [ESSAI] issu d'un devis
  d'essai) : 49/49 ; Commercial en ligne 57/57 ; tests_verrouillage 204/204 ; instantane_complet identique ;
  verifier_temps_existants 10/10 (anciennes colonnes préservées ; nouveaux champs = état après migration) ; 0 résidu.
  Nettoyage : supprimer_essais_rh → comptes → fiches → projet manuel → supprimer_essais_commercial → PDF.
- DÉFAUT trouvé au temps 2 : supprimer une fiche qui porte des pièces est bien REFUSÉ, mais le message est
  technique (« malformed array literal ») : `tableau || 'texte'` dans collaborateurs_avant_suppression().
  Aucun écran ne supprime de fiche (seuls le tableau de bord et la clé secrète sont concernés). Mes tests
  passaient à tort (recherche de « des temps » dans le message) : tests_rh.sql et le parcours en ligne vérifient
  désormais le message EXACT. Correctif DÉPLOYÉ (accord de l'utilisateur, 24/10/2026) : commit 2a566fa
  sur main = migration 20261026100000 SEULE (array_append ; autotest des messages exacts ; 4 sabotages sur 4 arrêtés).
  À la vérification du diff, la ligne `revoke` sur la fonction de déclencheur a été RETIRÉE (choix de l'utilisateur :
  aucun changement de droits) ; contrôlé en local : tables, colonnes, droits, règles, déclencheurs identiques.
  Après application (9 migrations) : message exact en production (« … porte des temps, un compte rattaché. … » et
  « … porte une équipe (manager). … »), fiches conservées ; parcours RH en ligne 50/50 (48 contrôles d'origine
  + contrôle de suppression resserré au message exact + nouveau contrôle « fiche refusée toujours présente ») ;
  tests_verrouillage 204/204 ; instantane_complet identique ; verifier_temps_existants 10/10 ; 0 résidu.
  Tests et CLAUDE.md publiés ensuite sur main (documentation et scripts de test seulement, accord de l'utilisateur).
- Décisions de l'utilisateur (23/10/2026, ne plus les redemander) : D1 projets sans devis créés par l'admin,
  projets `en_cours` visibles de tous (nom du client seulement) ; D2 chacun saisit ses temps, l'admin peut
  saisir pour autrui (auteur ≠ collaborateur, tracés), réouverture d'un temps validé = admin + motif, trace de
  la validation précédente ; D3 responsable hiérarchique (manager_id) valide son équipe, admin valide les autres,
  PERSONNE ne valide ses propres temps ; temps de l'admin seul : restent « soumis », attestation de l'intéressé
  = information distincte, facturabilité décidée au module Finance ; D4 pas de 0,25 h, fenêtre J-31 (au-delà :
  admin + motif), jamais de date future, > 12 h/jour = dérogation admin motivée, > 24 h/jour = refus absolu
  (paramètres de gestion, pas le droit du travail) ; D5 valide_par/valide_le/date_sortie ; régularisation après
  départ pour les journées antérieures ; date de sortie ≠ révocation du compte.
- Colonnes ajoutées (approuvées) : temps.saisi_par, saisi_par_nom, saisi_le, valide_par, valide_par_nom,
  valide_le, motif_derogation, historique (jsonb, ajout seul) ; collaborateurs.date_sortie. Identifiants de
  COMPTE sans clé étrangère + nom recopié : la révocation d'un compte n'efface ni les temps ni leur historique.
- Temps existants : auteur et validation laissés VIDES (inconnus) ; un événement « anterieur_au_module_rh »
  documente leur provenance. Rien d'inventé.
- Écriture des temps : UNIQUEMENT par les fonctions de service (clé secrète) `rh_enregistrer_temps`,
  `rh_supprimer_temps`, `rh_changer_statut_temps` (soumettre, retirer, renvoyer, valider, rouvrir, attester),
  appelées par les actions serveur après vérification ; elles posent un contexte d'auteur local à la transaction
  (sgi.rh_auteur/action/motif), invisible des jetons. Les jetons ne font que LIRE (temps : les siens ;
  admin/manager : tous). Le déclencheur `temps_controle` impose toutes les règles quel que soit le chemin
  (tableau de bord compris) : historique jamais écrit directement, statut seulement via l'application,
  cumul verrouillé par fiche (saisies simultanées prouvées), temps facturé figé, suppression seulement d'un
  brouillon jamais validé.
- Protections (déclencheurs, aucune clé étrangère modifiée) : fiche non supprimable si temps, congés, notes de
  frais, congé validé, compte rattaché ou équipe ; projet non supprimable si temps ou issu d'un devis (sauf essais,
  clé secrète) ; client non supprimable si lié ; AUCUNE facture supprimable (règle à garder au module Finance).
  Pas son propre manager, pas de boucle, manager sorti refusé, taux ≥ 0, date de sortie ≥ entrée et ≥ dernier temps.
- Projets : un projet lié à un devis naît seulement de l'acceptation (automatisme Commercial réutilisé, aucun
  second mécanisme) ; devis et client d'un tel projet figés ; manager : statut seulement ; vue
  `rh_projets_ouverts` (id, nom, statut, client_nom) pour la saisie.
- Nettoyage des essais RH : `supprimer_essais_rh()` (temps sur projets d'ESSAI), à appeler AVANT
  `supprimer_essais_commercial()`.
- Écran Utilisateurs (sur la branche) : taux obligatoire, ni prérempli ni remplacé par 0.
- Écrans (src/app/(protege)/rh) : accueil RH ; Collaborateurs (liste sans taux ; création/modification admin,
  manager choisi parmi les éligibles — ni soi, ni ses subordonnés, ni une personne sortie ; taux lu avec la clé
  secrète uniquement sur l'écran de modification admin) ; Projets (admin : création sans devis, nom/client des
  projets manuels ; MANAGER : statut seulement, la base l'impose ; collaborateur : vue des projets ouverts) ;
  Mes temps (sa fiche seulement, projets ouverts, dates bornées, pas de 0,25 h, alerte > 12 h avant envoi,
  admin : « Saisir pour » + motif de dérogation ; « Saisi par » distinct du propriétaire) ; Validation
  (manager : équipe directe ; admin : les autres ; renvoi et réouverture motivés ; jamais ses propres temps).
  Une saisie refusée est conservée à l'écran (React vide sinon les champs après chaque envoi) — LIMITE : les
  formulaires Utilisateurs et Commercial existants n'ont pas encore ce comportement.
- Date de saisie par défaut (approuvé le 24/10/2026) : la migration remplace le défaut `current_date` (heure
  universelle) de `temps.date_saisie` par `(now() at time zone 'America/Martinique')::date` ; aucune date
  existante modifiée ; assertion dans la migration. Testé à horloge simulée (`test_date_martinique.sh`) :
  24/10 20 h 30, 31/12 22 h 30 et 01/01 0 h 30 en Martinique — ligne sans date datée du jour en Martinique,
  vraie date future refusée (application et tableau de bord), dates existantes inchangées (21/21).
- Tests locaux (24/10/2026, base alignée sur les 13 tables réelles) : `rejouer.sh tests_rh.sql` puis
  `select count(*) filter (where ok), count(*) from rhe.resultats` : 153/153 ; `tests_concurrence_rh.sh` 5/5
  (créations, dérogations et CORRECTIONS simultanées ; preuve sans verrou : 14 h, 26 h et 14 h passeraient) ;
  `tests_rh_api.py` 28/28 ; `test_temps_existants.sh` 8/8 (anciennes colonnes identiques, nouveaux champs vides
  + 1 événement) ; navigateur `navigateur_rh.mjs` 49/49 (admin, collaboratrice, manager, manager hors équipe ;
  taux absent des pages reçues) ; autotest de la migration :
  6 sabotages sur 8 détectés par l'autotest, les 2 autres arrêtés par une seconde protection ;
  non-régression : Commercial 135/135, 17/17, 30/30, PDF 14/14, passage d'année, compatibilité Utilisateurs
  17/17 avec et sans la migration RH, navigateur Commercial 26/26 et 4/4, taux obligatoire 7/7.
  Production : `verifier_temps_existants.py avant|apres <fichier>` (lecture seule) autour du temps 1.
  `tests_verrouillage.py` détecte le module RH (projets et temps hors des modules fermés).

## Module Finance (migration 20261027100000) — DÉPLOYÉ (temps 1 et 2, 24/10/2026)
- TEMPS 2 FAIT (accord de l'utilisateur, 24/10/2026) : commit f996517 sur main (écrans ; parent 8cf0852 ; aucune
  migration touchée ; aucun secret ; identique aux fichiers testés). Vercel vert ; Supabase Preview « skipped » (aucune
  migration) ; toujours 10 migrations. Parcours en ligne `parcours_finance_en_ligne.mjs` 53/53 (facture d'ESSAI
  ESSAI-FAC-2026-0001 uniquement ; aucun compteur réel) ; tests_verrouillage 275/275 ; ecran_utilisateurs 45/45 ;
  parcours RH 50/50 ; Commercial 57/57 ; instantane_complet 19/19 identiques ; verifier_temps_existants 10/10 ;
  nouveaux champs toujours vides sur les données réelles ; 0 résidu (comptes, fiches, temps, projets, factures,
  fichiers, compteurs).
- TEMPS 1 FAIT (accord de l'utilisateur, 24/10/2026) : commit 8cf0852 sur main = migration seule (vérifié : un seul
  fichier, aucun secret, identique à la version testée, 118/118 rejoué juste avant). Supabase Preview vert ; appliquée en ~40 s ; 10 migrations
  dans migrations_appliquees(). Nouveaux champs présents et vides (projets : mode et tarifs vides, historique [] ; temps :
  taux et montant facturés vides) ; aucune facture ; aucun compteur ; bucket privé `factures` (PDF, 10 Mo), vide.
  `tests_verrouillage.py` (mode Finance) 275/275 (204 d'origine + 71 Finance) ; site encore en ancienne version :
  parcours RH en ligne 50/50, Commercial en ligne 57/57, `ecran_utilisateurs.mjs` 45/45 (script corrigé : taux
  obligatoire et liste des fiches sur /rh/collaborateurs depuis 127b824 — défauts du SCRIPT, pas de l'application) ;
  `instantane_complet.py` : 17 éléments identiques, seuls ajouts l'espace `factures` (vide) ; `verifier_temps_existants`
  10/10 ; 0 résidu d'essai ; aucun numéro réel consommé.
- Ajustements demandés pour le temps 2 (24/10/2026) : le PDF CLIENT n'imprime aucun nom d'intervenant (annexe :
  références non nominatives T-01…, date, projet, durée × tarif, montant) ; le détail nominatif reste dans l'espace admin
  (fiche facture, aperçu) ; message de confirmation visible en haut de la fiche facture après la reprise du PDF, l'envoi,
  le règlement et sa correction (texte fixe CONFIRMATIONS_FACTURE). Gabarit toujours `facture-v1` (aucune facture émise
  avant cet ajustement).
- Décisions de l'utilisateur (24/10/2026, ne plus les redemander) :
  - périmètre v1 : facturation des projets explicitement « au temps passé » (`projets.mode_facturation` = temps_passe ;
    forfait / non_facturable enregistrés mais non facturés ; vide = à définir = non facturable ; jamais déduit d'un devis) ;
    AUCUN avoir, AUCUN statut « annulee », AUCUNE relance, paiement INTÉGRAL seulement, aucun email ni suivi bancaire ;
  - tarif = tarif horaire de VENTE confirmé PAR PROJET (option A : identique pour tous les intervenants), à DATE D'EFFET,
    distinct du coût interne : `collaborateurs.taux_horaire` n'est JAMAIS lu par la facturation (assertion conservée) ;
    tarif > 0 obligatoire ; chaque temps est facturé au tarif contractuel en vigueur à sa date travaillée ;
  - seuls les temps VALIDÉS et non facturés sont facturés ; les temps de l'admin (soumis/attestés) jamais (aucune exception) ;
  - regroupement : un client + un mois, projets sélectionnables ; traitements de TVA incompatibles refusés (devis des
    projets ≠ traitement de la facture) ; essais et réel jamais mélangés ;
  - arrondi unique : montant de chaque temps = heures × tarif arrondi au centime ; ligne (projet × période tarifaire) =
    somme des montants arrondis ; total HT = somme des lignes ; TVA = total HT × taux arrondi ; TTC = HT + TVA ;
    l'écart avec « total des heures × tarif » est montré (aperçu, fiche, PDF), jamais corrigé en silence ;
  - aperçu sans numéro ni réservation ; émission en UNE transaction (verrous : clé d'émission, projets en partage,
    temps exclusifs ; recalcul ; empreinte de l'aperçu ; numéro ; rattachement ; instantané) ; aperçu périmé = refus ;
    même clé d'émission (double clic, coupure réseau) = même facture ; PDF généré ENSUITE (reprise : même numéro, même
    instantané) ; envoi impossible tant que le PDF n'est pas disponible ;
  - envoi DÉCLARÉ (canal, destinataire) ≠ règlement DÉCLARÉ ; paiement partiel jamais enregistré (message explicite) ;
    correction d'une déclaration de règlement : admin + motif, valeurs précédentes dans l'historique, facture inchangée ;
  - paramétrage vide (`CONDITIONS_PAIEMENT_SG_INGENIERIE`, coordonnées) jusqu'à confirmation : émission réelle bloquée
    (application ET base, `finance_controle_emetteur`), essais possibles avec des valeurs [DÉMO] ;
  - facturation électronique : documentation PROVISOIRE (FACTURATION_ELECTRONIQUE_PROVISOIRE) tant que les textes
    complets (DGFiP, BOFiP, Légifrance) ne sont pas vérifiés ; ne pas présenter la v1 comme adaptée à l'émission réelle.
    Extraits officiels lus le 24/10/2026 (sites bloqués par le réseau du conteneur : impots.gouv.fr, bofip.impots.gouv.fr) :
    réception 01/09/2026 pour tous ; émission PME/micro au plus tard 01/09/2027 ; Martinique, Guadeloupe, Réunion dans le
    champ (facturation électronique ET e-reporting) ; ne rien conclure de la seule taille de l'entreprise.
- Colonnes ajoutées (approuvées) :
  - projets : mode_facturation, tarif_vente_ht numeric(10,2) (> 0), tarif_reference, tarif_date_effet, tarif_confirme_par,
    tarif_confirme_par_nom, tarif_confirme_le (récapitulatif = DERNIER tarif confirmé, affiché avec sa date d'effet, « pas
    encore applicable » s'il est futur), tarif_historique jsonb (périodes et corrections, ajout seul : une correction ajoute
    un événement qui désigne la période remplacée ; la sélection ignore les périodes remplacées) ;
  - factures : essai, instantane_emission, emise_par, emise_par_nom, emise_le, pdf_statut, pdf_chemin, pdf_empreinte,
    pdf_taille, pdf_archive_le, pdf_erreur, cle_emission (unique), empreinte_apercu, historique (ajout seul, par la base),
    date_reglement, mode_reglement, reference_reglement, reglement_declare_par, reglement_declare_par_nom, reglement_declare_le ;
  - temps : taux_facture numeric(10,2), montant_facture_ht numeric(12,2) (posés à l'émission seulement, figés).
- Tarif à date d'effet : nouveau tarif = date d'effet postérieure à la dernière ; refusé si un temps facturé est daté
  de cette date ou après ; temps concernés confirmés par EMPREINTE (identité, date, heures : une modification qui garde le
  même nombre de lignes rend la confirmation périmée) ; correction = dernier tarif seulement, motif, refusée si un temps
  a été facturé à ce tarif. Changement de tarif et émission verrouillent le projet : jamais de période incohérente.
- Fonctions (clé secrète seulement) : finance_definir_mode, finance_confirmer_tarif, finance_corriger_tarif,
  finance_temps_concernes, finance_calculer (aperçu = émission), finance_emettre_facture, finance_enregistrer_pdf,
  finance_signaler_echec_pdf, finance_declarer_envoi, finance_enregistrer_reglement, finance_corriger_reglement,
  supprimer_essais_finance (à appeler AVANT supprimer_essais_rh et supprimer_essais_commercial) ; attribuer_numero
  accepte désormais `facture` (FAC) et `essai_facture` (ESSAI-FAC). Les 4 fonctions d'identité restent les seules
  appelables avec un jeton.
- Droits : factures SANS AUCUN droit pour les jetons (même admin ; règle RLS « lecture admin » en défense) — les écrans
  Finance lisent avec la clé secrète après exigerAdmin ; projets et temps lisibles seulement par colonnes nommées (tarifs,
  historique des tarifs, taux et montants facturés illisibles, non filtrables, non triables, `select=*` refusé) ;
  l'événement « facturation » de l'historique d'un temps ne porte que l'identifiant de la facture ; bucket privé `factures`.
- La migration remplace temps_controle (RH) à l'identique + UNE exception (nettoyage des factures d'ESSAI),
  factures_avant_suppression (exception : essais, clé secrète) et attribuer_numero ; elle vérifie AVANT les empreintes des
  versions en base (et celle de prochain_numero) et refuse de s'appliquer si elles diffèrent.
- Écrans (src/app/(protege)/finance) : accueil (factures, bandeaux : émission réelle bloquée, limites, facturation
  électronique provisoire) ; Tarifs et modes des projets ; fiche projet (mode, historique des tarifs, nouveau tarif avec
  liste des temps concernés et case de confirmation, correction motivée) ; Nouvelle facture (client, mois, projets, TVA —
  repris du devis du projet s'il existe, sinon proposition affichée jamais appliquée seule — aperçu, aperçu PDF à la volée,
  émission) ; fiche facture (PDF archivé ou reprise, envoi déclaré, règlement intégral, correction, historique).
  Gabarit PDF `facture-v1` (src/lib/finance/pdf.ts), jamais modifié une fois des factures émises avec.
- Tests locaux (24/10/2026) : `rejouer.sh tests_finance.sql` puis `select count(*) filter (where ok), count(*) from
  fne.resultats` : 118/118 ; `tests_concurrence_finance.sh` 15/15 (double clic, deux clés, tarif pendant une émission et
  inversement, numérotation sans trou) ; `tests_finance_api.py` 88/88 (après tests_finance.sql, PostgREST local) ;
  `test_passage_annee_finance.sh` 6/6 (31/12 22 h 30 en Martinique → FAC-2026) ; `tests_pdf_facture.mts` 19/19 (aucun nom
  d'intervenant, références T-01…) ;
  autotest : 9 sabotages sur 9 + 3 empreintes de fonctions modifiées : refus, rien appliqué ; navigateur
  `navigateur_finance.mjs` (après comptes_navigateur.sql + comptes_navigateur_finance.sql) : simulation 54/54, mode réel
  bloqué 21/21 ; `parcours_finance_en_ligne.mjs` répété sur la pile locale 53/53 (passerelle : création/suppression de
  comptes et liste/suppression de fichiers ajoutées). Non-régression avec la migration : Commercial 135/135, 17/17, 30/30,
  numérotation piégée, PDF devis 14/14, RH 155/155 (2 contrôles ajoutés : facture et rattachement hors émission refusés),
  RH API 28/28, concurrence RH 5/5, temps existants 8/8, compatibilité Utilisateurs 17/17, navigateur Commercial 26/26,
  limite 2/2, réel 4/4, RH 49/49, taux obligatoire 7/7.
- Production (après déploiement) : `tests_verrouillage.py` détecte le module (contrôles 4b) ; `parcours_finance_en_ligne.mjs`
  (facture d'ESSAI uniquement, nettoyage intégré) ; `instantane_complet.py` et `verifier_temps_existants.py` autour du temps 1.
- Ordre de déploiement prévu : temps 1 = commit de la migration seule (le site en ligne reste compatible : ses lectures de
  projets et temps nomment leurs colonnes, il ne lit pas les factures) ; temps 2 = écrans, après « Supabase Preview » vert
  et 20261027100000 dans migrations_appliquees(). Chaque temps sur accord explicite de l'utilisateur.

## Tests locaux dans le conteneur cloud
- Base d'essai PostgreSQL 16 : `/var/tmp/pg-essai` (port 5499), démarrage :
  `su postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D /var/tmp/pg-essai/data -o '-p 5499 -k /var/tmp/pg-essai -c listen_addresses=' -l /var/tmp/pg-essai/log start"`.
- Ne jamais arrêter un processus par son nom (pkill/pgrep) : la commande se tue elle-même ; utiliser les
  scripts `*_local.sh` (fichiers pid).
- Le serveur Node doit passer par le proxy : lancer avec
  `NODE_USE_ENV_PROXY=1 NODE_EXTRA_CA_CERTS=/root/.ccr/ca-bundle.crt npx next start -p 3100`.
- Navigateur : Playwright avec `executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome"`.
- Serveur Next local : `tests-reels/simulation/serveur_local.sh start [1]|stop` (arrêt par le processus qui écoute sur
  le port 3200, lu dans /proc ; `ss` n'existe pas ici ; le pid de `setsid` désigne un intermédiaire déjà terminé).
  Toujours arrêter la pile locale (`pile_locale.sh stop`) avant `rejouer.sh` (sinon la base reste ouverte et rien n'est rejoué).
- `.env.local` est régénéré depuis les variables d'environnement de la session (jamais commité).
