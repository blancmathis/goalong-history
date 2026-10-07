# Blocage — manques + verrou « Mot de passe » (2026-10-07)

Demande du propriétaire : « corrige les manques » (A, B, C ci-dessous) et « une option pour que ça
fasse un blocage le plus difficile à enlever, avec un mot de passe pour débloquer ».
Niveau Standard seulement (pas de démon root : voir BLOCKING.md › Strict level).

## A. Verrou par plage
- `BlockProgramRange.lock: BlockLock?` (nil = `.free`, compatibilité des anciens fichiers).
- `programBlocks` : verrou du bloc = le plus fort entre `range.lock` et le verrou du programme
  (`program.isLocked(at:)` → `.locked`).
- Ordre de force : free < typing < password < locked. Matrice « plus strict seulement » :
  pendant un programme verrouillé, le verrou d'une plage peut seulement monter.
- Sauter une plage (`programSkips`) : refusé si la plage est `typing` sans défi tapé, `password`
  sans mot de passe juste, `locked` toujours. Même règle que `stop`.

## B. Blocage ponctuel programmé
- Une `BlockSession` avec `start > now` = programmée une fois. Pas de nouveau type.
- `controller.schedule(listIDs:start:end:lock:)` ; actif seulement quand `start <= now < end`.
- `scheduleTimer` tient compte des débuts de sessions futures. Annuler avant le début : libre si
  `.free`, sinon même friction que `stop` (défi, mot de passe, refus si `locked`).
- Les listes d'une session future verrouillée ne deviennent « plus strict seulement » qu'à partir de
  son début.

## C. Lancement à la connexion
- `updateProtection` enregistre `SMAppService.mainApp` dès qu'il existe un blocage à venir ou actif
  non libre : plage programmée (tout verrou), session future, session non libre. Aujourd'hui :
  seulement si `locked`. Ne jamais désinscrire un choix fait par le membre ailleurs
  (`LaunchAtLoginManager`).

## D. Verrou « Mot de passe » (le plus difficile)
Nouveau cas `BlockLock.password` (« Mot de passe »). Idée : un proche choisit le mot de passe et le
garde ; le membre ne peut plus rien desserrer sans lui.

- **Un seul mot de passe de blocage**, global (`BlockingDocument.passwordLock: BlockPasswordLock?`) :
  sel aléatoire 16 o + PBKDF2-HMAC-SHA256 (CommonCrypto, ≥ 200 000 tours) + date de création. Jamais
  le mot de passe en clair, ni en journal, ni en diagnostic.
- Définir : `setPassword(_:)` si aucun. Changer/supprimer : exige l'ancien, et refusé tant qu'un bloc
  `password` est actif ou à venir.
- Choisir `.password` sans mot de passe défini = refusé (l'UI le fait définir d'abord).
- **Pendant un bloc `password` actif** (et pour ses listes) — tout ce que fait `locked`, plus :
  - arrêt, saut de plage, annulation, pause/break au-delà des pauses prévues : mot de passe exigé ;
  - listes concernées « plus strict seulement » ; suppression de liste refusée ;
  - désactiver le module Blocage refusé (`apply(enabled: false)` et réglages modules) ;
  - Quitter Goalong (menu, ⌘Q, `applicationShouldTerminate`) : mot de passe exigé ; extinction /
    déconnexion du système autorisées ;
  - lancement à la connexion forcé (C).
- **Essais** : 5 erreurs → attente 1 min, puis doublée à chaque nouvelle erreur (max 1 h),
  persistée dans le document (survit au redémarrage).
- **Fichier modifié à la main** : si un bloc `password` existe et que le hash manque ou est
  illisible, le bloc devient `locked` (jamais libre).
- **Mot de passe oublié** : le bloc finit à son heure. Pas de porte dérobée.
- Honnêteté (texte UI) : « Un Forcer à quitter ou une désinstallation arrête le blocage jusqu'au
  prochain lancement. » Le niveau Strict reste le vrai rempart (plus tard).

## API pour l'UI (session Claude)
- `controller.unlockWithPassword(_ password: String, blockID: UUID) -> BlockingPasswordResult`
  (`.ok`, `.wrong(remaining:)`, `.wait(until:)`).
- `controller.hasPassword`, `setPassword`, `changePassword(old:new:)`, `removePassword(old:)`.
- `controller.schedule(...)`, `controller.cancelScheduled(id:typed:password:)`.
- `controller.quitRequiresPassword: Bool`, `controller.authorizeQuit(password:) -> BlockingPasswordResult`.
- `editCheck` renvoie une raison lisible quand le mot de passe bloque une modification.
