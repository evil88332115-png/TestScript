#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 4-5 Resolution Test
#
# Detect all available resolutions from the current connected display,
# switch from largest to smallest, verify each switch, then restore the
# original resolution and GNOME per-monitor scale.
#
# Requirement:
#   xrandr
# ============================================================

export DISPLAY="${DISPLAY:-:0}"
VERIFY_TIMEOUT_SECONDS="${VERIFY_TIMEOUT_SECONDS:-8}"
VERIFY_INTERVAL_SECONDS="${VERIFY_INTERVAL_SECONDS:-1}"
MIN_WIDTH="${MIN_WIDTH:-720}"
MIN_HEIGHT="${MIN_HEIGHT:-576}"
MODE_SOURCE="unknown"
GNOME_INTERFACE_SCHEMA="org.gnome.desktop.interface"
GNOME_MUTTER_SCHEMA="org.gnome.mutter"
ORIGINAL_SCALING_FACTOR=""
ORIGINAL_TEXT_SCALING_FACTOR=""
ORIGINAL_EXPERIMENTAL_FEATURES=""
ORIGINAL_MONITOR_SCALE=""

if [ -t 1 ]; then
  RED="\033[31m"
  GREEN="\033[32m"
  YELLOW="\033[33m"
  NC="\033[0m"
else
  RED=""
  GREEN=""
  YELLOW=""
  NC=""
fi

pass() { echo -e "${GREEN}$*${NC}"; }
fail() { echo -e "${RED}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd" >&2
    exit 1
  fi
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
  MUTTER_STATE="$state" python3 - "$output" "$MIN_WIDTH" "$MIN_HEIGHT" <<'PY'
import re
import sys
import os

target_output = sys.argv[1]
min_width = int(sys.argv[2])
min_height = int(sys.argv[3])
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

    # Deduplicate by resolution. Prefer current/preferred, then higher refresh.
    resolution = f"{w}x{h}"
    priority = 0
    if "is-current" in props:
        priority += 100000
    if "is-preferred" in props:
        priority += 50000
    priority += hz
    old = seen.get(resolution)
    if old is None or priority > old[0]:
        seen[resolution] = (priority, w * h, w, h)

for resolution, (_priority, area, w, _h) in sorted(
    seen.items(), key=lambda item: (-item[1][1], -item[1][2], item[0])
):
    print(resolution)
PY
}

list_resolutions_from_xrandr_filtered_desc() {
  local output="$1"
  list_resolutions_desc "$output" | awk -F'x' -v min_w="$MIN_WIDTH" -v min_h="$MIN_HEIGHT" '
    $1 >= min_w && $2 >= min_h { print $0 }
  '
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

  while [ "$elapsed" -le "$VERIFY_TIMEOUT_SECONDS" ]; do
    current="$(get_current_resolution "$output")"
    if [ "$current" = "$expected" ]; then
      pass "RESULT,RESOLUTION,${output},${expected},MODE_PASS"
      return 0
    fi
    sleep "$VERIFY_INTERVAL_SECONDS"
    elapsed=$((elapsed + VERIFY_INTERVAL_SECONDS))
  done

  fail "RESULT,RESOLUTION,${output},${expected},MODE_FAIL,current=${current:-unknown}"
  return 1
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
# untouched and use the xrandr fallback above.
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
  if [ -n "$ORIGINAL_SCALING_FACTOR" ]; then
    echo "Restore scaling-factor: $ORIGINAL_SCALING_FACTOR"
    gsettings set "$GNOME_INTERFACE_SCHEMA" scaling-factor "$ORIGINAL_SCALING_FACTOR" 2>/dev/null || true
  fi
  if [ -n "$ORIGINAL_TEXT_SCALING_FACTOR" ]; then
    echo "Restore text-scaling-factor: $ORIGINAL_TEXT_SCALING_FACTOR"
    gsettings set "$GNOME_INTERFACE_SCHEMA" text-scaling-factor "$ORIGINAL_TEXT_SCALING_FACTOR" 2>/dev/null || true
  fi
  if [ -n "$ORIGINAL_EXPERIMENTAL_FEATURES" ]; then
    echo "Restore mutter experimental-features: $ORIGINAL_EXPERIMENTAL_FEATURES"
    gsettings set "$GNOME_MUTTER_SCHEMA" experimental-features "$ORIGINAL_EXPERIMENTAL_FEATURES" 2>/dev/null || true
  fi
}

