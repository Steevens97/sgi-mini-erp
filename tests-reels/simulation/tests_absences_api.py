"""Appels DIRECTS à l'API (PostgREST local, base d'ESSAI) avec de vrais jetons : confidentialité Absences.
Soldes et historique des soldes : illisibles dans les fiches pour TOUS les jetons (admin compris), visibles seulement
par la vue absences_soldes (soi, équipe directe du manager, admin) ; congés et notes : mêmes règles ; aucune écriture.
Usage : rejouer.sh tests-reels/simulation/tests_absences.sql ; postgrest_local.sh start ;
        python3 -I tests-reels/simulation/tests_absences_api.py ; postgrest_local.sh stop
"""
import base64, hashlib, hmac, json, urllib.error, urllib.request

API = "http://127.0.0.1:3999"
SECRET = b"secret-essai-local-uniquement-0123456789abcdef"  # base locale uniquement


def jeton(sub, session, role="authenticated"):
    b64 = lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=")
    corps = b64({"alg": "HS256", "typ": "JWT"}) + b"." + b64({"sub": sub, "role": role, "session_id": session, "exp": 9999999999})
    return (corps + b"." + base64.urlsafe_b64encode(hmac.new(SECRET, corps, hashlib.sha256).digest()).rstrip(b"=")).decode()


ADMIN = jeton("11111111-1111-1111-1111-111111111111", "bbbbbbbb-0000-0000-0000-000000000001")
BRUNO = jeton("aaaaaaaa-0000-0000-0000-000000000041", "bbbbbbbb-0000-0000-0000-000000000041")
LEA = jeton("aaaaaaaa-0000-0000-0000-000000000042", "bbbbbbbb-0000-0000-0000-000000000042")
CHLOE = jeton("aaaaaaaa-0000-0000-0000-000000000043", "bbbbbbbb-0000-0000-0000-000000000043")
KARIM = jeton("aaaaaaaa-0000-0000-0000-000000000044", "bbbbbbbb-0000-0000-0000-000000000044")
PROVISOIRE = jeton("aaaaaaaa-0000-0000-0000-000000000047", "bbbbbbbb-0000-0000-0000-000000000047")
LEA_ANCIENNE = jeton("aaaaaaaa-0000-0000-0000-000000000042", "bbbbbbbb-0000-0000-0000-0000000000ff")
SERVICE = jeton("service", None, "service_role")
FLEA, FNGU, FDUB, FADM = ("22222222-2222-2222-2222-222222222221", "22222222-2222-2222-2222-222222222223",
                          "22222222-2222-2222-2222-222222222222", "22222222-2222-2222-2222-2222222222fa")
resultats = []


def appel(chemin, j=None, methode="GET", corps=None, entetes=None):
    h = {"Content-Type": "application/json", **(entetes or {})}
    if j:
        h["Authorization"] = "Bearer " + j
    req = urllib.request.Request(API + chemin, method=methode, headers=h, data=json.dumps(corps).encode() if corps is not None else None)
    try:
        with urllib.request.urlopen(req) as r:
            t = r.read().decode()
            return r.status, (json.loads(t) if t else None)
    except urllib.error.HTTPError as e:
        t = e.read().decode()
        try:
            return e.code, json.loads(t)
        except ValueError:
            return e.code, t


def verifier(libelle, ok, detail=""):
    resultats.append(ok)
    print(f"  [{'OK ' if ok else 'ÉCHEC'}] {libelle}" + (f"  ({detail})" if detail else ""))


lignes = lambda r: r if isinstance(r, list) else []
REFUS = (401, 403)

print("== 1. Soldes illisibles dans les fiches, pour tous les jetons (admin compris)")
interdites = [
    ("/collaborateurs?select=solde_conges", "solde de congés payés"),
    ("/collaborateurs?select=id,solde_rtt", "solde RTT"),
    ("/collaborateurs?select=id,historique_soldes", "historique des soldes"),
    ("/collaborateurs?select=*", "« select=* » sur les fiches"),
    ("/collaborateurs?select=id&solde_conges=gt.20", "filtre sur le solde"),
    ("/collaborateurs?select=id&order=solde_conges.desc", "tri sur le solde"),
    ("/conges?select=id,collaborateurs!conges_collaborateur_id_fkey(solde_conges)", "jointure congés → solde"),
    ("/conges?select=id,collaborateurs!conges_valide_par_fkey(solde_rtt)", "jointure congés → solde RTT du valideur"),
    ("/notes_de_frais?select=id,collaborateurs(historique_soldes)", "jointure notes → historique des soldes"),
]
for nom, j in (("Admin", ADMIN), ("Manager", BRUNO), ("Collaboratrice", LEA), ("Visiteur", None)):
    for chemin, quoi in interdites:
        s, r = appel(chemin, j)
        verifier(f"{nom} : {quoi} refusé", s in (400, 401, 403) and not lignes(r), f"HTTP {s}")
