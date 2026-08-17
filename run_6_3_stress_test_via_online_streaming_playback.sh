#!/bin/bash
set -u

# ============================================================
# 6-3 Stress Test via Streaming Playback
#
# Playback source:
#   1. Online HTTP stream served by nginx on a remote host
#   2. Direct playback from TestVideo.mp4 at the NAS mount root
#
# Test stops when the requested duration is reached.
# Ctrl+C also stops test and still attempts to draw the temperature curve.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

TEST_NAME="6-3 Stress Test via Streaming Playback"
ENABLE_AUDIO="${ENABLE_AUDIO:-true}"
ENABLE_SYS_STATS="${ENABLE_SYS_STATS:-true}"
ENABLE_FPS="${ENABLE_FPS:-true}"
DISPLAY_SYNC="${DISPLAY_SYNC:-true}"
STATS_PLATFORM="${STATS_PLATFORM:-auto}"
LOOP_FOREVER="${LOOP_FOREVER:-true}"
STATUS_WIDTH="${STATUS_WIDTH:-78}"
TEST_DURATION_SECONDS="${TEST_DURATION_SECONDS:-}"
AVG_INTERVAL_MIN="${AVG_INTERVAL_MIN:-}"
RESULT_DIR=""
TEGRASTATS_LOG=""
TEGRASTATS_PID=""
TEST_END_TS=0
TEST_TIME_UP=false

SERVER_HOST=""
SERVER_USER=""
SERVER_PASS=""
VIDEO_BASENAME=""
URL=""
PLAYBACK_SOURCE_MODE="${PLAYBACK_SOURCE_MODE:-}"
NAS_VIDEO="${NAS_VIDEO:-/mnt/nas_home/TestVideo.mp4}"
PLAYBACK_SOURCE=""
VIDEO_CODEC=""
AUDIO_CODEC=""
FORMAT_NAME=""
SOURCE_FPS=""

if [ -t 1 ]; then
    RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; NC="\033[0m"
else
    RED=""; GREEN=""; YELLOW=""; NC=""
fi

print_pass() { echo -e "${GREEN}$1${NC}"; }
print_fail() { echo -e "${RED}$1${NC}"; }
print_warn() { echo -e "${YELLOW}$1${NC}" >&2; }
print_hwdecode() { echo -e "${GREEN}[HW Decode] $1${NC}"; }
print_swdecode() { echo -e "${RED}[SW Decode / Fallback] $1${NC}"; }

setup_display() {
    local uid xauth

    export DISPLAY="${DISPLAY:-:0}"

    if [ -z "${XAUTHORITY:-}" ]; then
        uid="$(id -u)"
        for xauth in \
            "${HOME}/.Xauthority" \
            "/run/user/${uid}/gdm/Xauthority" \
            "/run/user/${uid}/Xauthority"; do
            if [ -r "$xauth" ]; then
                export XAUTHORITY="$xauth"
                break
            fi
        done
    fi
}

cleanup_tegrastats() {
    if [ -n "${TEGRASTATS_PID:-}" ] && kill -0 "$TEGRASTATS_PID" >/dev/null 2>&1; then
        kill "$TEGRASTATS_PID" >/dev/null 2>&1 || true
        wait "$TEGRASTATS_PID" >/dev/null 2>&1 || true
    fi
    TEGRASTATS_PID=""
}

draw_temperature_curve() {
    local out_png

    [ -n "$TEGRASTATS_LOG" ] || return 0
    [ -s "$TEGRASTATS_LOG" ] || {
        echo "WARNING: tegrastats log is empty, skip drawing."
        return 0
    }

    out_png="${RESULT_DIR}/tegrastats_cpu_gpu.png"
    echo ""
    echo "Drawing CPU+GPU temperature curve..."
    echo "Input: $TEGRASTATS_LOG"
    echo "Output: $out_png"

    if ! command -v python3 >/dev/null 2>&1; then
        echo "ERROR: python3 not found. Cannot draw temperature curve."
        return 1
    fi

    if ! python3 "$SCRIPT_DIR/drawtempcurve_auto.py" \
        --file "$TEGRASTATS_LOG" \
        --mode cpu_gpu \
        --avg-min "$AVG_INTERVAL_MIN" \
        --interval-ms 1000 \
        --out "$out_png"; then
        echo "ERROR: drawtempcurve_auto.py failed."
        return 1
    fi

    print_pass "RESULT,TEMP_CURVE,$out_png,PASS"
}

