import { executerRelances, secretCronValide } from "@/lib/relances/serveur";

// Exécution des relances, appelée par la future tâche Cron (Supabase, secret partagé lu dans Vault). Aucune session :
// l'appel est authentifié par le secret partagé (comparaison à temps constant). Aucun en-tête n'est journalisé.
// Sans l'interrupteur RELANCES_ACTIVES=1, rien n'est réservé ni envoyé.
export const dynamic = "force-dynamic";
export const maxDuration = 60;

export async function POST(requete: Request) {
  if (!secretCronValide(requete.headers.get("authorization"))) {
    return Response.json({ erreur: "Accès refusé" }, { status: 401 });
  }
  const bilan = await executerRelances();
  return Response.json(bilan, { headers: { "Cache-Control": "no-store" } });
}
