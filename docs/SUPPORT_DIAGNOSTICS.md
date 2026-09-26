# Diagnostic local et assistance

## Parcours utilisateur

Dans **Réglages → Avancé → Diagnostic et assistance** (également dans le stockage et dans les écrans d’autorisation), cliquer **Marquer le problème maintenant**, reproduire le problème, puis **Exporter un diagnostic…**. L’utilisateur choisit le fichier JSON, peut le lire et décide lui-même de l’envoyer. Aucun téléversement, collecteur, compte support, SDK de télémétrie ou envoi automatique n’est ajouté.

Un interrupteur arrête la conservation des événements. Le bouton d’effacement ne touche qu’au nouveau journal technique ; il ne supprime ni historique d’activité, ni réglages, ni rapports déjà exportés, ni anciens fichiers bruts. L’export reste possible même avec une source désactivée ou des autorisations manquantes.

## Contenu autorisé

Le schéma est fermé : composant, événement et état sont des énumérations ; les valeurs sont des booléens, nombres ou états autorisés. Aucun champ libre n’est prévu pour une description de problème. Les événements portent leur date, un UUID aléatoire par lancement, un compteur et un emplacement dans le code (nom public de fichier compilé et ligne, jamais chemin personnel).

Le rapport contient la version/build de Goalong, sa révision, la catégorie et la validité de sa signature, un hash de son binaire, la catégorie de son emplacement d’installation, le nombre de copies en cours d’exécution, la version de macOS, l’architecture, les états des sources et services, les observations d’autorisation, des compteurs bornés, les codes numériques d’erreur, les réponses HTTP numériques et les durées d’opération instrumentées. Les horaires et métadonnées techniques restent potentiellement sensibles : le fichier doit être transmis volontairement à un interlocuteur de confiance.

Il exclut les contenus d’écran, captures, texte saisi, touches exactes, presse-papiers, audio, conversations, prompts, réponses du modèle, règles personnelles de productivité, historique d’activité, titres, URL, noms d’applications tierces, noms de fichiers utilisateur, chemins personnels, adresses e-mail, clés, jetons, cookies, identifiants de compte/appareil, environnement complet, préférences et bases brutes. Les classifications personnelles de productivité ne sont pas journalisées.

`failure` ne lit que le code NSError et traduit son domaine vers quatre catégories fixes. Il ignore la description, le domaine inconnu en clair, le dictionnaire `userInfo` et les erreurs imbriquées. Le pont `Diagnostics.write` ne **calcule même pas** les anciens messages libres : seul leur emplacement compilé est conservé. Les anciens `diagnostics.log` ne sont jamais intégrés au rapport.

L’export décode et reconstruit chaque événement avec le schéma fermé. Les enregistrements corrompus, trop gros, trop anciens ou contenant des champs/états/source non autorisés sont rejetés ; les clés supplémentaires ne sont pas recopiées. Le nombre d’enregistrements rejetés, d’événements perdus par surcharge dans le lancement courant et d’échecs d’écriture est indiqué.

## Conservation et sécurité des fichiers

Journal dans le sous-dossier `SupportDiagnostics` du répertoire de données de Goalong. Un dossier par date UTC, avec deux segments au maximum de 256 Kio chacun. Sept dates conservées : plafond de 3,5 Mio hors métadonnées du système de fichiers. La rotation peut raccourcir la période disponible lors d’une journée très active. La purge se fait au démarrage, au changement de date et à l’export, sans parcours de l’historique. Un programme qui ne tourne pas ne peut pas effectuer une purge.

Les producteurs passent par une file bornée (128 éléments, 256 Kio en attente, 8 Kio par message) avec un seul drainage programmé. Aucune opération disque ni attente réseau n’a lieu dans le callback de capture. Les répertoires du journal sont privés (0700), les fichiers sont privés (0600), les liens symboliques et fichiers non réguliers sont refusés et les fichiers à plusieurs liens physiques sont exclus à la lecture. L’effacement ne descend pas récursivement dans des données inconnues.

## Défaillance du journal et interface bloquée

