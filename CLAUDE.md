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
