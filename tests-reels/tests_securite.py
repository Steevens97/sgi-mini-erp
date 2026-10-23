"""Tests réels des règles RLS de profiles et collaborateurs, avec des comptes jetables.
Usage : python3 -I tests_securite.py creer|tester|nettoyer
"""
import json, os, ssl, sys, time, urllib.request, urllib.error

U = os.environ["NEXT_PUBLIC_SUPABASE_URL"]
ANON = os.environ["NEXT_PUBLIC_SUPABASE_ANON_KEY"]
SECRET = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
CTX = ssl.create_default_context(cafile="/root/.ccr/ca-bundle.crt")
DOMAINE = "@exemple.invalid"
MDP = "Jetable-MotDePasse-2026"
FICHIER = os.path.join(os.path.dirname(__file__), "comptes_jetables.json")
LEA, BRUNO, CHLOE = (
    "22222222-2222-2222-2222-222222222221",
    "22222222-2222-2222-2222-222222222222",
    "22222222-2222-2222-2222-222222222223",
)
MON_COMPTE = "sgi@gmx.fr"


def appel(methode, chemin, cle, jeton=None, corps=None, entetes=None):
    h = {"apikey": cle, "Authorization": f"Bearer {jeton or cle}", "Content-Type": "application/json"}
    h.update(entetes or {})
    req = urllib.request.Request(U + chemin, method=methode, headers=h,
                                 data=json.dumps(corps).encode() if corps is not None else None)
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=20) as r:
            txt = r.read().decode()
            return r.status, json.loads(txt) if txt else None
    except urllib.error.HTTPError as e:
        txt = e.read().decode()
        try:
            return e.code, json.loads(txt)
        except ValueError:
            return e.code, txt


def creer():
    t = int(time.time())
    plan = {
        "collaborateur": ("collaborateur", LEA),
        "manager": ("manager", BRUNO),
        "admin": ("admin", None),
        "orphelin": ("collaborateur", None),
    }
    comptes = {}
    for cle, (role, collab) in plan.items():
        email = f"jetable-{cle}-{t}{DOMAINE}"
        s, u = appel("POST", "/auth/v1/admin/users", SECRET,
                     corps={"email": email, "password": MDP, "email_confirm": True})
        assert s == 200, (s, u)
        uid = u["id"]
        s, p = appel("GET", f"/rest/v1/profiles?id=eq.{uid}&select=role,collaborateur_id", SECRET)
        print(f"  {cle:13s} créé ; profil créé par le déclencheur : {p}")
        s, _ = appel("PATCH", f"/rest/v1/profiles?id=eq.{uid}", SECRET,
                     corps={"role": role, "collaborateur_id": collab})
        assert s in (200, 204), s
        comptes[cle] = {"id": uid, "email": email}
    json.dump(comptes, open(FICHIER, "w"))
    print("  comptes jetables enregistrés dans", FICHIER)


def jeton(email):
    s, r = appel("POST", "/auth/v1/token?grant_type=password", ANON, corps={"email": email, "password": MDP})
    assert s == 200, (s, r)
    return r["access_token"]


resultats = []


def verifier(libelle, ok, detail=""):
    resultats.append(ok)
    print(f"  [{'OK ' if ok else 'ÉCHEC'}] {libelle}" + (f"  ({detail})" if detail else ""))


def lignes(r):
    return r if isinstance(r, list) else []


