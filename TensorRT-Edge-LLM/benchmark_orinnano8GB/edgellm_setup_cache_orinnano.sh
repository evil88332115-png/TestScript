#!/usr/bin/env bash
set -Eeuo pipefail

# Internal helper used by 00_setup_orin_nano_r39_2.sh.  The cache is deliberately
# exact-version and exact-path because TensorRT binaries are not generally
# portable across TensorRT builds, JetPack releases, or GPU types.

ACTION="${1:-}"
REPO_DIR="${REPO_DIR:-$HOME/edgellm-src-v0.9.0}"
BUILD_DIR="${BUILD_DIR:-$REPO_DIR/build-orin-r39.2-v0.9.0}"
BENCH_ROOT="${BENCH_ROOT:-$HOME/edgellm-benchmark}"
DATASET_DIR="${DATASET_DIR:-$BENCH_ROOT/datasets}"
LOCAL_MODEL_ROOT="${LOCAL_MODEL_ROOT:-$BENCH_ROOT/models}"
NAS_MOUNT="${NAS_MOUNT:-/mnt/nas_home}"
NAS_MODEL_ROOT="${NAS_MODEL_ROOT:-$NAS_MOUNT/10-1-TensorRT-Edge-LLM-models/Orin-Nano-8GB/JetPack-7.2_R39.2/v0.9.0}"
CACHE_DIR="${SETUP_CACHE_DIR:-$NAS_MODEL_ROOT/setup-cache/orin-nano-8gb-sm87-r39.2-v0.9.0}"
ENGINE_CACHE_DIR="${ENGINE_CACHE_DIR:-$NAS_MODEL_ROOT/engine-cache/orin-nano-8gb-r39.2-v0.9.0}"
EDGE_COMMIT='1ac0f2b99642045125e1c5ac7b109434ba3b36c7'
EXPECTED_HOME='/home/p'

info() { printf '\n==> CACHE: %s\n' "$*"; }
die() { printf 'CACHE ERROR: %s\n' "$*" >&2; exit 1; }
pkg_version() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true; }

collect_environment() {
  [[ "$HOME" == "$EXPECTED_HOME" ]] || die "Cache requires HOME=$EXPECTED_HOME; detected $HOME."
  [[ "$(uname -m)" == aarch64 ]] || die 'Cache requires aarch64.'
  local model mem_kib
  model="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)"
  [[ "$model" == *'Orin Nano'* ]] || die "Cache requires Orin Nano; detected ${model:-unknown}."
  mem_kib="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  [[ "$mem_kib" =~ ^[0-9]+$ && "$mem_kib" -ge 7000000 && "$mem_kib" -le 9000000 ]] \
    || die "Cache requires Orin Nano 8GB; detected MemTotal ${mem_kib:-unknown} KiB."
  L4T_VERSION="$(pkg_version nvidia-l4t-core)"
  JETPACK_VERSION="$(pkg_version nvidia-jetpack)"
  CUDA_VERSION="$(pkg_version cuda-toolkit-13-2)"
  TRT_VERSION="$(pkg_version libnvinfer10)"
  [[ "$L4T_VERSION" == 39.2.* ]] || die "Expected L4T 39.2.x; detected $L4T_VERSION."
  [[ "$JETPACK_VERSION" == 7.2-* ]] || die "Expected JetPack 7.2; detected $JETPACK_VERSION."
  [[ -n "$CUDA_VERSION" && -n "$TRT_VERSION" ]] || die 'CUDA/TensorRT package versions are unavailable.'
}

runtime_valid() {
  [[ -x "$BUILD_DIR/examples/llm/llm_build" \
    && -x "$BUILD_DIR/examples/llm/llm_inference" \
    && -x "$BUILD_DIR/examples/multimodal/visual_build" \
    && -f "$BUILD_DIR/libNvInfer_edgellm_plugin.so" ]]
}

datasets_valid() {
  [[ -s "$DATASET_DIR/mtbench/mtbench_dataset.json" \
    && -s "$DATASET_DIR/coco/dataset.json" \
    && "$(find "$DATASET_DIR/coco/images" -maxdepth 1 -type f 2>/dev/null | wc -l)" -eq 5000 ]]
}

engines_valid() {
  [[ -d "$LOCAL_MODEL_ROOT" ]] || return 1
  [[ "$(find "$LOCAL_MODEL_ROOT" -path '*/engine/*' -type f -name '*.engine' 2>/dev/null | wc -l)" -eq 15 ]]
}

engine_cache_compatible() {
  collect_environment
  [[ -d "$ENGINE_CACHE_DIR/models" ]] || return 1
  [[ "$(find "$ENGINE_CACHE_DIR/models" -path '*/engine/*' -type f -name '*.engine' 2>/dev/null | wc -l)" -eq 15 ]]
}

manifest_matches() {
  local manifest="$1"
  [[ -s "$manifest" ]] || return 1
  jq -e \
    --arg l4t "$L4T_VERSION" \
    --arg jp "$JETPACK_VERSION" \
    --arg cuda "$CUDA_VERSION" \
    --arg trt "$TRT_VERSION" \
    --arg edge "$EDGE_COMMIT" \
    --arg home "$EXPECTED_HOME" \
    '.schema == 1 and .platform == "Jetson Orin Nano 8GB" and
     .compute_capability == "8.7" and .l4t == $l4t and .jetpack == $jp and
     .cuda_toolkit == $cuda and .tensorrt == $trt and
     .edgellm_commit == $edge and .home == $home' "$manifest" >/dev/null
}

cache_valid() {
  collect_environment
  cache_compatible || return 1
  (cd "$CACHE_DIR" && sha256sum -c SHA256SUMS >/dev/null)
}

