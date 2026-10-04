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

Le téléchargement explicite est implémenté et testé sur loopback. La règle
« aucune query string » demeure stricte, redirections comprises. **GitHub impose
une query signée : les téléchargements passant par cette redirection restent
bloqués jusqu’à une décision complémentaire du propriétaire.** La question a
été posée ; aucune exception n’a été déduite de son silence.

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
  host de redirection et conflit des queries explicitement déclarés. Les droits
  micro deviennent interdits dans le manifeste ; le vérificateur rejette aussi
  les usage descriptions micro/Apple Music du bundle. Les autres invariants restent.
- `audit_site_submission.py`, `audit_jev.py`, `audit_local_only.sh`,
  `audit_update_dependency.py` : règles inchangées. Le premier ne contient aucun
  inventaire global à étendre. Le message de `verify_source_security.sh` est actualisé.

## Vérification

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

## Mesures réelles

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

## Passation et reste

Commits locaux : `e653cd2` (audio + gardes), `8b170ac` (transport + inventaires/docs),
`7d74718` (25 fixtures et builders), `0a6d0d0` (exporters exclus), `420844e` (ownership
session), `9df7065` (helper inutilisé exclu).
Reste : résoudre le résidu RAM Confluence ; arbitrer la query signée GitHub. La sortie est implémentée, mais cette tâche ne constitue pas une acceptation
finale des budgets. La cible CPU Ambre est manquée.
La publication des packs reste réservée à l’accord du propriétaire. La session UI conserve son worktree séparé.

Le `CONTEXT.md` partagé du checkout principal a été lu. L’interdiction de travailler
hors de ce worktree empêche de l’éditer ; ce document tient lieu de passation locale.
La décision `AMBIANCE-AUDIO-NETWORK.md`, initialement non suivie, reste intacte.
