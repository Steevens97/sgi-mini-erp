"""Passerelle LOCALE imitant Supabase pour tester l'application sans déploiement.
  /rest/v1/*     → vrai PostgREST local (port 3999) sur la base d'essai
  /auth/v1/*     → imitation minimale de l'authentification (mot de passe, session, jeton HS256)
  /storage/v1/*  → imitation du stockage (fichiers sur disque + ligne storage.objects)
Jamais utilisée avec Supabase. Usage : python3 -I passerelle_supabase.py
"""
import base64, hashlib, hmac, json, os, subprocess, time, urllib.request, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SECRET = b"secret-essai-local-uniquement-0123456789abcdef"
PGRST = "http://127.0.0.1:3999"
DOSSIER = "/var/tmp/pg-essai/stockage"
os.makedirs(DOSSIER, exist_ok=True)


def sql(requete, *params):
    """Requête sur la base d'essai (paramètres passés en variables psql, sans concaténation)."""
    args = ["psql", "-h", "/var/tmp/pg-essai", "-p", "5499", "-U", "postgres", "-d", "essai", "-qAt", "-X"]
    for i, p in enumerate(params):
        args += ["-v", f"p{i}={p}"]
    r = subprocess.run(args, input=requete, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(r.stderr)
    return r.stdout.strip()


def b64(d):
    return base64.urlsafe_b64encode(d).rstrip(b"=")


def signer(charge):
    corps = b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode()) + b"." + b64(json.dumps(charge).encode())
    return (corps + b"." + b64(hmac.new(SECRET, corps, hashlib.sha256).digest())).decode()


def lire_jeton(jeton):
    try:
        corps, sig = jeton.rsplit(".", 1)
        attendu = b64(hmac.new(SECRET, corps.encode(), hashlib.sha256).digest()).decode()
        if not hmac.compare_digest(attendu, sig):
            return None
        charge = json.loads(base64.urlsafe_b64decode(corps.split(".")[1] + "=="))
        return charge if charge.get("exp", 0) > time.time() else None
    except Exception:
        return None


def utilisateur(uid):
    ligne = sql("select json_build_object('id', id, 'email', email, 'aud', 'authenticated', 'role', 'authenticated', "
                "'app_metadata', raw_app_meta_data, 'user_metadata', '{}'::json, 'created_at', now(), 'email_confirmed_at', now(), "
                "'banned_until', banned_until) "
                "from auth.users where id = :'p0'", uid)
    return json.loads(ligne) if ligne else None


def session_pour(uid, session_id=None):
    session_id = session_id or str(uuid.uuid4())
    sql("insert into auth.sessions (id, user_id) values (:'p0', :'p1') on conflict do nothing", session_id, uid)
    u = utilisateur(uid)
    maintenant = int(time.time())
    jeton = signer({"sub": uid, "role": "authenticated", "aud": "authenticated", "email": u["email"],
                    "session_id": session_id, "app_metadata": u["app_metadata"], "iat": maintenant,
                    "exp": maintenant + 3600})
    return {"access_token": jeton, "token_type": "bearer", "expires_in": 3600, "expires_at": maintenant + 3600,
            "refresh_token": session_id, "user": u}