cache_compatible() {
  collect_environment
  manifest_matches "$CACHE_DIR/manifest.json" || return 1
  [[ -s "$CACHE_DIR/runtime-build.tar" && -s "$CACHE_DIR/datasets.tar" \
    && -s "$CACHE_DIR/SHA256SUMS" ]]
}

write_manifest() {
  local destination="$1"
  jq -n \
    --arg created "$(date --iso-8601=seconds)" \
    --arg l4t "$L4T_VERSION" \
    --arg jp "$JETPACK_VERSION" \
    --arg cuda "$CUDA_VERSION" \
    --arg trt "$TRT_VERSION" \
    --arg edge "$EDGE_COMMIT" \
    --arg home "$EXPECTED_HOME" \
    --arg build "$BUILD_DIR" \
    --arg datasets "$DATASET_DIR" \
    '{schema:1, platform:"Jetson Orin Nano 8GB", compute_capability:"8.7",
      created:$created, l4t:$l4t, jetpack:$jp, cuda_toolkit:$cuda,
      tensorrt:$trt, edgellm_tag:"v0.9.0", edgellm_commit:$edge,
      home:$home, build_dir:$build, dataset_dir:$datasets,
      contents:["complete CMake runtime build", "MTBench", "COCO Caption2017 val (5000 images)"]}' \
    >"$destination"
}

publish() {
  collect_environment
  runtime_valid || die "Runtime is incomplete: $BUILD_DIR"
  datasets_valid || die "Datasets are incomplete: $DATASET_DIR"
  if [[ -e "$CACHE_DIR" ]]; then
    cache_valid || die "An incompatible or incomplete cache already exists: $CACHE_DIR"
    info "Existing NAS cache is complete and verified."
    return
  fi
  local local_stage nas_stage build_name
  local_stage="$(mktemp -d "$BENCH_ROOT/.setup-cache-publish.XXXXXX")"
  nas_stage="${CACHE_DIR}.uploading.$(date +%Y%m%d_%H%M%S).$$"
  build_name="$(basename "$BUILD_DIR")"
  info "Archiving the complete runtime build (about 252MB)"
  tar -C "$REPO_DIR" -cf "$local_stage/runtime-build.tar" "$build_name"
  info "Archiving MTBench and COCO (about 433MB)"
  tar -C "$BENCH_ROOT" -cf "$local_stage/datasets.tar" datasets
  write_manifest "$local_stage/manifest.json"
  (cd "$local_stage" && sha256sum runtime-build.tar datasets.tar manifest.json >SHA256SUMS)
  mkdir -p "$(dirname "$CACHE_DIR")" "$nas_stage"
  rsync -a --info=progress2 "$local_stage/" "$nas_stage/"
  (cd "$nas_stage" && sha256sum -c SHA256SUMS)
  mv "$nas_stage" "$CACHE_DIR"
  rm -f -- "$local_stage/runtime-build.tar" "$local_stage/datasets.tar" \
    "$local_stage/manifest.json" "$local_stage/SHA256SUMS"
  rmdir "$local_stage"
  cache_valid || die 'NAS cache failed its post-upload verification.'
  info "Published and verified: $CACHE_DIR"
}

restore_runtime() {
  cache_valid || die "No compatible verified cache at $CACHE_DIR"
  if runtime_valid; then info 'Local runtime is already complete; no extraction needed.'; return; fi
  [[ ! -e "$BUILD_DIR" ]] || die "Refusing to overwrite incomplete build directory: $BUILD_DIR"
  info "Restoring runtime from $CACHE_DIR/runtime-build.tar"
  tar -C "$REPO_DIR" -xf "$CACHE_DIR/runtime-build.tar"
  runtime_valid || die 'Restored runtime failed validation.'
}

restore_datasets() {
  cache_valid || die "No compatible verified cache at $CACHE_DIR"
  if datasets_valid; then info 'Local datasets are already complete; no extraction needed.'; return; fi
  [[ ! -e "$DATASET_DIR" ]] || die "Refusing to overwrite incomplete dataset directory: $DATASET_DIR"
  mkdir -p "$BENCH_ROOT"
  info "Restoring datasets from $CACHE_DIR/datasets.tar"
  tar -C "$BENCH_ROOT" -xf "$CACHE_DIR/datasets.tar"
  datasets_valid || die 'Restored datasets failed validation.'
}

restore_engines() {
  engine_cache_compatible || die "No compatible complete engine cache at $ENGINE_CACHE_DIR"
  if engines_valid; then info 'Local engine cache is already complete; no download needed.'; return; fi
  [[ ! -e "$LOCAL_MODEL_ROOT" ]] || die "Refusing to overwrite incomplete model directory: $LOCAL_MODEL_ROOT"
  info "Restoring 15 TensorRT engine plans from $ENGINE_CACHE_DIR"
  mkdir -p "$LOCAL_MODEL_ROOT"
  rsync -a --info=progress2 "$ENGINE_CACHE_DIR/models/" "$LOCAL_MODEL_ROOT/"
  engines_valid || die 'Restored engine cache failed validation.'
}

case "$ACTION" in
  check) cache_valid ;;
  compatible) cache_compatible ;;
  check-runtime) collect_environment; runtime_valid ;;
  check-datasets) collect_environment; datasets_valid ;;
  check-engines) collect_environment; engines_valid ;;
  engines-compatible) engine_cache_compatible ;;
  publish) publish ;;
  restore-runtime) restore_runtime ;;
  restore-datasets) restore_datasets ;;
  restore-engines) restore_engines ;;
  *) die 'Usage: edgellm_setup_cache_orinnano.sh {check|compatible|check-runtime|check-datasets|check-engines|engines-compatible|publish|restore-runtime|restore-datasets|restore-engines}' ;;
esac
