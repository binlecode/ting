#!/usr/bin/env bash
# Real detached playback: the one surface whose bugs are PROCESSES, not output. Everything
# here starts real mpv players — silent (--volume 0), in a state dir of their own, and the run
# does not pass until `pgrep` comes back empty: a leaked mpv is the failure this file exists
# to catch.
#
# No gate. It used to sit behind YT_TEST_LIFECYCLE=1 because starting players meant starting
# them ON TOP OF the user's — --stop --all reached whatever they were listening to. The state
# dir below removes that, and what is left is a run that needs the network — a reason to run it
# when the player changed, not a reason for an env var to guard it.
#
# It also owns two claims contract.sh's offline half can never reach, both for the same
# reason — they need players that are really running: that a mutation with no `--id` and two
# players answers `status:"ambiguous"` (4 alone does not separate it from an idle call), and
# ARCH-cli-contract.md「调用面」's `ut-playlist --show … -j | ut-play -d --queue -`, run
# verbatim — contract.sh proves that envelope reaches the gate, this is where it launches.
#
# Cost: **~93s / 59 ok** (2026-09-04; 82s/51 ok on 2026-09-01, before the live read grew the
# media facts and the count drifted), and it is real work
# rather than waiting. The breakdown is the older 62s run's (2026-08-26) and still names where
# the time goes: roughly 30s is seven live engine resolves (ut-play:530 records the measured
# median between tracks at 4.3s) and ~19s is the listening-log section playing a 19-second
# track out to its own end rather than seeking there — that section cannot seek, because
# `duration` is null on a live stream and a check must not go green or red on whether the
# fixture was streaming that afternoon. Neither half is reducible without a stand-in, and this
# file has none. The rest is the sites', which is why the total is quoted as a range and the
# parts are not re-attributed without being re-measured.
#
# EVERY WAIT HERE IS A BOUNDED POLL. There are exactly two fixed sleeps left and neither is a
# wait — both are SETUP, and both say so where they sit. Three others were `sleep 1`/`sleep 2`
# guesses at conditions the code can observe (the record empty, pgrep at zero); they became
# polls on 2026-08-26, which took the run from 68s to 62s. Speed was the smaller half: a fixed
# guess also goes red when the machine is merely slow, and a red that is not a bug still costs
# somebody an investigation.
#
# And it carries the one claim that needs a SECOND source: that the player applies the
# http_headers an engine hands it. See the Bilibili section for why only that site can show it.
#
# It also owns the LIVE READ (--status off the mpv socket), for the same reason: the peer is
# real mpv or it is nothing. The suite keeps no stand-in for a component, so a claim about
# talking to mpv can only be made where mpv is running — which is here, and only here. That
# now includes `media` — what is actually decoding — which exists in no record and in no
# engine envelope at all, so this file is the only place it can be proved to exist.
#
# Portability: bash 3.2. Needs jq for the envelopes; no tmux and no terminal — every
# assertion here is an exit code or a field out of a real envelope.
#
# Usage:  tests/playback.sh
# Exit:   0 = every check held, 1 = at least one failed

set -uo pipefail
REPO=$(cd -P "$(dirname "$0")/.." && pwd -P) || exit 1
cd "$REPO" || exit 1

# ---- a state dir of this file's own -------------------------------------------------
# Why, once, for all three files under tests/: contract.sh's header. Here it earns
# the sharpest form of the same sentence — every --stop --all below would reach the player the
# user is listening to, and every orphan count would be a count of THEIR mpv.
UT_TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/uting-playback.XXXXXX") || exit 1
export TMPDIR="$UT_TEST_TMP"
STATE_DIR="$TMPDIR/uting-$(id -u)"

# And the USER-LEVEL store, for the same reason one line up but a longer-lived consequence:
# a detached player writes a row to the listening log for every track it finishes, so without
# this every run of this file would append a dozen tracks nobody listened to into the user's
# real history — and unlike a player, a log is not something --stop takes back.
export UT_STATE_DIR="$UT_TEST_TMP/state"

# AND THE USER'S OWN CONFIG FILE, which is the third thing this run must not read — the one
# that was missed. Every default this file leans on comes from the four-level chain, and the
# user's own file wins over the shipped one: a `UT_DEFAULT_ENGINE=bili` written there by
# `uting`'s own e key (it writes that key back) sends every YouTube handle below to
# `bili-resolve`, which refuses the host, and 23 checks go red saying nothing whatsoever about
# the player. That is not hypothetical — it is what this file did on the machine that added
# the paragraph, and the failures named sockets and volumes rather than the config that
# caused them. An EMPTY file, not an unset variable: unset means "read ~/.config/uting/config"
# and empty means "the shipped defaults, and nothing a person happened to prefer".
# contract.sh has isolated this from the start; this file had not.
: >"$UT_TEST_TMP/config"
export UT_CONFIG="$UT_TEST_TMP/config"

