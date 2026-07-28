#!/usr/bin/env bash

set -u

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

print_item() {
    printf '• %s: %s\n' "$1" "$2"
}

print_command() {
    printf 'Command: %s\n' "$1"
}

ensure_mesa_utils() {
    if have_cmd glxinfo; then
        return 0
    fi

    echo "glxinfo not found. Installing mesa-utils..."
    sudo apt-get install -y mesa-utils
}

export DISPLAY=:0
ensure_mesa_utils

echo "Commands:"
print_command "lsb_release -ds"
print_command "dpkg -s nvidia-jetpack"
print_command "dpkg -s cuda-toolkit-12-6"
print_command "dpkg -s libcudnn9-cuda-12"
print_command "dpkg -s tensorrt"
print_command "glxinfo"
print_command "vulkaninfo"
echo
echo "Results:"

# Operating System
OS_NAME="$(lsb_release -ds 2>/dev/null || grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"')"
print_item "Operating System" "${OS_NAME:-Unknown}"

# JetPack SDK
if dpkg -s nvidia-jetpack >/dev/null 2>&1; then
    JP_VER="$(dpkg -s nvidia-jetpack 2>/dev/null | sed -n 's/^Version: //p' | head -n1)"
elif [[ -f /etc/nv_tegra_release ]]; then
    JP_VER="$(sed 's/^# //' /etc/nv_tegra_release | head -n1)"
else
    JP_VER="N/A"
fi
print_item "JetPack SDK version" "${JP_VER:-N/A}"

# CUDA Toolkit
# dpkg-query -W lists every known package matching the glob, including ones
# that are merely referenced but not installed (empty Version, Status "not
# installed"/"unknown"). Filter to Status "install ok installed" and take the
# highest version so a stray/leftover package (e.g. an older cuda-toolkit-*
# left over from a previous JetPack install) can't be picked over the real one.
CUDA_VER=""
if dpkg -s cuda-toolkit-12-6 >/dev/null 2>&1; then
    CUDA_VER="$(dpkg -s cuda-toolkit-12-6 2>/dev/null | sed -n 's/.*Locked at CUDA Toolkit version \([^ .]*\.[^ .]*\).*/\1/p' | head -n1)"
    if [[ -z "${CUDA_VER}" ]]; then
        CUDA_VER="$(dpkg-query -W -f='${Package}\n' cuda-toolkit-12-6 2>/dev/null | sed -n 's/^cuda-toolkit-\([0-9]\+\)-\([0-9]\+\)$/\1.\2/p')"
    fi
fi
if [[ -z "${CUDA_VER}" ]]; then
    CUDA_PKG="$(dpkg-query -W -f='${Status}\t${Package}\n' 'cuda-toolkit-*' 2>/dev/null \
        | awk -F'\t' '$1 == "install ok installed" && $2 ~ /^cuda-toolkit-[0-9]+-[0-9]+$/ {print $2}' \
        | sort -rV | head -n1)"
    CUDA_VER="$(printf '%s\n' "${CUDA_PKG}" | sed -n 's/^cuda-toolkit-\([0-9]\+\)-\([0-9]\+\)$/\1.\2/p')"
fi
if [[ -z "${CUDA_VER}" && -f /usr/local/cuda/version.json ]]; then
    CUDA_VER="$(grep -m1 '"version"' /usr/local/cuda/version.json | sed 's/.*: *"//;s/".*//')"
fi
if [[ -z "${CUDA_VER}" && -f /usr/local/cuda/version.txt ]]; then
    CUDA_VER="$(sed -n 's/^CUDA Version //p' /usr/local/cuda/version.txt | head -n1)"
fi
if [[ -z "${CUDA_VER}" ]] && have_cmd nvcc; then
    CUDA_VER="$(nvcc --version 2>/dev/null | awk '/release/{print $6}' | tr -d ',')"
fi
if [[ -n "${CUDA_VER}" && "${CUDA_VER}" != V* ]]; then
    CUDA_VER="V${CUDA_VER}"
fi
print_item "CUDA Toolkit version" "${CUDA_VER:-N/A}"

# cuDNN
CUDNN_VER=""
if dpkg -s libcudnn9-cuda-12 >/dev/null 2>&1; then
    CUDNN_VER="$(dpkg -s libcudnn9-cuda-12 2>/dev/null | sed -n 's/^Version: //p' | head -n1)"
fi
if [[ -z "${CUDNN_VER}" ]]; then
    # Multiarch installs put the header under /usr/include/<triplet>/, not
    # directly in /usr/include (e.g. /usr/include/aarch64-linux-gnu/).
    CUDNN_HEADER="$(find /usr/include -maxdepth 2 -iname 'cudnn_version.h' 2>/dev/null | head -n1)"
    if [[ -n "${CUDNN_HEADER}" ]]; then
        CUDNN_MAJOR="$(awk '/^#define CUDNN_MAJOR/{print $3}' "${CUDNN_HEADER}")"
        CUDNN_MINOR="$(awk '/^#define CUDNN_MINOR/{print $3}' "${CUDNN_HEADER}")"
        CUDNN_PATCH="$(awk '/^#define CUDNN_PATCHLEVEL/{print $3}' "${CUDNN_HEADER}")"
        if [[ -n "${CUDNN_MAJOR}" ]]; then
            CUDNN_VER="${CUDNN_MAJOR}.${CUDNN_MINOR}.${CUDNN_PATCH}"
        fi
    fi
fi
if [[ -z "${CUDNN_VER}" ]]; then
    CUDNN_VER="$(dpkg-query -W -f='${Status}\t${Version}\n' 'libcudnn*' 2>/dev/null \
        | awk -F'\t' '$1 == "install ok installed" && $2 != "" {print $2}' \
        | sort -rV | head -n1)"
fi
print_item "cuDNN version" "${CUDNN_VER:-N/A}"

# TensorRT
if dpkg -s tensorrt >/dev/null 2>&1; then
    TRT_VER="$(dpkg -s tensorrt 2>/dev/null | sed -n 's/^Version: //p' | head -n1)"
else
    TRT_VER="$(dpkg-query -W -f='${Version}\n' 'libnvinfer*' 2>/dev/null | head -n1)"
fi
print_item "TensorRT version" "${TRT_VER:-N/A}"

# OpenGL / OpenGL ES
GL_VER="N/A"
GLES_VER="N/A"
if have_cmd glxinfo && GLX_OUT="$(glxinfo 2>/dev/null)"; then
    GL_VER="$(printf '%s\n' "$GLX_OUT" | awk -F': ' '/OpenGL version string/{print $2; exit}')"
    GLES_VER="$(printf '%s\n' "$GLX_OUT" | awk -F': ' '/OpenGL ES profile version string/{print $2; exit}')"
fi
print_item "OpenGL version" "${GL_VER:-N/A}"
print_item "OpenGL ES version" "${GLES_VER:-N/A}"

# Vulkan
VK_VER="N/A"
if have_cmd vulkaninfo && VK_OUT="$(vulkaninfo 2>/dev/null)"; then
    VK_VER="$(printf '%s\n' "$VK_OUT" | awk -F'= ' '/apiVersion/{print $2; exit}')"
fi
print_item "Vulkan version" "${VK_VER:-N/A}"
