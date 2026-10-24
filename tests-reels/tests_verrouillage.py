"""Tests du verrouillage par appels DIRECTS à Supabase (sans passer par l'application).
Comptes jetables en @exemple.invalid, supprimés à la fin. Ne touche jamais sgi@gmx.fr.
Usage : python3 -I tests-reels/tests_verrouillage.py
"""
import json, os, ssl, time, urllib.error, urllib.request

U = os.environ["NEXT_PUBLIC_SUPABASE_URL"]
ANON = os.environ["NEXT_PUBLIC_SUPABASE_ANON_KEY"]
SECRET = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
CTX = ssl.create_default_context(cafile="/root/.ccr/ca-bundle.crt")
DOMAINE = "@exemple.invalid"
MDP = "Verrou-Jetable-2026!"
LEA, BRUNO, CHLOE = (
    "22222222-2222-2222-2222-222222222221",
    "22222222-2222-2222-2222-222222222222",
    "22222222-2222-2222-2222-222222222223",
)
ONZE = ["clients", "prospects", "devis", "devis_lignes", "projets", "factures", "temps",
        "relances", "conges", "notes_de_frais", "compteurs"]
REFUS = (401, 403)
# Module Commercial (migration 20261024100000) : admin et manager sur prospects, devis, lignes ;
# clients en lecture admin/manager, écriture admin ; collaborateur par les vues de consultation.
# Les autres tables (modules encore fermés) restent « admin seulement ».
COMMERCIAL = ["prospects", "devis", "devis_lignes"]
FERMEES = ["projets", "factures", "temps", "relances", "conges", "notes_de_frais", "compteurs"]
VUES = {"commercial_prospects": ("prospects", "id,nom,societe,source,statut,essai,created_at"),
        "commercial_devis": ("devis", "id,prospect_id,numero,statut,total_ht,tva,total_ttc,essai,type_mission"),
        "commercial_devis_lignes": ("devis_lignes", "id,devis_id,designation,quantite,prix_unitaire,montant_ht")}
CACHEES = {"commercial_prospects": ["email", "telephone", "adresse", "client_id"],
           "commercial_devis": ["instantane_emission", "pdf_chemin", "criteres_tva", "envoi_destinataire", "emis_par"]}
DEPLOYE = False  # renseigné au démarrage d'après migrations_appliquees()
RH = False       # module RH (migration 20261025100000) : projets et temps sortent des modules fermés
ABSENCES = False  # module Absences (migration 20261028100000) : congés et notes lisibles par soi, l'équipe directe du
                  # manager et l'admin ; soldes seulement par la vue absences_soldes ; bucket justificatifs sans accès direct
FINANCE = False  # module Finance (migration 20261027100000) : factures sans aucun droit pour les jetons ;
                 # projets et temps lisibles seulement par colonnes nommées (tarifs, taux et montants facturés exclus)
COLONNES = {"projets": "id,nom,client_id,devis_id,statut,created_at,mode_facturation",
            "temps": "id,collaborateur_id,projet_id,date_saisie,heures,commentaire,statut,facture_id,created_at,saisi_par,"
                     "saisi_par_nom,saisi_le,valide_par,valide_par_nom,valide_le,motif_derogation,historique"}


def sel(t):
    """Sélection utilisée par les écrans : « * », ou les colonnes nommées quand le module Finance protège des colonnes."""
    return COLONNES[t] if FINANCE and t in COLONNES else "*"


def appel(methode, chemin, jeton=None, corps=None, brut=None, entetes=None, cle=ANON):
    h = {"apikey": cle, "Authorization": f"Bearer {jeton or cle}"}
    if brut is None:
        h["Content-Type"] = "application/json"
    h.update(entetes or {})
    donnees = brut if brut is not None else (json.dumps(corps).encode() if corps is not None else None)
    req = urllib.request.Request(U + chemin, method=methode, headers=h, data=donnees)
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=20) as r:
            t = r.read().decode()
            return r.status, (json.loads(t) if t else None)
    except urllib.error.HTTPError as e:
        t = e.read().decode()
        try:
            return e.code, json.loads(t)
        except ValueError:
            return e.code, t


def secret(methode, chemin, corps=None):
    return appel(methode, chemin, corps=corps, cle=SECRET, entetes={"Prefer": "return=representation"})


resultats = []


def verifier(libelle, ok, detail=""):
    resultats.append(ok)
    print(f"  [{'OK ' if ok else 'ÉCHEC'}] {libelle}" + (f"  ({detail})" if detail else ""))


def message(r):
    return (r.get("message") or r.get("msg") or r.get("error") or str(r))[:70] if isinstance(r, dict) else str(r)[:70]


def lignes(r):
    return r if isinstance(r, list) else []


T = int(time.time())


def creer(nom, role="collaborateur", collab=None, provisoire=False):
    email = f"jetable-{nom}-{T}{DOMAINE}"
    corps = {"email": email, "password": MDP, "email_confirm": True}
    if provisoire:
        corps["app_metadata"] = {"doit_changer_mot_de_passe": True}
    s, u = secret("POST", "/auth/v1/admin/users", corps)
    assert s == 200, (s, u)
    s, _ = secret("PATCH", f"/rest/v1/profiles?id=eq.{u['id']}", {"role": role, "collaborateur_id": collab})
    assert s in (200, 204), s
    return {"id": u["id"], "email": email}


