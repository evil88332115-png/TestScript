#!/usr/bin/env bash
set -Eeuo pipefail

# Shared worker for the numbered TensorRT Edge-LLM v0.9.0 export scripts.
# The Thor only quantizes/exports portable ONNX. TensorRT engines are built
# later on the Jetson Orin Nano 8GB (SM87), never on the Thor or NAS.

: "${ENTRY_SCRIPT_NAME:?wrapper must set ENTRY_SCRIPT_NAME}"
: "${MODE:?wrapper must set MODE}"
: "${HF_MODEL:?wrapper must set HF_MODEL}"
: "${MODEL_NAME:?wrapper must set MODEL_NAME}"
: "${NAS_RELATIVE_DIR:?wrapper must set NAS_RELATIVE_DIR}"
: "${EXPECTED_COMPONENTS:?wrapper must set EXPECTED_COMPONENTS}"

CONTAINER_NAME="${CONTAINER_NAME:-edgellm-export-v090}"
HOST_WORKSPACE="${HOST_WORKSPACE:-/home/n/edgellm-export-v0.9.0}"
CONTAINER_WORKSPACE="${CONTAINER_WORKSPACE:-/workspace}"
EDGE_LLM_TAG="${EDGE_LLM_TAG:-v0.9.0}"
NAS_MOUNT_POINT="${NAS_MOUNT_POINT:-/mnt/nas_home}"
NAS_EXPECTED_SOURCE="${NAS_EXPECTED_SOURCE:-//192.168.23.12/home}"
FORCE_RESTART="${FORCE_RESTART:-0}"

HOST_ONNX_DIR="${HOST_WORKSPACE}/models/${MODEL_NAME}/onnx"
NAS_MODEL_DIR="${NAS_MOUNT_POINT}/${NAS_RELATIVE_DIR}"
CONTAINER_ENTRY="${CONTAINER_WORKSPACE}/scripts/${ENTRY_SCRIPT_NAME}"

info() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
directory_has_files() { [[ -d "$1" ]] && find "$1" -mindepth 1 -print -quit | grep -q .; }
docker_cmd() {
  if docker info >/dev/null 2>&1; then docker "$@"; else sudo docker "$@"; fi
}

component_valid() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  [[ -s "$dir/config.json" ]] || return 1
  find "$dir" -maxdepth 1 -type f -name '*.onnx' -size +0c -print -quit | grep -q .
}

quant_valid() {
  local dir="$1"
  [[ -s "$dir/hf_quant_config.json" ]] || return 1
  [[ -s "$dir/config.json" ]] || return 1
  find "$dir" -maxdepth 1 -type f -name '*.safetensors' -size +0c -print -quit | grep -q .
}

all_components_valid() {
  local root="$1" component
  IFS=',' read -ra components <<< "$EXPECTED_COMPONENTS"
  for component in "${components[@]}"; do
    component_valid "$root/$component" || return 1
  done
}

backup_partial() {
  local path="$1" backup
  backup="${path}.partial-$(date +%Y%m%d_%H%M%S)"
  mv "$path" "$backup"
  info "Moved incomplete output to: $backup"
}

prepare_output() {
  local path="$1" label="$2"
  if directory_has_files "$path"; then
    if [[ "$FORCE_RESTART" == "1" ]]; then
      backup_partial "$path"
    else
      die "Incomplete $label exists at $path. Re-run with FORCE_RESTART=1 to preserve it and retry."
    fi
  fi
}

ensure_base_quantized() {
  local quant_dir="$1" log_file="$2" source_model="${3:-$HF_MODEL}"
  if quant_valid "$quant_dir"; then
    if [[ "$MODE" == "mtp-vlm" && ! -f "$quant_dir/.mtp-weights-verified" ]]; then
      die "Existing MTP checkpoint lacks .mtp-weights-verified; preserve it and rebuild from a local HF snapshot."
    fi
    info "Quantized checkpoint already complete: $quant_dir"
    return
  fi
  prepare_output "$quant_dir" "quantized checkpoint"
  info "Quantizing $HF_MODEL to INT4 AWQ (visual encoder remains FP16 when present)..."
  tensorrt-edgellm-quantize llm \
    --model_dir "$source_model" \
    --output_dir "$quant_dir" \
    --quantization int4_awq \
    2>&1 | tee "$log_file"

  if [[ "$MODE" == "mtp-vlm" ]] && grep -q "Missing keys in MTP draft model" "$log_file"; then
    die "MTP draft weights were not loaded; refusing to export an invalid speculative model."
  fi
  if [[ "$MODE" == "mtp-vlm" ]]; then
    touch "$quant_dir/.mtp-weights-verified"
  fi
}

