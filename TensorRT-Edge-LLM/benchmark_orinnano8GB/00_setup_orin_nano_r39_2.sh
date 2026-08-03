#!/usr/bin/env bash
set -Eeuo pipefail

# One-time, idempotent setup for TensorRT Edge-LLM v0.9.0 benchmarks on
# Jetson Orin Nano 8GB / JetPack 7.2 / Jetson Linux R39.2.
# Run as the normal user. This script requests sudo when needed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EDGE_TAG="${EDGE_TAG:-v0.9.0}"
DATASET_TOOLS_TAG="${DATASET_TOOLS_TAG:-v0.9.1}"
REPO_DIR="${REPO_DIR:-$HOME/edgellm-src-v0.9.0}"
BUILD_DIR="${BUILD_DIR:-$REPO_DIR/build-orin-r39.2-v0.9.0}"
BENCH_ROOT="${BENCH_ROOT:-$HOME/edgellm-benchmark}"
DATASET_DIR="${DATASET_DIR:-$BENCH_ROOT/datasets}"
DATASET_TOOLS_DIR="${DATASET_TOOLS_DIR:-$BENCH_ROOT/dataset-tools-v0.9.1}"
VENV_DIR="${VENV_DIR:-$BENCH_ROOT/venv}"
BUILD_JOBS="${BUILD_JOBS:-2}"
SWAP_FILE="${SWAP_FILE:-/mnt/16GB.swap}"
SWAP_SIZE="${SWAP_SIZE:-16G}"
NAS_SOURCE="${NAS_SOURCE:-//192.168.23.12/home}"
NAS_MOUNT="${NAS_MOUNT:-/mnt/nas_home}"
NAS_CREDENTIALS="${NAS_CREDENTIALS:-/etc/samba/credentials-nas-home}"
NAS_USERNAME="${NAS_USERNAME:-sqa}"
NAS_PASSWORD="${NAS_PASSWORD:-a1234567}"
NVP_MODE_ID="${NVP_MODE_ID:-0}"
NVP_MODE_NAME="${NVP_MODE_NAME:-15W}"
RUNTIME_SOURCE="${RUNTIME_SOURCE:-ask}"
DATASET_SOURCE="${DATASET_SOURCE:-ask}"
PUBLISH_SETUP_CACHE="${PUBLISH_SETUP_CACHE:-1}"
CACHE_HELPER="${CACHE_HELPER:-$SCRIPT_DIR/edgellm_setup_cache_orinnano.sh}"

info() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
repo_git() { git -c safe.directory="$REPO_DIR" -C "$REPO_DIR" "$@"; }
cache_helper() {
  REPO_DIR="$REPO_DIR" BUILD_DIR="$BUILD_DIR" BENCH_ROOT="$BENCH_ROOT" \
    DATASET_DIR="$DATASET_DIR" NAS_MOUNT="$NAS_MOUNT" "$CACHE_HELPER" "$@"
}

platform_check() {
  [[ "$(id -u)" -ne 0 ]] || die "Run as the normal user, not sudo/root."
  [[ "$(uname -m)" == aarch64 ]] || die "Expected aarch64."
  local model l4t mem_kib
  model="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)"
  [[ "$model" == *"Orin Nano"* ]] || die "Expected Orin Nano, detected: ${model:-unknown}"
  mem_kib="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  [[ "$mem_kib" =~ ^[0-9]+$ && "$mem_kib" -ge 7000000 && "$mem_kib" -le 9000000 ]] \
    || die "Expected Orin Nano 8GB (MemTotal 7,000,000-9,000,000 KiB), detected ${mem_kib:-unknown} KiB."
  l4t="$(dpkg-query -W -f='${Version}' nvidia-l4t-core 2>/dev/null || true)"
  [[ "$l4t" == 39.2.* ]] || die "Expected R39.2.x, detected nvidia-l4t-core ${l4t:-missing}"
  info "Platform OK: $model / 8GB class (${mem_kib} KiB visible) / L4T $l4t"
}

