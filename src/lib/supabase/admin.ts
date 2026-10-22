import "server-only";
import { createClient } from "@supabase/supabase-js";

// Client Supabase avec la clé SECRÈTE : contourne les règles RLS.
// Réservé au code serveur, et uniquement après une vérification explicite des droits.
export function creerClientAdmin() {
  return createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
    { auth: { autoRefreshToken: false, persistSession: false } },
  );
}
