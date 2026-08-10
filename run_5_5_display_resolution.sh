#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 5-5 Display Resolution Test
#
# Ensure a playback video exists, start playback, then switch
# display resolutions one by one. The operator presses Enter to
# move to the next resolution.
#
# Defaults:
#   NAS video:   /mnt/nas_home/TestVideo1.mp4
#   Local video: ~/TestVideo1.mp4
# ============================================================

NAS_VIDEO="${NAS_VIDEO:-/mnt/nas_home/TestVideo1.mp4}"
VIDEO_DEST="${VIDEO_DEST:-${HOME}/TestVideo1.mp4}"
LOG_DIR="${LOG_DIR:-/tmp/display_resolution_5_5_logs}"
PLAYER="${PLAYER:-nvgstplayer-1.0}"
PLAYER_GST_FLAGS="${PLAYER_GST_FLAGS:---gst-disable-segtrap --gst-disable-registry-fork}"
DISPLAY_SYNC="${DISPLAY_SYNC:-true}"
AUTO_ADVANCE_SECONDS="${AUTO_ADVANCE_SECONDS:-}"
VERIFY_TIMEOUT_SECONDS="${VERIFY_TIMEOUT_SECONDS:-8}"
VERIFY_INTERVAL_SECONDS="${VERIFY_INTERVAL_SECONDS:-1}"
MIN_WIDTH="${MIN_WIDTH:-720}"
MIN_HEIGHT="${MIN_HEIGHT:-576}"
MAX_WIDTH="${MAX_WIDTH:-0}"
MAX_HEIGHT="${MAX_HEIGHT:-0}"
MODE_SOURCE="unknown"
GNOME_INTERFACE_SCHEMA="org.gnome.desktop.interface"
GNOME_MUTTER_SCHEMA="org.gnome.mutter"
ORIGINAL_SCALING_FACTOR=""
ORIGINAL_TEXT_SCALING_FACTOR=""
ORIGINAL_EXPERIMENTAL_FEATURES=""
ORIGINAL_MONITOR_SCALE=""
PLAYBACK_PID=""
PLAYBACK_STOP_REQUESTED=false
export DISPLAY="${DISPLAY:-:0}"

if [[ -t 1 ]]; then
  RED=$'\033[31m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  NC=$'\033[0m'
else
  RED=""
  GREEN=""
  YELLOW=""
  NC=""
fi

pass() { printf '%s%s%s\n' "${GREEN}" "$*" "${NC}"; }
fail() { printf '%s%s%s\n' "${RED}" "$*" "${NC}"; }
warn() { printf '%s%s%s\n' "${YELLOW}" "$*" "${NC}"; }

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd" >&2
    exit 1
  fi
}

setup_display() {
  local uid xauth

  export DISPLAY

  if [[ -z "${XAUTHORITY:-}" ]]; then
    uid="$(id -u)"
    for xauth in \
      "${HOME}/.Xauthority" \
      "/run/user/${uid}/gdm/Xauthority" \
      "/run/user/${uid}/Xauthority"; do
      if [[ -r "${xauth}" ]]; then
        export XAUTHORITY="${xauth}"
        break
      fi
    done
  fi
}

file_uri() {
  local path="$1"
  printf 'file://%s' "${path}"
}

ensure_video_file() {
  mkdir -p "$(dirname "${VIDEO_DEST}")"

  if [[ -s "${VIDEO_DEST}" ]]; then
    echo "Local playback video exists: ${VIDEO_DEST}"
    ls -lh "${VIDEO_DEST}"
    return 0
  fi

  if [[ -s "${NAS_VIDEO}" ]]; then
    echo "Local playback video not found."
    echo "Copying NAS video to local:"
    echo "  From: ${NAS_VIDEO}"
    echo "  To:   ${VIDEO_DEST}"
    cp -f "${NAS_VIDEO}" "${VIDEO_DEST}"
    sync "${VIDEO_DEST}" || true
    ls -lh "${VIDEO_DEST}"
    return 0
  fi

  echo "ERROR: playback video not found." >&2
  echo "Local file: ${VIDEO_DEST}" >&2
  echo "NAS file:   ${NAS_VIDEO}" >&2
  echo "Please mount NAS and place TestVideo1.mp4 at the NAS path, or set NAS_VIDEO=/path/to/video." >&2
  exit 1
}

