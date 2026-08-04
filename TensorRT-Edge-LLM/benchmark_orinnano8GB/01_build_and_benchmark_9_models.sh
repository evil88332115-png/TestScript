#!/usr/bin/env bash
set -Eeuo pipefail

# Build and benchmark the nine TensorRT Edge-LLM v0.9.0 Orin Nano models.
# With no arguments all models are run.  Pass IDs (for example: 01 04) to
# build/run only selected models.  Existing completed engines are reused.

EDGE_TAG="${EDGE_TAG:-v0.9.0}"
REPO_DIR="${REPO_DIR:-$HOME/edgellm-src-v0.9.0}"
BUILD_DIR="${BUILD_DIR:-$REPO_DIR/build-orin-r39.2-v0.9.0}"
BENCH_ROOT="${BENCH_ROOT:-$HOME/edgellm-benchmark}"
DATASET_DIR="${DATASET_DIR:-$BENCH_ROOT/datasets}"
COCO_INPUT="${COCO_INPUT:-$DATASET_DIR/coco/dataset_nvidia_shape_20.json}"
NAS_MOUNT="${NAS_MOUNT:-/mnt/nas_home}"
NAS_MODEL_ROOT="${NAS_MODEL_ROOT:-$NAS_MOUNT/10-1-TensorRT-Edge-LLM-models/Orin-Nano-8GB/JetPack-7.2_R39.2/v0.9.0}"
LOCAL_MODEL_ROOT="${LOCAL_MODEL_ROOT:-$BENCH_ROOT/models}"
RESULT_ROOT="${RESULT_ROOT:-$BENCH_ROOT/results}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
RUN_DIR="$RESULT_ROOT/$RUN_ID"
LOG_DIR="$RUN_DIR/logs"
PROFILE_DIR="$RUN_DIR/profiles"
OUTPUT_DIR="$RUN_DIR/outputs"
FORCE_REBUILD="${FORCE_REBUILD:-0}"
UPLOAD_RESULTS="${UPLOAD_RESULTS:-0}"
NVME_GUARD="${NVME_GUARD:-0}"
NVP_MODE_ID="${NVP_MODE_ID:-0}"
NVP_MODE_NAME="${NVP_MODE_NAME:-15W}"
# Default to the fixed 61/62-token requests used for the published Orin Nano
# comparison table.  Use BENCHMARK_MODE=mtbench explicitly for dataset runs.
BENCHMARK_MODE="${BENCHMARK_MODE:-fixed-shape}"
SHAPE_REQUESTS="${SHAPE_REQUESTS:-20}"
SHAPE_MAX_GENERATE_LENGTH="${SHAPE_MAX_GENERATE_LENGTH:-512}"
VENV_PYTHON="${VENV_PYTHON:-$BENCH_ROOT/venv/bin/python}"
FIXED_INPUT_TOOL="${FIXED_INPUT_TOOL:-$BENCH_ROOT/scripts/prepare_fixed_llm_input.py}"
GPU_MAX_FREQ_15W=612000000
EMC_MAX_FREQ_15W=2133000000
CPU_MAX_FREQ_15W=1497600

LLM_BUILD="$BUILD_DIR/examples/llm/llm_build"
LLM_INFERENCE="$BUILD_DIR/examples/llm/llm_inference"
VISUAL_BUILD="$BUILD_DIR/examples/multimodal/visual_build"
PLUGIN="$BUILD_DIR/libNvInfer_edgellm_plugin.so"

