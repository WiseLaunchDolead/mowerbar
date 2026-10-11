# MowerBar

**Unofficial macOS client for Worx Landroid robotic mowers.** State, battery, alerts, activity log and the basic commands, in a native SwiftUI window and in the menu bar.

> MowerBar is an independent open-source project. It is not affiliated with, endorsed by or supported by Worx or Positec. "Worx" and "Landroid" are trademarks of their owners and are only used here to describe compatibility. It talks to the same cloud service as the official app; that service can change at any time.

[Version française plus bas](#français).

## Features

- **Dashboard**: state, error, battery and how fresh the data is, with a single highlighted action.
- **Commands**: start, pause and return to base (blades stopped). Each one asks for confirmation and is only offered when the mower's state is less than 5 minutes old.
- **Menu bar panel**: the same state and commands with the window closed. The icon gets a warning badge when the mower reports an error, and can be hidden.
- **Notifications**: new errors, errors cleared, activity changes and battery under 20 %.
- **Activity log**, grouped by day.
- **Schedule** (wired models): the week as a calendar. Click a slot to change its hours or edge cutting, or add and delete slots (up to two a day).
- **Fewer boundary exits** (wired models): wheel torque and delay after rain.
- Schedule and settings changes are configuration only; they never move the mower.
- **Experimental resume after an error** (off by default, see below).
- English and French interface, following the Mac's language.

### Supported mowers

| Model family | Read state and log | Commands and settings |
|---|---|---|
| Wired Landroid (cloud protocol 0) | Yes | Yes |
| Landroid Vision (protocol 1) | Yes | Not yet |

Remote driving (joystick) is not available: the official app only does it over Bluetooth, nearby, on models that declare it.

## Install

**Requirements**: macOS 14 or later, a Worx account with a mower already set up in the official app.

### From a release

1. Download `MowerBar.zip` from the [latest release](../../releases/latest) and move `MowerBar.app` to Applications.
2. The app is not notarized by Apple. The first time, open it, then go to **System Settings → Privacy & Security** and click **Open Anyway**.
3. Click **Connect my Worx account** and sign in on the Worx page that opens inside the app.

### From source

Requires Xcode 16 or later (Swift 6.1 tools). No third-party dependencies.

```sh
git clone https://github.com/WiseLaunchDolead/mowerbar.git
cd mowerbar
swift test
./tools/install-app.sh   # builds dist/MowerBar.app, installs it in ~/Applications and opens it
```

Set `BUNDLE_ID=com.example.mowerbar` before `build-app.sh` or `install-app.sh` to build under your own identifier.

## Your data

- **Each user signs in with their own Worx account.** MowerBar uses the same OAuth sign-in (PKCE) as the official app, in a private web view that keeps no cookies.
- **The session (access and refresh tokens) is stored only in your macOS Keychain**, under the app's bundle identifier, readable on this Mac only. Nothing is written to disk in clear, and nothing is sent anywhere other than Worx servers (`id.worx.com`, `api.worxlandroid.com` and the mower's MQTT endpoint).
- No analytics, no third-party server. **Sign out** in Settings deletes the Keychain item.

## Experimental resume after an error

For wired mowers, Worx asks you to press Start on the mower itself after errors such as *outside the mowing area*, *trapped* or *lifted*. The official app sends start or return to base **together with the current state and error** when the mower declares an error resumable remotely; wired mowers never declare it.

The **Experimental** option in Settings offers a *Try: return to base* / *Try: start mowing* button when the mower reports an error. It sends that same format. Whether the firmware accepts it has **not been validated**. The mower may move or start its blades, so only try with someone next to it and the area clear. The answer one minute later is written to the technical log. Reports are welcome in the issues.

## Limits

- MowerBar must stay open and the Mac awake and online for alerts. There is no server sending push notifications.
- A command acknowledged by the cloud is not proof that the mower executed it. MowerBar waits for the mower's answer and says so when it does not come.
- The protocol notes are in [docs/PROTOCOL.md](docs/PROTOCOL.md), and the manual test checklist in [docs/TESTING.md](docs/TESTING.md).

## Development

```sh
swift build                      # debug build
swift test                       # protocol and safety rules
./tools/check-localization.sh    # every user-facing text has a French translation
./tools/build-app.sh             # dist/MowerBar.app, ad hoc signed
```

- `Sources/MowerBarCore` contains the protocol: models, command and setting envelopes, MQTT framing, and the rules deciding when a command is allowed.
- `Sources/MowerBar` contains the app: SwiftUI views, cloud and MQTT clients, Keychain storage, and the icon drawn in code (`MowerGlyph.swift`).

Texts are written in English in the code. French translations live in `Resources/fr.lproj/Localizable.strings`.

`--check-readonly` runs an integration check against your own account. It reads the account, subscribes to events and asks for one status update, and it never sends a movement. Quit the app first.

```sh
~/Applications/MowerBar.app/Contents/MacOS/MowerBar --check-readonly
```

## License

[MIT](LICENSE)

---

## Français

**Client macOS non officiel pour les tondeuses robots Worx Landroid.** État, batterie, alertes, journal d'activité et commandes de base, dans une fenêtre et dans la barre des menus. Projet indépendant, sans lien avec Worx ni Positec.

**Installation** : télécharge `MowerBar.zip` depuis la [dernière version](../../releases/latest) et place l'app dans Applications. Ouvre-la une première fois, puis valide **Ouvrir quand même** dans **Réglages Système → Confidentialité et sécurité** (l'app n'est pas notarisée par Apple). Clique enfin sur **Connecter mon compte Worx**.

**Tes données** : chacun se connecte avec son propre compte Worx. La session reste uniquement dans le Trousseau macOS de ton Mac. Aucune donnée n'est envoyée ailleurs qu'aux serveurs Worx.

**Fonctions** :
- état, batterie et erreurs ;
- démarrer, pause et retour à la base, avec confirmation ;
- panneau dans la barre des menus ;
- notifications ;
- journal d'activité ;
- planning de la semaine en vue calendrier, avec modification, ajout et suppression des plages (horaires, coupe de bordure) ;
- réglages anti-sorties de zone pour les modèles à fil : couple des roues, délai après la pluie ;
- reprise expérimentale après une erreur, désactivée par défaut, à tester seulement avec quelqu'un à côté du robot.

L'interface est en français si ton Mac est en français.
