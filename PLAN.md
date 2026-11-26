# Flâneur — implementation plan

A small, fast, native macOS launcher: Spotlight-style floating panel, summoned from
anywhere, searching **apps · rift windows/workspaces · herdr tabs · rex blocks ·
Brave/Helium/Yab browser tabs · T3 Code threads · QuickTime screen recording ·
clipboard history (text) · local folders/GitHub workflow dispatch**, themed
from `~/.config/flaneur/` with automatic system light/dark detection. That is all it does.

## Locked decisions (from discussion)

| Decision | Choice | Rationale |
|---|---|---|
| Language/UI | **Swift + SwiftUI** | Panel polish (vibrancy, focus dance, animation) is ~free; backend is trivial in any language |
| Build | SwiftPM executable + hand-rolled `.app` bundle | CLT toolchain present (Swift 6.3.3); no Xcode needed |
| Name / bundle id | **Flâneur** / `com.yajanarao.flaneur` | The wanderer across workspaces |
| Project dir | `~/Developer/flaneur` | Existing dev home |
| Install target | `~/Applications/Flaneur.app` | User-level, no sudo |
| Summon key | `hotkey = "…"` in config.toml, owned by the app itself (Carbon `RegisterEventHotKey`); default **Alt+Space**, running as **⌘Space** with Spotlight's shortcut disabled | Never depends on rift being healthy (rift's event pipeline can silently die — observed 2026-10-05) |
| Workspace jumping | Rows for workspaces/windows, but the summon and activation paths never touch rift | Hot path keeps **zero rift coupling** (rift's event pipeline can silently die — observed 2026-10-05); rift rows are read-only, timeout-guarded, and fault-isolated |

## Architecture

```
┌─────────────────────────── Flaneur.app (LSUIElement agent) ──────────────────────────┐
│                                                                                       │
│  HotKey (Carbon) ──► Panel (NSPanel) ──► LauncherView (SwiftUI)                       │
│  flaneur --toggle ─┘  borderless           TextField + fuzzy list                     │
│  (DistributedNotif)   floating             ↑                                          │
│                        all-spaces/fullscreen│                                         │
│                        vibrancy, r=14   Model (@MainActor)                            │
│                                            │ refresh on every show                    │
│                        ┌───────────────────┴────────────────────┐                     │
│                        │ Collectors (background, all read-only) │                     │
│                        │  rift:  rift-cli query workspaces (JSON)                      │
│                        │  herdr: herdr tab list (JSON)          │                     │
│                        │  rex:   rex ls + session.view (JSON)   │                     │
│                        │       + rex events --all --json follower:                     │
│                        │         desktop_notification → banner + unread row            │
│                        │  tabs:  osascript → Brave, Helium, Yab │                     │
│                        │  apps:  NSWorkspace running + /Applications scan              │
│  projects: ~/Developer folders + cached Git metadata/workflows │
│                        └───────────────────┬────────────────────┘                     │
│                                            ▼                                          │
│                        Executor: activateApp · launchApp · rift window focus          │
│                                  herdr tab focus · browser tab focus                  │
│                                                                                       │
│  Config: ~/.config/flaneur/config.toml  (hotkey + [theme.dark]/[theme.light])         │
│  Theme:  NSAppearance auto-detect, live switch, rex-matched defaults                  │
│          (misty-forest dark / orchard-breeze light — native next to the Rex terminal) │
└───────────────────────────────────────────────────────────────────────────────────────┘
```

## Panel behavior (the "Spotlight-ness" checklist)

- `NSPanel`, `styleMask = [.borderless, .nonactivatingPanel]`, `canBecomeKey = true` override
- `level = .floating`, `collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]` → appears on the current Space, even over fullscreen apps
- `.thinMaterial` under an 80% palette tint (solid color when Reduce Transparency is on) + corner radius 14 + shadow
- Look: rounded inset selection (r8, 6px inset — no accent bar), accent-colored caret,
  fuzzy matches in accent + semibold (no underline), favicons get a 0.5pt `rule` hairline
  (white-on-transparent glyphs stay visible on light themes), footer shows per-row key
  glyphs. Collector failures stay out of the panel; the footer is for available actions only
- Show: center on active screen, upper-third; `NSApp.activate` + `makeKeyAndOrderFront` + focus field
- Hide: Esc, item chosen, or app resigns active (click-away) — all three
- 680×430, SF system font, mono for counts

## Sources → items

| Source | Command / API | Item shown | Action |
|---|---|---|---|
| rift workspaces | `rift-cli query workspaces` (JSON: index, name, focused, windows) | `  3 · Slack` (empty ones stay out of the resting list) | `rift-cli execute workspace switch <index>` |
| rift windows | same query, per window (title, app, window-server id, workspace) | `  Atul (DM) - Slack — Slack · workspace 3` | `rift-cli execute window focus --window-server-id <id>` **+** `NSRunningApplication.activate` fallback → covers Ghostty tabs (they're separate windows). Extras: **⌘1…0 / ⇧⌥1…0** move to workspace (`execute workspace move-window <index> <id>`, no follow — you stay put), **⌃F** fullscreen (focus + `toggle-fullscreen`), **⌘W** close (`execute window close --window-id`) |
| herdr tabs | `herdr tab list` (JSON) | `  herdr · w49 · tab 1 — working` | `herdr tab focus <tab_id>` |
| rex sessions + blocks | `rex ls --json`; per session `session.view` (placed blocks, focus, tab count) + `rex block ls --json` (adds detached blocks) | `  editor — Window · session` · `  arid-oasis — session · 3 tabs` | `rex do session.select session_id=… window_id=…` (shows the session in the app) **+** `rex block focus` **+** activate Rex; detached blocks select their session only |
| t3 threads | `~/.t3/userdata/statev2.sqlite` read-only (`orchestration_v2_projection_threads` ⨝ `projection_projects`, newest 30, WAL read so rows stay fresh) + `~/.t3/userdata/environment-id` | `  Fix the launcher — bento · dev` (badge: age) | activate/launch the app, then `t3code://threads/<env>/<thread>` — the URL must not be the launch event (cold-launch drops it, t3code#18613) |
| browser tabs | `osascript` per browser, only if running | `  Helium · PR #647 · Humanisys/bento` | AppleScript `set active tab index of window W to T` + activate → rift follows |
| apps | running (`NSWorkspace`) + installed (scan `/Applications`, `~/Applications`, `/System/Applications`) | `  Ghostty — running` / `  App` | activate (rift jumps to its workspace) / launch. Running apps: **⌘R** restart (terminate → wait → relaunch), **⌃⇧Q** quit |
| rift service | static row whenever `rift-cli` exists; survives query failures | `  Restart Rift — re-adopts every window` | `launchctl kickstart -k` on whichever label supervises rift (`sh.brew.rift` via brew services, else `git.acsandmann.rift`) — `rift-cli service` is a deprecated no-op stub |
| QuickTime Player | static row, only when the player is installed | `  Screen Recording — QuickTime Player` | osascript `new screen recording` → the File ▸ ⌃⌘N overlay; the red button is still manual |
| clipboard history | `ClipboardMonitor` polls `NSPasteboard.changeCount` every 0.5 s while the app runs (the pasteboard holds only the latest copy, so capture cannot wait for a show); newest 100 text clips in `~/.config/flaneur/clips.json` | `  first line of the clip — 2h` (icon: the app it was copied in) | Enter copies it back and restores focus — the next thing after copying is pasting. No Accessibility permission, no synthetic ⌘V |
| local folders / GitHub repositories | Immediate `~/Developer` folders; local `origin`, current/default branch and `origin/*` refs; root `.github/workflows/*.{yml,yaml}` | `bento — Humanisys/bento · 5 workflows` (branch badge; GitHub repositories get the bundled GitHub Mark) | Enter opens the folder. **⌃R** walks workflow → branch → any declared inputs, then `gh workflow run <file> --repo <owner/repo> --ref <branch>`; **⌃O** opens GitHub; **⌃Y** copies the repository URL |

- Fuzzy match: ~25-line subsequence scorer (boundary + consecutive bonuses), title+subtitle, cap 100 results.
- Row actions are data (`Item.actions: [ItemAction]` — chord, title, key label, run, exit), tinycast's
  `PopoverMenuItem` / snacks.picker's action spec: keys never name implementations, actions never
  hardcode keys. Enter, ⌃O/⌃Y, ⌘W, ⌘1–0, ⌃F, ⌘R, ⌃⇧Q all dispatch through one lookup; the footer
  hint is derived from the same list. ⌘W close stays bespoke in the state machine (it mutates rows).
- The Screen Recording row is search-only, like the Slack directory: the resting list stays the working set. Clipboard entries never appear in global search; they list only inside Clipboard mode.
- **Source scopes**: a single-letter query previews a source (snacks.picker's leader-key pickers, adapted to
  a field that is always in insert mode — a one-letter global search finds nothing anyway): `c` clips ·
  `w` rift workspaces/windows · `a` apps · `t` browser tabs · `b` brave · `y` yab · `h` herdr · `r` rex ·
  `n` notifications · `s` slack · `3` t3 · `g` GitHub repositories.
  The next letter returns to global filtering (`ca` is just "ca"). **`c` or `g` followed by Space**
  commits that source page and consumes the prefix: the input is empty, its placeholder names the
  scope, and subsequent text searches only that source. Backspace in an empty input or Escape leaves
  the page; ⌃U clears the query but keeps it. Sticky variant: `,c slack` keeps the scope while text
  searches within it. Scope listings bypass resting exclusions and keep natural order (clips stay MRU).
- Copies tagged `org.nspasteboard.ConcealedType` / `TransientType` / `com.apple.is-sensitive` (password managers, browsers, the OS) are never recorded; clips over 32 KB are skipped; a re-copy bumps the entry instead of duplicating it. The history is strict MRU: Enter on a clip never boosts it — time is the ranking.
- All collectors are **read-only** and **fault-isolated**: if rift is wedged or herdr is down, the rest still list. The launcher must be the tool you reach for when things break. The sole intentional write action is the final, explicit GitHub workflow dispatch.
- **Project cache:** `~/.cache/flaneur/projects.json` is loaded at launch and published before any rescan (stale-while-revalidate, single-flight). The folder catalog refreshes locally after five minutes. Parsed workflows are reused while their name/size/mtime signature is unchanged; branches come from local Git refs, never an API call. Only the final `gh workflow run` requires GitHub.

## Theming / config

`~/.config/flaneur/config.toml`:

```toml
hotkey = "cmd+space"    # top-level, before the first table; alt+space when unset

[theme.dark]          # rex misty-forest: bg/fg/selection/cursor verbatim
background = "#131A16"
text       = "#C4D2C5"
accent     = "#9DC2A0"   # rex cursor = the accent identity
on_accent  = "#131A16"

[theme.light]         # rex orchard-breeze
background = "#F4F9EF"
text       = "#3A4A35"
accent     = "#5DA24F"
on_accent  = "#F4F9EF"
```

- Minimal flat-TOML parser (~40 lines), hardcoded rex-matched fallbacks if file missing.
- Dark/light from `NSApp.effectiveAppearance`, KVO-observed → live switch.
- Recents (`~/.config/flaneur/recent.json`) rank zoxide-style: +10 per open, all scores
  age ×0.9 past a 10,000 total, entries under 1 fall off. v1 files seed scores from order.

## Integrations (outside the app)

1. **rift** — one line in `~/.config/rift/config.toml` `[settings]`:
   `auto_focus_blacklist = ["com.yajanarao.flaneur"]` — summoning the panel never yanks workspaces. (hot_reload picks it up; no restart.)

## File layout

```
~/Developer/flaneur/
├── PLAN.md                  ← this file
├── Package.swift            (swift-tools 5.9, macOS 14 floor)
├── Sources/flaneur/
│   ├── main.swift           bootstrap + --toggle CLI + AppDelegate
│   ├── Panel.swift          LauncherPanel (NSPanel subclass)
│   ├── HotKey.swift         Carbon RegisterEventHotKey wrapper
│   ├── Theme.swift          Config loader + Palette + hex colors + appearance
│   ├── Model.swift          Item/Action types, collectors, fuzzy scorer, executor
│   └── View.swift           LauncherView (SwiftUI)
│   (split today: Launcher.swift state machine, Herdr/Rex/Rift/T3Code/Browsers/Slack/
│    QuickTime collectors, Clipboard.swift pasteboard monitor + history store,
│    Projects.swift folder/GitHub catalog + persistent cache + workflow dispatch,
│    Item.swift types, Favicons.swift Chromium icon store — Yab is WebKit, no icons)
├── Resources/Info.plist     (LSUIElement = true)
├── Resources/GitHubMark.{svg,pdf}  (Primer Octicons source + bundled template vector)
└── scripts/build.sh         swift build -c release → ~/Applications/Flaneur.app → ad-hoc sign
    scripts/dev.sh           watch Sources/ → debug build → relaunch + pop panel (Ctrl-C restores installed app)
```

## Milestones

1. **M0** — scaffold + `swift build` green (empty panel shows/hides, hotkey works)
2. **M1** — apps source + activate/launch + fuzzy + keyboard nav
3. **M2** — rift, herdr, browser-tab collectors + actions
4. **M3** — config.toml theming + live light/dark switch
5. **M4** — rift blacklist line, verification, docs

## Verification

- `scripts/build.sh` exits clean
- `open ~/Applications/Flaneur.app` → no Dock icon (agent)
- `flaneur --toggle` → panel appears → `screencapture` visual check of theme/layout
- User confirms Alt+Space from another app, Esc, click-away, arrow/enter, one item per source type

## Known gotchas (accepted, with mitigations)

- **Automation consent**: first browser-tab query triggers macOS prompts “Flaneur wants to control Brave/Helium/Yab” — one-time per browser; collectors run async so a pending prompt never blocks the UI.
- **TCC + rebuilds**: ad-hoc signing identity is cdhash-based → consent may re-ask after rebuilds. Acceptable for v0; fix later with a self-signed cert if annoying.
- **TextField focus in a non-activating panel**: solved by `canBecomeKey = true` + activate-on-show (standard launcher pattern).
- **osascript latency** (~100–300 ms/browser): results render in two passes — instant sources first, tabs fill in async.
- **Pasteboard consent**: the first programmatic read of another app's clipboard may draw a one-time system prompt (macOS 14+); after that the monitor polls unnoticed.

## Explicit non-goals for v0

App icons in rows, launch animations, AI/files search, clipboard images/files/pinning,
multi-display smarts (panel uses the active screen), result caching across launches.

## Open items (defaults chosen; say otherwise)

- Hotkey **⌘Space** via `hotkey = "cmd+space"`; Spotlight's "Show Spotlight search"
  (symbolichotkeys key 64) is disabled. Re-enable in System Settings → Keyboard →
  Keyboard Shortcuts → Spotlight to go back.