get_connected_output() {
  xrandr --display "$DISPLAY" | awk '/ connected/ { print $1; exit }'
}

get_current_resolution() {
  local output="$1"
  xrandr --display "$DISPLAY" | awk -v output="$output" '
    $1 == output && $2 == "connected" {
      for (i=1; i<=NF; i++) {
        if ($i ~ /^[0-9]+x[0-9]+\+/) {
          split($i, parts, "+")
          print parts[1]
          exit
        }
      }
    }
    in_output && /\*/ {
      print $1
      exit
    }
    $1 == output && $2 == "connected" { in_output=1; next }
    /^[A-Za-z0-9-]+ connected/ && $1 != output { in_output=0 }
  '
}

list_resolutions_desc() {
  local output="$1"
  xrandr --display "$DISPLAY" | awk -v output="$output" '
    $1 == output && $2 == "connected" { in_output=1; next }
    /^[A-Za-z0-9-]+ connected/ && $1 != output { in_output=0 }
    in_output && $1 ~ /^[0-9]+x[0-9]+$/ {
      split($1, dim, "x")
      key = dim[1] * dim[2]
      if (!seen[$1]++) {
        printf "%d %d %s\n", key, dim[1], $1
      }
    }
  ' | sort -k1,1nr -k2,2nr | awk '{ print $3 }'
}

list_resolutions_from_mutter_desc() {
  local output="$1"
  local state

  if ! command -v gdbus >/dev/null 2>&1; then
    return 1
  fi

  state="$(gdbus call --session \
    --dest org.gnome.Mutter.DisplayConfig \
    --object-path /org/gnome/Mutter/DisplayConfig \
    --method org.gnome.Mutter.DisplayConfig.GetCurrentState 2>/dev/null)" || return 1
  MUTTER_STATE="$state" python3 - "$output" "$MIN_WIDTH" "$MIN_HEIGHT" "$MAX_WIDTH" "$MAX_HEIGHT" <<'PY'
import re
import sys
import os

min_width = int(sys.argv[2])
min_height = int(sys.argv[3])
max_width = int(sys.argv[4])
max_height = int(sys.argv[5])
text = os.environ["MUTTER_STATE"]

pattern = re.compile(
    r"\('([^']+)',\s*([0-9]+),\s*([0-9]+),\s*([0-9.]+),\s*[0-9.]+,\s*\[[^\]]*\],\s*\{([^}]*)\}\)"
)

seen = {}
for mode_id, width, height, refresh, props in pattern.findall(text):
    if "x" not in mode_id:
        continue
    try:
        w = int(width)
        h = int(height)
        hz = float(refresh)
    except ValueError:
        continue
    if w < min_width or h < min_height:
        continue
    if max_width > 0 and w > max_width:
        continue
    if max_height > 0 and h > max_height:
        continue

    resolution = f"{w}x{h}"
    priority = hz
    if "is-current" in props:
        priority += 100000
    if "is-preferred" in props:
        priority += 50000
    old = seen.get(resolution)
    if old is None or priority > old[0]:
        seen[resolution] = (priority, w * h, w)

for resolution, (_priority, area, width) in sorted(
    seen.items(), key=lambda item: (-item[1][1], -item[1][2], item[0])
):
    print(resolution)
PY
}

list_resolutions_from_xrandr_filtered_desc() {
  local output="$1"
  list_resolutions_desc "$output" | awk -F'x' \
    -v min_w="$MIN_WIDTH" -v min_h="$MIN_HEIGHT" \
    -v max_w="$MAX_WIDTH" -v max_h="$MAX_HEIGHT" '
    $1 >= min_w && $2 >= min_h &&
    (max_w <= 0 || $1 <= max_w) &&
    (max_h <= 0 || $2 <= max_h) { print $0 }
  '
}

