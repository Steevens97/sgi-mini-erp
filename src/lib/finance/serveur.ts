import "server-only";
import { creerClientAdmin } from "@/lib/supabase/admin";
import { genererPdfFacture, type InstantaneFacture } from "@/lib/finance/pdf";
import { archiverPdfDevis as archiverPdf, lireArchiveVerifiee, type BaseDevis, type StockageDevis } from "@/lib/devis/archivage";
import { conditionsFacture, emetteurFacture } from "@/lib/entreprise";
import type { Calcul } from "@/lib/finance";

// Toutes les lectures Finance passent par la clé secrète, APRÈS exigerAdmin() dans la page ou l'action :
// aucun jeton utilisateur n'a de droit sur les factures ni sur les tarifs.
const BUCKET = "factures";

// Stockage privé « factures » : clé secrète uniquement ; jamais d'écrasement (upsert: false).
// Même mécanique d'archivage que les devis (le fichier stocké fait foi, reprise sans changer de numéro).
function stockage(): StockageDevis {
  const admin = creerClientAdmin();
  return {
    async deposer(chemin, contenu) {
      const { error } = await admin.storage.from(BUCKET).upload(chemin, contenu, { contentType: "application/pdf", upsert: false });
      if (!error) return "depose";
      const code = (error as { statusCode?: string }).statusCode;
      if (code === "409" || /exists/i.test(error.message)) return "existe";
      throw new Error(`Stockage : ${error.message}`);
    },
    async lire(chemin) {
      const { data, error } = await admin.storage.from(BUCKET).download(chemin);
      if (error || !data) return null;
      return new Uint8Array(await data.arrayBuffer());
    },
  };
}

function base(): BaseDevis {
  const admin = creerClientAdmin();
  return {
    async enregistrer(id, chemin, empreinte, taille) {
      const { error } = await admin.rpc("finance_enregistrer_pdf", { p_facture: id, p_chemin: chemin, p_empreinte: empreinte, p_taille: taille });
      if (error) throw new Error(error.message);
    },
    async signalerEchec(id, message) {
      await admin.rpc("finance_signaler_echec_pdf", { p_facture: id, p_erreur: message });
    },
  };
}

export type FactureEmise = {
  id: string; numero: string; essai: boolean; emise_le: string; statut: string; pdf_statut: string | null;
  pdf_chemin: string | null; pdf_empreinte: string | null; pdf_erreur: string | null; instantane_emission: InstantaneFacture;
};

export async function lireFacture(id: string): Promise<FactureEmise | null> {
  const { data } = await creerClientAdmin().from("factures")
    .select("id, numero, essai, emise_le, statut, pdf_statut, pdf_chemin, pdf_empreinte, pdf_erreur, instantane_emission")
    .eq("id", id).maybeSingle();
  return (data as FactureEmise | null) ?? null;
}

// Après l'émission et pour toute reprise (« Générer / reprendre le PDF ») : idempotent.
export async function archiverFacture(id: string) {
  const f = await lireFacture(id);
  if (!f) return { statut: "echec" as const, message: "Facture introuvable" };
  if (f.pdf_statut === "disponible") return { statut: "disponible" as const };
  return archiverPdf({ id: f.id, numero: f.numero },
    () => genererPdfFacture(f.instantane_emission, { filigrane: f.essai ? "ESSAI — SANS VALEUR" : null, dateDocument: new Date(f.emise_le) }),
    stockage(), base());
}

export async function pdfFactureArchive(id: string): Promise<{ nom: string; contenu: Uint8Array }> {
  const f = await lireFacture(id);
  if (!f || f.pdf_statut !== "disponible" || !f.pdf_chemin || !f.pdf_empreinte) {
    throw new Error("Le PDF archivé de cette facture n'est pas disponible");
  }
  return { nom: `${f.numero}.pdf`, contenu: await lireArchiveVerifiee(stockage(), f.pdf_chemin, f.pdf_empreinte) };
}

// Aperçu : PDF généré à la volée depuis le calcul de la base, jamais stocké, sans numéro, filigrane.
export async function pdfApercu(calc: Calcul, aujourdhui: string): Promise<Uint8Array> {
  const conditions = conditionsFacture(calc.essai);
  const delai = Number(conditions.delai_paiement_jours) || 0;
  const echeance = delai ? new Date(Date.parse(`${aujourdhui}T12:00:00Z`) + delai * 86400000).toISOString().slice(0, 10) : null;
  return genererPdfFacture({
    essai: calc.essai, numero: null, date_emission: aujourdhui, date_echeance: echeance,
    periode: { mois: calc.mois, debut: calc.periode_debut, fin: calc.periode_fin },
    emetteur: emetteurFacture(calc.essai), conditions: conditions as unknown as Record<string, string>,
    client: calc.client, lignes: calc.lignes, temps: calc.temps, totaux: calc.totaux, tva: calc.tva,
  }, { filigrane: "APERÇU — NON ÉMISE", dateDocument: new Date() });
}
