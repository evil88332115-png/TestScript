#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 10-2 TensorRT Test
#
# Source models from NAS:
#   /mnt/nas_home/TEST FILE/onnx/yolov5s.onnx
#   /mnt/nas_home/TEST FILE/onnx/yolov5x.onnx
#
# Local models are copied to the current test user's home directory:
#   [0] ${USER_HOME}/yolov5s.onnx
#   [1] ${USER_HOME}/yolov5x.onnx
#
# Engine cache:
#   /home/<user>/trt_engine_cache/<model>_fp16.engine
# ============================================================

NAS_MOUNT="${NAS_MOUNT:-/mnt/nas_home}"
ONNX_NAS_DIR="${ONNX_NAS_DIR:-${NAS_MOUNT}/TEST FILE/onnx}"
TEST_USER="${TEST_USER:-${SUDO_USER:-$(id -un)}}"
USER_HOME="${USER_HOME:-$(getent passwd "$TEST_USER" | cut -d: -f6)}"
if [ -z "$USER_HOME" ]; then
  USER_HOME="${HOME}"
fi
LOG_DIR="${LOG_DIR:-${USER_HOME}/10-2_tensorrt_test_$(date +%Y%m%d_%H%M%S)}"
ENGINE_DIR="${ENGINE_DIR:-${USER_HOME}/trt_engine_cache}"
TRTEXEC="${TRTEXEC:-}"
PRECISION="${PRECISION:-fp16}"
DURATION="${DURATION:-60}"
TEGRATS_INTERVAL_MS="${TEGRATS_INTERVAL_MS:-1000}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRAW_TEMP_SCRIPT="${DRAW_TEMP_SCRIPT:-}"

MODELS=(
  "yolov5s.onnx"
  "yolov5x.onnx"
)

ACTIVE_JETSON_CLOCKS_STORE=""

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

print_command() {
  echo ""
  echo "Command:"
  printf '  '
  printf '%q ' "$@"
  echo ""
  echo ""
}

