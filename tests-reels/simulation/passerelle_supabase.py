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
                "'app_metadata', raw_app_meta_data, 'user_metadata', '{}'::json, 'created_at', now()) "
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

    def repondre(self, code, corps, type_="application/json"):
        donnees = corps if isinstance(corps, bytes) else json.dumps(corps).encode()
        self.send_response(code)
        self.send_header("Content-Type", type_)
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
                return self.repondre(200, utilisateur(uid))
            if methode == "GET":
                lignes = sql("select coalesce(json_agg(json_build_object('id', id, 'email', email, 'app_metadata', raw_app_meta_data)), '[]') from auth.users")
                return self.repondre(200, {"users": json.loads(lignes)})
        self.repondre(404, {"msg": "non imité : " + chemin})

    def stockage(self, methode, chemin):
        # /object/<bucket>/<chemin>
        if not chemin.startswith("/object/"):
            return self.repondre(404, {"message": "non imité"})
        j = self.jeton()
        if not j or j.get("role") != "service_role":
            return self.repondre(403, {"statusCode": "403", "message": "Réservé à la clé secrète (bucket privé)"})
        bucket, _, nom = chemin[len("/object/"):].partition("/")
        nom = urllib.parse.unquote(nom.split("?")[0])
        fichier = os.path.join(DOSSIER, bucket, nom)
        if methode == "POST":
            contenu = self.corps()
            if os.path.exists(fichier):
                return self.repondre(400, {"statusCode": "409", "error": "Duplicate", "message": "The resource already exists"})
            os.makedirs(os.path.dirname(fichier), exist_ok=True)
            with open(fichier, "wb") as f:
                f.write(contenu)
            sql("insert into storage.objects (bucket_id, name, metadata) values (:'p0', :'p1', :'p2'::jsonb)",
                bucket, nom, json.dumps({"size": len(contenu), "mimetype": "application/pdf"}))
            return self.repondre(200, {"Key": f"{bucket}/{nom}"})
        if methode == "GET":
            if not os.path.exists(fichier):
                return self.repondre(400, {"statusCode": "404", "message": "Object not found"})
            with open(fichier, "rb") as f:
                return self.repondre(200, f.read(), "application/pdf")
        self.repondre(405, {"message": "méthode"})

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
