# Ambiance — implémentation et vérification (2026-10-04)

Passe audio/réseau dans `/Users/mathisblanc/Developer/goalong-ambiance-audio-20261004`,
branche `feat/ambiance-audio-20261004`, selon la décision
[`AMBIANCE-AUDIO-NETWORK.md`](AMBIANCE-AUDIO-NETWORK.md). Aucun fichier SwiftUI,
Réglages ou sidebar modifié. Aucun push, PR, upload ou création de release.

## État et limite réseau

La sortie audio est implémentée : compositions Onde, textures installées en boucle,
fichiers personnels lus depuis leur emplacement. `play` publie `playing` après
le démarrage réussi du moteur. Stop et désactivation arrêtent le graphe, détachent
ses nœuds et libèrent le lecteur, le DSP et les mappings. Un échec de préparation
ou de démarrage publie une erreur française et libère le runtime.

Le téléchargement explicite est implémenté et testé sur loopback. La clarification
du propriétaire du 2026-10-04 est appliquée : URL initiale exacte du catalogue sur
`github.com`, sans query, puis au plus une redirection vers
`https://release-assets.githubusercontent.com:443` (port implicite 443 admis).
La query signée reçue de GitHub reste intacte ; Goalong ne la construit pas et
n'enregistre, n'affiche ni ne journalise l'URL signée. Les erreurs de transport
Foundation, susceptibles de contenir cette URL, deviennent une erreur de pack.

HEAD du 2026-10-04, sans télécharger l’asset : release publique `v0.6.2`, asset
`Goalong-History-macOS-universal.dmg`, réponse 302 vers
`release-assets.githubusercontent.com`. La query contient notamment `jwt`, `sig`
et les paramètres de signature Azure. La même destination sans query renvoie
HTTP 618. Aucune valeur signée n’est conservée. Preuve privée :
`.ambiance-work/github-redirect-observation.json`.
Les packs de cette tâche n’ont jamais été téléchargés depuis GitHub.

## API UI : aucune signature changée

Importer `Ambiance`, puis utiliser `model.ambianceModule` :

```swift
model.ambianceModule.setEnabled(true)
if let controller = model.ambianceModule.controller {
    controller.download("orchestra")
    controller.play(controller.sources[0])
    controller.stop()
}
model.ambianceModule.setEnabled(false)
```

- `AmbianceSettings` : `isEnabled` (false par défaut), `volume` borné 0…1,
  `ownFiles: [String]` (chemins), `lastSource: String?`.
- `AmbianceController` : MainActor/ObservableObject ; `state`, `sources`, `packs`,
  `volume`, `diagnostics`. États inchangés : idle/loading/playing/error ; packs
  notInstalled/downloading/installed/failed.
- Actions inchangées : `play`, `stop`, `download`, `cancelDownload`, `remove`,
  `addOwnFiles`, `removeOwnFile`, `refresh`, `renderOffline`.
- `diagnostics.engineRunning` mesure désormais le vrai graphe de périphérique ;
  `runtimeCreated` couvre aussi la lecture d’un fichier. Les octets résidents
  concernent tout le processus. `renderOffline` reste sans périphérique et libère
  toujours son runtime. Les anciens cas publics audioBoundary/networkBoundary
  restent présents pour compatibilité ; ils ne bloquent plus les actions.

Toujours désactiver par `setEnabled(false)`, qui arrête immédiatement la lecture,
annule les téléchargements et libère le contrôleur du module. Construire le modèle
n’évalue pas la propriété paresseuse. Activer le module ne crée aucun moteur ni
session réseau. Les textures n’apparaissent qu’après installation ; les fichiers
personnels manquants restent listés avec `isAvailable == false`.

L’UI choisit la musique via `NSOpenPanel` seulement à la demande du membre, puis
transmet les URL à `addOwnFiles`. Ce chantier ne crée aucune UI. Goalong peut jouer
de la musique ; il n’écoute jamais. Aucun micro, Apple Music, Full Disk Access ou
appel de demande de permission pour Ambiance. Un éventuel prompt de dossier émis
par macOS lors de l’accès à un fichier choisi reste un prompt du système.

## Implémentation et fichiers par domaine

- Audio : `AmbianceAudioOutput.swift` (seule frontière AVFoundation de lecture),
  `AmbianceRuntime.swift`, partie `play` de `AmbianceController.swift`.
  Le callback source appelle directement `onde_dsp_render`, sans allocation ni
  verrou. Volume du graphe : mixer AVFoundation, sans mutation concurrente du DSP.
  `AVAudioFile` + `AVAudioPlayerNode.scheduleFile` lisent les fichiers sur disque,
  sans décodage complet en mémoire ni copie. La fin d’un fichier personnel arrête
  la lecture ; une texture est reschedulée. L’arrêt du moteur précède la destruction
  du DSP, puis le démappage de ses instruments PCM16. Zéro copie PCM32.