# Two long, stable tracks. Silent at --volume 0; the point is the process, not the audio.
U1=${YT_TEST_URL1:-https://www.youtube.com/watch?v=n61ULEU7CO0}
U2=${YT_TEST_URL2:-https://www.youtube.com/watch?v=8S0FDjFBj8o}
# The second engine's fixture: an old-format BV with 76M views, picked to outlive the rig.
BV=${YT_TEST_BILI:-BV1fx411N7bU}

pass=0; fail=0; FAILED=""
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); FAILED="${FAILED}    ${1}"$'\n'; printf '  FAIL  %s\n' "$1"; }
report() { if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1: want $2, got $3"; fi; }

# A detached launch returns the moment the child is forked -- that is the point of it -- so the
# mpv IPC socket does not exist yet. Any check that MUTATES a player has to wait for the socket
# or it asserts on `ipc_failed`/exit 4, which is the CORRECT answer to "talk to a player that is
# not listening". Poll (bounded), never sleep a fixed guess: mpv's start is network-bound here
# and has ranged from under a second to fifteen. Returns 1 on timeout so the caller can say so.
wait_for_sock() {
    local sock=$1 i
    for i in $(seq 1 240); do
        [ -S "$sock" ] && return 0
        sleep 0.25
    done
    return 1
}

# wait_live <id> <field>  — poll --status until one LIVE field reports something real, then
# echo it; 1 on timeout, with whatever it last saw. The fields this waits on come off the mpv
# socket, not the record, so until mpv is decoding they are legitimately null — null there is
# an honest READING (ARCH-player.md「运行时 IPC」), and what must not happen is null forever. Same rule as
# wait_for_sock: bounded poll, never a fixed sleep, because the wait is network-bound.
#
# By FIELD rather than one loop per field: position and duration arrive at the same moment for
# the same reason, and the duration site below is a queue changing tracks, where reading once
# races the child killing one mpv and starting the next.
#
# `field` is a DOTTED PATH, so a nested live field (media.audio_codec) polls through the same
# loop as a flat one. getpath, not .[$f], for exactly that: the media object arrives when the
# decoder does, which is the same race every other field here is waiting out, and a second
# poller written to walk one level deeper would be the same bounded-poll rule stated twice.
wait_live() {
    local id=$1 field=$2 v="" i
    for i in $(seq 1 40); do
        v=$(shell/ut-play --status -j 2>/dev/null \
            | jq -r --arg i "$id" --arg f "$field" \
                '.players[]|select(.id==$i)|getpath($f|split("."))//empty' 2>/dev/null)
        case "$v" in "" | null | 0) ;; *) printf '%s' "$v"; return 0 ;; esac
        sleep 1
    done
    printf '%s' "$v"
    return 1
}

# wait_no_players  — poll --status until the record is empty; 1 on timeout. Same rule as
# wait_for_sock, and it exists because `--stop` returning is not the player being GONE: the
# child traps both signals and escalates, so the record clearing is the observable END of
# that path. This replaced a `sleep 2` at each of two sites — a fixed guess that was
# simultaneously too long (the teardown takes ~1s) and too short (it goes red on a machine
# that is merely slow, which is the most expensive red there is: not a bug, still investigated).
wait_no_players() {
    local i
    for i in $(seq 1 80); do
        [ "$(shell/ut-play --status -j 2>/dev/null | jq -c '.players' 2>/dev/null)" = "[]" ] && return 0
        sleep 0.25
    done
    return 1
}

# no_orphans <label>  — every mpv this file started is gone. Scoped to this run's own socket
# dir: a bare `mpv .*--input-ipc-server` counts the user's players too, so on any machine
# where uting is actually used the orphan check was a coin toss.
#
# The wait is INSIDE the helper, not a `sleep` at each call site: a process is reaped when it
# is reaped, both callers want the same answer, and one poll in one place cannot drift from
# itself. It reports the LAST count it saw, which is what keeps this able to fail — the shape
# wait_live already uses, where a timeout still hands back its final reading.
no_orphans() {
    local n i
    for i in $(seq 1 80); do
        n=$(pgrep -f "mpv .*--input-ipc-server=$STATE_DIR" 2>/dev/null | wc -l | tr -d ' ')
        [ "${n:-0}" = "0" ] && break
        sleep 0.25
    done
    report "$1" 0 "${n:-0}"
}

# Always stop everything, however this exits — a leaked player outlives the shell.
cleanup() {
    shell/ut-play --stop --all -j >/dev/null 2>&1
    rm -rf "$UT_TEST_TMP"
    return 0
}
trap cleanup EXIT INT TERM

shell/ut-play --stop --all -j >/dev/null 2>&1        # start from a clean slate

echo "── detach returns BEFORE mpv is up ────────────────────────────────"
# The envelope is the handle; if this waited for the player there would be nothing detached
# about it. A slow return has meant the title updater holding the captured pipe.
t0=$(date +%s)
o1=$(shell/ut-play -d -j --volume 0 -- "$U1" 2>/dev/null)
t1=$(date +%s)
report "detach envelope" 0 \
    "$(printf '%s' "$o1" | jq -e '.id and .pid and .sock' >/dev/null 2>&1; echo $?)"
if [ $((t1 - t0)) -le 3 ]; then ok "detach returned in $((t1 - t0))s (<= 3)"
else bad "detach took $((t1 - t0))s — is something holding the pipe?"; fi

id1=$(printf '%s' "$o1" | jq -r '.id // empty')
o2=$(shell/ut-play -d -j --volume 0 -- "$U2" 2>/dev/null)
id2=$(printf '%s' "$o2" | jq -r '.id // empty')

echo "── two players: the POPULATED envelope, one compact line ──────────"
report "--status one line" 1 "$(shell/ut-play --status -j | wc -l | tr -d ' ')"
report "--status sees 2"   2 "$(shell/ut-play --status -j | jq '.players | length')"

