import { NextResponse, type NextRequest } from "next/server";
import { createServerClient } from "@supabase/ssr";
import { PAGES_PUBLIQUES } from "@/lib/navigation";
import { INDICATEUR_CHANGEMENT_MDP } from "@/lib/utilisateurs";

// Le nom du fichier (proxy.ts) et de la fonction (proxy) sont imposés par Next.js.
// À chaque requête : rafraîchit la session Supabase, puis redirige un visiteur
// non connecté vers /connexion (et un utilisateur connecté hors de /connexion),
// et impose le remplacement d'un mot de passe provisoire.
export async function proxy(requete: NextRequest) {
  // Routes des relances (tâche planifiée, événements du fournisseur) : sans session ; chacune vérifie elle-même
  // son secret partagé ou sa signature, et refuse tout le reste.
  if (ROUTES_SANS_SESSION.includes(requete.nextUrl.pathname)) {
    return NextResponse.next();
  }
  let reponse = NextResponse.next({ request: requete });

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return requete.cookies.getAll();
        },
        setAll(cookiesAEcrire, entetes) {
          cookiesAEcrire.forEach(({ name, value }) =>
            requete.cookies.set(name, value),
          );
          reponse = NextResponse.next({ request: requete });
          cookiesAEcrire.forEach(({ name, value, options }) =>
            reponse.cookies.set(name, value, options),
          );
          Object.entries(entetes).forEach(([cle, valeur]) =>
            reponse.headers.set(cle, valeur),
          );
        },
      },
    },
  );

  const {
    data: { user },
  } = await supabase.auth.getUser();

  const chemin = requete.nextUrl.pathname;
  const pagePublique = PAGES_PUBLIQUES.some(
    (p) => chemin === p || chemin.startsWith(`${p}/`),
  );

  if (!user && !pagePublique) {
    return rediriger(requete, reponse, "/connexion");
  }
  if (user && pagePublique) {
    return rediriger(requete, reponse, "/");
  }
  // Mot de passe provisoire : aucune autre page (ni action serveur) avant son remplacement.
  if (
    user?.app_metadata?.[INDICATEUR_CHANGEMENT_MDP] === true &&
    chemin !== PAGE_CHANGEMENT_MDP
  ) {
    return rediriger(requete, reponse, PAGE_CHANGEMENT_MDP);
  }
  return reponse;
}

const PAGE_CHANGEMENT_MDP = "/changer-mot-de-passe";
const ROUTES_SANS_SESSION = ["/api/relances/executer", "/api/relances/livraison"];

// Redirige en conservant les cookies de session éventuellement rafraîchis.
function rediriger(requete: NextRequest, reponse: NextResponse, chemin: string) {
  const url = requete.nextUrl.clone();
  url.pathname = chemin;
  url.search = "";
  const redirection = NextResponse.redirect(url);
  reponse.cookies.getAll().forEach((c) => redirection.cookies.set(c));
  return redirection;
}

export const config = {
  // Toutes les pages, sauf les fichiers techniques et les images.
  matcher: [
    "/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico)$).*)",
  ],
};
