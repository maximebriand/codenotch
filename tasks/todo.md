# Session Switcher — plan

Un panneau HUD ouvert par raccourci global qui liste **toutes les sessions
d'agent en cours**, groupées par application et par workspace, et qui remonte
la bonne fenêtre quand une session se bloque sur une question.

Motivation : neuf sessions `claude` et une `copilot` réparties sur quinze
blocks Wave dans quatre workspaces, et rien pour dire laquelle attend quoi.
Aujourd'hui les sessions ne sont visibles que dans le tooltip d'un anneau à la
fois — jamais toutes ensemble, et seulement au survol.

## Ce qui existe déjà et qu'on réutilise

- `AgentSession` — état `busy` / `waiting` / `success` / `idle` + pid
- `SessionFocus` — pid → app propriétaire via l'arbre de process, et `activate()`
- `TerminalTabFocus` — sélection de l'onglet exact (Terminal.app, iTerm2, Ghostty, cmux)
- `SessionCompletionWatcher` — transitions `busy → idle/waiting`, déjà branché
  sur le son et le peek dans `AppDelegate.announceCompletions`
- `ActivityCoordinator` — cycle de vie des moniteurs

Rien de tout ça n'est à refaire. Le switcher est une **vue transversale** de ce
que les moniteurs publient déjà, plus deux moniteurs/ciblages manquants.

## M1 — Localiser une session

- [x] `Sources/Sessions/SessionLocation.swift` — où vit une session : bundle id
      et nom de l'app propriétaire, plus un conteneur nommé (workspace + onglet
      Wave, fenêtre Terminal.app). Résolu depuis le pid, comme `SessionFocus`.
- [x] `Sources/Sessions/WaveTerminal.swift` — le cas Wave :
      - lire `WAVETERM_BLOCKID` / `TABID` / `WORKSPACEID` / `JWT` dans
        l'environnement de l'ancêtre du process, via
        `TerminalTabFocus.environment(of:)` — **même pattern que
        `CMUX_SURFACE_ID`, déjà implémenté**
      - localiser `wsh` (`~/Library/Application Support/waveterm/bin/wsh`)
      - **`wsh` refuse de tourner hors d'un block Wave** (`WAVETERM_JWT not
        found`). On lui réinjecte le JWT lu dans l'environnement de la session.
        Vérifié : l'agent en hérite bien.
- [x] Tests : extraction des variables Wave depuis un bloc d'environnement
      synthétique, y compris l'absence de JWT.

## M2 — Sauter dans un block Wave

**Contrainte mesurée sur la machine, à ne pas contourner par du bruit :**

| commande | portée réelle |
|---|---|
| `wsh focusblock -b <id>` | onglet courant **seulement** — sinon `Block not found in tab` |
| `wsh badge -b <id>` | **fonctionne entre onglets et entre workspaces** |
| `wsh getmeta -b <id>` | idem, toutes portées |
| `wave://` | n'existe pas — pas de `CFBundleURLTypes` dans Wave.app |

Donc « sauter sur la session » en Wave, c'est :

- [x] toujours : raise de l'app Wave (`SessionFocus.activateApp`, déjà là)
- [x] si le block est dans l'onglet courant : `wsh focusblock` le sélectionne
- [x] sinon : `wsh badge` marque le block, l'onglet s'allume dans la barre
      d'onglets, un clic suffit. Un badge, pas un no-op silencieux.
- [x] `TerminalTabFocus.selectTab` gagne un `case "dev.commandline.waveterm"`
- [ ] Piste pour plus tard, hors périmètre ici : Wave expose un RPC sur
      `wave.sock` dont `wsh` n'est qu'un client. Un `SetActiveTab` y existe
      probablement. L'app embarque déjà SwiftNIO pour le phone-link, donc un
      client socket n'est pas hors de portée — mais ce n'est pas un préalable,
      le badge marche aujourd'hui.

## M3 — Moniteur Copilot CLI

Copilot n'existe que comme fournisseur d'usage (`GitHubCopilotProvider`) — il
ne publie aucune activité, donc aucune de ses sessions n'apparaît nulle part.

- [x] `Sources/Sessions/CopilotActivityMonitor.swift`, conforme à
      `AgentActivityMonitor`, sur le modèle de `CodexActivityMonitor` :
      - `~/.copilot/open-sessions-state.json` → `working: true/false` +
        `refreshedAt` par session
      - `~/.copilot/session-state/<id>/workspace.yaml` → `cwd`, `branch`, `name`
        (un vrai titre de session, à afficher)
      - `~/.copilot/session-state/<id>/events.jsonl` → l'état fin, dont
        l'attente d'une approbation d'outil = `waiting`
      - `~/.copilot/logs/process-<ms>-<pid>.log` → le pid, indispensable pour
        remonter la fenêtre
      - `ProcessLiveness.isAlive` filtre les sessions mortes, comme ailleurs