s, r = appel("/collaborateurs?select=id,nom,prenom,manager_id,date_sortie", LEA)
verifier("lectures existantes des fiches intactes (nom, manager, date de sortie)", s == 200 and len(lignes(r)) >= 1, f"HTTP {s}")

print("\n== 2. Vue des soldes : soi, équipe directe, admin")
s, tous = appel("/collaborateurs?select=id", SERVICE)
nb_fiches = len(lignes(tous))
cas = [
    ("Collaboratrice", LEA, lambda r: [x["id"] for x in r] == [FLEA]),
    ("Manager", BRUNO, lambda r: sorted(x["nom"] for x in r) == ["Dubois", "Moreau", "Nguyen"]),
    ("Manager hors équipe", KARIM, lambda r: [x["nom"] for x in r] == ["Petit"]),
    ("Admin", ADMIN, lambda r: len(r) == nb_fiches and nb_fiches > 3),
    ("Admin provisoire", PROVISOIRE, lambda r: r == []),
    ("Ancienne session de la collaboratrice", LEA_ANCIENNE, lambda r: r == []),
]
for nom, j, attendu in cas:
    s, r = appel("/absences_soldes?select=id,nom,solde_conges,solde_rtt,droits_rtt_renseignes,historique_soldes", j)
    verifier(f"{nom} : soldes visibles conformes", s == 200 and attendu(lignes(r)), f"HTTP {s}, {len(lignes(r))} ligne(s)")
s, r = appel("/absences_soldes?select=id", None)
verifier("Visiteur : vue des soldes refusée", s in REFUS, f"HTTP {s}")
s, r = appel(f"/absences_soldes?select=id,solde_conges&id=eq.{FLEA}", KARIM)
verifier("Manager hors équipe : fiche de Léa demandée par son identifiant → rien", s == 200 and lignes(r) == [], f"HTTP {s}")
s, r = appel(f"/absences_soldes?select=id&id=eq.{FNGU}", LEA)
verifier("Collaboratrice : solde d'une collègue demandé par son identifiant → rien", s == 200 and lignes(r) == [], f"HTTP {s}")
s, r = appel(f"/absences_soldes?select=id&id=eq.{FADM}", BRUNO)
verifier("Manager : solde de l'admin (hors équipe) → rien", s == 200 and lignes(r) == [], f"HTTP {s}")

print("\n== 3. Congés et notes de frais : soi, équipe directe, admin")
for table in ("conges", "notes_de_frais"):
    s, r = appel(f"/{table}?select=id,collaborateur_id", LEA)
    verifier(f"{table} — collaboratrice : ses seules lignes", s == 200 and lignes(r) and all(x["collaborateur_id"] == FLEA for x in r), f"{len(lignes(r))} ligne(s)")
    s, r = appel(f"/{table}?select=id&collaborateur_id=eq.{FNGU}", LEA)
    verifier(f"{table} — collaboratrice : lignes d'une collègue filtrées → rien", s == 200 and lignes(r) == [], f"HTTP {s}")
    s, r = appel(f"/{table}?select=id,collaborateur_id", BRUNO)
    verifier(f"{table} — manager : son équipe et lui seulement", s == 200 and all(x["collaborateur_id"] in (FLEA, FNGU, FDUB) for x in lignes(r))
             and any(x["collaborateur_id"] == FLEA for x in lignes(r)), f"{len(lignes(r))} ligne(s)")
    s, r = appel(f"/{table}?select=id&collaborateur_id=eq.{FLEA}", KARIM)
    verifier(f"{table} — manager hors équipe : rien de Léa", s == 200 and lignes(r) == [], f"HTTP {s}")
    s, r = appel(f"/{table}?select=id", LEA_ANCIENNE)
    verifier(f"{table} — ancienne session : rien", s == 200 and lignes(r) == [], f"HTTP {s}")
    s, r = appel(f"/{table}?select=id", PROVISOIRE)
    verifier(f"{table} — admin provisoire : rien", s == 200 and lignes(r) == [], f"HTTP {s}")
    s, r = appel(f"/{table}?select=id", None)
    verifier(f"{table} — visiteur : refusé", s in REFUS, f"HTTP {s}")
    s, srv = appel(f"/{table}?select=id", SERVICE)
    s, r = appel(f"/{table}?select=id", ADMIN)
    verifier(f"{table} — admin : vue globale", s == 200 and len(lignes(r)) == len(lignes(srv)) > 0, f"{len(lignes(r))} ligne(s)")

