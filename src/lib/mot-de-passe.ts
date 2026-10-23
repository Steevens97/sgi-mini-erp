import "server-only";
import { randomInt } from "node:crypto";

// Sans caractères ambigus (0/O, 1/l/I) pour être recopiable sans erreur.
const MAJUSCULES = "ABCDEFGHJKLMNPQRSTUVWXYZ";
const MINUSCULES = "abcdefghijkmnopqrstuvwxyz";
const CHIFFRES = "23456789";
const ALPHABET = MAJUSCULES + MINUSCULES + CHIFFRES;

// Mot de passe provisoire aléatoire (générateur cryptographique), ex. « Xk7m-P9qR-t2Wz ».
// Il n'est jamais journalisé ni stocké : il est renvoyé une seule fois à l'écran.
export function genererMotDePasseProvisoire(): string {
  for (;;) {
    const groupes = Array.from({ length: 3 }, () =>
      Array.from({ length: 4 }, () => ALPHABET[randomInt(ALPHABET.length)]).join(""),
    );
    const mdp = groupes.join("-");
    if (/[A-Z]/.test(mdp) && /[a-z]/.test(mdp) && /[2-9]/.test(mdp)) return mdp;
  }
}
