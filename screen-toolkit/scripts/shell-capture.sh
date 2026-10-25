#!/usr/bin/env bash
# shell-capture.sh <action> [args...]
#
# Screen captures through the shell's own screenshot stack
# (wlr-screencopy) instead of grim/slurp. The shell owns the output policy
# (directory, filename pattern, clipboard, cursor) under [shell.screenshot];
# this script only triggers captures and picks up the resulting file.
#
# Actions:
#   region-file                — interactive region capture; stdout: file path
#   fullscreen-file            — capture the focused monitor; stdout: file path
#   window-file                — click a window and snap to its geometry
#                                (Hyprland), or capture the focused window
#                                (Umbriel, no click-to-pick: same as Niri);
#                                via fullscreen + magick crop.
#                                stdout: file path
#   window-id-file             — snap the Umbriel window with the given id via
#                                fullscreen + magick crop (socket passed as $3).
#                                stdout: file path
#   edit <file>                — open <file> in the shell annotation editor
#   annotate-region            — region capture + editor; stdout: file path
#   annotate-fullscreen        — fullscreen capture + editor; stdout: file path
#   annotate-window            — focused-window capture + editor; stdout: file path
#
# The capture commands print only "ok", so the file is picked up as the
# newest file in the screenshot dir newer than (start - 2s). The shell
# flushes the file asynchronously after printing ok, so pickup polls.
#
# Exit codes:
#   0  — ok (stdout is the file path)
#   1  — missing dependency (dep name written to stdout)
#   2  — bad / missing arguments, or no window under the click
#   3  — image processing (crop) failed
#   10 — cancelled by the user (silent)
#   11 — capture finished but nothing was saved to a file (NOFILE)
#   13 — annotation editor handoff failed
#
# Used by: service.luau

set -u