save_gnome_scaling() {
  if ! command -v gsettings >/dev/null 2>&1; then
    return 0
  fi

  ORIGINAL_SCALING_FACTOR="$(gsettings get "$GNOME_INTERFACE_SCHEMA" scaling-factor 2>/dev/null || true)"
  ORIGINAL_TEXT_SCALING_FACTOR="$(gsettings get "$GNOME_INTERFACE_SCHEMA" text-scaling-factor 2>/dev/null || true)"
  ORIGINAL_EXPERIMENTAL_FEATURES="$(gsettings get "$GNOME_MUTTER_SCHEMA" experimental-features 2>/dev/null || true)"
}

force_100_percent_scaling() {
  if command -v gsettings >/dev/null 2>&1; then
    gsettings set "$GNOME_INTERFACE_SCHEMA" scaling-factor 1 2>/dev/null || true
    gsettings set "$GNOME_INTERFACE_SCHEMA" text-scaling-factor 1.0 2>/dev/null || true
  fi
}

# xrandr --scale controls the framebuffer transform, not the scale shown in
# GNOME Settings.  Mutter owns that per-monitor value.  Apply its D-Bus API
# when exactly one display is active; otherwise leave the multi-display layout
# untouched and use the xrandr fallback below.
get_mutter_monitor_scale() {
  local output="$1"
  local connected_count
  connected_count="$(xrandr --display "$DISPLAY" | awk '/ connected/ { count++ } END { print count + 0 }')"
  [[ "$connected_count" == "1" ]] || return 1

  local state
  state="$(gdbus call --session \
    --dest org.gnome.Mutter.DisplayConfig \
    --object-path /org/gnome/Mutter/DisplayConfig \
    --method org.gnome.Mutter.DisplayConfig.GetCurrentState 2>/dev/null)" || return 1
  MUTTER_STATE="$state" python3 - "$output" <<'PY'
import re
import sys
import os

text = os.environ["MUTTER_STATE"]
output = re.escape(sys.argv[1])
match = re.search(
    r"\[\((-?\d+),\s*(-?\d+),\s*([0-9.]+),\s*uint32\s+\d+,\s*"
    r"(?:true|false),\s*\[\('" + output + r"',",
    text,
)
if match:
    print(match.group(3))
PY
}

apply_mutter_mode_and_scale() {
  local output="$1"
  local resolution="$2"
  local scale="$3"
  local connected_count state config serial mode_id x y transform primary logical

  command -v gdbus >/dev/null 2>&1 || return 1
  connected_count="$(xrandr --display "$DISPLAY" | awk '/ connected/ { count++ } END { print count + 0 }')"
  [[ "$connected_count" == "1" ]] || return 1
  state="$(gdbus call --session --dest org.gnome.Mutter.DisplayConfig \
    --object-path /org/gnome/Mutter/DisplayConfig \
    --method org.gnome.Mutter.DisplayConfig.GetCurrentState 2>/dev/null)" || return 1

  config="$(MUTTER_STATE="$state" python3 - "$output" "$resolution" <<'PY'
import re
import sys
import os

text, output, resolution = os.environ["MUTTER_STATE"], sys.argv[1], sys.argv[2]
serial = re.search(r"uint32\s+(\d+)", text)
logical = re.search(
    r"\[\((-?\d+),\s*(-?\d+),\s*[0-9.]+,\s*uint32\s+(\d+),\s*"
    r"(true|false),\s*\[\('" + re.escape(output) + r"',",
    text,
)
if not (serial and logical):
    raise SystemExit(1)

want_w, want_h = map(int, resolution.split("x", 1))
modes = []
for mode_id, width, height, refresh, props in re.findall(
    r"\('([^']+)',\s*(\d+),\s*(\d+),\s*([0-9.]+).*?\{([^}]*)\}\)", text
):
    if int(width) == want_w and int(height) == want_h:
        priority = float(refresh)
        priority += 100000 if "is-current" in props else 0
        priority += 50000 if "is-preferred" in props else 0
        modes.append((priority, mode_id))
if not modes:
    raise SystemExit(1)
mode_id = max(modes)[1]
print("\t".join((serial.group(1), mode_id, logical.group(1), logical.group(2),
                 logical.group(3), logical.group(4))))
PY
)" || return 1

  IFS=$'\t' read -r serial mode_id x y transform primary <<<"$config"
  [[ -n "$serial" && -n "$mode_id" ]] || return 1
  logical="[(${x}, ${y}, ${scale}, ${transform}, ${primary}, [('${output}', '${mode_id}', {})])]"
  gdbus call --session \
    --dest org.gnome.Mutter.DisplayConfig \
    --object-path /org/gnome/Mutter/DisplayConfig \
    --method org.gnome.Mutter.DisplayConfig.ApplyMonitorsConfig \
    "$serial" 1 "$logical" "{}" >/dev/null
}

