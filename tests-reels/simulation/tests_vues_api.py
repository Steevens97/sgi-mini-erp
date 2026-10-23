"""Tentatives de contournement des vues de consultation par l'API (PostgREST local, base d'ESSAI).
Jointures (« embedding »), filtres sur colonnes cachées, appels directs, sessions révoquées.
Usage : python3 -I tests-reels/simulation/tests_vues_api.py  (après tests_commercial.sql)
"""
import base64, hashlib, hmac, json, urllib.error, urllib.request

API = "http://127.0.0.1:3999"
SECRET = b"secret-essai-local-uniquement-0123456789abcdef"  # base locale uniquement


def jeton(sub, session, role="authenticated"):
    b64 = lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=")
    corps = b64({"alg": "HS256", "typ": "JWT"}) + b"." + b64(
        {"sub": sub, "role": role, "session_id": session, "exp": 9999999999})
    return (corps + b"." + base64.urlsafe_b64encode(hmac.new(SECRET, corps, hashlib.sha256).digest()).rstrip(b"=")).decode()


COLLAB = jeton("aaaaaaaa-0000-0000-0000-000000000003", "bbbbbbbb-0000-0000-0000-000000000003")
REVOQUE = jeton("aaaaaaaa-0000-0000-0000-000000000005", "bbbbbbbb-0000-0000-0000-000000000099")
PROVISOIRE = jeton("aaaaaaaa-0000-0000-0000-000000000004", "bbbbbbbb-0000-0000-0000-000000000004")
SESSION_FERMEE = jeton("aaaaaaaa-0000-0000-0000-000000000003", "bbbbbbbb-0000-0000-0000-0000000000ff")

resultats = []


def appel(chemin, jeton_=None, methode="GET", corps=None):
    h = {"Content-Type": "application/json"}
    if jeton_:
        h["Authorization"] = "Bearer " + jeton_
    req = urllib.request.Request(API + chemin, method=methode, headers=h,
                                 data=json.dumps(corps).encode() if corps is not None else None)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            t = r.read().decode()
            return r.status, json.loads(t) if t else None
    except urllib.error.HTTPError as e:
        t = e.read().decode()
        try:
            return e.code, json.loads(t)
        except ValueError:
            return e.code, t


def verifier(libelle, ok, detail=""):
    resultats.append(ok)
    print(f"  [{'OK ' if ok else 'ÉCHEC'}] {libelle}" + (f"  ({detail})" if detail else ""))


def texte(r):
    return json.dumps(r, ensure_ascii=False)


INTERDIT = ["@exemple.invalid", "0596", "12 rue", "numero_tva_client", "instantane", "pdf_chemin", "BTP Caraïbes\",\"email"]

print("== Collaborateur actif")
s, r = appel("/commercial_devis?select=id,numero,statut", COLLAB)
verifier("lit les devis par la vue", s == 200 and len(r) >= 4, f"{len(r) if isinstance(r, list) else r} devis")
for chemin in [
    "/commercial_devis?select=*,prospects(*)",
    "/commercial_devis?select=*,prospects!inner(email,telephone,adresse)",
    "/commercial_devis_lignes?select=*,devis(*)",
    "/commercial_devis?select=*,projets(*)",
    "/commercial_prospects?select=*,clients(*)",
    "/commercial_prospects?select=*,devis(criteres_tva,instantane_emission)",
]:
    s, r = appel(chemin, COLLAB)
    fuite = [m for m in INTERDIT if m in texte(r)]
    vide_ou_refus = s >= 400 or all(
        all(v in (None, []) for k, v in ligne.items() if isinstance(v, (list, dict)) or v is None) for ligne in r) \
        if isinstance(r, list) else True
    verifier(f"jointure {chemin.split('?')[1][:55]} : aucune donnée interdite", not fuite,
             f"HTTP {s}, {'refusé' if s >= 400 else str(len(r)) + ' lignes'}{', FUITE ' + str(fuite) if fuite else ''}")
for chemin in [
    "/commercial_prospects?email=like.*",
    "/commercial_prospects?select=email",
    "/commercial_devis?criteres_tva=not.is.null",
    "/commercial_devis?select=instantane_emission",
    "/commercial_devis?order=pdf_empreinte",
    "/commercial_prospects?adresse=like.*rue*",
]:
    s, r = appel(chemin, COLLAB)
    verifier(f"filtre/colonne cachée {chemin.split('?')[1]} : refusé", s >= 400, f"HTTP {s}")
for chemin in ["/prospects?select=email", "/devis?select=instantane_emission", "/devis_lignes", "/clients", "/projets"]:
    s, r = appel(chemin, COLLAB)
    verifier(f"table {chemin.split('?')[0]} en direct : rien", (s == 200 and r == []) or s >= 400,
             f"HTTP {s}, {len(r) if isinstance(r, list) else r}")
for methode, chemin, corps in [("PATCH", "/commercial_prospects?id=not.is.null", {"nom": "Pirate"}),
                               ("POST", "/commercial_prospects", {"nom": "Pirate"}),
                               ("DELETE", "/commercial_devis?id=not.is.null", None)]:
    s, r = appel(chemin, COLLAB, methode, corps)
    verifier(f"{methode} sur la vue : refusé", s >= 400, f"HTTP {s}")
for f, corps in [("creer_prospect_essai", {"p_nom": "x", "p_societe": "x", "p_adresse": "x", "p_code_postal": "x",
                                           "p_ville": "x", "p_pays": "MQ"}),
                 ("emettre_devis", {"p_devis_id": "dddddddd-0000-0000-0000-000000000001",
                                    "p_auteur": "aaaaaaaa-0000-0000-0000-000000000003",
                                    "p_emetteur": {}, "p_gabarit": "v1"}),
                 ("controle_destinataire", {"p_prospect_id": "cccccccc-0000-0000-0000-000000000001"}),
                 ("construire_instantane_devis", {}),
                 ("prochain_numero", {"p_cle": "devis_2026", "p_prefixe": "DEV"})]:
    s, r = appel(f"/rpc/{f}", COLLAB, "POST", corps)
    verifier(f"appel direct de {f} : refusé", s >= 400, f"HTTP {s}")

for nom, j in [("Session révoquée (ancien jeton)", REVOQUE), ("Session fermée du collaborateur", SESSION_FERMEE),
               ("Manager au mot de passe provisoire", PROVISOIRE), ("Visiteur", None)]:
    print(f"== {nom}")
    total = 0
    statuts = []
    for chemin in ["/commercial_prospects", "/commercial_devis", "/commercial_devis_lignes",
                   "/commercial_devis?select=*,prospects(*)", "/prospects", "/devis", "/clients"]:
        s, r = appel(chemin, j)
        statuts.append(s)
        total += len(r) if isinstance(r, list) else 0
    verifier("ne voit rien (vues, jointures, tables)", total == 0, f"{total} ligne(s), HTTP {sorted(set(statuts))}")

print(f"\nBILAN : {sum(resultats)}/{len(resultats)} contrôles réussis")