detect_draw_temp_script() {
  local candidate

  if [ -n "$DRAW_TEMP_SCRIPT" ] && [ -f "$DRAW_TEMP_SCRIPT" ]; then
    printf '%s\n' "$DRAW_TEMP_SCRIPT"
    return 0
  fi

  for candidate in \
    "${SCRIPT_DIR}/drawtempcurve_auto.pyc" \
    "${SCRIPT_DIR}/drawtempcurve_auto.py" \
    "${USER_HOME}/MaxTestScript/drawtempcurve_auto.pyc" \
    "${USER_HOME}/MaxTestScript/drawtempcurve_auto.py"; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

print_draw_temp_search_paths() {
  echo "Searched drawtemp scripts:"
  echo "  ${DRAW_TEMP_SCRIPT:-<DRAW_TEMP_SCRIPT not set>}"
  echo "  ${SCRIPT_DIR}/drawtempcurve_auto.pyc"
  echo "  ${SCRIPT_DIR}/drawtempcurve_auto.py"
  echo "  ${USER_HOME}/MaxTestScript/drawtempcurve_auto.pyc"
  echo "  ${USER_HOME}/MaxTestScript/drawtempcurve_auto.py"
}

start_tegrastats() {
  local log_file="$1"

  if ! command -v tegrastats >/dev/null 2>&1; then
    warn "WARNING: tegrastats not found. Temperature log/graph will be skipped."
    return 1
  fi

  echo "Starting tegrastats for benchmark only: $log_file"
  tegrastats --interval "$TEGRATS_INTERVAL_MS" > "$log_file" 2>&1 &
  TEGRASTATS_PID="$!"
  return 0
}

stop_tegrastats() {
  if [ -n "${TEGRASTATS_PID:-}" ] && kill -0 "$TEGRASTATS_PID" >/dev/null 2>&1; then
    kill "$TEGRASTATS_PID" >/dev/null 2>&1 || true
    wait "$TEGRASTATS_PID" 2>/dev/null || true
  fi
  TEGRASTATS_PID=""
}

draw_temperature_curve() {
  local tegrastats_log="$1"
  local output_png="$2"
  local draw_script plot_log line_count target_samples

  if [ ! -s "$tegrastats_log" ]; then
    warn "WARNING: tegrastats log is empty, skip temperature graph."
    return 0
  fi

  plot_log="${tegrastats_log%.log}_trimmed.log"
  line_count="$(wc -l < "$tegrastats_log" 2>/dev/null || echo 0)"
  target_samples=$(( (DURATION * 1000 + TEGRATS_INTERVAL_MS - 1) / TEGRATS_INTERVAL_MS ))
  if [ "$target_samples" -gt 0 ] && [ "$line_count" -gt "$target_samples" ]; then
    head -n "$target_samples" "$tegrastats_log" > "$plot_log"
    echo "Temperature graph input: $plot_log (${target_samples}/${line_count} tegrastats samples kept)"
  else
    cp -f "$tegrastats_log" "$plot_log"
    echo "Temperature graph input: $plot_log (${line_count} tegrastats samples)"
  fi

  draw_script="$(detect_draw_temp_script || true)"
  if [ -z "$draw_script" ]; then
    warn "WARNING: drawtempcurve_auto.py/.pyc not found, skip temperature graph."
    print_draw_temp_search_paths
    return 0
  fi

  echo "Drawing CPU+GPU temperature curve..."
  print_command env PYTHONNOUSERSITE=1 python3 "$draw_script" --file "$plot_log" --mode cpu_gpu --avg-min 0 --interval-ms "$TEGRATS_INTERVAL_MS" --out "$output_png"
  if env PYTHONNOUSERSITE=1 python3 "$draw_script" --file "$plot_log" --mode cpu_gpu --avg-min 0 --interval-ms "$TEGRATS_INTERVAL_MS" --out "$output_png"; then
    if [ -s "$output_png" ]; then
      pass "RESULT,TENSORRT,TEMP_GRAPH,PASS,$output_png"
    else
      fail "RESULT,TENSORRT,TEMP_GRAPH,FAIL,output-not-found"
    fi
  else
    fail "RESULT,TENSORRT,TEMP_GRAPH,FAIL,draw-failed"
  fi
}

ensure_python_onnx() {
  if python3 -c "import onnx" >/dev/null 2>&1; then
    echo "Python onnx module found."
    return 0
  fi

  # Ubuntu 24.04 implements PEP 668 and rejects pip --user against the
  # externally-managed system Python.  Use the distro package on both R36 and
  # R39 so all later `python3` calls import ONNX from the same interpreter.
  if ! apt-cache show python3-onnx >/dev/null 2>&1; then
    fail "RESULT,TENSORRT,ONNX_MODULE,FAIL,apt-package-not-found"
    return 1
  fi

  echo "Python onnx module not found. Installing Ubuntu package python3-onnx..."
  sudo apt-get update
  if ! sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y python3-onnx; then
    fail "RESULT,TENSORRT,ONNX_MODULE,FAIL,apt-install-failed"
    return 1
  fi

  if python3 -c "import onnx" >/dev/null 2>&1; then
    pass "RESULT,TENSORRT,ONNX_MODULE,PASS,source=apt"
  else
    fail "RESULT,TENSORRT,ONNX_MODULE,FAIL,import-after-apt-install"
    return 1
  fi
}

check_requirements() {
  mkdir -p "$LOG_DIR" "$ENGINE_DIR"

  if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
    fail "ERROR: cannot detect home directory for user: $TEST_USER"
    return 1
  fi

  if [ ! -d "$ONNX_NAS_DIR" ]; then
    fail "ERROR: ONNX NAS directory not found: $ONNX_NAS_DIR"
    echo "Please mount NAS first with run_0_mount_nas.sh."
    return 1
  fi

  detect_trtexec || return 1
  check_nvdla_compiler || return 1

  ensure_python_onnx
}

check_nvdla_compiler() {
  local model lower_model

  model="$(tr -d '\000' </proc/device-tree/model 2>/dev/null || true)"
  lower_model="${model,,}"

  # Orin Nano has no DLA.  This script runs trtexec on the GPU and never passes
  # --useDLACore, so DLA libraries must not block the TensorRT GPU benchmark.
  if [[ "$lower_model" == *"orin nano"* ]]; then
    echo "DLA runtime check skipped: $model has no DLA; TensorRT GPU testing will continue."
    pass "RESULT,TENSORRT,DLA_RUNTIME,SKIP,no-dla-hardware"
    return 0
  fi

  if find /usr /lib /opt -name 'libnvdla_compiler.so*' 2>/dev/null | grep -q . && \
     find /usr /lib /opt -name 'libcudla.so*' 2>/dev/null | grep -q .; then
    echo "Optional TensorRT/DLA runtime libraries found."
    pass "RESULT,TENSORRT,DLA_RUNTIME,PASS"
    return 0
  fi

  warn "WARNING: optional DLA runtime libraries were not found."
  warn "This test uses TensorRT GPU FP16 only, so the GPU benchmark will continue."
  pass "RESULT,TENSORRT,DLA_RUNTIME,SKIP,optional-runtime-missing"
  return 0
}

detect_trtexec() {
  local candidate answer
  local candidates=(
    "/usr/src/tensorrt/bin/trtexec"
    "/usr/src/tensorrt/samples/trtexec"
    "/usr/bin/trtexec"
    "/usr/local/bin/trtexec"
  )

  if [ -n "$TRTEXEC" ]; then
    if [ -x "$TRTEXEC" ]; then
      echo "trtexec found: $TRTEXEC"
      return 0
    fi
    fail "ERROR: TRTEXEC is set but not executable: $TRTEXEC"
    return 1
  fi

  if command -v trtexec >/dev/null 2>&1; then
    TRTEXEC="$(command -v trtexec)"
    echo "trtexec found: $TRTEXEC"
    return 0
  fi

  for candidate in "${candidates[@]}"; do
    if [ -x "$candidate" ]; then
      TRTEXEC="$candidate"
      echo "trtexec found: $TRTEXEC"
      return 0
    fi
  done

  candidate="$(find /usr /opt "$USER_HOME" -type f -name trtexec -perm /111 2>/dev/null | head -n 1 || true)"
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    TRTEXEC="$candidate"
    echo "trtexec found: $TRTEXEC"
    return 0
  fi

  fail "ERROR: trtexec not found."
  echo "TensorRT/trtexec is not installed or not in PATH:"
  echo "  sudo apt-get install -y tensorrt"
  read -r -p "Install tensorrt now? [y/N] " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    sudo apt-get update
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y tensorrt
    if command -v trtexec >/dev/null 2>&1; then
      TRTEXEC="$(command -v trtexec)"
      echo "trtexec found: $TRTEXEC"
      return 0
    fi
    for candidate in "${candidates[@]}"; do
      if [ -x "$candidate" ]; then
        TRTEXEC="$candidate"
        echo "trtexec found: $TRTEXEC"
        return 0
      fi
    done
  fi

  fail "RESULT,TENSORRT,TRTEXEC,FAIL,not-found"
  return 1
}

sync_models_from_nas() {
  local model src dst

  echo ""
  echo "======================================"
  echo "Sync ONNX models from NAS"
  echo "NAS ONNX directory: $ONNX_NAS_DIR"
  echo "Local directory: $USER_HOME"
  echo "======================================"

  for model in "${MODELS[@]}"; do
    src="${ONNX_NAS_DIR}/${model}"
    dst="${USER_HOME}/${model}"

    if [ ! -f "$src" ]; then
      fail "ERROR: source model not found: $src"
      return 1
    fi

    if [ -f "$dst" ]; then
      echo "Local model exists; keeping: $dst"
    else
      echo "Copy model:"
      echo "  From: $src"
      echo "  To  : $dst"
      cp -f "$src" "$dst"
    fi
  done

  pass "RESULT,TENSORRT,MODEL_SYNC,PASS"
}

get_model_info() {
  local model_path="$1"
  python3 - "$model_path" <<'PY'
import sys
from pathlib import Path
import onnx
import onnx.shape_inference

model_path = Path(sys.argv[1])
model = onnx.load(str(model_path))
input_name = model.graph.input[0].name

dynamic = False
try:
    inferred = onnx.shape_inference.infer_shapes(model)
    for input_tensor in inferred.graph.input:
        shape = input_tensor.type.tensor_type.shape
        for dim in shape.dim:
            if dim.dim_param:
                dynamic = True
except Exception:
    # Keep static unless shape inference clearly shows dynamic shape.
    dynamic = False

print(f"{input_name}|{'dynamic' if dynamic else 'static'}")
PY
}

extract_metrics() {
  local log_file="$1"
  python3 - "$log_file" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(errors="ignore")

def find(pattern):
    m = re.search(pattern, text)
    return m.group(1) if m else "N/A"

throughput = find(r"Throughput:\s+([\d.]+)")

lat = re.search(r"Latency:\s+min\s*=\s*([\d.]+)\s*ms,\s*max\s*=\s*([\d.]+)\s*ms,\s*mean\s*=\s*([\d.]+)", text)
if lat:
    lat_min, lat_max, lat_mean = lat.group(1), lat.group(2), lat.group(3)
else:
    lat_min = lat_max = lat_mean = "N/A"

enqueue = find(r"Enqueue Time:.*?mean\s*=\s*([\d.]+)\s*ms")
h2d = find(r"H2D Latency:.*?mean\s*=\s*([\d.]+)\s*ms")
d2h = find(r"D2H Latency:.*?mean\s*=\s*([\d.]+)\s*ms")
gpu_compute_s = find(r"Total GPU Compute Time:\s*([\d.]+)\s*s")
try:
    h2d_d2h = round(float(h2d) + float(d2h), 6)
except Exception:
    h2d_d2h = "N/A"

print(f"Throughput (img/s): {throughput}")
print(f"Lat_min(ms): {lat_min}")
print(f"Lat_max(ms): {lat_max}")
print(f"Lat_mean(ms): {lat_mean}")
print(f"GPU Compute(ms): {float(gpu_compute_s) * 1000:.4f}" if gpu_compute_s != "N/A" else "GPU Compute(ms): N/A")
print(f"Enqueue(ms): {enqueue}")
print(f"H2D+D2H(ms): {h2d_d2h}")
PY
}

get_power_mode() {
  local output
  output="$(sudo -n nvpmodel -q 2>/dev/null || true)"
  if echo "$output" | grep -q "Power Mode"; then
    echo "$output" | awk -F: '/Power Mode/{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}'
  else
    echo "Unknown"
  fi
}

sanitize_power_mode_name() {
  local mode="$1"
  mode="${mode// /}"
  mode="${mode//_/}"
  mode="${mode^^}"

  case "$mode" in
    MAXN|MAXNSUPER|MAXNMODE|MODEMAXN)
      echo "MN"
      ;;
    *)
      # Keep names like 40W / 25W / 15W readable, remove unsafe chars only.
      echo "$mode" | sed -E 's/[^A-Z0-9]+//g'
      ;;
  esac
}

