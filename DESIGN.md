---
name: Goalong History
description: "Le fil : la journée dessinée comme une seule ligne, sur les surfaces forêt et le lime de la marque."
colors:
  accent: "#d3f35f"
  on-accent: "#18210d"
  sidebar-dark: "#0b100d"
  page-dark: "#101712"
  group-dark: "#131b16"
  sidebar-light: "#eae7dc"
  page-light: "#f4f2ea"
  group-light: "#faf9f4"
  work-dark: "#d3f35f"
  other-dark: "#8497f2"
  unclassified-dark: "#66766a"
  work-light: "#56701a"
  other-light: "#5a69c4"
  unclassified-light: "#8a9184"
typography:
  hero:
    fontFamily: "system-ui"
    fontSize: "56px"
    fontWeight: 700
    letterSpacing: "-1.8px"
  title:
    fontFamily: "system-ui"
    fontSize: "28px"
    fontWeight: 700
    letterSpacing: "-0.6px"
  section:
    fontFamily: "system-ui"
    fontSize: "17px"
    fontWeight: 600
  body:
    fontFamily: "system-ui"
    fontSize: "13px"
    fontWeight: 400
  caption:
    fontFamily: "system-ui"
    fontSize: "12px"
    fontWeight: 400
rounded:
  mark: "3px"
  control: "8px"
  group: "12px"
spacing:
  unit: "4px"
  page-inset: "32px"
  section: "40px"
  group-inset: "16px"
components:
  navigation:
    rounded: "{rounded.control}"
    height: "36px"
  group:
    rounded: "{rounded.group}"
    padding: "{spacing.group-inset}"
    backgroundColor: "{colors.group-dark}"
---

# Goalong History — direction artistique « Le fil »

Document de référence du design de l'app macOS. Les longueurs sont des points AppKit. Le code de référence est
dans `Sources/LocalHistoryApp/` : `GoalongTheme.swift` (tokens), `GoalongControls.swift` et
`GoalongButtonStyle.swift` (contrôles), `GoalongSignature.swift` (le fil, états vides, confirmations),
`DashboardComponents.swift` (surfaces, en-têtes, navigation).

## 1. Le constat (audit du 2 octobre 2026)

Rendus natifs de toutes les pages, sous-pages et feuilles, en sombre et en clair, sur `main` (0.6.55) et sur
le WIP `644ca8f`.

- **0.6.55** : un kit de contrôles propre posé sur une structure inchangée. Chaque information vit dans une
  carte identique (même rayon, même filet) ; Activité empile jusqu'à neuf cartes et mesure 2 800 points de
  haut pour une seule journée. Rien ne dit « Goalong » en dehors de la couleur.
- **WIP `644ca8f`** : des effets ajoutés, pas une direction. La structure est identique à `main`. Le serif
  New York n'appartient pas à la marque (le site est en grotesque grasse et serrée) et, en thème clair,
  retombe sur le cliché « papier crème + serif ». Les courbes de niveau sont un décor sans rapport avec le
  logo ni avec les données. Le « sentier » n'apparaît que dans les états vides : il ne touche jamais le
  produit. Les dégradés (bouton « ensoleillé », halo lime, liseré lumineux sur chaque carte) ajoutent du
  bruit sans hiérarchie. Le logo animé de la barre latérale revenait sur une décision antérieure (logo
  statique, voir `docs/BRAND-MOTION.md`).
- **Erreurs de sens** : « Hors travail » portait la couleur d'avertissement alors que l'app ne juge pas ; le
  chiffre du temps actif portait le lime, qui est la couleur de la série « Travail » ; des tuiles d'icônes
  lime répétées diluaient l'accent ; des libellés en capitales surmontaient les titres de six pages.

Ce qui est gardé du WIP : les interactions physiques (appui à ressort, sélection qui glisse, chevron qui
avance), le centre de confirmations, les chiffres qui roulent, l'idée qu'un état vide est un début.
Ce qui est jeté : serif, courbes de niveau, dégradés, halos, liserés lumineux, logo animé de la barre latérale.

## 2. Trois directions comparées

