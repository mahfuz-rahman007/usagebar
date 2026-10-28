<h1 align="center">UsageBar</h1>

<p align="center">
  <b>One tiny macOS menu bar icon. Every AI usage limit you care about.</b><br>
  Claude · Codex · Cursor · your running agents
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13%2B-black?logo=apple" alt="macOS 13+">
  <img src="https://img.shields.io/badge/memory-~14%20MB-brightgreen" alt="~14 MB">
  <img src="https://img.shields.io/badge/dependencies-0-blue" alt="0 dependencies">
  <img src="https://img.shields.io/badge/source-1%20file-orange" alt="1 Swift file">
  <img src="https://img.shields.io/badge/license-MIT-lightgrey" alt="MIT">
</p>

---

Ever hit "You've reached your limit" mid-task? UsageBar sits in your menu bar and shows exactly how much Claude Code, Codex and Cursor you have left, when each window resets, and which of your agents are still working. Glance, plan, keep going.

```
Claude
   9% used   5-hour session                         resets in 2h 48m
  17% used   Weekly (all models)                    resets in 19h 38m
   4% used   Weekly Fable                           resets in 19h 38m
  27% used   Cloud session credit                   $68 / $250 · resets in 8d 14h
             Weekly split                           Claude Code 100%
Codex (pro)
 100% used   Weekly                                 resets in 5d 13h     ← red
             Credits balance                        37364
Cursor (pro)
   0% used   Included usage                         $0.00 / $20 · resets in 25d
   0% used   Cursor models pool (Auto, Composer, Grok)
   0% used   Other models pool (API)
             grok-bot-default                       30 requests · $0.83 this cycle
Local agents
   ● claude · my-app @ feature/login                "fix the failing test" · 8s ago
   ○ codex  · api-server                            idle
VPS agents (my-vps)
   ● oneclick-loop                                  working · reviewing PR #42
```

## Why this instead of X?

| | UsageBar | Typical Electron tray app | Checking each dashboard by hand |
|---|---|---|---|
| Memory | **~14 MB** | 150–300 MB | your sanity |
| Install | `./build.sh` | installer + auto-updater | – |
| Dependencies | **none** | hundreds | – |
| Source | **1 Swift file, ~320 lines** | a repo you'll never read | – |
| Accounts to log in to | **zero** – reuses what the CLIs already stored | re-login | re-login |

## Install

Requires macOS 13+ and Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/mahfuz-rahman007/usagebar.git
cd usagebar
./build.sh
```

That's it. The script compiles `UsageBar.app`, launches it, and registers it to start at login. A gauge icon appears in your menu bar; click it.

To stop it from starting at login:

```bash
rm ~/Library/LaunchAgents/local.usagebar.plist
```

## What shows up

Sections appear only for tools you're actually logged in to.

| Section | Needs | Where the data comes from |
|---|---|---|
| **Claude** | `claude` CLI logged in (Pro/Max) | The same OAuth token Claude Code keeps in your Keychain, calling the same endpoint `/usage` uses. 5-hour, weekly, per-model, cloud session credit, extra usage, weekly split. |
| **Codex** | `codex login` done | `~/.codex/auth.json` token against the ChatGPT backend. 5-hour and weekly windows, credit balance. |
| **Cursor** | Cursor IDE signed in | Cursor's session token from its local state DB. Included usage, the Auto/Composer/Grok pool, the API pool, on-demand, per-model requests this cycle. |
| **Local agents** | – | Every interactive `claude` / `codex` process on this Mac: project, branch, last prompt, working/idle. |
| **VPS agents** | `vpsHost` in config, [herdr](https://herdr.dev) on the host | `herdr agent list` over ssh, plus whether `claude remote-control` is up. |

Everything refreshes every 5 minutes. Local agents refresh every time you open the menu. Press `R` in the menu to refresh now. Lines at 90%+ turn red.

**Offline?** Nothing breaks. Each section keeps the last numbers it fetched and is marked `⚠︎ stale, fetched 14:03`, and the footer says a refresh needs internet. It catches up on the next refresh once you're back online.

## Configuration (optional)

Create `~/.config/usagebar.json`. Every key is optional.

```json
{
  "vpsHost": "my-vps",
  "herdrPath": "/root/.local/bin/herdr",
  "refreshSeconds": 300,
  "workingSeconds": 120,
  "maxChars": 72
}
```

| Key | Default | Meaning |
|---|---|---|
| `vpsHost` | *(none, section hidden)* | An ssh host alias from `~/.ssh/config` that runs herdr. Must work with `ssh -o BatchMode=yes`. |
| `herdrPath` | `herdr` | Path to herdr on that host. |
| `refreshSeconds` | `300` | How often everything refreshes. |
| `workingSeconds` | `120` | A local agent counts as "working" if its session log changed within this many seconds. |
| `maxChars` | `72` | Menu lines longer than this are cut with an ellipsis, so the menu keeps a fixed width. |

## Check it from the terminal

```bash
./UsageBar.app/Contents/MacOS/UsageBar --print
```

Prints every section as plain text. Handy for scripts, tmux status lines, or just checking that your logins work.

## Honesty section

- **It reads your local credentials.** The Claude Code Keychain entry, `~/.codex/auth.json`, and Cursor's `state.vscdb`. Nothing is sent anywhere except to the respective vendor's own API. Read the source; it's one file.
- **The endpoints are undocumented.** Anthropic, OpenAI and Cursor can rename or remove them any time. If a section breaks, open an issue with the `--print` output.
- **Some labels are interpretations.** Anthropic's usage API returns obfuscated field names (yes, really: `iguana_necktie`). "Cloud session credit" is what that dollar-capped allowance appears to be. Cursor's "Auto/Composer/Grok pool" is the `autoPercentUsed` bucket, which Cursor's own API lists every Grok model under.
- **Not available anywhere:** Anthropic Console API credit balance (no endpoint exists), Cursor's separate Grok Bot allowance (not exposed), Antigravity quota (only while the IDE runs, via an internal socket).

## Add your own provider

Write a function that returns a `Section`, add it to the list in `refresh()` and in the `--print` block. A `Section` is a name plus `Line`s; a `Line` is a label, an optional percentage, a note, an optional URL to open on click, and a red flag. That's the whole API.

## License

MIT. Built with Claude Code in an evening because the author had usage left over.
