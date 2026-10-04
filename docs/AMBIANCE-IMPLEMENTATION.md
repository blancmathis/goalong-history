# Ambiance — état de l’implémentation (2026-10-04)

La plomberie sans UI est implémentée dans le worktree
`/Users/mathisblanc/Developer/goalong-ambiance-onde-20261004`, branche
`feat/ambiance-onde-20261004`. **La lecture sur périphérique et le téléchargement
HTTPS restent bloqués par les audits existants.** Aucun audit n’a été affaibli,
aucune release n’a été créée, aucun fichier n’a été téléversé ou poussé.

## API pour la session UI

Importer `Ambiance`. Le modèle `DashboardViewModel` expose la propriété paresseuse
`ambianceModule`, sans modifier aucune vue, `DashboardSection` ou Réglages.

```swift
let settings = model.ambianceModule.settings  // UserDefaults seulement
model.ambianceModule.setEnabled(true)         // action explicite du membre
if let controller = model.ambianceModule.controller {
    // Observer controller.state, sources, packs et volume (Combine).
    controller.download("orchestra")
    controller.play(controller.sources[0])
    controller.stop()
}
model.ambianceModule.setEnabled(false)        // arrêt et annulation des installations
```

La session UI doit utiliser `setEnabled` pour arrêter le module immédiatement et
libérer sa référence au contrôleur quand elle le désactive. Lire `controller`
réévalue aussi la préférence d’activation. Une construction du modèle d’application
n’évalue pas même la propriété paresseuse du module.

- `AmbianceSettings` : `isEnabled` (false par défaut), `volume` borné 0…1,
  `ownFiles: [String]` (chemins uniquement), `lastSource: String?` (identifiant).
- `AmbianceController` : `@MainActor`, `ObservableObject`, état
  `idle | loading | playing(AmbianceSource) | error(String)`, liste française
  `sources` et drapeaux `isAvailable`. Toutes les compositions exigent le pack
  Orchestre, y compris celles composées uniquement par synthèse.
- Actions : `play(_ source:)`, `stop()`, `download(_ id:)`, `cancelDownload(_ id:)`,
  `remove(_ id:)`, `addOwnFiles(_ urls:)`, `removeOwnFile(_ source:)`, `refresh()`.
- `diagnostics` : octets mappés, RSS du processus, échantillons copiés, runtime
  présent, moteur de périphérique en marche. Le RSS concerne le processus entier.
- `renderOffline(_ source:, seconds:)` est une action de diagnostic explicite,
  sans sortie audio et avec destruction du runtime sur succès comme sur erreur.
  Ne pas l’appeler pour simuler une lecture UI : `play` retourne actuellement
  une erreur honnête et ne publie jamais `playing`.

Les textures n’apparaissent qu’après installation de leur pack. Un fichier
personnel manquant reste dans la liste avec `isAvailable == false`. Aucun fichier
personnel n’est copié ni envoyé. Les imports acceptent WAV, AIFF, M4A, MP3, CAF,
FLAC et les fichiers audio d’un dossier choisi (sous-dossiers inclus).

## Moteur et packs

Onde est vendorisé au commit `dfa5ab747373d1eed324115db07971c4096ffc49`.
Provenance, MIT et notices originales se trouvent dans `Features/Ambiance/Engine`.
Le target C utilise la norme C11 du package, sans ajouter de flags non sûrs ou de
dépendance distante. Les adaptations sont détaillées dans `Engine/ADAPTATIONS.md`.

Le cache global décodé d’Onde a été retiré. Les instruments d’une composition sont
vérifiés par lectures de 64 Kio puis mappés en lecture seule. Le sampler interpole
directement le PCM16 stéréo, sans copie PCM32. Les mappings ont une durée de vie
explicite jusqu’à la destruction du DSP ; l’arrêt détruit le DSP avant de démapper.
Le rendu C n’alloue pas et ne prend aucun verrou. L’équivalence PCM16/PCM32 est
vérifiée sur une phrase qui contient effectivement des événements de piano.

Les archives USTAR non compressées ont une taille stable, des métadonnées
déterministes et seulement des fichiers réguliers à plat. L’installation vérifie
la taille et le SHA-256 **avant** toute extraction. Une extraction échouée ou
annulée nettoie son dossier de staging ; un renommage sur le même volume publie
le pack complet. Les liens, traversées de chemins et doublons sont rejetés.

```bash
python3 scripts/build_ambiance_packs.py --onde-source /tmp/onde-src
GOALONG_AMBIANCE_PACK_DIR=/tmp/goalong-ambiance-packs swift test --filter AmbianceTests
```

Le builder ne publie rien. Il fabrique les packs dans
`/tmp/goalong-ambiance-packs/` et inscrit leurs empreintes dans le catalogue Swift.
La variable de développement désigne le dossier contenant les archives, pas une
banque décodée. `download(id)` n’installe un pack local qu’après une action explicite.
Les packs vont dans `AppPaths.applicationSupportDirectory/Ambiance/<packId>/`.