install_jetpack_first() {
  # Intentionally the first installation stage requested by the user.
  info "Step 1: installing the complete JetPack 7.2 SDK meta-package"
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-jetpack
  dpkg-query -W nvidia-jetpack cuda-toolkit-13-2 libnvinfer-dev libnvonnxparsers-dev >/dev/null \
    || die "JetPack installation did not provide all required development packages."
  export PATH="/usr/local/cuda/bin:$PATH"
  command -v nvcc >/dev/null || die "nvcc is still missing after JetPack installation."
}

install_support_packages() {
  info "Installing benchmark support packages"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential cmake git git-lfs cifs-utils rsync jq \
    python3-venv python3-pip nvme-cli
  git lfs install --skip-repo
}

configure_swap() {
  info "Configuring persistent $SWAP_SIZE build swap"
  if [[ ! -f "$SWAP_FILE" ]]; then
    sudo install -d -m 0755 "$(dirname "$SWAP_FILE")"
    sudo fallocate -l "$SWAP_SIZE" "$SWAP_FILE"
    sudo chmod 0600 "$SWAP_FILE"
    sudo mkswap "$SWAP_FILE"
  fi
  grep -qF "$SWAP_FILE" /proc/swaps || sudo swapon "$SWAP_FILE"
  if ! grep -qF "$SWAP_FILE none swap sw 0 0" /etc/fstab; then
    printf '%s none swap sw 0 0\n' "$SWAP_FILE" | sudo tee -a /etc/fstab >/dev/null
  fi
  free -h
  swapon --show
}

configure_nas() {
  info "Configuring NAS automount"
  sudo install -d -m 0755 "$NAS_MOUNT" /etc/samba
  local tmp existing existing_source uid gid line
  tmp="$(mktemp)"
  chmod 0600 "$tmp"
  printf 'username=%s\npassword=%s\n' "$NAS_USERNAME" "$NAS_PASSWORD" >"$tmp"
  if ! sudo install -o root -g root -m 0600 "$tmp" "$NAS_CREDENTIALS"; then
    rm -f -- "$tmp"
    die "Failed to install NAS credentials."
  fi
  rm -f -- "$tmp"

  uid="$(id -u)"; gid="$(id -g)"
  line="$NAS_SOURCE $NAS_MOUNT cifs credentials=$NAS_CREDENTIALS,uid=$uid,gid=$gid,vers=3.0,file_mode=0664,dir_mode=0775,_netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=600 0 0"
  existing="$(awk -v mp="$NAS_MOUNT" '$2 == mp {print}' /etc/fstab)"
  if [[ -n "$existing" ]]; then
    existing_source="$(awk -v mp="$NAS_MOUNT" '$2 == mp {print $1; exit}' /etc/fstab)"
    [[ "$existing_source" == "$NAS_SOURCE" ]] || die "A different fstab entry owns $NAS_MOUNT: $existing"
    if [[ "$existing" != "$line" ]]; then
      tmp="$(mktemp)"
      awk -v mp="$NAS_MOUNT" -v desired="$line" '
        $2 == mp { if (!written) print desired; written=1; next }
        { print }
        END { if (!written) print desired }
      ' /etc/fstab >"$tmp"
      sudo install -o root -g root -m 0644 "$tmp" /etc/fstab
      rm -f -- "$tmp"
    fi
  else
    printf '%s\n' "$line" | sudo tee -a /etc/fstab >/dev/null
  fi
  sudo systemctl daemon-reload
  mountpoint -q "$NAS_MOUNT" || sudo mount "$NAS_MOUNT"
  ls -A "$NAS_MOUNT" >/dev/null
  [[ "$(findmnt -n -t cifs -o SOURCE --target "$NAS_MOUNT")" == "$NAS_SOURCE" ]] \
    || die "NAS mount source verification failed."
}

