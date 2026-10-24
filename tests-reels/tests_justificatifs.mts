// Contrôles partagés du module Absences (src/lib/absences.ts), hors Next.js : signature réelle des fichiers,
// emplacement, demi-journées, estimation indicative, montants et soldes.
// Usage : node --experimental-strip-types tests-reels/tests_justificatifs.mts
import {
  cheminConforme, controlerDemande, estimationJoursOuvres, joursMaximum, lireMontant, lireSolde, signatureConforme, typeSelonSignature,
} from "../src/lib/absences.ts";

let ok = 0, ko = 0;
const verifier = (libelle: string, cond: boolean, detail = "") => {
  cond ? ok++ : ko++;
  console.log(`  [${cond ? "OK " : "ÉCHEC"}] ${libelle}${detail ? `  (${detail})` : ""}`);
};
const octets = (...b: number[]) => new Uint8Array(b);
const texte = (s: string) => new TextEncoder().encode(s);
const PDF = texte("%PDF-1.7\n…"), JPEG = octets(0xff, 0xd8, 0xff, 0xe0, 0, 0x10), PNG = octets(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0);

verifier("PDF reconnu par sa signature", signatureConforme("application/pdf", PDF) && typeSelonSignature(PDF) === "application/pdf");
verifier("JPEG reconnu", signatureConforme("image/jpeg", JPEG) && typeSelonSignature(JPEG) === "image/jpeg");
verifier("PNG reconnu", signatureConforme("image/png", PNG) && typeSelonSignature(PNG) === "image/png");
verifier("texte déclaré PDF : refusé", !signatureConforme("application/pdf", texte("bonjour")) && typeSelonSignature(texte("bonjour")) === null);
verifier("PNG déclaré PDF : refusé (contenu ≠ type)", !signatureConforme("application/pdf", PNG));
verifier("« %PDF » sans tiret (signature incomplète) : refusé", !signatureConforme("application/pdf", texte("%PDF1.4")));
verifier("fichier vide : refusé", !signatureConforme("application/pdf", new Uint8Array()));
verifier("type non prévu (GIF, HTML) : refusé", !signatureConforme("image/gif", texte("GIF89a")) && !signatureConforme("text/html", texte("<html>")));
const F = "22222222-2222-2222-2222-222222222221", U = "0f8fad5b-d9cb-469f-a165-70867728950e";
verifier("chemin conforme : <fiche>/<aléatoire>.pdf", cheminConforme(`${F}/${U}.pdf`, F, "application/pdf"));
verifier("chemin d'une autre fiche : refusé", !cheminConforme(`${F}/${U}.pdf`, "22222222-2222-2222-2222-222222222223", "application/pdf"));
verifier("extension incohérente avec le type : refusée", !cheminConforme(`${F}/${U}.png`, F, "application/pdf"));
verifier("remontée de dossier, sous-dossier, nom libre : refusés", !cheminConforme(`${F}/../${U}.pdf`, F, "application/pdf")
  && !cheminConforme(`${F}/a/${U}.pdf`, F, "application/pdf") && !cheminConforme(`${F}/facture.pdf`, F, "application/pdf"));
verifier("demi-journées : J matin → J+1 midi = 1,5 au plus", joursMaximum("2026-11-02", "2026-11-03", false, true) === 1.5);
verifier("demi-journées : J après-midi → J après-midi = 0,5", joursMaximum("2026-11-02", "2026-11-02", true, false) === 0.5);
verifier("demi-journées : J après-midi → J midi = impossible", joursMaximum("2026-11-02", "2026-11-02", true, true) === null);
verifier("refus explicite du même jour après-midi → midi", controlerDemande({ debut: "2026-11-02", fin: "2026-11-02", apresMidi: true, finMidi: true, jours: "0.5" })
  ?.startsWith("Demi-journées incohérentes") === true);
verifier("pas de 0,5 : 0,25 refusé, 1,5 accepté", !!controlerDemande({ debut: "2026-11-02", fin: "2026-11-03", apresMidi: false, finMidi: false, jours: "0,25" })
  && controlerDemande({ debut: "2026-11-02", fin: "2026-11-03", apresMidi: false, finMidi: false, jours: "1,5" }) === null);
verifier("0 et dépassement de la période refusés", !!controlerDemande({ debut: "2026-11-02", fin: "2026-11-02", apresMidi: false, finMidi: false, jours: "0" })
  && controlerDemande({ debut: "2026-11-02", fin: "2026-11-03", apresMidi: false, finMidi: false, jours: "3" })?.includes("(2 jour(s) au plus") === true);
verifier("estimation : lundi → dimanche = 5 jours ouvrés (week-end exclu, jours fériés NON déduits)",
  estimationJoursOuvres("2026-11-02", "2026-11-08", false, false) === 5);
verifier("estimation : vendredi après-midi → lundi midi = 1", estimationJoursOuvres("2026-11-06", "2026-11-09", true, true) === 1);
verifier("montant : 42,50 lu ; 10,005 et 0 refusés", lireMontant("42,50") === 42.5 && typeof lireMontant("10,005") === "string" && typeof lireMontant("0") === "string");
verifier("solde : 0 accepté (vraie valeur), vide et négatif refusés", lireSolde("0") === 0 && typeof lireSolde("") === "string" && typeof lireSolde("-1") === "string");
console.log(`\nBILAN : ${ok}/${ok + ko} contrôles réussis`);
