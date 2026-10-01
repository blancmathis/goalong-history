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

Le premier lancement tient en trois étapes :

1. **Vos données** — ce que Goalong vous montre (temps actif, travail et concentration, apps et sites), puis l’enregistrement de ce Mac et le détail de ce qui est conservé. Tout est proposé et modifiable ; aucun envoi n’est autorisé ici ;
2. **Vos sources** — l’historique de ce Mac, puis, séparément et désactivés par défaut, le Temps d’écran Apple et les conversations IA locales ;
3. **Prêt** — le récapitulatif de vos sources et le choix explicite d’ouvrir Goalong à l’ouverture de session.

Chaque autorisation macOS est demandée séparément, au moment où son intérêt vient d’être expliqué. L’état se met à jour en direct et un bouton ouvre directement le bon écran des Réglages Système.

Vous pouvez revoir cet assistant à tout moment depuis **Réglages → Avancé → Revoir le démarrage**.

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

La collecte et les archives restent locales. L’analyse ChatGPT ne démarre qu’après un consentement séparé et utilise la connexion Codex locale avec un contexte quotidien borné. Le système de mise à jour intégré et l’ancien envoi de preuves restent exclus.

La connexion facultative au site permet de choisir une journée, ses appareils et les détails à transmettre, puis d’examiner un aperçu hors ligne. Seul **Send reviewed data**, ou la commande `goalong send-site`, envoie cette sélection avec le fichier de jeton choisi. Aucun envoi automatique n’est programmé. Les conversations brutes et le contenu des événements capturés ne sont pas transmis. Les données envoyées restent non vérifiées et les règles de partage déjà définies sur le site peuvent s’appliquer. Voir le [parcours de connexion et ses limites](docs/CLI.md#website-export-and-account-submission).

Depuis **Confidentialité et sécurité**, vous pouvez ouvrir le dossier local, examiner les protections et supprimer les détails. La suppression des détails conserve les sceaux cryptographiques ; la période devient alors privée et ne peut plus être révélée en détail.

Pour analyser une demande téléchargée depuis le site, ouvrez **Settings → Goalong website → Analyser une demande du site**. Choisissez le JSON, relisez son contenu et autorisez cette analyse avec votre connexion ChatGPT locale. Vous pourrez modifier le brouillon et l’exporter avant de l’importer volontairement sur le site. Ce parcours utilise uniquement le fichier choisi, avec un profil de connexion séparé ; il ne consulte pas votre historique natif. Voir le [parcours et ses limites](docs/SITE-ANALYSIS.md).

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
- mettre en pause ou reprendre, ou tout suspendre pour confidentialité ;
- ouvrir Goalong ;
- mettre en pause la surveillance temps réel si vous l’utilisez ;
- signaler un problème ;
- quitter l’application.

La fenêtre principale compte quatre rubriques (raccourcis ⌘1, ⌘2, ⌘3 et ⌘,) :

- **Activité** — votre journée, vos 7 ou 28 derniers jours : temps actif, travail, concentration, changements d’app, rythme heure par heure, apps et sites. Si rien n’est enregistré (désactivé, en pause, autorisation à rétablir), la page le dit en tête avec le bouton utile ;
- **Historique** — la chronologie d’une date, par source : ce Mac, Temps d’écran Apple et conversations locales ;
- **Surveillance temps réel** — facultative, avec ses rappels, ses pauses et ses effets ;
- **Réglages** — enregistrement, envoi à Goalong, analyse ChatGPT, apps et sites, autorisations macOS, stockage et options avancées.

Pour mesurer votre travail, classez vos principaux usages en **Travail** ou **Hors travail** directement depuis Activité : le choix s’applique à tout l’historique et reste modifiable dans **Réglages → Apps et sites**. Le temps au premier plan est volontairement prudent : Goalong n’invente jamais de minutes entre deux observations éloignées.

Pour chaque application ou site, la règle utilisée lors d’un export signé reste au choix :

- **Afficher le nom** ;
- **Catégorie seulement** ;
- **Masqué**.

La règle d’un site est prioritaire sur celle du navigateur qui le contient. Les nouvelles preuves séparent le nom d’hôte du contexte complet : afficher un site ne révèle donc ni le titre de page ni l’URL complète. Les anciennes données restent vérifiables mais reviennent automatiquement à la catégorie lorsqu’un nom de site ne peut pas être ouvert sans révéler davantage.

La clé qui signe les preuves est liée à la signature stable de l’application. Si cette signature change, Goalong History crée une nouvelle identité clairement visible tout en conservant l’historique précédent ; il ne réutilise pas silencieusement une ancienne clé incompatible. Un refus du Trousseau suspend aussi les nouvelles tentatives pour le lancement en cours, afin qu’aucune demande de mot de passe ne puisse revenir chaque minute.

## Mises à jour

Goalong History vérifie un flux de versions signé au lancement puis toutes les
heures (désactivable dans **Réglages → Avancé → Mises à jour**). Lorsqu’une
version est disponible, cliquez sur **Mise à jour disponible** dans la barre
latérale ou sur **Rechercher les mises à jour…** : le téléchargement, la
vérification de signature (Ed25519) et l’installation se font dans l’app, et
rien ne s’installe sans votre accord. Votre historique et vos réglages sont
conservés. Une version compilée sans module de mise à jour se remplace à la
main. Chaque release publie aussi le commit source exact, un manifeste de
capacités, un SBOM et une attestation de provenance GitHub/Sigstore ; cette
preuve n’est pas une notarisation Apple.

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