inside_standard() {
  local model_dir="$CONTAINER_WORKSPACE/models/$MODEL_NAME"
  local quant_dir="${QUANT_DIR_OVERRIDE:-$model_dir/quantized}"
  local onnx_dir="$model_dir/onnx"
  local log_dir="$CONTAINER_WORKSPACE/logs"
  local quant_source="$HF_MODEL"
  local -a export_args

  mkdir -p "$model_dir" "$log_dir" "$HF_HOME"
  if ! quant_valid "$quant_dir"; then
    info "Resolving $HF_MODEL to a local Hugging Face snapshot for checkpoint-aware loaders..."
    quant_source="$(python3 - "$HF_MODEL" <<'PY'
import sys
from huggingface_hub import snapshot_download
print(snapshot_download(repo_id=sys.argv[1]))
PY
)"
    [[ -d "$quant_source" ]] || die "Unable to resolve local checkpoint: $quant_source"
  fi
  ensure_base_quantized "$quant_dir" "$log_dir/$MODEL_NAME-quantize.log" "$quant_source"

  if all_components_valid "$onnx_dir"; then
    info "All expected ONNX components already complete; skipping export."
    return
  fi
  prepare_output "$onnx_dir" "ONNX output"

  export_args=("$quant_dir" "$onnx_dir" --externalize-weights int4_ffn)
  case "$MODE" in
    vanilla-llm) export_args+=(--skip-visual) ;;
    vanilla-vlm) ;;
    mtp-vlm) export_args+=(--mtp) ;;
    *) die "Unsupported standard mode: $MODE" ;;
  esac

  info "Exporting $MODE ONNX for Orin Nano..."
  tensorrt-edgellm-export "${export_args[@]}" \
    2>&1 | tee "$log_dir/$MODEL_NAME-export.log"
  all_components_valid "$onnx_dir" || die "Export completed but required ONNX components are incomplete."
}

inside_eagle3() {
  local model_dir="$CONTAINER_WORKSPACE/models/$MODEL_NAME"
  local base_quant_dir="${BASE_QUANT_DIR:-$model_dir/quantized-base}"
  local draft_source="$model_dir/draft-source"
  local draft_quant="$model_dir/quantized-draft"
  local onnx_dir="$model_dir/onnx"
  local base_export="$model_dir/base-export-work"
  local draft_export="$model_dir/draft-export-work"
  local log_dir="$CONTAINER_WORKSPACE/logs"

  : "${DRAFT_HF_MODEL:?EAGLE3 wrapper must set DRAFT_HF_MODEL}"
  mkdir -p "$model_dir" "$log_dir" "$HF_HOME"
  ensure_base_quantized "$base_quant_dir" "$log_dir/$MODEL_NAME-quantize-base.log"

  if [[ ! -s "$draft_source/config.json" ]]; then
    prepare_output "$draft_source" "EAGLE3 draft source"
    require_command hf
    info "Downloading EAGLE3 draft checkpoint: $DRAFT_HF_MODEL"
    hf download "$DRAFT_HF_MODEL" --local-dir "$draft_source"
  fi

  if ! quant_valid "$draft_quant"; then
    prepare_output "$draft_quant" "quantized EAGLE3 draft"
    tensorrt-edgellm-quantize draft \
      --base_model_dir "$HF_MODEL" \
      --draft_model_dir "$draft_source" \
      --output_dir "$draft_quant" \
      --quantization int4_awq \
      2>&1 | tee "$log_dir/$MODEL_NAME-quantize-draft.log"
  fi

  if all_components_valid "$onnx_dir"; then
    info "EAGLE3 base/draft ONNX already complete; skipping export."
    return
  fi
  prepare_output "$onnx_dir" "EAGLE3 ONNX output"
  prepare_output "$base_export" "EAGLE3 base export work directory"
  prepare_output "$draft_export" "EAGLE3 draft export work directory"

  tensorrt-edgellm-export "$base_quant_dir" "$base_export" \
    --eagle-base --externalize-weights int4_ffn \
    2>&1 | tee "$log_dir/$MODEL_NAME-export-base.log"
  tensorrt-edgellm-export "$draft_quant" "$draft_export" \
    --externalize-weights int4_ffn \
    2>&1 | tee "$log_dir/$MODEL_NAME-export-draft.log"

  component_valid "$base_export/llm" || die "EAGLE3 base export validation failed."
  component_valid "$draft_export/llm" || die "EAGLE3 draft export validation failed."
  mkdir -p "$onnx_dir/base" "$onnx_dir/draft"
  cp -a "$base_export/llm/." "$onnx_dir/base/"
  cp -a "$draft_export/llm/." "$onnx_dir/draft/"
  all_components_valid "$onnx_dir" || die "Normalized EAGLE3 ONNX validation failed."
}