# Resolve the shell's screenshot directory. getConfig only sees plugin
# keys, so parse the shell's own files (first match wins), then default.
# Never write these files: the running shell owns and rewrites them.
shell_dir() {
    local f val
    for f in "$HOME/.local/state/noctalia/settings.toml" "$HOME/.config/noctalia/settings.toml"; do
        [ -f "$f" ] || continue
        val=$(awk '
            /^\s*\[shell\.screenshot\]/ { in_s = 1; next }
            /^\s*\[/ { in_s = 0 }
            in_s && /^\s*directory\s*=/ {
                line = $0
                sub(/^[^=]*=/, "", line)
                gsub(/^[ \t"]+|[ \t"]+$/, "", line)
                print line
                exit
            }
        ' "$f" 2>/dev/null)
        if [ -n "$val" ]; then
            case "$val" in
                "~"/*) val="$HOME/${val#\~/}" ;;
                "~") val="$HOME" ;;
            esac
            printf '%s\n' "$val"
            return 0
        fi
    done
    printf '%s\n' "$HOME/Pictures/Screenshots"
}

# Newest regular file in $1 newer than ($2 - 2s). Prints nothing when none.
newest_since() {
    local dir="$1" since="$2"
    [ -d "$dir" ] || return 0
    find "$dir" -maxdepth 1 -type f -newermt "@$((since - 2))" -printf '%T@ %p\n' 2>/dev/null \
        | sort -n | tail -1 | cut -d' ' -f2-
}

# Poll for the capture the shell is still flushing. Prints the file path.
pickup() {
    local i f
    for i in $(seq 1 50); do
        f=$(newest_since "$1" "$2")
        if [ -n "$f" ]; then
            printf '%s\n' "$f"
            return 0
        fi
        sleep 0.1
    done
    return 1
}

# Wait until $1 is fully flushed (the shell writes the file asynchronously
# after printing ok). Cheap stat polling finds stability, then a single
# magick parse confirms it — a fresh file typically costs ~0.3s here.
wait_ready() {
    local prev="" cur="" i
    for i in $(seq 1 50); do
        cur=$(stat -c %s "$1" 2>/dev/null) || cur=""
        if [ -n "$cur" ] && [ "$cur" != "0" ] && [ "$cur" = "$prev" ]; then
            magick identify -format '%w %h\n' "$1" >/dev/null 2>&1 && return 0
        fi
        prev="$cur"
        sleep 0.1
    done
    return 1
}

_require() {
    command -v "$1" >/dev/null 2>&1 \
        || { echo "$1"; exit 1; }
}

ACTION="${1:-}"

case "$ACTION" in

    region-file)
        _require noctalia
        # Let the just-closed panel finish its close animation first.
        sleep 0.3
        _dir=$(shell_dir)
        _before=$(date +%s)
        noctalia msg screenshot-region >/dev/null 2>&1 || exit 10
        _f=""
        _f=$(pickup "$_dir" "$_before") || exit 11
        wait_ready "$_f" || exit 11
        printf '%s\n' "$_f"
        ;;

    fullscreen-file)
        _require noctalia
        sleep 0.4
        _dir=$(shell_dir)
        _before=$(date +%s)
        noctalia msg screenshot-fullscreen >/dev/null 2>&1 || exit 10
        _f=""
        _f=$(pickup "$_dir" "$_before") || exit 11
        wait_ready "$_f" || exit 11
        printf '%s\n' "$_f"
        ;;

    window-file)
        _require noctalia
        _require jq
        _require magick
        # Click a window, snap to its geometry, capture via fullscreen crop.
        # No dimming at all: plain click-to-snap.
        # Umbriel has no click-to-pick (slurp can't run there), so it uses
        # the focused window — same deal as Niri. Socket docs: $UMBRIEL_SOCKET,
        # else $XDG_RUNTIME_DIR/umbriel-$WAYLAND_DISPLAY.sock; plugin runtimes
        # may not inherit the shell's env, so scan for any umbriel socket
        # as a last resort.
        if [ -z "${UMBRIEL_SOCKET:-}" ]; then
            if [ -n "${WAYLAND_DISPLAY:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ] \
                && [ -S "$XDG_RUNTIME_DIR/umbriel-$WAYLAND_DISPLAY.sock" ]; then
                UMBRIEL_SOCKET="$XDG_RUNTIME_DIR/umbriel-$WAYLAND_DISPLAY.sock"
            else
                _rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
                for _s in "$_rt"/umbriel-*.sock; do
                    if [ -S "$_s" ]; then UMBRIEL_SOCKET="$_s"; break; fi
                done
            fi
            export UMBRIEL_SOCKET
        fi
        if [ -n "${UMBRIEL_SOCKET:-}" ] && command -v umbriel >/dev/null 2>&1 \
            && umbriel windows --json >/dev/null 2>&1; then
            # Focused visible window; fall back to the first visible one.
            _win=$(umbriel windows --json 2>/dev/null | jq -c '
                [ .[] | select(.visible == true and (.minimized != true)
                               and (.tab_hidden != true)
                               and (.x? != null) and (.y? != null)
                               and (.w? != null) and (.h? != null)) ]
                | ((map(select(.focused == true)) | first) // first // empty)' 2>/dev/null)
            [ -n "$_win" ] && [ "$_win" != "null" ] || { echo "ERR no visible window found"; exit 2; }
            _wx=$(printf '%s' "$_win" | jq -r '.x')
            _wy=$(printf '%s' "$_win" | jq -r '.y')
            _ww=$(printf '%s' "$_win" | jq -r '.w')
            _wh=$(printf '%s' "$_win" | jq -r '.h')
            _wout=$(printf '%s' "$_win" | jq -r '.output // empty')
            # Output under the window center, for origin + scale.
            _cx=$((_wx + _ww / 2))
            _cy=$((_wy + _wh / 2))
            _mon=$(umbriel outputs --json 2>/dev/null | jq -c --argjson x "$_cx" --argjson y "$_cy" --arg out "$_wout" '
                ([ .[] | select(.name == $out or
                                (.position.x <= $x and ($x < .position.x + .logical_size.width)
                                 and .position.y <= $y and ($y < .position.y + .logical_size.height)))
                   | {x: .position.x, y: .position.y, scale: .scale} ] | first)
                // (.[0] | {x: .position.x, y: .position.y, scale: .scale})' 2>/dev/null)
            [ -n "$_mon" ] && [ "$_mon" != "null" ] || { echo "ERR no output matches window"; exit 2; }
            _mx=$(printf '%s' "$_mon" | jq -r '.x // 0')
            _my=$(printf '%s' "$_mon" | jq -r '.y // 0')
            _scale=$(printf '%s' "$_mon" | jq -r '.scale // 1')
        else
            _require slurp
            _require hyprctl
            # Click a point, snap to the focused-first window containing it.
            _pt=""
            _rc=0
            _pt=$(slurp -p -b 00000000 2>/dev/null) || _rc=$?
            if [ "$_rc" -ne 0 ]; then exit 10; fi
            _px=$(printf '%s' "$_pt" | awk -F'[, ]+' '{print int($1)}')
            _py=$(printf '%s' "$_pt" | awk -F'[, ]+' '{print int($2)}')
            _win=$(hyprctl clients -j 2>/dev/null | jq -c --argjson x "$_px" --argjson y "$_py" '
                [ .[] | select(.mapped == true)
                  | { address: .address, at: (.at // [0, 0]), size: (.size // [0, 0]),
                      focusHistoryID: (.focusHistoryID // 9999999) }
                  | select(.at[0] <= $x and (.at[0] + .size[0]) >= $x
                       and .at[1] <= $y and (.at[1] + .size[1]) >= $y) ]
                | sort_by([.focusHistoryID, .size[0] * .size[1]]) | first' 2>/dev/null)
            [ -n "$_win" ] && [ "$_win" != "null" ] || exit 2
            _wx=$(printf '%s' "$_win" | jq -r '.at[0]')
            _wy=$(printf '%s' "$_win" | jq -r '.at[1]')
            _ww=$(printf '%s' "$_win" | jq -r '.size[0]')
            _wh=$(printf '%s' "$_win" | jq -r '.size[1]')
            # Monitor under the window center, for origin + scale.
            _cx=$((_wx + _ww / 2))
            _cy=$((_wy + _wh / 2))
            _mon=$(hyprctl monitors -j 2>/dev/null | jq -c --argjson x "$_cx" --argjson y "$_cy" '
                ([ .[] | select(.x <= $x and ($x < .x + .width)
                             and .y <= $y and ($y < .y + .height))
                   | {x: .x, y: .y, scale: .scale} ] | first) // (.[0] | {x: .x, y: .y, scale: .scale})' 2>/dev/null)
            [ -n "$_mon" ] && [ "$_mon" != "null" ] || exit 2
            _mx=$(printf '%s' "$_mon" | jq -r '.x // 0')
            _my=$(printf '%s' "$_mon" | jq -r '.y // 0')
            _scale=$(printf '%s' "$_mon" | jq -r '.scale // 1')
        fi
        _dir=$(shell_dir)
        _before=$(date +%s)
        noctalia msg screenshot-fullscreen >/dev/null 2>&1 || exit 10
        _full=""
        _full=$(pickup "$_dir" "$_before") || exit 11
        wait_ready "$_full" || exit 11
        # Window geometry is logical pixels; the PNG is physical (x scale).
        read -r _iw _ih < <(magick identify -format '%w %h\n' "$_full" 2>/dev/null) || exit 3
        read -r _cx _cy _cw _ch < <(awk -v wx="$_wx" -v wy="$_wy" -v ww="$_ww" -v wh="$_wh" \
            -v mx="$_mx" -v my="$_my" -v s="$_scale" -v iw="$_iw" -v ih="$_ih" 'BEGIN {
            x = int((wx - mx) * s); y = int((wy - my) * s)
            w = int(ww * s); h = int(wh * s)
            if (x < 0) { w += x; x = 0 }
            if (y < 0) { h += y; y = 0 }
            if (x + w > iw) w = iw - x
            if (y + h > ih) h = ih - y
            if (w < 1) w = 1; if (h < 1) h = 1
            printf "%d %d %d %d", x, y, w, h
        }')
        _out="/tmp/screen-toolkit-window-$(date +%s)-$$.png"
        magick "$_full" -crop "${_cw}x${_ch}+${_cx}+${_cy}" +repage "$_out" 2>/dev/null \
            || exit 3
        printf '%s\n' "$_out"
        ;;

    window-id-file)
        _require noctalia
        _require jq
        _require magick
        _WID="${2:-}"
        [ -n "$_WID" ] || exit 2
        # Let the just-closed picker finish its close animation first.
        sleep 0.4
        # Socket passed explicitly by the service (no env guessing needed).
        if [ -n "${3:-}" ]; then export UMBRIEL_SOCKET="$3"; fi
        if ! command -v umbriel >/dev/null 2>&1; then echo "umbriel"; exit 1; fi
        _win=$(umbriel windows --json 2>/dev/null | jq -c --arg id "$_WID" '
            [ .[] | select(.id == $id and (.x? != null) and (.y? != null)
                           and (.w? != null) and (.h? != null)) ]
            | first // empty' 2>/dev/null)
        [ -n "$_win" ] && [ "$_win" != "null" ] || { echo "ERR window gone"; exit 2; }
        _wx=$(printf '%s' "$_win" | jq -r '.x')
        _wy=$(printf '%s' "$_win" | jq -r '.y')
        _ww=$(printf '%s' "$_win" | jq -r '.w')
        _wh=$(printf '%s' "$_win" | jq -r '.h')
        _wout=$(printf '%s' "$_win" | jq -r '.output // empty')
        _cx=$((_wx + _ww / 2))
        _cy=$((_wy + _wh / 2))
        _mon=$(umbriel outputs --json 2>/dev/null | jq -c --argjson x "$_cx" --argjson y "$_cy" --arg out "$_wout" '
            ([ .[] | select(.name == $out or
                            (.position.x <= $x and ($x < .position.x + .logical_size.width)
                             and .position.y <= $y and ($y < .position.y + .logical_size.height)))
               | {x: .position.x, y: .position.y, scale: .scale} ] | first)
            // (.[0] | {x: .position.x, y: .position.y, scale: .scale})' 2>/dev/null)
        [ -n "$_mon" ] && [ "$_mon" != "null" ] || { echo "ERR no output matches window"; exit 2; }
        _mx=$(printf '%s' "$_mon" | jq -r '.x // 0')
        _my=$(printf '%s' "$_mon" | jq -r '.y // 0')
        _scale=$(printf '%s' "$_mon" | jq -r '.scale // 1')
        _dir=$(shell_dir)
        _before=$(date +%s)
        noctalia msg screenshot-fullscreen >/dev/null 2>&1 || exit 10
        _full=""
        _full=$(pickup "$_dir" "$_before") || exit 11
        wait_ready "$_full" || exit 11
        read -r _iw _ih < <(magick identify -format '%w %h\n' "$_full" 2>/dev/null) || { echo "ERR unreadable screenshot"; exit 3; }
        read -r _cx _cy _cw _ch < <(awk -v wx="$_wx" -v wy="$_wy" -v ww="$_ww" -v wh="$_wh" \
            -v mx="$_mx" -v my="$_my" -v s="$_scale" -v iw="$_iw" -v ih="$_ih" 'BEGIN {
            x = int((wx - mx) * s); y = int((wy - my) * s)
            w = int(ww * s); h = int(wh * s)
            if (x < 0) { w += x; x = 0 }
            if (y < 0) { h += y; y = 0 }
            if (x + w > iw) w = iw - x
            if (y + h > ih) h = ih - y
            if (w < 1) w = 1; if (h < 1) h = 1
            printf "%d %d %d %d", x, y, w, h
        }')
        _out="/tmp/screen-toolkit-window-$(date +%s)-$$.png"
        magick "$_full" -crop "${_cw}x${_ch}+${_cx}+${_cy}" +repage "$_out" 2>/dev/null \
            || { echo "ERR window crop failed"; exit 3; }
        printf '%s\n' "$_out"
        ;;

    edit)
        _require noctalia
        _file="${2:-}"
        [ -n "$_file" ] && [ -f "$_file" ] || exit 2
        # The annotate command postdates some shell builds (5.0.1 lacks it);
        # probe once so the caller reports a missing dependency instead of
        # retrying an unknown command and failing with a generic error.
        if ! noctalia msg --help 2>/dev/null | grep -q '^[[:space:]]*annotate'; then
            echo "a Noctalia shell that ships the annotate command"
            exit 1
        fi
        # The handoff can race the shell flushing the fresh capture.
        _i=0
        while [ "$_i" -lt 3 ]; do
            _err=""
            if _err=$(noctalia msg annotate "$_file" 2>&1); then
                printf '%s\n' "$_file"
                exit 0
            fi
            sleep 0.5
            _i=$((_i + 1))
        done
        printf '%s\n' "$_err" >&2
        exit 13
        ;;

    annotate-region|annotate-fullscreen|annotate-window|annotate-window-id)
        _kind="$ACTION"
        _kind="${_kind#annotate-}"
        _nested=""
        _rc=0
        _nested=$("$0" "$_kind-file" "${@:2}") || _rc=$?
        if [ "$_rc" -ne 0 ]; then
            [ -n "$_nested" ] && printf '%s\n' "$_nested"
            exit "$_rc"
        fi
        exec "$0" edit "$_nested"
        ;;

    *)
        echo "ERROR: unknown action '${ACTION}'. Expected: region-file | fullscreen-file | window-file | edit | annotate-region | annotate-fullscreen | annotate-window" >&2
        exit 2
        ;;

esac
