"""Empreinte des données réelles (nombre de lignes + somme de contrôle) des 13 tables, de la 14e (relances_evenements,
si elle existe) et du bucket."""
import hashlib, json, os, ssl, sys, urllib.error, urllib.request
U = os.environ["NEXT_PUBLIC_SUPABASE_URL"]; S = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
CTX = ssl.create_default_context(cafile="/root/.ccr/ca-bundle.crt")
TABLES = ["clients","prospects","devis","devis_lignes","collaborateurs","projets","factures","temps",
          "relances","conges","notes_de_frais","compteurs","profiles"]
def get(chemin, methode="GET", corps=None):
    req = urllib.request.Request(U + chemin, method=methode, data=json.dumps(corps).encode() if corps else None,
        headers={"apikey": S, "Authorization": f"Bearer {S}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, context=CTX, timeout=20) as r: return json.loads(r.read())
res = {}
residus = 0
try:
    get("/rest/v1/relances_evenements?select=evenement_id&limit=1")
    TABLES.append("relances_evenements")
except urllib.error.HTTPError as e:
    if e.code != 404:
        raise
    res["relances_evenements"] = (0, "absente")
for t in TABLES:
    lignes = get(f"/rest/v1/{t}?select=*")
    jetables = [l for l in lignes if "exemple.invalid" in json.dumps(l) or "[ESSAI]" in json.dumps(l)]
    residus += len(jetables)  # comptés à part : un essai mal nettoyé ne doit jamais passer inaperçu
    lignes = [l for l in lignes if l not in jetables]
    res[t] = (len(lignes), hashlib.sha256(json.dumps(sorted(lignes, key=lambda x: json.dumps(x, sort_keys=True)), sort_keys=True).encode()).hexdigest()[:12])
res["résidus d'essai"] = (residus, "-")  # attendu : 0 en dehors d'un test en cours
res["bucket justificatifs"] = (len(get("/storage/v1/object/list/justificatifs", "POST", {"prefix": "", "limit": 1000})), "-")
json.dump(res, open(sys.argv[1], "w"))
for k, v in res.items(): print(f"  {k:22s} {v[0]:4d} ligne(s)  empreinte {v[1]}")
