# CLAUDE.md

This file is the single source of truth for repository guidelines, used by Claude Code and all AI coding agents.

## Project Overview

**uting** (u-ting / 你听) — an agent-first media engine with a terminal face. A ten-script bash suite: search a source, play it through `mpv` detached from the terminal, keep controlling it, and save what you found — from a TUI if you are a human, from a single-line JSON contract if you are a program. Three sources ship today (YouTube, Bilibili, NetEase Cloud Music); a fourth is a new pair of scripts and no change anywhere else — the third one was, and it is the proof: nothing outside its own two files was rewritten to make room for it. Durable user-level state lives in its own commands — `ut-playlist` for what a person saved, `ut-history` for what a player played — not in the player, not in the TUI. The one deliberate exception is preferences: the TUI writes ten keys back, in place, to the user's own `config` (`docs/ARCHITECTURE.md`) — that file IS the agent surface for a preference, so no eleventh command was made to hold it.

The suite is exposed **directly** to shell-capable agents with no MCP wrapper, so the **CLI contract itself** (argv, exit codes, output shape, process lifecycle) *is* the product and the safety boundary. Every design choice follows from that. Full rationale: `docs/ARCHITECTURE.md`.

**Status: reference implementation.** Not packaged — no installer, no Homebrew formula, and none planned for the shell version (`docs/ROADMAP.md`, the packaging NO). Users symlink `uting` (the human surface) and `ut-play`/`yt-search`/`yt-resolve`/`bili-search`/`bili-resolve`/`ne-search`/`ne-resolve`/`ut-playlist`/`ut-history` (the agent surface) onto their own PATH. **No short name ships** (`docs/ARCHITECTURE.md`) — the human face carries the project's own name, so `~/bin/uting` is a plain symlink with the same word at both ends. A user wanting a short form writes their own alias.

## Runtime Environment (Required)