| Archive | Octets | SHA-256 |
|---|---:|---|
| `orchestra.tar` | 77 158 400 | `d8535aa60dbbb9b8b44897a3de0ef26c532b9e3f2a368a5fbe9c4f62462c2489` |
| `textures.tar` | 83 363 840 | `eee48c8c039e50d1e23f824c3de4151252c5e66e8c42d1264c3daa3b2f5da3a2` |

## Règles de la spécification qui restent bloquées

1. **Sortie audio et musique personnelle en streaming** :
   `scripts/audit_privacy_boundaries.sh:18` interdit la classe de moteur audio,
   et les lignes 29–32 rejettent sa présence dans `Sources` ou `Features`, même
   pour une sortie. Le port du graphe source et du lecteur de fichiers est donc
   arrêté. Le DSP réel, la gestion des chemins et le rendu hors ligne sont prêts.
2. **Téléchargement HTTPS éphémère** : les lignes 211–219 du même audit ne
   permettent que les chemins site/Jev déjà approuvés. Les cinq émissions actives
   restent inchangées. Les URL réservées de packs figurent séparément, comme
   inactives, dans `docs/NETWORK.md` et `generate_security_artifacts.py`.
3. **Mesures de lecture sur périphérique** : aucun moteur de périphérique n’est
   créé. Les mesures portent sur le rendu hors ligne du DSP de production, comme
   autorisé pour un environnement sans sortie audio utilisable.
4. **Hébergement et disponibilité de la release** : la release
   `ambiance-packs-v1` reste à créer et approuver par le propriétaire. Les URL du
   catalogue sont réservées ; leur existence distante n’est pas affirmée.

## Vérification et mesures

Les preuves complètes sont dans le dossier privé `.ambiance-work/`, ignoré par Git.
La comparaison avant modification utilise un snapshot immuable du commit de
départ et des builds Release séparés arm64/x86_64 assemblés avec `lipo`. Le premier
essai multi-architecture direct a rencontré le doublon de produit CLI du package ;
la comparaison emploie les builds par architecture utilisés par le builder du dépôt.

- `swift build` : passé.
- `xcrun swift test` avec HOME et CFFIXED_USER_HOME isolés, et vrais packs :
  **1 544 tests, 43 skips opt-in, 0 échec**. Les tests keychain n’ont pas reproduit
  le piège historique dans cet environnement.
- Tests Ambiance et construction réelle du modèle : 14 tests, 0 échec ; seule la
  mesure longue opt-in est séparée. Tous les Focus/Relax produisent du son.
- Scripts du workflow : 20 commandes passées ; relancements natifs réels passés.
- Interactions disclosure, rendu analytics, effets Jev, parcours natifs : passés.
  Export de site vérifié en UTC, America/Chicago et Europe/Paris.
- Audit source final : passé, sans modification de ses règles.
- Bundle universel final arm64 + x86_64 : construit et signé, signature stricte
  vérifiée, inventaire de sécurité vérifié, smoke tests CLI passés. ZIP et DMG
  locaux fabriqués et vérifiés ; aucun upload. Les huit commandes bundle/package
  du workflow passent également.

### Taille de l’exécutable universel

Comparaison à profil de signature identique : copies des deux exécutables
signées ad hoc avec le même identifiant et des entitlements vides  pour éviter
que la différence de format de signature compte comme du code Ambiance.

| Avant | Après | Surcroît |
|---:|---:|---:|
| 84 217 984 octets | 85 130 544 octets | **+912 560 octets** |

Le surcroît de 0 913 Mo reste sous le plafond de 1 000 000 octets. Marge restante
pour la future UI : **87 440 octets** ; elle devra refaire la mesure.
L’exécutable effectivement signé dans le bundle pèse 85 130 880 octets.
Les deux architectures sont présentes. Aucun fichier audio ou archive de pack
n’est dans le bundle. Données : `.ambiance-work/binary-measures.json`.

### Mesures de production hors ligne

Code Swift compilé avec `-O`, Swift 5, cible macOS 13 ; objets C/OndeCore issus du
build Release. Le runner indépendant utilise les mêmes targets, **pas le processus
Goalong complet**. L’installation du pack est terminée avant de mesurer le repos.
RSS = octets résidents du processus ; Mo = 1 000 000 octets. Le pic est échantillonné
chaque seconde d’audio. Les 13 compositions sont mesurées sur 60 secondes d’audio,
avec 300 secondes pour Ambre et Confluence. Aucun périphérique audio n’est ouvert.

| Composition | RSS repos | RSS pic du rendu | RSS après arrêt | CPU d’un cœur |
|---|---:|---:|---:|---:|
| Ambre (300 s) | 10,91 Mo | 19,73 Mo | 11,83 Mo | 1,429 % |
| Confluence (300 s) | 18,79 Mo | 35,31 Mo | 19,09 Mo | 0,754 % |

Ambre : 4,286752 s CPU et 10,775421 s murales pour 300 s d’audio.
Confluence : 2,262433 s CPU et 4,321256 s murales pour 300 s d’audio.
Le CPU rapporté vaut temps CPU / durée audio × 100 ; le temps mural est aussi
conservé pour distinguer l’effet de la charge des autres processus du Mac.

