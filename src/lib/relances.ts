// Relances automatiques des factures : constantes, textes validés par l'utilisateur (25/10/2026), construction de la
// demande au fournisseur et classement de ses réponses. Fichier ordinaire, SANS secret ni accès réseau : utilisé par
// l'écran (simulation comprise) et par le module d'envoi ; testé hors Next.js (tests-reels/tests_relances_module.mts).
// La base revérifie tout (migration 20261029100000) : demande figée, adresses, calendrier, horaires, secrets.

// Même format que euros() de format.ts, recopié : ce fichier est aussi testé avec Node seul (hors Next.js), qui ne
// résout pas les imports sans extension ; l'égalité des deux est vérifiée par tests-reels/tests_relances_module.mts.
export function eurosRelance(n: number | string): string {
  const v = Number(n ?? 0);
  const [entier, dec] = Math.abs(v).toFixed(2).split(".");
  return `${v < 0 ? "-" : ""}${entier.replace(/\B(?=(\d{3})+(?!\d))/g, " ")},${dec} €`;
}

export type Expediteur = { nom: string; adresse: string; reponse: string };

// VALEURS RÉELLES — vides tant que l'utilisateur n'a pas de domaine vérifié chez le fournisseur ni confirmé la
// signature : les relances réelles restent bloquées (application et base). Aucune valeur n'est inventée.
export const EXPEDITEUR_RELANCES: Expediteur = { nom: "", adresse: "", reponse: "" };
export const SIGNATURE_RELANCES = "";

// Relances d'ESSAI (factures d'ESSAI seulement) : expéditeur de test du fournisseur (sans domaine vérifié, Resend
// n'envoie qu'à l'adresse du compte), destinataire = adresse de test confirmée par l'utilisateur (variable
// RELANCES_ADRESSE_ESSAI, vide = aucun envoi d'essai), jamais l'adresse d'un client.
export const EXPEDITEUR_ESSAI: Expediteur = { nom: "SG Ingénierie [ESSAI]", adresse: "onboarding@resend.dev", reponse: "" };
export const SIGNATURE_ESSAI = "SG Ingénierie (message d'essai, sans valeur)";

// Textes validés par l'utilisateur (25/10/2026) : aucune pénalité, aucune menace, aucune coordonnée bancaire.
export const TEXTES_RELANCES: Record<1 | 2 | 3, { objet: string; corps: string }> = {
  1: {
    objet: "Facture {numero} : rappel d'échéance",
    corps: "Bonjour,\n\nSauf erreur de notre part, la facture {numero} du {date_emission}, d'un montant de {total_ttc} TTC, " +
      "arrivée à échéance le {date_echeance}, ne semble pas encore réglée.\n\nVous la trouverez ci-jointe. Si le règlement a " +
      "déjà été effectué, merci de ne pas tenir compte de ce message.\n\nNous restons à votre disposition pour toute " +
      "question.\n\nCordialement,\n{signature}",
  },
  2: {
    objet: "Facture {numero} : second rappel",
    corps: "Bonjour,\n\nNous revenons vers vous au sujet de la facture {numero} du {date_emission}, d'un montant de " +
      "{total_ttc} TTC, échue le {date_echeance}, qui reste à ce jour impayée selon nos informations.\n\nPourriez-vous " +
      "nous indiquer la date de règlement prévue, ou nous signaler toute difficulté éventuelle ? La facture est de nouveau " +
      "jointe à ce message.\n\nSi le paiement est en cours, merci de ne pas tenir compte de ce rappel.\n\nCordialement,\n{signature}",
  },
  3: {
    objet: "Facture {numero} : dernier rappel avant contact direct",
    corps: "Bonjour,\n\nMalgré nos précédents messages, la facture {numero} du {date_emission}, d'un montant de {total_ttc} " +
      "TTC, échue le {date_echeance}, n'apparaît toujours pas comme réglée.\n\nCe message est notre dernier rappel " +
      "automatique : nous vous contacterons directement si nécessaire. Pour faciliter le traitement, la facture est " +
      "jointe.\n\nSi le règlement a été effectué entre-temps, merci de ne pas tenir compte de ce message, et veuillez nous " +
      "excuser pour ce rappel.\n\nCordialement,\n{signature}",
  },
};
export const MENTION_ESSAI = "[ESSAI — SANS VALEUR] Ce message est un essai : aucune somme n'est due.\n\n";