declare -A MODEL_PATH MODEL_SLUG MODEL_KIND MODEL_MODE MODEL_PREFILL_TOKENS
MODEL_PATH[01]='Qwen3-0.6B/Vanilla-INT4-AWQ/onnx'
MODEL_PATH[02]='Qwen3-1.7B/Vanilla-INT4-AWQ/onnx'
MODEL_PATH[03]='Qwen3-1.7B/EAGLE3-INT4-AWQ/onnx'
MODEL_PATH[04]='Qwen3-VL-2B-Instruct/Vanilla-INT4-AWQ-FP16/onnx'
MODEL_PATH[05]='Qwen3.5-0.8B/VLM-Vanilla-INT4-AWQ-FP16/onnx'
MODEL_PATH[06]='Qwen3.5-0.8B/VLM-MTP-INT4-AWQ-FP16/onnx'
MODEL_PATH[07]='Qwen3.5-0.8B/LLM-Vanilla-INT4-AWQ/onnx'
MODEL_PATH[08]='Qwen3.5-2B/VLM-Vanilla-INT4-AWQ-FP16/onnx'
MODEL_PATH[09]='Qwen3.5-2B/LLM-Vanilla-INT4-AWQ/onnx'

MODEL_SLUG[01]='qwen3-0.6b-llm-vanilla'
MODEL_SLUG[02]='qwen3-1.7b-llm-vanilla'
MODEL_SLUG[03]='qwen3-1.7b-llm-eagle3'
MODEL_SLUG[04]='qwen3-vl-2b-instruct-vlm-vanilla'
MODEL_SLUG[05]='qwen3.5-0.8b-vlm-vanilla'
MODEL_SLUG[06]='qwen3.5-0.8b-vlm-mtp'
MODEL_SLUG[07]='qwen3.5-0.8b-llm-vanilla'
MODEL_SLUG[08]='qwen3.5-2b-vlm-vanilla'
MODEL_SLUG[09]='qwen3.5-2b-llm-vanilla'

MODEL_KIND[01]=llm; MODEL_MODE[01]=vanilla
MODEL_KIND[02]=llm; MODEL_MODE[02]=vanilla
MODEL_KIND[03]=llm; MODEL_MODE[03]=eagle3
MODEL_KIND[04]=vlm; MODEL_MODE[04]=vanilla
MODEL_KIND[05]=vlm; MODEL_MODE[05]=vanilla
MODEL_KIND[06]=vlm; MODEL_MODE[06]=mtp
MODEL_KIND[07]=llm; MODEL_MODE[07]=vanilla
MODEL_KIND[08]=vlm; MODEL_MODE[08]=vanilla
MODEL_KIND[09]=llm; MODEL_MODE[09]=vanilla

MODEL_PREFILL_TOKENS[01]=61
MODEL_PREFILL_TOKENS[02]=61
MODEL_PREFILL_TOKENS[03]=61
MODEL_PREFILL_TOKENS[07]=62
MODEL_PREFILL_TOKENS[09]=62

info() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

normalize_id() {
  local id="$1"
  [[ "$id" =~ ^[0-9]+$ ]] || die "Invalid model ID: $id"
  printf '%02d' "$((10#$id))"
}

platform_check() {
  [[ "$(id -u)" -ne 0 ]] || die 'Run as the normal user, not root.'
  local model l4t tag mem_kib
  model="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)"
  [[ "$model" == *'Orin Nano'* ]] || die "Expected Orin Nano, detected: ${model:-unknown}"
  mem_kib="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  [[ "$mem_kib" =~ ^[0-9]+$ && "$mem_kib" -ge 7000000 && "$mem_kib" -le 9000000 ]] \
    || die "Expected Orin Nano 8GB (MemTotal 7,000,000-9,000,000 KiB), detected ${mem_kib:-unknown} KiB."
  l4t="$(dpkg-query -W -f='${Version}' nvidia-l4t-core 2>/dev/null || true)"
  [[ "$l4t" == 39.2.* ]] || die "Expected R39.2.x, detected: ${l4t:-missing}"
  tag="$(git -C "$REPO_DIR" describe --tags --exact-match 2>/dev/null || true)"
  [[ "$tag" == "$EDGE_TAG" ]] || die "$REPO_DIR is not checked out at $EDGE_TAG."
  [[ -x "$LLM_BUILD" && -x "$LLM_INFERENCE" && -x "$VISUAL_BUILD" ]] \
    || die 'Runtime binaries are missing; finish script 00 first.'
  [[ -f "$PLUGIN" ]] || die "Plugin missing: $PLUGIN"
  [[ "$BENCHMARK_MODE" == fixed-shape || "$BENCHMARK_MODE" == mtbench ]] \
    || die "BENCHMARK_MODE must be mtbench or fixed-shape, got: $BENCHMARK_MODE"
  [[ "$SHAPE_REQUESTS" =~ ^[1-9][0-9]*$ ]] || die 'SHAPE_REQUESTS must be a positive integer.'
  [[ "$SHAPE_MAX_GENERATE_LENGTH" =~ ^[1-9][0-9]*$ ]] \
    || die 'SHAPE_MAX_GENERATE_LENGTH must be a positive integer.'
  if [[ "$BENCHMARK_MODE" == mtbench ]]; then
    [[ -s "$DATASET_DIR/mtbench/mtbench_dataset.json" ]] || die 'MTBench dataset is missing.'
  else
    [[ -x "$VENV_PYTHON" ]] || die "Benchmark Python environment missing: $VENV_PYTHON"
    [[ -s "$FIXED_INPUT_TOOL" ]] || die "Fixed-input helper missing: $FIXED_INPUT_TOOL"
  fi
  [[ -s "$COCO_INPUT" ]] || die "COCO runtime input is missing: $COCO_INPUT"
}

