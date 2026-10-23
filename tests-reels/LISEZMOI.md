# Tests réels (Supabase + navigateur)

Comptes et fiches jetables en `@exemple.invalid`, supprimés par `nettoyer`. Ne touchent jamais sgi@gmx.fr.
Clés lues dans les variables d'environnement (jamais écrites ici).

- `python3 -I tests-reels/tests_securite.py creer|tester|nettoyer` : règles RLS via l'API.
- `NODE_USE_ENV_PROXY=1 NODE_EXTRA_CA_CERTS=/root/.ccr/ca-bundle.crt node tests-reels/ecran_utilisateurs.mjs <url>`
  puis `python3 -I tests-reels/tests_securite.py nettoyer` : écran Utilisateurs de bout en bout
  (Playwright installé hors du dépôt, dans le dossier de travail de Claude).
