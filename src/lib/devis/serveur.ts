import "server-only";
import { creerClientAdmin } from "@/lib/supabase/admin";
import { creerClientServeur } from "@/lib/supabase/serveur";
import { genererPdfDevis, type InstantaneDevis } from "@/lib/devis/pdf";
import { archiverPdfDevis, lireArchiveVerifiee, type BaseDevis, type StockageDevis } from "@/lib/devis/archivage";
import { COORDONNEES_DEMO, coordonneesEmetteur } from "@/lib/entreprise";

const BUCKET = "devis";

// Stockage privé « devis » : clé secrète uniquement ; jamais d'écrasement (upsert: false).
export function stockageSupabase(): StockageDevis {
  const admin = creerClientAdmin();
  return {
    async deposer(chemin, contenu) {
      const { error } = await admin.storage.from(BUCKET).upload(chemin, contenu, {
        contentType: "application/pdf",
        upsert: false,
      });
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

export function baseSupabase(): BaseDevis {
  const admin = creerClientAdmin();
  return {
    async enregistrer(devisId, chemin, empreinte, taille) {
      const { error } = await admin.rpc("enregistrer_pdf_devis", {
        p_devis_id: devisId, p_chemin: chemin, p_empreinte: empreinte, p_taille: taille,
      });
      if (error) throw new Error(error.message);
    },
    async signalerEchec(devisId, message) {
      await admin.rpc("signaler_echec_pdf_devis", { p_devis_id: devisId, p_erreur: message });
    },
  };
}

type DevisEmis = {
  id: string;
  numero: string;
  essai: boolean;
  emis_le: string;
  pdf_statut: string | null;
  pdf_chemin: string | null;
  pdf_empreinte: string | null;
  instantane_emission: InstantaneDevis;
};

async function lireDevisEmis(devisId: string): Promise<DevisEmis | null> {
  const { data } = await creerClientAdmin()
    .from("devis")
    .select("id, numero, essai, emis_le, pdf_statut, pdf_chemin, pdf_empreinte, instantane_emission")
    .eq("id", devisId)
    .neq("statut", "brouillon")
    .maybeSingle();
  return (data as DevisEmis | null) ?? null;
}

function genererDepuisInstantane(d: DevisEmis) {
  return () =>
    genererPdfDevis(d.instantane_emission, {
      filigrane: d.essai ? "ESSAI — SANS VALEUR" : null,
      dateDocument: new Date(d.emis_le),
    });
}

// À appeler après l'émission et pour toute reprise (« Régénérer ») : idempotent.
export async function archiverDevis(devisId: string) {
  const d = await lireDevisEmis(devisId);
  if (!d) return { statut: "echec" as const, message: "Devis introuvable ou non émis" };
  if (d.pdf_statut === "disponible") return { statut: "disponible" as const };
  return archiverPdfDevis({ id: d.id, numero: d.numero }, genererDepuisInstantane(d), stockageSupabase(), baseSupabase());
}

export async function pdfArchive(devisId: string): Promise<{ nom: string; contenu: Uint8Array }> {
  const d = await lireDevisEmis(devisId);
  if (!d || d.pdf_statut !== "disponible" || !d.pdf_chemin || !d.pdf_empreinte) {
    throw new Error("Le PDF archivé de ce devis n'est pas disponible");
  }
  return { nom: `${d.numero}.pdf`, contenu: await lireArchiveVerifiee(stockageSupabase(), d.pdf_chemin, d.pdf_empreinte) };
}

// Brouillon : PDF généré à la volée, jamais stocké, sans numéro, filigrane « BROUILLON — NON ÉMIS ».
// Lu avec la session de l'utilisateur (ses droits s'appliquent). Aucune écriture.
export async function pdfBrouillon(devisId: string): Promise<{ nom: string; contenu: Uint8Array }> {
  const supabase = await creerClientServeur();
  const { data: d } = await supabase
    .from("devis")
    .select("id, essai, statut, total_ht, tva, total_ttc, regime_tva, territoire_tva, pays_tva, taux_tva, mention_tva, remplace_devis_id, avenant_du_devis_id, prospects(nom, societe, email, telephone, adresse, code_postal, ville, pays)")
    .eq("id", devisId)
    .eq("statut", "brouillon")
    .maybeSingle();
  if (!d) throw new Error("Brouillon introuvable");
  const { data: lignes } = await supabase
    .from("devis_lignes")
    .select("designation, quantite, prix_unitaire, montant_ht")
    .eq("devis_id", devisId)
    .order("created_at")
    .order("id");
  const lien = async (id: string | null) =>
    id ? ((await supabase.from("devis").select("numero").eq("id", id).maybeSingle()).data?.numero ?? null) : null;
  const instantane: InstantaneDevis = {
    essai: d.essai,
    numero: null,
    date_emission: new Date().toISOString().slice(0, 10),
    emetteur: (d.essai ? COORDONNEES_DEMO : coordonneesEmetteur()) as unknown as Record<string, string>,
    destinataire: { prospect: (d.prospects as unknown as Record<string, string | null>) ?? {} },
    lignes: (lignes ?? []).map((l) => ({ ...l, quantite: Number(l.quantite), prix_unitaire: Number(l.prix_unitaire), montant_ht: Number(l.montant_ht) })),
    totaux: { total_ht: Number(d.total_ht), tva: Number(d.tva), total_ttc: Number(d.total_ttc) },
    tva: { regime: d.regime_tva, territoire: d.territoire_tva, pays: d.pays_tva, taux: d.taux_tva === null ? null : Number(d.taux_tva), mention: d.mention_tva },
    remplace: await lien(d.remplace_devis_id),
    avenant_de: await lien(d.avenant_du_devis_id),
  };
  return {
    nom: "devis-brouillon.pdf",
    contenu: await genererPdfDevis(instantane, { filigrane: "BROUILLON — NON ÉMIS", dateDocument: new Date() }),
  };
}
