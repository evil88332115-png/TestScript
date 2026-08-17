#!/usr/bin/env bash
set -Eeuo pipefail

# 10-1 LLM Benchmark preset
#
# Non-interactive defaults:
#   - Original cache flow: remove model and JIT caches after use
#   - Run the complete 12-model benchmark set
#   - Skip the optional full nvidia-jetpack installation prompt

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_SCRIPT="${SCRIPT_DIR}/run_10_1_LLMBenchmark.sh"

if [[ ! -f "$MAIN_SCRIPT" ]]; then
  printf 'ERROR: Main 10-1 script not found: %s\n' "$MAIN_SCRIPT" >&2
  exit 1
fi

printf '10-1 LLM Benchmark preset\n'
printf '  Cache mode:  remove (option 1)\n'
printf '  Model count: 12\n'

exec env \
  INSTALL_JETPACK=0 \
  MLC_CACHE_MODE=remove \
  MLC_MODEL_COUNT=12 \
  MLC_ONLY_MODEL= \
  bash "$MAIN_SCRIPT" "$@"