restore_gnome_scaling() {
  if ! command -v gsettings >/dev/null 2>&1; then
    return 0
  fi

  echo ""
  echo "Restoring GNOME scaling settings if available..."
  if [[ -n "$ORIGINAL_SCALING_FACTOR" ]]; then
    gsettings set "$GNOME_INTERFACE_SCHEMA" scaling-factor "$ORIGINAL_SCALING_FACTOR" 2>/dev/null || true
  fi
  if [[ -n "$ORIGINAL_TEXT_SCALING_FACTOR" ]]; then
    gsettings set "$GNOME_INTERFACE_SCHEMA" text-scaling-factor "$ORIGINAL_TEXT_SCALING_FACTOR" 2>/dev/null || true
  fi
  if [[ -n "$ORIGINAL_EXPERIMENTAL_FEATURES" ]]; then
    gsettings set "$GNOME_MUTTER_SCHEMA" experimental-features "$ORIGINAL_EXPERIMENTAL_FEATURES" 2>/dev/null || true
  fi
}

switch_resolution() {
  local output="$1"
  local resolution="$2"
  local scale="${3:-1.0}"
  echo ""
  echo "Switching ${output} to ${resolution}"
  if apply_mutter_mode_and_scale "$output" "$resolution" "$scale"; then
    echo "Applied GNOME per-monitor scale: ${scale}"
  else
    warn "Could not apply the GNOME per-monitor configuration; falling back to xrandr."
    echo "Command: xrandr --display ${DISPLAY} --output ${output} --mode ${resolution} --scale 1x1"
    xrandr --display "$DISPLAY" --output "$output" --mode "$resolution" --scale 1x1
  fi
  force_100_percent_scaling
}

verify_resolution() {
  local output="$1"
  local expected="$2"
  local elapsed=0
  local current=""

  while [[ "$elapsed" -le "$VERIFY_TIMEOUT_SECONDS" ]]; do
    current="$(get_current_resolution "$output")"
    if [[ "$current" == "$expected" ]]; then
      pass "RESULT,DISPLAY_RESOLUTION,${output},${expected},MODE_PASS"
      return 0
    fi
    sleep "$VERIFY_INTERVAL_SECONDS"
    elapsed=$((elapsed + VERIFY_INTERVAL_SECONDS))
  done

  fail "RESULT,DISPLAY_RESOLUTION,${output},${expected},MODE_FAIL,current=${current:-unknown}"
  return 1
}