- Réseau : `AmbiancePackDownloader.swift`, partie `download` du contrôleur.
  Une session éphémère par action, GET seulement, URL initiale égale au catalogue,
  HTTPS et hôtes exacts contrôlés sur chaque redirection. Aucun cookie, cache,
  credential, header personnalisé, identifiant ou retry. Les challenges autres
  que la validation TLS standard sont refusés. Les tailles annoncée/réelle sont
  bornées ; le store vérifie taille et SHA-256 avant extraction atomique. Le fichier
  temporaire téléchargé est supprimé après succès, échec ou annulation.
- Vérification : `AmbianceAudioTests.swift`, `AmbianceAudioNetworkTests.swift`,
  adaptation de `AmbianceTests.swift`, fixtures privacy Python et inventaires.
- Documentation : ce rapport, `NETWORK.md`, `PERMISSIONS.md`, `GUARANTEES.md`.

Le moteur reste vendorisé au commit Onde
`dfa5ab747373d1eed324115db07971c4096ffc49`. Aucun changement de source C/Swift
vendorisée, dépendance distante ou flag SwiftPM ajouté. `Package.swift` exclut
maintenant trois fichiers sans aucun appelant Goalong : `GenerativeRenderer.swift`,
`TransitionRenderer.swift`, `PlaybackSelection.swift`. Ils restent sur disque pour
la provenance ; `Engine/ADAPTATIONS.md` l’explique. Ces trois types publics du target
privé OndeCore ne sont plus compilés. L’API Ambiance documentée ci-dessus est stable,
y compris `renderOffline`, qui passe directement par le runtime. Catalogue et
archives restent ceux de la passe antérieure (77 158 400 / 83 363 840 octets).

## Audits : ancienne règle → nouvelle règle

- `audit_privacy_boundaries.sh` : moteur audio interdit partout → sortie autorisée
  uniquement dans `Features/Ambiance/Sources/AmbianceAudioOutput.swift`.
  Source/player/mixer sont aussi confinés à ce fichier. AVAudioFile/PCMBuffer sous
  `Ambiance/Sources` ont le même chemin unique autorisé ; les usages hors ligne
  préexistants hors de ce sous-arbre conservent leurs règles de fichiers/buffers.
- Même audit : absence de garde dédiée aux entrées → interdiction globale des neuf
  tokens micro de la décision, y compris dans le fichier autorisé. Les quatre API
  bas niveau de capture restent interdites partout. Usage descriptions micro et
  Apple Music rejetées dans les builders shell/Python ; droits audio-input et
  microphone rejetés dans les fichiers d’entitlements source. MediaPlayer/MusicKit
  sont rejetés. Fixtures négatives lancées contre le véritable audit, copie isolée.
- Même audit : URLSession limité aux fichiers site/Jev/retiré → une seule addition,
  `Features/Ambiance/Sources/AmbiancePackDownloader.swift`. Les autres règles restent.
- `generate_security_artifacts.py` / `verify_security_capabilities.py` : cinq chemins
  externes actifs et packs inactifs → six chemins, avec GET, session, intégrité,
  host/port de redirection, limite d’une redirection et query signée reçue intacte.
  Le conflit déclaré avant la clarification du propriétaire est supprimé. Les droits
  micro deviennent interdits dans le manifeste ; le vérificateur rejette aussi
  les usage descriptions micro/Apple Music du bundle. Les autres invariants restent.
- `audit_site_submission.py`, `audit_jev.py`, `audit_local_only.sh`,
  `audit_update_dependency.py` : règles inchangées. Le premier ne contient aucun
  inventaire global à étendre. Le message de `verify_source_security.sh` est actualisé.

## Vérification antérieure au rebase

- `swift build` : passé.
- `swift test`, vrais packs locaux, CFFIXED_USER_HOME isolé, tests de périphérique
  activés lors de la première suite corrigée : **1 548 tests, 48 skips opt-in, 0 échec**.
  Suite finale après exclusions, sans périphérique concurrent aux mesures :
  **1 548 tests, 49 skips opt-in, 0 échec** (560,59 s sous compilation concurrente).
  Première passe : une assertion attendait encore l’ancien blocage audio ; corrigée,
  puis suite entière relancée. Logs `.ambiance-work/full-tests*.log`.
