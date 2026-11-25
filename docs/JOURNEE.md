# Journée guidée et processus en parallèle

Goalong réunit le déroulé humain de la journée et les travaux qui avancent en parallèle. Une personne peut suivre une seule tâche, ou lancer plusieurs agents puis documenter, créer, répondre et vérifier pendant qu'ils travaillent. Le modèle n'impose pas un nombre de projets ou une méthode de travail.

## Activer et comprendre le guide

Dans **Réglages → Modules → Journée guidée**, lire la présentation puis activer le guide. L'explication reste accessible par « Revoir l'explication » et dans la page du programme. L'activation démarre seulement le composant Concentration s'il manque ; elle n'active pas le module Blocage. Désactiver le guide arrête ses rappels et ses ajustements de reprise, sans supprimer le programme, arrêter une séance ou modifier un blocage.

Une installation neuve n'a ni guide actif, ni agenda, ni modèle de routine, ni appel IA automatique. Les anciens rappels matin/soir sont aussi désactivés par défaut ; une préférence déjà enregistrée est conservée. Aucun horaire, activité personnelle ou contexte de l'auteur n'est installé chez les autres utilisateurs. Les nouveaux formulaires d'agenda demandent les horaires souhaités.

Le premier écran montre l'action actuelle et ses consignes. Les réponses attendues des agents viennent ensuite ; un agenda long affiche un aperçu près du moment présent et permet d'ouvrir toute la journée. Fermer un rappel ne coche rien : l'action reste dans le programme. Le temps écoulé ne constitue pas une preuve d'exécution.

## Trois objets complémentaires

| Objet | Ce qu'il décrit | Exemple |
|---|---|---|
| Action humaine | Un résultat ou une intervention de la personne, avec un premier geste et une fin reconnaissable. | Écrire la section de décision ; lancer deux briefs ; enregistrer une démonstration. |
| Créneau | Quand faire une action ou suivre un repère de routine. | Documentation à 10 h ; déjeuner ; réponses aux agents. |
| Processus | Un travail parallèle dont l'état est explicitement signalé. | Un agent implémente ; un autre attend une décision ; un troisième est prêt à relire. |

Un créneau peut pointer vers une action via itemID. Une action peut référencer plusieurs processIDs. Les liens contextURL mènent à la documentation ou au livrable : Goalong n'est pas une copie des documents ni des conversations.

La journée reste bornée : au plus dix actions humaines, 64 créneaux et 64 processus. Les processus ne consomment pas automatiquement toute une plage d'attention humaine. Leur durée ne s'ajoute pas aux heures de travail de la personne.

## Suivre et adapter le jour

L'agenda distingue les repères fixes et les blocs flexibles. Le premier geste est affiché dans nextAction ; doneWhen précise comment reconnaître la fin. actionKind distingue travail, lancement, coordination, revue et routine.

Une routine récurrente fournit des repères sans inventer de tâches professionnelles. Ses créneaux n'ont pas d'itemID. Chaque journée peut ensuite recevoir ses vraies actions. Les horaires, le fuseau, la marge et le guidage sont propres à l'utilisateur ; le dépôt n'embarque pas la routine personnelle de son auteur.

Les réponses CLI exposent agendaDiagnostics : les conflits et identifiants des créneaux qui ne tiennent pas. Cette lecture ne modifie rien. Vérifier ces avertissements avant de présenter une journée comme réalisable. Une nouvelle configuration doit utiliser le fuseau du calendrier natif du Mac ; les données historiques conservent leur fuseau.

Le réagencement garde les blocs fixes et les créneaux déjà traités. Il replace les blocs flexibles restants avec la marge choisie et leurs éventuelles bornes earliestMinute/latestEndMinute. Un bloc qui ne tient plus dans la journée reste visible avec state unscheduled. Un chevauchement d'ancrages doit être corrigé explicitement ; l'algorithme ne le résout pas en déplaçant silencieusement un rendez-vous fixe. Le réagencement ne décide ni qu'un travail est terminé ni qu'un agent a repris. Quand autoAdjust est actif, les interactions de début/fin, le report de quinze minutes et la reprise d'une journée tardive peuvent déclencher ce recalage ; reflow le demande explicitement.

Chaque créneau peut contenir des instructions multilignes (1 200 caractères au maximum), un lien et un choix de rappel : inherit suit le choix de l'agenda, notify demande un rappel explicite, silent n'en demande aucun. Tous restent soumis à l'activation du guide, à son interrupteur global des rappels, à sa plage silencieuse éventuelle et au plafond de l'agenda. La plage silencieuse peut traverser minuit ; elle n'arrête aucun blocage ou séance.

Les rappels natifs apparaissent aux horaires choisis, une fois par créneau, avec un report de quinze minutes. Le plafond reminderLimit vaut huit par défaut et se règle de un à 32 par jour. Choisir les transitions utiles plutôt que notifier chaque geste. Il n'y a pas de rafale de rattrapage au réveil. Leur exécution dépend de l'app ; aucun second agent de surveillance n'est lancé. Un repère fixe peut se situer après la fin du travail et être silencieux, avec toutes ses étapes visibles avant de quitter le Mac.