finish_test() {
    cleanup_tegrastats
    draw_temperature_curve || true
    if [ -n "$RESULT_DIR" ]; then
        {
            echo "Test name: $TEST_NAME"
            echo "Host: $(hostname)"
            echo "Date finished: $(date -Iseconds)"
            echo "Server: $SERVER_HOST"
            echo "Playback source mode: $PLAYBACK_SOURCE_MODE"
            echo "Playback source: $PLAYBACK_SOURCE"
            echo "URI: $URL"
            echo "Duration seconds: $TEST_DURATION_SECONDS"
            echo "Average interval minutes: $AVG_INTERVAL_MIN"
            echo "Video codec: $VIDEO_CODEC"
            echo "Audio codec: $AUDIO_CODEC"
            echo "Format: $FORMAT_NAME"
            echo "Source FPS: $SOURCE_FPS"
            echo "Tegrastats log: $TEGRASTATS_LOG"
            echo "Temperature PNG: ${RESULT_DIR}/tegrastats_cpu_gpu.png"
        } > "${RESULT_DIR}/test_summary.txt"
        echo ""
        echo "Result directory: $RESULT_DIR"
    fi
}

handle_interrupt() {
    echo ""
    echo "Interrupted. Stopping stress test..."
    TEST_TIME_UP=true
    finish_test
    exit 130
}

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: required command not found: $cmd"
        return 1
    fi
    return 0
}

ensure_sshpass() {
    if command -v sshpass >/dev/null 2>&1; then
        return 0
    fi
    echo "sshpass not found. Installing sshpass..."
    sudo apt-get update
    sudo apt-get install -y sshpass
}

prompt_test_duration() {
    local input

    if [ -z "$TEST_DURATION_SECONDS" ]; then
        read -rp "Enter stress test duration in seconds [43200]: " input
        TEST_DURATION_SECONDS="${input:-43200}"
    fi

    if ! echo "$TEST_DURATION_SECONDS" | grep -Eq '^[0-9]+$' || [ "$TEST_DURATION_SECONDS" -lt 1 ]; then
        echo "ERROR: duration must be an integer >= 1."
        exit 1
    fi

    if [ -z "$AVG_INTERVAL_MIN" ]; then
        read -rp "Temperature graph average interval in minutes, 0 = raw [30]: " input
        AVG_INTERVAL_MIN="${input:-30}"
    fi

    if ! echo "$AVG_INTERVAL_MIN" | grep -Eq '^[0-9]+([.][0-9]+)?$'; then
        echo "ERROR: average interval must be a number >= 0."
        exit 1
    fi
}

start_tegrastats_log() {
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    RESULT_DIR="${HOME}/6-3_streaming_stress_${ts}"
    mkdir -p "$RESULT_DIR"
    TEGRASTATS_LOG="${RESULT_DIR}/tegrastats.log"

    if ! command -v tegrastats >/dev/null 2>&1; then
        echo "WARNING: tegrastats not found. Temperature log/curve will be skipped."
        return 0
    fi

    echo "Starting tegrastats log: $TEGRASTATS_LOG"
    tegrastats --interval 1000 > "$TEGRASTATS_LOG" 2>&1 &
    TEGRASTATS_PID=$!
}

read_cpu_totals() {
    awk '/^cpu / {
        idle=$5+$6
        total=0
        for (i=2; i<=NF; i++) total+=$i
        print idle, total
        exit
    }' /proc/stat
}

