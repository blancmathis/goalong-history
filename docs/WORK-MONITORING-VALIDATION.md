# Surveillance et présentation des mises à jour — validation

Les fenêtres réelles du pilote standard Sparkle 2.9.6 (vérification et téléchargement)
ont été exercées hors écran sans updater, réseau ou installation : parent Goalong,
niveau au-dessus du tableau de bord et restauration de la relation vérifiés.

L’évaluation sémantique locale a utilisé 12 situations entièrement synthétiques,
avec une référence de projet fictive, sans envoyer d’historique réel. Sur le dernier
passage : **8 résultats attendus, 4 abstentions, aucun classement opposé**. Les
abstentions concernaient une lecture historique hors projet, un jeu développé hors
projet, un fichier source du bon projet et un homonyme du nom de projet. Ce n’est
pas un taux de précision généralisable ; les essais précédents ont montré la
sensibilité du modèle aux formulations et aux titres insuffisants.

Les recherches pertinentes et hors projet, les vidéos éducatives, le fil social,
les rédactions pertinentes et hors sujet et l’absence de titre étaient distingués
sur ce passage. Les requêtes observées étaient de 658 à 721 octets et 439 à 452 tokens
d’entrée. Le plafond JSON complet de 800 octets et le contrôle des 999 tokens restent
appliqués à chaque réponse ; la référence de travail est limitée à 100 octets.

Les tests opt-in `JevSemanticEvaluationTests` conservent les labels attendus et
échouent sur une abstention inattendue : ils servent à exposer les limites, pas à
prétendre qu’un test simulé valide le jugement réel. Ils ne s’exécutent pas lors
des tests CI usuels et ne lisent la clé locale qu’avec l’option explicite prévue.

L’erreur de somme des probabilités arrondies a été reproduite (0,81 + 0,13 + 0,05),
puis corrigée par une réduction à ordre fixe et une tolérance de 0,01 + 1e-9. Aucune
probabilité n’est remontée artificiellement ; le seuil de décision reste 0,80.


## Évolution des critères le 24 septembre 2026

Les résultats chiffrés ci-dessus concernent l’ancien profil et l’ancien prompt.
Le nouveau format accepte projets, applications/sites et contenus (800 octets au
total), avec une enveloppe JSON maximale de 1 600 octets. Le plafond de réponse
acceptée reste 999 tokens. Voir `MONITORING-STABILITY.md` ; ne pas présenter les
scores historiques comme une évaluation du nouveau prompt.