Le conseil IA est une option séparée, désactivée par défaut : [COACH.md](COACH.md) décrit le choix de modèle, l'aperçu des données, les limites d'appels et l'utilisation d'un agent externe. L'agenda, le réagencement et les rappels n'utilisent aucun modèle.

Les réponses non urgentes peuvent être regroupées dans des créneaux de coordination. Une question bloquante reste visible sans transformer tous les travaux de création en une suite d'interruptions. L'utilisateur garde le choix de changer la priorité.

## États des processus

| État | Signification |
|---|---|
| queued | Accepté, pas encore commencé. |
| running | L'agent a explicitement commencé ou repris. |
| waitingForYou | Une réponse ou action humaine est nécessaire. |
| readyForReview | Le résultat attend une revue. |
| done | Les critères de fin ont été satisfaits. |
| failed | Le processus s'est arrêté sur un échec concret. |
| cancelled | Le travail a été annulé explicitement. |

Les champs question et answer contiennent uniquement la décision utile. Enregistrer une réponse ne change pas automatiquement waitingForYou en running : le travailleur confirme sa reprise. Un résultat readyForReview ne devient pas done sans le contrôle prévu.

Ces états sont déclarés. Goalong ne lit pas automatiquement les fils T3, ne mesure pas l'avancement d'un agent à partir du temps d'écran et ne prend pas son silence pour une réussite.

## CLI et agents

Le CLI local et l'app partagent les mêmes objets. L'app reste l'unique auteur des fichiers Focus ; les intégrations passent par son socket local, jamais par une édition directe de la base. Voir [CLI.md](CLI.md) pour les schémas et commandes.

Le paquet réutilisable [.agents/skills/goalong-day](../.agents/skills/goalong-day/SKILL.md) apprend aux agents à :

- reprendre un processus existant avec un ID stable ;
- publier seulement leurs changements d'état réels ;
- transmettre une question courte et un lien documentaire ;
- préparer les actions humaines sans sérialiser les agents ;
- fusionner les changements avec contrôle de révision ;
- poursuivre le vrai travail lorsque Goalong est indisponible.

Son helper Python n'a aucune dépendance externe. prepare et process produisent un fichier d'opération sans écrire. apply envoie une seule demande. Aucun serveur MCP, agent permanent ou boucle de surveillance n'est nécessaire. L'installation du skill dans un environnement d'agents ne garantit pas sa lecture par des fils déjà démarrés.

## Écritures concurrentes

Chaque plan a une revision (zéro pour un ancien plan). Une écriture fournit if-revision et un request-id unique. items/processes sont des upserts d'objets complets : lire l'objet courant et préserver ses champs avant de changer ceux qui sont concernés. agenda remplace l'ensemble de l'agenda.

Le contrôle de révision empêche un agent de remplacer silencieusement une modification arrivée entre sa lecture et son écriture. Après conflict, relire puis reconstruire le changement utile. Le même identifiant et le même corps peuvent être rejoués sans appliquer deux fois l'opération tant que le reçu est conservé. Un identifiant réutilisé avec un autre contenu renvoie requestConflict.

Après outcomeUnknown ou un délai d'écriture, inspecter les receipts du plan avant une nouvelle action. Le CLI peut avoir transmis la demande même si la réponse n'est pas revenue. Ne pas générer immédiatement un autre identifiant. Le helper conserve l'opération préparée et ne réessaie pas seul.

Le journal changes conserve la raison, l'acteur, la date et la révision d'une modification. Il aide à comprendre un déplacement sans faire passer un raisonnement d'agent pour une décision de l'utilisateur. Les commandes undo et reflow utilisent les mêmes garanties de concurrence. Undo restaure seulement l'agenda précédent, en préservant les tâches/processus et les états déjà actifs, terminés ou passés. Il ajoute une nouvelle révision ; il n'efface pas les reçus ni l'historique.

## Données et limites

Conserver seulement les métadonnées nécessaires à l'action. Ne pas mettre de secrets, tokens, transcripts complets ou données personnelles sensibles dans les titres, réponses ou URLs. Les exports publics et les données d'activité ne deviennent pas une deuxième base d'objectifs. Une option native distincte, désactivée par défaut, peut fournir à Jev uniquement le titre et le premier geste de l'action liée à la session courante, dans le budget de contexte existant. Elle n'envoie ni la file d'agents, ni leurs questions, ni la documentation ; le budget peut omettre cette action entièrement. Voir [NETWORK.md](NETWORK.md) pour la frontière réseau.

L'activité observée, le temps d'une session, l'état déclaré d'un processus et un résultat vérifié sont des informations différentes. Les données absentes restent inconnues. Une routine affichée n'atteste pas qu'une personne s'est entraînée, a mangé, médité ou dormi.

Les commandes de guidage ne lancent pas les agents, ne publient pas leur travail et ne modifient pas automatiquement les protections de blocage. Un rappel de fin de journée guide l'utilisateur ; il ne constitue pas un verrouillage du Mac.

Une configuration de blocage explicitement demandée peut utiliser le CLI block-list : les listes et plages passent par le contrôleur natif, avec empreinte de concurrence et refus des affaiblissements protégés. Cette opération reste distincte de l'activation du guide. Les agents n'écrivent jamais directement les fichiers de blocage ni les mots de passe.
