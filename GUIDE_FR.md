# Guide simple — LocalHistory v0.3.2

## Ce que fait l'application

LocalHistory observe l'activité autorisée du Mac et conserve les détails **uniquement en local** : application, fenêtre, clics, défilements, raccourcis et activité de saisie sans enregistrer les caractères tapés.

Toutes les minutes, elle crée une preuve cryptographique. Lorsque la vérification serveur est activée, seul cet engagement opaque est envoyé. Le serveur ne reçoit alors ni l'application, ni le site, ni la fenêtre, ni les clics, ni la catégorie de travail.

Plus tard, l'utilisateur peut publier une journée en choisissant précisément ce qu'il révèle pour chaque période :

- **Full details** : tous les champs partageables ;
- **Application only** : l'application et l'heure, sans le contexte ;
- **Category only** : la catégorie locale, sans l'application ;
- **Completely private** : uniquement l'existence et la couverture de la période.

L'historique original n'est jamais réécrit pour être anonymisé. L'application fabrique un package de partage séparé et vérifiable.

## La nouvelle interface v0.3

### Overview

Affiche immédiatement :

- si l'enregistrement fonctionne ;
- les permissions manquantes ;
- le temps actif et classifié comme travail ;
- les minutes scellées et reçues par le serveur ;
- les périodes privées ou indisponibles ;
- une timeline de 24 heures ;
- les applications principales et les sessions récentes.

### Activity

Permet de rechercher et filtrer les sessions. En sélectionnant une session, on voit le contexte local, la catégorie, la durée, le nombre d'événements et les éventuels signaux d'entrée générée par logiciel.

### Share

C'est ici que l'utilisateur anonymise sa journée. Les minutes similaires sont regroupées pour faciliter la navigation. Chaque groupe possède un menu de confidentialité et un aperçu exact de ce qui sera révélé ou conservé sur le Mac.

Le bouton **Export verified package** crée un fichier JSON séparé. Les périodes dont les détails ont été supprimés sont automatiquement forcées en mode complètement privé.

### Privacy & security

Explique le trajet des données, montre les permissions macOS, le stockage local, l'identité cryptographique du Mac et les protections appliquées. Les boutons de suppression effacent les détails locaux mais conservent les preuves, afin qu'une mauvaise période ne puisse pas simplement disparaître.

### Settings

Permet de régler la capture, la conservation, l'anonymisation des URL, le serveur de vérification, App Attest et les applications/sites exclus. Les changements doivent être sauvegardés explicitement.

## Installation

1. Décompresse le ZIP.
2. Ouvre le dossier `LocalHistory`.
3. Double-clique sur `Install.command`.
4. Si macOS bloque le fichier : clic droit → **Ouvrir**.
5. Autorise **Accessibilité** et **Surveillance de l'entrée**.
6. L'interface s'ouvre automatiquement lors du premier lancement de la v0.3.

Ensuite, clique sur l'icône LocalHistory dans la barre des menus pour rouvrir l'interface, mettre l'enregistrement en pause ou préparer un partage.

## Tester le serveur anti-triche en local

```bash
cd server_reference
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app:app --host 127.0.0.1 --port 8787
```

Dans LocalHistory :

1. ouvre **Settings** ;
2. active **Send opaque minute commitments** ;
3. saisis `http://127.0.0.1:8787` ;
4. clique **Save settings**.

Utilise HTTPS pour un serveur distant.

## Fichiers importants

```text
events/    historique détaillé privé
seals/     preuves cryptographiques locales
receipts/  reçus des preuves acceptées par le serveur
shares/    packages anonymisés exportés
```

Si le JSON détaillé est modifié après l'ancrage, il ne correspondra plus aux preuves déjà reçues. Si les détails sont supprimés, la période reste visible mais ne peut plus être partagée autrement qu'en privé.

## Important sur App Attest

Le client contient le pont App Attest, mais le serveur de référence ne prétend pas encore le valider. Il renvoie volontairement `appAttestAccepted=false` tant qu'un vrai validateur Apple n'est pas connecté.

Pour la production, il faudra utiliser ton compte Apple Developer, ton Team ID, ton Bundle ID, une application officiellement signée/notarisée et une validation App Attest complète côté serveur.
