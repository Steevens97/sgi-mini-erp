#!/bin/bash
# Serveur Next LOCAL (build fait sur 127.0.0.1:54321), port 3200, base d'ESSAI. Jamais Supabase.
# Usage : serveur_local.sh start [1]   (1 = SIMULATION_LOCALE : coordonnées « SIMULATION LOCALE — SANS VALEUR »)
#         serveur_local.sh stop
# Arrêt par le processus qui ÉCOUTE sur le port (lecture de /proc ; ni nom de processus, ni `ss`, absent ici),
# puis tout son groupe : le pid renvoyé par `setsid` désigne un intermédiaire déjà terminé.
R="$(cd "$(dirname "$0")/../.." && pwd)"
pid_port() {
  python3 -I - "$1" <<'PY'
import os, sys
port = int(sys.argv[1]); inodes = set()
for f in ("/proc/net/tcp", "/proc/net/tcp6"):
    try:
        for l in open(f).read().splitlines()[1:]:
            c = l.split()
            if int(c[1].split(":")[1], 16) == port and c[3] == "0A":
                inodes.add(c[9])
    except OSError:
        pass
for p in filter(str.isdigit, os.listdir("/proc")):
    try:
        for fd in os.listdir(f"/proc/{p}/fd"):
            if os.readlink(f"/proc/{p}/fd/{fd}").strip("socket:[]") in inodes:
                print(p); sys.exit(0)
    except OSError:
        pass
PY
}
case "$1" in
  start)
    . /var/tmp/pg-essai/cles_locales.sh
    (cd "$R" && NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:54321 NEXT_PUBLIC_SUPABASE_ANON_KEY=$ESSAI_ANON \
      SUPABASE_SERVICE_ROLE_KEY=$ESSAI_SERVICE SIMULATION_LOCALE=$2 nohup setsid npx next start -p 3200 > /var/tmp/pg-essai/next.log 2>&1 &)
    for i in $(seq 1 40); do curl -s -o /dev/null http://127.0.0.1:3200/connexion && break; sleep 1; done ;;
  stop)
    pid=$(pid_port 3200)
    [ -n "$pid" ] && kill -- -"$(ps -o pgid= "$pid" | tr -d ' ')" 2>/dev/null
    for i in $(seq 1 20); do [ -z "$(pid_port 3200)" ] && break; sleep 0.5; done ;;
esac
