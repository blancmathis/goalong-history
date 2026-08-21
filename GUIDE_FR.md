# Goalong History — guide d’installation et de prise en main

Goalong History crée sur votre Mac une chronologie privée de l’activité autorisée au premier plan. Cette chronologie est enregistrée localement, scellée cryptographiquement minute par minute, puis peut être partagée de manière sélective sans réécrire l’historique original.

L’application est destinée à votre propre Mac. Elle ne doit jamais servir à surveiller une autre personne sans son accord explicite préalable.

## Installation recommandée

L’installation normale ne demande **ni Terminal, ni Xcode, ni Homebrew, ni commande administrateur**.

1. Ouvrez la page **Releases** du dépôt.
2. Téléchargez `Goalong-History-macOS-universal.dmg`.
3. Ouvrez le fichier téléchargé.
4. Glissez **Goalong History** vers **Applications**.
5. Ouvrez Goalong History et suivez l’assistant.

Le même fichier fonctionne sur les Mac Apple Silicon et Intel équipés de macOS 13 Ventura ou d’une version plus récente. La version publique doit être signée avec Developer ID et notarisée par Apple afin que Gatekeeper puisse la vérifier normalement.

## L’assistant de première ouverture

Le premier lancement est volontairement progressif. Il présente cinq étapes :

1. **Bienvenue** — ce que Goalong History apporte concrètement ;
2. **Confidentialité** — ce qui est enregistré et ce qui ne le sera jamais ;
3. **Accessibilité** — pourquoi cette autorisation est nécessaire ;
4. **Surveillance de l’entrée** — comment l’activité est mesurée sans enregistrer le texte saisi ;
5. **Vérification finale** — état des autorisations et choix explicite du lancement à la connexion.

Chaque demande d’autorisation est faite séparément, au moment où son intérêt vient d’être expliqué. L’état se met à jour en direct et un bouton ouvre directement le bon écran des Réglages Système.

Vous pouvez choisir **Configurer plus tard**. Goalong History ouvrira alors son espace Confidentialité et fonctionnera avec des informations plus limitées tant que les autorisations ne sont pas accordées.

## Autorisation Accessibilité

Chemin manuel :

```text
Réglages Système → Confidentialité et sécurité → Accessibilité
```

Cette autorisation permet de connaître le contexte autorisé au premier plan : application, fenêtre, URL de navigateur permise, contrôle sélectionné et élément d’interface cliqué.

Goalong History n’utilise pas cette autorisation pour piloter le Mac.

## Autorisation Surveillance de l’entrée

Chemin manuel :

```text
Réglages Système → Confidentialité et sécurité → Surveillance de l’entrée
```

Cette autorisation sert à compter les clics, défilements, raccourcis, touches de navigation et la durée de saisie.

Goalong History ne conserve jamais les caractères tapés, les mots de passe ni le contenu du presse-papiers.

Selon la version de macOS, le système peut demander de quitter puis de rouvrir l’application après l’activation. Acceptez cette demande, puis revenez dans l’assistant ; son état se mettra à jour automatiquement.

## Ce qui est enregistré localement

Selon les autorisations et les exclusions choisies :

- application et identifiant de bundle actifs ;
- titre de fenêtre et métadonnées accessibles ;
- URL nettoyée lorsqu’elle est disponible et autorisée ;
- clics et défilements regroupés ;
- raccourcis et touches de navigation ;
- nombre et durée de saisie, jamais le texte ;
- changements d’application, fenêtre et focus ;
- verrouillage, veille, pause et suppression de contexte ;
- certains signaux d’origine des événements clavier/souris.

## Ce qui n’est jamais enregistré

- captures d’écran ou vidéo de l’écran ;
- caméra ;
- microphone ou audio système ;
- presse-papiers ;
- mots de passe ;
- caractères saisis reconstitués.