read_thermal_temp() {
    local pattern="${1:-}" path temp type
    for path in /sys/class/thermal/thermal_zone*; do
        [ -r "$path/temp" ] || continue
        type=""
        [ -r "$path/type" ] && type="$(cat "$path/type" 2>/dev/null || true)"
        if [ -z "$pattern" ] || echo "$type" | grep -qiE "$pattern"; then
            temp="$(cat "$path/temp" 2>/dev/null || true)"
            if [ -n "$temp" ]; then
                awk -v t="$temp" 'BEGIN { if (t > 1000) printf "%.1f", t / 1000; else printf "%.1f", t }'
                return 0
            fi
        fi
    done
    echo "N/A"
}

read_jetson_gpu_stats() {
    command -v tegrastats >/dev/null 2>&1 || { echo "N/A N/A"; return 0; }
    timeout 2 tegrastats --interval 1000 2>/dev/null | head -n 1 | awk '
        {
            gpu_usage = "N/A"
            gpu_temp = "N/A"
            if (match($0, /GR3D_FREQ [0-9]+%/)) gpu_usage = substr($0, RSTART + 10, RLENGTH - 11)
            if (match($0, /[Gg][Pp][Uu]@[0-9.]+C/)) gpu_temp = substr($0, RSTART + 4, RLENGTH - 5)
            printf "%s %s", gpu_usage, gpu_temp
        }'
}

detect_stats_platform() {
    local model machine cpuinfo
    model="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)"
    machine="$(uname -m 2>/dev/null || true)"
    cpuinfo="$(cat /proc/cpuinfo 2>/dev/null || true)"
    if command -v tegrastats >/dev/null 2>&1 || echo "$model $cpuinfo" | grep -qiE "nvidia|jetson|tegra"; then
        echo "jetson"
    elif echo "$machine" | grep -qiE "x86_64|amd64|i[3-6]86"; then
        echo "x86"
    else
        echo "other"
    fi
}

detect_display_mode() {
    local mode
    if command -v xrandr >/dev/null 2>&1; then
        mode="$(xrandr --display "${DISPLAY:-:0}" 2>/dev/null | awk '
            /^[A-Za-z0-9-]+ connected/ { output=$1 }
            /\*/ {
                refresh=$2
                gsub(/\*/, "", refresh)
                gsub(/\+/, "", refresh)
                printf "%s@%sHz", $1, refresh
                exit
            }')"
        [ -n "$mode" ] && { echo "$mode"; return 0; }
    fi
    echo "N/A"
}

latest_fps_from_log() {
    local gst_log="$1"
    [ "$ENABLE_FPS" = "true" ] || { echo "disabled"; return 0; }
    [ -s "$gst_log" ] || { echo ""; return 0; }
    awk '
        /fps=\(double\)[0-9.]+/ {
            line = $0
            sub(/^.*fps=\(double\)/, "", line)
            sub(/[^0-9.].*$/, "", line)
            if (line != "") latest=line
        }
        /[Uu]pdated max-fps to/ {
            fps=$NF
            gsub(/[^0-9.]/, "", fps)
            if (fps != "") latest=fps
        }
        /current[=: ]+[0-9.]+/ {
            line=$0
            sub(/^.*current[=: ]+/, "", line)
            sub(/[^0-9.].*$/, "", line)
            gsub(/[^0-9.]/, "", line)
            if (line != "") latest=line
        }
        END { print latest }
    ' "$gst_log" 2>/dev/null | tail -n 1
}

probe_video_codec() {
    ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n 1 || true
}

probe_audio_codec() {
    ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n 1 || true
}

probe_format() {
    ffprobe -v error -show_entries format=format_name -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n 1 || true
}