export const CALENDRIER_RELANCES =
  "Relances n° 1, 2 et 3 à J+7, J+15 et J+30 après l'échéance, dans l'ordre, au moins 8 jours entre deux relances " +
  "acceptées par le fournisseur, au plus une par facture et par jour ; du lundi au vendredi, de 8 h à 17 h (heure de " +
  "Martinique). Les jours fériés ne sont pas exclus.";

export const LIMITES_RELANCES = [
  "Les jours fériés ne sont pas exclus : un jour férié en semaine reste un jour d'envoi.",
  "Seules les factures émises ou envoyées, impayées et échues sont relancées ; jamais les congés ni les notes de frais.",
  "Le PDF archivé de la facture est joint après contrôle de son empreinte ; il n'est jamais régénéré.",
  "« Acceptée » signifie prise en charge par le fournisseur ; « Livrée » (suivi de livraison) signifie remise au serveur " +
    "du destinataire ; aucune des deux ne dit si l'email a été lu.",
  "Offre gratuite du fournisseur : 100 emails par jour au plus.",
];

export const LIBELLES_STATUT_RELANCE: Record<string, string> = {
  reservee: "Réservée — aucun envoi",
  en_cours: "Envoi non confirmé",
  acceptee: "Acceptée par le fournisseur",
  refusee: "Refusée par le fournisseur — aucun email",
  rejetee: "Rejetée par le serveur du destinataire",
  a_verifier: "À vérifier — envoi incertain",
  abandonnee: "Abandonnée — aucun email",
};

export const CONSTATS_RESOLUTION = [
  { valeur: "email_accepte", libelle: "Email accepté (constaté dans le tableau de bord du fournisseur)", pour: ["en_cours", "a_verifier"] },
  { valeur: "aucun_envoi", libelle: "Aucun email parti (constaté)", pour: ["reservee", "en_cours", "a_verifier"] },
  { valeur: "traitee", libelle: "Refus ou rejet traité (ex. adresse corrigée)", pour: ["refusee", "rejetee"] },
] as const;

export type FactureARelancer = {
  numero: string; date_emission: string; date_echeance: string; total_ttc: number | string; essai: boolean; pdf_empreinte: string;
};

export type DemandeFournisseur = {
  fournisseur: "resend"; version: 1; from: string; to: string; reply_to: string | null; subject: string; text: string;
  piece_jointe: { nom: string; type: "application/pdf"; empreinte: string };
  tags: { name: "relance_id"; value: string }[];
};

const dateFrIso = (iso: string) => iso.slice(0, 10).split("-").reverse().join("/");

// Ce qui manque pour une relance RÉELLE (domaine vérifié, expéditeur, signature) : vide = rien ne manque.
export function blocagesRelancesReelles(): string[] {
  const b: string[] = [];
  if (!EXPEDITEUR_RELANCES.adresse) b.push("Adresse d'expédition sur un domaine vérifié chez le fournisseur : à fournir (aucun domaine pour le moment).");
  if (!EXPEDITEUR_RELANCES.nom) b.push("Nom de l'expéditeur : à fournir.");
  if (!SIGNATURE_RELANCES) b.push("Signature des emails : à confirmer.");
  if (/@resend\.dev$/i.test(EXPEDITEUR_RELANCES.adresse)) b.push("L'expéditeur de test du fournisseur est interdit pour une relance réelle.");
  return b;
}

// Demande complète au fournisseur, figée à la réservation (la base la contrôle et en calcule l'empreinte).
export function construireDemande(p: {
  relanceId: string; rang: 1 | 2 | 3; facture: FactureARelancer; emailClient: string | null; adresseEssai: string | null;
}): { demande: DemandeFournisseur } | { blocage: string } {
  const { facture: f } = p;
  if (f.essai && !p.adresseEssai) return { blocage: "Adresse de test non confirmée : aucune relance d'essai." };
  if (!f.essai) {
    const b = blocagesRelancesReelles();
    if (b.length) return { blocage: b[0] };
    if (!p.emailClient) return { blocage: "Client sans email." };
  }
  const exp = f.essai ? EXPEDITEUR_ESSAI : EXPEDITEUR_RELANCES;
  const signature = f.essai ? SIGNATURE_ESSAI : SIGNATURE_RELANCES;
  const remplir = (t: string) => t
    .replaceAll("{numero}", f.numero).replaceAll("{date_emission}", dateFrIso(f.date_emission))
    .replaceAll("{date_echeance}", dateFrIso(f.date_echeance)).replaceAll("{total_ttc}", eurosRelance(f.total_ttc))
    .replaceAll("{signature}", signature);
  const texte = TEXTES_RELANCES[p.rang];
  return {
    demande: {
      fournisseur: "resend", version: 1,
      from: `${exp.nom} <${exp.adresse}>`,
      to: (f.essai ? p.adresseEssai! : p.emailClient!).trim().toLowerCase(),
      reply_to: exp.reponse || null,
      subject: (f.essai ? "[ESSAI] " : "") + remplir(texte.objet),
      text: (f.essai ? MENTION_ESSAI : "") + remplir(texte.corps),
      piece_jointe: { nom: `${f.numero}.pdf`, type: "application/pdf", empreinte: f.pdf_empreinte },
      tags: [{ name: "relance_id", value: p.relanceId }],
    },
  };
}