- Chaque `scripts/audit_*.sh` et `scripts/audit_*.py` : passé (cinq scripts).
  Les **25 fixtures négatives** sont passées contre le vrai audit privacy après
  exclusion du helper Onde ; baseline acceptée et 25 mutations rejetées.
- `verify_source_security.sh` : passé. Tests de politique site/manifeste : 39 passés.
- Transport réel via serveur HTTP de `/tmp/goalong-ambiance-packs/` : cinq scénarios
  passés (succès, corruption, taille, redirection, annulation). Deux passes : dix GET
  `/orchestra.tar`, aucun cookie/credential, aucun téléchargement temporaire restant.
  `GOALONG_AMBIANCE_PACK_TEST_URL=http://127.0.0.1:<port>/` existe en Debug seulement ;
  tous ses redirects sont refusés. `GOALONG_AMBIANCE_PACK_DIR` conserve l’installation
  locale antérieure. Logs `.ambiance-work/network-tests-final-ownership.log` et
  `.ambiance-work/pack-http-requests.jsonl`.
- `bash scripts/build_local_app.sh`, `LOCALHISTORY_ARCHS="arm64 x86_64"`,
  `LOCALHISTORY_RUN_TESTS=0` (suite exécutée séparément), jobs=4 : passé.
  Bundle signé Apple Development, vérification stricte et inventaire de sécurité
  passés ; architectures x86_64 + arm64, source `9df7065`, aucune usage description
  micro/Apple Music. `.ambiance-work/universal-bundle-final.log`,
  `dist/Goalong History.app`, `dist/security-capabilities.json`. Pas de notarisation
  ni publication demandée. Les trois mesures de sortie sont terminées ci-dessous.

## Mesures réelles antérieures

Runner Swift `-O`, targets Ambiance/OndeCore/OndeDSP de production, sans rendu offline.
Il initialise `NSApplication.shared` avec la politique `.accessory`, comme
`Sources/LocalHistoryApp/main.swift`, avant le relevé ; aucun objet audio n’est
préchauffé. C’est un hôte AppKit minimal, pas l’app Goalong complète. RSS de tout le
processus, relevée chaque seconde ; CPU utilisateur+système / temps réel × 100.
Après arrêt, RSS immédiate puis à cinq secondes. Sortie par défaut : AirPods Pro,
48 kHz au relevé. Les JSON privés conservent les échantillons et les durées exactes.

| Source | Avant / pic / 5 s après stop (Mo décimaux) | CPU sur 300 s | Résidu après stop |
|---|---:|---:|---:|
| Ambre | 25,43 / 36,09 / 25,95 | 5,63 % (300,19 s) | +0,52 Mo |
| Confluence | 23,49 / 44,37 / 29,41 | 3,53 % (300,32 s) | **+5,91 Mo : hors budget** |
| Fichier personnel | 24,74 / 32,49 / 24,76 | 0,33 % (300,12 s) | +0,02 Mo |

Pour les trois passes : moteur/runtime absents et mappings nuls après stop ;
pics < +90 Mo. Ambre et le fichier personnel reviennent à ±5 Mo ; **Confluence
échoue de 914 624 octets**. Ambre dépasse la cible CPU de 5 % ; celle-ci est une
cible à rapporter, pas un résultat à masquer. Mappings Ambre : 17 705 796 octets,
zéro copie d’échantillons. Preuves : `.ambiance-work/appkit-live-pass/live-*.json`.

La première passe AppKit Confluence s’est arrêtée à 119 s. Les logs natifs montrent
`iounit configuration changed > stopping the engine` : changement de périphérique
CoreAudio, sans appel Stop du runner. Cette passe n’est pas une mesure de 300 s.
La seconde passe a tenu 300 s ; ses valeurs sont dans le tableau. Un changement
de sortie peut interrompre le graphe ;
il faut alors Stop puis Play. Aucun redémarrage automatique ou observateur ajouté.

Une variante isolée remplaçant les lectures Foundation par un buffer réutilisé
64 Kio, avec la même vérification SHA-256, a passé un essai court mais échoué après
300 s (+8,09 Mo Confluence). Elle est **rejetée**, non intégrée et non commitée.
Les essais d’engine reset et de purge d’allocateur n’ont pas résolu le résidu ; ils
ne sont pas intégrés non plus. Aucune préinitialisation audio au repos, conservation
de moteur après Stop ou relâchement d’audit n’a été utilisé pour faire passer le budget.

Le fichier personnel est un WAV synthétique stéréo PCM16 de 330 s, 58,2 Mo, ajouté
via `addOwnFiles`. Il exerce le chemin personnel ; aucune musique privée recherchée.

