"""Appels DIRECTS à l'API (PostgREST local, base d'ESSAI) avec de vrais jetons : droits RH.
Usage : rejouer.sh tests-reels/simulation/tests_rh.sql ; postgrest_local.sh start ;
        python3 -I tests-reels/simulation/tests_rh_api.py ; postgrest_local.sh stop
"""
import base64, hashlib, hmac, json, urllib.error, urllib.request

API = "http://127.0.0.1:3999"
SECRET = b"secret-essai-local-uniquement-0123456789abcdef"  # base locale uniquement


def jeton(sub, session, role="authenticated"):
    b64 = lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=")
    corps = b64({"alg": "HS256", "typ": "JWT"}) + b"." + b64({"sub": sub, "role": role, "session_id": session, "exp": 9999999999})
    return (corps + b"." + base64.urlsafe_b64encode(hmac.new(SECRET, corps, hashlib.sha256).digest()).rstrip(b"=")).decode()


CHLOE = jeton("aaaaaaaa-0000-0000-0000-000000000023", "bbbbbbbb-0000-0000-0000-000000000023")
MANAGER = jeton("aaaaaaaa-0000-0000-0000-000000000021", "bbbbbbbb-0000-0000-0000-000000000021")
ADMIN = jeton("11111111-1111-1111-1111-111111111111", "bbbbbbbb-0000-0000-0000-000000000001")
PROVISOIRE = jeton("aaaaaaaa-0000-0000-0000-000000000026", "bbbbbbbb-0000-0000-0000-000000000026")
FERMEE = jeton("aaaaaaaa-0000-0000-0000-000000000023", "bbbbbbbb-0000-0000-0000-0000000000ff")
FCHLOE = "22222222-2222-2222-2222-222222222223"
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

print("== Collaboratrice (Chloé)")
s, r = appel("/temps?select=id,collaborateur_id,statut,historique", CHLOE)
verifier("ne lit que ses propres temps", s == 200 and len(lignes(r)) > 0 and all(x["collaborateur_id"] == FCHLOE for x in lignes(r)),
         f"{len(lignes(r))} ligne(s)")
s, r = appel("/rh_projets_ouverts?select=*", CHLOE)
verifier("projets ouverts : id, nom, statut, nom du client seulement",
         s == 200 and len(lignes(r)) > 0 and all(set(x) == {"id", "nom", "statut", "client_nom"} for x in lignes(r)))
s, r = appel("/temps?select=id,projets(nom,clients(nom,email_contact,telephone,adresse))", CHLOE)
verifier("jointure temps → projets → clients : aucune coordonnée client révélée",
         s >= 400 or all(not x.get("projets") for x in lignes(r)), f"HTTP {s}")
s, r = appel("/rh_projets_ouverts?select=id,clients(email_contact)", CHLOE)
verifier("jointure vue projets → clients refusée", s >= 400, f"HTTP {s}")
s, r = appel("/projets?select=id,nom", CHLOE)
verifier("table projets directe : 0 ligne", s == 200 and lignes(r) == [], f"HTTP {s}")
for libelle, chemin in [("colonne taux_horaire", "/collaborateurs?select=taux_horaire"), ("select=*", "/collaborateurs?select=*"),
                        ("filtre sur le taux", "/collaborateurs?select=id&taux_horaire=gt.0"),
                        ("tri par taux", "/collaborateurs?select=id&order=taux_horaire")]:
    s, r = appel(chemin, CHLOE)
    verifier(f"taux horaire : {libelle} refusé", s in REFUS, f"HTTP {s}")
