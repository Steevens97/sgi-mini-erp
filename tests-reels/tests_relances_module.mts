// Bibliothèque des relances (src/lib/relances.ts), hors Next.js : textes validés, demande figée, corps envoyé au
// fournisseur, classement des réponses, lecture des événements. Aucun appel réseau.
// Usage : node --experimental-strip-types tests-reels/tests_relances_module.mts
import { classerReponse, construireDemande, corpsFournisseur, eurosRelance, lireEvenement, blocagesRelancesReelles,
         TEXTES_RELANCES, type FactureARelancer } from "../src/lib/relances.ts";
import { euros } from "../src/lib/format.ts";

let ok = 0, ko = 0;
const verifier = (libelle: string, cond: boolean, detail = "") => {
  cond ? ok++ : ko++;
  console.log(`  [${cond ? "OK " : "ÉCHEC"}] ${libelle}${detail ? `  (${detail})` : ""}`);
};
const ID = "0f8fad5b-d9cb-469f-a165-70867728950e";
const F: FactureARelancer = { numero: "ESSAI-FAC-2026-0001", date_emission: "2026-09-01", date_echeance: "2026-10-01",
  total_ttc: "1085.5", essai: true, pdf_empreinte: "a".repeat(64) };

verifier("montant au même format que l'écran (1 085,50 €, -12,30 €, 0,00 €)",
  [1085.5, -12.3, 0, "1234567.891"].every((n) => eurosRelance(n) === euros(n)) && eurosRelance(1085.5) === "1 085,50 €");
const sans = construireDemande({ relanceId: ID, rang: 1, facture: F, emailClient: "x@client.fr", adresseEssai: null });
verifier("essai sans adresse de test confirmée : aucune demande", "blocage" in sans && sans.blocage.startsWith("Adresse de test non confirmée"));
const reel = construireDemande({ relanceId: ID, rang: 1, facture: { ...F, essai: false }, emailClient: "x@client.fr", adresseEssai: "t@ok.fr" });
verifier("relance réelle : bloquée tant que domaine, expéditeur et signature manquent",
  "blocage" in reel && blocagesRelancesReelles().length === 3);
const c = construireDemande({ relanceId: ID, rang: 1, facture: F, emailClient: "x@client.fr", adresseEssai: " Test@Exemple.FR " });
const d = "demande" in c ? c.demande : null;
verifier("essai : destinataire = adresse de test (minuscules), jamais l'email du client", d?.to === "test@exemple.fr");
verifier("essai : expéditeur de test du fournisseur, objet préfixé [ESSAI]",
  d?.from === "SG Ingénierie [ESSAI] <onboarding@resend.dev>" && d.subject === "[ESSAI] Facture ESSAI-FAC-2026-0001 : rappel d'échéance");
verifier("texte n° 1 : exactement le texte validé, champs remplis (dates jj/mm/aaaa, montant TTC)",
  d!.text === "[ESSAI — SANS VALEUR] Ce message est un essai : aucune somme n'est due.\n\nBonjour,\n\nSauf erreur de notre part, " +
  "la facture ESSAI-FAC-2026-0001 du 01/09/2026, d'un montant de 1 085,50 € TTC, arrivée à échéance le 01/10/2026, ne semble " +
  "pas encore réglée.\n\nVous la trouverez ci-jointe. Si le règlement a déjà été effectué, merci de ne pas tenir compte de ce " +
  "message.\n\nNous restons à votre disposition pour toute question.\n\nCordialement,\nSG Ingénierie (message d'essai, sans valeur)");
verifier("aucun texte ne parle de pénalité, d'indemnité, d'intérêts ni de poursuites",
  Object.values(TEXTES_RELANCES).every((t) => !/pénalit|indemnit|intérêt|poursuite|contentieux|huissier|mise en demeure/i.test(t.objet + t.corps)));
verifier("objets des relances n° 2 et 3 conformes",
  TEXTES_RELANCES[2].objet === "Facture {numero} : second rappel" && TEXTES_RELANCES[3].objet === "Facture {numero} : dernier rappel avant contact direct");
verifier("pièce jointe : nom = numéro, type PDF, empreinte du PDF archivé ; étiquette de la relance",
  d!.piece_jointe.nom === "ESSAI-FAC-2026-0001.pdf" && d!.piece_jointe.empreinte === "a".repeat(64)
  && JSON.stringify(d!.tags) === JSON.stringify([{ name: "relance_id", value: ID }]));
const corps1 = corpsFournisseur(d!, "QUJD"), corps2 = corpsFournisseur(JSON.parse(JSON.stringify(d)), "QUJD");
verifier("corps envoyé : identique à chaque reprise (même demande figée, même PDF)", corps1 === corps2);
verifier("corps envoyé : aucune clé ni secret (seulement l'en-tête Authorization en porte un)",
  !/re_|Bearer|Authorization|whsec_|api_key/i.test(corps1));
verifier("corps envoyé : destinataire, pièce jointe en base64, sans adresse de réponse vide",
  JSON.parse(corps1).to[0] === "test@exemple.fr" && JSON.parse(corps1).attachments[0].content === "QUJD" && !("reply_to" in JSON.parse(corps1)));
const cas: [number | null, unknown, string][] = [
  [200, { id: "em-1" }, "acceptee"], [200, {}, "incertain"], [429, { name: "rate_limit_exceeded" }, "temporaire"],
  [500, null, "temporaire"], [503, null, "temporaire"], [null, null, "temporaire"], [401, { name: "missing_api_key" }, "temporaire"],
  [409, { name: "concurrent_idempotent_requests" }, "temporaire"], [409, { name: "invalid_idempotent_request" }, "incertain"],
  [422, { name: "validation_error" }, "refus"], [403, { name: "validation_error" }, "refus"], [400, null, "refus"], [418, null, "incertain"],
];
verifier("classement des réponses (acceptée, temporaire, refus certain, incertain)",
  cas.every(([s, b, attendu]) => classerReponse(s, b).issue === attendu),
  cas.filter(([s, b, a]) => classerReponse(s, b).issue !== a).map(([s]) => String(s)).join(","));
verifier("acceptation : identifiant du fournisseur retenu", classerReponse(200, { id: "em-1" }).id === "em-1");
verifier("message d'erreur : code et nom seulement (jamais d'en-tête)",
  classerReponse(422, { name: "validation_error", message: "Invalid `to` field" }).erreur === "HTTP 422 validation_error : Invalid `to` field");
const ev = lireEvenement({ type: "email.bounced", created_at: "2026-11-02T19:11:00Z",
  data: { email_id: "em-1", tags: { relance_id: ID }, bounce: { message: "Mailbox does not exist" } } });
verifier("événement : type, date, identifiant, étiquette (objet) et motif du rejet lus",
  ev?.type === "email.bounced" && ev.emailId === "em-1" && ev.relanceId === ID && ev.detail === "Mailbox does not exist");
verifier("événement : étiquette en liste lue aussi ; étiquette non conforme ignorée",
  lireEvenement({ type: "email.sent", created_at: "x", data: { email_id: "e", tags: [{ name: "relance_id", value: ID }] } })?.relanceId === ID
  && lireEvenement({ type: "email.sent", created_at: "x", data: { email_id: "e", tags: { relance_id: "'; drop" } } })?.relanceId === null);
verifier("événement d'un autre type (contact, domaine) ignoré", lireEvenement({ type: "contact.created", created_at: "x", data: {} }) === null);
console.log(`\nBILAN : ${ok}/${ok + ko} contrôles réussis`);
