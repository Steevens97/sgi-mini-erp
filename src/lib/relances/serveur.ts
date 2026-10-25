import "server-only";
import { createHash, createHmac, randomUUID, timingSafeEqual } from "node:crypto";
import { creerClientAdmin } from "@/lib/supabase/admin";
import { lireArchiveVerifiee, type StockageDevis } from "@/lib/devis/archivage";
import { classerReponse, construireDemande, corpsFournisseur, lireEvenement, type DemandeFournisseur, type FactureARelancer } from "@/lib/relances";

// Module d'ENVOI des relances : appelé seulement par la route /api/relances/executer (secret partagé vérifié) et
// /api/relances/livraison (signature vérifiée). Jamais par les pages : la simulation de l'écran n'importe pas ce
// fichier. Secrets lus dans les variables d'environnement du serveur, jamais journalisés, jamais enregistrés :
//   RESEND_API_KEY (clé du fournisseur), RELANCES_SECRET_CRON (secret partagé avec Vault), RESEND_WEBHOOK_SECRET
//   (signature des événements). Réglages : RELANCES_ACTIVES=1 (interrupteur), RELANCES_ADRESSE_ESSAI (destinataire
//   des essais, confirmé par l'utilisateur), RESEND_COMPTE_REFERENCE (référence NON secrète du compte fournisseur, à
//   changer avec la clé et le secret de signature si l'on change de compte), RESEND_URL (essais locaux seulement :
//   imitation du fournisseur).

const URL_FOURNISSEUR = "https://api.resend.com";
const DELAI_APPEL_MS = 20000;

export function configuration() {
  return {
    url: (process.env.RESEND_URL || URL_FOURNISSEUR).replace(/\/+$/, ""),
    cle: process.env.RESEND_API_KEY ?? "",
    actives: process.env.RELANCES_ACTIVES === "1",
    adresseEssai: (process.env.RELANCES_ADRESSE_ESSAI ?? "").trim().toLowerCase() || null,
    compte: (process.env.RESEND_COMPTE_REFERENCE ?? "").trim(),
  };
}

// Référence du compte fournisseur : un NOM choisi par l'administrateur (ex. « resend-sgi-1 »), jamais une clé ni un
// secret. Elle est enregistrée sur chaque relance tentée et sur chaque événement reçu : une reprise avec un autre compte
// est refusée, et un événement d'un autre compte n'est jamais rapproché. La base refuse aussi ce qui ressemble à un secret.
export function referenceCompteValide(reference: string): boolean {
  if (!/^[A-Za-z0-9._-]{3,64}$/.test(reference)) return false;
  if (/^(re_|whsec_)/i.test(reference)) return false;
  const secrets = [process.env.RESEND_API_KEY, process.env.RESEND_WEBHOOK_SECRET, process.env.RELANCES_SECRET_CRON]
    .filter((x): x is string => !!x && x.length >= 8);
  return !secrets.some((x) => reference.includes(x) || x.includes(reference) && reference.length >= 16);
}

function egalSur(a: string, b: string): boolean {
  const x = Buffer.from(a), y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}

export function secretCronValide(entete: string | null): boolean {
  const attendu = process.env.RELANCES_SECRET_CRON ?? "";
  if (attendu.length < 32 || !entete?.startsWith("Bearer ")) return false;
  return egalSur(entete.slice(7), attendu);
}

// Signature des événements (format Svix utilisé par Resend) : HMAC-SHA256 de « id.horodatage.corps », clé = partie
// après « whsec_ » décodée en base64 ; horodatage à 5 minutes près.
export function signatureEvenementValide(corps: string, id: string | null, horodatage: string | null, signatures: string | null,
  maintenant = Date.now()): boolean {
  const secret = process.env.RESEND_WEBHOOK_SECRET ?? "";
  if (!secret.startsWith("whsec_") || !id || !horodatage || !signatures) return false;
  const t = Number(horodatage);
  if (!Number.isFinite(t) || Math.abs(maintenant / 1000 - t) > 300) return false;
  const attendue = createHmac("sha256", Buffer.from(secret.slice(6), "base64")).update(`${id}.${horodatage}.${corps}`).digest("base64");
  return signatures.split(" ").some((s) => s.startsWith("v1,") && egalSur(s.slice(3), attendue));
}

