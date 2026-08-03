#!/usr/bin/env bash
set -Eeuo pipefail

# Rebuild the TensorRT Edge-LLM v0.9.0 ONNX export environment on a freshly
# flashed Jetson AGX Thor / JetPack 7.2 host. Run as the normal user, not root.
#
# This script is idempotent: rerun it after a reboot/login or interrupted step.
# It never deletes existing models, logs, repositories, containers, or NAS data.
# NAS and Hugging Face secrets are never embedded in this file.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${WORKSPACE:-$HOME/edgellm-export-v0.9.0}"
REPO_DIR="$WORKSPACE/TensorRT-Edge-LLM"
CONTAINER_NAME="${CONTAINER_NAME:-edgellm-export-v090}"
CONTAINER_IMAGE="${CONTAINER_IMAGE:-nvcr.io/nvidia/pytorch:26.05-py3}"
EDGE_LLM_TAG="${EDGE_LLM_TAG:-v0.9.0}"
NAS_SOURCE="${NAS_SOURCE:-//192.168.23.12/home}"
NAS_MOUNT_POINT="${NAS_MOUNT_POINT:-/mnt/nas_home}"
NAS_CREDENTIALS="${NAS_CREDENTIALS:-/etc/samba/credentials-nas-home}"
NAS_USERNAME="${NAS_USERNAME:-sqa}"
NAS_PASSWORD="${NAS_PASSWORD:-a1234567}"
SKIP_NAS="${SKIP_NAS:-0}"
RECONFIGURE_NAS="${RECONFIGURE_NAS:-0}"
CHECK_ONLY=0

if [[ "${1:-}" == "--check" ]]; then
  CHECK_ONLY=1
elif [[ -n "${1:-}" ]]; then
  printf 'Usage: %s [--check]\n' "$(basename "$0")" >&2
  exit 2
fi

info() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
repo_git() { git -c safe.directory="$REPO_DIR" -C "$REPO_DIR" "$@"; }