def jeton(compte):
    s, r = appel("POST", "/auth/v1/token?grant_type=password", corps={"email": compte["email"], "password": MDP})
    assert s == 200, (s, r)
    return r["access_token"]


def compter_tout():
    return {t: len(lignes(secret("GET", f"/rest/v1/{t}?select=*")[1])) for t in ONZE}


def voit_quelque_chose(j):
    """Somme des lignes visibles sur profiles, collaborateurs et les 11 tables."""
    total = 0
    for t in ["profiles"] + ONZE:
        total += len(lignes(appel("GET", f"/rest/v1/{t}?select={sel(t)}", j)[1]))
    total += len(lignes(appel("GET", "/rest/v1/collaborateurs?select=id", j)[1]))
    if DEPLOYE:
        for v in VUES:
            total += len(lignes(appel("GET", f"/rest/v1/{v}?select=id", j)[1]))
    if RH:
        total += len(lignes(appel("GET", "/rest/v1/rh_projets_ouverts?select=id", j)[1]))
    if ABSENCES:
        total += len(lignes(appel("GET", "/rest/v1/absences_soldes?select=id", j)[1]))
    return total


def essais_ecriture_refusee(j, qui, moi_collab, commercial=False):
    s, projets = secret("GET", "/rest/v1/projets?select=id&limit=1")
    essais = {
        "clients": {"nom": "Intrus"},
        **({} if commercial else {"prospects": {"nom": "Intrus"}}),
        "compteurs": {"cle": "intrus", "valeur": 999},
        "notes_de_frais": {"collaborateur_id": moi_collab or LEA, "montant": 1},
        "temps": {"collaborateur_id": moi_collab or LEA, "projet_id": projets[0]["id"] if projets else None, "heures": 1},
    }
    for table, corps in essais.items():
        s, r = appel("POST", f"/rest/v1/{table}", j, corps)
        verifier(f"{qui} : création dans {table} refusée", s in REFUS, f"HTTP {s}")
    for table, filtre in (("clients", "id=not.is.null"), ("projets", "id=not.is.null"), ("compteurs", "cle=not.is.null")):
        s, r = appel("PATCH", f"/rest/v1/{table}?{filtre}", j, {"nom": "Pirate"} if table != "compteurs" else {"valeur": 0},
                     entetes={"Prefer": "return=representation"})
        verifier(f"{qui} : modification de {table} sans effet", lignes(r) == [], f"HTTP {s}")
        s, r = appel("DELETE", f"/rest/v1/{table}?{filtre}", j, entetes={"Prefer": "return=representation"})
        verifier(f"{qui} : suppression dans {table} sans effet", lignes(r) == [], f"HTTP {s}")


def bucket_devis_ferme(j, qui):
    s, r = appel("POST", "/storage/v1/object/list/devis", j, {"prefix": ""})
    verifier(f"{qui} : bucket devis, rien de visible", lignes(r) == [], f"HTTP {s}")
    s, r = appel("POST", f"/storage/v1/object/devis/jetable-{qui}-{T}.pdf", j, brut=b"%PDF-1.4 essai",
                 entetes={"Content-Type": "application/pdf"})
    verifier(f"{qui} : bucket devis, dépôt refusé (clé secrète seulement)", s >= 400, f"HTTP {s}")