echo "── a selector-less mutation on 2 players is ambiguous -> exit 4 ───"
report "--set-volume no --id" 4 "$(shell/ut-play --set-volume 40 -j >/dev/null 2>&1; echo $?)"
# The exit code alone leaves the third row of ARCH-cli-contract.md「调用面」's 1-vs-4 table
# unproved: 4 is also what an IDLE mutation answers, so a caller told only "4" cannot tell
# "nothing to act on" from "say which one". `status` is the field that separates them, and it
# has no check anywhere else — contract.sh reaches the not_playing side and can never reach
# this one, ambiguity needing two live players.
# Captured FIRST, never piped straight from the command: under `set -o pipefail` the pipeline
# carries ut-play's own 4 and jq's verdict is thrown away — this line read FAIL/4 that way on
# its first run, against correct behaviour. Same trap contract.sh's jq_ok exists to close.
amb=$(shell/ut-play --set-volume 40 -j 2>/dev/null)
report "…and says ambiguous"  0 "$(printf '%s' "$amb" | jq -e '.status=="ambiguous" and .reason=="multiple_players" and (.players|length)==2' >/dev/null 2>&1; echo $?)"
# --stop takes the same ambiguity rule (ARCH-cli-contract.md「数据契约」): with 2 players and no
# selector it must refuse with 4 AND stop nothing — a --stop that guessed would kill the
# wrong listener's audio, which no exit code repairs.
report "--stop no --id"       4 "$(shell/ut-play --stop -j >/dev/null 2>&1; echo $?)"
report "ambiguous --stop stopped nothing" 2 "$(shell/ut-play --status -j | jq '.players | length')"
# Ambiguity is decided before any IPC, so the check above needs no player listening. The
# targeted ones below do -- wait for player 1's socket first (see wait_for_sock).
sock1=$(printf '%s' "$o1" | jq -r '.sock // empty')
wait_for_sock "$sock1" || bad "player 1's IPC socket never appeared -- the checks below are moot"
report "--set-volume --id"    0 "$(shell/ut-play --set-volume 40 --id "$id1" -j >/dev/null 2>&1; echo $?)"
# Only the targeted player moved: a mutation that leaks across players is the bug --id exists for.
report "only the target moved" "40" \
    "$(shell/ut-play --status -j | jq -r --arg i "$id1" '.players[]|select(.id==$i)|.volume')"

echo "── the live read: a real socket, a real peer, null is not false ───"
# The four live fields cost a round trip to mpv itself. Nothing in this repo may stand in for
# that peer, so the read is proved HERE, against the real one — never in contract.sh against
# something written to imitate it.
#
# Poll for the first reading rather than sleeping a guess (see wait_live).
if pos=$(wait_live "$id1" position); then
    ok "position came off the socket (${pos}s), not off the record"
else
    bad "player 1 never reported a position — the live read is unproved"
fi
# false is an ANSWER; null is "the question could not be asked" (ARCH-player.md「运行时 IPC」). A playing player that
# reported paused:null would make every consumer's readiness probe read a fabrication, and a
# playing player that reported it as anything but false would make --pause unobservable.
report "live paused is false, not null" 0 \
    "$(shell/ut-play --status -j | jq -e --arg i "$id1" \
        '.players[]|select(.id==$i)|.paused==false' >/dev/null 2>&1; echo $?)"
report "live duration is a number" 0 \
    "$(shell/ut-play --status -j | jq -e --arg i "$id1" \
        '.players[]|select(.id==$i)|.duration|type=="number"' >/dev/null 2>&1; echo $?)"
# The backfill's third field. `title` and `format` were already patched in from the resolve
# envelope; `selected` joins them, and it is the one of the three that no OFFLINE check can
# reach — the record is born with selected:null at launch, and only a real resolve of a real
# handle ever replaces it. A player record still reporting null here is a backfill that
# dropped the key, which is exactly what the launch-time default looks like.
report "the record carries selected" 0 \
    "$(shell/ut-play --status -j | jq -e --arg i "$id1" \
        '.players[]|select(.id==$i)|.selected|type=="string"' >/dev/null 2>&1; echo $?)"
# `media` — what is ACTUALLY DECODING, and the only place in the suite it can be proved: the
# facts come off the mpv socket, so an implementation without a real peer has nothing to
# report and this suite keeps no stand-in for one.
#
# THE DISCRIMINATING INPUT IS THE PLAYER ITSELF, playing audio. Two plausible wrong
# implementations are separated here without touching a tracked file:
#
#   * "copy what the engine said" — the record already carries `selected`, and on this play
#     it is a yt-dlp format string like "251 - audio only (medium)". A codec name cannot
#     contain a space, so the pattern below goes red the moment audio_codec is that string
#     rather than the decoder's own answer;
#   * "an absent number is zero" — this is an AUDIO play, so video_codec/width/height do not
#     apply, and the contract is that they are null. A width of 0 claims a video track one
#     pixel narrower than none; null says the question does not apply. Same distinction the
#     `paused` check above rests on, one field family over.
#
# audio_bitrate is deliberately NOT asserted: mpv computes it from recently decoded packets
# and reports it unavailable for the first seconds of a track and on some streams
# indefinitely (measured 2026-09-04, mpv 0.41). A check on it would go red on a demuxer's
# timing rather than on a bug, and a red that is not a bug still costs somebody a look.
if acodec=$(wait_live "$id1" media.audio_codec); then
    ok "media.audio_codec came off the socket ($acodec), not out of the record"
