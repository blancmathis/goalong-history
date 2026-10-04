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
FLAC et les fichiers audio d’un dossier choisi.

## Moteur et packs

Onde est vendorisé au commit `dfa5ab747373d1eed324115db07971c4096ffc49`.
Provenance, MIT et notices originales se trouvent dans `Features/Ambiance/Engine`.
Le target C utilise la norme C11 du package, sans ajouter de flags non sûrs ou de
dépendance distante. Les adaptations sont détaillées dans `Engine/ADAPTATIONS.md`.

Le cache global décodé d’Onde a été retiré. Les instruments d’une composition sont
vérifiés par lectures de 64 Kio puis mappés en lecture seule. Le sampler interpole
directement le PCM16 stéréo, sans copie PCM32. Les mappings ont une durée de vie
explicite jusqu’à la destruction du DSP ; l’arrêt détruit le DSP avant de démappper.
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

- Tests ciblés : 11 tests, 0 échec avec les vrais packs ; la mesure opt-in est
  exécutée séparément avec le code compilé en Release.
- Scripts de workflow : 20 commandes de validation/audit passées.
- Audit source : passé, sans modification de ses règles.
- Mesures binaires, mémoire, CPU et commandes CI natives restantes : en cours.

Le `CONTEXT.md` partagé du checkout principal a été lu. L’interdiction de travailler
hors de ce worktree empêche de l’éditer ; ce document constitue la passation locale.
