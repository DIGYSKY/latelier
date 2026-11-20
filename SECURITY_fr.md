# Politique de sécurité

<sub>[English](SECURITY.md) · **Français**</sub>

L’Atelier supprime des fichiers, lance des commandes, modifie `~/.ssh/config`, agit sur vos
serveurs et se met à jour tout seul. Les signalements de sécurité sont pris au sérieux et traités
en priorité.

## Signaler une faille

**Merci de ne pas ouvrir d’issue publique.** Utilisez un
[signalement de sécurité privé](https://github.com/DIGYSKY/latelier/security/advisories/new) sur GitHub.

Indiquez si possible :
- la version (Réglages › À propos › Copier les infos de diagnostic) ;
- ce qu’un attaquant peut faire, et dans quelles conditions ;
- les étapes pour reproduire, ou une preuve de concept.

Vous aurez une réponse sous une semaine. Une fois corrigée, la faille est publiée avec le correctif
et vous est créditée, sauf si vous préférez rester anonyme.

## Versions suivies

Pendant la bêta, seule la **dernière** version `1.0.0-beta` reçoit les correctifs. La mise à jour
intégrée les apporte à tous les utilisateurs.

## Ce qui est concerné

- Supprimer ou modifier quoi que ce soit sans aperçu, ou hors du dossier personnel.
- Injection de commande : commandes locales, commandes SSH distantes, noms de fichiers sur un serveur.
- La mise à jour : installer une app non vérifiée (empreinte, certificat de signature).
- Des données envoyées sur le réseau au-delà de ce que liste le tableau Confidentialité du README.
