import { lireUtilisateurCourant } from "@/lib/session";
import { creerClientAdmin } from "@/lib/supabase/admin";
import { aujourdhuiMartinique } from "@/lib/rh";
import { lireParametresFacture, type Calcul } from "@/lib/finance";
import { pdfApercu } from "@/lib/finance/serveur";

// Aperçu PDF d'une facture non émise : calculé par la base (même fonction que l'émission), généré à la volée,
// jamais stocké, sans numéro, filigrane « APERÇU — NON ÉMISE ». Aucune écriture. Administrateur seulement.
export async function GET(requete: Request) {
  const moi = await lireUtilisateurCourant();
  if (moi.role !== "admin") return new Response("Accès réservé à l'administrateur", { status: 403 });
  const p = lireParametresFacture(new URL(requete.url).searchParams);
  const { data, error } = await creerClientAdmin().rpc("finance_calculer", { p_client: p.client, p_mois: p.mois, p_projets: p.projets, p_tva: p.tva });
  const calc = data as Calcul | null;
  if (error || !calc) return new Response("Aperçu impossible", { status: 409 });
  if (calc.blocages.length) return new Response(`Aperçu impossible : ${calc.blocages.join(" ")}`, { status: 409 });
  return new Response(await pdfApercu(calc, aujourdhuiMartinique()) as BodyInit, {
    headers: { "Content-Type": "application/pdf", "Content-Disposition": 'inline; filename="apercu-facture.pdf"', "Cache-Control": "private, no-store" },
  });
}