probe_video_fps() {
    ffprobe -v error -select_streams v:0 \
        -show_entries stream=avg_frame_rate,r_frame_rate \
        -of default=nw=1:nk=1 "$1" 2>/dev/null | awk '
            function fps_value(rate, parts) {
                split(rate, parts, "/")
                if (parts[1] == "" || parts[1] == "0") return ""
                if (parts[2] == "" || parts[2] == "0") return parts[1]
                return sprintf("%.3f", parts[1] / parts[2])
            }
            {
                v = fps_value($0)
                if (v != "" && v != "0.000") {
                    print v
                    exit
                }
            }' | head -n 1 || true
}

get_parser() {
    case "$1" in
        h264) echo "h264parse" ;;
        hevc|h265) echo "h265parse" ;;
        vp9) gst-inspect-1.0 vp9parse >/dev/null 2>&1 && echo "vp9parse" || echo "" ;;
        av1) gst-inspect-1.0 av1parse >/dev/null 2>&1 && echo "av1parse" || echo "" ;;
        vp8) gst-inspect-1.0 vp8parse >/dev/null 2>&1 && echo "vp8parse" || echo "" ;;
        mpeg4) gst-inspect-1.0 mpeg4videoparse >/dev/null 2>&1 && echo "mpeg4videoparse" || echo "" ;;
        *) echo "" ;;
    esac
}

get_demux() {
    local url="$1" format="${2:-}" lower
    lower="$(echo "$url" | tr '[:upper:]' '[:lower:]')"
    if echo "$format" | grep -qiE 'mpegts'; then echo "tsdemux"; return; fi
    if echo "$format" | grep -qiE 'matroska|webm'; then echo "matroskademux"; return; fi
    if echo "$format" | grep -qiE 'mov|mp4|m4a|3gp|3g2|mj2'; then echo "qtdemux"; return; fi
    if echo "$format" | grep -qiE 'avi'; then echo "avidemux"; return; fi
    case "$lower" in
        *.mp4|*.m4v|*.mov|*.3gp) echo "qtdemux" ;;
        *.mkv|*.webm) echo "matroskademux" ;;
        *.m2ts|*.mts|*.ts) echo "tsdemux" ;;
        *.avi|*.divx) echo "avidemux" ;;
        *) echo "" ;;
    esac
}

jetson_hw_supported_codec() {
    case "$1" in
        h264|hevc|h265|vp9|av1) return 0 ;;
        *) return 1 ;;
    esac
}

audio_supported_for_demux() {
    case "$1" in qtdemux|matroskademux) return 0 ;; *) return 1 ;; esac
}

make_sink_parts() {
    if [ "$ENABLE_FPS" = "true" ]; then
        if gst-inspect-1.0 nv3dsink >/dev/null 2>&1; then
            SINK_PARTS=(fpsdisplaysink video-sink=nv3dsink text-overlay=false silent=false fps-update-interval=1000 sync="$DISPLAY_SYNC")
        else
            print_warn "nv3dsink not found. Using autovideosink."
            SINK_PARTS=(fpsdisplaysink video-sink=autovideosink text-overlay=false silent=false fps-update-interval=1000 sync="$DISPLAY_SYNC")
        fi
    else
        if gst-inspect-1.0 nv3dsink >/dev/null 2>&1; then
            SINK_PARTS=(nv3dsink sync="$DISPLAY_SYNC")
        else
            SINK_PARTS=(autovideosink)
        fi
    fi
}

print_command() {
    echo ""
    echo "Command:"
    printf '  '
    printf '%q ' "$@"
    echo ""
    echo ""
}