// Corps exact envoyé au fournisseur : construit UNIQUEMENT depuis la demande figée et le PDF archivé (même entrée →
// même corps, à chaque reprise). Aucun secret : la clé du fournisseur n'est que dans l'en-tête Authorization.
export function corpsFournisseur(d: DemandeFournisseur, pdfBase64: string): string {
  return JSON.stringify({
    from: d.from, to: [d.to], subject: d.subject, text: d.text,
    ...(d.reply_to ? { reply_to: [d.reply_to] } : {}),
    attachments: [{ filename: d.piece_jointe.nom, content: pdfBase64 }],
    tags: d.tags.map((t) => ({ name: t.name, value: t.value })),
  });
}

export type Issue = "acceptee" | "temporaire" | "refus" | "incertain";

// Classement d'une réponse du fournisseur (Resend) :
//   200 + identifiant → acceptée ;
//   409 « concurrent_idempotent_requests » (même clé encore en cours), 429, 5xx, 401 (clé refusée : rien n'est traité),
//   coupure ou délai dépassé → temporaire (même demande, même clé, plus tard, dans la limite de reprise) ;
//   400, 403, 422 → refus certain (aucun email) ;
//   409 « invalid_idempotent_request » (contenu différent pour la même clé) ou réponse inattendue → incertain.
export function classerReponse(statut: number | null, corps: unknown): { issue: Issue; id: string | null; erreur: string | null } {
  const c = (corps ?? {}) as { id?: unknown; name?: unknown; message?: unknown };
  const nom = typeof c.name === "string" ? c.name : "";
  const msg = typeof c.message === "string" ? c.message : "";
  const erreur = statut === null ? "Coupure ou délai dépassé (réponse inconnue)" : `HTTP ${statut}${nom ? ` ${nom}` : ""}${msg ? ` : ${msg}` : ""}`.slice(0, 250);
  if (statut !== null && statut >= 200 && statut < 300) {
    return typeof c.id === "string" && c.id ? { issue: "acceptee", id: c.id, erreur: null } : { issue: "incertain", id: null, erreur: "Réponse sans identifiant" };
  }
  if (statut === null || statut === 429 || statut >= 500 || statut === 401) return { issue: "temporaire", id: null, erreur };
  if (statut === 409) return { issue: nom === "concurrent_idempotent_requests" ? "temporaire" : "incertain", id: null, erreur };
  if (statut === 400 || statut === 403 || statut === 422) return { issue: "refus", id: null, erreur };
  return { issue: "incertain", id: null, erreur };
}

// Événement de livraison (webhook) : identifiant de l'email et étiquette de la relance (objet ou liste).
export function lireEvenement(charge: unknown): { type: string; survenuLe: string; emailId: string | null; relanceId: string | null; detail: string | null } | null {
  const e = charge as { type?: unknown; created_at?: unknown; data?: Record<string, unknown> };
  if (typeof e?.type !== "string" || !e.type.startsWith("email.") || typeof e.created_at !== "string" || !e.data) return null;
  const tags = e.data.tags;
  let relance: unknown = null;
  if (Array.isArray(tags)) relance = (tags as { name?: unknown; value?: unknown }[]).find((t) => t?.name === "relance_id")?.value;
  else if (tags && typeof tags === "object") relance = (tags as Record<string, unknown>).relance_id;
  const uuid = typeof relance === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(relance) ? relance : null;
  const bounce = e.data.bounce as { message?: unknown; type?: unknown } | undefined;
  const detail = typeof bounce?.message === "string" ? bounce.message : typeof bounce?.type === "string" ? bounce.type : null;
  return { type: e.type, survenuLe: e.created_at, emailId: typeof e.data.email_id === "string" ? e.data.email_id : null, relanceId: uuid, detail };
}
