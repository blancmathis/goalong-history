# Usage passif au premier plan

Le temps local ne dépend plus exclusivement du délai depuis le dernier clavier
ou mouvement de souris. Il n’est pas une preuve d’attention ou de productivité.
Apple Screen Time reste une source distincte, non modifiée par ce mécanisme.

## Signaux et périmètre

`ForegroundActivityProbe` ne considère que l’application réellement au premier
plan, non masquée, avec une fenêtre visible. `IOPMCopyAssertionsByProcess` fournit
les assertions macOS, y compris avec les libellés/titres désactivés ; seules les assertions actives `PreventUserIdleDisplaySleep`
du PID de cette app ou de ses helpers embarqués dans ce même bundle sont retenues.
Les assertions système, téléchargements, audio global, CPU, daemon ou caffeinate
ne constituent pas un signal pour une autre app. Aucune commande shell n’est
exécutée par la sonde ; aucun son, image, titre d’assertion ou vidéo n’est enregistré.

Lorsque la lecture des libellés est déjà autorisée, un parcours Accessibility
borné de la fenêtre focalisée recherche des contrôles précis : Pause pour une
lecture en cours, Quitter/Terminer l’appel pour une réunion. Un contrôle Lecture
indique une pause et neutralise l’assertion résiduelle. Le nom Zoom seul ne suffit
jamais. Le budget est de 192 nœuds, 75 ms plus un éventuel appel AX en cours borné
à 25 ms. Le cache est borné à 10 s et invalidé aux changements de contexte,
permissions de libellés, révisions de confidentialité et interruptions. Les
changements rapides de contexte invalident le cache sans multiplier les sondages.

Un signal navigateur au niveau du processus ne permet pas d’identifier l’onglet
qui joue. Sans saisie récente, il contribue au temps de l’app, sans attribuer de
site, classer son contenu ni alimenter la surveillance sémantique. Les contrôles de lecture/appel du contexte focalisé
peuvent alimenter la surveillance déjà activée, même sans nouvelle saisie.

## Durées et confidentialité

Le marqueur compact `activity.foreground_evidence` est conservé dans les projections
bornées, sans y retenir de contenu supplémentaire. Les changements de signal
produisent une observation immédiate ; tant que le signal existe, les sondes
sont espacées d’au plus 10 s et les battements de 30 s. Un arrêt peut donc être
constaté au sondage suivant ; ces observations ne sont pas une mesure à l’image près.
La veille écran/système, le verrouillage, les pauses, Secure Input, les fenêtres
privées et les exclusions conservent leur priorité. Aucun consentement n’est activé
ni nouvelle autorisation système demandée. Sans API/contrôle probant, la détection
reste prudente. Certains lecteurs ou logiciels n’exposant aucun signal peuvent
rester non détectés. Les journaux anciens ne sont ni réécrits ni reconstitués.

## Validation

Tests de 45 minutes de réunion et 30 minutes de vidéo sans input, arrêts/changements
d’app, périodes privées, verrouillage/veille, trous, métadonnées anciennes/inconnues,
passage par les lecteurs minimaux de disque, attribution site/app et absence de
faux input. Un test macOS crée puis libère une assertion réelle du processus de
test et vérifie le lecteur IOKit ; il ne simule pas un appel Zoom de bout en bout.
