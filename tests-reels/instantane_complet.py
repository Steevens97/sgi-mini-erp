"""Empreinte COMPLÈTE des données réelles, sans rien exclure (éléments d'essai compris).
13 tables (colonnes d'origine uniquement, pour comparer avant/après une migration qui ajoute des
colonnes), comptes d'authentification, espaces de stockage et leurs fichiers. Lecture seule.
Les valeurs ne sont jamais affichées (taux horaires compris) : seulement des nombres et des empreintes.
Usage : python3 -I tests-reels/instantane_complet.py <fichier.json> [<fichier_avant.json> pour comparer]
"""
import hashlib, json, os, ssl, sys, urllib.request

U = os.environ["NEXT_PUBLIC_SUPABASE_URL"]; S = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
CTX = ssl.create_default_context(cafile="/root/.ccr/ca-bundle.crt")
COLONNES = {
    "clients": "id,nom,email_contact,telephone,adresse,created_at",
    "prospects": "id,nom,societe,email,telephone,source,statut,client_id,created_at",
    "devis": "id,prospect_id,numero,date_emission,statut,total_ht,tva,total_ttc,created_at",
    "devis_lignes": "id,devis_id,designation,quantite,prix_unitaire,montant_ht,created_at",
    "collaborateurs": "id,nom,prenom,email,poste,date_entree,manager_id,taux_horaire,solde_conges,created_at",
    "projets": "id,nom,client_id,devis_id,statut,created_at",
    "factures": "id,client_id,numero,date_emission,date_echeance,periode_debut,periode_fin,total_ht,tva,total_ttc,statut,date_envoi,created_at",
    "temps": "id,collaborateur_id,projet_id,date_saisie,heures,commentaire,statut,facture_id,created_at",
    "relances": "id,facture_id,date_envoi,canal,message,created_at",
    "conges": "id,collaborateur_id,type,date_debut,date_fin,nb_jours,motif,statut,valide_par,created_at",
    "notes_de_frais": "id,collaborateur_id,date_depense,montant,categorie,justificatif_url,statut,created_at",
    "compteurs": "cle,valeur",
    "profiles": "id,email,nom,role,collaborateur_id,created_at",
}


def get(chemin, methode="GET", corps=None):
    req = urllib.request.Request(U + chemin, method=methode, data=json.dumps(corps).encode() if corps is not None else None,
                                 headers={"apikey": S, "Authorization": f"Bearer {S}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, context=CTX, timeout=30) as r:
        return json.loads(r.read())


def empreinte(objets):
    return hashlib.sha256(json.dumps(sorted(objets, key=lambda x: json.dumps(x, sort_keys=True)), sort_keys=True).encode()).hexdigest()[:16]


res = {}
for t, cols in COLONNES.items():
    lignes = get(f"/rest/v1/{t}?select={cols}")
    res[f"table {t}"] = [len(lignes), empreinte(lignes)]
comptes = [{"id": u["id"], "email": u["email"], "banni": u.get("banned_until"), "meta": u.get("app_metadata")}
           for u in get("/auth/v1/admin/users?per_page=1000")["users"]]
res["comptes"] = [len(comptes), empreinte(comptes)]
res["comptes (emails)"] = [len(comptes), ", ".join(sorted(c["email"] for c in comptes))]
seaux = get("/storage/v1/bucket")
res["espaces de stockage"] = [len(seaux), ", ".join(sorted(f"{b['id']}({'public' if b['public'] else 'privé'})" for b in seaux))]
for b in seaux:
    objets = get(f"/storage/v1/object/list/{b['id']}", "POST", {"prefix": "", "limit": 1000})
    res[f"fichiers {b['id']}"] = [len(objets), empreinte([o["name"] for o in objets])]
json.dump(res, open(sys.argv[1], "w"), ensure_ascii=False, indent=1)
avant = json.load(open(sys.argv[2])) if len(sys.argv) > 2 else None
for k, v in res.items():
    if avant is None:
        print(f"  {k:24s} {v[0]:4d}  {v[1]}")
    else:
        a = avant.get(k)
        print(f"  [{'identique' if a == v else 'DIFFÉRENT'}] {k:24s} {v[0]:4d}  {v[1]}" + ("" if a == v else f"   (avant : {a})"))
if avant is not None:
    for k in avant:
        if k not in res:
            print(f"  [DISPARU] {k}  (avant : {avant[k]})")
