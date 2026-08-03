#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ENTRY_SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
export MODE=vanilla-llm
export HF_MODEL=Qwen/Qwen3.5-2B
export MODEL_NAME=Qwen3.5-2B-llm-int4-awq
export QUANT_DIR_OVERRIDE=/workspace/models/Qwen3.5-2B-vlm-int4-awq-fp16/quantized
export EXPECTED_COMPONENTS=llm
export NAS_RELATIVE_DIR=10-1-TensorRT-Edge-LLM-models/Orin-Nano-8GB/JetPack-7.2_R39.2/v0.9.0/Qwen3.5-2B/LLM-Vanilla-INT4-AWQ
exec "$SCRIPT_DIR/edgellm_orin_export_common.sh" "$@"