start_playback_loop() {
  local source="$1"
  local log="$2"
  local uri
  uri="$(file_uri "$source")"

  {
    echo "Playback source: ${source}"
    echo "Playback URI: ${uri}"
    echo "Player: ${PLAYER} ${PLAYER_GST_FLAGS} -i"
    echo "Started: $(date --iso-8601=seconds)"
    echo
  } >"${log}"

  (
    child_pid=""
    input_fifo="$(mktemp -u /tmp/5_5_nvgstplayer_input_XXXXXX)"
    mkfifo "${input_fifo}"
    exec {input_fd}<>"${input_fifo}"

    stop_child() {
      if [[ -n "${child_pid}" ]] && kill -0 "${child_pid}" 2>/dev/null; then
        printf 'q\n' >&"${input_fd}" 2>/dev/null || true
        kill -TERM "${child_pid}" 2>/dev/null || true
        sleep 1
        kill -KILL "${child_pid}" 2>/dev/null || true
      fi
      exec {input_fd}>&- 2>/dev/null || true
      rm -f "${input_fifo}"
      exit 0
    }
    trap stop_child TERM INT

    read -r -a player_gst_flags <<<"${PLAYER_GST_FLAGS}"
    while [[ "${PLAYBACK_STOP_REQUESTED}" != "true" ]]; do
      "${PLAYER}" "${player_gst_flags[@]}" -i "${uri}" >>"${log}" 2>&1 <"${input_fifo}" &
      child_pid=$!
      wait "${child_pid}" || true
      child_pid=""
      sleep 1
    done

    exec {input_fd}>&- 2>/dev/null || true
    rm -f "${input_fifo}"
  ) &
  PLAYBACK_PID=$!
  echo "Playback started in background. PID: ${PLAYBACK_PID}"
  echo "Playback log: ${log}"
}

stop_playback() {
  PLAYBACK_STOP_REQUESTED=true
  if [[ -n "${PLAYBACK_PID}" ]] && kill -0 "${PLAYBACK_PID}" 2>/dev/null; then
    kill -TERM "${PLAYBACK_PID}" 2>/dev/null || true
    sleep 1
    kill -KILL "${PLAYBACK_PID}" 2>/dev/null || true
    wait "${PLAYBACK_PID}" 2>/dev/null || true
  fi
}

cleanup() {
  stop_playback
  if [[ -n "${OUTPUT:-}" && -n "${ORIGINAL_RESOLUTION:-}" ]]; then
    echo ""
    echo "Returning to original resolution: ${ORIGINAL_RESOLUTION}"
    switch_resolution "$OUTPUT" "$ORIGINAL_RESOLUTION" "${ORIGINAL_MONITOR_SCALE:-1.0}" || true
  fi
  restore_gnome_scaling
}

handle_interrupt() {
  echo ""
  echo "Interrupted. Stopping playback and restoring display..."
  cleanup
  exit 130
}

prompt_next_resolution() {
  local output="$1"
  local resolution="$2"
  local answer

  if [[ ! -t 0 ]]; then
    if [[ -n "${AUTO_ADVANCE_SECONDS}" ]]; then
      warn "Non-interactive shell; continuing automatically after ${AUTO_ADVANCE_SECONDS}s for resolution ${resolution}."
      sleep "${AUTO_ADVANCE_SECONDS}"
      return 0
    fi
    echo "ERROR: interactive stdin is required so the operator can press Enter after checking the display." >&2
    echo "Run this script from the Jetson terminal, or use SSH with a TTY." >&2
    echo "For automated dry runs only, set AUTO_ADVANCE_SECONDS=3." >&2
    return 2
  fi

  echo ""
  echo "Video should be playing at ${resolution} on ${output}."
  read -r -p "Press Enter to switch to next resolution. Type n to mark FAIL and continue: " answer
  case "$answer" in
    n|N|no|NO)
      fail "RESULT,DISPLAY_RESOLUTION_PLAYBACK,${output},${resolution},VISIBLE_FAIL"
      return 1
      ;;
    *)
      pass "RESULT,DISPLAY_RESOLUTION_PLAYBACK,${output},${resolution},VISIBLE_PASS"
      return 0
      ;;
  esac
}