class Passerelle(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def repondre(self, code, corps, type_="application/json", entetes=None):
        donnees = corps if isinstance(corps, bytes) else json.dumps(corps).encode()
        self.send_response(code)
        self.send_header("Content-Type", type_)
        # Comme Supabase Storage : appels directs du navigateur autorisés (dépôt par lien signé).
        self.send_header("Access-Control-Allow-Origin", "*")
        for k, v in (entetes or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(donnees)))
        self.end_headers()
        self.wfile.write(donnees)

    def corps(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def jeton(self):
        a = self.headers.get("Authorization", "")
        return lire_jeton(a[7:]) if a.startswith("Bearer ") else None

    def traiter(self, methode):
        chemin = self.path
        if chemin.startswith("/rest/v1"):
            return self.vers_postgrest(methode, chemin[len("/rest/v1"):])
        if chemin.startswith("/auth/v1"):
            return self.auth(methode, chemin[len("/auth/v1"):])
        if chemin.startswith("/storage/v1"):
            return self.stockage(methode, chemin[len("/storage/v1"):])
        self.repondre(404, {"message": "inconnu"})

    def vers_postgrest(self, methode, chemin):
        corps = self.corps()
        entetes = {k: v for k, v in self.headers.items() if k.lower() in (
            "authorization", "content-type", "prefer", "accept", "range", "accept-profile", "content-profile")}
        req = urllib.request.Request(PGRST + chemin, method=methode, data=corps or None, headers=entetes)
        try:
            with urllib.request.urlopen(req) as r:
                self.send_response(r.status)
                donnees = r.read()
                for k, v in r.headers.items():
                    if k.lower() in ("content-type", "content-range", "preference-applied"):
                        self.send_header(k, v)
                self.send_header("Content-Length", str(len(donnees)))
                self.end_headers()
                self.wfile.write(donnees)
        except urllib.error.HTTPError as e:
            self.repondre(e.code, e.read())

    def auth(self, methode, chemin):
        if chemin.startswith("/token"):
            donnees = json.loads(self.corps() or b"{}")
            if "grant_type=password" in chemin:
                uid = sql("select id from auth.users where email = :'p0' and mot_de_passe = :'p1' "
                          "and (banned_until is null or banned_until < now())",
                          donnees.get("email", ""), donnees.get("password", ""))
                if not uid:
                    return self.repondre(400, {"code": 400, "error_code": "invalid_credentials", "msg": "Invalid login credentials"})
                return self.repondre(200, session_pour(uid))
            if "grant_type=refresh_token" in chemin:
                uid = sql("select user_id from auth.sessions where id::text = :'p0'", donnees.get("refresh_token", ""))
                if not uid:
                    return self.repondre(400, {"error_code": "refresh_token_not_found", "msg": "Invalid Refresh Token"})
                return self.repondre(200, session_pour(uid, donnees["refresh_token"]))
        j = self.jeton()
        if chemin.startswith("/user"):
            if not j or not sql("select 1 from auth.sessions where id::text = :'p0'", j.get("session_id", "")):
                return self.repondre(403, {"error_code": "session_not_found", "msg": "Session not found"})
            if methode == "PUT":
                # Changement de son propre mot de passe (comme Supabase : refusé s'il est identique à l'actuel).
                nouveau = json.loads(self.corps() or b"{}").get("password")
                if nouveau is not None:
                    if sql("select 1 from auth.users where id = :'p0' and mot_de_passe = :'p1'", j["sub"], nouveau):
                        return self.repondre(422, {"code": 422, "error_code": "same_password",
                                                   "msg": "New password should be different from the old password."})
                    sql("update auth.users set mot_de_passe = :'p1' where id = :'p0'", j["sub"], nouveau)
            u = utilisateur(j["sub"])
            return self.repondre(200, u) if u else self.repondre(403, {"error_code": "user_not_found"})
        if chemin.startswith("/logout"):
            if j:
                sql("delete from auth.sessions where id::text = :'p0'", j.get("session_id", ""))
            return self.repondre(204, b"")
        if chemin.startswith("/admin/users"):
            uid = chemin.split("/admin/users/")[1].split("?")[0] if "/admin/users/" in chemin else None
            if methode == "PUT" and uid:
                donnees = json.loads(self.corps() or b"{}")
                if "app_metadata" in donnees:
                    sql("update auth.users set raw_app_meta_data = raw_app_meta_data || :'p1'::jsonb where id = :'p0'",
                        uid, json.dumps(donnees["app_metadata"]))
                if "password" in donnees:
                    sql("alter table auth.users add column if not exists mot_de_passe text;\n"
                        "update auth.users set mot_de_passe = :'p1' where id = :'p0'", uid, donnees["password"])
                if "ban_duration" in donnees:
                    # Comme Supabase : « none » lève le blocage ; une durée (ex. 24h) bloque le compte.
                    duree = donnees["ban_duration"]
                    sql("update auth.users set banned_until = case when :'p1' = 'none' then null else now() + :'p1'::interval end "
                        "where id = :'p0'", uid, duree)
                return self.repondre(200, utilisateur(uid))
            if methode == "GET":
                lignes = sql("select coalesce(json_agg(json_build_object('id', id, 'email', email, 'app_metadata', raw_app_meta_data, "
                             "'email_confirmed_at', now(), 'banned_until', banned_until)), '[]') from auth.users")
                return self.repondre(200, {"users": json.loads(lignes)})
            # Création et suppression de comptes (clé secrète) : utilisées par les parcours « en ligne » rejoués en local.
            j = self.jeton()
            if not j or j.get("role") != "service_role":
                return self.repondre(403, {"msg": "Réservé à la clé secrète"})
            if methode == "POST" and not uid:
                donnees = json.loads(self.corps() or b"{}")
                nouveau = sql("alter table auth.users add column if not exists mot_de_passe text;\n"
                              "insert into auth.users (id, email, mot_de_passe, raw_app_meta_data) "
                              "values (gen_random_uuid(), :'p0', :'p1', :'p2'::jsonb) returning id",
                              donnees.get("email", ""), donnees.get("password", ""), json.dumps(donnees.get("app_metadata") or {}))
                return self.repondre(200, utilisateur(nouveau.splitlines()[0]))
            if methode == "DELETE" and uid:
                sql("delete from auth.users where id = :'p0'", uid)
                return self.repondre(200, {})
        self.repondre(404, {"msg": "non imité : " + chemin})

    def ecrire_objet(self, bucket, nom, contenu, type_):
        """Dépôt avec les limites du bucket (taille, types), sans jamais écraser : comme Supabase Storage."""
        limites = sql("select json_build_object('taille', file_size_limit, 'types', allowed_mime_types) from storage.buckets "
                      "where id = :'p0'", bucket)
        limites = json.loads(limites) if limites else {}
        if limites.get("taille") and len(contenu) > limites["taille"]:
            return 413, {"statusCode": "413", "error": "Payload too large", "message": "The object exceeded the maximum allowed size"}
        if limites.get("types") and type_ not in limites["types"]:
            return 415, {"statusCode": "415", "error": "invalid_mime_type", "message": f"mime type {type_} is not supported"}
        fichier = os.path.join(DOSSIER, bucket, nom)
        if os.path.exists(fichier) or sql("select count(*) from storage.objects where bucket_id = :'p0' and name = :'p1'", bucket, nom) != "0":
            return 400, {"statusCode": "409", "error": "Duplicate", "message": "The resource already exists"}
        os.makedirs(os.path.dirname(fichier), exist_ok=True)
        with open(fichier, "wb") as f:
            f.write(contenu)
        sql("insert into storage.objects (bucket_id, name, metadata) values (:'p0', :'p1', :'p2'::jsonb)",
            bucket, nom, json.dumps({"size": len(contenu), "mimetype": type_}))
        return 200, {"Key": f"{bucket}/{nom}"}

    def servir_objet(self, bucket, nom):
        fichier = os.path.join(DOSSIER, bucket, nom)
        if not os.path.exists(fichier):
            return self.repondre(400, {"statusCode": "404", "message": "Object not found"})
        type_ = sql("select metadata ->> 'mimetype' from storage.objects where bucket_id = :'p0' and name = :'p1'", bucket, nom)
        with open(fichier, "rb") as f:
            return self.repondre(200, f.read(), type_ or "application/octet-stream")

    def corps_fichier(self):
        """Corps brut, ou première partie d'un envoi multipart (comme le fait storage-js avec un Blob)."""
        brut, type_ = self.corps(), (self.headers.get("Content-Type") or "").split(";")[0].strip()
        if type_ == "multipart/form-data":
            borne = self.headers.get("Content-Type").split("boundary=")[1].strip('"').encode()
            for partie in brut.split(b"--" + borne):
                tete, _, contenu = partie.partition(b"\r\n\r\n")
                if b"filename=" in tete or b'name=""' in tete:
                    t = [l.split(b":", 1)[1].strip().decode() for l in tete.split(b"\r\n") if l.lower().startswith(b"content-type")]
                    return contenu[:-2] if contenu.endswith(b"\r\n") else contenu, (t[0] if t else "application/octet-stream")
        return brut, type_ or "application/octet-stream"

    def stockage(self, methode, chemin):
        # /object/<bucket>/<chemin>
        if chemin.startswith("/bucket/") and methode == "GET":
            j = self.jeton()
            if not j or j.get("role") != "service_role":
                return self.repondre(400, {"statusCode": "404", "message": "Bucket not found"})
            b = sql("select row_to_json(x) from (select id, name, public, file_size_limit, allowed_mime_types from storage.buckets "
                    "where id = :'p0') x", chemin[len("/bucket/"):].split("?")[0])
            return self.repondre(200, json.loads(b)) if b else self.repondre(400, {"statusCode": "404", "message": "Bucket not found"})
        if not chemin.startswith("/object/"):
            return self.repondre(404, {"message": "non imité"})
        adresse, _, requete = chemin.partition("?")
        jeton_lien = urllib.parse.parse_qs(requete).get("token", [None])[0]
        j = self.jeton()
        # Liens signés : dépôt (2 h, un chemin, jamais d'écrasement) et lecture (durée demandée). Émis avec la clé secrète.
        for genre, prefixe in (("depot", "/object/upload/sign/"), ("lecture", "/object/sign/")):
            if adresse.startswith(prefixe):
                bucket, _, nom = urllib.parse.unquote(adresse[len(prefixe):]).partition("/")
                if methode == "POST" and not jeton_lien:
                    if not j or j.get("role") != "service_role":
                        return self.repondre(403, {"statusCode": "403", "message": "Réservé à la clé secrète (bucket privé)"})
                    duree = 7200 if genre == "depot" else int(json.loads(self.corps() or b"{}").get("expiresIn", 60))
                    t = signer({"genre": genre, "objet": f"{bucket}/{nom}", "exp": int(time.time()) + duree})
                    cle = "url" if genre == "depot" else "signedURL"
                    return self.repondre(200, {cle: f"{prefixe}{bucket}/{urllib.parse.quote(nom)}?token={t}"})
                c = lire_jeton(jeton_lien or "")
                if not c or c.get("genre") != genre or c.get("objet") != f"{bucket}/{nom}":
                    return self.repondre(400, {"statusCode": "400", "error": "InvalidJWT", "message": "jwt expired or invalid"})
                if genre == "depot" and methode in ("PUT", "POST"):
                    contenu, type_ = self.corps_fichier()
                    code, r = self.ecrire_objet(bucket, nom, contenu, type_)
                    return self.repondre(code, r)
                if genre == "lecture" and methode == "GET":
                    return self.servir_objet(bucket, nom)
                return self.repondre(405, {"message": "méthode"})
        if chemin.startswith("/object/list/"):
            # Liste : rien pour un jeton utilisateur (aucune règle), le contenu pour la clé secrète.
            if not j or j.get("role") != "service_role":
                return self.repondre(200, [])
            bucket = chemin[len("/object/list/"):].split("?")[0]
            prefixe = (json.loads(self.corps() or b"{}").get("prefix") or "").strip("/")
            if prefixe:
                # Comme Supabase : fichiers du dossier demandé, noms relatifs à ce dossier, avec un identifiant.
                noms = sql("select coalesce(json_agg(json_build_object('name', substr(name, length(:'p1') + 2), 'id', id, 'metadata', metadata)), '[]') "
                           "from storage.objects where bucket_id = :'p0' and name like :'p1' || '/%' "
                           "and position('/' in substr(name, length(:'p1') + 2)) = 0", bucket, prefixe)
                return self.repondre(200, json.loads(noms))
            noms = sql("select coalesce(json_agg(name), '[]') from storage.objects where bucket_id = :'p0'", bucket)
            return self.repondre(200, [{"name": n} for n in json.loads(noms)])
        if not j or j.get("role") != "service_role":
            return self.repondre(403, {"statusCode": "403", "message": "Réservé à la clé secrète (bucket privé)"})
        bucket, _, nom = chemin[len("/object/"):].partition("/")
        if methode == "DELETE" and not nom:
            supprimes = []
            for n in json.loads(self.corps() or b"{}").get("prefixes", []):
                f = os.path.join(DOSSIER, bucket, n)
                if os.path.exists(f):
                    os.remove(f)
                sql("delete from storage.objects where bucket_id = :'p0' and name = :'p1'", bucket, n)
                supprimes.append({"name": n})
            return self.repondre(200, supprimes)
        nom = urllib.parse.unquote(nom.split("?")[0])
        if methode == "POST":
            contenu, type_ = self.corps_fichier()
            code, r = self.ecrire_objet(bucket, nom, contenu, type_)
            return self.repondre(code, r)
        if methode == "PUT":
            # Remplacement d'un fichier existant (clé secrète), comme l'« update » de Supabase Storage.
            contenu, type_ = self.corps_fichier()
            fichier = os.path.join(DOSSIER, bucket, nom)
            if not os.path.exists(fichier):
                return self.repondre(400, {"statusCode": "404", "message": "Object not found"})
            with open(fichier, "wb") as f:
                f.write(contenu)
            sql("update storage.objects set metadata = :'p2'::jsonb where bucket_id = :'p0' and name = :'p1'",
                bucket, nom, json.dumps({"size": len(contenu), "mimetype": type_}))
            return self.repondre(200, {"Key": f"{bucket}/{nom}"})
        if methode == "GET":
            return self.servir_objet(bucket, nom)
        self.repondre(405, {"message": "méthode"})

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "authorization, apikey, content-type, x-upsert, x-client-info, cache-control")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self): self.traiter("GET")
    def do_POST(self): self.traiter("POST")
    def do_PATCH(self): self.traiter("PATCH")
    def do_PUT(self): self.traiter("PUT")
    def do_DELETE(self): self.traiter("DELETE")
    def do_HEAD(self): self.traiter("HEAD")


import urllib.parse  # noqa: E402

if __name__ == "__main__":
    print("ANON=" + signer({"role": "anon", "exp": 9999999999}))
    print("SERVICE=" + signer({"role": "service_role", "exp": 9999999999}))
    ThreadingHTTPServer(("127.0.0.1", 54321), Passerelle).serve_forever()