get_jetson_clocks_status() {
  local output
  output="$(sudo -n jetson_clocks --show 2>/dev/null || true)"
  if [ -z "$output" ]; then
    echo "Unknown"
    return 0
  fi

  if echo "$output" | grep -q "FreqOverride=1"; then
    echo "ON"
    return 0
  fi

  # R36 lines carry an explicit Online=0/1 field; R39 (JetPack 7.2) dropped
  # that field and only lists online cpus in the first place. Treat a
  # missing Online= field as online so both formats are handled.
  if echo "$output" | awk '
    /^cpu[0-9]+:/ {
      online = ($0 ~ /Online=/) ? ($0 ~ /Online=1/) : 1;
      if (!online) next;
      min=max="";
      for (i=1; i<=NF; i++) {
        if ($i ~ /^MinFreq=/) { min=$i; sub("MinFreq=", "", min) }
        if ($i ~ /^MaxFreq=/) { max=$i; sub("MaxFreq=", "", max) }
      }
      if (min != "" && max != "" && min != max) bad=1
      seen=1
    }
    END { exit !(seen && !bad) }
  '; then
    echo "ON"
    return 0
  fi

  echo "OFF"
}

restore_jetson_clocks() {
  local store_file="${1:-${ACTIVE_JETSON_CLOCKS_STORE:-}}"

  if [ -z "$store_file" ] || [ ! -s "$store_file" ]; then
    return 0
  fi

  echo "Restoring jetson_clocks state..."
  if sudo jetson_clocks --restore "$store_file"; then
    sleep 1
    echo "jetson_clocks status after restore: $(get_jetson_clocks_status)"
    pass "RESULT,TENSORRT,JETSON_CLOCKS,RESTORE,PASS"
  else
    fail "RESULT,TENSORRT,JETSON_CLOCKS,RESTORE,FAIL"
    return 1
  fi

  if [ "${ACTIVE_JETSON_CLOCKS_STORE:-}" = "$store_file" ]; then
    ACTIVE_JETSON_CLOCKS_STORE=""
  fi
}