prepare_repo() {
  info "Preparing TensorRT Edge-LLM $EDGE_TAG source"
  if [[ ! -e "$REPO_DIR" ]]; then
    git clone --recursive --branch "$EDGE_TAG" --depth 1 \
      https://github.com/NVIDIA/TensorRT-Edge-LLM.git "$REPO_DIR"
  else
    local dirty build_rel
    [[ -d "$REPO_DIR/.git" ]] || die "$REPO_DIR exists but is not a Git repository."
    if [[ "$BUILD_DIR" == "$REPO_DIR/"* ]]; then
      build_rel="${BUILD_DIR#"$REPO_DIR/"}"
      dirty="$(repo_git status --porcelain -- . ":(exclude)$build_rel")"
    else
      dirty="$(repo_git status --porcelain)"
    fi
    [[ -z "$dirty" ]] || die "Repository has unexpected local changes: $dirty"
    [[ "$(repo_git describe --tags --exact-match 2>/dev/null || true)" == "$EDGE_TAG" ]] \
      || die "Repository is not at $EDGE_TAG."
    repo_git submodule update --init --recursive
  fi
}

build_runtime_from_source() {
  info "Configuring and building the Orin SM87 C++ runtime with $BUILD_JOBS jobs"
  export PATH=/usr/local/cuda/bin:$PATH
  if [[ ! -f "$BUILD_DIR/CMakeCache.txt" ]]; then
    cmake -S "$REPO_DIR" -B "$BUILD_DIR" \
      -DCMAKE_BUILD_TYPE=Release \
      -DTRT_PACKAGE_DIR=/usr \
      -DCMAKE_TOOLCHAIN_FILE=cmake/aarch64_linux_toolchain.cmake \
      -DEMBEDDED_TARGET=jetson-orin \
      -DCUDA_CTK_VERSION=13.2 \
      -DENABLE_CUTE_DSL=ALL
  fi
  cmake --build "$BUILD_DIR" --parallel "$BUILD_JOBS"
  [[ -x "$BUILD_DIR/examples/llm/llm_build" ]] || die "llm_build was not produced."
  [[ -x "$BUILD_DIR/examples/llm/llm_inference" ]] || die "llm_inference was not produced."
  [[ -f "$BUILD_DIR/libNvInfer_edgellm_plugin.so" ]] || die "Edge-LLM plugin library is missing."
}

prepare_runtime() {
  local source="$RUNTIME_SOURCE" choice
  [[ -x "$CACHE_HELPER" ]] || die "Cache helper is missing or not executable: $CACHE_HELPER"
  if cache_helper check-runtime; then
    info "Reusing the complete local Edge-LLM runtime; CMake build is skipped."
    return
  fi
  if [[ "$source" == ask ]]; then
    if [[ -t 0 ]]; then
      printf '\nRuntime source:\n  1) verified NAS cache\n  2) rebuild from v0.9.0 source\n'
      read -r -p 'Choose [1/2]: ' choice
      [[ "$choice" == 1 ]] && source=nas || source=build
    else
      source=auto
    fi
  fi
  case "$source" in
    auto)
      if cache_helper compatible; then
        info "Compatible NAS runtime cache found; CMake build will be skipped."
        cache_helper restore-runtime
      else
        info "No compatible NAS runtime cache; building from source."
        build_runtime_from_source
      fi
      ;;
    nas) cache_helper restore-runtime ;;
    build) build_runtime_from_source ;;
    *) die "RUNTIME_SOURCE must be auto, nas, build, or ask; received: $source" ;;
  esac
  cache_helper check-runtime || die 'Runtime preparation did not produce valid binaries.'
}

