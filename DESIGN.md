# Tamio — Design Document

> Status: Draft v0.1 · 2026-10-17
> Platform for v1: **macOS 14 Sonoma or later only** (iOS is deferred)
> Distribution: signed + notarized DMG on GitHub Releases, auto-update via Sparkle
> Bundle ID: **`sb.moe.tamio`**

Tamio is a native SSH client for macOS in the spirit of [Termius](https://termius.com).
It is built on the open-source **Rayon** codebase, which already has a good
terminal, sidebar, settings and management pages. Tamio keeps most of that and
reworks three areas: the **New Server dialog**, **live metrics on saved
servers**, and a **Termius-style dual-pane SFTP**.

---

## 1. References

### 1.1 Projects

| What | URL | Local path |
|---|---|---|
| Rayon (our fork, the base for Tamio) | https://github.com/missuo/Rayon | `~/Projects/Rayon` |
| catussh (Rayon's upstream; the README still calls the app "catussh") | https://github.com/mizorewww/catussh | — |
| Original Rayon by Lakr Aream | https://github.com/Lakr233/Rayon | — |
| libghostty-spm (terminal engine, SwiftPM) | https://github.com/Lakr233/libghostty-spm | pulled by SwiftPM |
| Ghostty | https://ghostty.org | — |
| Termius (UX reference) | https://termius.com | — |
| ServerCat (UX reference for status cards, closed source, bundle `tech.baye.servercat`) | — | `/Applications/ServerCat.app` |
| Sparkle 2 (auto-update) | https://sparkle-project.org · https://github.com/sparkle-project/Sparkle | Fetched into `External/Sparkle` by `Workflow/Scripts/sparkle.sh`, linked into the app |
| Tamio (this project) | — | `~/Projects/tamio` |

Rayon state at the time of writing: `02b313a chore: version 2.5.2 (49)`, MIT license.

### 1.2 UX reference material

- Termius SFTP screenshot (from the product owner): dual pane, left = **Local**,
  right = empty "Connect to host" state with a **Select host** button. Details in §6.
- ServerCat inspector screenshots (from the product owner): the Overview tab
  (CPU / memory / network + TCP / per-interface / per-mount boxes) and the
  Containers tab. Details in §5.7.
- ServerCat "Status" screenshot (from the product owner): per-server cards with Load,
  Mem, net ↑/↓ per second and disk Read/Write per second gauges that rotate. Details in §5.2.
- Termius "New Host" panel: Address → General (Label, Group, Tags) → SSH port →
  Credentials (Username, Password / Key / Identity). Details in §4.

### 1.3 Rayon source map (paths relative to `~/Projects/Rayon`; after M0 the `catussh` / `Catussh` parts become `Tamio`, see §3.2)

| Area | Path | Notes |
|---|---|---|
| Workspace | `App.xcworkspace` | Open this, scheme **catussh** |
| macOS app target (XcodeGen) | `Application/catussh/project.yml` | Native macOS app (SwiftUI on AppKit); Mac Catalyst until 0.2.0 |
| Generated project | `Application/catussh/catussh.xcodeproj` | Regenerate with `xcodegen generate` |
| Info.plist / entitlements | `Application/catussh/macOS/Info.plist`, `macOS/macOS.entitlements` | Rayon is sandboxed; Tamio drops the sandbox (§3.4) |
| App entry | `Application/catussh/Application/CatusshApp.swift` | |
| AppKit | `Application/Tamio/Mac/*` | Window material, status items, dialogs, legacy keychain, Sparkle |
| Navigation | `Application/catussh/Interface/Shell/AppRouter.swift` | `Route` enum, session owners |
| Sidebar | `Application/catussh/Interface/Shell/SidebarView.swift` | Home · Manage (Servers, Identities, Snippets, Port Forward) · Sessions · Settings |
| Page chrome | `Application/catussh/Interface/Shell/PageScaffold.swift`, `MainView.swift` | |
| Home + Quick Connect + server tiles | `Application/catussh/Interface/Home/HomeView.swift` | `QuickConnectHero`, `ServerTile`, `NewServerTile` |
| Servers table | `Application/catussh/Interface/Servers/ServersView.swift` | |
| **New/Edit Server sheet** | `Application/catussh/Interface/Servers/ServerEditorSheet.swift` | Rewritten in §4 |
| Server actions, live reader | `Application/catussh/Interface/Servers/ServerActions.swift` | `ServerLiveReader`, `ServerToolSwitcher` |
| **SFTP page** | `Application/catussh/Interface/FileTransfer/FileTransferPage.swift`, `FileTable.swift` | Single remote pane today; replaced in §6 |
| Monitor page | `Application/catussh/Interface/Monitor/MonitorPage.swift` | |
| Menu-bar monitor | `Application/catussh/Interface/Menubar/*` | |
| Identities / Snippets / Port Forward / Settings | `Application/catussh/Interface/{Identities,Snippets,PortForward,Settings}` | **Kept as-is** |
| Terminal | `Application/catussh/Interface/Terminal/*`, `Foundation/CatusshTerminal` | Ghostty; `CONFIGURATION.md` documents coverage |
| Data model + store | `Foundation/CatusshModule/Sources/CatusshModule/{Machine,Identity,Snippet,PortForward,Store,Sync}` | `RDMachine`, `RDIdentity`, `CatusshStore` |
| SFTP backend | `Foundation/CatusshModule/Sources/CatusshModule/FileTransfer/*` | `FileTransferContext` (serial, one transfer at a time) |
| SSH (libssh2 wrapper) | `External/NSRemoteShell` | Obj-C, `CSSH.xcframework` |
| iCloud sync (passphrase E2EE, KVS) | `Foundation/CatusshModule/Sources/CatusshModule/Sync/*` | `SyncCipher` (PBKDF2 + AES-GCM), `SyncDocument` (per-item LWW, tombstones), `SyncTransport` (one blob in `NSUbiquitousKeyValueStore`, 1 MB cap). Replaced in §7 |
| Local secret storage | `Foundation/CatusshModule/Sources/CatusshModule/Utils/AES.swift`, `Foundation/Keychain` | Store encrypted at rest with a master key kept in the keychain |
| Metrics collection | `Foundation/MachineStatus` | Linux `/proc` + Darwin parsers, no agent |
| Metrics UI + sessions | `Foundation/MachineStatusView` | `MonitorSession`, `MonitorCenter`, cards |
| Design system | `Foundation/CatusshDesign` | `RX.*` tokens, `.rx` styles |
| Build scripts | `Workflow/Scripts/build-macos.sh`, `install-macos.sh`, `release.sh` | |
| CI | `.github/workflows/release.yml` | |
| iOS app (deferred) | `Application/mCatussh`, `Application/mCatusshUITests` | Not built for v1 |

---

## 2. Goals and non-goals

### Goals (v1, macOS)

1. A Termius-style **New Server** panel (§4).
2. **Live CPU / memory / disk** on every saved server, without opening Monitor (§5).
3. A **dual-pane SFTP** with drag and drop between panes and a visible transfer
   queue with progress (§6).
4. **End-to-end encrypted iCloud sync** of identities (keys and passwords),
   snippets and SSH hosts across the user's devices, automatic, and ready for a
   later iOS client (§7).
5. Rebrand to Tamio with bundle ID `sb.moe.tamio` (§3).
6. An **MCP server** so AI agents can list every host's connection details and,
   with the user's approval, run commands across the fleet. Secrets never leave
   Tamio (§8).
7. Keep everything else from Rayon that already works: terminal, sidebar,
   Identities, Snippets, Port Forward, Settings, menu-bar monitor.

### Non-goals (v1)

- iOS / iPadOS app. The code stays in the tree but is not built or shipped.
- Termius-style top tab bar (Vaults / SFTP tabs). Tamio keeps Rayon's sidebar.
- Cloud accounts, team vaults, sharing.
- New terminal features beyond what Rayon has.

---

## 3. Project setup and rebranding

### 3.1 Repository strategy

- `~/Projects/tamio` becomes the Tamio repo. It starts as a copy of Rayon at
  `02b313a`, with `missuo/Rayon` added as the `upstream` remote so Rayon fixes can
  be merged later.
- Keep `LICENSE` (MIT) and `Resources/LICENSE` (third-party), and credit Rayon /
  catussh / Lakr Aream in About and the README.
- **Internal names become Tamio too** (decided, Q5). In M0, everything named
  `catussh` / `Catussh` / `CATUSSH` is renamed: 196 files and about 1,000
  occurrences in Rayon at `02b313a`. It is done as one mechanical commit (the
  rename map is in §3.2) before any feature work, so later diffs stay readable.
  The `RD*` model prefix (`RDMachine`, `RDIdentity`…) and the `RX` design tokens
  don't contain the old name and stay as they are, to keep the rename small.
- The trade-off: Rayon fixes can no longer be merged directly. They are ported by
  hand (`git format-patch` from `upstream`, then the same rename map applied with
  a small script, `Workflow/Scripts/port-upstream.sh`, written in M0).

### 3.2 Identifiers

| Item | Rayon | Tamio |
|---|---|---|
| App bundle ID (Release) | `me.mizorewww.rayon` | `sb.moe.tamio` |
| App bundle ID (Debug) | `me.mizorewww.rayon.debug` | `sb.moe.tamio.debug` |
| AppKit bridge bundle | `me.mizorewww.rayon.bridge` | `sb.moe.tamio.bridge` |
| Display name | `catussh` | `Tamio` |
| Product name / scheme | `catussh` | `Tamio` |
| UserDefaults keys (`me.mizorewww.rayon.*`) | e.g. `.appearance`, `.maxRecentRecordCount`, `.menubarMachines` | `sb.moe.tamio.*` |
| Dispatch queue labels | `me.mizorewww.*` | `sb.moe.tamio.*` |
| Copyright | Lakr Aream, mizorewww | add "© 2026 Tamio" while keeping the originals |
| About links | `github.com/mizorewww/catussh` | Tamio's repo; Rayon credited as upstream |
| App icon | `Resources/catussh.icon` | new `Resources/Tamio.icon` |

**Code rename map (M0):**

| Rayon | Tamio |
|---|---|
| `Foundation/CatusshModule` (+ `CatusshModuleTests`) | `Foundation/TamioModule` (+ `TamioModuleTests`) |
| `Foundation/CatusshTerminal` (+ `CatusshTerminalTests`, `CatusshConfigurationPreview`) | `Foundation/TamioTerminal` (+ `TamioTerminalTests`, `TamioConfigurationPreview`) |
| `Foundation/CatusshDesign` | `Foundation/TamioDesign` |
| `Foundation/CatusshEditor` (+ tests) | `Foundation/TamioEditor` (+ tests) |
| `Application/catussh` (target, scheme, `catussh.xcodeproj`) | `Application/Tamio` (target `Tamio`, scheme `Tamio`, `Tamio.xcodeproj`) |
| `Application/mCatussh`, `mCatusshUITests` (deferred iOS) | `Application/TamioMobile`, `TamioMobileUITests` |
| `CatusshStore`, `CatusshApp`, `CatusshUtil`, `CatusshCommands`, `CatusshTerminalView` / `…Configuration` / `…Session`, `catusshKeys` | `TamioStore`, `TamioApp`, `TamioUtil`, `TamioCommands`, `TamioTerminalView` / … / …, `tamioKeys` |
| `NSRemoteShell+catussh.swift` | `NSRemoteShell+Tamio.swift` |
| Env vars `CATUSSH_KERNEL` (remote shell probe), `CATUSSH_PREVIEW`, `CATUSSH_BENCH`, `CATUSSH_SYNC`, `CATUSSH_SSH` | `TAMIO_KERNEL`, `TAMIO_PREVIEW`, `TAMIO_BENCH`, `TAMIO_SYNC`, `TAMIO_SSH` |
| `Resources/catussh.icon`, `ASSETCATALOG_COMPILER_APPICON_NAME: catussh` | `Resources/Tamio.icon`, `Tamio` |
| `Foundation/CatusshTerminal/CONFIGURATION.md` references | updated paths |

Untouched: the `External/NSRemoteShell` and `External/CodeMirrorUI` names, and
the third-party packages (`MachineStatus`, `MachineStatusView`, `Keychain`,
`SymbolPicker`, `SPIndicator`, `XMLCoder`, `PropertyWrapper`, `StripedTextTable`),
since they don't carry the old name. After the rename, `xcodegen generate`, then
build and run `swift test` for every package.

Checklist command for leftovers (must print nothing):

```sh
grep -rnI -i "catussh\|mizorewww\|me\.mizore" --exclude-dir=.git . \
  | grep -v -e Copyright -e "Resources/LICENSE" -e "README.*upstream"
find . -iname '*catussh*' -not -path './.git/*'
```

Also check the keychain service names (`Mac/Mac.swift`,
`Foundation/Keychain`) and any iCloud key-value container in `Sync/`. These are
tied to the bundle ID, so Tamio starts with an empty store and does not read
Rayon's data. Importing from Rayon is out of scope for v1.

### 3.3 Build

- Native macOS (AppKit) since 0.2.0; Mac Catalyst before that. Universal arm64 + x86_64.
- Minimum macOS **14.0** (Sonoma), needed for `CKSyncEngine` (§7.5). Xcode 26+ / Swift 6.2.
  `project.yml` `deploymentTarget.macOS` and `MACOSX_DEPLOYMENT_TARGET` change from 13.0.
- `project.yml` stays the source of truth; run `xcodegen generate` after edits.
- Drop the iOS scheme from the workspace build for now. Leave `Application/TamioMobile` (was `mCatussh`)
  in the tree and out of the build.
- `Workflow/Scripts/build-macos.sh` / `install-macos.sh` change to the new scheme
  and product names.
- Signing (decided 2026-10-17): **local builds are ad hoc** (`build-macos.sh`
  never touches the keychain). Developer ID signing and notarization happen
  **only in GitHub Actions** when a `v*` tag is pushed (`.github/workflows/release.yml`
  → `release.sh mac`, on the hosted `macos-26` runner), with the certificate and
  notary credentials in repository secrets (`DEVELOPER_ID_P12`,
  `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_APPLE_ID`, `NOTARY_PASSWORD`). Team ID
  `NCFNX3LJ83` (MOE AI LLC) is set in `project.yml`.

### 3.4 Distribution and updates

- **Not on the Mac App Store.** Releases are a signed, notarized, stapled DMG
  attached to GitHub Releases. A Homebrew cask can follow later.
- **App Sandbox is removed** (`com.apple.security.app-sandbox` dropped from
  `macOS.entitlements`). It is not required outside the App Store. This lets the
  Local SFTP pane browse the whole disk without folder-access prompts, and allows
  reading `~/.ssh/config`, `~/.ssh/known_hosts` and the SSH agent later. Hardened
  Runtime stays on (notarization needs it).
- iCloud (CloudKit + push + iCloud Keychain) works for Developer ID apps, but
  needs a **Developer ID provisioning profile** for `sb.moe.tamio` with the iCloud
  container and Push Notifications enabled, embedded in the app.
  `Workflow/Scripts/provisioning-profile.sh` already finds and embeds a profile;
  point it at the Developer ID one.
- **Sparkle 2** for updates:
  - Sparkle is linked into the app and driven by `Application/Tamio/Mac/MacUpdates.swift`
    ("Check for Updates…" in the app menu and in Settings → About, plus the
    automatic check and download switches). Until 0.2.0, when the app was Mac
    Catalyst, it lived in a separate AppKit bundle.
  - EdDSA (ed25519) signed updates. The public key goes in `Info.plist`
    (`SUPublicEDKey`), and the private key stays in the release machine's keychain
    / a CI secret (`release-secrets.sh`).
  - `SUFeedURL` = an `appcast.xml` published with each GitHub Release (for example
    `https://github.com/<owner>/tamio/releases/latest/download/appcast.xml`),
    generated by Sparkle's `generate_appcast` in `release.sh`.
  - Sparkle's XPC installer services stay off (only needed for sandboxed apps).

---

## 4. New Server panel (Termius-style)

> **Revised 2026-10-17 (after review in the running app).** Where this section
> and the notes below differ, the notes win:
> - New / Edit Server is a **centered dialog** over the dimmed window (not a side
>   panel). Esc or a click outside closes it, asking first when there are changes.
> - **The username belongs to the server**, under SSH with the port, and is `root`
>   when left empty. **An identity is only a credential**, a named SSH key (or a
>   password identity kept from before), never tied to a user, so one key works
>   as `root` on one host and `debian` on another.
> - Credentials are **Password** (kept with this server only, a private identity
>   never listed in Identities), **SSH key**: choose one from Identities or
>   **New Key…** to paste, load or **generate an Ed25519** key, which is saved to
>   Identities, or **None**: no password or key, for a server that trusts the
>   connection itself (Tailscale SSH), signed in with the protocol's `none`
>   request. There is no "try automatic identities" choice any more.
> - A private key is **never shown again** once it is in: the field becomes
>   "•••• ED25519 private key" with only **Replace…**. The public key stays
>   visible with Copy.
> - Labels that name a country (`JP Tokyo`, `us-sjc-1`, `KR ICN ORACLE`) show its
>   **flag** on cards, the Servers table and the sidebar.

### 4.1 What changes

Today `ServerEditorSheet` is a 520-pt centered sheet with Name, Address + Port,
Identity (picker) + Group, SFTP start folder and Comment. The username and the
password or key can only come from a separately created Identity.

Tamio replaces it with a Termius-style panel where everything needed to connect
is entered in one place.

**No combined `user@host:22` field.** Address, port and username are separate
fields. The `user@host:22` Quick Connect bar on Home (`QuickConnectHero`) is also
removed (confirmed, Q1). Home opens straight onto the server cards.

### 4.2 Presentation

- Slides in as a **trailing inspector panel** (about 380 pt wide, full window
  height), like Termius, instead of a modal sheet. The server grid stays visible
  and usable behind it.
- The same panel handles **New** and **Edit**. Edit opens from a tile's context
  menu, from the Servers table, or with ⌘I on a selected server.
- ⇧⌘N opens it (unchanged). Esc closes it. Unsaved changes ask before discarding.

### 4.3 Layout (top to bottom)

```
┌───────────────────────────────────────┐
│ New Server                        ✕   │
├───────────────────────────────────────┤
│ [🖥]  IP or hostname                   │  ← Address, large, focused first
├───────────────────────────────────────┤
│ General                               │
│   Label          prod-web-01          │  ← defaults to address
│   Group          Production      ▾    │  ← existing groups + new
│   Tags           +                    │  ← optional free labels, e.g. "prod", "tokyo" (Q3)
├───────────────────────────────────────┤
│ SSH on port [ 22 ]                    │
├───────────────────────────────────────┤
│ Credentials                           │
│   Username       root                 │
│   Password       ••••••••   👁        │
│   Key            None            ▾    │  ← imported keys / Import…
│   ─── or ───                          │
│   Identity       None            ▾    │  ← existing RDIdentity
├───────────────────────────────────────┤
│ Advanced  ▸                           │  ← collapsed
│   SFTP start folder   /               │
│   Startup snippet     None       ▾    │
│   Comment                             │
│   Last banner (edit only, read-only)  │
├───────────────────────────────────────┤
│        [ Save ]   [ Connect ]         │
└───────────────────────────────────────┘
```

### 4.4 Behavior

- **Address** is the only required field. Port defaults to 22 and accepts 1–65535.
- **Credentials**: the user either types username + password/key inline, **or**
  picks an Identity. Choosing an Identity fills in and locks the inline fields,
  and shows its name with a "Detach" link. Leaving everything empty keeps Rayon's
  "Automatic" behavior (try identities marked for auto-auth).
- Inline credentials are stored as a **per-server private identity**: an
  `RDIdentity` flagged hidden that does not show in the Identities list. This
  reuses the existing auth path (`RDIdentity.callAuthenticationWith`), so the
  `RDMachine` schema does not change. "Save as Identity…" promotes it to a shared
  identity.
- **Connect** = save + test + open terminal. It reuses the flow in
  `ServerEditorSheet.createAndConnect`: the host-key prompt, the auth fallback,
  and banner capture.
- **Save** stores the server without connecting.
- Errors show inline under the relevant section (unreachable → Address; auth
  failed → Credentials) and are never only an alert.

### 4.5 Model impact

- **Identity of a server = its UUID.** `RDMachine.id` is a `UUID()` generated
  once, when the server is first created (already true in Rayon,
  `RDMachine.swift`). The name ("Label") is only a display name: it can be
  renamed freely, and duplicates are allowed. Everything else (sync records,
  metrics history, the traffic ledger, card order, flipped faces, the identity
  link) refers to the UUID, so a rename on one Mac shows up on the others as an
  update of the same server, never as a new one. The same holds for identities,
  snippets and port forwards (`RDIdentity.id`, `RDSnippet.id`, …).
- `RDMachine`: no breaking change. New optional fields go in `attachment`, as
  `fileTransferLoginPath` already does: `tags`, `startupSnippet`.
- `RDIdentity`: add `isPrivate: Bool` (decoded with default `false`).

---

## 5. Live server metrics on saved servers

> **Revised 2026-10-17 (after review in the running app).** Where this section
> and the notes below differ, the notes win:
> - Cards are **small (240–320 pt), with no rotation**: the name (and flag), the
>   OS logo with as much of "macOS 26.6.2 · up 25d 5h" as fits **whole** (never
>   an ellipsis; what does not fit is in the inspector), and three rings:
>   **CPU · MEM · DISK**. Terminal and ⋯ on the right.
> - Home has **no title row**: the toolbar holds search and New Server at the top
>   right, and the grid starts right under it. Once a server has a group, a
>   segmented switcher at the toolbar's leading end (All · each group · No
>   Group, drawn like Terminal · Files · Monitor) shows one group's cards; the
>   choice is kept across launches.
> - A click on a card opens the **inspector beside the grid, below the toolbar**,
>   never under it, so search and New Server keep their own row. Overview /
>   Processes / Containers as in §5.7; it gives up width before the cards do.
> - OS logos are the Simple Icons set (CC0) from missuo/herdrm
>   (`Resources/OSIcons`), plus a Windows mark, in the app's asset catalog.

### 5.1 Today

`ServerTile` only shows CPU and memory bars while a **Monitor session** is open for
that server (`ServerLiveReader` → `MonitorCenter`). Otherwise it shows "Last used"
and "Identity".

### 5.2 Reference: ServerCat status cards (observed 2026-10-17)

Reference app: **ServerCat** 26.10.1 (`/Applications/ServerCat.app`,
`tech.baye.servercat`, closed source, native Swift). It was studied by running it
and reading its accessibility tree, bundled strings and screenshots. It was not
decompiled, and none of its code is used.

```
┌───────────────────────────────────────────────────────────────┐
│ KR ICN ORACLE                                           [>_]  │
│   ( ◎ )          ( 40% )        12 K ↑/s       0 M Read/s     │
│                                  6 K ↓/s       0 M Write/s    │
│   Load            Mem                                         │
└───────────────────────────────────────────────────────────────┘
```

What it does:

- **Card**: the server name in bold caps, top left; a terminal button top right; a
  drag handle (⋮⋮) at the top left on hover, for reordering cards. Below that,
  four slots in a row: **Load · Mem · Net · Disk I/O**. The grid is 1–3 columns,
  depending on window width.
- **Load gauge**: three concentric rings (1 / 5 / 15 min), each filled with a
  green arc. Tooltips are "load average in 5/10/15 minutes".
- **Mem gauge**: a ring with % in the centre. Green = used, dark grey = cache /
  buffers, light grey = free.
- **Net slot**: `12 K ↑/s` / `6 K ↓/s`. A bold number with a small grey unit;
  the number is green when it isn't zero and grey at zero.
- **Disk slot**: `0 M Read/s` / `10 K Write/s`, styled the same way.
- **Faces flip on click, per slot**, and the choice is remembered:
  - Mem → **Swap** (a ring with a dot)
  - Net rate → **totals** `424 G Upload` / `14 G Download`
  - (Load and Disk didn't flip when tried)
  - In a minute of watching, there was **no automatic rotation**; the
    "now this, now that" effect comes from clicking.
- **Animation**: number changes roll with a per-digit blur (like
  `.contentTransition(.numericText())`). A face flip animates each letter
  separately along a curve, like a rolling drum ("Download" visibly bends while
  flipping).
- **A click anywhere else on the card** opens a right-hand **inspector** with
  three tabs (gauge / waveform / box icons):
  - Status: OS name ("Debian GNU/Linux 12 (bookworm)"), big CPU % with
    SYS / USER / IO WAIT / STEAL, a dot-matrix CPU history chart, and
    Cores / Idle / Uptime / Load at the bottom.
  - Processes: a `top`-style table (Process, CPU% ↓, Mem).
  - Containers.
- **Traffic totals**: these come from the server's own `/proc/net/dev` counters
  (the binary contains `date +%s%3N; cat /proc/net/dev`), so they mean
  "**since boot**". ServerCat has no traffic billing cycle: the only "billing"
  strings in it belong to its RevenueCat subscription.

Tamio follows this closely (the user wants this kind of result), restyled with
Tamio's design tokens, and adds CPU, disk usage and automatic rotation.

### 5.3 Tamio server card

```
┌────────────────────────────────────────────────────────────────────┐
│ ● PROD-WEB-01   Ubuntu 24.04 · up 41d               [>_] [📁] [⋯]  │
│                                                                    │
│   ⟨ LOAD ⟩         ⟨ CPU ⟩        ⟨ MEM ⟩        ⟨ NET ⟩    ⟨ DISK ⟩ │
│  ( 0.42 )        ( 23% )        ( 61% )      ↑ 1.2 MB/s   ( 48% )  │
│  1·5·15          4 cores        9.8/16 G     ↓ 340 KB/s   R 0 W 2M │
└────────────────────────────────────────────────────────────────────┘
```

Five slots: **Load, CPU, Memory, Network, Disk**. Each slot is a small gauge or a
number pair with a caption. Slots that have more than one "face" rotate (§5.4).

| Slot | Face A (default) | Face B | Face C |
|---|---|---|---|
| **Load** | Three concentric rings for 1 / 5 / 15 min, scaled to core count (like ServerCat) | `0.42 · 0.38 · 0.31` as numbers | — |
| **CPU** | CPU % ring | user / system / iowait split bar | per-core mini bars (≤ 16 cores) |
| **Memory** | Used % ring (used / cache / free segments, like ServerCat) | Swap % ring | `9.8 / 16 GB` |
| **Network** | Live speed `↑ 1.2 MB/s ↓ 340 KB/s` | **Traffic used** `424 G Upload / 14 G Download` (§5.6) | — |
| **Disk** | Root (or fullest) mount used % ring | I/O `R 0 B/s W 2.1 MB/s` | `48 / 100 GB` |

- Colors: green normal, amber ≥ 75 %, red ≥ 90 % (load: ratio to cores). Numbers
  follow the reference: a bold number with a small grey unit, green when it isn't
  zero and grey at zero.
- A drag handle on hover lets the user reorder cards; the order syncs (§7).
- Header: a status dot (live / connecting / offline), the name, the OS + uptime in
  grey, and quick buttons for Terminal, Files and a ⋯ menu (Monitor, Edit, Show in
  Menu Bar…). A click anywhere else on the card opens the terminal.
- States: **connecting** shows skeleton rings; **offline** dims the card and shows
  "Offline · retrying in 30 s"; **no auto-auth credentials** shows "Connect once to
  see live status".
- The grid adapts to the window: cards are about 420–520 pt wide and fill 1–3 columns.
- A click on the card body (not on a slot) opens the **server inspector** (§5.7).
  A double-click or the [>_] button opens the terminal.
  Below about 420 pt, Disk and Load collapse into a rotation with CPU and Memory.
- The Servers table (`ServersView`) gets compact columns: Load, CPU, Mem, Net ↑↓,
  Disk.

### 5.4 Face switching: click to flip, plus auto-rotation

ServerCat only flips on click. Tamio does both:

- **Click a slot** to flip it to its next face (ServerCat behavior). The chosen
  face is remembered per server and slot, and it syncs.
- **Auto-rotation** (the "now this, now that" the user asked for). It is on by
  default: slots with more than one face move to the next one every **5 s**,
  staggered by 0.6 s so the whole card never flips at once. A slot the user
  clicked holds its face for 30 s before rotating again. Settings → General →
  Server cards: Auto-rotate **On / Off**, interval 3 / 5 / 8 / 12 s.
- **Hover pauses** rotation on that card.
- **Animation** (matching the reference):
  - Value changes: `.contentTransition(.numericText())`, so digits roll with a blur.
  - Face flips: each character of the caption and value is animated separately,
    rotating about the X axis with a small stagger (a "drum roll"). It's built as a
    custom `Transition` over `Text` split into characters, about 0.45 s, spring.
  - Reduce Motion: a plain 0.2 s crossfade.
- One shared `TimelineView(.periodic)` drives every card, and it pauses when the
  window isn't visible.

### 5.5 Data layer: `MetricsPoller` (new, in `MachineStatusView` or a new `TamioMetrics` package)

- One lightweight SSH connection per server, separate from terminal and SFTP
  sessions. It reuses the `MachineStatus` collector and parsers
  (`ServerStatusInfo`, `ProcParsers`, `DarwinParsers`), so Linux and macOS hosts
  work with no agent.
- What Rayon's collector already reads in one compound command
  (`ServerStatusInfo.swift`): `/proc/stat` ×2 (CPU), `/proc/net/dev` ×2 (net rate),
  `/proc/meminfo`, `df -Pk`, `/proc/uptime`, `/proc/loadavg` (Darwin:
  `netstat -ibn`, `vm_stat`, `sysctl`).
- **Added for Tamio**:
  - Disk I/O: `/proc/diskstats` sampled twice (Linux), `iostat -d -c 2` (Darwin).
    Real block devices only (skip `loop*`, `ram*`, partitions when the whole disk
    is present).
  - Traffic totals: the cumulative byte counters already in `/proc/net/dev`, kept
    instead of discarded (§5.6).
  - `vnstat --json m 1` only if `command -v vnstat` succeeds (§5.6).
  - CPU core count (`nproc` / `sysctl -n hw.ncpu`) for the load scale.
- Interfaces: totals and rates exclude `lo`, `docker*`, `veth*`, `br-*`,
  `virbr*`, `tun*`/`wg*` (the last two can be included from the card menu).
- **Cadence**: every 3 s for cards on screen, every 30 s for the rest, and paused
  when the app is hidden or the Mac is in Low Power Mode. Settings → General:
  "Live server status: Off / Visible only / All servers".
- If a full Monitor session is open for the server, the poller reads from it
  instead of opening a second connection.
- Backoff on failure: 3 s → 30 s → 2 min → 5 min, with the offline state shown. A
  server that fails auth stops polling until it is edited or connected.
- Only servers whose credentials authenticate without user interaction are polled.
- At most 8 connections open at the same time while polling starts.
- Publishes `[RDMachine.ID: LiveMetrics]` on the main actor:

```swift
struct LiveMetrics: Equatable, Sendable {
    enum State: Equatable { case idle, connecting, live, offline(String), unauthenticated }
    var state: State
    var updatedAt: Date?

    var load: (one: Double, five: Double, fifteen: Double)?
    var cores: Int?
    var cpu: Double?                 // 0...1
    var cpuSplit: (user: Double, system: Double, iowait: Double)?
    var memory: (used: UInt64, total: UInt64)?
    var swap: (used: UInt64, total: UInt64)?
    var disk: (mount: String, used: UInt64, total: UInt64)?   // root or fullest
    var diskIO: (readPerSec: Double, writePerSec: Double)?
    var net: (upPerSec: Double, downPerSec: Double)?
    var traffic: Traffic?            // §5.6
    var uptime: TimeInterval?
    var os: String?                  // "Ubuntu 24.04"
    var cpuHistory: [Double]         // last ~60 samples
}
```

### 5.6 Traffic used ("used how many GB")

**Default: the same as ServerCat.** Totals are the server's own cumulative rx/tx
byte counters from `/proc/net/dev` (Darwin: `netstat -ibn`), summed over the
counted interfaces. They mean "since the server last booted", they cost nothing
extra, they need nothing on the server, and Tamio doesn't have to be running to
count them. Caption: `Upload` / `Download`, with the tooltip "Since boot (41 d)".

Optional, per server (Edit Server → Advanced → Traffic), off by default:

- **Billing cycle**: a reset day (1–31, or the last day) and optionally a quota
  (for example 1 TB, counting ↑ only / ↓ only / both). Tamio keeps a per-server
  ledger of counter deltas, which handles counter resets on reboot. The ledger only
  counts while some Tamio device is polling, so it is labelled "approximate". The
  face then reads `182 G / 1 T` with a ring. Ledger samples sync, so several Macs
  add up instead of counting twice (deduplicated by counter value).
- **vnstat**: if `vnstat` is installed on the server, "This month (vnstat)" can be
  chosen as the source instead. It is exact, and it survives reboots and Tamio not
  running.

### 5.7 Server inspector (right-hand panel)

Modelled on ServerCat's inspector (product owner's screenshots, 2026-10-17). It
is a trailing panel about 460 pt wide; the card grid reflows to the remaining
width. The header has the server name in bold caps, a "Toggle Panel" button, and
a segmented control with three icon tabs: **Overview** (gauge), **Processes**
(waveform), **Containers** (box). The selected card is highlighted, and the page
title changes to the server name. It closes with Esc or the toggle. Visual
language throughout: rounded grey "group" boxes on the panel background,
**small caps grey labels** above **bold values with small grey units**, colored
dots as legend keys, and small rings / pills as the gauges.

```
┌ KR ICN ORACLE                         [▣] (◉ ∿ ▢) ┐
│ Arch Linux ARM                                     │
│ ┌────────────────────────────────────────────────┐ │
│ │ 5 %   ▮SYS 3%  ▮USER 1%  ▮IO WAIT 0%  ▮STEAL 0% │ │  CPU
│ │ ▮▮▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯     │ │  history pills (newest left)
│ │ CORES 1   IDLE 94%   UPTIME 164 D   LOAD (◎)  │ │
│ └────────────────────────────────────────────────┘ │
│ ┌ FREE 734 M   ▮USED 2.3 G   ▮PAGE CACHE 2.7 G (40%)┐│  Memory
│ ┌ ↑/S 13 K/s  ↓/S 4 K/s     ↑ 595 G ▮ ↓ 571 G ▮ (◐)┐│  Network total
│ │ RETRANS 3%  ACTIVE 5.3 M  PASSIVE 4.8 M  FAILS 396.9 K││  TCP
│ │ ᯤ enp0s6                              10.0.0.16    ││  per interface
│ │ ↑/S 18 K/s  ↓/S 4 K/s     ↑ 595 G   ↓ 571 G   (◐) ││
│ │ › VIRTUAL INTERFACES                          2    ││  collapsed
│ └────────────────────────────────────────────────────┘│
│ ┌ /            EXT4   0M/98G  ▉ ┐                     │  one box per mount
│ │ /dev/root                     │                     │  vertical fill pill
│ ┌ /efi         VFAT  99M/100M ▉ ┐                    │
│ │ /dev/sda1                     │                     │
│ │     SPEED   BYTES  IOPS  WAIT │                     │  I/O table when
│ │ R   0 M/s   5.8 M   0     0   │                     │  the device has I/O
│ │ W   0 M/s   512 B   0     0   │                     │
└──────────────────────────────────────────────────────┘
```

**Overview tab**, top to bottom:

1. **OS line**: `PRETTY_NAME` from `/etc/os-release` (Darwin: `sw_vers`), grey.
2. **CPU box**: a big total % next to SYS / USER / IO WAIT / STEAL, each with a
   colored dot (red / green / purple / yellow). Below it, a row of **history
   pills**: one rounded pill per sample, colored by the dominant component and
   grey when idle, about 45 visible. Then CORES · IDLE · UPTIME (days) · LOAD
   (the triple-ring gauge with the caption "1,5,15m"). Clicking the box expands it
   into per-core rows.
3. **Memory box**: FREE · USED (green dot) · PAGE CACHE (grey dot) and a used %
   ring. Swap is shown as a second row only when swap exists.
4. **Network box**:
   - Totals row: ↑/S · ↓/S rates; ↑ total (orange dot) / ↓ total (green dot)
     (§5.6); a two-color ring showing the ↑/↓ share.
   - TCP row from `/proc/net/snmp`: RETRANS % (RetransSegs / OutSegs), ACTIVE
     (ActiveOpens), PASSIVE (PassiveOpens), FAILS (AttemptFails).
   - One block per physical interface: a Wi-Fi/ethernet glyph, the name in mono,
     the primary IPv4 on the right (`ip -o -4 addr`), then the same rate/total
     row and ring.
   - A **"› Virtual interfaces  N"** disclosure collapses `lo`, `docker*`,
     `veth*`, `br-*`, `virbr*`, `tun*`, `wg*`.
5. **One box per mounted filesystem** (pseudo filesystems like tmpfs, overlay,
   proc and squashfs are hidden; a "Show all" toggle is in the ⋯ menu):
   - Mount point (bold) / device (grey) on the left; FS type (caps) and
     `used/size` on the right; a **vertical fill pill** whose color follows the
     thresholds in §5.3.
   - When the backing block device has I/O, a small table: rows **R / W**,
     columns **SPEED · BYTES · IOPS · WAIT**, from two `/proc/diskstats` samples
     (sectors × 512, completed ops, ms spent / ops).
6. GPU box (only when `nvidia-smi` exists), reusing Rayon's `GraphicsInfo`.

**Processes tab**: a `top`-style table, Process · CPU% ↓ · Mem, sortable by any
column, refreshing every 3 s, from `ps -eo pid,pcpu,rss,args --sort=-pcpu | head -100`
(Darwin: `ps -Ao pid,%cpu,rss,command -r`). The process name is shown in mono, and
the full command line appears on hover. The row menu has Copy PID and
**Kill… / Kill -9…** (with confirmation; it runs in the same connection).

**Containers tab** (Docker; Podman via the same CLI flags if `docker` is absent):

```
┌ tokscale-db-1                      up 4 months (healthy) ⋯ ┐
│ ( 0% )   MEM          R 140 M           ↑ 15 G             │
│          93 M         W  60 G           ↓ 3.8 G            │
├────────────────────────────────────────────────────────────┤
│ memos                                       up 5 months ⋯  │
│ …                                                          │
```

- One row per container: the name (bold), status on the right
  (`up 4 months (healthy)`, red text when exited / unhealthy), and a ⋯ menu.
- Body: a CPU % ring with a green dot · MEM used · block I/O **R / W** totals ·
  network **↑ / ↓** totals.
- Data: `docker ps -a --format '{{json .}}'` (name, state, status, health) plus
  `docker stats --no-stream --format '{{json .}}'` (CPU %, mem, BlockIO, NetIO),
  polled every 5 s while the tab is visible and never in the background.
- The ⋯ menu has Start / Stop / Restart, **Logs** (opens a terminal tab running
  `docker logs -f --tail 200 <name>`), **Shell** (a terminal tab running
  `docker exec -it <name> sh`), and Copy ID.
- Sorted running first, then by CPU. A filter field appears above 10 containers.
- If Docker is missing or permission is denied, an empty state explains why
  ("Docker isn't installed" / "The user `deploy` can't access the Docker socket.
  Add it to the `docker` group.").

**Data and cost**: the extra collectors (`/proc/net/snmp`, `ip addr`, process
list, docker) run **only while the inspector shows that server and tab**, over
the poller's existing connection (§5.5). Cards keep the cheap command set. These
are extensions of Rayon's `MachineStatus` (new sections in `ServerStatusInfo`
plus parsers in `ProcParsers`, each with unit tests from captured fixtures). The
inspector views replace Rayon's `MonitorDashboard` cards in `MachineStatusView`.
Rayon's full **Monitor** page stays reachable from the ⋯ menu for now.

---

## 6. SFTP: Termius-style dual pane

### 6.1 Today

`FileTransferPage` is one remote pane per server with a toolbar (Up, Go to Folder,
Reload, New Folder, Upload, Download) and a single transfer card. Uploads come
from Finder drag or a file picker. `FileTransferContext` runs one transfer at a
time and blocks the UI while it runs (`isProgressRunning`).

### 6.2 Target layout (from the reference screenshot)

```
┌──────────────────────────────────────┬──────────────────────────────────────┐
│ [🖥] Local          🔍 Filter  Actions▾│ [🖥] prod-web-01    🔍 Filter  Actions▾│
│ ‹  ›   📁 Users › 📁 vincent           │ ‹  ›   📁 / › 📁 var › 📁 www          │
├──────────────────────────────────────┼──────────────────────────────────────┤
│ Name            │Date Modified│Size│Kind│ Name            │Date Modified│Size│Kind│
│ 📁 ..                                 │ 📁 ..                                 │
│ 📁 Desktop                            │ 📄 index.html                         │
│    drwx------@                        │    -rw-r--r--                         │
│ …                                    │ …                                    │
├──────────────────────────────────────┴──────────────────────────────────────┤
│ Transfers (2)   ▲ app.tar.gz  ███████░░░ 68%  12.4 MB/s  0:08 left    ✕     │
└─────────────────────────────────────────────────────────────────────────────┘
```

- **Two panes, side by side**, split 50/50 with a draggable divider.
- **Either pane can be Local or any saved server.** This allows local↔remote and
  remote↔remote. The left pane defaults to Local (the home folder); the right pane
  defaults to the empty state.
- **Pane header**: a source icon + name (click to switch: Local / saved servers /
  Disconnect), a **Filter** field, an **Actions ▾** menu (New Folder, Upload…,
  Download…, Refresh, Go to Folder…, Show Hidden Files, Copy Path, Open in
  Terminal (remote) / Reveal in Finder (local)).
- **Navigation row**: Back / Forward (history per pane), then a breadcrumb with
  folder icons. Each crumb is clickable and is a drop target.
- **Columns**: Name (with a smaller second line showing permissions, like
  `drwxr-xr-x@`), Date Modified, Size (`- -` for folders), Kind. Columns are
  sortable and resizable. Folders come first. A `..` row sits at the top.
- **Empty state** (pane with no source): folder icon, "Connect to host",
  "Start by connecting to a saved host to manage your files with SFTP.",
  **Select host** button → a host picker with search (reuses `ServerPickerPanel`).

### 6.3 Drag and drop (the core of the feature)

| Drag from | Drop on | Result |
|---|---|---|
| Local pane | Remote pane (list or folder row or crumb) | Upload |
| Remote pane | Local pane | Download |
| Remote A | Remote B | Server-to-server copy (streamed through the Mac) |
| Finder | Any pane | Upload (remote) / copy (local) |
| Any pane | Finder | Download / copy to the drop location (file promise) |
| Within one pane, onto a folder | — | Move (⌥ = copy) |

- Dropping on a **folder row** targets that folder; dropping on empty space targets
  the pane's current folder. The target highlights while hovering. Hovering a
  folder for about 1 s springs it open, like Finder.
- Multi-select (⇧ / ⌘ click, ⌘A) drags all selected items. Folders transfer
  recursively.
- **Conflicts**: a dialog with Replace / Skip / Keep Both, plus "Apply to all".

### 6.4 Transfer queue and progress

- New `TransferQueue` (in `TamioModule/FileTransfer`), separate from browsing,
  so **browsing stays usable while files transfer**. This removes the
  `isProgressRunning` lockout.
- Each job has source, destination, item list, bytes total/done, speed, ETA and a
  state (queued, running, paused, done, failed, cancelled).
- Parallelism: 2 concurrent jobs per server connection by default, each over its
  own SFTP channel. It can be set in Settings.
- **Progress UI**:
  - A collapsible **Transfers bar** at the bottom of the SFTP page: the current
    file, a progress bar, %, speed and ETA, a count of queued jobs, and Cancel. It
    expands into a list of every job with per-job progress, Cancel and Retry.
  - Inline: the destination row shows a small circular progress ring on the file
    being written.
  - Sidebar: the session row shows a small progress ring while transfers run.
  - The Dock icon shows overall progress; a notification is sent when a long batch
    finishes while the app is in the background.
- Errors per file never stop the batch. Failed items are listed with Retry.

### 6.5 Backend notes

- Local pane: `FileManager` listing, plus `URLResourceValues` for kind and date.
  The app is not sandboxed (§3.4), so the pane opens in the home folder and can go
  anywhere the user can, with no access prompts. macOS privacy prompts (TCC) for
  Desktop, Documents and Downloads still appear the first time; Tamio shows a
  short inline hint if one is denied.
- Remote pane: `NSRemoteShell` SFTP (`requestUpload`, download, list, rename,
  delete). The queue needs **per-file byte progress and cancellation**, which
  `requestUpload(forFileAndWait:toDirectory:progress:continuation:)` already
  provides. Recursive folder transfer needs to be added to the queue layer.
- Server-to-server copy: stream read from A and write to B in chunks; no temp
  file for files under a size threshold, a temp file in the app container for
  larger ones.
- The editor integration stays: double-click a remote text file → `EditorPage`.

### 6.6 Routing

- `Route.transfer(UUID)` now points to a **dual-pane SFTP workspace**, not a
  single server's context. Each pane holds an optional `FileTransferContext`
  (remote) or a local source.
- The sidebar gets one **SFTP** entry under Sessions per open workspace. "Files"
  on a server tile opens a workspace with Local on the left and that server on
  the right.

---

## 7. iCloud sync with end-to-end encryption

### 7.1 Requirements

- Sync **identities** (usernames, passwords, private and public keys), **snippets**
  and **SSH hosts** across every device on the user's Apple ID. Known host keys and
  port forwards also sync (Q9).
- **End-to-end encrypted.** Apple, anyone with access to iCloud servers, and anyone
  who gets a copy of the CloudKit data sees only ciphertext. Secrets are never
  written to iCloud in readable form, not even in CloudKit's own "encrypted
  fields". Those use Apple-held keys unless the user has turned on Advanced Data
  Protection, so they are not end-to-end on their own.
- **Automatic**: changes reach other devices within seconds, with no "Sync now"
  button needed. Works offline and catches up later.
- **Cross-platform from day one**: the format, keys and code live in
  `TamioModule`, so the future iOS client syncs with no protocol change.

### 7.2 What changes from Rayon's sync

| | Rayon (today) | Tamio |
|---|---|---|
| Storage | One sealed blob in `NSUbiquitousKeyValueStore` | **CloudKit private database**, custom zone `TamioVault`, one record per item |
| Size limit | 1 MB total | Effectively none (per-record limit 1 MB, so large keys are fine) |
| Items | Servers, identities | Hosts, identities, snippets, known hosts, port forwards |
| Key | Derived from a passphrase on every device | A random **vault key**, distributed through iCloud Keychain, with passphrase / recovery key as backup |
| Change notification | KVS external-change notification | CloudKit silent push + `CKSyncEngine` |
| Merging | Whole document, per-item last-writer-wins | Per record, last-writer-wins on server change tags, tombstones |

What is kept: AES-256-GCM sealing, per-item LWW with tombstones (`SyncDocument`
logic), and the off-main-thread pure "sync round" design of `SyncSession`.
Rayon's KVS transport is removed. Tamio has a new bundle ID, so there is no
existing Tamio data to migrate.

### 7.3 Key hierarchy

```
                 ┌──────────────────────────────┐
                 │ Vault Key (VK) 256-bit random │  created once, on the first device
                 └──────────────┬───────────────┘
        distributed by ─────────┼──────────────── optional backup
  iCloud Keychain item          │          Recovery Key (offered, skippable)
  (kSecAttrSynchronizable,      │          → KEK = HKDF-SHA256(recovery key)
   E2EE by Apple)               │          → wrapped VK stored in CloudKit `VaultMeta`
                                ▼
     Item Key = HKDF-SHA256(VK, salt = recordName, info = "tamio.item.v1")
                                ▼
     record payload = AES-256-GCM(item JSON, AAD = recordType ‖ recordName ‖ schemaVersion)
```

- **Vault key (VK)**: 32 random bytes from `SecRandomCopyBytes`, created on the
  first device that turns sync on. It never leaves the device in plain form
  except through iCloud Keychain.
- VK is saved as a synchronizable keychain item
  (`kSecAttrSynchronizable = true`, service `sb.moe.tamio.vault`, accessible
  `AfterFirstUnlock`). iCloud Keychain is end-to-end encrypted by Apple for all
  users (protected by device passcodes), so a new Mac or iPhone signed in to the
  same Apple ID gets VK automatically and sync starts with no prompt.
- **There is only this one mode.** No passphrase is asked for (decided, Q8). A
  "strict" mode (VK kept out of iCloud Keychain, passphrase on each new device)
  could be added later without changing the record format, because VK is already
  wrapped separately for recovery.
- **Recovery Key (recommended, skippable)**: after the first enable, Tamio offers a
  **Recovery Key** (a base32 code, with "Save to file / Print / Copy"). VK wrapped
  with a key derived from it (HKDF-SHA256) is stored in the `VaultMeta` record. It
  is only needed if iCloud Keychain loses VK, for example after an iCloud Keychain
  reset or when signing in on a new device with no trusted device left. If it is
  skipped and VK is lost, the iCloud data cannot be decrypted. The local data on
  each device is unaffected, and sync can be started fresh from it. Settings →
  Sync keeps a "Create Recovery Key" button.
- **Item keys** are derived per record. A ciphertext copied from one record into
  another fails authentication, because of the AAD binding.
- **Key check**: `VaultMeta` holds a `keyCheck` (a GCM seal of a constant) so a
  device can tell "wrong key" from "corrupt data". This matches Rayon's
  `OpenError.wrongPassphrase` / `.corruptedData`.

### 7.4 CloudKit layout

- Container: `iCloud.sb.moe.tamio`. Private database, custom zone `TamioVault`
  (custom zones are required for change tokens and atomic batches).
- Record types (the names are generic on purpose to leak less):
  - `VaultMeta` (one record): `formatVersion`, `vaultID`, `wrappedVK` (by the recovery
    key, if one was made), `kdf` parameters, `keyCheck`, `createdAt`.
  - `Item`: `payload` (Bytes: nonce ‖ ciphertext ‖ tag), `schema` (Int64), and
    nothing else. **The item kind, name, host address, etc. are all inside the
    ciphertext.** `recordName` is a random UUID, not tied to the local item ID.
- Inside the payload (plain JSON before sealing):
  `{ kind: "host"|"identity"|"snippet"|"knownHost"|"portForward", id, modified, deviceID, deleted, value }`
- Payloads are padded to a 256-byte bucket so their size doesn't reveal what they
  hold (for example, the length of a key).
- What Apple can still see (stated in the privacy notes): that the user has
  Tamio, the number of records, approximate sizes, and when they change.

### 7.5 Sync engine

- `CKSyncEngine` (macOS 14 / iOS 17) handles fetching changes, sending pending
  changes, retries, the account state and push subscriptions. This needs a
  minimum of macOS 14 (Q7).
- **Automatic**: the engine registers a CloudKit zone subscription, so a change on
  one device sends a silent push to the others. Entitlements:
  `com.apple.developer.icloud-services = CloudKit`,
  `com.apple.developer.icloud-container-identifiers`, `aps-environment`. Also sync
  on launch, on becoming active, and after local edits (debounced 1–2 s).
- **Local store** stays the source of truth for the UI (`TamioStore`). The engine
  is told about local changes as `pendingRecordZoneChanges`; incoming records are
  decrypted off the main thread and applied as put/remove changes, as
  `SyncChange` does today.
- **Conflicts**: last writer wins per item, using the `modified` value inside the
  payload, with `deviceID` as a tie-breaker. On `serverRecordChanged` the engine
  re-reads the server copy, decrypts it, compares, and keeps the later one. Only
  the whole item is kept, never a mix of fields. A conflict that overwrote a
  local edit made within the last minute is logged for "Sync activity".
- **Deletions**: a tombstone (`deleted: true`, `value: nil`) is uploaded and then
  the record is removed after 180 days, matching Rayon's `tombstoneLifetime`.
- **Device-local fields that do not sync**: `lastConnection`, `lastBanner`, live
  metrics, the SFTP pane state, window layout, and per-device settings.
- **Per-type toggles** in Settings: Hosts, Identities, Snippets, Known hosts, Port
  forwards. Turning one off stops sending and applying that kind, and does not
  delete it on the other devices.

### 7.6 Security details for identities (keychains)

- At rest on each device: the existing store encryption (`AES.swift`, master key
  in the data-protection keychain, `ThisDeviceOnly`) stays. VK and the master key
  are separate keys.
- Optional **"Require Touch ID to use keys"**: private keys and passwords are
  released only after `LAContext` / `SecAccessControl(.userPresence)`. Off by
  default.
- Secrets are never logged and never placed in crash reports, the pasteboard
  (except an explicit Copy with auto-clear after 60 s), Spotlight, or `UserDefaults`.
- Memory: decrypted payloads are short-lived and are not cached outside the store.
- Crypto comes only from CryptoKit / CommonCrypto (no custom primitives). The
  sealing code gets unit tests with fixed vectors, plus tamper tests (bit flip,
  swapped record, wrong AAD, wrong key) in `TamioModuleTests`.

### 7.7 Lifecycle and UX (Settings → Sync)

- **On by default**: on first launch with iCloud signed in, Tamio shows a one-screen
  explanation ("Your hosts, keys and snippets sync through iCloud, end-to-end
  encrypted. Apple can't read them.") with **Turn On** preselected, then offers
  the Recovery Key (skippable). After that it uploads with progress.
- **Another device**: picks up VK from iCloud Keychain and merges automatically,
  with no prompt. If the data is in iCloud but VK has not arrived yet (iCloud
  Keychain can lag, or is off on that device), it shows "Waiting for iCloud
  Keychain…" with "Enter Recovery Key" as a fallback, and a hint to turn on iCloud
  Keychain (System Settings → Apple ID → iCloud → Passwords & Keychain). Merging
  with existing local data uses the LWW rules, and nothing is silently deleted.
- **Status line**: Synced · just now / Syncing… / Offline / iCloud not signed in /
  Locked (needs recovery key) / Error with details.
- **Create / regenerate the recovery key**: re-wraps VK only (fast); the old key stops working.
- **Rotate vault key** (for example after a device is lost and removed from the
  Apple ID): new VK, re-encrypts every record, updates iCloud Keychain and
  `VaultMeta`. Other devices pick up the new VK automatically. Note: rotation
  protects future changes. A device that already has the data has a copy of it.
- **Turn off on this device**: stops syncing, keeps local data.
  **Delete iCloud data**: deletes the zone on every device, after a confirmation.
- iCloud account changes (sign-out, switch) stop sync and keep local data. The
  user is asked before data from a different account is merged.

### 7.8 Threat model (summary)

| Threat | Mitigation |
|---|---|
| Apple / iCloud breach reads CloudKit data | Only AES-GCM ciphertext; VK never stored in CloudKit unwrapped |
| Attacker tampers with or swaps records in CloudKit | GCM authentication + AAD binding of recordName / type / schema |
| Attacker with the Apple ID password only | iCloud Keychain also requires a trusted device or one of the user's device passcodes (Apple's iCloud Keychain escrow); without that, VK is unreachable |
| Stolen unlocked Mac | Out of scope for E2EE; optional Touch ID gate on key use (§7.6) |
| Lost recovery key and all devices | Data is unrecoverable (stated during setup) |
| Attacker who knows the Apple ID password **and** a device passcode | Can reach iCloud Keychain, so can get VK. This is the accepted trade-off of automatic key sharing (Q8). A strict mode could close it later (§7.3) |
| Leaked recovery key | Regenerate it (re-wraps VK) or rotate the vault key |

### 7.9 Where it lives in the code

- `Foundation/TamioModule/Sources/TamioModule/Sync/`
  - `VaultKey.swift` (new): VK creation, keychain storage (sync / this device only), wrap and unwrap.
  - `SyncCipher.swift`: extended with HKDF item keys, AAD, padding, and format v2.
  - `SyncRecord.swift` (new): payload ↔ `CKRecord` mapping.
  - `CloudKitSyncEngine.swift` (new): the `CKSyncEngineDelegate`, replacing `CloudKeyValueTransport`.
  - `SyncDocument.swift` / `SyncSession.swift`: LWW and tombstone logic reused per record.
  - `CloudSyncSettings.swift`: the new Settings UI (shared with iOS later).
- The `RDSnippet`, `RDPortForward` and known-hosts stores gain `modified` stamps.
- Entitlements are added to `Application/Tamio/macOS/macOS.entitlements`; the
  CloudKit container and push are configured on the Apple Developer account for
  `sb.moe.tamio`.

---

## 8. Agent access: Tamio MCP server

> **Revised 2026-10-17 (implemented).** Where this section and the notes below
> differ, the notes win:
> - **Full management, secrets write-only.** Beyond reading hosts, metrics and
>   `ssh_config` and running commands, agents can add / update / remove servers,
>   SSH key identities (`add_identity` with `generate: true` returns only the
>   public key; an imported `private_key` or `password` goes in and never comes
>   back out), snippets and port forwards (add, start, stop, remove). Every one of
>   these asks the user (Allow / Allow for 1 Hour / Deny). A test
>   (`AgentServerTests`) saves secrets and checks that no read tool or resource
>   returns them.
> - **Per-server agent activity, for every Mac.** Each approved action is
>   recorded on the servers it concerns (client, device, command, per-server
>   exit codes, outcome, also when declined). Agents that act by their own ssh
>   report it with `log_activity`; `get_activity` gives the next agent the
>   history. The MCP instructions and the skill tell agents to do both. The log
>   is an item kind of the E2EE iCloud sync (§7), so another Mac's Tamio and its
>   agents see it. It shows in each server's inspector (Activity) and in
>   Settings › MCP.
> - **Settings › MCP**: the server is **on by default**; the page has the Claude
>   Code command, the Codex config, **Install Skill** (copies the skill bundled
>   in the app to `~/.claude/skills/tamio`) with its shell command, and a prompt
>   to paste into any agent. The skill lives in the repo at `skills/tamio/SKILL.md`.
> - The stdio command is `Tamio.app/Contents/Resources/tamio-mcp`, a shell script
>   that relays to the socket with `nc -U` (no extra binary). The socket is
>   `~/Library/Application Support/<bundle id>/agent.sock`, mode 0600, and only
>   the user's own processes may connect (`getpeereid`).

### 8.1 Goal

AI agents (Claude Code, Codex, Cursor, any MCP client) can see the user's hosts
and act on them through Tamio. For example: "update the kernel on every
Production host and reboot the ones that need it". No existing SSH client offers
this. Tamio is the one place that already knows every host, how to log in, and
its live state, so it is the natural server for it.

### 8.2 The core rule: details out, secrets never

- Agents can read **connection details**: name, address (IP or hostname), port,
  username, group, tags, comment, auth *kind* (key / password / agent), identity
  *name*, host-key fingerprint, OS / kernel / uptime from live metrics, and last
  connected time.
- Agents can **never** read passwords, private keys, passphrases, the vault key or
  recovery key. There is no tool, resource or setting that returns them. The MCP
  layer works on a separate `AgentHost` type that has no secret fields, so a
  secret can't leak by mistake.
- To **do** something on a host, the agent asks Tamio. `run_command` and friends
  run over Tamio's own SSH connections with Tamio's saved credentials. The keys
  stay in Tamio, and the user sees and approves what runs.
- For agents that prefer their own `ssh`, `export_ssh_config` returns `Host`
  blocks (HostName / Port / User / HostKeyAlias). It has no keys; that works when
  the user's keys are already in `ssh-agent` / `~/.ssh`.

### 8.3 Transport

- **stdio, the default**: a small helper inside the app bundle,
  `Tamio.app/Contents/Helpers/tamio-mcp`. MCP clients launch it as a command:
  ```sh
  claude mcp add tamio -- /Applications/Tamio.app/Contents/Helpers/tamio-mcp
  ```
  The helper is a thin pipe: it relays MCP JSON-RPC between stdio and the running
  app over a Unix domain socket,
  `~/Library/Application Support/Tamio/agent.sock` (mode 0600, owner only; the
  app checks the peer's UID and code signature with `getpeereid` + `SecCode`). If
  Tamio isn't running, the helper launches it in the background (menu-bar only)
  and waits up to 10 s.
- **Streamable HTTP, optional**: `http://127.0.0.1:<port>/mcp`, off by default,
  for clients that only take a URL. Needs a bearer token shown in Settings, and
  binds to loopback only.
- The MCP server itself lives **in the app process** (`TamioModule/Agent/`), so it
  reuses the store, identities, SSH engine, known-hosts checks and metrics. It is
  built on the official Swift MCP SDK (`modelcontextprotocol/swift-sdk`), with
  protocol revision 2025-06-18 or later.

### 8.4 Tools

| Tool | Input | Returns | Approval |
|---|---|---|---|
| `list_hosts` | `query?`, `group?`, `tags?`, `status?` (online/offline) | `AgentHost[]` (§8.2 fields + `id` UUID) | none (read) |
| `get_host` | `id` or `name` | one `AgentHost` + live metrics summary | none |
| `list_groups` / `list_tags` | — | names with host counts | none |
| `get_metrics` | `ids[]` | CPU / mem / disk / load / net / traffic / OS / kernel / uptime (§5.5) | none |
| `export_ssh_config` | `ids[]?` | `ssh_config` text, no secrets | none |
| `list_snippets` | `query?` | snippet names, descriptions and bodies | none |
| `run_command` | `targets` (ids / group / tag / `"all"`), `command`, `timeout_s` (default 300), `concurrency` (default 8), `sudo` (bool), `stop_on_error` | a job id plus per-host `{exit_code, stdout, stderr, duration}`; progress notifications while running | **yes** |
| `run_snippet` | `targets`, `snippet_id`, `vars?` | same as `run_command` | **yes** |
| `get_job` / `cancel_job` | `job_id` | status and output so far / cancels | none |
| `read_file` / `write_file` | `id`, `path`, (`content`) | SFTP, size-capped at 1 MB | write: **yes** |
| `upload` / `download` | `id`, local ↔ remote paths | through the §6.4 transfer queue | **yes** |

Resources: `tamio://hosts` (the list), `tamio://hosts/{id}`, and
`tamio://hosts/{id}/metrics`, with change notifications so a client can keep a
live inventory.

Prompts: `fleet_update` (check updates → apply → reboot if the kernel changed →
verify), and `fleet_health` (report hosts with high load, disk over 90 %, or long
uptime without a reboot).

Notes:
- `sudo: true` runs `sudo -n sh -c '<command>'`. If sudo needs a password and the
  host's identity has one saved, Tamio feeds it on stdin itself, so the password
  never goes to the agent. Otherwise the host returns a clear error.
- Output per host is capped (1 MB, then the tail is kept and a flag says it was
  truncated). Long jobs keep running after the call returns, and the agent polls
  `get_job`.
- Host-key checks apply exactly as for the terminal. An unknown or changed key
  fails that host with `host_key_unverified`. It is never auto-accepted for an
  agent.

### 8.5 Approval and control (Settings → Agents)

- **Off by default.** Turning it on shows the setup command for Claude Code /
  Codex / Cursor, with copy buttons.
- **Connected clients** list: the client name from MCP `initialize`, when it was
  last seen, and Revoke.
- **Scope**: which hosts agents can see. All, or chosen groups / tags; the rest
  are invisible to `list_hosts` and can't be targeted.
- **Approval for actions** (`run_*`, writes, transfers):
  - **Ask every time (default)**: a Tamio window (or notification when in the
    background) shows the client, the exact command, and the target host list with
    a count, e.g. "Run on 14 hosts: `sudo apt-get update && sudo apt-get -y
    dist-upgrade`". Buttons: Run / Deny / **Allow this client for 1 hour**.
  - **Allow read-only commands** without asking: an allow-list of prefixes
    (`uname`, `cat /etc/os-release`, `uptime`, `df`, `systemctl status`, …) that
    the user can edit.
  - **Always allow for this client**: the user has to choose it on purpose, and
    it is labelled as dangerous.
- **Activity log** (Settings → Agents → Activity): every tool call with the time,
  client, tool, targets, command, approval decision, and per-host exit code;
  output can be expanded. Kept for 30 days, device-local, never synced.
- A running agent job shows as a session in the sidebar (like a batch snippet
  run), with live per-host output and Stop.

### 8.6 Implementation

- `TamioModule/Agent/`: `AgentServer` (the MCP tool/resource handlers),
  `AgentHost` (a secret-free projection of `RDMachine` + `RDIdentity` metadata),
  `AgentJobRunner` (reuses `SnippetExecSession` from Rayon's batch snippet runner,
  with concurrency limits and output caps), `AgentPolicy` (scope, approvals,
  allow-list), `AgentAuditLog`.
- `Application/Tamio/Interface/Agents/`: the Settings page, the approval sheet,
  and the job session page.
- `Helpers/tamio-mcp`: a Swift command-line target (macOS, AppKit-free), embedded
  at `Contents/Helpers/` and signed with the app.
- Tests: unit tests that no `AgentHost` encoding contains a secret field (a
  reflection test over the encoded JSON against known secrets), policy tests, and
  an end-to-end test that drives the helper with recorded MCP sessions against a
  local `sshd` in CI.

---

## 9. Kept as-is from Rayon

- Sidebar structure: Home · **Manage** (Servers, Identities, Snippets, Port
  Forward) · Sessions · Settings pinned bottom-left (`SidebarView.swift`).
- Settings pages (`Interface/Settings`), including the terminal text, colors and
  keyboard settings.
- Ghostty terminal (`Foundation/TamioTerminal`, was `CatusshTerminal`) and its configuration.
- Monitor page, menu-bar monitor, snippets batch run, port forwarding, the editor,
  and known-hosts checking. (Rayon's iCloud sync is replaced, see §7.)
- The design system (`TamioDesign`, `RX` tokens). A Tamio accent color and icon
  are the only visual brand changes for v1.

---

## 10. Milestones

| # | Milestone | Content | Done when |
|---|---|---|---|
| M0 | Fork and rebrand | Copy Rayon, `upstream` remote, bundle IDs, names, icon, iOS out of the build | `Tamio.app` builds, launches, and the terminal connects |
| M1 | New Server panel | §4 panel, inline credentials as private identities, Quick Connect removed | New/edit/connect works for password, key and identity |
| M2 | Live status cards + inspector | §5: `MetricsPoller` (+ disk I/O, traffic), ServerCat-style cards with click-flip + auto-rotation, the §5.7 inspector (Overview / Processes / Containers), table columns, settings | 20 servers update every 3 s with no visible UI cost; rotation, hover pause and Reduce Motion work; offline/auth states shown |
| M3 | Agent access (MCP) | §8: in-app MCP server, `tamio-mcp` stdio helper, read tools + `run_command` with approval, Settings → Agents, activity log | `claude mcp add tamio …` lists hosts; an approved `run_command` updates packages on several hosts with per-host results; no secret appears in any response |
| M4 | Dual-pane SFTP: browsing | §6.2 layout, local + remote panes, history, sorting, filter, Actions menu | Both panes browse; empty state and host picker work |
| M5 | SFTP: transfers | §6.3 drag and drop, §6.4 queue + progress, conflicts | Drag both ways with live progress; browsing works during transfers |
| M6 | E2EE iCloud sync | §7: vault key, CloudKit zone, `CKSyncEngine`, push, recovery key, Settings UI | Two Macs on one Apple ID converge within seconds; CloudKit Dashboard shows only ciphertext |
| M7 | Polish and release (Sparkle, DMG) | Remote↔remote, Finder drag-out, notifications, signing, notarization, DMG | Signed, notarized build |

---

## 11. Decisions and open questions

### Decided (2026-10-17)

| # | Decision |
|---|---|
| Q1 | No `user@host:22` field anywhere: removed from the New Server panel and the Home Quick Connect bar |
| Q2 | Live status uses ServerCat-style cards with rotating slots: Load, CPU, Memory, Disk, network speed and traffic used (§5) |
| Q4 | Not on the Mac App Store. Developer ID signed + notarized DMG on GitHub Releases, updates through Sparkle 2; App Sandbox removed (§3.4) |
| Q7 | Minimum macOS is 14 Sonoma |
| Q8 | Automatic key sharing through iCloud Keychain is the only mode; no passphrase. A recovery key is offered but optional (§7.3) |
| Q3 | Tags kept as in the default: optional free-form labels on a server (like "prod", "tokyo"), used for search and filtering. They are not identifiers; a server is identified by its UUID (§4.5) |
| Q5 | Internal module names also become Tamio (`TamioModule`, `TamioTerminal`, `TamioDesign`, `TamioEditor`, `TamioStore`…); the `RD*` / `RX` prefixes stay. Upstream fixes are ported by hand (§3.1, §3.2) |
| Q6 | The product owner has an Apple Developer Team ID; it goes into `project.yml` `DEVELOPMENT_TEAM` at M0 |
| Q10 | The product owner has the Sparkle update feed URL; it goes into `SUFeedURL` at M6 |
| Q11 | Traffic totals default to ServerCat's behavior (since-boot counters); billing cycle / quota / vnstat are optional per server (§5.6) |

### Open

| # | Question | Default if unanswered |
|---|---|---|
| Q9 | Also sync known host keys and port forwards, beyond hosts, identities and snippets? | Yes, both |