def tester():
    c = json.load(open(FICHIER))
    retour = {"Prefer": "return=representation"}

    print("\n== Visiteur anonyme")
    s, r = appel("GET", "/rest/v1/profiles?select=id", ANON)
    verifier("ne voit aucun profil", lignes(r) == [], f"{len(lignes(r))} ligne(s)")
    s, r = appel("GET", "/rest/v1/collaborateurs?select=id", ANON)
    verifier("ne voit aucune fiche collaborateur", lignes(r) == [], f"{len(lignes(r))} ligne(s)")
    s, r = appel("POST", "/rest/v1/rpc/mon_role", ANON, corps={})
    verifier("ne peut pas appeler mon_role()", s in (401, 403), f"HTTP {s}")
    s, r = appel("PATCH", "/rest/v1/profiles?email=eq.sgi@gmx.fr", ANON, corps={"role": "collaborateur"}, entetes=retour)
    verifier("ne peut pas modifier un rôle", lignes(r) == [], f"HTTP {s}")

    for nom, attendu_collabs in (("collaborateur", {LEA}), ("orphelin", set())):
        print(f"\n== Compte {nom}" + (" (rattaché à Léa Moreau)" if nom == "collaborateur" else " (sans fiche collaborateur)"))
        j = jeton(c[nom]["email"])
        moi = c[nom]["id"]
        s, r = appel("GET", "/rest/v1/profiles?select=id,role", ANON, j)
        verifier("ne lit que son propre profil", [x["id"] for x in lignes(r)] == [moi], f"{len(lignes(r))} ligne(s)")
        s, r = appel("GET", "/rest/v1/collaborateurs?select=id,nom", ANON, j)
        vus = {x["id"] for x in lignes(r)}
        verifier(f"voit exactement {len(attendu_collabs)} fiche(s) collaborateur", vus == attendu_collabs,
                 ", ".join(x["nom"] for x in lignes(r)) or "aucune")
        s, r = appel("POST", "/rest/v1/rpc/mon_role", ANON, j, corps={})
        verifier("mon_role() = collaborateur", r == "collaborateur", repr(r))
        s, r = appel("POST", "/rest/v1/rpc/est_admin", ANON, j, corps={})
        verifier("est_admin() = faux", r is False, repr(r))
        s, r = appel("POST", "/rest/v1/rpc/mon_collaborateur_id", ANON, j, corps={})
        verifier("mon_collaborateur_id() correct", r == (LEA if nom == "collaborateur" else None), repr(r))
        s, r = appel("PATCH", f"/rest/v1/profiles?id=eq.{moi}", ANON, j, corps={"role": "admin"}, entetes=retour)
        verifier("ne peut PAS se donner le rôle admin", lignes(r) == [], f"HTTP {s}, {len(lignes(r))} ligne(s) modifiée(s)")
        s, r = appel("PATCH", f"/rest/v1/profiles?id=eq.{moi}", ANON, j, corps={"collaborateur_id": CHLOE}, entetes=retour)
        verifier("ne peut PAS changer son rattachement", lignes(r) == [], f"HTTP {s}")
        s, r = appel("PATCH", f"/rest/v1/collaborateurs?id=eq.{LEA}", ANON, j, corps={"taux_horaire": 999}, entetes=retour)
        verifier("ne peut PAS modifier une fiche (même la sienne)", lignes(r) == [], f"HTTP {s}")
        s, r = appel("POST", "/rest/v1/collaborateurs", ANON, j, corps={"nom": "Intrus", "taux_horaire": 0}, entetes=retour)
        verifier("ne peut PAS créer de fiche", s in (401, 403), f"HTTP {s}")
        s, r = appel("DELETE", f"/rest/v1/collaborateurs?id=eq.{CHLOE}", ANON, j, entetes=retour)
        verifier("ne peut PAS supprimer de fiche", lignes(r) == [], f"HTTP {s}")

    print("\n== Compte manager (rattaché à Bruno Dubois)")
    j = jeton(c["manager"]["email"])
    moi = c["manager"]["id"]
    s, r = appel("GET", "/rest/v1/profiles?select=id", ANON, j)
    verifier("ne lit que son propre profil", [x["id"] for x in lignes(r)] == [moi], f"{len(lignes(r))} ligne(s)")
    s, r = appel("GET", "/rest/v1/collaborateurs?select=id", ANON, j)
    s2, tous = appel("GET", "/rest/v1/collaborateurs?select=id", SECRET)
    verifier("voit toutes les fiches collaborateur", {x["id"] for x in lignes(r)} == {x["id"] for x in tous},
             f"{len(lignes(r))}/{len(tous)}")
    s, r = appel("POST", "/rest/v1/rpc/mon_role", ANON, j, corps={})
    verifier("mon_role() = manager", r == "manager", repr(r))
    s, r = appel("PATCH", f"/rest/v1/profiles?id=eq.{moi}", ANON, j, corps={"role": "admin"}, entetes=retour)
    verifier("ne peut PAS se donner le rôle admin", lignes(r) == [], f"HTTP {s}")
    s, r = appel("PATCH", f"/rest/v1/profiles?id=eq.{c['collaborateur']['id']}", ANON, j, corps={"role": "manager"}, entetes=retour)
    verifier("ne peut PAS changer le rôle d'un autre", lignes(r) == [], f"HTTP {s}")
    s, r = appel("PATCH", f"/rest/v1/collaborateurs?id=eq.{LEA}", ANON, j, corps={"taux_horaire": 999}, entetes=retour)
    verifier("ne peut PAS modifier une fiche", lignes(r) == [], f"HTTP {s}")
    s, r = appel("POST", "/rest/v1/collaborateurs", ANON, j, corps={"nom": "Intrus", "taux_horaire": 0}, entetes=retour)
    verifier("ne peut PAS créer de fiche", s in (401, 403), f"HTTP {s}")

    print("\n== Compte admin jetable")
    j = jeton(c["admin"]["email"])
    moi = c["admin"]["id"]
    s, r = appel("GET", "/rest/v1/profiles?select=id,email", ANON, j)
    s2, tous_profils = appel("GET", "/rest/v1/profiles?select=id", SECRET)
    verifier("lit tous les profils", len(lignes(r)) == len(tous_profils), f"{len(lignes(r))}/{len(tous_profils)}")
    s, r = appel("GET", "/rest/v1/collaborateurs?select=id", ANON, j)
    verifier("voit toutes les fiches", len(lignes(r)) == len(tous), f"{len(lignes(r))}/{len(tous)}")
    s, r = appel("POST", "/rest/v1/rpc/est_admin", ANON, j, corps={})
    verifier("est_admin() = vrai", r is True, repr(r))
    cible = c["collaborateur"]["id"]
    s, r = appel("PATCH", f"/rest/v1/profiles?id=eq.{cible}", ANON, j, corps={"role": "manager"}, entetes=retour)
    verifier("PEUT changer le rôle d'un autre compte", [x["role"] for x in lignes(r)] == ["manager"], f"HTTP {s}")
    s, r = appel("PATCH", f"/rest/v1/profiles?id=eq.{cible}", ANON, j, corps={"role": "collaborateur"}, entetes=retour)
    verifier("  … et le remettre", [x["role"] for x in lignes(r)] == ["collaborateur"], f"HTTP {s}")
    s, r = appel("PATCH", f"/rest/v1/profiles?id=eq.{moi}", ANON, j, corps={"role": "collaborateur"}, entetes=retour)
    msg = r.get("message") if isinstance(r, dict) else r
    verifier("ne peut PAS se rétrograder lui-même", s >= 400 and "lui-même" in str(msg), f"HTTP {s} : {msg}")
    s, r = appel("PATCH", f"/rest/v1/profiles?id=eq.{moi}", ANON, j, corps={"collaborateur_id": None}, entetes=retour)
    verifier("peut modifier son propre rattachement", len(lignes(r)) == 1, f"HTTP {s}")
    s, fiche = appel("GET", f"/rest/v1/collaborateurs?id=eq.{LEA}&select=poste", SECRET)
    s, r = appel("PATCH", f"/rest/v1/collaborateurs?id=eq.{LEA}", ANON, j, corps={"poste": fiche[0]["poste"]}, entetes=retour)
    verifier("PEUT modifier une fiche (valeur réécrite à l'identique)", len(lignes(r)) == 1, f"HTTP {s}")
    s, r = appel("POST", "/rest/v1/collaborateurs", ANON, j,
                 corps={"nom": "Fiche-jetable-test", "taux_horaire": 0}, entetes=retour)
    ok = s == 201 and len(lignes(r)) == 1
    verifier("PEUT créer une fiche", ok, f"HTTP {s}")
    if ok:
        s, r2 = appel("DELETE", f"/rest/v1/collaborateurs?id=eq.{r[0]['id']}", ANON, j, entetes=retour)
        verifier("PEUT supprimer cette fiche de test", len(lignes(r2)) == 1, f"HTTP {s}")

    print("\n== Votre compte sgi@gmx.fr")
    s, r = appel("GET", "/rest/v1/profiles?email=eq.sgi@gmx.fr&select=role,nom,collaborateur_id", SECRET)
    verifier("toujours admin, inchangé", lignes(r) and r[0]["role"] == "admin", json.dumps(r, ensure_ascii=False))
    s, r = appel("GET", "/rest/v1/collaborateurs?select=id,nom,prenom,poste,taux_horaire&order=nom", SECRET)
    print("  fiches collaborateur après tests :", ", ".join(f"{x['prenom']} {x['nom']} ({x['poste']}, {x['taux_horaire']})" for x in r))

    print(f"\nBILAN : {sum(resultats)}/{len(resultats)} contrôles réussis")