setup_video_server() {
    local remote_env remote_probe_output remote_video_name

    ensure_sshpass || return 1
    remote_env="$(printf 'SERVER_PASS=%q bash -s' "$SERVER_PASS")"

    echo ""
    echo "Setting up nginx video server on ${SERVER_USER}@${SERVER_HOST}..."
    SSHPASS="$SERVER_PASS" sshpass -e ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "${SERVER_USER}@${SERVER_HOST}" \
        "$remote_env" <<'REMOTE_SETUP'
set -e

run_sudo() {
    printf '%s\n' "$SERVER_PASS" | sudo -S -p '' "$@"
}

if ! command -v nginx >/dev/null 2>&1; then
    echo "nginx not found. Installing nginx..."
    run_sudo apt-get update
    run_sudo apt-get install -y nginx
else
    echo "nginx found: $(command -v nginx)"
fi

run_sudo mkdir -p /var/www/html
if command -v systemctl >/dev/null 2>&1; then
    run_sudo systemctl start nginx || run_sudo systemctl restart nginx || true
else
    run_sudo service nginx start || true
fi

if systemctl is-active --quiet nginx 2>/dev/null || pgrep -x nginx >/dev/null 2>&1; then
    echo "NGINX_STATUS=RUNNING"
else
    echo "NGINX_STATUS=FAILED"
    exit 1
fi
REMOTE_SETUP
    [ "$?" -eq 0 ] || return 1

    echo "Checking remote /var/www/html/TestVideo.* ..."
    if remote_probe_output="$(SSHPASS="$SERVER_PASS" sshpass -e ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "${SERVER_USER}@${SERVER_HOST}" \
        "$remote_env" <<'REMOTE_FIND'
set -e
run_sudo() {
    printf '%s\n' "$SERVER_PASS" | sudo -S -p '' "$@"
}
for name in TestVideo.mp4 TestVideo.mkv TestVideo.mov TestVideo.avi TestVideo.ts TestVideo.m2ts TestVideo.webm; do
    if run_sudo test -f "/var/www/html/$name"; then
        run_sudo ls -lh "/var/www/html/$name"
        echo "__REMOTE_VIDEO_NAME__=$name"
        exit 0
    fi
done
exit 1
REMOTE_FIND
    )"; then
        remote_video_name="$(printf '%s\n' "$remote_probe_output" | sed -n 's/^__REMOTE_VIDEO_NAME__=//p' | head -n 1)"
        printf '%s\n' "$remote_probe_output" | sed '/^__REMOTE_VIDEO_NAME__=/d'
        if [ -n "$remote_video_name" ]; then
            VIDEO_BASENAME="$remote_video_name"
            URL="http://${SERVER_HOST}/${VIDEO_BASENAME}"
            print_pass "RESULT,NGINX_SERVER_CHECK,$SERVER_HOST,PASS"
            echo "Target URL: $URL"
            return 0
        fi
    fi

    echo "ERROR: no TestVideo.* found on server /var/www/html."
    echo "Please put one of these files on the server:"
    echo "  /var/www/html/TestVideo.mp4"
    echo "  /var/www/html/TestVideo.mkv"
    echo "  /var/www/html/TestVideo.mov"
    echo "  /var/www/html/TestVideo.avi"
    echo "  /var/www/html/TestVideo.ts"
    echo "  /var/www/html/TestVideo.m2ts"
    echo "  /var/www/html/TestVideo.webm"
    return 1
}

select_playback_source() {
    local choice

    if [ -n "$PLAYBACK_SOURCE_MODE" ]; then
        case "$PLAYBACK_SOURCE_MODE" in
            online|http|nginx) PLAYBACK_SOURCE_MODE="online" ;;
            nas|nas_direct|local) PLAYBACK_SOURCE_MODE="nas" ;;
            *)
                echo "ERROR: unsupported PLAYBACK_SOURCE_MODE=$PLAYBACK_SOURCE_MODE. Use online or nas."
                return 1
                ;;
        esac
    elif [ ! -t 0 ]; then
        PLAYBACK_SOURCE_MODE="online"
        echo "Non-interactive shell; defaulting playback source to online nginx streaming."
    else
        echo ""
        echo "Playback source:"
        echo "1) Online HTTP streaming via nginx (existing test flow)"
        echo "2) Direct NAS playback: $NAS_VIDEO"
        read -rp "Select [1/2, default 1]: " choice
        case "$choice" in
            2) PLAYBACK_SOURCE_MODE="nas" ;;
            *) PLAYBACK_SOURCE_MODE="online" ;;
        esac
    fi

    case "$PLAYBACK_SOURCE_MODE" in
        online)
            echo "Playback source: online HTTP streaming"
            ;;
        nas)
            if [ ! -f "$NAS_VIDEO" ]; then
                echo "ERROR: NAS video not found: $NAS_VIDEO"
                echo "Please mount NAS first with $SCRIPT_DIR/run_0_mount_nas.sh."
                return 1
            fi
            PLAYBACK_SOURCE="$NAS_VIDEO"
            VIDEO_BASENAME="$(basename "$NAS_VIDEO")"
            URL="file://$NAS_VIDEO"
            echo "Playback source: direct NAS file"
            ls -lh "$NAS_VIDEO"
            ;;
    esac
}