- **bash 3.2** — macOS's frozen system `/bin/bash`. This is a deliberate floor, not an accident: zero install step, identical behavior under macOS, Linux, containers, CI, and cron/launchd. Do **not** raise it, and do **not** hardcode a Homebrew bash path. See the portability contract below — it is a hard rule.
- Runtime deps, all external and unvendored: `yt-dlp`, `jq`, `mpv`, a unix-socket netcat (BSD `nc` stock on macOS; on Linux any `-U`-capable variant — `netcat-openbsd`'s nc or `ncat` — found by the `resolve_nc_unix` probe in `ut-play`/`uting`), `curl`. `curl` is required by `bili-search` and by both halves of the netease pair (it IS their transport) and optional elsewhere — the YouTube play-time client probe. **`openssl` is engine-local and stays off this list**: only `ne-search` calls it, so a machine without it loses that one command and every other one still runs (`docs/AS-BUILT-engine.md`).
- **macOS first, Linux workable.** The mpv IPC path needs a `-U`-capable netcat; the suite probes for one (`nc` with `-U`, else `ncat`) so mainstream Linux distros work once one is installed. Do not "fix" the remaining gap (`netcat-traditional`/busybox-only hosts) by adding a NEW dependency such as socat — a netcat variant is the same dependency, socat is not. There is no Go escape hatch — `docs/ROADMAP.md`'s recorded NO rules that rewrite out, and Linux was never a reason for it.
- The test suite needs `tmux` (`contract.sh`'s TUI boot check) and nothing else — it is shell all the way down, because a suite whose subject depends only on primitives must not need more than its subject does. Nothing in `tests/` is needed at runtime, and **nothing in `tests/` may be a stand-in for a component** (see the testing rules).
- There is **no** build step, no venv, no lockfile, and no CI. The checks below are run by hand — that is the whole reason they are written out — with two of them gated locally by git hooks:

```sh
git config core.hooksPath .githooks   # RUN ONCE PER CLONE — fresh clones have no hooks
```

`.githooks/pre-commit` and `.githooks/pre-push` are the two gates, and **each one states what it blocks in its own source** — read them there rather than here, because a list in this file is a second copy that goes stale silently. The one thing their source cannot state is an **absence**: a direct push to `main` is **not** blocked — see the commit guidelines.

## Build, Test, and Development Commands

```sh
bash -n shell/*                                              # syntax check — run before EVERY commit
/bin/bash shell/yt-search -j -n 5 -- "lofi hip hop"           # exercise on the 3.2 floor, explicitly
shell/uting "lofi hip hop"                                   # interactive; needs a real TTY on stdin AND stdout
shell/ut-play --help                                          # the player's own help (it is on PATH)
shell/bili-search -j -n 5 -- "周杰伦"                          # the second engine, same envelope
shell/ne-search -j -n 5 -- "钢琴"                              # the third; its rows carry a real `access`
shell/ne-resolve --transcript -j -- 1824020871                # …and lyrics are its caption track
shell/ut-playlist --ls -j                                     # the store: durable, user-level state
UT_STATE_DIR=$(mktemp -d) shell/ut-playlist --ls -j           # …never against the real one, in a test
shell/ut-history --ls -n 20 -j                                # the log: what a player played, written by it
UT_HISTORY=0 shell/ut-play -d -- URL                          # …and the switch that stops it being written
shell/uting --version                                        # answers before any dependency gate

tests/contract.sh --offline                                   # the hermetic half: ~28s, no packet sent
tests/contract.sh                                             # …and the live half too: ~83-99s, 400-403 checks
tests/playback.sh                                             # real detached players; silent, ~88s
tests/drive.sh -x 62 -y 20                                    # drive the TUI, reap the player after
tests/drive.sh -k Enter -w Playing                            # …including a real detached play
```

Each suite runs directly and says in its own docstring what it proves. Read the docstring before changing it.

## Architecture & Core Components

| File | Role |
|------|------|
| `shell/ut-play` | **The player** — play + detached-playback lifecycle, non-interactive, never prompts. Owns the player lifecycle (id / pid / socket / lock / state dir / reap), the **queue** a player consumes (`--queue/--enqueue/--next`; a lone handle is a queue of one, resolved just in time — `docs/AS-BUILT-player.md`), the JSON envelope and the exit-code taxonomy, and **its own flag gate** (one verb, so there is no bypass to defend against). It is also the one process that knows a track ended and why, so it writes the listening row — by calling `ut-history` by name, exactly as it calls an engine (`UT_HISTORY=0` turns it off). **Source-agnostic** — it does not search, does not extract, and carries no yt-dlp call, cookie decision or format string. It asks an engine, by name: `--engine yt` → `yt-resolve` |
| `shell/yt-search` | **The YouTube engine, half one** — query → result envelope. Owns its own yt-dlp call, cookie decision, result shaping and duration formatter, and its own flag gate. Zero playback or lifecycle logic |
| `shell/yt-resolve` | **The YouTube engine, half two** — handle → `{stream_urls[], http_headers{}, title, duration, format, start_seconds}`, plus `--info`, `--transcript`, `--auth` and `--quality` (the (mode, tier) → format-sort table lives here, like the mode→format table). Owns the PO-token probe, the cookie decision, the mode→format table and the yt-dlp error vocabulary. Every site-specific fact in the suite lives in this file or in `yt-search`; adding a source is adding a pair like it |
| `shell/bili-search` | **The Bilibili engine, half one** — query → result envelope, over `curl` + `jq`. It talks HTTP rather than shelling out to yt-dlp because yt-dlp's Bilibili search returns **no metadata at all** (flat) and recurses into every part of every collection (non-flat, >120s for 10 results). Sends no credential: one public endpoint, a Referer, and a locally generated random `buvid3` |
| `shell/bili-resolve` | **The Bilibili engine, half two** — handle → the same resolve envelope, over `yt-dlp`. No request signing, no stream selection, no CDN logic: that is a thousand lines to redo what the dependency maintains. Owns the BV/av handle shapes, the cookie decision, the mode→format table and the (mode, tier) quality table (`--quality` is translated HERE, never in the player); `--info`, `--auth` and `--parts` (the multi-part verb, one HTTP request, no yt-dlp) are here too. No `--transcript` — the site has no captions, and an engine states a missing capability by not having the verb |
| `shell/ne-search` | **The NetEase engine, half one** — query → result envelope, over `curl` + `openssl` + `jq`. It is the only command in the suite that encrypts anything, and it has no choice: the site's plaintext search endpoint now answers an encrypted blob, so the transport is weapi — two AES-128-CBC passes plus a pinned `encSecKey` constant, which is why no RSA runs at play time. `openssl` is therefore an **engine-local** dependency, scoped to this one file and deliberately NOT in the Runtime Environment list: a machine without it loses this half and keeps the other nine. Sends no credential. It is also the ONE engine that can fill `access`, from the site's own `fee`, in the page already fetched — the signal `docs/ROADMAP.md` had been waiting for |
| `shell/ne-resolve` | **The NetEase engine, half two** — handle → the same resolve envelope, over `yt-dlp`; no eapi envelope, no second cipher, no stream ladder of our own. Owns the handle shapes (a song URL, the desktop app's `#/song` fragment route, the mobile share host, a bare numeric id — all canonicalised to ONE url), the song-path gate (every resource on this site is `?id=N`, so a resolver reading the query and ignoring the path plays a different track), the cookie decision, the mode→format table (audio only — the site has no video track) and the (mode, tier) quality table. `--transcript` IS here: lyrics are this site's caption track and cost one plain GET. No `--parts`: one song id is one file |
| `VERSION` | The suite version, declared once — a one-line data file, not a shell variable, and at the **repo root** rather than under `shell/`: it versions the suite, not the script directory. The player and the engines are independent executables sharing no library, so a variable in any one of them would make the others ask *it* for the version — the wrong dependency direction for a player that must not know its engines. Each entry point reads it one level up from its own **resolved** location, so a symlink on PATH still finds it |
| `config` | **The shipped defaults, declared once** — a root data file beside `VERSION`, read as DATA and never sourced, one `KEY=value` per line. It exists because ten independent executables sharing no library would otherwise carry ten inline copies of every default; a user's own file (`${XDG_CONFIG_HOME:-~/.config}/uting/config`, relocated by `UT_CONFIG`) is read first and wins. Chain: flag > environment > user config > this file. Topology and the decision in `docs/ARCHITECTURE.md`. A default belongs HERE, not behind a `:-` in a script. **This file is never written by any command; the USER's file is** — `uting` writes ten keys back to it in place (`docs/ARCHITECTURE.md`) |
| `shell/ut-playlist` | **The playlist store** — durable, user-level, engine-agnostic state: `$UT_STATE_DIR/playlists/<name>.json`, one file per list, `mkdir` lock + atomic temp+mv, six verbs (`--ls --show --add --rm --del --rename`) and its own state-error enum (the two input errors `invalid_name` / `invalid_input` exit 1, the four store refusals `not_found` / `exists` / `locked` / `corrupt` exit 4 — the same 1 vs 4 split the rest of the suite uses). Knows **no site and no playback**: its record is `{engine, url, …}`, which is exactly `ut-play --engine E -- URL`, so a stored record is a CALL, not a reference. Input is stdin JSON only — a search envelope, its own `--show` envelope, or an item array. **The queue is NOT here**: a queue is a playlist being consumed and belongs to the player (`docs/AS-BUILT-player.md`) |
| `shell/ut-history` | **The listening log** — the other half of the durable store, and the only one written by a program: `$UT_STATE_DIR/history/<YYYY-MM>.jsonl`, append-only, three verbs (`--ls --record --clear`). **The one write in the suite that takes no lock** — `>>` is `O_APPEND` and a line under `PIPE_BUF` lands whole — so **every line must stay under 4096 bytes**: the title is truncated to 200 bytes on a UTF-8 boundary and the finished row is then MEASURED. A row is the playlist's item record plus `played_at`/`ended_at`/`seconds`/`reason`, so `--ls -j` pipes into `ut-playlist --add` and `ut-play -d --queue -` unmapped. Knows no site and no playback; the PLAYER decides when a track ended and why (`docs/AS-BUILT-player.md`) |
| `shell/uting` | The human face — ONE self-rendered list, live filter, reflowing pagination, three playback states, en/zh chrome, ASCII fallback, themes. Everything else is a ROW SOURCE that replaces the rows in place and is pressed again to leave: stores (`b`/`h`), a video's parts (`c`, via `<engine>-resolve --parts`) and its chapters (`i`, via `--info`). **Pure orchestration: zero YouTube logic.** No TUI framework, no fzf, and no second renderer |

**Dependency graph — one layer, ten peers. Site knowledge exists ONLY in an engine pair, playback ONLY in the player. An engine's two halves need not use the same primitive: the seam is the ENVELOPE, not the tool behind it:**

```
  ~/bin/yt-search    → shell/yt-search ───► yt-dlp · jq            (engine: query → results)
  ~/bin/yt-resolve   → shell/yt-resolve ──► yt-dlp · jq · curl     (engine: handle → stream URL + headers)
  ~/bin/bili-search  → shell/bili-search ─► curl · jq              (engine: query → results)
  ~/bin/bili-resolve → shell/bili-resolve ► yt-dlp · jq            (engine: handle → stream URL + headers)
  ~/bin/ne-search    → shell/ne-search ───► curl · openssl · jq    (engine: query → results)
  ~/bin/ne-resolve   → shell/ne-resolve ──► yt-dlp · curl · jq     (engine: handle → stream URL + headers)
  ~/bin/ut-play      → shell/ut-play ─────► <engine>-resolve -j ──► mpv · jq · nc   (player)
  ~/bin/ut-playlist  → shell/ut-playlist ─► jq                    (durable state, optional)
  ~/bin/ut-history   → shell/ut-history ──► jq                    (the listening log, optional)
  ~/bin/uting       → shell/uting ──────► (<engine>-search -j | ut-playlist --show -j
                                            | ut-history --ls -j → render
                                            → ut-play -d -j --engine <the ROW's engine>)
                        the player also ──► ut-history --record -  (one row per track ended)
```

The player never runs yt-dlp and mpv never runs it either (`--no-ytdl` + a direct URL): **one extraction, and we make it.** The engine name IS the command prefix, which is what lets the player find `yt-resolve` with a string concatenation instead of a registry.

Each script locates its siblings by a path **relative to its own resolved script location** (self-resolving symlink chain, `cd -P`/`pwd -P` — bash 3.2 has no `readlink -f`), so the checkout can live anywhere and needs no `bin/` entry to work.

**Primitives sit behind seams** (`docs/ARCHITECTURE.md`), and the seams are now split by file: `mpv` behind `run_mpv()` in `ut-play` (single play seam) plus the `mpv_supports_vo()` capability probe; `yt-dlp` only in the engines (`fetch_results` in `yt-search`; `dump_once`, `resolve_info`, `resolve_transcript` in `yt-resolve`; `dump_once`, `resolve_info` in `bili-resolve` and in `ne-resolve`); the hand-built HTTP seams are `fetch_page_once` in `bili-search` and in `ne-search`, `fetch_view_once` in `bili-resolve` (`--parts`) and `fetch_lyric_once` in `ne-resolve` (`--transcript`) — the only four places in the suite that build a request by hand; `openssl` is behind `weapi_params` in `ne-search` and nowhere else in the suite; `curl` also backs `probe_raw` in `yt-resolve` (the fetchability probe); `jq` pervasive. Keep new primitive calls inside the existing seams — and a yt-dlp call in `ut-play` or an mpv call in an engine is a layering violation, not a seam.

**Governing principle: correctness is added *down* — in the player if it is about playback, in the engine if it is about a site — so every surface inherits it, never *up* in a UI.** A fix in `uting` that `ut-play` could have made is a bug in the wrong file.

## Hard Rules

### 1. The bash 3.2 portability contract (enforced at review)

`bash -n` and shellcheck do **not** catch this class — these are runtime version behaviors. Only executing under `/bin/bash` on 3.2 does.

```
  Forbidden (bash 4+):  declare -A · ${var,,} / ${var^^} · mapfile/readarray ·
                        ${arr[-1]} · &>> · |& · ${!prefix@}
  Empty array + set -u: a bare "${arr[@]}" on an EMPTY array ABORTS on 3.2. Use
                          ((${#arr[@]})) && cmd "${arr[@]}"      (guard, as in the core)
                          cmd ${arr[@]+"${arr[@]}"}              (inline, as in uting)
  Arithmetic + set -e:  a bare ((expr)) is a COMMAND whose status is 1 when the
                        expression evaluates to 0 — under set -e that aborts. Never
                        ((n += w)) as a statement; write n=$((n + w)). ((x)) as a TEST
                        (in if / && / ||) is fine — there the status is the point.
  read -rsn1 = one BYTE, not one character. A CJK keypress arrives as 2-3 "keys", so any
                        reader accumulating keypresses must reassemble the UTF-8 sequence
                        from its lead byte (uting's utf8_complete). Classify the lead
                        byte by TABLE MEMBERSHIP the way char_w does — `LC_ALL=C [[ … ]]`
                        is not valid bash at all, and a ( LC_ALL=C … ) subshell forks per
                        keypress and cannot set a global.
  ${var//pat/} is O(n2): pattern SUBSTITUTION is quadratic on 3.2 once the string holds one
                        match (measured: 7KB envelope = 17s; no match at all = 5ms, which is
                        why it reads as free). A blank-input test is a MATCH, never a
                        substitution: [[ "$s" == *[![:space:]]* ]] / [[ "$s" != *[![:space:]]* ]].
                        There is no `${var//` left in shell/ — keep it that way. Anchored
                        strips (${v#pat} / ${v%pat}) are unaffected — see ARCHITECTURE.md's
                        portability contract.
  read -s is per-read:  it restores echo after ONE read, so the driver echoes whatever is
                        still queued between reads (a paste, a fast multi-byte char). A UI
                        that draws its own input owns the echo for the whole session
                        (stty -echo) and restores it from the same trap as the cursor.
```

If a feature genuinely needs bash 4+, the honest move is `((BASH_VERSINFO[0] >= 4))` at the top with a `brew install bash` hint — never a hardcoded interpreter path.

### 2. One fact, one place — and docs hold why/how, never what

Each fact lives in exactly ONE place; everything else points at it. **The durable docs — `ARCHITECTURE.md` and the as-built files — are for human engineers and hold *why* and *how* — never *what***: flags, envelopes, defaults, key tables and function inventories are already stated by the source, by `usage()`, and proved by the test suites, and restating them there is a violation (a `PLAN-` is different; see the SDLC section). **One carve-out, and it is narrow: the 「接口与 API」 section of an as-built doc carries the CALLING SURFACE** — worked invocations, which options combine, and which combinations are refused and with what exit code. That is the one *what* a reader cannot assemble from `usage()`, because a flag list states each flag's meaning and says nothing about the product of them. It is bounded: the calling surface, not the flag list, not the envelope fields, not the defaults, not a function inventory — those stay out. And it is bounded a second way: **every line written there must be a check first — the refusals AND the runnable invocations alike.** A refusal is a check on its message or its exit code; a worked invocation is a check that RUNS that argv, verbatim, and asserts it was accepted. Where the real call needs the network, replace only the half that does — with a fixture, meaning data a real command reads, never something that runs in place of one — and where even that is impossible, mark the line **「实测」** rather than 「已证」 and say in one sentence why it cannot be proved. The direction is fixed: **the check is the authority and the doc is its reader's view**, so when the two disagree the doc moves. Prose that no suite holds reports green by default; a runnable line nothing runs is the same failure wearing a more convincing costume — measured on 2026-09-01, when the first pass over these blocks found a documented `uting --lang zh` whose flag had never existed. Cite a doc by **filename, plus a heading name when the file is large** — plain greppable headings, no section-number scheme, no index to maintain. The version is declared once, in `VERSION`; each entry point reads that file and prints its own name, so the entry points can never disagree.

### 3. Scratch stays under `tmp/`

`.gitignore` carries `**/tmp/`. All throwaway scripts, captures, and probe output go there — never the repo root, never `tests/`. A throwaway check graduates into `tests/` only when it earns a permanent place, and then it gets a docstring saying what it proves. Consequently **no doc names a scratch check by path**: a cited scratch path is a promise the checkout cannot keep. Record the *shape* of a check, not its filename — and a check's own home is its line in a suite, not a doc.

### 4. The contract is frozen surface

The single-line JSON envelope, the player record, the exit-code table (0 ok / 1 usage / 2+ propagated tool failure / 4 didn't take effect), and the lifecycle semantics (launch → status → stop, idempotent stop, ambiguity → 4) are the one thing that survives any rewrite. The surface's normative statement is the code itself — each command's `usage()` — and `tests/contract.sh`, which proves it; `docs/AS-BUILT-cli-contract.md` holds only the *why* of the surface's shape and the semver boundary (what counts as public API). Changing the surface is a deliberate, documented act — never a side effect of a feature.

<important if="you are adding, changing, or judging a check in tests/">

## Testing Guidelines (HARD RULE — enforced at review)

**Functional tests only.** A command-line tool is tested by running it and reading its exit code and its stdout. There is no rig layer, no screen model, no pty harness and no unit tier: every check invokes a real entry point the way a caller does, and asserts on what came back.

Two files, one rule:

| File | Drives | Gate |
|---|---|---|
| `tests/contract.sh` | every command's argv, exit codes and `-j` envelopes; the playlist store AND the listening log under a disposable `UT_STATE_DIR` (including an 8KB title, because the 4096-byte line is the premise the lock-free append rests on); the host gate across every discovered engine; the row model's own premise — a row is a playable call, so a row either has a duration or says why it has none — over EVERY live search envelope the file already paid for, on every discovered engine, which is what keeps it from going vacuous on a query that happens to carry no container; the `--parts`/`--quality`/`--start` gates (capability by absence, the stream-format gate, bogus tiers and a non-second offset at the door); the idle lifecycle and the death record; three of the four cross-command pipelines `docs/AS-BUILT-cli-contract.md`「调用面」 prints, run rather than printed (the search half replaced by a fixture envelope, which is data a real command reads — not a stand-in that runs in place of one); the TUI's boot / resize / quit under tmux, that a notice is frame content rather than a modal (the key after one does its own job), the parts row source on whichever installed engine HAS `--parts` (discovered, never named), and that it left no player behind when it went | none — `--offline` before every commit (~28s, 258 checks, hermetic), the whole thing before every push (~83-99s, the spread being how far the two row-source walks have to go; the total is 400-403 because four checks report only when a walk meets the row they need — 0 failed is the number that means passing) |
| `tests/playback.sh` | detached players end to end (launch → status → mutate → stop → stop again), the **live read off a real mpv socket** (the peer has no stand-in, so the claim lives here), that an engine's `http_headers` actually reach mpv, the two claims the offline half can never reach (`status:"ambiguous"`, which needs two live players, and the fourth documented pipeline — a real `ut-playlist --show -j` envelope launching a real `--queue`), and the listening log's **wiring** — only here does a real track really end | none — it starts real players, but in a `TMPDIR` and a `UT_STATE_DIR` of its own; ~88s and needs the network, so run it when the player changed |

`tests/drive.sh` is the only other file, and it is not a suite — it asserts nothing. It is a
**driver**: it launches the TUI in tmux at a declared geometry, waits on the ready marker, optionally sends keys, and **always reaps the detached player** — which killing the tmux session does not do. Use it whenever a TUI change has to be driven rather than reasoned about.

### Harden before you extend

The default move on a gap is to make an **existing** check stronger, not to add a file. A check that drives one engine when the function behind it is duplicated across engines is a *weak* check, not a missing one — state the claim as an invariant over all **discovered** engines (`<name>-search` + `<name>-resolve` pairs, the registry `uting` already builds) and engine #3 is covered the day it lands. A new check earns its place only by naming a production failure no existing check catches; if you cannot name one, harden instead.

### Reject a check when it:

- asserts on an internal function or a private helper instead of invoking the command;
- **introduces a mock, a fake, a stub or a stand-in of any kind — no exception, including for a peer.** There is exactly one legitimate thing this suite may author: a **fixture**, meaning *data a real command really reads* (a state file for the reaper, a search envelope on `ut-playlist`'s stdin). The moment something in `tests/` *executes* in place of a component — a scripted socket peer, a `sleep` posing as a live pid, a shimmed binary on `PATH` — it is a mock and it does not land. The rule is not "fake the peer, never the subject": it is **no fake at all**. A claim that needs a real peer is proved where the real peer runs (`playback.sh`), or it is not proved. Coverage a real dependency cannot be made to produce on cue is coverage this suite does not have, and saying so is honest; a green check against a scripted peer is not;
- asserts on a rendered **picture** — cell grids, column alignment, glyph widths. Layout is proved when a frame enters a doc, and the `capture-pane` skill owns that; the suite asserts survival, not shape;
- exists only to raise a count, or asserts a default that a behavioural check already exercises;
- times a network-dependent path against YouTube when a local synthetic source (`av://lavfi:sine`) would do — throttling corrupts a timing measurement, and a red that is the network's fault still costs someone a look;
- **cannot fail** — meaning no input reaching it separates a correct implementation from a plausibly-wrong one. The way to settle that is to **find the discriminating input and land it as the check**, not to break the subject and watch it go red: ask what a naive implementation would get wrong, then feed exactly that. `<ENGINE>_COOKIE_BROWSER=definitely-not-a-browser` is the worked example — not `"none"`, yet no profile can exist, so only an engine that really checks the profile answers `anonymous`, while the env-var-alone shortcut answers `cookie` and goes red. Mutating tracked files to prove a point is **not** how this is done: the restore step is a step that can be skipped, and once was — an interrupt landed between the mutation and its `cp` back, leaving a broken engine in the worktree. A discriminating input costs nothing, leaves the tree untouched, and stays in the suite as coverage instead of evaporating.

### Accept a check when it drives a real surface:

`bash -n` on every script in `shell/`; a real `-j` invocation whose envelope is parsed; the exit code of a real failure path; a real unix socket with real mpv on the far end (`playback.sh`); the TUI under tmux asserted on survival — it booted, it is still up after a resize, it left on `q` with 0.

</important>

### Minimum checks before every commit

**The two suites in `tests/` ARE these checks.** A check that exists only as prose for someone to copy out reports green by default. A new check goes in the suite, never in a doc — and a fixed command sequence goes in a script, never in prose.

- `/bin/bash -n shell/*` — enforced by `.githooks/pre-commit` on staged content and by `pre-push` on the worktree, so this is a backstop for a `--no-verify`, not a habit.
- **Any change at all:** `tests/contract.sh --offline` (it also drives the empty-argument paths on the 3.2 floor) — every gate, both stores, the lifecycle and the death record, in ~30s with nothing fetched, because a gate that cannot run without YouTube is a gate that gets skipped. **Before every push, the same file with no flag**: `--offline` is a prefix of that run, never a substitute for it. It starts no process it did not have to and talks to no peer — every live claim is `playback.sh`'s.
- **Any change to the detached player:** `tests/playback.sh`. It starts real players (silent, `--volume 0`, in a state dir of its own) and does not pass until `pgrep` finds none of them left.
- The shellcheck baseline is a tracked count, not a clean bill — `docs/RESEARCH-tui-player.md`.

<important if="you are making a structural change — moving logic between files, retiring a path, or adding a surface">

## Safe-Evolution Methodology (how this suite is changed)

Any structural change follows a staged, reversible order:

```
  A  Build the new path against the CURRENT tools and validate it in a tmux pty
     → an interactive path is never absent.
  B  Repoint callers / wrappers / symlinks; run the headless regression.
  C  Delete the old path — the destructive step, kept LAST and small; grep-gate every
     removed symbol before deleting it; regress again.
  D  Update docs (docs/ARCHITECTURE.md, README.md, usage()).
  E  Final headed (tmux) + headless sweep.
```

Principle: put the single destructive step last and smallest, prove its replacement first, and gate deletions by grep so no dangling reference survives.

</important>

<important if="you are planning, pre-morteming, or landing a unit of work — anything that touches a docs/PLAN-*.md">

## How a Unit of Work Moves

```
 (roadmap) ──► plan ──► pre-mortem ──► build ──► verify ──► land
   entry:      PLAN-    PLAN-        (A→E if   (the two   (checklist; as-built
   decided,   authored  hardened     structural) suites)   docs resynced,
   sequenced                                               PLAN- deleted)

  ...off the pipeline, on their own cadence: research feeding the roadmap, and the
  whole-tree conformance audit.
```

Interrogation and design are activities inside authoring the `PLAN-`, not stages of their own;
the as-built docs are touched only at land. Each stage is bound to a discipline below. The
disciplines are normative for the work itself; the agent skills that automate them are
conveniences the checkout does not depend on.

- **An idea is interrogated before it is designed.** An adversarial interview, not a monologue: questions in dependency order, each with a recommended answer; facts are looked up — a contract claim is executed, never read — and only decisions are asked. What settles is distilled into the `PLAN-` **before the conversation ends**: a decision that lives only in a conversation does not exist.
- **Design speaks the seam vocabulary, and this repo's doctrine outranks generic instinct.** Interfaces here are envelopes, seams are the swap points `docs/ARCHITECTURE.md` lists, and depth is judged by what a caller gets per fact they must learn. Explore 2–4 deliberately different shapes before committing. Where generic advice points at a shared library or a mock, the carve-outs above win.
- **A plan is pre-mortemed before it is built.** The plan text *alone*, without its authoring context, goes to a cold reader who writes its failure retrospective; each preventive fix is accepted into the `PLAN-` or explicitly rejected. The cold read is the point — a critique from the session that wrote the plan inherits the plan's assumptions. The user-level `discuss-with-me` skill runs exactly this: a standalone brief → a fresh subagent that gets the brief and nothing else → numbered preventive fixes → settled in rounds, one decision at a time. Its round rule also governs the interrogation above: ask only what can be answered now, and a fix that is neither accepted nor refused is an open question, not a footnote.
- **A build is incremental, or it is staged.** Small edits in place for ordinary work; the A→E order above the moment the change is structural — moves logic between files, retires a path, adds a surface.
- **A bug gets a red loop before it gets a theory.** No hypothesis until one command exists that goes red on the exact symptom — fast, deterministic, agent-runnable. The harness lives in `tmp/`; the regression check lands in whichever suite owns the surface; the hypothesis that proved out is stated in the commit message.
- **An initiative descends from the roadmap — the ADLC's root; research is external to the ADLC, not a stage of it.** Outside-world questions are answered against primary sources and land as `docs/RESEARCH-<topic>.md` with each claim cited, on their own cadence; what enters the lifecycle is the roadmap entry the research led to. The `PLAN-` names the roadmap entry it implements, never the research doc.
- **A landing is a checklist, not a feeling.** The unit of work closes against the document that authorized it, atomically: every plan item landed or explicitly deferred, every `done_when` executed rather than read, accepted pre-mortem fixes verified in, review findings resolved, the as-built docs resynced, the `PLAN-` deleted, the version judged. Skipping the housekeeping half means the work has not landed — the code is merely present. Landing closes the unit of work, not the code's liability: that stays with `docs/ARCHITECTURE.md`'s risk register and the audit below.
- **A session ends by sorting its residue.** Durable state — settled decisions, work-in-progress position — goes into the in-flight `PLAN-` before the session closes; only conversation-shaped remainder goes to a `tmp/` handoff note. The dividing line: if it still has value after the next session consumes it, it is not handoff content.
- **Accretion is audited, not watched for.** Diff review catches what a change introduces; the whole-tree sweep (`/audit-conformance`) catches what accumulates between changes. Its cadence and rules are its own skill's.

</important>

<important if="you are writing or resyncing a doc under docs/ — a PLAN-, an AS-BUILT-, ARCHITECTURE.md, ROADMAP.md or a RESEARCH-">

## SDLC & Architectural Documentation

**The durable docs — `ARCHITECTURE.md` and the as-built files — are for human engineers, and they hold *why* and *how* — never *what*.** The what — argv, envelopes, exit codes, defaults, key tables, function inventories — is already stated by the source, by each command's `usage()`, and proved by the test suites; restating it in a durable doc is a violation, with the single 「接口与 API」 carve-out hard rule 2 defines (the calling surface — worked invocations and refused combinations, each backed by a check). A paragraph earns its place only by saying something the code cannot: a decision and the alternative it rejected, a rule forced by a dated measurement, an invariant that spans files, a pitfall that cost a debugging session. When a doc and the code disagree, the code is right and the doc is the bug.

**`PLAN-` is different — it serves both human engineers and coding agents.** A plan is the bridge from design all the way down to implementation specs, written so a coding agent can write the source with minimal confusion and ambiguity: core processing logic, API contracts, envelope fields, logic specs, edge cases, the verification matrix. It **tracks the real source-code implementation and its validation** as they land. That precision is its job, and it never becomes a duplication liability because the plan is **deleted at land** — what survives into the durable docs is only the why.

**No global numbering or indexing.** Headings are plain and named, reordered freely; a citation is a **filename, plus a heading name when the file is large** — resolved by grep, not by an index. No section-number scheme, no inherited numbers, no tombstones, no stable citation keys: maintaining an index forever costs more than the stale reference it prevents, and grep finds those in seconds.

**The agentic DLC has three stages and the roadmap is its root: roadmap → plan → as-built.**
The prefix says which stage a file is in. **Research is NOT an ADLC stage** — it is an
outside-world activity on its own cadence whose findings land as roadmap entries; a
`RESEARCH-` doc is the evidence behind those entries, feeding the lifecycle from outside it.
A doc that stops moving is a doc nobody trusts, so each names what ends it:

| Stage | Prefix | What it holds | What ends it |
|---|---|---|---|
| *(external — feeds the roadmap, not an ADLC stage)* research | `RESEARCH-<topic>.md` | surveying the world **outside** this repo — what comparable projects do, measured data, comparisons. Says nothing about what we will build | **distil the DECISION into a decision record** — `ARCHITECTURE.md`'s decisions when something is adopted, `ROADMAP.md` when the answer is a recorded NO or deferred work — filtered by relevance and business need; the survey itself stays here as the evidence, dated, and is re-run or deleted when its measurements go stale — the decision records hold decisions, never data |
| roadmap | `ROADMAP.md` | the still-open ledger: recorded NOs (each with its reason and reopen condition), reopen triggers for settled decisions, and work not done yet. **Landed decisions are NOT here** — they live in `ARCHITECTURE.md`'s decisions and the as-built docs; neither are positioning and non-goals nor the analysis behind the decisions. An entry is cited by name ("the packaging NO", "the Go-rewrite NO"), never by a key | nothing — it is the one doc that outlives a rewrite |
| plan | `PLAN-<topic>.md` | one feature, from open question to built — **for both human engineers and coding agents: the bridge from design down to implementation specs**, precise enough that a coding agent writes the source without ambiguity: options and trade-offs are explored **during its authoring** (design is an activity inside this stage, not a doc class), then the core processing logic, the API contract (fields, flags, envelopes, exit codes), logic specs and edge cases, and the verification matrix. **Tracks the real implementation and its validation** — the status line and per-item state are updated as code and checks land | **the why is distilled into the as-built docs as it lands, then the plan is deleted** — gone, not archived; its implementation-level detail dies with it, because from then on the source states the what |
| as-built | `ARCHITECTURE.md` + `AS-BUILT-<scope>.md` | why the code is the way it is and how it hangs together — a description that chases the code, never a promise the code chases (which is why the prefix is not `SPEC-`: "spec" reads as a normative document implementations conform to). Every fact in exactly ONE place, and never a restatement of what the source, `usage()` or the suites already say | never; it is **resynced at land, after the code stops moving** — never edited ahead of the build |

Today there are **five** as-built docs, and — like everything else under `docs/` — **all five are
written in Chinese**; this file and the README are the English surface. `docs/ARCHITECTURE.md`
is the umbrella a newcomer opens first — the why of the whole suite — and **four** per-scope docs
carry the per-module why, each sized by its measured content: a scope earns its own file only
while its why outgrows a chapter of the umbrella, and **folds back when it shrinks** — which is
exactly what the verification doc did (its risk register is now a chapter of the umbrella; what
proves a check, and what deliberately proves nothing, belongs to the suite that runs it). The **process** — how a unit of work
moves through the repo — is not one of them: it lives in this file, above. The rule that keeps
the family honest is the one that already governs a single file: one fact, one place,
everything else points at it. **The taxonomy is closed**: work in flight is a `PLAN-`, work
landed is as-built — no further doc class is introduced.

**Every `AS-BUILT-<scope>.md` opens with the same two sections, in this order, then the why
chapters:** 「模块功能和结构」 (Module function and structure — what the scope is made of and
the map of this doc, together with its boundary and isolation: what this module owns, what it
deliberately does not, and the layering rule it enforces. **This section MUST carry one
diagram**: an ASCII block in the style `ARCHITECTURE.md` already uses, showing the scope's
parts — files, processes, stores, seams — and the edges between them, so a reader sees the
shape before reading the why. A rendered terminal frame is not that diagram; it belongs to
`capture-pane`), 「接口与 API」 (Interface and API —
its surface, its shape, and how it is actually CALLED: the verbs and envelopes by name,
pointing at `usage()` / `tests/contract.sh` / `AS-BUILT-cli-contract.md` for the shapes rather
than restating them, plus the calling surface hard rule 2 carves out — worked invocations,
the options that combine, and the combinations that are refused with their exit code, each
one backed by a check in `tests/contract.sh`). `ARCHITECTURE.md`'s first three sections are
the suite-level mirror: the mission and design goals, the system panorama, and the design
decisions grouped by module — the hub whose spokes are the per-scope docs.

**`docs/` is FLAT — the prefix is the only grouping, and no subfolder is ever created.** The
stage is already encoded in the filename (`RESEARCH-` / `PLAN-` / `AS-BUILT-`), so a
`docs/as-built/` would be a second spelling of a fact the name already carries — and every
citation in this file, the README and the scripts is a one-level path. `ls docs/` is the index.

`PLAN-`, not `TODO-`, for the third stage: a plan **carries work-in-progress state** — it is
updated as items land and is only deleted when the last one has — whereas a todo is a list of
things not done, with nowhere to record that three of five now are. The stage needs the former.
(`TODO-` is also doubly spoken for: an agent's own in-session task list, and `// TODO` comments.)

The live files:

- `docs/ARCHITECTURE.md` — the umbrella: **positioning, the differentiators and the non-goals, plus the findings the roadmap's decisions rest on** — ask it before adding a feature — then topology, seams, control-flow diagrams, the design decisions grouped by module and interface, the known constraints, the **risk register** (the known ways this goes wrong, what defends each, and the accepted residual risks) and the bash 3.2 portability contract. Diagrams, flows and decisions — why and how only. **Kept in sync on every change that touches architecture or a contract.**
- `docs/AS-BUILT-cli-contract.md` — why the CLI contract is shaped the way it is, and the semver boundary: what counts as public API and what does not. The shapes themselves live in `usage()` and are proved by `tests/contract.sh` — this doc explains them, it does not restate them.
- `docs/AS-BUILT-engine.md` — the site half: why each engine is shaped the way it is — query shaping, the two hand-written transports and why each site forced one, the login / PO-token probe, the weapi cipher and its engine-local `openssl`, handle grammar and the host allowlist. Every site-specific fact belongs to an engine or it is a layering violation.
- `docs/AS-BUILT-player.md` — the player, the queue and the two durable stores: the process-group model, the state machine and the death record, the lock-free append, and the measurements that forced each rule.
- `docs/AS-BUILT-tui.md` — the human face: the rendering model, the width layer, the reflow, the focused row's cover art (the kitty-protocol emitter, its budget gate and the three ways drawing a picture broke the TUI), and the rules pinned by measurement.
- `docs/ROADMAP.md` — **only what is still open: recorded NOs (each with its reason and its reopen condition), reopen triggers for settled decisions, and work not done yet.** No changelog, no landed work, no survey data, and no positioning — landed decisions live in `docs/ARCHITECTURE.md`. **Its recorded NOs, worth knowing before proposing them again, by name:** the packaging NO (reference implementation — no installer, no `v*` tags), the Ximalaya NO (a fourth-pair candidate; that site's `m` endpoint needs a per-request `webtk`), the `list=` NO, the `--vo-tct-algo=plain` NO, **terminal images via mpv's VO** (it clears the screen and ships uncompressed frames — the route is dead, and the FEATURE shipped 2026-09-03 down a different one, emitting the kitty protocol itself: `docs/AS-BUILT-tui.md`「封面」. It still pins one adjacent no — chafa / img2sixel / kitty `icat` are new runtime dependencies — while its old "the thumbnail URL is not a contract gap" clause is retired: the engines now project a normalised `thumbnail`, because three sites hand out three different shapes and letting a consumer learn them moves site knowledge out of the engine), the keybinding-registry NO, the terminfo-truecolor NO, **the Go rewrite (closed entirely, TUI and player alike: the differentiator is the contract and the contract is language-independent; it reopens only for MCP or single-file distribution)**, and **the `ut-search` NO (re-evaluated and reaffirmed as NO on 2026-09-03 after NetEase landed — container rows diverge envelope shapes across engines, and callers can already loop across engines).** Every feature must ship an **agent surface** (a verb plus a `-j` envelope) alongside its keybinding — a TUI-only feature is half a feature here.
- `docs/RESEARCH-tui-player.md` — the broad survey the suite's recorded decisions rest on. It opened as one half **measured**, one half **read, not run**, and it still says up front which is which — but the 2026-09-03 pass promoted the load-bearing half of the read side to **measured or source-verified** (stream-URL lifetimes on all three sites, go-musicfox's mpv IPC, termusic's gRPC), so what remains merely read is labelled as such rather than assumed. Every figure is dated; **re-run the method before reopening anything it settled, and where a claim is still only read, treat it as a pointer to its source.**
- `docs/RESEARCH-terminal-graphics.md` — the narrow one: showing pictures in a terminal. Same two-half discipline; its measured half is **host-specific** (mpv build, tmux version, terminal), so re-run it on the machine asking rather than citing the numbers. It is the evidence behind the mpv-VO route being a NO **and** behind the cover art that shipped without it (`docs/AS-BUILT-tui.md`「封面」).
- `docs/PLAN-*.md` — whatever is ready to build or in flight, with its progress recorded inline. Empty is a valid state.
- One repo, one README: there is deliberately no `tests/README.md` — the two suites are described in the root README's `## Tests` section and in their own docstrings.

</important>

<important if="you are adding or invoking an agent skill, or a terminal frame in README.md or docs/ has gone stale">

### Agent skills

**Skills live in `.claude/skills/` — nowhere else.** Claude Code discovers project skills only there (plus `~/.claude/skills/` and plugins); a skill parked anywhere else is invisible and will simply never be invoked. **A skill is for work needing judgement; a fixed command sequence is a script.** Two exist:

| Skill | Use it when |
|---|---|
| `capture-pane` | A terminal frame in `README.md` / `docs/ARCHITECTURE.md` is stale. Capture → clean (`clean_capture.py`, which refuses a mid-fetch frame) → **prove with the skill's own `assert_pane.py`** → splice with a Python replace. Never hand-draw a frame |
| `audit-conformance` | Periodically, not per-commit. Whole-suite scan against 13 rules (surface layering, DRY, bash 3.2, dead code, swallowed errors, terminal ownership, stale prose defending a retired mechanism, contract and doc drift) → `docs/PLAN-conformance-YYYY-MM-DD.md`. Ships `fn_graph.py` (defs vs call sites across every script in `shell/`) as a manual aid — **never** as a gate or a `tests/` member |

A skill may propose a *structural detector as a manual aid*; it may never propose one as a test. The functional-only mandate above binds skills too — and layout proving lives in `capture-pane`, deliberately outside the suite.

**Those two are the checkout's. Two of the disciplines above are automated by USER-level skills that are deliberately not vendored here** — `discuss-with-me` (the pre-mortem, and the round-based settle loop the interrogation borrows) and `land` (the landing checklist) live in `~/.claude/skills/`, both user-invoked only. A fresh clone has neither, and every discipline above still stands without them: they automate the work, they are not the authority on it. The other disciplines — the red loop before a theory, the A→E staging, research on its own cadence — have no skill by design, and a norm that should always apply is a line in this file, never a skill.

**Driving the TUI is not a skill, it is `tests/drive.sh`.** Launching at a fixed geometry, polling the ready marker, sending keys and reaping the detached player are mechanical, and a mechanical sequence written as prose is a runner nobody executes the same way twice.

</important>

## Coding Style & Naming Conventions

- Match the surrounding style: 4-space indentation, `snake_case` functions, `UPPER_SNAKE` globals, `local` for everything inside a function, `set -euo pipefail` semantics respected (see the arithmetic rule above).
- **One name per command, and no second spelling of any of them.** `ut-play`, `yt-search`, `yt-resolve`, `bili-search`, `bili-resolve`, `ne-search`, `ne-resolve`, `ut-playlist`, `ut-history`, `uting` are the canonical identity — help text, errors, docs, and the PATH entry itself. The suite ships **no short form** (`docs/ARCHITECTURE.md` — the short names are taken on npm/PyPI/crates, and a second official spelling is a second thing to keep in sync). A user wanting one writes their own alias. Never add a second name for an existing command.
- Per-request choices are **flags**; set-once tuning is a **configuration key** — suite-wide `UT_*`, per-engine `YT_*` / `BILI_*` / `NE_*` (the prefix is also what makes a name config-reachable, so a constant must not wear one — and a new engine's prefix has to be added to the `ut_read_config` regex in EVERY entry point, which is duplicated verbatim, or its keys are silently unreadable). It resolves through four levels — flag > environment > the user's config file > the shipped `config` — and its default is declared once, in `config`, never behind a `:-` in a script. The keys are enumerated by the shipped `config` itself. This keeps each verb's flag surface narrow enough for a small model to call safely; do not add a flag for something a user sets once.
- Never add a runtime dependency. The suite's differentiator is that it depends only on primitives everyone already has.
- Prefer small, incremental edits in the existing scripts over refactors that move logic between files.

<important if="you are about to commit, push, tag, or bump VERSION">

## Commit & Pull Request Guidelines

- **`main` is the working branch** — linear, no merges, single author. Commit straight to it for ordinary work; take a branch when the change is structural enough to want the staged A→E order below, or when it may need to be abandoned. No stacked branches.
- Imperative, scoped commit subjects in the existing style — the file or surface first when it helps: `uting: stop Enter stalling a second in utf8_complete`, `add --version, declared once`, `docs: resync DESIGN with the detached-playback TUI`.
- One logical change per commit. Renderer changes come with the proved capture (`capture-pane`) that shows them.
- `bash -n` on every script in `shell/` before every commit; `tests/contract.sh --offline` with it, and the full `tests/contract.sh` before every push.
- **Always ask before `git push`.** Never force-push `main`.
- **Versioning is semver 2.0.0 over the CLI contract, not over the code** (`docs/AS-BUILT-cli-contract.md` opens with what counts as the public API). While the suite is `0.y.z`: a breaking change bumps **y**, an addition or a fix bumps **z**. `VERSION` is bumped deliberately, **alone, in its own commit**, and never once per commit. There is no release process to run and no CHANGELOG: the suite is not packaged (`docs/ROADMAP.md`), so a `v<VERSION>` tag is for a real release only — `1.0.0` waits for the packaging NO to reverse.

</important>

## Security & Configuration Tips

- The suite runs **unprivileged**. Never introduce `sudo`, a persistent privileged process, or unsafe temp-file handling.
- Player state lives in a per-player state dir with a lock; `players/` holds only `<id>.json` — **no bare token or credential may ever land there**, and the detached mpv log must not grow unbounded.
- Cookies are read from a browser profile via `YT_COOKIE_BROWSER` and presence-checked per platform; if absent, extraction runs anonymously rather than breaking. Never log a cookie path's contents or an extracted token.
- Secrets and credentials belong in `~/env-secrets/`, never in the repo.
- Anything that shells out to `yt-dlp`/`mpv` passes arguments as an array, never through a re-quoted string.