prepare_datasets() {
  info "Preparing official MTBench and COCO benchmark inputs"
  mkdir -p "$BENCH_ROOT"
  local source="$DATASET_SOURCE"
  if cache_helper check-datasets; then
    info "Reusing complete local MTBench and COCO datasets; generation is skipped."
    return
  fi
  if [[ "$source" == ask ]]; then
    if [[ -t 0 ]]; then
      local choice
      printf '\nDataset source:\n  1) verified NAS cache\n  2) download and regenerate\n'
      read -r -p 'Choose [1/2]: ' choice
      [[ "$choice" == 1 ]] && source=nas || source=build
    else
      source=auto
    fi
  fi
  if [[ "$source" == nas ]] || { [[ "$source" == auto ]] && cache_helper compatible; }; then
    cache_helper restore-datasets
    return
  fi
  [[ "$source" == auto || "$source" == build ]] \
    || die "DATASET_SOURCE must be auto, nas, build, or ask; received: $source"
  mkdir -p "$DATASET_DIR"
  if [[ ! -f "$VENV_DIR/bin/activate" ]]; then python3 -m venv "$VENV_DIR"; fi
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
  python3 -m pip install --upgrade pip
  python3 -m pip install -r "$REPO_DIR/examples/accuracy/requirements.txt"
  if [[ ! -s "$DATASET_DIR/mtbench/mtbench_dataset.json" ]]; then
    python3 "$REPO_DIR/examples/accuracy/scripts/prepare_dataset.py" \
      --dataset MTBench --output_dir "$DATASET_DIR/mtbench" --batch_size 1
  fi
  if [[ ! -s "$DATASET_DIR/coco/dataset.json" ]]; then
    info "Preparing the NVIDIA $DATASET_TOOLS_TAG COCO converter beside the v0.9.0 runtime source"
    if [[ ! -f "$DATASET_TOOLS_DIR/.source-commit" ]]; then
      [[ ! -e "$DATASET_TOOLS_DIR" ]] \
        || die "Incomplete dataset tools directory exists: $DATASET_TOOLS_DIR"
      repo_git fetch --depth=1 origin "tag" "$DATASET_TOOLS_TAG"
      local tools_tmp source_commit
      tools_tmp="$(mktemp -d "$BENCH_ROOT/.dataset-tools-v0.9.1.XXXXXX")"
      repo_git archive "$DATASET_TOOLS_TAG" examples/accuracy | tar -x -C "$tools_tmp"
      mv "$tools_tmp/examples/accuracy" "$DATASET_TOOLS_DIR"
      rmdir "$tools_tmp/examples" "$tools_tmp"
      source_commit="$(repo_git rev-parse "$DATASET_TOOLS_TAG^{commit}")"
      printf '%s\n' "$source_commit" >"$DATASET_TOOLS_DIR/.source-commit"
    fi
    [[ "$(cat "$DATASET_TOOLS_DIR/.source-commit")" == "$(repo_git rev-parse "$DATASET_TOOLS_TAG^{commit}")" ]] \
      || die "Dataset tools provenance check failed for $DATASET_TOOLS_TAG."
    python3 -m pip install -r "$DATASET_TOOLS_DIR/requirements.txt"
    # COCO stores decoded images. The v0.9.1 requirements pin datasets 4.8.5
    # but omit its optional Pillow-backed vision dependency.
    python3 -m pip install 'datasets[vision]==4.8.5'
    python3 "$DATASET_TOOLS_DIR/scripts/prepare_dataset.py" \
      --dataset COCO --output_dir "$DATASET_DIR/coco" --batch_size 1
  fi
  deactivate
}

prepare_benchmark_python() {
  info "Preparing fixed-token benchmark helper"
  if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    python3 -m venv "$VENV_DIR"
  fi
  "$VENV_DIR/bin/python" -m pip install 'tokenizers==0.22.2'
}

install_benchmark_scripts() {
  info "Installing benchmark runner and parser"
  mkdir -p "$BENCH_ROOT/scripts" "$BENCH_ROOT/models" "$BENCH_ROOT/results" "$BENCH_ROOT/logs"
  local file mode
  for file in 00_setup_orin_nano_r39_2.sh 01_build_and_benchmark_9_models.sh parse_edgellm_profiles.py prepare_fixed_llm_input.py prepare_coco_shape_subset.py edgellm_setup_cache_orinnano.sh; do
    [[ -f "$SCRIPT_DIR/$file" ]] || die "Companion file missing beside setup script: $file"
    mode=0755; [[ "$file" == 00_setup_orin_nano_r39_2.sh ]] && mode=0700
    if [[ "$(readlink -f "$SCRIPT_DIR/$file")" == "$(readlink -f "$BENCH_ROOT/scripts/$file" 2>/dev/null || true)" ]]; then
      chmod "$mode" "$BENCH_ROOT/scripts/$file"
    else
      install -m "$mode" "$SCRIPT_DIR/$file" "$BENCH_ROOT/scripts/$file"
    fi
  done
  bash -n "$BENCH_ROOT/scripts/00_setup_orin_nano_r39_2.sh" "$BENCH_ROOT/scripts/01_build_and_benchmark_9_models.sh"
  bash -n "$BENCH_ROOT/scripts/edgellm_setup_cache_orinnano.sh"
  python3 -m py_compile "$BENCH_ROOT/scripts/parse_edgellm_profiles.py"
  python3 -m py_compile "$BENCH_ROOT/scripts/prepare_coco_shape_subset.py"
  "$VENV_DIR/bin/python" -m py_compile "$BENCH_ROOT/scripts/prepare_fixed_llm_input.py"
  python3 "$BENCH_ROOT/scripts/prepare_coco_shape_subset.py" \
    --input "$DATASET_DIR/coco/dataset.json" \
    --output "$DATASET_DIR/coco/dataset_nvidia_shape_20.json" \
    --requests 20 --average-image-tokens 265
}