Les premiers runners CLI froids, sans initialisation AppKit, restent archivés :
`.ambiance-work/first-live-pass/` (~315 s sous charge) et
`.ambiance-work/final-live-pass/` (~300 s). La dernière passe CLI avait des résidus
Ambre +4,52 Mo, Confluence +5,08 Mo, personnel +6,37 Mo : deux hors budget.
Ils ne sont pas présentés comme verts. Le profil AppKit reproduit le démarrage du
vrai produit et distingue ces caches de démarrage de ceux de la lecture audio.

## Taille du bundle

Dernière construction après exclusion du helper : **85 202 160 octets signés**.
Aucun asset audio dans le bundle. Comparaison identique à la passe précédente :
exécutable universel copié, signé ad hoc `ai.goalong.localhistory` avec entitlements
vides, sans strip ajouté : **85 201 696 octets**. Référence avant Ambiance :
84 217 984 ; passe précédente : 85 130 544 (rapport antérieur, références non
reconstruites aujourd’hui). Delta avant Ambiance : **+983 712 octets**, sous le
plafond strict de 1 000 000. Delta de cette passe audio/réseau : +71 152 octets.
Preuve privée : `.ambiance-work/binary-audio-final-measures.json`.
L’avant-dernière construction dépassait de 2 352 octets ; l’exclusion du helper
inutilisé a résolu cet échec, sans changer la signature de comparaison.

## Reprise sur la branche combinée (2026-10-04)