else
    bad "player 1 never reported a decoding codec — the media read is unproved"
fi
report "audio_codec is a codec name, not the engine's format string" 0 \
    "$(shell/ut-play --status -j | jq -e --arg i "$id1" \
        '.players[]|select(.id==$i)|.media.audio_codec|test("^[a-z0-9_.+-]+$")' >/dev/null 2>&1; echo $?)"
report "sample_rate is a number the engine never sent" 0 \
    "$(shell/ut-play --status -j | jq -e --arg i "$id1" \
        '.players[]|select(.id==$i)|.media.sample_rate|type=="number" and .>0' >/dev/null 2>&1; echo $?)"
report "an audio play reports video_codec/width null, not 0" 0 \
    "$(shell/ut-play --status -j | jq -e --arg i "$id1" \
        '.players[]|select(.id==$i)|.media|.video_codec==null and .width==null' >/dev/null 2>&1; echo $?)"
# The whole object is always present with all nine members, absent value or not: a caller
# that has to tell a missing KEY from a null VALUE is a caller we made work for nothing.
report "media carries all nine keys" 0 \
    "$(shell/ut-play --status -j | jq -e --arg i "$id1" \
        '.players[]|select(.id==$i)|.media|keys_unsorted|sort ==
         ["audio_bitrate","audio_codec","channels","fps","height","sample_rate","video_bitrate","video_codec","width"]' \
        >/dev/null 2>&1; echo $?)"
echo "── the playback verbs: the envelope reports what mpv answered ───"
# --pause / --resume / --seek / --seek-to over the same one-shot socket as --set-volume.
# contract.sh owns the idle half (no player → 4, an unsigned --seek → 1); what only a real
# player can show is that the verb MOVED something and that the number in the envelope came
# back off mpv rather than out of the caller's own arithmetic.
#
# Pause FIRST and seek while paused: a playing time-pos advances on its own, so any assertion
# about where a seek landed would be racing the decoder — and a check that depends on how
# fast this machine decodes is the timing assertion CLAUDE.md forbids. Paused, the playhead
# holds still and every claim below is about behaviour.
report "--pause reads back paused"  "true" \
    "$(shell/ut-play --pause --id "$id1" -j | jq -r '.paused')"
report "…and --status agrees"         "true" \
    "$(shell/ut-play --status -j | jq -r --arg i "$id1" '.players[]|select(.id==$i)|.paused')"
# The order is load-bearing: seek FORWARD first, then home. Doing it the other way round
# leaves a --seek-to that secretly seeks RELATIVE looking correct — a relative 0 from a
# playhead near the start also lands near the start. Proved by breaking it exactly that way
# and watching this pass; it only goes red once the absolute seek has somewhere to come back
# from. Each claim is anchored to the position BEFORE it, so a verb that does nothing at all
# cannot ride on where the decoder happened to be.
before=$(shell/ut-play --status -j | jq -r --arg i "$id1" '.players[]|select(.id==$i)|.position')
# A RELATIVE seek lands on a keyframe, so the claim is "forward by about that much", never an
# exact 30 — asserting the exact number would be asserting mpv's keyframe interval. What is
# proved here is that the sign was honoured and that the number is READ, not computed.
p1=$(shell/ut-play --seek +30 --id "$id1" -j | jq -r '.position')
# Each operand is judged SEPARATELY. Concatenating them ("$before$p1") let an empty baseline
# through whenever p1 was a number — and an empty `before` is 0 to bash 3.2 arithmetic, so
# `p1 >= before + 20` became `p1 >= 20` and this passed with no baseline at all.
case "$before" in
    "" | null) bad "--seek +30 had no baseline position to compare against" ;;
    *) case "$p1" in
        "" | null) bad "--seek +30 reported no position — the read-back is unproved" ;;
        *) if [ "$p1" -ge $((before + 20)) ]; then ok "--seek +30 moved the playhead forward (${before}s → ${p1}s)"
           else bad "--seek +30 left the playhead at ${p1}s (was ${before}s)"; fi ;;
       esac ;;
esac
# An ABSOLUTE seek is exact (mpv hr-seeks it), so coming back from ~30s means the start
# itself, not a keyframe in its neighbourhood.
p0=$(shell/ut-play --seek-to 0 --id "$id1" -j | jq -r '.position')
case "$p0" in
    "" | null) bad "--seek-to 0 reported no position — the read-back is unproved" ;;
    *) if [ "$p0" -le 2 ]; then ok "--seek-to 0 came back to the start (${p1}s → ${p0}s)"
       else bad "--seek-to 0 landed at ${p0}s, which is not the start"; fi ;;
esac
report "--resume reads back running" "false" \
    "$(shell/ut-play --resume --id "$id1" -j | jq -r '.paused')"
report "…and --status agrees"         "false" \
    "$(shell/ut-play --status -j | jq -r --arg i "$id1" '.players[]|select(.id==$i)|.paused')"

