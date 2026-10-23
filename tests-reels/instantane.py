"""Empreinte des données réelles (nombre de lignes + somme de contrôle) des 13 tables et du bucket."""
import hashlib, json, os, ssl, sys, urllib.request
U = os.environ["NEXT_PUBLIC_SUPABASE_URL"]; S = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
CTX = ssl.create_default_context(cafile="/root/.ccr/ca-bundle.crt")
TABLES = ["clients","prospects","devis","devis_lignes","collaborateurs","projets","factures","temps",
          "relances","conges","notes_de_frais","compteurs","profiles"]
def get(chemin, methode="GET", corps=None):
    req = urllib.request.Request(U + chemin, method=methode, data=json.dumps(corps).encode() if corps else None,
        headers={"apikey": S, "Authorization": f"Bearer {S}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, context=CTX, timeout=20) as r: return json.loads(r.read())
res = {}
for t in TABLES:
    lignes = get(f"/rest/v1/{t}?select=*")
    lignes = [l for l in lignes if "exemple.invalid" not in json.dumps(l)]  # ignore les jetables
    res[t] = (len(lignes), hashlib.sha256(json.dumps(sorted(lignes, key=lambda x: json.dumps(x, sort_keys=True)), sort_keys=True).encode()).hexdigest()[:12])
res["bucket justificatifs"] = (len(get("/storage/v1/object/list/justificatifs", "POST", {"prefix": "", "limit": 1000})), "-")
json.dump(res, open(sys.argv[1], "w"))
for k, v in res.items(): print(f"  {k:22s} {v[0]:4d} ligne(s)  empreinte {v[1]}")