def main():
    global DEPLOYE, RH, FINANCE, ABSENCES, FERMEES
    s, versions = secret("POST", "/rest/v1/rpc/migrations_appliquees", {})
    DEPLOYE = "20261024100000" in (versions or [])
    RH = "20261025100000" in (versions or [])
    FINANCE = "20261027100000" in (versions or [])
    ABSENCES = "20261028100000" in (versions or [])
    if RH:
        FERMEES = [t for t in FERMEES if t not in ("projets", "temps")]
    if ABSENCES:
        FERMEES = [t for t in FERMEES if t not in ("conges", "notes_de_frais")]
    print("Module Commercial déployé :", "oui" if DEPLOYE else "non", "| module RH :", "oui" if RH else "non",
          "| module Finance :", "oui" if FINANCE else "non", "| module Absences :", "oui" if ABSENCES else "non")
    avant = compter_tout()
    print("Lignes des 11 tables (clé secrète) :", avant)

    print("\n== 1. Visiteur anonyme (clé publique seule)")
    for t in ["profiles", "collaborateurs"] + ONZE:
        s, r = appel("GET", f"/rest/v1/{t}?select=*")
        verifier(f"lecture {t} refusée", s in REFUS, f"HTTP {s}")
    s, r = appel("POST", "/rest/v1/clients", corps={"nom": "Intrus"})
    verifier("création d'un client refusée", s in REFUS, f"HTTP {s}")
    for f in ("mon_role", "est_admin", "acces_actif"):
        s, r = appel("POST", f"/rest/v1/rpc/{f}", corps={})
        verifier(f"{f}() refusée", s in REFUS, f"HTTP {s}")
    s, r = appel("POST", "/rest/v1/rpc/taux_horaires_collaborateurs", corps={})
    verifier("taux_horaires_collaborateurs() n'existe plus", s == 404, f"HTTP {s}")
    s, r = appel("POST", "/rest/v1/rpc/prochain_numero", corps={"p_cle": "essai_securite", "p_prefixe": "ESSAI"})
    verifier("prochain_numero() refusée", s in REFUS, f"HTTP {s} : {message(r)}")
    s, r = appel("POST", "/storage/v1/object/list/justificatifs", corps={"prefix": ""})
    verifier("bucket justificatifs : rien de visible", lignes(r) == [], f"HTTP {s}")
    if DEPLOYE:
        for v in VUES:
            s, r = appel("GET", f"/rest/v1/{v}?select=id")
            verifier(f"vue {v} refusée", s in REFUS, f"HTTP {s}")
        bucket_devis_ferme(None, "visiteur")

    print("\n== Préparation des comptes jetables")
    c = {
        "collab": creer("collab", "collaborateur", LEA),
        "manager": creer("manager", "manager", BRUNO),
        "admin": creer("admin", "admin"),
        "admin_provisoire": creer("admin-provisoire", "admin", provisoire=True),
    }
    print("  4 comptes créés :", ", ".join(x["email"] for x in c.values()))
    j = {k: jeton(v) for k, v in c.items()}

    print("\n== 2. Collaborateur (Léa) : tables fermées" + (" (sauf ses propres temps)" if RH else ""))
    for t in ONZE:
        s, r = appel("GET", f"/rest/v1/{t}?select={sel(t)}", j["collab"])
        if (RH and t == "temps") or (ABSENCES and t in ("conges", "notes_de_frais")):
            siens = len(lignes(secret("GET", f"/rest/v1/{t}?select=id&collaborateur_id=eq.{LEA}")[1]))
            verifier(f"{t} : uniquement les siens", len(lignes(r)) == siens and all(x["collaborateur_id"] == LEA for x in lignes(r)),
                     f"{len(lignes(r))}/{siens} ligne(s), réel : {avant[t]}")
        else:
            verifier(f"{t} : aucune ligne lue", lignes(r) == [], f"HTTP {s}, réel : {avant[t]} ligne(s)")
    if RH:
        ouverts = len(lignes(secret("GET", "/rest/v1/projets?select=id&statut=eq.en_cours")[1]))
        s, r = appel("GET", "/rest/v1/rh_projets_ouverts?select=*", j["collab"])
        verifier("projets ouverts : visibles par la vue, nom du client seulement",
                 len(lignes(r)) == ouverts and all(set(x) == {"id", "nom", "statut", "client_nom"} for x in lignes(r)), f"{len(lignes(r))}/{ouverts}")
        s, r = appel("GET", "/rest/v1/rh_projets_ouverts?select=id,clients(email_contact)", j["collab"])
        verifier("projets ouverts : jointure vers les coordonnées client refusée", s >= 400, f"HTTP {s}")
        siens = lignes(secret("GET", f"/rest/v1/temps?select=id&collaborateur_id=eq.{LEA}&limit=1")[1])
        if siens:
            s, r = appel("PATCH", f"/rest/v1/temps?id=eq.{siens[0]['id']}", j["collab"], {"statut": "valide"})
            verifier("temps : se valider directement refusé", s in REFUS, f"HTTP {s}")
        s, r = appel("POST", "/rest/v1/rpc/rh_changer_statut_temps", j["collab"],
                     {"p_auteur": None, "p_temps_ids": None, "p_action": None, "p_motif": None})
        verifier("temps : fonction de service refusée", s in REFUS, f"HTTP {s}")
    essais_ecriture_refusee(j["collab"], "collaborateur", LEA)
    s, r = appel("POST", "/rest/v1/rpc/prochain_numero", j["collab"], {"p_cle": "essai_securite", "p_prefixe": "ESSAI"})
    verifier("prochain_numero() refusée", s >= 400, f"HTTP {s} : {message(r)}")
    if DEPLOYE:
        print("  -- consultation commerciale par les vues")
        for v, (table, colonnes) in VUES.items():
            s, r = appel("GET", f"/rest/v1/{v}?select={colonnes}", j["collab"])
            verifier(f"{v} : lisible avec ses colonnes explicites", s == 200 and len(lignes(r)) == avant[table],
                     f"HTTP {s}, {len(lignes(r))}/{avant[table]}")
            s, r = appel("POST", f"/rest/v1/{v}", j["collab"], {"nom": "Intrus"} if table == "prospects" else {})
            verifier(f"{v} : écriture refusée", s >= 400, f"HTTP {s}")
        for v, colonnes in CACHEES.items():
            for col in colonnes:
                s, r = appel("GET", f"/rest/v1/{v}?select=id,{col}", j["collab"])
                verifier(f"{v} : colonne {col} absente", s >= 400, f"HTTP {s}")
        s, r = appel("GET", "/rest/v1/commercial_devis?select=id,prospects(email)", j["collab"])
        verifier("vue devis : jointure vers les coordonnées du prospect refusée", s >= 400 or all(
            not x.get("prospects") for x in lignes(r)), f"HTTP {s}")
        s, prospects = secret("GET", "/rest/v1/prospects?select=id&limit=1")
        s, r = appel("POST", "/rest/v1/devis", j["collab"], {"prospect_id": prospects[0]["id"]} if prospects else {})
        verifier("collaborateur : création d'un devis refusée", s in REFUS, f"HTTP {s}")
        bucket_devis_ferme(j["collab"], "collaborateur")

    print("\n== 3. Taux horaire protégé au niveau des données")
    for qui in ("collab", "manager", "admin"):
        s, r = appel("GET", "/rest/v1/collaborateurs?select=taux_horaire", j[qui])
        verifier(f"{qui} : select=taux_horaire refusé", s in REFUS, f"HTTP {s} : {message(r)}")
        s, r = appel("GET", "/rest/v1/collaborateurs?select=*", j[qui])
        verifier(f"{qui} : select=* refusé (contiendrait le taux)", s in REFUS, f"HTTP {s}")
        s, r = appel("GET", "/rest/v1/collaborateurs?select=id&taux_horaire=gt.90", j[qui])
        verifier(f"{qui} : filtre sur le taux refusé (pas de déduction)", s in REFUS, f"HTTP {s}")
        s, r = appel("GET", "/rest/v1/collaborateurs?select=id&order=taux_horaire", j[qui])
        verifier(f"{qui} : tri par taux refusé", s in REFUS, f"HTTP {s}")
    s, r = appel("GET", "/rest/v1/collaborateurs?select=id,nom", j["collab"])
    verifier("collaborateur : sa fiche reste lisible sans le taux", [x["id"] for x in lignes(r)] == [LEA], f"{len(lignes(r))} fiche(s)")
    s, r = appel("GET", "/rest/v1/collaborateurs?select=id,nom", j["manager"])
    verifier("manager : toutes les fiches lisibles sans le taux", len(lignes(r)) >= 3, f"{len(lignes(r))} fiche(s)")
    for qui in ("collab", "manager", "admin"):
        s, r = appel("POST", "/rest/v1/rpc/taux_horaires_collaborateurs", j[qui], {})
        verifier(f"{qui} : aucune fonction de taux appelable avec son jeton", s >= 400, f"HTTP {s} : {message(r)}")
    s, r = secret("GET", "/rest/v1/collaborateurs?select=id,taux_horaire")
    verifier("côté serveur, la clé secrète lit les taux", len(lignes(r)) >= 3, f"{len(lignes(r))} taux")
    s, r = appel("PATCH", f"/rest/v1/collaborateurs?id=eq.{LEA}", j["collab"], {"taux_horaire": 999}, entetes={"Prefer": "return=minimal"})
    s2, v = secret("GET", f"/rest/v1/collaborateurs?id=eq.{LEA}&select=taux_horaire")
    verifier("collaborateur : ne peut pas changer son taux", v[0]["taux_horaire"] != 999, f"HTTP {s}, taux = {v[0]['taux_horaire']}")

    if not DEPLOYE:
        print("\n== 4. Manager : 11 tables fermées")
        for t in ONZE:
            s, r = appel("GET", f"/rest/v1/{t}?select=*", j["manager"])
            verifier(f"{t} : aucune ligne lue", lignes(r) == [], f"HTTP {s}")
        essais_ecriture_refusee(j["manager"], "manager", BRUNO)
    else:
        print("\n== 4. Manager : Commercial ouvert, modules encore fermés")
        for t in COMMERCIAL + ["clients"] + (["projets", "temps"] if RH else []):
            s, r = appel("GET", f"/rest/v1/{t}?select={sel(t)}", j["manager"])
            verifier(f"{t} : lisible en entier", s == 200 and len(lignes(r)) == avant[t], f"{len(lignes(r))}/{avant[t]}")
        if ABSENCES:
            equipe = [BRUNO] + [x["id"] for x in lignes(secret("GET", f"/rest/v1/collaborateurs?select=id&manager_id=eq.{BRUNO}")[1])]
            for t in ("conges", "notes_de_frais"):
                attendu = len(lignes(secret("GET", f"/rest/v1/{t}?select=id&collaborateur_id=in.({','.join(equipe)})")[1]))
                s, r = appel("GET", f"/rest/v1/{t}?select=id,collaborateur_id", j["manager"])
                verifier(f"{t} : lui et son équipe directe seulement", s == 200 and len(lignes(r)) == attendu
                         and all(x["collaborateur_id"] in equipe for x in lignes(r)), f"{len(lignes(r))}/{attendu}, réel : {avant[t]}")
        for t in FERMEES:
            s, r = appel("GET", f"/rest/v1/{t}?select=*", j["manager"])
            verifier(f"{t} (module fermé) : aucune ligne lue", lignes(r) == [], f"HTTP {s}")
        essais_ecriture_refusee(j["manager"], "manager", BRUNO, commercial=True)
        if RH:
            un = lignes(secret("GET", "/rest/v1/temps?select=id&limit=1")[1])
            if un:
                s, r = appel("PATCH", f"/rest/v1/temps?id=eq.{un[0]['id']}", j["manager"], {"statut": "valide"})
                verifier("manager : lecture de tous les temps ≠ écriture (validation directe refusée)", s in REFUS, f"HTTP {s}")
            s, r = appel("POST", "/rest/v1/projets", j["manager"], {"nom": "Intrus"})
            verifier("manager : création de projet refusée (admin seulement)", s in REFUS, f"HTTP {s}")
        rien = "id=eq.00000000-0000-0000-0000-000000000000"
        for table, corps, libelle in (
            ("devis", {"numero": "PIRATE"}, "numéro"), ("devis", {"statut": "accepte"}, "statut"),
            ("devis", {"total_ttc": 0}, "total"), ("devis", {"pdf_statut": "disponible"}, "état du PDF"),
            ("devis", {"essai": True}, "indicateur d'essai"), ("prospects", {"essai": True}, "indicateur d'essai"),
            ("devis_lignes", {"montant_ht": 0}, "montant de ligne")):
            s, r = appel("PATCH", f"/rest/v1/{table}?{rien}", j["manager"], corps)
            verifier(f"manager : {table}.{list(corps)[0]} ({libelle}) non modifiable", s in REFUS, f"HTTP {s}")
        s, r = appel("POST", "/rest/v1/prospects", j["manager"], {"nom": "Intrus", "essai": True})
        verifier("manager : création d'un prospect d'essai refusée (clé secrète seulement)", s in REFUS, f"HTTP {s}")
        s, r = appel("POST", "/rest/v1/devis", j["manager"], {"prospect_id": None, "statut": "accepte"})
        verifier("manager : création d'un devis déjà accepté refusée", s in REFUS, f"HTTP {s}")
        bucket_devis_ferme(j["manager"], "manager")

    if FINANCE:
        print("\n== 4b. Finance : tarifs, montants facturés et factures illisibles pour TOUS les jetons")
        interdits = [("projets?select=tarif_vente_ht", "tarif de vente"), ("projets?select=id,tarif_historique", "historique des tarifs"),
                     ("projets?select=*", "select=* sur projets"), ("projets?select=id&tarif_vente_ht=gt.0", "filtre sur le tarif"),
                     ("projets?select=id&order=tarif_date_effet", "tri sur la date d'effet"), ("temps?select=taux_facture", "taux facturé"),
                     ("temps?select=id&montant_facture_ht=gt.0", "filtre sur le montant facturé"), ("temps?select=*", "select=* sur temps"),
                     ("factures?select=id", "factures"), ("factures?select=*", "select=* sur factures")]
        for qui in ("collab", "manager", "admin"):
            for chemin, libelle in interdits:
                s, r = appel("GET", f"/rest/v1/{chemin}", j[qui])
                verifier(f"{qui} : {libelle} refusé", s in REFUS, f"HTTP {s}")
            for f in ("finance_calculer", "finance_emettre_facture", "finance_confirmer_tarif", "supprimer_essais_finance"):
                s, r = appel("POST", f"/rest/v1/rpc/{f}", j[qui], {})
                verifier(f"{qui} : fonction {f} refusée", s >= 400, f"HTTP {s}")
            s, r = appel("POST", "/rest/v1/factures", j[qui], {"client_id": None})
            verifier(f"{qui} : création de facture refusée", s in REFUS, f"HTTP {s}")
            s, r = appel("POST", "/storage/v1/object/list/factures", j[qui], {"prefix": ""})
            verifier(f"{qui} : bucket factures, rien de visible", lignes(r) == [], f"HTTP {s}")
            s, r = appel("POST", f"/storage/v1/object/factures/jetable-{qui}-{T}.pdf", j[qui], brut=b"%PDF-1.4 essai",
                         entetes={"Content-Type": "application/pdf"})
            verifier(f"{qui} : bucket factures, dépôt refusé", s >= 400, f"HTTP {s}")
        s, r = appel("POST", "/storage/v1/object/list/factures", None, {"prefix": ""})
        verifier("visiteur : bucket factures, rien de visible", lignes(r) == [], f"HTTP {s}")
        s, r = secret("GET", "/rest/v1/factures?select=id,numero")
        verifier("côté serveur (clé secrète, après exigerAdmin) : factures lisibles", s == 200, f"HTTP {s}, {len(lignes(r))} facture(s)")

    if ABSENCES:
        print("\n== 4c. Absences : soldes confidentiels, aucune écriture avec un jeton")
        for qui in ("collab", "manager", "admin"):
            for chemin, libelle in (("collaborateurs?select=solde_conges", "solde de congés payés"),
                                    ("collaborateurs?select=id,solde_rtt", "solde RTT"),
                                    ("collaborateurs?select=id,historique_soldes", "historique des soldes"),
                                    ("collaborateurs?select=id&solde_conges=gt.0", "filtre sur le solde"),
                                    ("collaborateurs?select=id&order=solde_conges", "tri sur le solde")):
                s, r = appel("GET", f"/rest/v1/{chemin}", j[qui])
                verifier(f"{qui} : {libelle} illisible dans les fiches", s in REFUS or s == 400, f"HTTP {s}")
            for t, corps in (("conges", {"collaborateur_id": LEA, "date_debut": "2030-01-02", "date_fin": "2030-01-02"}),
                             ("notes_de_frais", {"collaborateur_id": LEA, "montant": 1})):
                s, r = appel("POST", f"/rest/v1/{t}", j[qui], corps)
                verifier(f"{qui} : création directe dans {t} refusée", s in REFUS, f"HTTP {s}")
                s, r = appel("PATCH", f"/rest/v1/{t}?id=not.is.null", j[qui], {"statut": "validee"}, entetes={"Prefer": "return=representation"})
                verifier(f"{qui} : décision directe dans {t} refusée", s in REFUS and lignes(r) == [], f"HTTP {s}")
            s, r = appel("PATCH", f"/rest/v1/collaborateurs?id=eq.{LEA}", j[qui], {"solde_conges": 99}, entetes={"Prefer": "return=minimal"})
            verifier(f"{qui} : solde non modifiable directement", s in REFUS, f"HTTP {s}")
            for f in ("abs_demander_conge", "abs_decider_conge", "abs_ajuster_solde", "abs_creer_note", "abs_declarer_remboursement",
                      "abs_fichiers_orphelins", "supprimer_essais_absences"):
                s, r = appel("POST", f"/rest/v1/rpc/{f}", j[qui], {})
                verifier(f"{qui} : fonction {f} refusée", s >= 400, f"HTTP {s}")
        s, r = appel("GET", "/rest/v1/absences_soldes?select=id", j["collab"])
        verifier("collaboratrice : vue des soldes = sa seule fiche", [x["id"] for x in lignes(r)] == [LEA], f"{len(lignes(r))} ligne(s)")
        equipe = sorted([BRUNO] + [x["id"] for x in lignes(secret("GET", f"/rest/v1/collaborateurs?select=id&manager_id=eq.{BRUNO}")[1])])
        s, r = appel("GET", "/rest/v1/absences_soldes?select=id", j["manager"])
        verifier("manager : vue des soldes = lui et son équipe directe", sorted(x["id"] for x in lignes(r)) == equipe, f"{len(lignes(r))}/{len(equipe)}")
        toutes = len(lignes(secret("GET", "/rest/v1/collaborateurs?select=id")[1]))
        s, r = appel("GET", "/rest/v1/absences_soldes?select=id,solde_conges,solde_rtt,droits_rtt_renseignes", j["admin"])
        verifier("admin : vue globale des soldes", len(lignes(r)) == toutes, f"{len(lignes(r))}/{toutes}")
        s, r = appel("GET", "/rest/v1/absences_soldes?select=id", None)
        verifier("visiteur : vue des soldes refusée", s in REFUS, f"HTTP {s}")
        s, r = appel("GET", "/rest/v1/absences_soldes?select=id", j["admin_provisoire"])
        verifier("admin provisoire : vue des soldes vide", lignes(r) == [], f"HTTP {s}")

    print("\n== 5. Admin actif : accès complet" + (" (factures : écrans serveur seulement)" if FINANCE else ""))
    for t in ONZE:
        s, r = appel("GET", f"/rest/v1/{t}?select={sel(t)}", j["admin"])
        if FINANCE and t == "factures":
            verifier("factures : aucun accès par jeton, même admin (lecture serveur avec la clé secrète)", s in REFUS, f"HTTP {s}")
            continue
        verifier(f"{t} : tout est lisible", len(lignes(r)) == avant[t], f"{len(lignes(r))}/{avant[t]}")
    s, r = appel("POST", "/rest/v1/clients", j["admin"], {"nom": f"Jetable-client-{T}"}, entetes={"Prefer": "return=representation"})
    ok = s == 201 and len(lignes(r)) == 1
    verifier("création d'un client de test", ok, f"HTTP {s}")
    if ok:
        s, r2 = appel("DELETE", f"/rest/v1/clients?id=eq.{r[0]['id']}", j["admin"], entetes={"Prefer": "return=representation"})
        verifier("suppression de ce client de test", len(lignes(r2)) == 1, f"HTTP {s}")
    s, r = appel("POST", "/rest/v1/rpc/prochain_numero", j["admin"], {"p_cle": "essai_securite", "p_prefixe": "ESSAI"})
    verifier("prochain_numero() refusée même à l'admin (clé secrète seulement)", s in REFUS, f"HTTP {s} : {message(r)}")
    nom_fichier = f"jetable-{T}.txt"
    s, r = appel("POST", f"/storage/v1/object/justificatifs/{nom_fichier}", j["collab"], brut=b"essai", entetes={"Content-Type": "text/plain"})
    verifier("bucket : dépôt par un collaborateur refusé", s >= 400, f"HTTP {s}")
    if ABSENCES:
        # Module Absences : plus AUCUN accès direct au bucket, même pour l'admin (dépôt par lien signé du serveur).
        for qui in ("admin", "manager"):
            s, r = appel("POST", f"/storage/v1/object/justificatifs/{nom_fichier}", j[qui], brut=b"%PDF-1.4 essai",
                         entetes={"Content-Type": "application/pdf"})
            verifier(f"bucket justificatifs : dépôt direct par {qui} refusé (serveur seulement)", s >= 400, f"HTTP {s}")
            s, r = appel("POST", "/storage/v1/object/list/justificatifs", j[qui], {"prefix": ""})
            verifier(f"bucket justificatifs : {qui} ne liste rien directement", lignes(r) == [], f"HTTP {s}")
        s, r = secret("POST", "/storage/v1/object/list/justificatifs", {"prefix": ""})
        verifier("bucket justificatifs : aucun fichier déposé par ces essais", not any(o["name"].startswith("jetable-") for o in lignes(r)))
    else:
        s, r = appel("POST", f"/storage/v1/object/justificatifs/{nom_fichier}", j["admin"], brut=b"essai", entetes={"Content-Type": "text/plain"})
        verifier("bucket : dépôt par l'admin accepté", s == 200, f"HTTP {s}")
        s, r = appel("POST", "/storage/v1/object/list/justificatifs", j["collab"], {"prefix": ""})
        verifier("bucket : le collaborateur ne voit pas le fichier", lignes(r) == [], f"{len(lignes(r))} fichier(s)")
        s, r = appel("DELETE", "/storage/v1/object/justificatifs", j["collab"], {"prefixes": [nom_fichier]})
        verifier("bucket : suppression par un collaborateur sans effet", lignes(r) == [], f"HTTP {s}")
        s, r = appel("DELETE", "/storage/v1/object/justificatifs", j["admin"], {"prefixes": [nom_fichier]})
        verifier("bucket : suppression par l'admin", s == 200 and len(lignes(r)) == 1, f"HTTP {s}")
    if DEPLOYE:
        bucket_devis_ferme(j["admin"], "admin")

    print("\n== 6. Admin devant changer son mot de passe (jeton valide)")
    verifier("ne voit rien du tout", voit_quelque_chose(j["admin_provisoire"]) == 0)
    s, r = appel("POST", "/rest/v1/rpc/est_admin", j["admin_provisoire"], {})
    verifier("est_admin() = faux", r is False, repr(r))
    s, r = appel("POST", "/rest/v1/clients", j["admin_provisoire"], {"nom": "Intrus"})
    verifier("création refusée", s in REFUS, f"HTTP {s}")
    s, r = appel("PATCH", f"/rest/v1/profiles?id=eq.{c['collab']['id']}", j["admin_provisoire"], {"role": "admin"},
                 entetes={"Prefer": "return=representation"})
    verifier("ne peut pas attribuer de rôle", lignes(r) == [], f"HTTP {s}")
    for f in ("mon_role", "mon_collaborateur_id"):
        s, r = appel("POST", f"/rest/v1/rpc/{f}", j["admin_provisoire"], {})
        verifier(f"{f}() ne renvoie rien", r is None, f"HTTP {s}, {r!r}")
    s, r = appel("POST", "/storage/v1/object/justificatifs/provisoire.txt", j["admin_provisoire"], brut=b"x",
                 entetes={"Content-Type": "text/plain"})
    verifier("stockage : dépôt refusé", s >= 400, f"HTTP {s}")
    s, r = appel("POST", "/storage/v1/object/list/justificatifs", j["admin_provisoire"], {"prefix": ""})
    verifier("stockage : rien de visible", lignes(r) == [], f"HTTP {s}")
    secret("PUT", f"/auth/v1/admin/users/{c['admin_provisoire']['id']}", {"app_metadata": {"doit_changer_mot_de_passe": False}})
    s, r = appel("POST", "/rest/v1/rpc/est_admin", j["admin_provisoire"], {})
    verifier("après levée de l'obligation, le même jeton redevient admin", r is True, repr(r))

    print("\n== 7. Anciens jetons : révocation, déconnexion, réinitialisation, blocage")
    scenarios = [
        ("révocation (compte supprimé) d'un admin", "admin", None,
         lambda x: secret("DELETE", f"/auth/v1/admin/users/{x['id']}")),
        ("révocation (compte supprimé) d'un collaborateur", "collaborateur", CHLOE,
         lambda x: secret("DELETE", f"/auth/v1/admin/users/{x['id']}")),
        ("déconnexion", "collaborateur", None, None),
        ("réinitialisation du mot de passe par un admin", "collaborateur", None,
         lambda x: secret("PUT", f"/auth/v1/admin/users/{x['id']}",
                          {"password": "Autre-Verrou-2026!", "app_metadata": {"doit_changer_mot_de_passe": True}})),
        ("compte bloqué (banni)", "collaborateur", None,
         lambda x: secret("PUT", f"/auth/v1/admin/users/{x['id']}", {"ban_duration": "24h"})),
    ]
    for i, (libelle, role, fiche, action) in enumerate(scenarios):
        compte = creer(f"ancien-jeton-{i}", role, fiche)
        jj = jeton(compte)
        avant_action = voit_quelque_chose(jj)
        if action is None:
            appel("POST", "/auth/v1/logout?scope=local", jj, {})
        else:
            action(compte)
        apres = voit_quelque_chose(jj)
        s, r = appel("POST", "/rest/v1/clients", jj, {"nom": "Intrus"})
        verifier(f"{libelle} : l'ancien jeton ne voit plus rien et n'écrit plus",
                 avant_action > 0 and apres == 0 and s in REFUS,
                 f"lignes visibles avant {avant_action} → après {apres}, écriture HTTP {s}")
        roles = [appel("POST", f"/rest/v1/rpc/{f}", jj, {})[1] for f in ("mon_role", "mon_collaborateur_id", "est_admin")]
        verifier(f"{libelle} : fonctions d'identité muettes", roles[:2] == [None, None] and roles[2] is False, repr(roles))
        s, r = appel("POST", f"/storage/v1/object/justificatifs/ancien-{i}.txt", jj, brut=b"x", entetes={"Content-Type": "text/plain"})
        verifier(f"{libelle} : stockage refusé", s >= 400, f"HTTP {s}")
        c[f"ancien_{i}"] = compte

    print("\n== 8. Inventaire des fonctions exposées par l'API")
    s, d = appel("GET", "/rest/v1/", cle=SECRET, entetes={"Accept": "application/openapi+json"})
    fonctions = sorted(p[5:] for p in d["paths"] if p.startswith("/rpc/"))
    print("  fonctions exposées :", ", ".join(fonctions))
    identite = {"acces_actif", "est_admin", "mon_collaborateur_id", "mon_role"}
    for f in fonctions:
        # Arguments vides (null) aux noms exacts : la fonction est trouvée, le droit d'exécution est
        # contrôlé avant tout traitement. prochain_numero : clé d'essai, nettoyée à la fin.
        corps_rpc = next((x.get("schema", {}) for x in d["paths"][f"/rpc/{f}"].get("post", {}).get("parameters", [])
                          if x.get("in") == "body"), {})
        args = {k: None for k in corps_rpc.get("properties", {})}
        if f == "prochain_numero":
            args = {"p_cle": "essai_securite", "p_prefixe": "ESSAI"}
        s_anon, _ = appel("POST", f"/rest/v1/rpc/{f}", corps=args)
        s_admin, r_admin = appel("POST", f"/rest/v1/rpc/{f}", j["admin"], args)
        if f in identite:
            verifier(f"{f} : visiteur refusé, admin actif autorisé (ne concerne que lui-même)",
                     s_anon in REFUS and s_admin == 200, f"visiteur {s_anon}, admin {s_admin}")
        else:
            verifier(f"{f} : refusée au visiteur ET à l'admin actif", s_anon in REFUS and s_admin in REFUS,
                     f"visiteur {s_anon}, admin {s_admin}")

    print("\n== 9. Votre compte et vos données")
    s, r = secret("GET", "/rest/v1/profiles?email=eq.sgi@gmx.fr&select=role")
    verifier("sgi@gmx.fr toujours admin", lignes(r) and r[0]["role"] == "admin")
    apres = compter_tout()
    verifier("11 tables : aucune ligne ajoutée ni perdue", apres == avant, json.dumps(apres))

    print(f"\nBILAN : {sum(resultats)}/{len(resultats)} contrôles réussis")


