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
  chaque module.

## Module Commercial (migration 20261024100000) — PRÉPARÉ sur la branche `preparation-commercial`, NON DÉPLOYÉ
- Ne jamais fusionner dans `main` sans l'accord explicite de l'utilisateur (fusion = déploiement).

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
  `select count(*) filter (where ok), count(*) from essai.resultats` : 123/123.
- `tests_concurrence.sh` : 17/17. `test_numerotation_piegee.sh` : refus par empreinte, rien appliqué.
- Passage d'année : 2e grappe libfaketime `/var/tmp/pg-faketime` (port 5498),
  `PORT_ESSAI=5498 rejouer.sh test_passage_annee.sql`.
- `postgrest_local.sh start` + `python3 -I tests_vues_api.py` : 30/30 (puis `postgrest_local.sh stop`).
- `node --experimental-strip-types tests-reels/tests_pdf_archivage.mts` : 14/14.
- Navigateur : `pile_locale.sh start`, build avec l'URL 127.0.0.1:54321, `navigateur_commercial.mjs`
  (modes simulation 25/25, limite 2/2, reel 4/4 — le mode reel exige un brouillon réel « conseil »).
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

- Module Commercial : PRÉPARÉ (branche `preparation-commercial`), non déployé — voir la section dédiée.

## Tests locaux dans le conteneur cloud
- Base d'essai PostgreSQL 16 : `/var/tmp/pg-essai` (port 5499), démarrage :
  `su postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D /var/tmp/pg-essai/data -o '-p 5499 -k /var/tmp/pg-essai -c listen_addresses=' -l /var/tmp/pg-essai/log start"`.
- Ne jamais arrêter un processus par son nom (pkill/pgrep) : la commande se tue elle-même ; utiliser les
  scripts `*_local.sh` (fichiers pid).
- Le serveur Node doit passer par le proxy : lancer avec
  `NODE_USE_ENV_PROXY=1 NODE_EXTRA_CA_CERTS=/root/.ccr/ca-bundle.crt npx next start -p 3100`.
- Navigateur : Playwright avec `executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome"`.
- `.env.local` est régénéré depuis les variables d'environnement de la session (jamais commité).
