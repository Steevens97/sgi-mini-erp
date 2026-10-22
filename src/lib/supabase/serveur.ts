import "server-only";
import { cookies } from "next/headers";
import { createServerClient } from "@supabase/ssr";

// Client Supabase côté serveur, agissant au nom de l'utilisateur connecté
// (clé publique + cookies de session) : les règles RLS s'appliquent.
export async function creerClientServeur() {
  const magasinCookies = await cookies();

  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return magasinCookies.getAll();
        },
        setAll(cookiesAEcrire) {
          // Depuis une page, l'écriture des cookies est impossible : le proxy
          // (src/proxy.ts) se charge alors de rafraîchir la session.
          try {
            cookiesAEcrire.forEach(({ name, value, options }) =>
              magasinCookies.set(name, value, options),
            );
          } catch {}
        },
      },
    },
  );
}