Un tampon de 128 événements techniques reste disponible en mémoire lorsque les écritures échouent. L’export attend au maximum deux secondes le journal disque et indique `diskSnapshotIncomplete` lorsque cette partie n’est pas disponible ou a subi des erreurs. Les demandes répétées ne créent pas une file illimitée de lectures. La fermeture n’attend qu’une seconde le drainage du journal et ne prétend pas avoir correctement finalisé les écritures lorsque ce délai expire. Les sauvegardes explicites utilisent un fichier temporaire privé (0600) dans le dossier choisi, puis un remplacement atomique sans suivre un lien symbolique de destination.

Un contrôle de réactivité hors du thread principal ne garde qu’un ping en attente. Il peut signaler une absence de réponse de 30 secondes et la reprise ultérieure, même si la fenêtre principale était bloquée. Une longue suspension du minuteur de fond ou un retour d’horloge invalide le ping pour limiter les faux positifs de veille. Aucun contenu ou stack de l’utilisateur n’est collecté ; ces indices ne prouvent pas à eux seuls la cause d’un blocage.

## Arrêts et crashes

Une marque d’arrêt propre est persistée. Son absence au prochain lancement signale un arrêt non propre, **pas nécessairement un crash** : fermeture forcée, extinction ou interruption peuvent produire le même résultat. Un retard du minuteur n’est pas non plus une preuve de blocage : veille et App Nap peuvent le retarder.

Seulement lors de l’export, jusqu’à cinq rapports IPS récents de **Goalong** accessibles sans autorisation supplémentaire peuvent être réduits à leur type d’exception, UUID de son binaire et décalages des frames appartenant à ce binaire. Aucun rapport brut, chemin, symbole, registre, adresse mémoire, payload d’exception, rapport d’autre application ou journal système global n’est joint. Une absence de résumé ne prouve pas une absence de crash. Les UUID et offsets servent à corréler le binaire et, lorsqu’ils sont disponibles, les symboles de compilation.

## Autorisations et récupération

L’assistant d’activation et le watchdog partagent le même mécanisme. Une autorisation est confirmée par le préflight de macOS ou, lorsqu’il est négatif, par la réussite d’une lecture **protégée d’un autre processus**. La lecture de sa propre fenêtre ou d’un simple rôle d’application n’est pas une preuve d’autorisation. Deux cibles au maximum sont sondées, avec délai AX borné à 120 ms par cible, sans lecture de titre ou de contenu. Une panne AX temporaire ne révoque pas une autorisation accordée ; la santé de capture reste évaluée séparément. Aucun ancien succès n’est conservé après une nouvelle vérification négative.

Une récupération explicite permet à l’utilisateur de supprimer **une seule** ancienne autorisation de Goalong via `/usr/bin/tccutil reset <service> ai.goalong.localhistory`. Les trois services autorisés sont Accessibility, ListenEvent et SystemPolicyAllFiles. Il n’existe ni reset All, ni modification de base TCC, ni resignature, ni contournement, ni octroi automatique. Le processus reçoit un environnement minimal, aucun shell et aucun argument utilisateur. Après confirmation, l’utilisateur réaccorde l’accès dans les réglages macOS et relance l’application. L’historique et les choix de sources ne sont pas modifiés.

## Maintenance et limites

Pour instrumenter une nouvelle branche, ajouter un événement/une clé/une valeur catégorielle au schéma puis appeler `SupportDiagnostics.record` ou `failure`. Ne jamais ajouter de champ String libre, de dump de requête, d’Error description, de configuration ou de snapshot de capture complet. Mettre à jour la liste des fichiers avec `python3 scripts/generate_support_source_allowlist.py`.

Les tests `SupportDiagnosticsTests` et `PermissionReconciliationTests` couvrent les canaris privés, les erreurs imbriquées, les champs inconnus, l’opt-out, la rotation, la purge, les liens, les résumés de crash, les autorisations incohérentes/révoquées et le périmètre de réparation. Les audits de confidentialité vérifient les frontières de processus.

Ce diagnostic améliore l’investigation des défaillances instrumentées, mais ne garantit ni la reproduction ni l’explication de tout bug. Pour un signalement, préciser aussi la version utilisée, l’heure approximative, l’action effectuée et le résultat attendu ; ne pas joindre de capture contenant des informations privées.