Sur les 13 compositions : plus grand surcroît de RSS **16 515 072 octets** ;
plus grand écart absolu après arrêt **3 817 472 octets**, dans la tolérance ±5 Mo.
Copies d’échantillons : **0 octet**. Mappings logiques : 17 705 796 octets pour
Ambre, 53 569 492 pour Confluence ; ils sont tous libérés à l’arrêt. Ces résultats
valident le runtime hors ligne. La RAM et le CPU du futur graphe audio complet
restent à mesurer après revue de la frontière audio.

Données complètes : `.ambiance-work/measures-final.jsonl`, runner
`.ambiance-work/measure.swift`, logs `.ambiance-work/ci-*.log` et tableaux de statut
`.ambiance-work/ci-static-status.tsv` / `ci-native-status.tsv`. Les captures natives
sont conservées dans `.ambiance-work/qa-local-analytics/` et `qa/journey-ci/`.

Le `CONTEXT.md` partagé du checkout principal a été lu. L’interdiction de travailler
hors de ce worktree empêche de l’éditer ; ce document constitue la passation locale.

## Commits et fichiers ajoutés

Commits de code/outillage : `67a9a79` (moteur et mappings), `fbb278b` (API et
runtime), `832c71c` (packs et documentation des frontières), `21578a2` (buffers
bornés, dossiers imbriqués et états de pack). Le dernier commit contient seulement
cette passation et les mesures. Le bundle a été construit avec le code `21578a2`.

La spec `docs/AMBIANCE.md` était déjà non suivie au début et reste intacte, non
ajoutée aux commits. Aucune vue, aucun réglage UI ou `DashboardSection` n’a changé.

<details>
<summary>Nouveaux fichiers (41)</summary>

- `Features/Ambiance/Engine/ADAPTATIONS.md`
- `Features/Ambiance/Engine/LICENSE`
- `Features/Ambiance/Engine/OndeCore/FocusCompositions.swift`
- `Features/Ambiance/Engine/OndeCore/GenerativeRenderer.swift`
- `Features/Ambiance/Engine/OndeCore/GenerativeSettings.swift`
- `Features/Ambiance/Engine/OndeCore/OrchestraBank.swift`
- `Features/Ambiance/Engine/OndeCore/PlaybackSelection.swift`
- `Features/Ambiance/Engine/OndeCore/RelaxCompositions.swift`
- `Features/Ambiance/Engine/OndeCore/RenderingTypes.swift`
- `Features/Ambiance/Engine/OndeCore/TransitionRenderer.swift`
- `Features/Ambiance/Engine/OndeDSP/GravityPlanner.c`
- `Features/Ambiance/Engine/OndeDSP/GravityScore.h`
- `Features/Ambiance/Engine/OndeDSP/OndeDSP.c`
- `Features/Ambiance/Engine/OndeDSP/Orchestra.c`
- `Features/Ambiance/Engine/OndeDSP/Orchestra.h`
- `Features/Ambiance/Engine/OndeDSP/PhrasePlanner.c`
- `Features/Ambiance/Engine/OndeDSP/PlaybackEnvelope.c`
- `Features/Ambiance/Engine/OndeDSP/RelaxationPlanner.c`
- `Features/Ambiance/Engine/OndeDSP/RelaxationScore.h`
- `Features/Ambiance/Engine/OndeDSP/SceneMixer.c`
- `Features/Ambiance/Engine/OndeDSP/SignatureScore.h`
- `Features/Ambiance/Engine/OndeDSP/VowelChoir.c`
- `Features/Ambiance/Engine/OndeDSP/VowelChoir.h`
- `Features/Ambiance/Engine/OndeDSP/include/GravityPlanner.h`
- `Features/Ambiance/Engine/OndeDSP/include/OndeDSP.h`
- `Features/Ambiance/Engine/OndeDSP/include/PhrasePlanner.h`
- `Features/Ambiance/Engine/OndeDSP/include/PlaybackEnvelope.h`
- `Features/Ambiance/Engine/OndeDSP/include/RelaxationPlanner.h`
- `Features/Ambiance/Engine/OndeDSP/include/SceneMixer.h`
- `Features/Ambiance/Engine/SOURCE_COMMIT`
- `Features/Ambiance/Engine/THIRD_PARTY_NOTICES.md`
- `Features/Ambiance/Sources/AmbianceController.swift`
- `Features/Ambiance/Sources/AmbianceModule.swift`
- `Features/Ambiance/Sources/AmbiancePackCatalog.swift`
- `Features/Ambiance/Sources/AmbiancePackStore.swift`
- `Features/Ambiance/Sources/AmbianceRuntime.swift`
- `Features/Ambiance/Sources/AmbianceSettings.swift`
- `Features/Ambiance/Sources/AmbianceSource.swift`
- `Features/Ambiance/Tests/AmbianceTests.swift`
- `docs/AMBIANCE-IMPLEMENTATION.md`
- `scripts/build_ambiance_packs.py`

</details>
