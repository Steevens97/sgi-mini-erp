"""Temps existants en PRODUCTION, avant/après la migration RH (lecture seule, clé secrète).
- avant : enregistre les ANCIENNES colonnes de chaque temps (valeurs exactes) dans un fichier.
- apres : vérifie que ces colonnes sont inchangées, puis contrôle À PART les nouveaux champs :
          auteur et validation vides (rien d'inventé), un seul événement « antérieur au module RH ».
Usage : python3 -I tests-reels/verifier_temps_existants.py avant|apres <fichier.json>
"""
import json, os, ssl, sys, urllib.request

U = os.environ["NEXT_PUBLIC_SUPABASE_URL"]; S = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
CTX = ssl.create_default_context(cafile="/root/.ccr/ca-bundle.crt")
ANCIENNES = "id,collaborateur_id,projet_id,date_saisie,heures,commentaire,statut,facture_id,created_at"
NOUVEAUX = "id,saisi_par,saisi_par_nom,saisi_le,valide_par,valide_par_nom,valide_le,motif_derogation,historique"


def get(chemin):
    req = urllib.request.Request(U + chemin, headers={"apikey": S, "Authorization": f"Bearer {S}"})
    with urllib.request.urlopen(req, context=CTX, timeout=30) as r:
        return json.loads(r.read())


mode, fichier = sys.argv[1], sys.argv[2]
anciennes = {t["id"]: t for t in get(f"/rest/v1/temps?select={ANCIENNES}&order=id")}
if mode == "avant":
    json.dump(anciennes, open(fichier, "w"), ensure_ascii=False, indent=1)
    print(f"  {len(anciennes)} temps enregistrés (anciennes colonnes)")
    sys.exit(0)

reussis = []
def verifier(libelle, ok, detail=""):
    reussis.append(ok)
    print(f"  [{'OK ' if ok else 'ÉCHEC'}] {libelle}" + (f"  ({detail})" if detail else ""))

avant = json.load(open(fichier))
print("Anciennes colonnes :")
verifier("mêmes temps (aucun ajouté ni perdu)", set(avant) == set(anciennes), f"{len(avant)} → {len(anciennes)}")
for i, t in avant.items():
    verifier(f"temps du {t['date_saisie']} ({t['statut']}) : valeurs identiques", anciennes.get(i) == t)
print("Nouveaux champs (comparés séparément) :")
nouveaux = {t["id"]: t for t in get(f"/rest/v1/temps?select={NOUVEAUX}&id=in.({','.join(avant)})")}
for i, t in avant.items():
    n = nouveaux[i]
    h = n["historique"]
    verifier(f"temps du {t['date_saisie']} : auteur et validation vides, dérogation vide",
             all(n[k] is None for k in ("saisi_par", "saisi_par_nom", "saisi_le", "valide_par", "valide_par_nom", "valide_le", "motif_derogation")))
    verifier(f"temps du {t['date_saisie']} : un seul événement « antérieur au module RH », sans auteur, statut d'origine rappelé",
             len(h) == 1 and h[0]["action"] == "anterieur_au_module_rh" and h[0]["auteur"] is None and h[0]["auteur_nom"] is None
             and h[0]["motif"].endswith(f"Statut d'origine : {t['statut']}."))
print(f"\nBILAN : {sum(reussis)}/{len(reussis)} contrôles réussis")
