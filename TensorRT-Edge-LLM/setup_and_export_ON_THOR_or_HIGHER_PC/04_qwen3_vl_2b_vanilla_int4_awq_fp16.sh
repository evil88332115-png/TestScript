#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ENTRY_SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
export MODE=vanilla-vlm
export HF_MODEL=Qwen/Qwen3-VL-2B-Instruct
export MODEL_NAME=Qwen3-VL-2B-Instruct-int4-awq-fp16
export EXPECTED_COMPONENTS=llm,visual
export NAS_RELATIVE_DIR=10-1-TensorRT-Edge-LLM-models/Orin-Nano-8GB/JetPack-7.2_R39.2/v0.9.0/Qwen3-VL-2B-Instruct/Vanilla-INT4-AWQ-FP16
exec "$SCRIPT_DIR/edgellm_orin_export_common.sh" "$@"