| | A. Le fil (retenue) | B. Le carnet | C. L'instrument |
|---|---|---|---|
| Idée | La journée est une seule ligne continue, celle du logo déroulée dans le temps | Journal de terrain : serif, papier, courbes de niveau | Outil de précision dense : mono, grille serrée, palette de commandes |
| D'où vient l'âme | Des données elles-mêmes | D'un décor posé autour | D'une esthétique d'outil pour développeurs |
| Lien avec la marque | Direct : tracé du logo, lignes lime qui se tracent sur le site, grotesque serrée | Faible : typographie et motifs étrangers au site | Moyen : couleurs seulement |
| Risque | Demande de restructurer Activité | Kitsch, cliché en clair, décor qui fatigue | Froid, générique, contraire à « simplifier » |

**B est rejetée** : c'est le WIP mené à son terme. Son caractère vient d'emprunts (une police, un motif
cartographique) qui ne disent rien du produit et s'usent en une semaine d'usage quotidien.

**C est rejetée** : Goalong n'est pas un outil qu'on opère toute la journée, c'est un miroir qu'on consulte
quelques minutes. La densité et le vocabulaire « pro » contredisent la promesse (l'app ne juge pas, elle
montre) et produiraient un énième outil sombre.

**A est retenue** parce que l'élément mémorable y est le produit lui-même : ce que Goalong enregistre, c'est
le fil de votre journée, et son logo est déjà une ligne continue. La signature n'est donc pas un ornement,
c'est la donnée.

## 3. Concept

> Goalong déroule votre journée comme un fil. Une seule ligne, de la première trace à la dernière.
> Elle s'épaissit quand vous êtes actif, elle est lime quand c'était du travail selon *votre* définition,
> elle redevient un trait fin quand rien n'est observé. Elle ne casse jamais.

Trois principes en découlent :

1. **Le contenu est posé sur la page, pas rangé dans des boîtes.** Ce qui se lit (chiffres, fil, graphiques,
   constats) est posé directement sur le fond. Une surface n'apparaît que lorsqu'il y a quelque chose à
   manipuler (une liste de réglages, un formulaire, une liste cliquable).
2. **Le lime est rare.** Il signifie trois choses seulement : le travail dans les données, l'action
   principale, l'endroit où vous êtes (sélection, focus). Jamais un décor, jamais une icône d'ambiance.
3. **Une chose se dessine, le reste répond.** Par écran, un seul moment d'entrée : le fil qui se trace.
   Tout autre mouvement est la réponse à un geste.

## 4. L'unique élément mémorable : le fil

`GoalongDayThread` (journée) et `GoalongThreadWeave` (7 ou 28 jours), dans `GoalongSignature.swift`.

- **Journée** : un trait continu d'un point sur toute la largeur, de la première à la dernière observation
  (ou de 0 h à 24 h). Les périodes actives l'épaississent en segments de 14 points aux bouts arrondis :
  lime pour le travail, pervenche pour le hors travail, gris sauge pour ce qui reste à classer. Sous le fil,
  quelques repères horaires. Au survol, une étiquette donne l'intervalle, la durée et le classement.
- **Période** : un fil par jour, empilés du plus ancien au plus récent, sur une même échelle 0 h – 24 h.
  Sept ou vingt-huit fils forment une trame : on voit d'un coup d'œil quand on commence, quand on s'arrête,
  et où tombe le travail. Un clic sur un fil ouvre la journée. Cette trame remplace l'ancienne carte de
  chaleur.
- **Échos discrets** (même trait, jamais en concurrence) : le marqueur de sélection de la barre latérale,
  le fil d'étapes de l'onboarding, le trait en pointillé des états vides (« le fil n'a pas encore commencé »).

Le fil est la seule chose qui se trace à l'arrivée sur Activité (700 ms, de gauche à droite, une fois par
affichage). Avec « Réduire les animations », il est affiché complet immédiatement.

## 5. Palette

Les fonds et l'accent sont ceux du site (`goalong-website`, `styles/landing/shared.css`) et restent imposés.

| Rôle | Sombre | Clair |
|---|---|---|
| Barre latérale | `#0B100D` | `#EAE7DC` |
| Page | `#101712` | `#F4F2EA` |
| Groupe (surface manipulable) | `#131B16` | `#FAF9F4` |
| Contrôle relevé | `#1B251E` | `#FFFFFF` |
| Champ creusé | `#0C120E` | `#FFFFFF` |
| Filet | `#26332A` | `#DCDFD3` |
| Filet fort (contraste renforcé) | `#718A75` | `#828B76` |
| Texte | `#F2F6EF` | `#0D100E` |
| Texte secondaire | `#A0B0A4` | `#566252` |
| Accent (sélection, focus, liens) | `#D3F35F` | `#4B611B` |
| Action principale (fond / encre) | `#D3F35F` / `#18210D` | identique |