# NOT checked here: the `head -n <count>` pipe close in live_props (ARCH-player.md「运行时 IPC」).
# Tried and pulled: against the real peer it cannot go red — swap the `head` for a bare `cat`
# and the same read still measures 0.04s, so the assertion passes whatever the code does. The
# 1.11s that guard appeared to save was measured against a SCRIPTED peer, and this suite keeps
# none. The guard stays in the player as a defence; it does not get a green tick pretending
# this file proved it. Do not re-add it as a timing assertion.
# The degradation an agent must be able to tell from a reading — and it is produced by doing
# it, not by imitating it: the socket of a REALLY running player is really removed, which is
# what a crashed mpv or a half-cleaned state dir leaves behind. Live fields go null and volume
# falls back to the record, which --set-volume patched to 40 above.
rm -f "$sock1"
report "socketless player: nulls, volume off the record" 0 \
    "$(shell/ut-play --status -j | jq -e --arg i "$id1" \
        '.players[]|select(.id==$i)|.paused==null and .position==null and .duration==null and .volume==40' \
        >/dev/null 2>&1; echo $?)"

echo "── a second engine: the envelope's http_headers reach mpv ─────────"
# The only check in the suite that proves the player APPLIES what an engine hands it.
# contract.sh asserts http_headers is PRESENT in the resolve envelope; nothing asserted that
# ut-play forwards it into mpv. This site is what makes the difference observable: its CDN
# answers 403 to a bare stream URL and 206 to the same URL carrying the envelope's Referer
# (docs/ARCHITECTURE.md「调用栈」, measured). So a player that dropped the header block would still
# play YouTube, and every other check in this file would stay green, while bytes never flowed
# from here. Position leaving zero IS the proof that they did.
o3=$(shell/ut-play -d -j --volume 0 --engine bili -- "$BV" 2>/dev/null)
report "bili detach envelope" 0 \
    "$(printf '%s' "$o3" | jq -e '.id and .pid and .sock' >/dev/null 2>&1; echo $?)"
id3=$(printf '%s' "$o3" | jq -r '.id // empty')
sock3=$(printf '%s' "$o3" | jq -r '.sock // empty')
# A record is a CALL: {engine, url} is the argv that produced it, so a caller reading --status
# can re-issue what is playing instead of guessing which engine owns the handle. This player is
# the discriminating input — the only one in the file launched under --engine, against a suite
# default of yt — so a field filled from the default, or missing, answers `yt` here.
report "the record names the engine that resolved it" "bili" \
    "$(shell/ut-play --status -j | jq -r --arg i "$id3" '.players[] | select(.id == $i) | .engine // "null"')"
if wait_for_sock "$sock3"; then
    # `position` is read live off the socket, not from the record, and time-to-first-byte is
    # network-bound — so it is the same bounded poll as player 1's (wait_live).
    if pos=$(wait_live "$id3" position); then
        ok "bili audio flowed (position ${pos}s) — the envelope's headers reached mpv"
    else
        bad "bili position never left 0 — did http_headers reach mpv? (CDN 403s without the Referer)"
    fi
else
    bad "the bili player's IPC socket never appeared — the header claim is untested"
fi

echo "── a third engine: a search row plays, end to end ─────────────────"
# THE WHOLE PIPELINE ON ONE ENGINE, with nothing pinned: a real `ne-search` answers, its first
# row's url goes straight to `ut-play -d --engine ne`, and the playhead moves. Three envelopes
# have to agree for that to happen — search's row, resolve's stream_urls/http_headers, and the
# player's record — and this is the only place all three are the same engine's and all three
# are real.
#
# THE HANDLE IS SEARCHED FOR, NOT WRITTEN DOWN, and on this site that is not a style choice.
# Roughly 43% of this catalogue is VIP-only, so a pinned song id is a check that goes red the
# day someone else's licence changes. `ne-search` filters to access:"full" by default, so its
# first row is by construction a track this account can really play — which makes "take row
# one" both the cheapest handle and the correct one. `lofi` is the query because it measured
# 98% playable; the row itself is asserted, so a query that stops returning one is a red with
# a name on it rather than a mystery below.
NE_ROW=$(shell/ne-search -j -n 5 -- lofi 2>/dev/null | jq -r '.results[0].url // empty')
if [ -z "$NE_ROW" ]; then
    bad "ne-search returned no playable row — the third engine's pipeline is untested"
else
    o6=$(shell/ut-play -d -j --volume 0 --engine ne -- "$NE_ROW" 2>/dev/null)
    report "ne detach envelope" 0 \
        "$(printf '%s' "$o6" | jq -e '.id and .pid and .sock' >/dev/null 2>&1; echo $?)"
    id6=$(printf '%s' "$o6" | jq -r '.id // empty')
    sock6=$(printf '%s' "$o6" | jq -r '.sock // empty')
    report "the record names the engine that resolved it" "ne" \
        "$(shell/ut-play --status -j | jq -r --arg i "$id6" '.players[] | select(.id == $i) | .engine // "null"')"
    if wait_for_sock "$sock6"; then
        if pos=$(wait_live "$id6" position); then
            ok "ne audio flowed (position ${pos}s) — search row to playhead, one engine"
        else
            bad "ne position never left 0 — did the resolve envelope's stream url and headers reach mpv?"
        fi
    else
        bad "the ne player's IPC socket never appeared — the third engine's pipeline is untested"
    fi
fi

echo "── the quality tier rides the same path as -f ────────────────────"
# --quality low must stack with -f and reach the engine without breaking
# format selection — a detached player that comes up and reports position proves the
# tier did not break the stream. auto (the default) sends no sort at all.
o4=$(shell/ut-play -d -j --volume 0 --quality low -f audio -- "$U1" 2>/dev/null)
report "quality detach envelope" 0 \
    "$(printf '%s' "$o4" | jq -e '.id and .pid and .sock' >/dev/null 2>&1; echo $?)"