- [x] **Inconnue à lever en premier** : la correspondance session ↔ pid. Ni
      `workspace.yaml` ni `open-sessions-state.json` ne portent le pid ; il
      faudra le déduire du nom du fichier de log corrélé au `startTime`, ou le
      trouver dans `events.jsonl`. À vérifier avant d'écrire le moniteur.
- [x] Tests sur des fixtures — pas sur `~/.copilot` réel.

## M4 — Le panneau

- [x] `Sources/Switcher/SessionFleetModel.swift` — agrège les sessions de tous
      les moniteurs en lignes groupées par `SessionLocation`, triées : `waiting`
      d'abord, puis `busy`, puis le reste par ancienneté. Pur, testable.
- [x] `Sources/Switcher/SessionFleetView.swift` — SwiftUI, sur `Palette` /
      `Typography` existants, pas de nouvelle échelle de design.
- [x] `Sources/Switcher/SessionFleetWindowController.swift` — `NSPanel` HUD
      centré, qui devient key (≠ `NotchPanel` qui est non-activating par
      construction), ↑/↓ pour naviguer, ↩ pour sauter, ⎋ pour fermer.
- [x] `Sources/App/GlobalHotKey.swift` — Carbon `RegisterEventHotKey`, choisi
      sur `NSEvent.addGlobalMonitorForEvents` précisément parce qu'il ne
      demande **aucune permission Accessibilité**.
- [ ] ~~Le clic sur le notch ouvre aussi le panneau.~~ Abandonné : le clic sur
      le notch est déjà routé par `NotchPanel.mouseDown` →
      `NotchWindowController.handleClick` vers la pastille de réglages et le
      saut de session, et y greffer une troisième cible se jouerait sur la
      géométrie au pixel près. Le panneau s'ouvre par ⌥⌘S et par l'entrée
      « Active sessions… » de la barre de menus.
- [x] Tests : groupement, tri, navigation de sélection.

## M5 — Remontée automatique

- [x] `announceCompletions` : sur `reason == .blocked` et si le réglage est
      activé, `SessionFocus.focus(pid:)`. Uniquement `.blocked` — remonter une
      fenêtre à chaque fin de tour volerait le focus toute la journée.
- [x] En parallèle, badge Wave sur le block concerné (`wsh badge --pid <pid>`
      s'auto-efface à la mort du process — exactement ce qu'on veut).
- [x] La session bloquée remonte en tête du panneau avec son marqueur.
- [x] Réglages dans `Preferences` + `SettingsView` : raccourci, remontée auto
      (**désactivée par défaut**, elle vole le focus), badges Wave.
- [x] Toute copie visible passe par `L10n.t("source anglaise")`, anglais source,
      traductions optionnelles dans `Sources/Localizable.xcstrings`.

## Vérification

### Fait ici, sans Xcode

- [x] **Typecheck du module entier** : `./tasks/typecheck-clt/run.sh` —
      194 fichiers, 0 erreur. C'est ce qui a attrapé l'erreur réelle de câblage
      (`statusItem` hors de portée) qu'un `swiftc -parse` fichier par fichier
      laissait passer. À relancer après chaque modif.
- [x] Contraintes Wave mesurées sur la machine : portée de `focusblock`
      (onglet courant) contre `badge`/`getmeta` (tous onglets, tous
      workspaces), et `wsh` n'a besoin que de `WAVETERM_JWT` +
      `WAVETERM_BLOCKID` réinjectés.
- [x] Formats Copilot lus sur de vraies sessions : pid dans le nom du log,
      session dans son head, `client_name` distinguant `github/cli` (234) de
      `github/autopilot` (2), événements appariés dans `events.jsonl`.
- [x] `core.autocrlf` mis à `false` **pour ce dépôt seulement** — le global
      reste à `true`. Sans ça le premier commit réécrit les fins de ligne de
      tout le dépôt.

Ce que le harnais ne couvre pas : l'exécution des tests, le catalogue
d'assets, l'app elle-même, et les 5 fichiers exclus (Sparkle, SwiftNIO, zstd).

### Sur le poste perso, qui a Xcode et le compte développeur

Dans cet ordre :

1. `brew install xcodegen`
2. `./tasks/typecheck-clt/run.sh` — doit toujours donner 0 erreur ; si non,
   c'est une différence de toolchain, à regarder avant le reste.
3. `make test-ci` — **et pas `make test`**, voir le piège ci-dessous.
4. `make build`, puis `make run`.

**Le piège de signature, qui se déclenche justement parce que le compte dev
existe.** Le Makefile ne pose ses propres réglages de signature *que si* aucun
certificat « Developer ID Application » n'est dans le trousseau :

```make
ifeq (,$(HAS_DEVELOPER_ID))
  ... DEV_SIGN ...
endif
```