confirm_visible() {
  local output="$1"
  local resolution="$2"
  local answer

  if [ ! -t 0 ]; then
    warn "Non-interactive shell; cannot confirm visible display."
    return 0
  fi

  echo ""
  echo "Resolution ${resolution} is set on ${output}."
  read -r -p "If the display is visible/correct, press Enter to continue. Type n to mark FAIL and continue: " answer
  case "$answer" in
    n|N|no|NO)
      fail "RESULT,RESOLUTION,${output},${resolution},VISIBLE_FAIL"
      return 1
      ;;
    *)
      pass "RESULT,RESOLUTION,${output},${resolution},VISIBLE_PASS"
      return 0
      ;;
  esac
}

handle_interrupt() {
  echo ""
  echo "Interrupted. Restoring the original resolution and scaling..."
  if [ -n "${OUTPUT:-}" ] && [ -n "${ORIGINAL_RESOLUTION:-}" ]; then
    switch_resolution "$OUTPUT" "$ORIGINAL_RESOLUTION" "${ORIGINAL_MONITOR_SCALE:-1.0}" || true
  fi
  restore_gnome_scaling
  exit 130
}

echo "======================================"
echo "4-5 Resolution Test"
echo "Host: $(hostname)"
echo "Date: $(date -Iseconds)"
echo "DISPLAY: ${DISPLAY}"
echo "Minimum resolution: ${MIN_WIDTH}x${MIN_HEIGHT}"
echo "======================================"

require_cmd xrandr
save_gnome_scaling
trap handle_interrupt INT TERM

OUTPUT="${OUTPUT:-$(get_connected_output)}"
if [ -z "$OUTPUT" ]; then
  echo "ERROR: no connected display output found by xrandr." >&2
  exit 1
fi

mapfile -t RESOLUTIONS < <(list_resolutions_from_mutter_desc "$OUTPUT")
if [ "${#RESOLUTIONS[@]}" -gt 0 ]; then
  MODE_SOURCE="gnome-mutter-displayconfig"
else
  warn "Could not read resolutions from GNOME Mutter DisplayConfig; fallback to xrandr."
  mapfile -t RESOLUTIONS < <(list_resolutions_from_xrandr_filtered_desc "$OUTPUT")
  MODE_SOURCE="xrandr"
fi

if [ "${#RESOLUTIONS[@]}" -eq 0 ]; then
  echo "ERROR: no resolutions found for output: $OUTPUT" >&2
  xrandr --display "$DISPLAY"
  exit 1
fi

ORIGINAL_RESOLUTION="$(get_current_resolution "$OUTPUT")"
MAX_RESOLUTION="${RESOLUTIONS[0]}"
ORIGINAL_MONITOR_SCALE="$(get_mutter_monitor_scale "$OUTPUT" || true)"

echo "Output: ${OUTPUT}"
echo "Resolution source: ${MODE_SOURCE}"
echo "Original resolution: ${ORIGINAL_RESOLUTION:-unknown}"
echo "Original GNOME scaling-factor: ${ORIGINAL_SCALING_FACTOR:-unknown}"
echo "Original GNOME text-scaling-factor: ${ORIGINAL_TEXT_SCALING_FACTOR:-unknown}"
echo "Original GNOME per-monitor scale: ${ORIGINAL_MONITOR_SCALE:-unknown}"
echo "Detected resolutions from largest to smallest:"
for resolution in "${RESOLUTIONS[@]}"; do
  echo "  ${resolution}"
done

echo ""
echo "The screen will switch through all detected resolutions."
if [ -t 0 ]; then
  read -r -p "Press Enter to start, or type n to cancel: " answer
  case "$answer" in
    n|N|no|NO)
      echo "Canceled."
      exit 0
      ;;
  esac
fi

overall_rc=0
for resolution in "${RESOLUTIONS[@]}"; do
  if switch_resolution "$OUTPUT" "$resolution" && verify_resolution "$OUTPUT" "$resolution"; then
    if ! confirm_visible "$OUTPUT" "$resolution"; then
      overall_rc=1
    fi
  else
    overall_rc=1
  fi
done

echo ""
echo "Returning to original resolution: ${ORIGINAL_RESOLUTION}"
if switch_resolution "$OUTPUT" "$ORIGINAL_RESOLUTION" "${ORIGINAL_MONITOR_SCALE:-1.0}" && verify_resolution "$OUTPUT" "$ORIGINAL_RESOLUTION"; then
  confirm_visible "$OUTPUT" "$ORIGINAL_RESOLUTION" || overall_rc=1
else
  overall_rc=1
fi

restore_gnome_scaling

echo ""
if [ "$overall_rc" -eq 0 ]; then
  pass "TEST COMPLETE: 4-5 Resolution = PASS"
else
  fail "TEST COMPLETE: 4-5 Resolution = FAIL"
fi

exit "$overall_rc"
