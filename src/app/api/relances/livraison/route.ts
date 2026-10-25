import { enregistrerEvenement, signatureEvenementValide } from "@/lib/relances/serveur";

// Événements de livraison envoyés par le fournisseur (webhook). Aucune session : chaque appel est authentifié par sa
// signature (RESEND_WEBHOOK_SECRET), vérifiée sur le corps brut. Un événement non signé ou périmé est refusé.
// Réponse 500 si la base est indisponible : le fournisseur renverra l'événement (les doublons sont ignorés).
export const dynamic = "force-dynamic";

export async function POST(requete: Request) {
  const corps = await requete.text();
  const id = requete.headers.get("svix-id");
  if (!signatureEvenementValide(corps, id, requete.headers.get("svix-timestamp"), requete.headers.get("svix-signature"))) {
    return Response.json({ erreur: "Signature invalide" }, { status: 401 });
  }
  let charge: unknown;
  try {
    charge = JSON.parse(corps);
  } catch {
    return Response.json({ erreur: "Corps illisible" }, { status: 400 });
  }
  try {
    return Response.json({ resultat: await enregistrerEvenement(id!, charge) });
  } catch {
    return Response.json({ erreur: "Enregistrement impossible pour le moment" }, { status: 500 });
  }
}
