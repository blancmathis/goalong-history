> Mise à jour du cycle de vie : [Permission lifecycle and recovery](PERMISSION_LIFECYCLE.md).

# Diagnostic local et assistance

## Parcours utilisateur

**Signaler un problème…** est accessible depuis le menu **Aide**, le menu de la barre des menus, le bas des **Réglages**, **Réglages → Avancé → Aide et diagnostic**, la bannière affichée quand l’enregistrement est interrompu, les écrans d’autorisation et l’alerte d’échec au démarrage.

Un clic ouvre une fenêtre qui :

1. prépare le rapport en arrière-plan et l’enregistre dans le dossier privé `SupportReports/` (0700, fichiers 0600, cinq rapports au plus) ;
2. affiche **Ce que Goalong a détecté** : un résumé en français calculé à partir du journal (enregistrement interrompu, disque presque plein, arrêts inattendus, plantages, échecs de mise à jour, crédit de surveillance épuisé, erreurs répétées, autorisation manquante, interface bloquée) ;
3. rappelle **Ce que contient le rapport** et ce qu’il ne contient jamais ;
4. propose **Envoyer par e-mail…** (nouveau message de l’app de messagerie avec le fichier joint et un modèle à compléter), **Partager…** (Messages, AirDrop…) et, dans **Plus**, *Ajouter un repère*, *Actualiser le rapport* et *Enregistrer une copie…*.

Rien n’est envoyé automatiquement : l’utilisateur choisit le destinataire. Il n’existe ni collecteur, ni compte support, ni SDK de télémétrie.

Un interrupteur arrête la conservation des événements (déconseillé : le rapport ne décrit alors que l’instant présent). L’effacement ne touche qu’au journal technique.

## Contenu autorisé

Le schéma est fermé : composant, événement et état sont des énumérations ; les valeurs sont des booléens, nombres, états autorisés ou **symboles**. Un symbole est soit un identifiant du code compilé (type d’erreur Swift, nom du cas d’erreur, nom d’événement résumé), validé par `^[A-Za-z_][A-Za-z0-9_.]{0,127}$`, soit un numéro de version validé par `^[0-9]+(\.[0-9]+){0,3}$`. Les symboles ne sont acceptés que pour les clés prévues (`errorType`, `errorCase`, `repeatedEvent`, `version`, `build`, `previousVersion`, `previousBuild`, `availableVersion`) et sont revalidés à la relecture.

`failure` et `SupportDiagnostics.errorValues` conservent :

- le code numérique et une catégorie fixe (`urlError`, `cocoaError`, `posixError`, `osStatusError`, `machError`, `sparkleError`, `swiftError`, `otherError`) ;
- pour une erreur Swift, son type qualifié (ex. `LocalHistoryApp.JSONLStore.JSONLStoreError`), le nom de son cas lu par réflexion et, si le cas porte un seul entier, cet entier (ex. `JevError.http(402)`). Un type qui fournit sa propre description n’est jamais utilisé comme nom de cas ;
- pour une erreur Foundation, le nom du domaine uniquement s’il appartient à une liste fixe (Cocoa, POSIX, URL, OSStatus, Mach, Sparkle, CFNetwork) ;
- jusqu’à trois niveaux d’erreurs sous-jacentes, réduits à leur code et catégorie ; le plus profond est gardé comme `rootErrorCode` (souvent l’errno, par exemple 28 = disque plein).

La description, les chaînes de `userInfo`, les chemins et les domaines inconnus ne sont jamais lus. Le pont `Diagnostics.write` ne **calcule même pas** les anciens messages libres : seul leur emplacement compilé est conservé.

Le rapport contient aussi : version/build/révision et signature de Goalong, hash de son binaire, emplacement d’installation (catégorie), nombre de copies en cours d’exécution, version de macOS et architecture, états des sources et services, observations d’autorisation, espace libre du volume (Mo), taille des dossiers internes de Goalong (noms fixes : `events`, `seals`, `memories`…), état des mises à jour (vérification automatique, dernier résultat, version disponible), état de l’enregistrement (interrompu ou non, cause, observations perdues), sources activées et envoi quotidien au site (oui/non), compteurs bornés, réponses HTTP numériques et durées instrumentées.

Il exclut les contenus d’écran, captures, texte saisi, touches exactes, presse-papiers, audio, conversations, prompts, réponses du modèle, règles personnelles de productivité, historique d’activité, titres, URL, noms d’applications tierces, noms de fichiers utilisateur, chemins personnels, adresses e-mail, clés, jetons, cookies, identifiants de compte/appareil, environnement complet et bases brutes.

## Un journal lisible même pendant un incident

L’incident du 26–28/09/2026 (disque plein puis plus de 900 échecs identiques en quelques heures) a montré que la rotation effaçait la cause d’origine. Le journal applique désormais trois règles :

- **Regroupement des répétitions** : un événement identique (composant, événement, niveau, emplacement, valeurs discrètes) est conservé trois fois par tranche de dix minutes ; les suivants deviennent un seul `repeatSummary` avec `suppressedCount` exact, émis à la fin de la tranche, à l’export et à l’arrêt.
- **Événements périodiques sur changement** : pulsation, vérifications d’autorisation, cycles de surveillance et requêtes réussies passent par `recordIfChanged`, qui n’écrit que si une valeur discrète change (ou toutes les 15 à 30 minutes). Les délais et compteurs continus accompagnent l’événement sans le rendre nouveau.
- **Flux prioritaire** : avertissements, erreurs et changements d’état (démarrage, arrêt, mise à jour installée, repère utilisateur, santé de capture, mises à jour, reprise de l’enregistrement) sont écrits dans `day-AAAA-MM-JJ/important/`, qui a son propre budget. Les événements courants ne peuvent donc plus évincer la cause d’un problème.