s, r = appel("/temps", CHLOE, "POST", {"collaborateur_id": FCHLOE, "projet_id": None, "heures": 1})
verifier("créer un temps directement : refusé", s in REFUS, f"HTTP {s}")
s, r = appel("/temps?collaborateur_id=eq." + FCHLOE, CHLOE, "PATCH", {"statut": "valide"})
verifier("se valider directement : refusé", s in REFUS, f"HTTP {s}")
s, r = appel("/temps?collaborateur_id=eq." + FCHLOE, CHLOE, "PATCH", {"collaborateur_id": "22222222-2222-2222-2222-222222222222"})
verifier("changer le propriétaire : refusé", s in REFUS, f"HTTP {s}")
s, r = appel("/temps?collaborateur_id=eq." + FCHLOE, CHLOE, "PATCH", {"historique": []})
verifier("effacer l'historique : refusé", s in REFUS, f"HTTP {s}")
s, r = appel("/temps?collaborateur_id=eq." + FCHLOE, CHLOE, "DELETE")
verifier("supprimer ses temps : refusé", s in REFUS, f"HTTP {s}")
for f, corps in [("rh_changer_statut_temps", {"p_auteur": None, "p_temps_ids": None, "p_action": None, "p_motif": None}),
                 ("rh_enregistrer_temps", {"p_auteur": None, "p_temps_id": None, "p_collaborateur_id": None, "p_projet_id": None,
                                           "p_date": None, "p_heures": None, "p_commentaire": None, "p_motif_derogation": None}),
                 ("supprimer_essais_rh", {})]:
    s, r = appel(f"/rpc/{f}", CHLOE, "POST", corps)
    verifier(f"fonction de service {f} : refusée", s in REFUS, f"HTTP {s}")

print("== Manager (Dubois)")
s, r = appel("/temps?select=id", MANAGER)
verifier("lit tous les temps", s == 200 and len(lignes(r)) >= 3, f"{len(lignes(r))} ligne(s)")
un_temps = lignes(appel("/temps?select=id&statut=eq.soumis", MANAGER)[1])[0]["id"]
s, r = appel(f"/temps?id=eq.{un_temps}", MANAGER, "PATCH", {"statut": "valide"})
verifier("lecture globale ≠ écriture : valider par l'API refusé", s in REFUS, f"HTTP {s}")
s, r = appel("/projets", MANAGER, "POST", {"nom": "Pirate"})
verifier("créer un projet : refusé (admin seulement)", s in REFUS, f"HTTP {s}")
s, r = appel("/collaborateurs?select=taux_horaire", MANAGER)
verifier("taux horaire illisible", s in REFUS, f"HTTP {s}")

print("== Admin")
s, r = appel("/collaborateurs?select=taux_horaire", ADMIN)
verifier("taux horaire illisible même pour l'admin (jeton)", s in REFUS, f"HTTP {s}")
s, r = appel("/temps", ADMIN, "POST", {"collaborateur_id": FCHLOE, "heures": 1})
verifier("écriture directe d'un temps refusée (passer par l'application)", s in REFUS, f"HTTP {s}")
s, r = appel("/projets", ADMIN, "POST", {"nom": "Pirate", "devis_id": "dddddddd-0000-0000-0000-0000000000a9"})
verifier("projet rattaché à la main à un devis : refusé", s in REFUS, f"HTTP {s}")
s, r = appel("/factures?select=id", ADMIN, "DELETE")
verifier("supprimer des factures : refusé", s >= 400, f"HTTP {s}")

print("== Comptes sans accès")
for nom, j in [("compte provisoire", PROVISOIRE), ("session fermée", FERMEE)]:
    s1, r1 = appel("/temps?select=id", j)
    s2, r2 = appel("/rh_projets_ouverts?select=id", j)
    verifier(f"{nom} : aucun temps, aucun projet", lignes(r1) == [] and lignes(r2) == [], f"HTTP {s1}/{s2}")
s1, _ = appel("/temps?select=id")
s2, _ = appel("/rh_projets_ouverts?select=id")
verifier("visiteur : refusé", s1 in REFUS and s2 in REFUS, f"HTTP {s1}/{s2}")

print(f"\nBILAN : {sum(resultats)}/{len(resultats)} contrôles réussis")