inside_container() {
  local repo_dir="$CONTAINER_WORKSPACE/TensorRT-Edge-LLM"
  local actual_tag
  [[ -f /.dockerenv ]] || die "--inside-container must run inside Docker."
  cd "$repo_dir"
  actual_tag="$(git describe --tags --exact-match 2>/dev/null || true)"
  [[ "$actual_tag" == "$EDGE_LLM_TAG" ]] || die "Expected $EDGE_LLM_TAG, found ${actual_tag:-unknown}."
  # shellcheck disable=SC1091
  source venv/bin/activate
  export HF_HOME="$CONTAINER_WORKSPACE/hf-cache"
  require_command tensorrt-edgellm-quantize
  require_command tensorrt-edgellm-export
  python3 -c 'import torch; assert torch.cuda.is_available(); n=torch.cuda.get_device_name(0); assert "Thor" in n, n; print("CUDA export host:", n, torch.version.cuda)'

  if [[ "$MODE" == "eagle3" ]]; then inside_eagle3; else inside_standard; fi
  all_components_valid "$CONTAINER_WORKSPACE/models/$MODEL_NAME/onnx" || die "Final ONNX validation failed."
  find "$CONTAINER_WORKSPACE/models/$MODEL_NAME/onnx" -type f -printf '%P %s bytes\n' | sort
}

host_main() {
  local running mounted_source checksum_diff
  [[ "$(id -u)" -ne 0 ]] || die "Run as the normal Thor user, not sudo."
  require_command docker; require_command rsync; require_command findmnt; require_command mountpoint
  [[ -f "$HOST_WORKSPACE/scripts/$ENTRY_SCRIPT_NAME" ]] || die "Missing installed wrapper: $HOST_WORKSPACE/scripts/$ENTRY_SCRIPT_NAME"
  [[ -f "$HOST_WORKSPACE/scripts/edgellm_orin_export_common.sh" ]] || die "Missing common worker script."
  docker_cmd inspect "$CONTAINER_NAME" >/dev/null 2>&1 || die "Container not found: $CONTAINER_NAME"
  running="$(docker_cmd inspect -f '{{.State.Running}}' "$CONTAINER_NAME")"
  if [[ "$running" != true ]]; then docker_cmd start "$CONTAINER_NAME" >/dev/null; fi

  docker_cmd exec \
    -e ENTRY_SCRIPT_NAME="$ENTRY_SCRIPT_NAME" -e MODE="$MODE" \
    -e HF_MODEL="$HF_MODEL" -e MODEL_NAME="$MODEL_NAME" \
    -e NAS_RELATIVE_DIR="$NAS_RELATIVE_DIR" -e EXPECTED_COMPONENTS="$EXPECTED_COMPONENTS" \
    -e QUANT_DIR_OVERRIDE="${QUANT_DIR_OVERRIDE:-}" -e BASE_QUANT_DIR="${BASE_QUANT_DIR:-}" \
    -e DRAFT_HF_MODEL="${DRAFT_HF_MODEL:-}" -e FORCE_RESTART="$FORCE_RESTART" \
    "$CONTAINER_NAME" bash "$CONTAINER_ENTRY" --inside-container

  all_components_valid "$HOST_ONNX_DIR" || die "Host ONNX validation failed."
  if ! mountpoint -q "$NAS_MOUNT_POINT"; then
    info "NAS is not mounted; mounting the fstab entry at $NAS_MOUNT_POINT..."
    sudo mount "$NAS_MOUNT_POINT" \
      || die "NAS mount failed. Run 00_setup_thor_edgellm_v090.sh to configure credentials and fstab."
  fi
  mountpoint -q "$NAS_MOUNT_POINT" || die "NAS is not mounted at $NAS_MOUNT_POINT."
  ls -A "$NAS_MOUNT_POINT" >/dev/null
  mounted_source="$(findmnt -n -t cifs -o SOURCE --target "$NAS_MOUNT_POINT")"
  [[ "$mounted_source" == "$NAS_EXPECTED_SOURCE" ]] || die "Unexpected mount source: $mounted_source"
  mkdir -p "$NAS_MODEL_DIR/onnx"
  rsync -rltH --partial --info=stats2 "$HOST_ONNX_DIR/" "$NAS_MODEL_DIR/onnx/"
  checksum_diff="$(rsync -rltHnc --delete "$HOST_ONNX_DIR/" "$NAS_MODEL_DIR/onnx/")"
  [[ -z "$checksum_diff" ]] || { printf '%s\n' "$checksum_diff" >&2; die "NAS checksum verification failed."; }
  info "SUCCESS: $MODEL_NAME is ready for Orin Nano."
  info "NAS path: $NAS_MODEL_DIR/onnx"
  find "$NAS_MODEL_DIR/onnx" -type f -printf '%P %s bytes\n' | sort
}

show_config() {
  printf 'script=%s\nmode=%s\nhf_model=%s\nmodel_name=%s\ncomponents=%s\nnas=%s\n' \
    "$ENTRY_SCRIPT_NAME" "$MODE" "$HF_MODEL" "$MODEL_NAME" \
    "$EXPECTED_COMPONENTS" "$NAS_RELATIVE_DIR"
}

case "${1:-}" in
  --inside-container) inside_container ;;
  --show-config) show_config ;;
  "") host_main ;;
  *) die "Unknown argument: $1" ;;
esac