configure_performance_mode() {
  info "Verifying nvpmodel mode $NVP_MODE_NAME ($NVP_MODE_ID)"
  local power_mode
  power_mode="$(nvpmodel -q)"
  [[ "$power_mode" == *"$NVP_MODE_NAME"* && "$(printf '%s\n' "$power_mode" | tail -n 1)" == "$NVP_MODE_ID" ]] \
    || die "Expected power mode $NVP_MODE_NAME ($NVP_MODE_ID), detected: $power_mode. Run 'sudo nvpmodel -m $NVP_MODE_ID', reboot when requested, then rerun setup."
  printf '%s\n' "$power_mode"
}

health_check() {
  info "Final health check"
  nvcc --version
  dpkg-query -W nvidia-jetpack nvidia-l4t-core cuda-toolkit-13-2 libnvinfer-dev libnvonnxparsers-dev
  local smart critical_warning media_errors fatal_events timeout_count
  smart="$(sudo nvme smart-log /dev/nvme0)"
  printf '%s\n' "$smart"
  critical_warning="$(printf '%s\n' "$smart" | awk -F: '/^critical_warning/ {gsub(/[[:space:]]/, "", $2); print $2}')"
  media_errors="$(printf '%s\n' "$smart" | awk -F: '/^media_errors/ {gsub(/[[:space:]]/, "", $2); print $2}')"
  [[ "$critical_warning" == 0 ]] || die "NVMe SMART critical_warning is $critical_warning."
  [[ "$media_errors" == 0 ]] || die "NVMe SMART media_errors is $media_errors."
  fatal_events="$(sudo dmesg | grep -Ei 'nvme.*(reset|I/O error|controller is down|device not ready)|EXT4-fs error|Buffer I/O error.*nvme' || true)"
  [[ -z "$fatal_events" ]] || die "Fatal NVMe/filesystem events detected: $fatal_events"
  timeout_count="$(sudo dmesg | grep -Eic 'nvme.*timeout' || true)"
  if (( timeout_count > 0 )); then
    info "WARNING: $timeout_count recovered NVMe timeout event(s) exist in this boot; benchmark preflight will use this count as its baseline."
  fi
  "$BUILD_DIR/examples/llm/llm_build" --help >/dev/null
  "$BUILD_DIR/examples/llm/llm_inference" --help >/dev/null
  info "SETUP COMPLETE"
  printf 'Next command:\n  bash %s/scripts/01_build_and_benchmark_9_models.sh\n' "$BENCH_ROOT"
  [[ ! -e /var/run/reboot-required ]] || info "A reboot is requested by installed packages; reboot, rerun this setup, then run item 01."
}

main() {
  platform_check
  sudo -v
  install_jetpack_first
  install_support_packages
  configure_swap
  configure_nas
  prepare_repo
  prepare_runtime
  prepare_datasets
  prepare_benchmark_python
  if [[ "$PUBLISH_SETUP_CACHE" == 1 ]]; then cache_helper publish; fi
  install_benchmark_scripts
  configure_performance_mode
  health_check
}

main "$@"