cleanup_on_exit() {
  restore_jetson_clocks "${ACTIVE_JETSON_CLOCKS_STORE:-}" || true
}

trap cleanup_on_exit EXIT INT TERM

enable_jetson_clocks() {
  local store_file="$1"

  echo "Enabling jetson_clocks before benchmark..."
  echo "Storing current jetson_clocks state: $store_file"
  if sudo jetson_clocks --store "$store_file"; then
    ACTIVE_JETSON_CLOCKS_STORE="$store_file"
  else
    fail "RESULT,TENSORRT,JETSON_CLOCKS,STORE,FAIL"
    return 1
  fi

  if sudo jetson_clocks; then
    sleep 1
    echo "jetson_clocks status: $(get_jetson_clocks_status)"
    pass "RESULT,TENSORRT,JETSON_CLOCKS,SET,PASS"
    return 0
  fi

  fail "RESULT,TENSORRT,JETSON_CLOCKS,SET,FAIL"
  return 1
}

get_engine_size_mib() {
  local engine_path="$1"
  if [ -f "$engine_path" ]; then
    python3 - "$engine_path" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
print(round(p.stat().st_size / (1024 * 1024), 2))
PY
  else
    echo "N/A"
  fi
}

write_report() {
  local model_path="$1"
  local engine_path="$2"
  local log_file="$3"
  local report_file="$4"
  local input_name="$5"
  local shape_mode="$6"
  local tegrastats_log="${7:-}"
  local temp_png="${8:-}"
  local power_mode jetson_clocks engine_size first_line metrics_text

  power_mode="$(get_power_mode)"
  jetson_clocks="$(get_jetson_clocks_status)"
  engine_size="$(get_engine_size_mib "$engine_path")"
  first_line="$(head -n 1 "$log_file" 2>/dev/null || true)"
  metrics_text="$(extract_metrics "$log_file")"

  {
    echo "# TensorRT Benchmark Report"
    echo "* **Model**: $(basename "$model_path")"
    echo "* **Precision**: $PRECISION"
    echo "* **Duration**: ${DURATION} sec"
    echo "* **Input Name**: $input_name"
    echo "* **Timestamp**: $(date +%Y%m%d_%H%M%S)"
    echo "* **Engine Path**: $engine_path"
    echo "* **Tegrastats Log**: $tegrastats_log"
    if [ -n "$temp_png" ] && [ -s "$temp_png" ]; then
      echo "* **Temperature PNG**: $temp_png"
    fi
    echo ""
    echo "## System Info"
    echo '```'
    echo "Power Mode    : $power_mode"
    echo "Jetson Clocks : $jetson_clocks"
    echo '```'
    echo ""
    echo "## Command Line / First Line of Log"
    echo '```bash'
    echo "$first_line"
    echo '```'
    echo ""
    echo "## Metrics Summary"
    echo '```'
    echo "$metrics_text"
    echo "Engine(MiB): $engine_size"
    echo '```'
  } > "$report_file"

  echo "Report: $report_file"
}