## Conservation et sécurité des fichiers

Journal dans `SupportDiagnostics`, un dossier par date UTC. Par jour : deux segments de 256 Kio pour les événements courants et deux segments de 128 Kio pour le flux prioritaire. Sept dates conservées : plafond de 5,25 Mio hors métadonnées. La purge se fait au démarrage, au changement de date et à l’export, sans parcours de l’historique.

Les producteurs passent par une file bornée (128 éléments, 256 Kio en attente, 8 Kio par message) avec un seul drainage programmé. Aucune opération disque ni attente réseau n’a lieu dans le callback de capture. Répertoires privés (0700), fichiers privés (0600), liens symboliques et fichiers non réguliers refusés, fichiers à plusieurs liens physiques exclus à la lecture. L’effacement ne descend pas récursivement dans des données inconnues.

## Défaillance du journal et interface bloquée

Un tampon de 128 événements reste disponible en mémoire lorsque les écritures échouent. L’export attend au maximum deux secondes le journal disque et indique `diskSnapshotIncomplete` lorsque cette partie n’est pas disponible. La fermeture n’attend qu’une seconde le drainage. Les copies explicites utilisent un fichier temporaire privé puis un remplacement atomique sans suivre un lien symbolique.

Un contrôle de réactivité hors du thread principal peut signaler une absence de réponse de 30 secondes et la reprise ultérieure. Une longue suspension du minuteur de fond ou un retour d’horloge invalide le ping pour limiter les faux positifs de veille.

## Arrêts, crashes et mises à jour

Une marque d’arrêt propre est persistée ; son absence signale un arrêt non propre, **pas nécessairement un crash**. Au premier lancement d’une nouvelle version, `appUpdated` enregistre la version et le build précédents et actuels : un rapport montre ainsi exactement quelle mise à jour a précédé un problème.

Le cycle de mise à jour est journalisé : début de vérification (manuelle ou automatique), résultat (`upToDate`, `updateAvailable`, `failed` avec le code Sparkle et l’erreur réseau sous-jacente), choix de l’utilisateur (`install`, `skip`, `later`) et relance d’installation.

Seulement lors de l’export, jusqu’à cinq rapports IPS récents de **Goalong** peuvent être réduits à leur type d’exception, UUID du binaire et décalages des frames de ce binaire. Aucun rapport brut, chemin, symbole, registre ou rapport d’autre application n’est joint.

## Enregistrement interrompu

Si le journal d’événements refuse une écriture (disque plein, dossier non inscriptible), l’enregistreur ne s’arrête plus jusqu’au prochain lancement. Il compte les observations perdues, réessaie à l’événement suivant puis de façon espacée (5 s, 15 s… jusqu’à 5 minutes), réconcilie la chaîne d’intégrité avec la fin du journal durable exactement comme au démarrage, écrit un marqueur `observation_gap` (`gap_reason = storage_unavailable`, nombre et période des observations perdues) puis reprend. Pendant la coupure, la santé de capture passe à `storageUnavailable`, la barre latérale et le menu indiquent « Enregistrement interrompu » ou « Disque plein », et une bannière propose *Gérer le stockage…* et *Signaler le problème…*. Une alerte apparaît aussi quand il reste moins de 2 Go.

## Autorisations et récupération

L’assistant d’activation et le watchdog partagent le même mécanisme. Une autorisation est confirmée par le préflight de macOS ou, lorsqu’il est négatif, par la réussite d’une lecture **protégée d’un autre processus**. Une récupération explicite permet de réinitialiser **une seule** ancienne autorisation de Goalong via `/usr/bin/tccutil reset <service> ai.goalong.localhistory` (Accessibility, ListenEvent, SystemPolicyAllFiles), jamais « All ».

## Maintenance et limites

Pour instrumenter une nouvelle branche, ajouter l’événement, la clé ou l’état au schéma puis appeler `SupportDiagnostics.shared.record`, `recordIfChanged` (pour tout ce qui est périodique) ou `failure`. Ne jamais ajouter de champ texte libre, de dump de requête, de description d’erreur, de configuration ou de snapshot de capture complet. Un nouveau résumé lisible se déclare dans `SupportFindings.detect`. Mettre à jour la liste des fichiers avec `python3 scripts/generate_support_source_allowlist.py`.

Les tests `SupportDiagnosticsTests`, `SupportDiagnosticsHardeningTests`, `SupportDiagnosticsSignalTests`, `EventRecorderStorageRecoveryTests` et `PermissionReconciliationTests` couvrent les canaris privés, les symboles, les erreurs imbriquées, le regroupement, le flux prioritaire, la transition de version, les résumés, la reprise après disque plein, l’opt-out, la rotation, la purge, les liens et les résumés de crash.

Ce diagnostic améliore l’investigation des défaillances instrumentées, mais ne garantit ni la reproduction ni l’explication de tout bug. Le message pré-rempli invite l’utilisateur à décrire ce qu’il faisait et ce qu’il attendait.