require_normal_user() {
  [[ "$(id -u)" -ne 0 ]] || die "Run as the normal Thor user, not root or sudo. The script requests sudo only where needed."
  [[ -n "${HOME:-}" && "$HOME" == /* ]] || die "HOME is not a valid absolute path."
}

detect_platform() {
  local arch model l4t
  arch="$(uname -m)"
  [[ "$arch" == "aarch64" ]] || die "Expected aarch64, found $arch."
  model="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)"
  [[ "$model" == *Thor* ]] || die "This setup is for Jetson AGX Thor; detected: ${model:-unknown}."
  l4t="$(dpkg-query -W -f='${Version}' nvidia-l4t-core 2>/dev/null || true)"
  [[ "$l4t" == 39.2.* ]] || die "Expected Jetson Linux R39.2.x / JetPack 7.2; nvidia-l4t-core is ${l4t:-missing}."
  info "Platform OK: $model, L4T $l4t, $arch"
}

docker_cmd() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    sudo docker "$@"
  fi
}

install_host_packages() {
  info "Installing host prerequisites"
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl gnupg cifs-utils git git-lfs rsync
  git lfs install --skip-repo

  if ! have docker; then
    info "Installing Docker CE from Docker's Ubuntu repository"
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    local arch codename
    arch="$(dpkg --print-architecture)"
    codename="$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")"
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' "$arch" "$codename" \
      | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi

  sudo systemctl enable --now containerd docker
  if ! id -nG "$USER" | tr ' ' '\n' | grep -Fxq docker; then
    sudo usermod -aG docker "$USER"
    info "Added $USER to the docker group. This takes effect after logout/login; setup will use sudo docker during this run."
  fi

  if ! have nvidia-ctk; then
    info "Installing NVIDIA Container Toolkit from the JetPack repositories"
    sudo apt-get install -y nvidia-container-toolkit
  fi
  sudo nvidia-ctk runtime configure --runtime=docker
  sudo systemctl restart docker
  docker_cmd info >/dev/null
}

install_numbered_scripts() {
  local required file
  required=(
    00_setup_thor_edgellm_v090.sh
    edgellm_orin_export_common.sh
    01_qwen3_0_6b_vanilla_int4_awq.sh
    02_qwen3_1_7b_vanilla_int4_awq.sh
    03_qwen3_1_7b_eagle3_int4_awq.sh
    04_qwen3_vl_2b_vanilla_int4_awq_fp16.sh
    05_qwen3_5_0_8b_vlm_vanilla_int4_awq_fp16.sh
    06_qwen3_5_0_8b_vlm_mtp_int4_awq_fp16.sh
    07_qwen3_5_0_8b_llm_vanilla_int4_awq.sh
    08_qwen3_5_2b_vlm_vanilla_int4_awq_fp16.sh
    09_qwen3_5_2b_llm_vanilla_int4_awq.sh
  )
  mkdir -p "$WORKSPACE/scripts" "$WORKSPACE/models" "$WORKSPACE/logs" "$WORKSPACE/hf-cache"
  for file in "${required[@]}"; do
    [[ -f "$SCRIPT_DIR/$file" ]] || die "Required companion script missing beside setup script: $file"
    local mode=0755
    [[ "$file" == 00_setup_thor_edgellm_v090.sh ]] && mode=0700
    if [[ "$(readlink -f "$SCRIPT_DIR/$file")" == "$(readlink -f "$WORKSPACE/scripts/$file" 2>/dev/null || true)" ]]; then
      chmod "$mode" "$WORKSPACE/scripts/$file"
    else
      install -m "$mode" "$SCRIPT_DIR/$file" "$WORKSPACE/scripts/$file"
    fi
  done
  bash -n "$WORKSPACE/scripts/edgellm_orin_export_common.sh" "$WORKSPACE/scripts/"0[1-9]_*.sh
  info "Installed and syntax-checked numbered scripts in $WORKSPACE/scripts"
}

configure_hf_token() {
  mkdir -p "$WORKSPACE/hf-cache"
  if [[ -n "${HF_TOKEN:-}" ]]; then
    umask 077
    printf '%s' "$HF_TOKEN" >"$WORKSPACE/hf-cache/token"
    chmod 600 "$WORKSPACE/hf-cache/token"
    info "Stored the supplied HF_TOKEN in the persistent HF cache (token value not displayed)."
  elif [[ -s "$WORKSPACE/hf-cache/token" ]]; then
    info "Existing persistent Hugging Face token found."
  else
    info "No HF_TOKEN supplied. Public models work anonymously, with lower Hub rate limits."
  fi
}

prepare_repository() {
  if [[ ! -e "$REPO_DIR" ]]; then
    info "Cloning TensorRT Edge-LLM $EDGE_LLM_TAG"
    git clone --recursive --branch "$EDGE_LLM_TAG" --depth 1 \
      https://github.com/NVIDIA/TensorRT-Edge-LLM.git "$REPO_DIR"
  else
    [[ -d "$REPO_DIR/.git" ]] || die "$REPO_DIR exists but is not a Git repository."
    local dirty tag
    dirty="$(repo_git status --porcelain)"
    [[ -z "$dirty" ]] || die "Repository has local changes; refusing to alter it: $REPO_DIR"
    tag="$(repo_git describe --tags --exact-match 2>/dev/null || true)"
    [[ "$tag" == "$EDGE_LLM_TAG" ]] || die "Existing repository is at ${tag:-a non-tag commit}, expected $EDGE_LLM_TAG."
    repo_git submodule update --init --recursive
  fi
  [[ "$(repo_git describe --tags --exact-match 2>/dev/null)" == "$EDGE_LLM_TAG" ]] \
    || die "Repository tag verification failed."
}

prepare_container() {
  info "Pulling pinned NVIDIA PyTorch container: $CONTAINER_IMAGE"
  docker_cmd pull "$CONTAINER_IMAGE"

  if docker_cmd inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    local image mount
    image="$(docker_cmd inspect -f '{{.Config.Image}}' "$CONTAINER_NAME")"
    [[ "$image" == "$CONTAINER_IMAGE" ]] || die "Existing $CONTAINER_NAME uses $image, expected $CONTAINER_IMAGE."
    mount="$(docker_cmd inspect -f '{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}' "$CONTAINER_NAME")"
    [[ "$mount" == "$WORKSPACE" ]] || die "Existing container maps /workspace from $mount, expected $WORKSPACE."
  else
    info "Creating persistent export container: $CONTAINER_NAME"
    docker_cmd run -dit \
      --name "$CONTAINER_NAME" \
      --runtime nvidia \
      --ipc host \
      --ulimit memlock=-1 \
      --ulimit stack=67108864 \
      --volume "$WORKSPACE:/workspace" \
      --workdir /workspace \
      "$CONTAINER_IMAGE" bash
  fi
  if [[ "$(docker_cmd inspect -f '{{.State.Running}}' "$CONTAINER_NAME")" != true ]]; then
    docker_cmd start "$CONTAINER_NAME" >/dev/null
  fi
}

prepare_python_environment() {
  info "Creating/verifying the v0.9.0 Python environment"
  docker_cmd exec "$CONTAINER_NAME" bash -lc '
    set -Eeuo pipefail
    cd /workspace/TensorRT-Edge-LLM
    if [[ ! -f venv/bin/activate ]]; then
      python3 -m venv --system-site-packages venv
    fi
    source venv/bin/activate
    python3 -m pip install --upgrade pip setuptools wheel
    python3 -m pip install \
      transformers==5.9.0 \
      onnx==1.19.0 \
      onnxscript==0.7.0 \
      safetensors==0.7.0 \
      numpy==2.4.6 \
      onnx-graphsurgeon==0.6.1
    python3 -m pip install --no-deps .
  '
}

configure_nas() {
  [[ "$SKIP_NAS" != 1 ]] || { info "SKIP_NAS=1: NAS setup skipped."; return; }
  info "Configuring secure NAS automount for $NAS_SOURCE"
  sudo install -d -m 0755 "$NAS_MOUNT_POINT" /etc/samba

  if [[ ! -s "$NAS_CREDENTIALS" || "$RECONFIGURE_NAS" == 1 ]]; then
    local tmp
    [[ -n "$NAS_USERNAME" ]] || die "NAS username cannot be empty."
    [[ -n "$NAS_PASSWORD" ]] || die "NAS password cannot be empty."
    tmp="$(mktemp)"
    chmod 600 "$tmp"
    printf 'username=%s\npassword=%s\n' "$NAS_USERNAME" "$NAS_PASSWORD" >"$tmp"
    if ! sudo install -o root -g root -m 0600 "$tmp" "$NAS_CREDENTIALS"; then
      rm -f -- "$tmp"
      die "Failed to install NAS credentials."
    fi
    rm -f -- "$tmp"
  else
    info "Keeping existing root-only NAS credentials: $NAS_CREDENTIALS"
  fi

  local existing fstab_line uid gid
  existing="$(awk -v mp="$NAS_MOUNT_POINT" '$2 == mp {print}' /etc/fstab)"
  if [[ -n "$existing" ]]; then
    [[ "$existing" == "$NAS_SOURCE "* ]] || die "A different /etc/fstab entry already owns $NAS_MOUNT_POINT: $existing"
  else
    uid="$(id -u)"; gid="$(id -g)"
    fstab_line="$NAS_SOURCE $NAS_MOUNT_POINT cifs credentials=$NAS_CREDENTIALS,uid=$uid,gid=$gid,vers=3.0,file_mode=0664,dir_mode=0775,_netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=600 0 0"
    printf '%s\n' "$fstab_line" | sudo tee -a /etc/fstab >/dev/null
  fi
  sudo systemctl daemon-reload
  if ! mountpoint -q "$NAS_MOUNT_POINT"; then
    sudo mount "$NAS_MOUNT_POINT"
  fi
  mountpoint -q "$NAS_MOUNT_POINT" || die "NAS mount failed: $NAS_MOUNT_POINT"
  ls -A "$NAS_MOUNT_POINT" >/dev/null
  [[ "$(findmnt -n -t cifs -o SOURCE --target "$NAS_MOUNT_POINT")" == "$NAS_SOURCE" ]] \
    || die "NAS source verification failed."
  info "NAS mounted and verified: $NAS_SOURCE -> $NAS_MOUNT_POINT"
}

verify_environment() {
  info "Verifying container, CUDA, package versions, scripts, and NAS"
  docker_cmd exec -e HF_HOME=/workspace/hf-cache "$CONTAINER_NAME" \
    /workspace/TensorRT-Edge-LLM/venv/bin/python3 -c '
import torch, transformers, onnx, onnxscript, tensorrt_edgellm
assert torch.cuda.is_available(), "CUDA unavailable"
gpu = torch.cuda.get_device_name(0)
assert "Thor" in gpu, gpu
assert transformers.__version__ == "5.9.0", transformers.__version__
assert onnx.__version__ == "1.19.0", onnx.__version__
assert onnxscript.__version__ == "0.7.0", onnxscript.__version__
print("GPU:", gpu)
print("Torch:", torch.__version__, "CUDA:", torch.version.cuda)
print("Transformers:", transformers.__version__, "ONNX:", onnx.__version__)
'
  [[ "$(repo_git describe --tags --exact-match 2>/dev/null)" == "$EDGE_LLM_TAG" ]] || die "Repo tag check failed."
  bash -n "$WORKSPACE/scripts/edgellm_orin_export_common.sh" "$WORKSPACE/scripts/"0[1-9]_*.sh
  if [[ "$SKIP_NAS" != 1 ]]; then
    mountpoint -q "$NAS_MOUNT_POINT" || die "NAS is not mounted."
    ls -A "$NAS_MOUNT_POINT" >/dev/null
    [[ "$(findmnt -n -t cifs -o SOURCE --target "$NAS_MOUNT_POINT")" == "$NAS_SOURCE" ]] || die "NAS source check failed."
  fi
}

check_existing_only() {
  have docker || die "docker is missing."
  have nvidia-ctk || die "nvidia-ctk is missing."
  [[ -d "$REPO_DIR/.git" ]] || die "Repository is missing: $REPO_DIR"
  [[ -f "$WORKSPACE/scripts/edgellm_orin_export_common.sh" ]] || die "Installed scripts are missing."
  docker_cmd inspect "$CONTAINER_NAME" >/dev/null 2>&1 || die "Container is missing: $CONTAINER_NAME"
  if [[ "$(docker_cmd inspect -f '{{.State.Running}}' "$CONTAINER_NAME")" != true ]]; then docker_cmd start "$CONTAINER_NAME" >/dev/null; fi
  verify_environment
}

main() {
  require_normal_user
  detect_platform
  if [[ "$CHECK_ONLY" == 1 ]]; then
    check_existing_only
    info "CHECK PASSED: the existing Thor export environment is ready."
    return
  fi
  sudo -v
  install_host_packages
  install_numbered_scripts
  configure_hf_token
  prepare_repository
  prepare_container
  prepare_python_environment
  configure_nas
  verify_environment
  info "SETUP COMPLETE"
  printf '%s\n' "Run item 1:" \
    "bash $WORKSPACE/scripts/01_qwen3_0_6b_vanilla_int4_awq.sh"
  if ! docker info >/dev/null 2>&1; then
    printf '%s\n' "NOTE: docker-group access activates after logout/login. Until then, item scripts safely fall back to sudo docker."
  fi
}

main "$@"