id4=$(printf '%s' "$o4" | jq -r '.id // empty')
sock4=$(printf '%s' "$o4" | jq -r '.sock // empty')
if wait_for_sock "$sock4"; then
    if pos=$(wait_live "$id4" position); then
        ok "quality audio flowed (position ${pos}s) — the tier reached the engine"
    else
        bad "quality player position never left 0 — did --quality reach the engine?"
    fi
else
    bad "the quality player's IPC socket never appeared"
fi

echo "── the start offset really moves the playhead ────────────────────"
# The one claim in this feature that only a real mpv can settle: contract.sh proves the
# engine READS a timestamp and the gate refuses a bad one, and neither says the number ever
# reached a decoder. Read back off the same live socket everything else here uses.
#
# N is 600, not 42, and that is the whole design of this check. An implementation that drops
# --start reports a single-digit position — two orders of magnitude away — so the window can
# be generous without ever going green on the failure it exists to catch. At 42 the honest
# window would be a couple of seconds wide (a cold, unwarmed decoder reports its first
# position anywhere in that range), and a window that wide DOES admit "started from zero" on
# a small N. Widening a tolerance until the check passes is how a check stops being able to
# fail; moving N is how the same tolerance stops mattering.
#
# The lower bound is 595 rather than 600 because mpv lands on the keyframe at or before the
# target — measured 599 for this stream. Asserting 600 exactly would be asserting the
# keyframe interval of whatever U1 resolves to today.
o5=$(shell/ut-play -d -j --volume 0 --start 600 -- "$U1" 2>/dev/null)
report "start-offset detach envelope" 0 \
    "$(printf '%s' "$o5" | jq -e '.id and .pid and .sock' >/dev/null 2>&1; echo $?)"
id5=$(printf '%s' "$o5" | jq -r '.id // empty')
sock5=$(printf '%s' "$o5" | jq -r '.sock // empty')
if wait_for_sock "$sock5"; then
    if pos=$(wait_live "$id5" position); then
        if [ "$pos" -ge 595 ] && [ "$pos" -le 605 ]; then
            ok "--start 600 opened at ${pos}s — mpv got the offset"
        else
            bad "--start 600 opened at ${pos}s, which is not where it was told to"
        fi
    else
        bad "the start-offset player never reported a position — the claim is untested"
    fi
else
    bad "the start-offset player's IPC socket never appeared"
fi
shell/ut-play --stop --id "$id5" -j >/dev/null 2>&1

echo "── stop is targeted, then idempotent, and leaks nothing ───────────"
report "--stop --id"       0 "$(shell/ut-play --stop --id "$id1" -j >/dev/null 2>&1; echo $?)"
report "--stop --all"      0 "$(shell/ut-play --stop --all -j >/dev/null 2>&1; echo $?)"
report "--stop --all again" 0 "$(shell/ut-play --stop --all -j >/dev/null 2>&1; echo $?)"
report "no players left"   0 "$(shell/ut-play --status -j | jq -e '.players==[]' >/dev/null 2>&1; echo $?)"

no_orphans "no orphan mpv"

echo "── a queue is a player consuming a playlist ───────────────────────"
# Everything above played ONE handle. This section plays a LIST, and it is here rather than
# in contract.sh for the reason that file states about itself: proving a queue ADVANCES
# needs a real engine round trip and a real mpv reaching the end of a track, and nothing may
# stand in for either. A mock engine answering av://lavfi:sine would skip the JIT resolve —
# the very thing most likely to break between two tracks — and be green for it.
#
# One player, so no --id is needed anywhere below (exactly-one is the zero-friction case).
shell/ut-play --stop --all -j >/dev/null 2>&1
# The list is STORED first and read back out, so what launches the player is
# ARCH-cli-contract.md「调用面」's second pipeline run verbatim:
#     ut-playlist --show chill -j | ut-play -d --queue -
# It used to be a `jq -nc` array inlined here, which proved the array arm and left the arm the
# doc actually advertises unexecuted — and that arm is the one carrying the claim: a stored
# record IS a call, so the two commands need no jq mapping between them. contract.sh proves
# the same envelope reaches the gate offline (4, no player); this is the half where it really
# starts one. UT_STATE_DIR is this file's own (top of file), so the list is disposable.
jq -nc --arg a "$U1" --arg b "$U2" '[{engine:"yt",url:$a},{engine:"yt",url:$b}]' |
    shell/ut-playlist --add chill -j >/dev/null 2>&1
report "the list stored 2" 2 "$(shell/ut-playlist --show chill -j 2>/dev/null | jq -r '.count // 0')"
qout=$(shell/ut-playlist --show chill -j 2>/dev/null | shell/ut-play -d --queue - -j --volume 0 2>/dev/null)
report "--queue - launches" 0 "$(printf '%s' "$qout" | jq -e '.status=="started" and .id' >/dev/null 2>&1; echo $?)"
# The queue is visible from the moment the player exists, not once the first track decodes:
# a caller that asks what is queued must not have to wait for mpv. `upcoming` is asserted
# beside `next` because it is the READ half of the queue (uting's card draws it): the two
# describe the same tail, so a projection that let them disagree about what comes next is
# the failure this check exists to catch. `duration` is the field `next` does not carry —
# the whole reason the list exists — so it is asserted as PRESENT rather than as a number
# (these items were queued from urls alone, and an absent duration is null, not zero).
report "--status carries the queue" 0 \
    "$(shell/ut-play --status -j | jq -e '.players[0].queue
        | .pos==0 and .len==2 and (.next.url|type=="string")
          and (.upcoming|length)==1 and .upcoming[0].url==.next.url
          and (.upcoming[0]|has("duration"))' >/dev/null 2>&1; echo $?)"