run_gst_with_one_line_status() {
    local loop_index="$1"
    shift
    local gst_log gst_pid rc start_ts now elapsed
    local prev_idle prev_total cur_idle cur_total cpu_usage cpu_temp gpu_usage gpu_temp fps_value
    local display_mode stats_platform line latest_short

    gst_log="$(mktemp /tmp/6_3_online_stream_XXXXXX.log)"
    display_mode="$(detect_display_mode)"
    stats_platform="$STATS_PLATFORM"
    [ "$stats_platform" = "auto" ] && stats_platform="$(detect_stats_platform)"

    print_command "$@"

    if [ "$ENABLE_FPS" = "true" ]; then
        GST_DEBUG_NO_COLOR=1 GST_DEBUG="${GST_DEBUG:-fpsdisplaysink:5}" "$@" > "$gst_log" 2>&1 &
    else
        "$@" > "$gst_log" 2>&1 &
    fi
    gst_pid=$!
    start_ts="$(date +%s)"

    if [ "$ENABLE_SYS_STATS" = "true" ]; then
        read -r prev_idle prev_total < <(read_cpu_totals)
    fi

    trap 'if kill -0 "$gst_pid" 2>/dev/null; then echo ""; echo "Ctrl+C detected. Stopping playback..."; kill -INT "$gst_pid" 2>/dev/null; fi' INT

    while kill -0 "$gst_pid" 2>/dev/null; do
        now="$(date +%s)"
        elapsed=$((now - start_ts))
        if [ "$TEST_END_TS" -gt 0 ] && [ "$now" -ge "$TEST_END_TS" ]; then
            TEST_TIME_UP=true
            kill -INT "$gst_pid" 2>/dev/null || true
            break
        fi
        fps_value="$(latest_fps_from_log "$gst_log")"
        if [ "$ENABLE_FPS" = "true" ] && { [ -z "$fps_value" ] || [ "$fps_value" = "N/A" ]; } && [ "$SOURCE_FPS" != "unknown" ]; then
            fps_value="source:$SOURCE_FPS"
        fi
        fps_value="${fps_value:-N/A}"

        if [ "$ENABLE_SYS_STATS" = "true" ]; then
            read -r cur_idle cur_total < <(read_cpu_totals)
            cpu_usage="$(awk -v pi="$prev_idle" -v pt="$prev_total" -v ci="$cur_idle" -v ct="$cur_total" 'BEGIN {
                total_delta=ct-pt
                idle_delta=ci-pi
                if (total_delta > 0) printf "%.1f", 100 * (total_delta - idle_delta) / total_delta
                else print "N/A"
            }')"
            prev_idle=$cur_idle
            prev_total=$cur_total

            case "$stats_platform" in
                jetson)
                    cpu_temp="$(read_thermal_temp "cpu|soc|package|thermal")"
                    read -r gpu_usage gpu_temp < <(read_jetson_gpu_stats)
                    ;;
                *)
                    cpu_temp="$(read_thermal_temp "cpu|soc|package|thermal")"
                    gpu_usage="N/A"
                    gpu_temp="$(read_thermal_temp "gpu")"
                    ;;
            esac
            [ -n "$cpu_temp" ] && [ "$cpu_temp" != "N/A" ] && cpu_temp="${cpu_temp}C"
            [ -n "$gpu_temp" ] && [ "$gpu_temp" != "N/A" ] && gpu_temp="${gpu_temp}C"
            line="L=${loop_index} t=${elapsed}s FPS=${fps_value} CPU=${cpu_usage:-N/A}% GPU=${gpu_usage:-N/A}% T=${cpu_temp:-N/A}/${gpu_temp:-N/A}"
        else
            line="L=${loop_index} t=${elapsed}s FPS=${fps_value} DISP=${display_mode}"
        fi

        if [ "$TEST_END_TS" -gt 0 ]; then
            line="${line} left=$((TEST_END_TS - now))s"
        fi

        latest_short="${line:0:$STATUS_WIDTH}"
        printf "\r%-${STATUS_WIDTH}s" "$latest_short"
        sleep 1
    done

    wait "$gst_pid"
    rc=$?
    trap - INT
    echo ""

    if [ "$TEST_TIME_UP" = "true" ]; then
        print_pass "RESULT,ONLINE_STREAMING_PLAYBACK,$loop_index,PASS,time-complete"
    elif [ "$rc" -eq 0 ]; then
        print_pass "RESULT,ONLINE_STREAMING_PLAYBACK,$loop_index,PASS"
    else
        print_fail "RESULT,ONLINE_STREAMING_PLAYBACK,$loop_index,FAIL,rc=$rc"
        echo "Last 40 GStreamer log lines:"
        tail -n 40 "$gst_log"
    fi
    rm -f "$gst_log"
    return "$rc"
}

