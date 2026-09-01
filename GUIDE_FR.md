# Goalong History — guide d’installation et de prise en main

Goalong History crée sur votre Mac une chronologie privée de l’activité autorisée au premier plan. Cette chronologie est enregistrée localement, scellée cryptographiquement minute par minute, puis peut être partagée de manière sélective sans réécrire l’historique original.

L’application est destinée à votre propre Mac. Elle ne doit jamais servir à surveiller une autre personne sans son accord explicite préalable.

## Installation recommandée actuellement

Téléchargez le DMG universel de la dernière **Community Build** sur GitHub, puis
glissez **Goalong History** dans Applications. C’est l’unique application
publique : elle est gratuite, open source et ne nécessite ni Xcode ni abonnement
Apple Developer payant.

La Community Build est signée ad hoc pour vérifier l’intégrité du bundle, mais
elle n’est pas notariée par Apple. Après avoir vérifié le SHA-256, le manifeste
de release et la provenance GitHub/Sigstore, si macOS bloque la première
ouverture, essayez d’ouvrir l’app une fois puis utilisez uniquement :

```text
Réglages Système → Confidentialité et sécurité → Ouvrir quand même
```

Ne désactivez jamais Gatekeeper globalement.

Après l’installation, ouvrez **Goalong History** et suivez l’assistant. L’app
exige macOS 13 Ventura ou une version plus récente. Comme la signature gratuite
n’a pas d’identité Apple stable, macOS peut demander de renouveler les
autorisations Goalong après une mise à jour ; l’historique et les réglages restent
conservés.

## L’assistant de première ouverture

Le premier lancement est volontairement progressif. Il présente sept étapes :

1. **Bienvenue** — ce que Goalong History apporte concrètement ;
2. **Confidentialité** — ce qui est enregistré et ce qui ne le sera jamais ;
3. **Computer History** — choix explicite, désactivé par défaut ;
4. **Accessibilité et Surveillance de l’entrée** — demandées seulement si Computer History a été choisi ;
5. **Screen Time Apple** — choix distinct, désactivé par défaut ;
6. **Conversations IA** — lecture directe optionnelle, désactivée par défaut ;
7. **Vérification finale** — état des autorisations et choix explicite du lancement à la connexion.

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

Les détails restent sur le Mac. L’application publique ne contient ni transport HTTP Goalong, ni téléverseur, ni système de mise à jour intégré. L’analyse ChatGPT est une frontière externe distincte : elle ne démarre qu’après un consentement séparé et utilise la connexion Codex locale avec un contexte quotidien borné.

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

Le tableau de bord garde trois destinations principales : **Today**, **History**
et **Settings**. **Today** réunit Screen Time et l’activité Goalong de la journée.
**History** permet d’ouvrir une date puis de filtrer Computer History, Screen Time
et Conversations IA. **Settings** regroupe la connexion ChatGPT, les sources,
les autorisations, la confidentialité et les réglages experts. Les historiques
IA configurés sont lus directement à leur emplacement d’origine sans seconde
copie des transcriptions. L’analyse quotidienne optionnelle combine ces sources
dans un rapport de cinq lignes via le compte ChatGPT connecté.

Dans **Activité → Apps & sites**, toutes les applications et tous les sites observés sont listés avec leur temps estimé au premier plan et leurs minutes d’entrée active. Le temps au premier plan est volontairement prudent : Goalong History n’invente jamais plus de 75 secondes entre deux observations.

Pour chaque application ou site, choisissez la règle utilisée lors d’un partage :

- **Afficher le nom** ;
- **Catégorie uniquement** ;
- **Masqué**.

La règle d’un site est prioritaire sur celle du navigateur qui le contient. Les nouvelles preuves séparent le nom d’hôte du contexte complet : afficher un site ne révèle donc ni le titre de page ni l’URL complète. Les anciennes données restent vérifiables mais reviennent automatiquement à la catégorie lorsqu’un nom de site ne peut pas être ouvert sans révéler davantage.

La clé qui signe les preuves est liée à la signature stable de l’application. Si cette signature change, Goalong History crée une nouvelle identité clairement visible tout en conservant l’historique précédent ; il ne réutilise pas silencieusement une ancienne clé incompatible. Un refus du Trousseau suspend aussi les nouvelles tentatives pour le lancement en cours, afin qu’aucune demande de mot de passe ne puisse revenir chaque minute.

## Mises à jour

Goalong History n’intègre aucun mécanisme de mise à jour et ne vérifie pas
GitHub en arrière-plan. Une mise à jour est un remplacement manuel. L’installateur
public vérifie le SHA-256, l’identité unique de l’application, sa signature ad
hoc, les marqueurs de confidentialité et la politique d’app unique avant tout
remplacement. Chaque release publie aussi le commit source exact, un manifeste
de capacités, un SBOM et une attestation de provenance GitHub/Sigstore. Cette
preuve n’est pas une notarisation Apple. L’état courant de la release est indiqué
dans le [`README`](README.md).

## Désinstallation

Double-cliquez `Uninstall.command` dans le dossier source, ou lancez :

```bash
./uninstall.sh
```

Par défaut, l’application et ses autorisations sont supprimées, mais l’historique reste conservé. Pour supprimer aussi les données :

```bash
./uninstall.sh --purge-data
```

## Installation actuelle depuis les sources

Cette voie nécessite macOS 13 ou une version plus récente et les Command Line
Tools de Xcode. Dans ce checkout :

```bash
./install.sh --source
```

L’installateur vérifie les frontières de confidentialité, exécute la suite de
tests complète, construit l’application native, valide et signe localement le
bundle, le copie d’abord dans une zone de staging sur le disque de destination,
puis l’ouvre. Une installation existante est conservée comme retour en arrière
jusqu’à la validation du remplacement. Les logs techniques sont placés dans :

```text
~/Library/Logs/LocalHistory/installer.log
```