def nettoyer():
    s, r = appel("GET", "/auth/v1/admin/users?per_page=200", SECRET)
    for u in r["users"]:
        if u["email"].endswith(DOMAINE) and u["email"] != MON_COMPTE:
            s2, _ = appel("DELETE", f"/auth/v1/admin/users/{u['id']}", SECRET)
            print(f"  supprimé {u['email']} (HTTP {s2})")
    s, r = appel("GET", "/auth/v1/admin/users?per_page=200", SECRET)
    print("  comptes restants :", [u["email"] for u in r["users"]])
    s, r = appel("GET", "/rest/v1/collaborateurs?email=like.*%40exemple.invalid&select=id,prenom,nom,email", SECRET)
    for f in r:
        s2, _ = appel("DELETE", f"/rest/v1/collaborateurs?id=eq.{f['id']}", SECRET)
        print(f"  fiche jetable supprimée : {f['prenom']} {f['nom']} (HTTP {s2})")
    s, r = appel("GET", "/rest/v1/profiles?select=email,role,collaborateur_id", SECRET)
    print("  profils restants :", r)
    s, r = appel("GET", "/rest/v1/collaborateurs?select=prenom,nom&order=nom", SECRET)
    print("  fiches restantes :", ", ".join(f"{x['prenom']} {x['nom']}" for x in r))
    if os.path.exists(FICHIER):
        os.remove(FICHIER)


{"creer": creer, "tester": tester, "nettoyer": nettoyer}[sys.argv[1]]()