**Données** (les trois états du temps actif, toujours dans cet ordre) :

| | Sombre | Clair |
|---|---|---|
| Travail | `#D3F35F` | `#56701A` |
| Hors travail | `#8497F2` (pervenche) | `#5A69C4` |
| À classer | `#66766A` (sauge neutre) | `#8A9184` |

« Hors travail » n'est ni une alerte ni une faute : il quitte l'ambre d'avertissement pour une pervenche
calme, presque complémentaire du lime. « À classer » est volontairement neutre : c'est une absence de
classement, pas une catégorie. La palette est passée au validateur (`dataviz/scripts/validate_palette.js`,
surfaces `#101712` et `#f4f2ea`) : séparation daltonisme ΔE ≥ 17,8 et vision normale ≥ 18,4 dans les deux
thèmes. Deux écarts assumés : le lime de marque est plus clair que la bande recommandée en sombre, et le
gris « À classer » est sous le seuil de chroma (c'est son rôle) et à 2,9:1 en clair ; l'identité ne repose
donc jamais sur la couleur seule (légende toujours présente, libellé texte dans chaque ligne, valeurs
accessibles à VoiceOver).

Les couleurs d'état (succès `#98D7A5`, avertissement `#EED08C`, danger `#FFADA0`, privé `#C7B4E8`) sont
réservées aux états du système et ne servent jamais de couleur de série. Le texte ne porte jamais une
couleur de série : les valeurs sont en encre, la couleur est sur la marque à côté.

## 6. Typographie

Une seule famille, San Francisco, comme le site n'en a qu'une (Inter). Le caractère vient de l'échelle et du
serrage, pas d'une seconde police.

| Rôle | Corps | Graisse | Interlettrage | Usage |
|---|---|---|---|---|
| Héros | 56 | bold | −1,8 | Le chiffre de la période, un seul par écran, chiffres proportionnels |
| Titre de page | 28 | bold | −0,6 | Un par page |
| Titre de feuille | 22 | bold | −0,4 | Un par feuille |
| Chiffre secondaire | 22 | semibold | −0,4 | Les trois mesures à côté du héros |
| Section | 17 | semibold | −0,2 | Titres posés sur la page |
| Groupe | 13 | semibold | 0 | Intitulé d'un groupe de réglages, en texte secondaire |
| Ligne | 13 | medium | 0 | Libellé d'une ligne, d'un bouton |
| Corps | 13 | regular | 0 | Texte courant |
| Légende | 12 | regular | 0 | Aide, méta, texte secondaire |
| Micro | 11 | regular | 0 | Axes de graphiques uniquement |

Chiffres tabulaires dans les colonnes et les axes, proportionnels pour les grands chiffres isolés. Pas de
libellé en capitales, pas de sur-titre au-dessus des titres. Une méta tient en une phrase courte plutôt
qu'en fragments séparés par des points médians.

## 7. Espacement et mise en page

Grille de 4 points : 4, 8, 12, 16, 24, 32, 40.

- Marge de page 32. Largeur de lecture 760 pour les pages de réglages et de texte, pleine largeur (jusqu'à
  1 080) pour Activité et Historique.
- Activité : le chiffre héros, puis ses trois chiffres secondaires, puis le fil, toujours dans cet ordre et
  empilés, pour que la page ne change pas de forme entre Jour, 7 jours et 28 jours.
- 40 entre deux sections posées sur la page, 16 entre un titre de section et son contenu, 12 entre deux
  éléments d'un même ensemble, 8 à l'intérieur d'un élément.
- Lignes de liste : 44 de haut minimum, filet de séparation en retrait, aligné sur le texte.
- Tout est aligné à gauche sur une même verticale ; les valeurs et les interrupteurs partagent le bord droit.

## 8. Hiérarchie des surfaces

| Niveau | Quoi | Traitement |
|---|---|---|
| 0 | Barre latérale | Fond le plus sombre, aucun filet interne |
| 1 | Page | Fond de page ; le contenu à lire y est posé sans cadre |
| 2 | Groupe (`LHCard`, `GoalongSettingsGroup`) | Surface tonale, filet d'un point, rayon 12 ; uniquement pour ce qui se manipule |
| 3 | Contrôle | Relevé (boutons, segmentés) ou creusé (champs), rayon 8 |
| 4 | Flottant (popover, confirmation, menu) | Surface relevée et la seule ombre de l'app |

Pas de dégradé, pas de liseré lumineux, pas de carte dans une carte. Une note (`GoalongNote`) est un bloc
teinté sans filet. Un seul rayon par niveau : 3 pour les marques de données, 8 pour les contrôles, 12 pour
les groupes.

## 9. Composants

Dans `GoalongControls.swift`, sauf mention.

**Actions**
- **Bouton principal** (`LHPrimaryButtonStyle`, `GoalongButtonStyle.swift`) : encre sur lime, aplat. Un seul par
  écran ou par feuille.
- **Bouton secondaire** (`LHSecondaryButtonStyle`) : surface relevée, filet. Rôle destructif en texte danger.
  C'est le style par défaut posé par `.goalongControls()`.
- **Bouton discret** (`LHQuietButtonStyle`) : texte accent sans fond, pour les actions de troisième rang
  (« Corriger », « Voir les 12 usages »). Le fond de survol déborde du texte pour garder l'alignement.

**Saisie et choix**
- **Champ, zone de texte, recherche** (`GoalongFieldStyle`, `GoalongTextArea`, `GoalongSearchField`) : creusés,
  filet qui passe au lime et s'épaissit au focus. `GoalongFormField` : libellé, une ligne d'aide au plus, et
  l'explication longue derrière un bouton d'information.
- **Interrupteur** (`.goalongSwitch`, `.goalongSwitchInline`, `.goalongSwitchOnly`) : piste à coins de contrôle
  et curseur carré arrondi, la même famille d'angles que les boutons. Lime et encre quand il est actif. Le
  curseur s'étire vers sa destination pendant l'appui. Taille réduite dans les longues listes.
- **Case à cocher** (`.goalongCheckbox`) : boîte creusée, lime avec coche encre quand elle est cochée.
- **Segmenté** (`GoalongSegmentedControl`) : piste creusée, pastille relevée qui glisse.
- **Sélecteur de jour** (`DateSelectionControl`, `DashboardComponents.swift`) : ‹ jour ›, calendrier en popover.
- **Restent natifs, volontairement** : menus déroulants (`Picker` en menu), calendriers et sélecteurs
  d'heure, curseurs, pas-à-pas, alertes et dialogues de confirmation. Leur comportement clavier et VoiceOver
  vaut plus qu'une peau maison.

**Structure**
- **Section** (`GoalongSection`, `DashboardComponents.swift`) : titre posé sur la page, action discrète à
  droite, contenu sans cadre. Pour tout ce qui se lit.
- **Groupe** (`LHCard`, `GoalongSettingsGroup`) : la surface de niveau 2, pour ce qui se manipule.
- **Liste** (`GoalongSettingsList`, `GoalongSettingsLink`, `GoalongRowDivider`, `SimpleSettingsComponents.swift`) :
  lignes pleine largeur dans un groupe, glyphe neutre sans tuile, libellé, valeur, chevron qui avance au survol.
- **Dépliant** (`GoalongDisclosureGroup`) : ligne pleine largeur, chevron qui pivote.
- **Note** (`GoalongNote`) et **bandeau** (`GoalongBanner`) : information secondaire dans un bloc teinté sans
  filet ; ton neutre, confidentialité ou avertissement.
- **En-tête de page** (`PageHeader`, `.goalongPageTitle()`) : un titre, une phrase. Jamais de sur-titre.
- **Pastille d'état** (`StatusPill`) : le glyphe porte la couleur, le mot reste en encre.

**Données**
- **Le fil** (`GoalongDayThread`, `GoalongThreadWeave`, `GoalongThread.swift`) : voir section 4.
- **Graphiques** (`GoalongActivityCharts.swift`) : barres de 24 points au plus, coins de 3, écart de 2 points
  entre segments empilés, grille en filets pleins, légende toujours présente (`GoalongActivityClassLegend`).
- **Part d'un total** (`GoalongShareBar`) : la même barre fine dans les tâches, les usages et les jauges.
- **Chiffre** : un héros par écran ; les chiffres secondaires sont des colonnes sans cadre, précédées de la
  marque de couleur quand ils correspondent à une série.

**États**
- **État vide** (`GoalongEmptyState`, `EmptyStateView`) : le fil en pointillé qui attend
  (`GoalongThreadPlaceholder`), un titre, une phrase, une action.
- **Chargement** : `GoalongPageLoadingView` (animation « Passage » du logo, inchangée, liée à une opération
  réelle) pour une page entière ; `ProgressView` natif de petite taille dans un bouton ou une ligne.
- **Confirmation** (`GoalongToastCenter`, `GoalongSignature.swift`) : pastille en bas de fenêtre, coche qui se
  trace, annoncée à VoiceOver, disparaît seule.
- **Onboarding** (`OnboardingView.swift`, `OnboardingPages.swift`) : les étapes sont accrochées à un fil dans la
  colonne de gauche (lime pour le chemin parcouru) ; la première page montre un fil d'exemple qui se trace.

## 10. Mouvement

Une seule courbe, celle du site : `cubic-bezier(.2, .8, .2, 1)` (`LHTheme.ease`).

| Geste | Réponse | Durée |
|---|---|---|
| Survol | Fond ou filet qui change, chevron qui avance de 3 points | 120 ms |
| Appui | Échelle 0,97, fond pressé | ressort court |
| Changement d'état (interrupteur, onglet, sélection) | La pastille ou le curseur glisse jusqu'à sa place | 240 ms |
| Déplier | Le chevron pivote, le contenu apparaît | 240 ms |
| Changement de page | Fondu | 160 ms |
| Arrivée sur Activité | Le fil se trace de gauche à droite, une fois | 700 ms |
| Confirmation | La pastille monte, la coche se trace, puis s'efface | 240 ms + 2,4 s |

Aucune animation en boucle, à une exception près, antérieure et conservée : l'animation « Passage » du logo
pendant une attente réelle (`docs/BRAND-MOTION.md`). Avec « Réduire les animations » : aucun tracé, aucune
échelle, aucun glissement ; les états changent immédiatement, seul un fondu court subsiste.

## 11. Natif et accessibilité

- Focus clavier : anneau lime de 2 points à l'extérieur de chaque contrôle (encre sur le bouton principal).
- VoiceOver : tous les identifiants d'accessibilité existants sont conservés ; le fil expose un résumé
  textuel et chaque graphique ses valeurs ; les interrupteurs se présentent comme des cases natives.
- Contraste renforcé : filets forts, pas de teinte décorative.
- Clair et sombre : mêmes rôles, valeurs choisies séparément (tableaux ci-dessus).
- Fenêtre minimale 900 × 620 ; les en-têtes passent sur deux lignes quand la largeur manque.
- Les feuilles `.sheet` n'héritent pas du style de bouton de la vue parente : chaque fermeture `.sheet`
  applique `.goalongControls()`.

## 12. À faire et à ne pas faire

- Poser le contenu à lire sur la page ; réserver les groupes à ce qui se manipule.
- Un seul chiffre héros, un seul bouton lime, un seul tracé d'entrée par écran.
- Écrire court : une phrase d'aide au plus sous un réglage, le reste dans un dépliant.
- Ne pas réintroduire : serif, dégradés, halos, tuiles d'icônes teintées, sur-titres en capitales, ombres
  sous les cartes, contrôles gris AppKit (`.bordered`, `.roundedBorder`, interrupteur ou segmenté natifs).
- Ne jamais présenter une app ou un site comme « productif » ; « Hors travail » n'est pas une alerte.
- Ne toucher ni à la capture, ni au stockage, ni aux consentements, ni aux envois depuis un travail de design.

## 13. Vérification

`scripts/verify_design_audit.sh <dossier>` rend chaque page, sous-page de Réglages et feuille, en sombre et
en clair, dans un HOME isolé. `GOALONG_ANALYTICS_SNAPSHOTS=<dossier> swift test --filter
GoalongAnalyticsRenderingTests` rend Activité avec des données fictives. `scripts/verify_brand_ui.sh` exerce
de vraies actions d'accessibilité. Les clics simulés n'atteignent pas les gestes SwiftUI : survols, appuis et
tracés se vérifient à la main dans l'app.

L'état de vérification de la passe « Le fil » est tenu à jour dans `docs/DESIGN-SOUL-VERIFICATION.md`.