function stockageFactures(): StockageDevis {
  const admin = creerClientAdmin();
  return {
    async deposer() { throw new Error("Aucun dépôt depuis les relances"); },
    async lire(chemin) {
      const { data, error } = await admin.storage.from("factures").download(chemin);
      if (error || !data) return null;
      return new Uint8Array(await data.arrayBuffer());
    },
  };
}

const sha256 = (t: string) => createHash("sha256").update(t, "utf8").digest("hex");

export type Bilan = { actives: boolean; reprises: number; reservees: number; acceptees: number; temporaires: number; refus: number;
                      incertaines: number; ignorees: { facture: string; motif: string }[]; erreurs: string[];
                      evenements: { examines: number; rapproches: number; en_attente: number; alertes: number; purges: number } | null };

type Prise = { action: string; tentative: number; requete_texte: string; requete_empreinte: string; cle_idempotence: string;
               pdf_chemin: string; pdf_empreinte: string; statut?: string };

// Une tentative : prise de la demande (enregistrée AVANT l'appel), contrôles, appel, résultat.
async function tenter(relanceId: string, compte: string, b: Bilan) {
  const admin = creerClientAdmin();
  const cfg = configuration();
  const { data, error } = await admin.rpc("relances_prendre", { p_relance: relanceId, p_compte: compte });
  if (error) { b.erreurs.push(`Prise de la relance : ${error.message}`); return; }
  const p = data as Prise;
  if (p.action !== "envoyer") return;
  const resultat = async (issue: string, id: string | null, erreur: string | null) => {
    const { error: e } = await admin.rpc("relances_resultat", { p_relance: relanceId, p_tentative: p.tentative, p_issue: issue,
      p_fournisseur_id: id, p_erreur: erreur });
    if (e) b.erreurs.push(`Résultat de la relance : ${e.message}`);
    if (issue === "acceptee") b.acceptees++; else if (issue === "temporaire") b.temporaires++;
    else if (issue === "refus") b.refus++; else b.incertaines++;
  };
  // La demande envoyée est EXACTEMENT la demande figée : empreinte recalculée sur le texte rendu par la base.
  if (sha256(p.requete_texte) !== p.requete_empreinte) return resultat("incertain", null, "Demande figée altérée : aucun appel au fournisseur.");
  let pdf: Uint8Array;
  try {
    pdf = await lireArchiveVerifiee(stockageFactures(), p.pdf_chemin, p.pdf_empreinte);
  } catch (e) {
    const m = e instanceof Error ? e.message : String(e);
    return resultat(/altéré/.test(m) ? "incertain" : "temporaire", null, `${m} : aucun appel au fournisseur.`);
  }
  const demande = JSON.parse(p.requete_texte) as DemandeFournisseur;
  let statut: number | null = null, corps: unknown = null;
  try {
    const r = await fetch(`${cfg.url}/emails`, {
      method: "POST", signal: AbortSignal.timeout(DELAI_APPEL_MS),
      headers: { Authorization: `Bearer ${cfg.cle}`, "Content-Type": "application/json", "Idempotency-Key": p.cle_idempotence,
                 "User-Agent": "sgi-mini-erp-relances/1" },
      body: corpsFournisseur(demande, Buffer.from(pdf).toString("base64")),
    });
    statut = r.status;
    corps = await r.json().catch(() => null);
  } catch {
    statut = null; // coupure ou délai : l'email a PEUT-ÊTRE été accepté → reprise avec la même clé
  }
  const c = classerReponse(statut, corps);
  await resultat(c.issue, c.id, c.erreur);
}