La navigation privée des navigateurs reconnus ou détectés par leurs capacités est traitée en mode fermé par défaut : l’application garde uniquement un état générique de période privée, sans URL privée, titre de fenêtre, détail des clics ni activité clavier. La disponibilité des URL dépend toutefois des informations d’Accessibilité réellement exposées par chaque navigateur.

## Où sont les données ?

```text
~/Library/Application Support/LocalHistory/
```

Les détails restent sur le Mac. La vérification réseau est désactivée par défaut. Lorsqu’elle est activée volontairement, seuls des engagements cryptographiques opaques sont envoyés ; pas les noms d’application, URL, titres de fenêtre ou clics.

Depuis **Confidentialité et sécurité**, vous pouvez ouvrir le dossier local, examiner les protections et supprimer les détails. La suppression des détails conserve les sceaux cryptographiques ; la période devient alors privée et ne peut plus être révélée en détail.

## Lancement à la connexion

La dernière étape propose :

```text
Démarrer Goalong History à ma connexion
```

Le choix est visible et modifiable. Il utilise le mécanisme macOS `SMAppService`, présenté dans **Réglages Système → Général → Ouverture et extensions** lorsque macOS exige une approbation supplémentaire.

Aucun LaunchAgent caché n’est installé par la nouvelle version.

## Utilisation quotidienne

L’icône de barre des menus permet de :

- vérifier si l’enregistrement est actif ;
- mettre en pause ou reprendre ;
- ouvrir le tableau de bord ;
- accéder au partage sélectif ;
- consulter les diagnostics ;
- quitter l’application.

Le tableau de bord contient : **Vue d’ensemble**, **Activité**, **Apple Screen Time**, **Partager**, **Confidentialité et sécurité**, et **Réglages**.

Dans **Activité → Apps & sites**, toutes les applications et tous les sites observés sont listés avec leur temps estimé au premier plan et leurs minutes d’entrée active. Le temps au premier plan est volontairement prudent : Goalong History n’invente jamais plus de 75 secondes entre deux observations.

Pour chaque application ou site, choisissez la règle utilisée lors d’un partage :

- **Afficher le nom** ;
- **Catégorie uniquement** ;
- **Masqué**.

La règle d’un site est prioritaire sur celle du navigateur qui le contient. Les nouvelles preuves séparent le nom d’hôte du contexte complet : afficher un site ne révèle donc ni le titre de page ni l’URL complète. Les anciennes données restent vérifiables mais reviennent automatiquement à la catégorie lorsqu’un nom de site ne peut pas être ouvert sans révéler davantage.

La clé qui signe les preuves est liée à la signature stable de l’application. Si cette signature change, Goalong History crée une nouvelle identité clairement visible tout en conservant l’historique précédent ; il ne réutilise pas silencieusement une ancienne clé incompatible. Un refus du Trousseau suspend aussi les nouvelles tentatives pour le lancement en cours, afin qu’aucune demande de mot de passe ne puisse revenir chaque minute.

## Mises à jour

Cette version doit être installée manuellement une première fois. Les versions publiques suivantes, lorsqu’elles sont signées et publiées dans le flux officiel, apparaissent ensuite directement dans Goalong History. Le bouton de mise à jour permet de consulter la version proposée avant de lancer son installation ; l’application ne l’installe pas silencieusement.

## Désinstallation

Double-cliquez `Uninstall.command` dans le dossier source, ou lancez :

```bash
./uninstall.sh
```

Par défaut, l’application et ses autorisations sont supprimées, mais l’historique reste conservé. Pour supprimer aussi les données :

```bash
./uninstall.sh --purge-data
```

## Installation depuis les sources

Cette voie est réservée au développement. Elle nécessite les Command Line Tools de Xcode :

```bash
./install.sh --source
```

L’installateur vérifie les frontières de confidentialité, exécute les tests, construit l’application native, signe localement le bundle et l’ouvre. Les logs techniques sont placés dans :

```text
~/Library/Logs/LocalHistory/installer.log
```
