#!/usr/bin/env bash
set -euo pipefail

if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
  COLOR_TITLE=$'\033[1;36m'
  COLOR_OK=$'\033[1;32m'
  COLOR_WARN=$'\033[1;33m'
  COLOR_ERROR=$'\033[1;31m'
  COLOR_RESET=$'\033[0m'
else
  COLOR_TITLE=""
  COLOR_OK=""
  COLOR_WARN=""
  COLOR_ERROR=""
  COLOR_RESET=""
fi

PACKAGES=(
  bonnie++
  build-essential
  cifs-utils
  cmake
  coreutils
  curl
  dosfstools
  e2fsprogs
  exfatprogs
  ffmpeg
  freeglut3-dev
  git
  gir1.2-gstreamer-1.0
  glmark2
  gstreamer1.0-libav
  gstreamer1.0-plugins-bad
  gstreamer1.0-plugins-base
  gstreamer1.0-plugins-good
  gstreamer1.0-plugins-ugly
  gstreamer1.0-tools
  iperf
  iperf3
  libfreeimage-dev
  libgl1-mesa-dev
  libglfw3-dev
  libglib2.0-bin
  libglu1-mesa-dev
  libopenmpi-dev
  libvulkan-dev
  lsb-release
  lshw
  memtester
  mesa-utils
  mtr-tiny
  net-tools
  network-manager
  nvme-cli
  openmpi-bin
  openssh-client
  pciutils
  pkg-config
  procps
  python3
  python3-gi
  python3-matplotlib
  python3-numpy
  python3-onnx
  python3-pandas
  python3-pip
  sshpass
  sysbench
  usbutils
  util-linux
  vulkan-tools
  wget
  wmctrl
  wput
  x11-xserver-utils
  xdotool
)

# Intentionally not installed here.  These NVIDIA SDK/meta packages are large
# and remain the responsibility of their dedicated test/preparation scripts.
EXCLUDED_LARGE_PACKAGES=(
  nvidia-jetpack
  nvidia-l4t-dla-compiler
  libcudla-12-6
  tensorrt
)

REQUIRED_COMMANDS=(
  bon_csv2html
  bonnie++
  cmake
  curl
  dd
  ffplay
  ffprobe
  findmnt
  fsck
  fsck.exfat
  fsck.vfat
  gdbus
  git
  glmark2
  glxgears
  glxinfo
  gsettings
  gst-launch-1.0
  gst-play-1.0
  hwclock
  ifconfig
  iperf
  iperf3
  lshw
  lsblk
  lspci
  lsusb
  make
  memtester
  mount.cifs
  mtr
  nmcli
  nvme
  pkg-config
  python3
  sftp
  ssh
  sshpass
  sync
  sysbench
  sysctl
  timedatectl
  timeout
  vulkaninfo
  wget
  wmctrl
  wput
  xdotool
  xrandr
)

JETSON_COMMANDS=(
  nvgstplayer-1.0
  tegrastats
)

install_packages() {
  if ! command -v apt-get >/dev/null 2>&1; then
    printf '%sERROR: apt-get not found. This installer supports Ubuntu/Debian only.%s\n' \
      "${COLOR_ERROR}" "${COLOR_RESET}" >&2
    exit 1
  fi

  local sudo_cmd=()
  if [[ "$(id -u)" -ne 0 ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
      printf '%sERROR: sudo not found. Run this script as root.%s\n' \
        "${COLOR_ERROR}" "${COLOR_RESET}" >&2
      exit 1
    fi
    sudo_cmd=(sudo)
  fi

  printf '%sInstalling test requirements...%s\n' "${COLOR_TITLE}" "${COLOR_RESET}"
  "${sudo_cmd[@]}" apt-get update
  if [[ "${#sudo_cmd[@]}" -gt 0 ]]; then
    "${sudo_cmd[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y "${PACKAGES[@]}"
  else
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${PACKAGES[@]}"
  fi
}

verify_commands() {
  local command_name
  local missing=0

  echo
  printf '%s=== General command check ===%s\n' "${COLOR_TITLE}" "${COLOR_RESET}"
  for command_name in "${REQUIRED_COMMANDS[@]}"; do
    if command -v "${command_name}" >/dev/null 2>&1; then
      printf '%s[OK]     %-22s %s%s\n' \
        "${COLOR_OK}" "${command_name}" "$(command -v "${command_name}")" "${COLOR_RESET}"
    else
      printf '%s[MISSING] %s%s\n' "${COLOR_ERROR}" "${command_name}" "${COLOR_RESET}"
      missing=1
    fi
  done

  echo
  printf '%s=== Jetson / JetPack component check ===%s\n' "${COLOR_TITLE}" "${COLOR_RESET}"
  for command_name in "${JETSON_COMMANDS[@]}"; do
    if command -v "${command_name}" >/dev/null 2>&1; then
      printf '%s[OK]     %-22s %s%s\n' \
        "${COLOR_OK}" "${command_name}" "$(command -v "${command_name}")" "${COLOR_RESET}"
    else
      printf '%s[WARNING] %-20s not found; install/repair NVIDIA JetPack components.%s\n' \
        "${COLOR_WARN}" "${command_name}" "${COLOR_RESET}"
    fi
  done

  if command -v gst-inspect-1.0 >/dev/null 2>&1; then
    for command_name in nvv4l2decoder nv3dsink nvvidconv; do
      if gst-inspect-1.0 "${command_name}" >/dev/null 2>&1; then
        printf '%s[OK]     GStreamer %-12s available%s\n' \
          "${COLOR_OK}" "${command_name}" "${COLOR_RESET}"
      else
        printf '%s[WARNING] GStreamer %-12s not found; NVIDIA accelerated tests may fail.%s\n' \
          "${COLOR_WARN}" "${command_name}" "${COLOR_RESET}"
      fi
    done
  fi

  for python_module in gi matplotlib numpy onnx pandas; do
    if python3 -c "import ${python_module}" >/dev/null 2>&1; then
      printf '%s[OK]     Python %-15s available%s\n' \
        "${COLOR_OK}" "${python_module}" "${COLOR_RESET}"
    else
      printf '%s[MISSING] Python %s%s\n' \
        "${COLOR_ERROR}" "${python_module}" "${COLOR_RESET}"
      missing=1
    fi
  done

  echo
  printf '%s=== Deliberately excluded large packages ===%s\n' \
    "${COLOR_TITLE}" "${COLOR_RESET}"
  printf '  %s\n' "${EXCLUDED_LARGE_PACKAGES[@]}"

  echo
  if [[ "${missing}" -eq 0 ]]; then
    printf '%sRESULT,Requirements,PASS%s\n' "${COLOR_OK}" "${COLOR_RESET}"
  else
    printf '%sRESULT,Requirements,FAIL%s\n' "${COLOR_ERROR}" "${COLOR_RESET}"
    return 1
  fi
}

printf '%s1. Install test requirements%s\n' "${COLOR_TITLE}" "${COLOR_RESET}"
echo "Host: $(hostname)"
echo "Date: $(date --iso-8601=seconds)"
echo

install_packages
verify_commands