run_benchmark() {
  local index="$1"
  local model_path model_stem power_mode power_label run_name engine_path run_dir log_file build_log report_file tegrastats_log temp_png clocks_store info input_name shape_mode rc build_rc
  local build_cmd=()
  local bench_cmd=()

  model_path="${USER_HOME}/${MODELS[$index]}"
  model_stem="${MODELS[$index]%.onnx}"
  power_mode="$(get_power_mode)"
  power_label="$(sanitize_power_mode_name "$power_mode")"
  if [ -z "$power_label" ] || [ "$power_label" = "UNKNOWN" ]; then
    power_label="UnknownPower"
  fi
  run_name="${power_label}${model_stem}"
  engine_path="${ENGINE_DIR}/${model_stem}_${PRECISION}.engine"
  run_dir="${LOG_DIR}/${run_name}"
  log_file="${run_dir}/trtexec_output.txt"
  build_log="${run_dir}/trtexec_build_output.txt"
  report_file="${run_dir}/report.md"
  tegrastats_log="${run_dir}/tegrastats_benchmark_${DURATION}s.log"
  temp_png="${run_dir}/tegrastats_cpu_gpu_${DURATION}s.png"
  clocks_store="${run_dir}/jetson_clocks_before.conf"

  mkdir -p "$run_dir" "$ENGINE_DIR"

  if [ ! -f "$model_path" ]; then
    fail "ERROR: model not found: $model_path"
    return 1
  fi

  info="$(get_model_info "$model_path")"
  input_name="${info%%|*}"
  shape_mode="${info##*|}"

  echo ""
  echo "======================================"
  echo "10-2 TensorRT Test"
  echo "Model: $model_path"
  echo "Precision: $PRECISION"
  echo "Duration: ${DURATION}s"
  echo "Input: $input_name"
  echo "Shape mode: $shape_mode"
  echo "Engine: $engine_path"
  echo "Log: $log_file"
  echo "======================================"

  bench_cmd=(
    "$TRTEXEC"
    "--duration=${DURATION}"
    "--useSpinWait"
    "--useCudaGraph"
    "--separateProfileRun"
  )

  if [ -f "$engine_path" ]; then
    echo "Existing engine found; using it directly."
    bench_cmd+=("--loadEngine=${engine_path}")
  else
    echo "${model_stem} building engine ..."
    echo "Engine not found; building engine first without tegrastats."
    build_cmd=(
      "$TRTEXEC"
      "--onnx=${model_path}"
      "--${PRECISION}"
      "--saveEngine=${engine_path}"
      "--duration=1"
      "--warmUp=0"
      "--iterations=1"
    )
    if [ "$shape_mode" = "dynamic" ]; then
      build_cmd+=("--shapes=${input_name}:1x3x640x640")
    fi

    print_command "${build_cmd[@]}"
    set +e
    "${build_cmd[@]}" 2>&1 | tee "$build_log"
    build_rc=${PIPESTATUS[0]}
    set -e

    if [ "$build_rc" -ne 0 ] || [ ! -f "$engine_path" ]; then
      fail "RESULT,TENSORRT,$model_stem,$PRECISION,FAIL,build-rc=$build_rc,log=$build_log"
      return "$build_rc"
    fi

    pass "RESULT,TENSORRT,$model_stem,$PRECISION,ENGINE_BUILD,PASS,engine=$engine_path"
    bench_cmd+=("--loadEngine=${engine_path}")
  fi

  enable_jetson_clocks "$clocks_store" || return 1

  echo "${model_stem} benchmark start ..."
  echo "Starting benchmark phase only. Tegrastats will cover this ${DURATION}s run."
  print_command "${bench_cmd[@]}"
  set +e
  start_tegrastats "$tegrastats_log"
  "${bench_cmd[@]}" 2>&1 | tee "$log_file"
  rc=${PIPESTATUS[0]}
  stop_tegrastats
  set -e

  draw_temperature_curve "$tegrastats_log" "$temp_png"

  write_report "$model_path" "$engine_path" "$log_file" "$report_file" "$input_name" "$shape_mode" "$tegrastats_log" "$temp_png"

  echo ""
  echo "TensorRT Metrics Summary"
  extract_metrics "$log_file"

  if [ "$rc" -eq 0 ]; then
    pass "RESULT,TENSORRT,$model_stem,$PRECISION,PASS,engine=$engine_path,log=$log_file"
  else
    fail "RESULT,TENSORRT,$model_stem,$PRECISION,FAIL,rc=$rc,log=$log_file"
  fi

  restore_jetson_clocks "$clocks_store" || true

  return "$rc"
}