echo "======================================"
echo "5-5 Display Resolution Test"
echo "Host: $(hostname)"
echo "Date: $(date --iso-8601=seconds)"
echo "DISPLAY: ${DISPLAY}"
echo "Resolution range: ${MIN_WIDTH}x${MIN_HEIGHT} to ${MAX_WIDTH}x${MAX_HEIGHT}"
echo "NAS video: ${NAS_VIDEO}"
echo "Local video: ${VIDEO_DEST}"
echo "Auto advance: ${AUTO_ADVANCE_SECONDS:-disabled}"
echo "======================================"

require_cmd xrandr
require_cmd python3
require_cmd "${PLAYER}"
setup_display
save_gnome_scaling
trap handle_interrupt INT TERM

ensure_video_file

OUTPUT="${OUTPUT:-$(get_connected_output)}"
if [[ -z "$OUTPUT" ]]; then
  echo "ERROR: no connected display output found by xrandr." >&2
  exit 1
fi

mapfile -t RESOLUTIONS < <(list_resolutions_from_mutter_desc "$OUTPUT")
if [[ "${#RESOLUTIONS[@]}" -gt 0 ]]; then
  MODE_SOURCE="gnome-mutter-displayconfig"
else
  warn "Could not read resolutions from GNOME Mutter DisplayConfig; fallback to xrandr."
  mapfile -t RESOLUTIONS < <(list_resolutions_from_xrandr_filtered_desc "$OUTPUT")
  MODE_SOURCE="xrandr"
fi

if [[ "${#RESOLUTIONS[@]}" -eq 0 ]]; then
  echo "ERROR: no resolutions found for output: $OUTPUT" >&2
  xrandr --display "$DISPLAY"
  exit 1
fi

ORIGINAL_RESOLUTION="$(get_current_resolution "$OUTPUT")"
MAX_RESOLUTION="${RESOLUTIONS[0]}"
ORIGINAL_MONITOR_SCALE="$(get_mutter_monitor_scale "$OUTPUT" || true)"

echo ""
echo "Output: ${OUTPUT}"
echo "Resolution source: ${MODE_SOURCE}"
echo "Original resolution: ${ORIGINAL_RESOLUTION:-unknown}"
echo "Original GNOME per-monitor scale: ${ORIGINAL_MONITOR_SCALE:-unknown}"
echo "Detected resolutions from largest to smallest:"
for resolution in "${RESOLUTIONS[@]}"; do
  echo "  ${resolution}"
done
echo ""
echo "The video will start first. Press Enter after checking each resolution."

if [[ -t 0 ]]; then
  read -r -p "Press Enter to start, or type n to cancel: " answer
  case "$answer" in
    n|N|no|NO)
      echo "Canceled."
      exit 0
      ;;
  esac
elif [[ -z "${AUTO_ADVANCE_SECONDS}" ]]; then
  echo "ERROR: interactive stdin is required for this test." >&2
  echo "Run this script from the Jetson terminal, or use SSH with a TTY." >&2
  echo "For automated dry runs only, set AUTO_ADVANCE_SECONDS=3." >&2
  exit 2
fi

mkdir -p "${LOG_DIR}"
PLAYBACK_LOG="${LOG_DIR}/playback.log"
start_playback_loop "${VIDEO_DEST}" "${PLAYBACK_LOG}"
sleep 3

overall_rc=0
for resolution in "${RESOLUTIONS[@]}"; do
  if switch_resolution "$OUTPUT" "$resolution" && verify_resolution "$OUTPUT" "$resolution"; then
    if ! prompt_next_resolution "$OUTPUT" "$resolution"; then
      overall_rc=1
    fi
  else
    overall_rc=1
  fi
done

cleanup
trap - INT TERM

echo ""
echo "Playback log: ${PLAYBACK_LOG}"
if [[ "$overall_rc" -eq 0 ]]; then
  pass "TEST COMPLETE: 5-5 Display Resolution = PASS"
else
  fail "TEST COMPLETE: 5-5 Display Resolution = FAIL"
fi

exit "$overall_rc"