qsock=$(printf '%s' "$qout" | jq -r '.sock // empty')
wait_for_sock "$qsock" || bad "the queued player's socket never appeared — the checks below are moot"

# --enqueue lands on a RUNNING player, and the envelope reports the queue it wrote.
report "--enqueue appends" 0 \
    "$(jq -nc --arg a "$U1" '[{engine:"yt",url:$a}]' | shell/ut-play --enqueue - -j 2>/dev/null \
        | jq -e '.status=="ok" and .added==1 and .queue.len==3' >/dev/null 2>&1; echo $?)"
# Concurrency is DRIVEN, not argued (the rule ut-playlist's eight concurrent --add checks
# already follow): six writers, six items, no lost update. With lock_queue_state stubbed to
# fail this loop leaves fewer — watched, so the check is known to be able to fail.
for i in 1 2 3 4 5 6; do
    jq -nc --arg a "$U2" '[{engine:"yt",url:$a}]' | shell/ut-play --enqueue - -j >/dev/null 2>&1 &
done
wait
report "6 concurrent --enqueue all land (3+6)" 9 \
    "$(shell/ut-play --status -j | jq -r '.players[0].queue.len')"
# Nine queued items is the discriminating input for the CAP: a projection that dumped the
# whole tail would answer 8 here and grow with every --enqueue, which is the thing --status
# --all must not do. `len` above already proved the total is still told honestly.
report "upcoming is capped, len is not" 5 \
    "$(shell/ut-play --status -j | jq -r '.players[0].queue.upcoming | length')"

# --next: the POSITION moves in the parent, so the envelope reports a queue it read. Then the
# player follows — a bounded poll, because what is being proved is that it DID follow, not
# how fast it resolved (a duration assertion against a live site is the timing check
# CLAUDE.md forbids).
report "--next advances the position" 1 \
    "$(shell/ut-play --next -j 2>/dev/null | jq -r '.queue.pos')"
i=0
while [ $i -lt 60 ]; do
    u=$(shell/ut-play --status -j | jq -r '.players[0].url // empty')
    [ "$u" = "$U2" ] && break
    sleep 1; i=$((i + 1))
done
report "the record follows the track" "$U2" \
    "$(shell/ut-play --status -j | jq -r '.players[0].url // empty')"

# The one a queue exists for: a track ENDING on its own starts the next. Seek to just before
# the end rather than waiting out a six-hour stream, then poll for the position to move —
# the child has to notice mpv exited, advance under its own lock, resolve the next handle and
# start a new mpv, and none of that is driven from here.
# WAIT for the duration, never read it once. `duration` comes off the socket while the poll
# above only proved the RECORD advanced — at that moment the child may have just killed track
# one's mpv and still be resolving track two, so a single read has come back empty and turned
# this red on a correct player (measured). Worse than the red: it skipped the arm below, so
# the one claim a queue exists for went unproved while the score dropped by only 1.
qid=$(printf '%s' "$qout" | jq -r '.id // empty')
if dur=$(wait_live "$qid" duration); then
    shell/ut-play --seek-to $((dur - 4)) -j >/dev/null 2>&1
    i=0
    while [ $i -lt 90 ]; do
        [ "$(shell/ut-play --status -j | jq -r '.players[0].queue.pos // empty')" = "2" ] && break
        sleep 1; i=$((i + 1))
    done
    report "a track ending advances the queue" "2" \
        "$(shell/ut-play --status -j | jq -r '.players[0].queue.pos // empty')"
else
    bad "the queued player never reported a duration in 40s — cannot drive it to a track end"
fi

# --stop takes the whole QUEUE down. The child traps BOTH signals stop_group sends it, and
# the INT half is not belt-and-braces: bash only sets SIGINT to SIG_IGN in an async child when
# job control is OFF, and detach_play launches under `set -m`, so an untrapped INT here is a
# plain kill landing while the TERM handler runs (measured — see stop_group). The signals are
# repeated on every tick of the escalation because the engine call between two tracks spawns
# processes that never saw the first one.
shell/ut-play --next -j >/dev/null 2>&1
# NOT a wait, and so not a poll: this sleep is SETUP. It puts the --stop below in the middle
# of the between-tracks resolve, which is the race being driven; without it the stop lands
# before the child has spawned anything and the check passes without touching the claim.
sleep 0.5
report "--stop ends the queue" 0 "$(shell/ut-play --stop --all -j >/dev/null 2>&1; echo $?)"
wait_no_players
report "no players after a queue" 0 "$(shell/ut-play --status -j | jq -e '.players==[]' >/dev/null 2>&1; echo $?)"
no_orphans "no orphan mpv after a queue"
# NOT checked here: that a stopped queue files no tombstone. Tried and pulled: disable the
# child's `stopped` branch outright and failed[] is STILL empty, so the check was green against
# broken code. contract.sh drives the tombstone boundaries from fixtures instead, which is
# where a rule about what the REAPER records belongs.

