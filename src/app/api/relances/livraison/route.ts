import { enregistrerEvenement, signatureEvenementValide } from "@/lib/relances/serveur";

// Événements de livraison envoyés par le fournisseur (webhook). Aucune session : chaque appel est authentifié par sa
// signature (RESEND_WEBHOOK_SECRET), vérifiée sur le corps brut. Un événement non signé ou périmé est refusé.
// Un événement signé est ENREGISTRÉ par la base (réception durable) avant toute réponse 200, même s'il ne peut pas encore
// être rapproché (il reste alors en attente, sans limite de durée, jusqu'au rapprochement ou à un classement motivé par
// l'administrateur). Réponse 500 si l'enregistrement échoue (base indisponible, référence du compte absente) : le
// fournisseur renvoie l'événement (même identifiant ; un doublon est sans effet).
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
    return Response.json({ resultat });
  } catch {
    return Response.json({ erreur: "Enregistrement impossible pour le moment" }, { status: 500 });
  }
}