play_once() {
    local loop_index="$1"
    local parser demux
    local cmd
    local -a source_parts

    parser="$(get_parser "$VIDEO_CODEC")"
    demux="$(get_demux "$PLAYBACK_SOURCE" "$FORMAT_NAME")"
    make_sink_parts

    if [ "$PLAYBACK_SOURCE_MODE" = "nas" ]; then
        source_parts=(filesrc "location=$PLAYBACK_SOURCE" !)
    else
        source_parts=(souphttpsrc "location=$URL" !)
    fi

    echo ""
    echo "======================================"
    echo "$TEST_NAME"
    echo "Loop index: $loop_index"
    echo "Source mode: $PLAYBACK_SOURCE_MODE"
    echo "Source: $PLAYBACK_SOURCE"
    echo "URI: $URL"
    echo "Format: $FORMAT_NAME"
    echo "Video codec: $VIDEO_CODEC"
    echo "Audio codec: $AUDIO_CODEC"
    echo "Source FPS: $SOURCE_FPS"
    echo "======================================"

    if [ -z "$parser" ] || [ -z "$demux" ]; then
        print_swdecode "Unsupported codec/container for fixed pipeline. Fallback to playbin."
        run_gst_with_one_line_status "$loop_index" gst-launch-1.0 -e playbin uri="$URL"
        return 0
    fi

    if jetson_hw_supported_codec "$VIDEO_CODEC"; then
        print_hwdecode "Using Jetson hardware decoder: nvv4l2decoder"
        if [ "$ENABLE_AUDIO" = "true" ] && [ "$AUDIO_CODEC" != "none" ] && audio_supported_for_demux "$demux"; then
            run_gst_with_one_line_status "$loop_index" \
                gst-launch-1.0 -e \
                "${source_parts[@]}" \
                "$demux" name=demux \
                demux.video_0 ! queue ! "$parser" ! nvv4l2decoder ! nvvidconv ! "${SINK_PARTS[@]}" \
                demux.audio_0 ! queue ! decodebin ! audioconvert ! audioresample ! autoaudiosink
        else
            run_gst_with_one_line_status "$loop_index" \
                gst-launch-1.0 -e \
                "${source_parts[@]}" \
                "$demux" name=demux demux.video_0 ! queue ! "$parser" ! nvv4l2decoder ! nvvidconv ! "${SINK_PARTS[@]}"
        fi
    else
        print_swdecode "Jetson hardware decoder is not enabled for codec: $VIDEO_CODEC. Fallback to playbin."
        run_gst_with_one_line_status "$loop_index" gst-launch-1.0 -e playbin uri="$URL"
    fi
}

