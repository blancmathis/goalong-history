# Fast deploy — décisions de périmètre à autoriser

## Runner : contrôleur privé proposé

Créer le dépôt GitHub privé **`blancmathis/goalong-ci-private`**, accessible au propriétaire seulement, sans nouvelle prestation payante. Le runner installé sur le Mac serait enregistré exclusivement dans ce dépôt. Aucun runner du compte propriétaire ne serait rattaché au dépôt public.

Le contrôleur exécuterait une politique fixe de sa branche principale, revue et épinglée. Un composant de coordination de confiance, hors jobs de PR, relierait les demandes du dépôt public aux runs privés ; les identifiants exacts de PR, head/base/checkout/tree, run et artifact seraient recoupés avec GitHub. Aucun input ne permettrait de choisir un script, un dépôt ou une commande arbitraire.

Les PR externes conserveraient la CI GitHub-hosted. Seules les PR internes du dépôt officiel et les commits admissibles de main pourraient produire un candidat sur le Mac. L'admission aurait lieu avant le job, indépendamment du YAML public. Le hook local serait une défense supplémentaire, jamais la frontière d'admission.

Le dépôt public conserverait un reçu vérifiable des gates et de l'artifact du builder privé. La provenance finale continuerait de rattacher les octets servis au dépôt public et à son SHA ; elle déclarerait explicitement le run producteur privé et la promotion de métadonnée. Un run privé ne serait pas présenté comme un run PR public. La chaîne de vérification croisée doit être revue et prouvée avant activation ; aucune commande de provenance actuelle ne sera supprimée ou rendue moins stricte pour faire fonctionner ce circuit.

**Autorisation demandée :** ajouter ce dépôt privé et ce circuit de coordination. Le pipeline final, ses credentials et sa preuve de provenance restent à préparer et vérifier ; cette proposition ne prétend pas qu'ils sont déjà implémentés. Si le plan GitHub exige un nouveau paiement, arrêt avant toute souscription.

## Feed : préciser l'exigence

Le canal actuel utilise `gh release upload --clobber`. GitHub CLI documente que l'ancien asset est supprimé avant le nouvel upload et qu'un échec peut laisser le canal sans asset. Cette méthode ne garantit donc pas une lecture continue de l'ancien ou du nouveau feed.

Deux contrats distincts sont possibles, tous deux maintenant les vérifications Ed25519 :

- **Authenticité du contenu servi, canal existant :** aucun feed non signé/invalide n'est accepté ; une indisponibilité transitoire pendant le remplacement est admise, en échec fermé. L'URL et la clé de confiance restent celles des clients installés.
- **Disponibilité continue en plus de l'authenticité :** toute lecture doit recevoir un feed complet valide. Cela demande un canal à publication atomique et une migration compatible avec les URL déjà embarquées. Aucun changement d'URL, de clé ou de politique n'est autorisé par cette proposition ; il faut préparer ce plan séparément.

**Clarification demandée :** dans « le feed reste valide et signé à tout moment », faut-il garantir aussi l'absence de toute indisponibilité pendant l'upload ? Aucun affaiblissement de signature, d'identité ou de provenance n'est proposé.

## Décision de version déjà réglée

Compiler en PR la version suivante et le build monotone du run producteur, identiques dans le bundle et dans les deux tranches de la CLI. À la promotion : prouver le même arbre et toutes les gates, authentifier l'état public, exiger une version encore admissible et un build strictement supérieur, modifier seulement `GoalongSourceRevision`, re-signer avec les pins actuels, recréer les archives et attestations finales. Un candidat périmé/incohérent/absent impose un fallback sûr, même si le budget de temps échoue. Pas de patch Mach-O ni de renumérotation du seul plist extérieur.

Sources : [revue Pro 812713](/Users/mathisblanc/.gpt-pro/tasks/812713/response.md), [runner v2.338.0](https://github.com/actions/runner/blob/v2.338.0/src/Runner.Worker/StepsRunner.cs#L190-L285), [contrat de --clobber](https://cli.github.com/manual/gh_release_upload).