Base `1bf8d44`, après rebase sur `origin/main` (Cold Turkey #62, deltas Sparkle #64)
et intégration de la branche UI. Aucun fichier de `Sources/LocalHistoryApp/` modifié
par cette reprise. Le code audio reste inchangé.

### Redirection signée

`allows` sépare l'URL initiale sans query du seul host de redirection autorisé.
`redirectRequest`, appelée directement par le delegate, exige un compteur égal à 1,
une URL initiale exacte du catalogue, une réponse depuis cette même URL, HTTPS et
port 443, un GET sans body/stream, sans user/password/fragment. Elle réutilise
l'objet URL reçu sans reconstruire sa query et crée une requête sans les headers
transmis. Toute seconde redirection est refusée. Les erreurs réseau Foundation ne
sortent jamais du delegate ; seul un message nommant le pack atteint le contrôleur.
Session éphémère, cookies/cache/credentials désactivés, aucun retry inchangés.

Cinq nouveaux tests couvrent query sur GitHub (initiale ou cible), autre host, HTTP,
autre port, seconde redirection, origine de réponse inattendue, asset host en
première requête, POST/body/stream, user/fragment et headers transmis. Le cas positif
prouve l'égalité de l'URL et de sa query encodée, avec `%2B`, `%2F`, `%3D`, `+`,
paramètres répétés et valeur vide. Toutes les signatures de test sont synthétiques.
Aucun téléchargement ni nouvel appel GitHub ; l'observation HEAD antérieure reste
la preuve du host. Les packs GitHub n'existent pas encore.

### Cinq cycles de sortie réelle par composition

Runner AppKit `-O`, recompilé contre les targets de production de cette branche :
Confluence puis Ambre, chacun dans un processus froid distinct, volume 0,08,
sortie par défaut, aucun rendu offline ni préchauffage audio. Après 5 s au repos :
RSS et `TASK_VM_INFO.phys_footprint` avant lecture. Chaque cycle fait Play 60 s,
Stop, puis attend au moins 10 s avant le relevé. Les durées observées vont de
60,02 à 60,06 s et de 10,32 à 10,70 s. Les dix contrôles du graphe confirment
moteur/runtime absents et mappings nuls après Stop.

| Relevé après Stop + 10 s | Confluence RSS (Mo) | Confluence footprint (Mo) | Ambre RSS (Mo) | Ambre footprint (Mo) |
|---|---:|---:|---:|---:|
| Avant toute lecture | 24,22 | 6,49 | 23,72 | 6,64 |
| Cycle 1 | 26,51 | 9,42 | 30,06 | 9,50 |
| Cycle 2 | 26,26 | 9,57 | 29,15 | 9,68 |
| Cycle 3 | 25,72 | 9,55 | 28,79 | 9,62 |
| Cycle 4 | 27,12 | 9,60 | 25,36 | 9,67 |
| Cycle 5 | 27,03 | 9,65 | 25,33 | 9,80 |

Mo décimaux. Confluence : RSS oscille, sans accumulation ; footprint +0,23 Mo
entre les cycles 1 et 5. Ambre : RSS diminue ; footprint +0,29 Mo entre les
cycles 1 et 5. Le saut initial du footprint est voisin de 2,9 Mo pour les deux,
puis le niveau reste dans une plage étroite. Résidu RSS final : Confluence +2,82 Mo,
Ambre +1,61 Mo. Le +5,91 Mo antérieur ne se répète pas à chaque lecture.
**Verdict : cache unique de démarrage audio/allocateur, pas fuite Ambiance/Onde
mise en évidence. Aucune modification audio.** Cela ne réécrit pas l'ancien
relevé hors budget ; la RSS dépend aussi de la résidence des pages et des caches.

`leaks 12042` après les cinq cycles Confluence : exit 1, **287 objets / 14 320 octets**.
`leaks 35961` après les cinq cycles Ambre : exit 1, **288 objets / 14 400 octets**.
Les trois racines de chaque rapport sont des cycles `NSXPCConnection`, protocole
`LNDaemonApplicationInterface`, dans AppIntents/Foundation ; aucun objet
Ambiance/Onde ni allocation DSP signalé. Témoin AppKit sans import Ambiance et sans
audio : exit 1, 192 objets / 9 600 octets, deux cycles identiques du même protocole.
Ce sont des résultats non nuls, pas un « leaks vert ». macOS marque ces runners
« not debuggable » et limite la lecture du contenu des objets ; les types et graphes
ci-dessus sont ceux effectivement affichés. La conclusion repose aussi sur les
dix relevés et la libération du runtime, pas sur une prétendue absence universelle
de fuite. Preuves privées : `.ambiance-work/r3/cycles-{confluence,ambre}.json`,
`cycle-progress.log`, `leaks-{confluence,ambre,appkit-idle}.log`, sources des runners.

### Vérification actuelle

- `swift build` : exit 0, branche combinée.
- `swift test` : exit 0, **1 591 tests, 48 skips opt-in, zéro échec**, 485,77 s.
  HOME et CFFIXED_USER_HOME isolés dans `/tmp/goalong-ambiance-r3-*`, vrais packs
  locaux ; aucun test concurrent de périphérique. Les cinq nouveaux tests réseau
  sont tous exécutés. Logs `.ambiance-work/r3/swift-{build,test}.log` ; statuts
  `swift-checks.json`. Aucune ancienne suite utilisée comme preuve de cette reprise.
- Les cinq audits (`audit_local_only`, `audit_privacy_boundaries`,
  `audit_site_submission`, `audit_jev`, `audit_update_dependency`) : exit 0.
  **25 fixtures négatives rejetées**, baseline acceptée, exit 0. Statuts et logs
  `.ambiance-work/r3/audit-checks.json` et `privacy-fixtures.log`.
- `verify_source_security.sh` : exit 0 ; politique site/manifeste : 39 tests passés.
- Exécutables Release arm64 (`LocalHistory`, `goalong`, `goalong-relauncher`) de la
  branche combinée reconstruits. Bundle de vérification local signé Apple Development,
  ressources/framework/runtime déjà présents réutilisés sans téléchargement GitHub.
  Signature stricte et `verify_security_capabilities.py` : exit 0. Les trois artefacts
  (`security-capabilities.json`, `sbom.spdx.json`, `release-manifest.json`) sont
  régénérés dans `.ambiance-work/r3/artifacts/`, puis repris dans `dist/` avec ce
  bundle ; l'ancien `dist/` est sauvegardé dans `.ambiance-work/r3/previous-dist/`.
  La déclaration du conflit de query est supprimée ; le manifeste décrit le host,
  le port 443, une redirection, query initiale interdite et query GitHub intacte.
  Ce bundle arm64 local ne remplace pas la référence universelle historique de taille.
  Il n'est ni installé ni publié. Logs `artifact-{build,finalize}.log`,
  `artifact-checks.json` ; le pointeur de source est actualisé après le commit local.
- Le premier audit a rejeté les tokens de construction de requête dans les nouveaux
  tests. Les tests utilisent maintenant l'inférence de type sur le helper de
  production ; l'audit et ses allowlists restent strictement inchangés. Les cinq
  audits et les fixtures ont été relancés après cette correction.

### Passation

La publication de la release `ambiance-packs-v1` reste à autoriser séparément.
Cette reprise prépare uniquement un commit local avec le trailer
`Co-Authored-By: Codex <noreply@openai.com>`. Aucun push, PR, upload ou release.
Le `CONTEXT.md` partagé du checkout principal a été lu et actualisé ; la session UI
conserve son worktree et ses fichiers. Les références de commits des sections
historiques décrivent les builds antérieures au rebase, pas un nouveau bundle.
