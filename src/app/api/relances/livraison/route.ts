import { enregistrerEvenement, signatureEvenementValide } from "@/lib/relances/serveur";

// Événements de livraison envoyés par le fournisseur (webhook). Aucune session : chaque appel est authentifié par sa
// signature (RESEND_WEBHOOK_SECRET), vérifiée sur le corps brut. Un événement non signé ou périmé est refusé.
// Réponse 500 si la base est indisponible, 503 si l'événement ne peut pas encore être rapproché (une relance tentée attend
// l'enregistrement de son identifiant) : dans les deux cas le fournisseur RENVOIE l'événement (même identifiant ; les
// doublons sont ignorés). Rien n'est écrit tant qu'il n'est pas rapproché.
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
    const resultat = await enregistrerEvenement(id!, charge);
    if (resultat === "en_attente") {
      return Response.json({ resultat, erreur: "Événement pas encore rapprochable : à renvoyer" }, { status: 503, headers: { "Retry-After": "300" } });
    }
    return Response.json({ resultat });
  } catch {
    return Response.json({ erreur: "Enregistrement impossible pour le moment" }, { status: 500 });
  }
}