echo "── the listening log, written by a player that really played ─────"
# contract.sh drives ut-history's own contract from fixtures. The WIRING — that a track
# ending makes a row exist — can only be proved where a real track really ends, so it is
# proved on a track chosen to end: 19 seconds, permanent and public, the same handle
# contract.sh resolves. A seek to the end of one of the long tracks above would be cheaper
# and it is what the queue section does, but it cannot carry this claim: `duration` is null
# on a live stream, and this file must not have a check that goes green or red depending on
# whether the fixture was streaming that afternoon.
SHORT=${YT_TEST_SHORT:-https://www.youtube.com/watch?v=jNQXAC9IVRw}
# How many rows this one track has, out of an envelope already in hand. Every claim below is
# keyed by its url rather than by a total: this file leaves players stopping in the background
# and a row landing from one of them mid-window would move a total for a reason that has
# nothing to do with what is being asserted.
h_url() { printf '%s' "$1" | jq -r --arg u "$SHORT" '[.items[]|select(.url==$u)]|length'; }

shell/ut-play -d -j --volume 0 -- "$SHORT" >/dev/null 2>&1
# Poll the LOG, not the clock: the row appears when the track ends, and how long the track
# takes to start is network-bound (the rule wait_for_sock follows, applied to the artefact).
# Poll for THIS track's row: the queue section also ends a track on its own, so a poll for
# "any row that ended by itself" returns immediately and waits for nothing.
i=0
while [ $i -lt 60 ]; do
    [ "$(h_url "$(shell/ut-history --ls -n 50 -j 2>/dev/null)")" != "0" ] && break
    sleep 1; i=$((i + 1))
done
HIST=$(shell/ut-history --ls -n 50 -j 2>/dev/null)
# THE RECORD POINT, and the one claim that separates a history from a death record: a track
# that ended ON ITS OWN is in the log, carrying no reason at all. If the row were written
# only when a player dies, this is the check that would be empty.
report "a track that ended is logged" 0 \
    "$(printf '%s' "$HIST" | jq -e --arg u "$SHORT" 'any(.items[]; .url==$u and .reason==null)' >/dev/null 2>&1; echo $?)"
# And it is that TRACK's row, not a placeholder: the title the engine returned, and a played
# length in the neighbourhood of the 19 seconds the thing actually is.
report "…with its own title and length" 0 \
    "$(printf '%s' "$HIST" | jq -e --arg u "$SHORT" 'any(.items[]; .url==$u and (.title|type)=="string" and .seconds >= 15 and .seconds <= 40)' >/dev/null 2>&1; echo $?)"
# The other half, off the players every section above stopped: an interrupted track is
# recorded too, which is what keeps the log from being a record of what went uninterrupted.
report "an interrupted track says so" 0 \
    "$(printf '%s' "$HIST" | jq -e '[.items[]|select(.reason=="stopped_by_user")]|length >= 1' >/dev/null 2>&1; echo $?)"
# A row is a CALL: `engine` plus `url` is `ut-play --engine E -- <handle>`, which is why the
# log stores the pair and not a bare handle. Both are asserted as the GRAMMAR each side of
# that argv has — an engine name the player will paste into `<engine>-resolve`, a handle with
# no whitespace in it — and not as "yt" or as "starts with http": this run drove two engines,
# one of them on a bare BV id, and a third must pass this check unedited.
report "…and every row is a call"    0 \
    "$(printf '%s' "$HIST" | jq -e 'all(.items[]; (.engine|test("^[a-z0-9][a-z0-9_-]*$")) and (.url|test("^[^[:space:]]+$")))' >/dev/null 2>&1; echo $?)"
# One shape for every source: the same two engines the sections above drove are both in the
# log, with no per-site branch anywhere between them and the row.
report "…from both engines, one shape" 0 \
    "$(printf '%s' "$HIST" | jq -e '[.items[].engine]|unique|length >= 2' >/dev/null 2>&1; echo $?)"

# The off switch is the whole switch: not a shorter row, no row. One more real player,
# because a knob only read on a path nothing drives is a knob nobody has tested.
#
# The short track is replayed here because exactly one row for it exists by now, and only
# this player could write a second.
h_before=$(h_url "$HIST")
o4=$(UT_HISTORY=0 shell/ut-play -d -j --volume 0 -- "$SHORT" 2>/dev/null)
sock4=$(printf '%s' "$o4" | jq -r '.sock // empty')
if wait_for_sock "$sock4"; then
    # Setup again, not a wait: mpv has to really play, or "the switch wrote nothing" is true
    # of a track that never started and the check is vacuous.
    sleep 2
    shell/ut-play --stop --all -j >/dev/null 2>&1
    # An ABSENCE cannot be polled for — you can only wait long enough — so this polls the
    # PRECONDITION instead of guessing at the absence: the row is written by the player's own
    # exit path, so once the record is empty the only process that could write one is gone and
    # the answer below is final. Strictly stronger than the `sleep 2` it replaced, which
    # merely hoped.
    wait_no_players
    report "UT_HISTORY=0 writes nothing" "$h_before" \
        "$(h_url "$(shell/ut-history --ls -n 50 -j 2>/dev/null)")"
else
    bad "the UT_HISTORY=0 player never started — the off switch is untested"
fi

echo
printf '%s: %d ok, %d failed\n' "$(basename "$0")" "$pass" "$fail"
if [ "$fail" -ne 0 ]; then printf 'failures:\n%s' "$FAILED"; exit 1; fi
exit 0