print("\n== 4. Aucune écriture avec un jeton")
s, c = appel(f"/conges?select=id&collaborateur_id=eq.{FLEA}&limit=1", SERVICE)
conge = lignes(c)[0]["id"]
s, n = appel(f"/notes_de_frais?select=id&collaborateur_id=eq.{FLEA}&limit=1", SERVICE)
note = lignes(n)[0]["id"]
s, avant_c = appel(f"/conges?select=statut&id=eq.{conge}", SERVICE)
s, avant_n = appel(f"/notes_de_frais?select=montant,statut&id=eq.{note}", SERVICE)
ecritures = [
    ("Collaboratrice : création d'un congé", LEA, "POST", "/conges", {"collaborateur_id": FLEA, "date_debut": "2027-03-01", "date_fin": "2027-03-01"}),
    ("Manager : validation directe d'un congé", BRUNO, "PATCH", f"/conges?id=eq.{conge}", {"statut": "validee"}),
    ("Admin : validation directe d'un congé", ADMIN, "PATCH", f"/conges?id=eq.{conge}", {"statut": "validee"}),
    ("Admin : suppression d'un congé", ADMIN, "DELETE", f"/conges?id=eq.{conge}", None),
    ("Collaboratrice : modification de sa note", LEA, "PATCH", f"/notes_de_frais?id=eq.{note}", {"montant": 1}),
    ("Admin : remboursement direct d'une note", ADMIN, "PATCH", f"/notes_de_frais?id=eq.{note}", {"statut": "remboursee"}),
    ("Admin : suppression d'une note", ADMIN, "DELETE", f"/notes_de_frais?id=eq.{note}", None),
    ("Admin : solde modifié dans la fiche", ADMIN, "PATCH", f"/collaborateurs?id=eq.{FLEA}", {"solde_conges": 99}),
    ("Admin : historique des soldes effacé", ADMIN, "PATCH", f"/collaborateurs?id=eq.{FLEA}", {"historique_soldes": []}),
    ("Admin : fiche créée avec un solde", ADMIN, "POST", "/collaborateurs", {"nom": "X", "taux_horaire": 0, "solde_conges": 50}),
]
for libelle, j, m, chemin, corps in ecritures:
    s, r = appel(chemin, j, m, corps, {"Prefer": "return=minimal"})
    verifier(libelle + " : refusé", s in (400, 401, 403), f"HTTP {s}")
s, r = appel(f"/conges?select=statut&id=eq.{conge}", SERVICE)
s2, r2 = appel(f"/notes_de_frais?select=montant,statut&id=eq.{note}", SERVICE)
verifier("après ces tentatives : congé et note inchangés", lignes(r) == lignes(avant_c) and lignes(r2) == lignes(avant_n), f"{lignes(r)} {lignes(r2)}")
s, r = appel("/collaborateurs?select=id", ADMIN, "POST",
             {"nom": "Compat-API", "prenom": "U", "email": "compat-api@exemple.invalid", "poste": "Essai", "date_entree": "2026-10-01", "taux_horaire": 1},
             {"Prefer": "return=representation"})
verifier("Admin : création de fiche de l'écran Utilisateurs toujours possible", s == 201 and len(lignes(r)) == 1, f"HTTP {s}")
if s == 201:
    appel(f"/collaborateurs?id=eq.{lignes(r)[0]['id']}", SERVICE, "DELETE")

print("\n== 5. Fonctions de service inaccessibles avec un jeton (même admin)")
fonctions = [
    ("abs_demander_conge", {"p_auteur": "aaaaaaaa-0000-0000-0000-000000000042", "p_collaborateur": FLEA, "p_type": "rtt", "p_debut": "2027-03-01",
                            "p_fin": "2027-03-01", "p_debut_apres_midi": False, "p_fin_midi": False, "p_nb_jours": 1, "p_motif": None, "p_motif_retroactif": None}),
    ("abs_decider_conge", {"p_auteur": "11111111-1111-1111-1111-111111111111", "p_conge": conge, "p_decision": "valider", "p_motif": None}),
    ("abs_ajuster_solde", {"p_auteur": "11111111-1111-1111-1111-111111111111", "p_collaborateur": FLEA, "p_type": "rtt", "p_ancien": 2, "p_nouveau": 9, "p_motif": "x"}),
    ("abs_declarer_remboursement", {"p_auteur": "11111111-1111-1111-1111-111111111111", "p_note": note, "p_date": "2026-10-24", "p_reference": None}),
    ("abs_fichiers_orphelins", {}),
    ("supprimer_essais_absences", {}),
]
for nom_f, args in fonctions:
    for nom, j in (("Admin", ADMIN), ("Collaboratrice", LEA), ("Visiteur", None)):
        s, r = appel(f"/rpc/{nom_f}", j, "POST", args)
        verifier(f"{nom} : {nom_f} refusée", s in (401, 403, 404), f"HTTP {s}")
s, r = appel("/rpc/abs_fichiers_orphelins", SERVICE, "POST", {})
verifier("clé secrète : abs_fichiers_orphelins disponible (serveur seulement)", s == 200, f"HTTP {s}")
s, r = appel("/collaborateurs?select=solde_conges,solde_rtt&limit=1", SERVICE)
verifier("clé secrète : soldes lisibles (écrans serveur après contrôle des droits)", s == 200 and len(lignes(r)) == 1, f"HTTP {s}")

print(f"\nBILAN : {sum(resultats)}/{len(resultats)} contrôles réussis")