echo "======================================"
echo "$TEST_NAME"
echo "Host: $(hostname)"
echo "Date: $(date -Iseconds)"
echo "Display sync: $DISPLAY_SYNC"
echo "Audio enabled: $ENABLE_AUDIO"
echo "FPS enabled: $ENABLE_FPS"
echo "System stats: $ENABLE_SYS_STATS"
echo "======================================"

setup_display
echo "DISPLAY: ${DISPLAY:-not set}"
echo "XAUTHORITY: ${XAUTHORITY:-not set}"
trap handle_interrupt INT TERM

require_cmd gst-launch-1.0 || exit 1
require_cmd gst-inspect-1.0 || exit 1
require_cmd ffprobe || {
    echo "ffprobe not found. Installing ffmpeg..."
    sudo apt-get update
    sudo apt-get install -y ffmpeg
}

prompt_test_duration
select_playback_source || exit 1

if [ "$PLAYBACK_SOURCE_MODE" = "online" ]; then
    echo ""
    echo "Video server setup"
    echo ""
    read -rp "Enter nginx server IP/host: " SERVER_HOST
    [ -n "$SERVER_HOST" ] || { echo "No server IP/host entered. Exit."; exit 1; }
    SERVER_HOST="${SERVER_HOST#http://}"
    SERVER_HOST="${SERVER_HOST#https://}"
    SERVER_HOST="${SERVER_HOST%%/*}"

    read -rp "Enter SSH username for $SERVER_HOST: " SERVER_USER
    [ -n "$SERVER_USER" ] || { echo "No SSH username entered. Exit."; exit 1; }

    read -rsp "Enter SSH password for ${SERVER_USER}@${SERVER_HOST}: " SERVER_PASS
    echo ""
    [ -n "$SERVER_PASS" ] || { echo "No SSH password entered. Exit."; exit 1; }

    setup_video_server || {
        echo "ERROR: Failed to set up nginx video server."
        exit 1
    }
    PLAYBACK_SOURCE="$URL"
fi

echo ""
echo "Checking remote video codec..."
VIDEO_CODEC="$(probe_video_codec "$URL")"
AUDIO_CODEC="$(probe_audio_codec "$URL")"
FORMAT_NAME="$(probe_format "$URL")"
SOURCE_FPS="$(probe_video_fps "$URL")"
[ -n "$VIDEO_CODEC" ] || { echo "ERROR: Cannot detect video codec from URL: $URL"; exit 1; }
AUDIO_CODEC="${AUDIO_CODEC:-none}"
FORMAT_NAME="${FORMAT_NAME:-unknown}"
SOURCE_FPS="${SOURCE_FPS:-unknown}"
echo "Format: $FORMAT_NAME"
echo "Video codec: $VIDEO_CODEC"
echo "Audio codec: $AUDIO_CODEC"
echo "Source FPS: $SOURCE_FPS"
echo "Stats platform: $([ "$STATS_PLATFORM" = "auto" ] && detect_stats_platform || echo "$STATS_PLATFORM")"

echo ""
echo "Stress playback starts now. It will stop after ${TEST_DURATION_SECONDS} second(s)."
echo "Press Ctrl+C to stop early."

start_tegrastats_log
TEST_END_TS=$(($(date +%s) + TEST_DURATION_SECONDS))

LOOP_INDEX=1
while true; do
    play_once "$LOOP_INDEX"
    [ "$TEST_TIME_UP" = "true" ] && break
    LOOP_INDEX=$((LOOP_INDEX + 1))
    [ "$LOOP_FOREVER" = "true" ] || break
    sleep 1
done

echo ""
finish_test
print_pass "TEST COMPLETE: $TEST_NAME"