mount_nas() {
  mountpoint -q "$NAS_MOUNT" || sudo mount "$NAS_MOUNT"
  # A systemd automount is itself a mountpoint (autofs), but the backing CIFS
  # mount is created only after the path is accessed.
  timeout 30 ls -A "$NAS_MOUNT" >/dev/null \
    || die "NAS automount did not become ready at $NAS_MOUNT."
  [[ "$(findmnt -n -t cifs -o SOURCE --target "$NAS_MOUNT")" == '//192.168.23.12/home' ]] \
    || die "Unexpected or missing CIFS mount at $NAS_MOUNT."
  [[ -d "$NAS_MODEL_ROOT" ]] || die "NAS model root missing: $NAS_MODEL_ROOT"
}

storage_preflight() {
  local smart critical_warning media_errors fatal_events
  NVME_EVENT_BASELINE="$(sudo dmesg | grep -Eic 'nvme.*(timeout|reset|I/O error|controller is down)|EXT4-fs error|Buffer I/O error.*nvme' || true)"
  if [[ "$NVME_GUARD" != 1 ]]; then
    info "WARNING: NVMe safety guard disabled; existing boot event baseline: $NVME_EVENT_BASELINE"
    return
  fi
  smart="$(sudo nvme smart-log /dev/nvme0)"
  critical_warning="$(printf '%s\n' "$smart" | awk -F: '/^critical_warning/ {gsub(/[[:space:]]/, "", $2); print $2}')"
  media_errors="$(printf '%s\n' "$smart" | awk -F: '/^media_errors/ {gsub(/[[:space:]]/, "", $2); print $2}')"
  [[ "$critical_warning" == 0 ]] || die "NVMe SMART critical_warning is $critical_warning."
  [[ "$media_errors" == 0 ]] || die "NVMe SMART media_errors is $media_errors."
  fatal_events="$(sudo dmesg | grep -Ei 'nvme.*(reset|I/O error|controller is down|device not ready)|EXT4-fs error|Buffer I/O error.*nvme' || true)"
  [[ -z "$fatal_events" ]] || die "Fatal NVMe/filesystem events detected before benchmark: $fatal_events"
  info "NVMe preflight OK; existing boot event baseline: $NVME_EVENT_BASELINE"
}

check_new_storage_events() {
  local current
  current="$(sudo dmesg | grep -Eic 'nvme.*(timeout|reset|I/O error|controller is down)|EXT4-fs error|Buffer I/O error.*nvme' || true)"
  if (( current > NVME_EVENT_BASELINE )); then
    sudo dmesg | grep -Ei 'nvme.*(timeout|reset|I/O error|controller is down)|EXT4-fs error|Buffer I/O error.*nvme' | tail -20 >&2
    if [[ "$NVME_GUARD" == 1 ]]; then
      die "New NVMe/filesystem event detected during this benchmark; stopping before the next stage."
    fi
    info "WARNING: New NVMe/filesystem event detected; continuing because NVME_GUARD=0."
    NVME_EVENT_BASELINE="$current"
  fi
}

