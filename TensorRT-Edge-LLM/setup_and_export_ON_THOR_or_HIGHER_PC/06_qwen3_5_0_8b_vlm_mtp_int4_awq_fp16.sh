#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ENTRY_SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
export MODE=mtp-vlm
export HF_MODEL=Qwen/Qwen3.5-0.8B
export MODEL_NAME=Qwen3.5-0.8B-vlm-mtp-int4-awq-fp16
# Keep a dedicated quantized checkpoint for MTP.  Reusing the Vanilla VLM
# checkpoint can silently produce a draft graph with near-zero acceptance.
export EXPECTED_COMPONENTS=llm,mtp_draft,visual
export NAS_RELATIVE_DIR=10-1-TensorRT-Edge-LLM-models/Orin-Nano-8GB/JetPack-7.2_R39.2/v0.9.0/Qwen3.5-0.8B/VLM-MTP-INT4-AWQ-FP16
exec "$SCRIPT_DIR/edgellm_orin_export_common.sh" "$@"