// Une exécution (appelée par la future tâche Cron) : reprises d'abord, puis nouvelles relances dues, au plus `limite`.
export async function executerRelances(limite = 10): Promise<Bilan> {
  const cfg = configuration();
  const b: Bilan = { actives: cfg.actives, reprises: 0, reservees: 0, acceptees: 0, temporaires: 0, refus: 0, incertaines: 0,
                     ignorees: [], erreurs: [], evenements: null };
  const admin = creerClientAdmin();
  // À chaque exécution, même interrupteur coupé (aucun envoi) : rapprochement des événements en attente, puis nettoyage
  // des événements rapprochés ou classés depuis plus de 30 jours. Un événement en attente n'est jamais supprimé.
  const { data: rap, error: er } = await admin.rpc("relances_rapprocher_tout");
  const { data: purges, error: ep } = await admin.rpc("relances_purger_evenements");
  if (er || ep) b.erreurs.push(`Événements : ${(er ?? ep)!.message}`);
  else b.evenements = { ...(rap as { examines: number; rapproches: number; en_attente: number; alertes: number }), purges: purges as number };
  if (!cfg.actives) return b;
  if (!cfg.cle) { b.erreurs.push("Clé du fournisseur absente : aucune relance."); return b; }
  if (!referenceCompteValide(cfg.compte)) { b.erreurs.push("Référence du compte fournisseur absente ou non conforme : aucune relance."); return b; }
  const compte = cfg.compte;
  const { data: aReprendre, error: e1 } = await admin.rpc("relances_a_reprendre");
  if (e1) { b.erreurs.push(e1.message); return b; }
  for (const id of ((aReprendre ?? []) as string[]).slice(0, limite)) {
    b.reprises++;
    await tenter(id, compte, b);
  }
  const { data: apercu, error: e2 } = await admin.rpc("relances_apercu");
  if (e2) { b.erreurs.push(e2.message); return b; }
  type Ligne = FactureARelancer & { facture_id: string; rang: 1 | 2 | 3 | null; client_email: string | null; pdf_chemin: string };
  for (const f of (apercu ?? []) as Ligne[]) {
    if (!f.rang) continue;
    if (b.reprises + b.reservees >= limite) break;
    const relanceId = randomUUID();
    const c = construireDemande({ relanceId, rang: f.rang, facture: f, emailClient: f.client_email, adresseEssai: cfg.adresseEssai });
    if ("blocage" in c) { b.ignorees.push({ facture: f.numero, motif: c.blocage }); continue; }
    try {
      await lireArchiveVerifiee(stockageFactures(), f.pdf_chemin, f.pdf_empreinte); // PDF contrôlé AVANT la réservation
    } catch (e) {
      b.ignorees.push({ facture: f.numero, motif: e instanceof Error ? e.message : String(e) });
      continue;
    }
    const { data: res, error } = await admin.rpc("relances_reserver", { p_relance: relanceId, p_facture: f.facture_id,
      p_rang: f.rang, p_requete: c.demande });
    if (error) { b.erreurs.push(`Réservation ${f.numero} : ${error.message}`); continue; }
    const r = res as { reservee: boolean; motif?: string };
    if (!r.reservee) { b.ignorees.push({ facture: f.numero, motif: r.motif ?? "Réservation refusée" }); continue; }
    b.reservees++;
    await tenter(relanceId, compte, b);
  }
  return b;
}

// Événement de livraison vérifié : ENREGISTRÉ DURABLEMENT par la base (table relances_evenements) avec la référence du
// compte qui l'a signé, puis rapproché si possible (sinon conservé en attente, avec une alerte s'il y a une anomalie).
// Doublons, retards et désordre traités par la base. Sans référence de compte valide : erreur (le fournisseur renverra).
export async function enregistrerEvenement(idEvenement: string, charge: unknown): Promise<string> {
  const e = lireEvenement(charge);
  if (!e || (!e.emailId && !e.relanceId)) return "ignore";
  const compte = configuration().compte;
  if (!referenceCompteValide(compte)) throw new Error("Référence du compte fournisseur absente ou non conforme");
  const { data, error } = await creerClientAdmin().rpc("relances_recevoir_evenement", {
    p_evenement_id: idEvenement, p_type: e.type, p_fournisseur_id: e.emailId, p_relance: e.relanceId,
    p_survenu_le: e.survenuLe, p_detail: e.detail, p_compte: compte,
  });
  if (error) throw new Error(error.message);
  return (data as { resultat: string }).resultat;
}