select_models() {
  local raw id
  SELECTED=()
  if (($# == 0)); then
    SELECTED=(01 02 03 04 05 06 07 08 09)
    return
  fi
  for raw in "$@"; do
    id="$(normalize_id "$raw")"
    [[ -n "${MODEL_PATH[$id]:-}" ]] || die "Model ID must be 01 through 09: $raw"
    SELECTED+=("$id")
  done
}

resolve_llm_onnx_dir() {
  local root="$1"
  if [[ -s "$root/model.onnx" ]]; then
    printf '%s\n' "$root"
  elif [[ -s "$root/llm/model.onnx" ]]; then
    printf '%s\n' "$root/llm"
  else
    return 1
  fi
}

verify_onnx_layout() {
  local id="$1" dir="$2" mode="${MODEL_MODE[$id]}" kind="${MODEL_KIND[$id]}"
  local base_dir draft_dir llm_dir mtp_dir
  if [[ "$mode" == eagle3 ]]; then
    base_dir="$(resolve_llm_onnx_dir "$dir/base" || true)"
    draft_dir="$(resolve_llm_onnx_dir "$dir/draft" || true)"
    [[ -n "$base_dir" && -n "$draft_dir" ]] \
      || die "$id EAGLE3 base/draft ONNX layout is incomplete under $dir."
  else
    llm_dir="$(resolve_llm_onnx_dir "$dir/llm" || true)"
    [[ -n "$llm_dir" ]] || die "$id LLM ONNX is incomplete under $dir."
  fi
  if [[ "$mode" == mtp ]]; then
    mtp_dir="$(resolve_llm_onnx_dir "$dir/mtp_draft" || true)"
    [[ -n "$mtp_dir" ]] || die "$id MTP draft ONNX is incomplete under $dir."
  fi
  if [[ "$kind" == vlm ]]; then
    [[ -s "$dir/visual/model.onnx" ]] || die "$id visual ONNX is incomplete."
  fi
}

sync_model() {
  local id="$1" src="$NAS_MODEL_ROOT/${MODEL_PATH[$id]}" dst="$LOCAL_MODEL_ROOT/$id-${MODEL_SLUG[$id]}/onnx"
  [[ -d "$src" ]] || die "NAS model missing: $src"
  mkdir -p "$dst"
  info "$id: syncing ONNX artifacts from NAS"
  rsync -a --partial --info=progress2 "$src/" "$dst/"
  verify_onnx_layout "$id" "$dst"
  printf '%s\n' "$src" >"$dst/.nas-source"
  LOCAL_ONNX="$dst"
}

prepare_engine_dir() {
  local id="$1" engine="$2"
  if [[ -f "$engine/.build_complete" ]]; then
    if [[ "$FORCE_REBUILD" != 1 ]]; then
      info "$id: reusing completed engine"
      BUILD_NEEDED=0
      return
    fi
    info "$id: FORCE_REBUILD=1; preserving completed engine and rebuilding"
    mv "$engine" "${engine}.previous.$(date +%Y%m%d_%H%M%S)"
  fi
  if [[ -d "$engine" && -n "$(find "$engine" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
    if [[ "$FORCE_REBUILD" != 1 ]]; then
      die "$id has an incomplete engine at $engine. Rerun with FORCE_REBUILD=1 to preserve it as a backup and rebuild."
    fi
    mv "$engine" "${engine}.incomplete.$(date +%Y%m%d_%H%M%S)"
  fi
  mkdir -p "$engine/llm"
  BUILD_NEEDED=1
}

build_model() {
  local id="$1" onnx="$2" engine="$3" mode="${MODEL_MODE[$id]}" kind="${MODEL_KIND[$id]}"
  local base_onnx draft_onnx llm_onnx mtp_onnx
  prepare_engine_dir "$id" "$engine"
  ((BUILD_NEEDED == 1)) || return 0
  info "$id: building TensorRT engine ($kind/$mode)"
  if [[ "$mode" == eagle3 ]]; then
    base_onnx="$(resolve_llm_onnx_dir "$onnx/base")"
    draft_onnx="$(resolve_llm_onnx_dir "$onnx/draft")"
    "$LLM_BUILD" --onnxDir "$base_onnx" --engineDir "$engine/llm" \
      --maxBatchSize 1 --maxInputLen 2048 --maxKVCacheCapacity 2200 \
      --specBase --maxVerifyTreeSize 60
    "$LLM_BUILD" --onnxDir "$draft_onnx" --engineDir "$engine/llm" \
      --maxBatchSize 1 --maxInputLen 2048 --maxKVCacheCapacity 2200 \
      --specDraft --maxDraftTreeSize 60
  elif [[ "$mode" == mtp ]]; then
    llm_onnx="$(resolve_llm_onnx_dir "$onnx/llm")"
    mtp_onnx="$(resolve_llm_onnx_dir "$onnx/mtp_draft")"
    "$LLM_BUILD" --onnxDir "$llm_onnx" --engineDir "$engine/llm" \
      --maxBatchSize 1 --maxInputLen 2048 --maxKVCacheCapacity 2200 \
      --specBase --maxVerifyTreeSize 4
    "$LLM_BUILD" --onnxDir "$mtp_onnx" --engineDir "$engine/llm" \
      --maxBatchSize 1 --maxInputLen 2048 --maxKVCacheCapacity 2200 \
      --specDraft --maxDraftTreeSize 4
  else
    llm_onnx="$(resolve_llm_onnx_dir "$onnx/llm")"
    "$LLM_BUILD" --onnxDir "$llm_onnx" --engineDir "$engine/llm" \
      --maxBatchSize 1 --maxInputLen 2048 --maxKVCacheCapacity 2200
  fi
  if [[ "$kind" == vlm ]]; then
    mkdir -p "$engine/visual"
    "$VISUAL_BUILD" --onnxDir "$onnx/visual" --engineDir "$engine/visual" \
      --minImageTokens 8 --maxImageTokens 2048 --maxImageTokensPerImage 2048
  fi
  date --iso-8601=seconds >"$engine/.build_complete"
}

run_model() {
  local id="$1" engine="$2" onnx="$3" slug="${MODEL_SLUG[$id]}" kind="${MODEL_KIND[$id]}" mode="${MODEL_MODE[$id]}"
  local input profile output tokenizer_dir target_tokens
  if [[ "$kind" == vlm ]]; then
    input="$COCO_INPUT"
  elif [[ "$BENCHMARK_MODE" == mtbench ]]; then
    input="$DATASET_DIR/mtbench/mtbench_dataset.json"
  else
    target_tokens="${MODEL_PREFILL_TOKENS[$id]}"
    if [[ "$mode" == eagle3 ]]; then
      tokenizer_dir="$(resolve_llm_onnx_dir "$onnx/base")"
    else
      tokenizer_dir="$(resolve_llm_onnx_dir "$onnx/llm")"
    fi
    input="$BENCH_ROOT/inputs/${id}_${slug}_${target_tokens}tokens.json"
    "$VENV_PYTHON" "$FIXED_INPUT_TOOL" create \
      --tokenizer-dir "$tokenizer_dir" \
      --output "$input" \
      --target-tokens "$target_tokens" \
      --requests "$SHAPE_REQUESTS" \
      --max-generate-length "$SHAPE_MAX_GENERATE_LENGTH"
    mkdir -p "$RUN_DIR/inputs"
    install -m 0644 "$input" "$input.metadata.json" "$RUN_DIR/inputs/"
  fi
  if [[ "$mode" == eagle3 || "$mode" == mtp ]]; then
    local greedy_input="$RUN_DIR/inputs/${id}_${slug}_greedy.json"
    "$VENV_PYTHON" "$FIXED_INPUT_TOOL" greedy --input "$input" --output "$greedy_input"
    input="$greedy_input"
  fi
  profile="$PROFILE_DIR/${id}_${slug}.profile.json"
  output="$OUTPUT_DIR/${id}_${slug}.output.json"
  local -a args=(
    --engineDir "$engine/llm"
    --inputFile "$input"
    --outputFile "$output"
    --batchSize 1
    --warmup 10
    --dumpProfile
    --profileOutputFile "$profile"
  )
  [[ "$kind" != vlm ]] || args+=(--multimodalEngineDir "$engine/visual")
  [[ "$mode" != eagle3 ]] || args+=(--specDecode --specVerifySize 60)
  [[ "$mode" != mtp ]] || args+=(--specDecode --specDraftTopK 1 --specDraftStep 3 --specVerifySize 4)
  info "$id: running benchmark mode=$BENCHMARK_MODE input=$input"
  "$LLM_INFERENCE" "${args[@]}"
  [[ -s "$profile" ]] || die "$id did not produce its profile JSON."
  if [[ "$kind" == llm && "$BENCHMARK_MODE" == fixed-shape ]]; then
    "$VENV_PYTHON" "$FIXED_INPUT_TOOL" verify \
      --profile "$profile" --target-tokens "$target_tokens"
  fi
}

record_environment() {
  mkdir -p "$RUN_DIR" "$LOG_DIR" "$PROFILE_DIR" "$OUTPUT_DIR"
  {
    date --iso-8601=seconds
    uname -a
    cat /etc/nv_tegra_release
    dpkg-query -W nvidia-jetpack nvidia-l4t-core cuda-toolkit-13-2 libnvinfer10 2>/dev/null || true
    nvpmodel -q 2>/dev/null || true
    free -h
    swapon --show
    git -C "$REPO_DIR" describe --tags --always --dirty
    printf 'benchmark_mode=%s\nshape_requests=%s\nshape_max_generate_length=%s\n' \
      "$BENCHMARK_MODE" "$SHAPE_REQUESTS" "$SHAPE_MAX_GENERATE_LENGTH"
  } >"$RUN_DIR/environment.txt"
}

upload_results() {
  local destination="$NAS_MODEL_ROOT/benchmark-results/$RUN_ID"
  info "Uploading result files to $destination"
  mkdir -p "$destination"
  rsync -a --info=progress2 "$RUN_DIR/" "$destination/"
}

apply_and_verify_power_caps() {
  # JetPack 7.2 can retain the requested nvpmodel ID while its boot service
  # fails at the interactive golden-context reboot prompt.  In that state
  # `nvpmodel -q` says 15W but the live clocks remain at MAXN.  Apply the
  # documented mode-0 caps directly and verify the live sysfs values.
  [[ "$NVP_MODE_ID" == 0 ]] || return
  local gpu_path='/sys/devices/platform/17000000.gpu/devfreq_dev/max_freq'
  local emc_path='/sys/kernel/nvpmodel_clk_cap/emc'
  local cpu_path actual_gpu actual_emc actual_cpu
  printf '%s\n' "$GPU_MAX_FREQ_15W" | sudo tee "$gpu_path" >/dev/null
  printf '%s\n' "$EMC_MAX_FREQ_15W" | sudo tee "$emc_path" >/dev/null
  for cpu_path in /sys/devices/system/cpu/cpu[0-5]/cpufreq/scaling_max_freq; do
    printf '%s\n' "$CPU_MAX_FREQ_15W" | sudo tee "$cpu_path" >/dev/null
  done
  actual_gpu="$(<"$gpu_path")"
  actual_emc="$(<"$emc_path")"
  actual_cpu="$(</sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq)"
  [[ "$actual_gpu" == "$GPU_MAX_FREQ_15W" ]] || die "15W GPU cap failed: $actual_gpu"
  [[ "$actual_emc" == "$EMC_MAX_FREQ_15W" ]] || die "15W EMC cap failed: $actual_emc"
  [[ "$actual_cpu" == "$CPU_MAX_FREQ_15W" ]] || die "15W CPU cap failed: $actual_cpu"
  info "Live 15W caps verified: GPU=$actual_gpu EMC=$actual_emc CPU=$actual_cpu Hz"
}

print_decode_comparison() {
  local results_csv="$RUN_DIR/benchmark-results.csv"
  [[ -s "$results_csv" ]] || return 0

  printf '\n=== Decode Throughput vs NVIDIA v0.9.0 (Jetson Orin Nano 8GB) ===\n'
  python3 - "$results_csv" <<'PY'
import csv
import sys

official_decode = {
    ("Qwen3-0.6B", "Vanilla"): 72.8,
    ("Qwen3-1.7B", "Vanilla"): 37.4,
    ("Qwen3-1.7B", "EAGLE3"): 41.2,
    ("Qwen3-VL-2B-Instruct", "Vanilla"): 36.9,
    ("Qwen3.5-0.8B", "Vanilla"): 55.3,
    ("Qwen3.5-0.8B", "MTP"): 45.0,
    ("Qwen3.5-0.8B-LLM", "Vanilla"): 55.4,
    ("Qwen3.5-2B", "Vanilla"): 29.9,
    ("Qwen3.5-2B-LLM", "Vanilla"): 30.0,
}

with open(sys.argv[1], newline="", encoding="utf-8") as csv_file:
    rows = list(csv.DictReader(csv_file))

print(f"{'Model':<26} {'Mode':<8} {'Yours':>9} {'NVIDIA':>9} {'Diff':>9}")
print("-" * 65)
for row in rows:
    key = (row.get("Model", ""), row.get("Mode", ""))
    reference = official_decode.get(key)
    if reference is None:
        continue
    try:
        measured = float(row["Generation (tok/s)"].replace(",", ""))
    except (KeyError, TypeError, ValueError):
        continue
    difference = (measured / reference - 1.0) * 100.0
    print(f"{key[0]:<26} {key[1]:<8} {measured:>8.1f} {reference:>8.1f} {difference:>+8.1f}%")
PY
  printf '%s\n' 'EAGLE3/MTP Decode = accepted-token throughput; all other rows = generated-token throughput.'
}

main() {
  select_models "$@"
  platform_check
  sudo -v
  mount_nas
  storage_preflight
  export EDGELLM_PLUGIN_PATH="$PLUGIN"
  export LD_LIBRARY_PATH="$BUILD_DIR:${LD_LIBRARY_PATH:-}"
  local power_mode
  power_mode="$(nvpmodel -q)"
  [[ "$power_mode" == *"$NVP_MODE_NAME"* && "$(printf '%s\n' "$power_mode" | tail -n 1)" == "$NVP_MODE_ID" ]] \
    || die "Expected power mode $NVP_MODE_NAME ($NVP_MODE_ID), detected: $power_mode. Run 'sudo nvpmodel -m $NVP_MODE_ID', reboot when requested, then retry."
  info "Power mode verified: $NVP_MODE_NAME ($NVP_MODE_ID)"
  apply_and_verify_power_caps
  record_environment
  local id model_dir engine
  for id in "${SELECTED[@]}"; do
    sync_model "$id"
    model_dir="$LOCAL_MODEL_ROOT/$id-${MODEL_SLUG[$id]}"
    engine="$model_dir/engine"
    {
      build_model "$id" "$LOCAL_ONNX" "$engine"
      check_new_storage_events
      run_model "$id" "$engine" "$LOCAL_ONNX"
      check_new_storage_events
    } 2>&1 | tee "$LOG_DIR/${id}_${MODEL_SLUG[$id]}.log"
    python3 "$BENCH_ROOT/scripts/parse_edgellm_profiles.py" "$PROFILE_DIR" --output-dir "$RUN_DIR"
  done
  if [[ "$UPLOAD_RESULTS" == 1 ]]; then
    upload_results
  else
    info "NAS result upload disabled (UPLOAD_RESULTS=$UPLOAD_RESULTS)"
  fi
  print_decode_comparison
  info "COMPLETE: $RUN_DIR"
  printf 'Markdown table: %s\nCSV: %s\n' "$RUN_DIR/benchmark-results.md" "$RUN_DIR/benchmark-results.csv"
}

main "$@"
