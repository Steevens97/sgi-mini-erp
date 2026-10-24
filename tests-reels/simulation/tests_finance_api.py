"""Appels DIRECTS à l'API (PostgREST local, base d'ESSAI) avec de vrais jetons : confidentialité Finance.
Tarifs, historique des tarifs, taux et montants facturés, factures : illisibles, non filtrables, non triables
pour TOUS les jetons utilisateurs (admin compris) ; lectures existantes des écrans intactes.
Usage : rejouer.sh tests-reels/simulation/tests_finance.sql ; postgrest_local.sh start ;
        python3 -I tests-reels/simulation/tests_finance_api.py ; postgrest_local.sh stop
"""
import base64, hashlib, hmac, json, urllib.error, urllib.request

API = "http://127.0.0.1:3999"
SECRET = b"secret-essai-local-uniquement-0123456789abcdef"  # base locale uniquement


def jeton(sub, session, role="authenticated"):
    b64 = lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=")
    corps = b64({"alg": "HS256", "typ": "JWT"}) + b"." + b64({"sub": sub, "role": role, "session_id": session, "exp": 9999999999})
    return (corps + b"." + base64.urlsafe_b64encode(hmac.new(SECRET, corps, hashlib.sha256).digest()).rstrip(b"=")).decode()


ADMIN = jeton("11111111-1111-1111-1111-111111111111", "bbbbbbbb-0000-0000-0000-000000000001")
MANAGER = jeton("aaaaaaaa-0000-0000-0000-000000000031", "bbbbbbbb-0000-0000-0000-000000000031")
LEA = jeton("aaaaaaaa-0000-0000-0000-000000000032", "bbbbbbbb-0000-0000-0000-000000000032")
SERVICE = jeton("service", None, "service_role")
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
MOTS = ("tarif", "taux_facture", "montant_facture", "instantane", "montant", "taux")

lectures_interdites = [
    ("/projets?select=tarif_vente_ht", "tarif de vente"),
    ("/projets?select=id,tarif_historique", "historique des tarifs"),
    ("/projets?select=id,tarif_reference,tarif_date_effet", "référence et date d'effet"),
    ("/projets?select=*", "« select=* » sur projets"),
    ("/projets?select=id&tarif_vente_ht=gt.0", "filtre sur le tarif"),
    ("/projets?select=id&order=tarif_vente_ht.desc", "tri sur le tarif"),
    ("/projets?select=id&tarif_historique=cs.%5B%7B%22tarif%22%3A80%7D%5D", "recherche dans l'historique des tarifs"),
    ("/temps?select=taux_facture", "taux facturé"),
    ("/temps?select=id&montant_facture_ht=gt.0", "filtre sur le montant facturé"),
    ("/temps?select=id&order=taux_facture", "tri sur le taux facturé"),
    ("/temps?select=*", "« select=* » sur temps"),
    ("/temps?select=id,factures(total_ht)", "jointure temps → factures"),
    ("/temps?select=id,projets(tarif_vente_ht)", "jointure temps → tarif du projet"),
    ("/factures?select=id", "factures"),
    ("/factures?select=*", "« select=* » sur factures"),
    ("/factures?select=id&total_ht=gt.0", "filtre sur les factures"),
]
for nom, j in (("Admin", ADMIN), ("Manager", MANAGER), ("Collaboratrice", LEA), ("Visiteur", None)):
    print(f"== {nom}")
    for chemin, libelle in lectures_interdites:
        s, r = appel(chemin, j)
        verifier(f"{libelle} : refusé", s in REFUS, f"HTTP {s}")
    for f, args in (("finance_calculer", {"p_client": None, "p_mois": None, "p_projets": None, "p_tva": None}),
                    ("finance_temps_concernes", {"p_projet": None, "p_date_effet": None}),
                    ("finance_tarif_a_date", {"p_historique": [], "p_date": "2026-01-01"})):
        s, r = appel(f"/rpc/{f}", j, "POST", args)
        verifier(f"fonction {f} : refusée", s in REFUS + (404,), f"HTTP {s}")

print("== Écritures (admin)")
s, r = appel("/factures", ADMIN, "POST", {"client_id": "33333333-3333-3333-3333-3333333333a1"})
verifier("créer une facture : refusé", s in REFUS, f"HTTP {s}")
s, r = appel("/factures?id=not.is.null", ADMIN, "PATCH", {"statut": "payee"})
verifier("changer le statut d'une facture : refusé", s in REFUS, f"HTTP {s}")
s, r = appel("/factures?id=not.is.null", ADMIN, "DELETE")
verifier("supprimer une facture : refusé", s in REFUS, f"HTTP {s}")
s, r = appel("/projets?nom=eq.Mission%20r%C3%A9gie", ADMIN, "PATCH", {"tarif_vente_ht": 1})
verifier("écrire un tarif : refusé", s in REFUS, f"HTTP {s}")
s, r = appel("/projets?nom=eq.Mission%20r%C3%A9gie", ADMIN, "PATCH", {"mode_facturation": "forfait"})
verifier("changer le mode de facturation : refusé", s in REFUS, f"HTTP {s}")
s, r = appel("/projets?nom=eq.Mission%20r%C3%A9gie", ADMIN, "PATCH", {"statut": "en_cours"},
             {"Prefer": "return=representation"})
verifier("réponse d'une écriture autorisée sans « select » : refusée (aucune colonne de tarif renvoyée)", s in REFUS, f"HTTP {s}")

print("== Lectures existantes des écrans (colonnes nommées) : intactes")
s, r = appel("/projets?select=id,nom,statut,client_id,devis_id,created_at", ADMIN)
verifier("admin : liste des projets", s == 200 and len(lignes(r)) >= 5, f"HTTP {s}, {len(lignes(r))} ligne(s)")
s, r = appel("/projets?select=id,nom,mode_facturation", MANAGER)
verifier("manager : projets et mode de facturation (pas un tarif)", s == 200 and len(lignes(r)) >= 5, f"HTTP {s}")
s, r = appel("/temps?select=id,collaborateur_id,projet_id,date_saisie,heures,commentaire,statut,facture_id,saisi_par,saisi_par_nom,saisi_le,valide_par_nom,valide_le,motif_derogation,historique", LEA)
verifier("collaboratrice : ses temps (écran « Mes temps »)", s == 200 and len(lignes(r)) > 0, f"HTTP {s}, {len(lignes(r))} ligne(s)")
evenements = [e for x in lignes(r) for e in (x.get("historique") or []) if e.get("action") == "facturation"]
verifier("historique d'un temps facturé : aucune clé de montant ni de tarif",
         len(evenements) > 0 and all(not any(m in k for k in e for m in MOTS) for e in evenements), f"{len(evenements)} événement(s)")
s, r = appel("/rh_projets_ouverts?select=*", LEA)
verifier("vue des projets ouverts : aucune donnée de facturation", s == 200 and all(set(x) == {"id", "nom", "statut", "client_nom"} for x in lignes(r)))

print("== Clé secrète (serveur, après exigerAdmin)")
s, r = appel("/factures?select=id,numero,total_ht", SERVICE)
verifier("le serveur lit les factures", s == 200 and len(lignes(r)) == 1, f"HTTP {s}")

print(f"\nBILAN : {sum(resultats)}/{len(resultats)} contrôles réussis")