Avec un compte développeur, ce certificat est présent, `DEV_SIGN` reste vide,
et le build retombe sur `project.yml` : `CODE_SIGN_IDENTITY: "Developer ID
Application"` avec `DEVELOPMENT_TEAM: 6WFPL8B9FB` — **le Team ID de vinzdg**,
pas le tien. Xcode cherchera un certificat Developer ID appartenant à une
équipe qui n'est pas la tienne et refusera.

Trois sorties, par ordre de propreté :

- `make test-ci` force `CODE_SIGNING_ALLOWED=NO` : aucune identité requise,
  c'est la bonne commande pour faire tourner les tests.
- Pour un build lançable : `make build DEV_SIGN='CODE_SIGN_IDENTITY="Apple
  Development" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="<ton Team ID>"'`.
- Sur un fork que tu gardes : remplacer `DEVELOPMENT_TEAM` dans `project.yml`
  par le tien. Le commentaire du fichier explique pourquoi une identité
  *stable* compte — l'ACL du trousseau retient quel binaire signé a été
  autorisé à lire le token OAuth de Claude Code, et une identité ad-hoc qui
  change à chaque build ramène la boîte de dialogue à chaque `make run`.
  `Scripts/fix-keychain-partitions.sh` est là pour ça.

### À regarder à l'œil une fois que ça tourne

- [ ] Le badge Wave : `wsh badge` accepte n'importe quel nom d'icône et
      n'affiche rien pour un nom inconnu. `bell` et `circle-arrow-right` sont
      posés sans avoir été vus à l'écran.
- [ ] Une session Claude bloquée dans un *autre* workspace Wave : en tête du
      panneau, et le saut doit au minimum allumer son onglet.
- [ ] Une session Copilot CLI réelle — aucune n'était ouverte pendant
      l'écriture, donc le moniteur n'a jamais tourné contre une session
      vivante, seulement contre les fichiers laissés par les précédentes.
- [ ] Le raccourci ⌥⌘S : s'il est déjà pris par une autre app,
      `registerHotKey` renvoie false et le log le dit — le réglage permet de
      le couper et d'ouvrir le panneau par la barre de menus.

---

# Hub — feuille de route

Codenotch devient le hub du poste : les agents, le son, la musique, et ce qu'on
lance dans chaque projet.

## H1 — « À faire » dans l'encoche — fait et vu à l'écran le 2026-09-27

- [x] `ClaudeTranscript.prompt(inTail:)` : titre (`custom-title` sinon `ai-title`),
      appel d'outil non résolu → texte lisible, et début de la dernière réponse
- [x] `AgentSession.topic` / `lastReply`, remplis pour les sessions au repos
- [x] `SessionPrompt.open` : questions (bloquées) + tours terminés vus pendant
      que Codenotch tournait, du plus récent au plus ancien
- [x] Cloche = dernière case de l'encoche (`NotchViewModel.inboxIndex`), avec le
      compte ; survol/clic → `InboxCard` (4 lignes max, → y aller, ✕ effacer)
- [x] Une arrivée ouvre l'encoche sur la liste le temps d'un peek
- [x] « Y aller » : Wave au premier plan via `NSWorkspace.openApplication` (un
      `activate()` est refusé depuis macOS 14 : l'encoche n'est jamais active),
      puis ⌘N dans Wave (onglet lu dans `waveterm.db`, caractère injecté pour
      l'AZERTY), puis `wsh focusblock` avec `WAVETERM_TABID` — autorisation
      Accessibilité requise
- [ ] Au-delà du 9ᵉ onglet : badge seulement
- [ ] Plusieurs fenêtres / workspaces Wave : non testé (un seul ouvert ici)

## H2 — Sortie son — fait le 2026-09-27

- [x] Case 🔊 (icône de la sortie, volume en anneau) ; carte : sorties, curseur
- [x] Core Audio direct (`AudioOutputs`), suit Centre de contrôle et touches volume
- [ ] À l'œil : le curseur répond-il au glisser dans le panneau non activant ?

## H3 — Lecture en cours — étape A faite le 2026-09-27

- [x] Spotify (AppleScript + notification `PlaybackStateChanged`)
- [x] YouTube dans Chrome (titre de l'onglet ; lecture/pause/suivant en JS —
      exige « Autoriser JavaScript depuis les Apple Events » dans Chrome)
- [x] `NSAppleEventsUsageDescription` ajouté (project.yml)
- [ ] B — Teams en appel : bouton micro, musique en pause pendant l'appel
- [ ] C — Volume de Teams seul (process tap Core Audio, macOS 14.2+)
- [ ] Teams n'est pas installé en app ici : web dans Chrome ? à confirmer

## H4 — Lanceur NX par projet

- [ ] Pour chaque workspace/projet Wave, lister les cibles NX (`serve`, `test`,
      `component-test`, …) comme le plugin NX de l'IDE
- [ ] Les lancer dans le bon terminal Wave (`wsh` sait créer un block et y
      lancer une commande — à vérifier)