show_menu() {
  echo ""
  echo "======================================"
  echo "10-2 TensorRT Test"
  echo "Log directory: $LOG_DIR"
  echo "Engine directory: $ENGINE_DIR"
  echo "======================================"
  for i in "${!MODELS[@]}"; do
    echo "[$i] ${USER_HOME}/${MODELS[$i]}"
  done
  echo "a) Run all models"
  echo "q) Quit"
  echo "======================================"
}

main() {
  echo "10-2 TensorRT Test"
  echo "User: $TEST_USER"
  echo "Home: $USER_HOME"
  echo "NAS ONNX directory: $ONNX_NAS_DIR"
  echo "trtexec: ${TRTEXEC:-auto-detect}"
  echo "Duration: ${DURATION}s"
  echo "Precision: $PRECISION"

  check_requirements || exit 1
  sync_models_from_nas || exit 1

  local choice
  while true; do
    show_menu
    read -r -p "Select model to test: " choice
    case "$choice" in
      0|1)
        run_benchmark "$choice" || true
        ;;
      a|A)
        run_benchmark 0 || true
        run_benchmark 1 || true
        ;;
      q|Q)
        echo "Done."
        echo "Logs saved in: $LOG_DIR"
        exit 0
        ;;
      *)
        echo "Invalid selection: $choice"
        ;;
    esac
  done
}

main "$@"