try:
    main()
finally:
    print("\n== Nettoyage des comptes jetables")
    s, r = secret("GET", "/auth/v1/admin/users?per_page=1000")
    for u in r["users"]:
        if u["email"].endswith(DOMAINE):
            secret("DELETE", f"/auth/v1/admin/users/{u['id']}")
    s, r = secret("GET", "/auth/v1/admin/users?per_page=1000")
    print("  comptes restants :", [u["email"] for u in r["users"]])
    s, r = secret("POST", "/storage/v1/object/list/justificatifs", {"prefix": ""})
    jetables = [o["name"] for o in lignes(r) if o["name"].startswith("jetable-")]
    if jetables:
        secret("DELETE", "/storage/v1/object/justificatifs", {"prefixes": jetables})
    s, r = secret("POST", "/storage/v1/object/list/justificatifs", {"prefix": ""})
    print("  fichiers restants dans le bucket :", [o["name"] for o in lignes(r)])
    s, r = secret("POST", "/storage/v1/object/list/devis", {"prefix": ""})
    jetables = [o["name"] for o in lignes(r) if o["name"].startswith("jetable-")]
    if jetables:
        secret("DELETE", "/storage/v1/object/devis", {"prefixes": jetables})
        print("  ATTENTION : des fichiers jetables avaient été déposés dans le bucket devis ; supprimés")
    s, r = secret("GET", "/rest/v1/compteurs?cle=eq.essai_securite")
    if lignes(r):
        secret("DELETE", "/rest/v1/compteurs?cle=eq.essai_securite")
        print("  ATTENTION : un compteur d'essai avait été créé ; il a été supprimé")
