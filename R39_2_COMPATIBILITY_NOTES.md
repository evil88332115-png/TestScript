# JetPack 7.2 / L4T R39.2 compatibility notes

Updated: 2026-07-28

## Test target

- Jetson Orin Nano Super 8GB (P3767-0003)
- JetPack 7.2 / L4T R39.2
- Ubuntu 24.04, CUDA 13.2
- Test host: `192.168.23.101`

## MLC status

The old `dustynv/mlc:0.1.4-r36.4.2` image is tied to JetPack 6 / CUDA 12.6 and
cannot expose a usable CUDA device on R39.2.  R39.2 therefore uses a separately
built image:

```text
mlc:r39.2.tegra-aarch64-cu132-24.04-mlc
```

Validated components in this image:

- CUDA device `cuda:0` on SM87
- TVM `0.24.dev0` from MLC's bundled, compatible TVM source
- TVM-FFI `0.1.10`
- MLC LLM 0.20 development build
- MLC model import, JIT compilation and CUDA inference

Triton was removed from the final runtime image because importing its LLVM
extension caused a registry crash on this stack.  The selected q4f16 models use
TVM/CUDA and do not require Triton.

## R39 model cache

MLC 0.20 expects `tensor-cache.json`.  The R36 MLC 0.1.4 cache uses the older
`ndarray-cache.json` format and its compiled model libraries are ABI-incompatible.
The caches must remain separate:

```text
Local R39: /home/p/jetson-containers/data/models/mlc/cache-r39
NAS R39:   /mnt/nas_home/10-1-MLC-model-cache-r39
Local R36: /home/p/jetson-containers/data/models/mlc/cache
NAS R36:   /mnt/nas_home/10-1-MLC-model-cache
```

The R39 6-model and complete 12-model sets use the
`mlc-ai/*-q4f16_1-MLC` repositories.

The validated image backup is stored at:

```text
/mnt/nas_home/10-1-MLC-docker-images/mlc-r39.2-cu132-ubuntu24.04-mlc0.20-sm87-aarch64.tar.zst
```

Restore it with:

```bash
zstd -dc /mnt/nas_home/10-1-MLC-docker-images/mlc-r39.2-cu132-ubuntu24.04-mlc0.20-sm87-aarch64.tar.zst | sudo docker load
```

`run_10_1_LLMBenchmark.sh` checks this image at startup on R39.  If the local
image is missing, it automatically restores this NAS backup before starting
the benchmark.

## R36-compatible benchmark parameters

MLC 0.20 defaults Llama 3.1 8B to a 131072-token context and an 8192-token
prefill chunk.  That configuration needs about 4308 MB for weights plus 2836 MB
for a temporary buffer and cannot start in the available unified GPU memory.
The R39 benchmark nevertheless passes the same effective context and prefill
values as the R36 benchmark so results are not collected under silently reduced
parameters.  On an 8GB Orin Nano, large models can therefore fail with OOM on
R39 instead of being run under a smaller, non-comparable configuration.

## Other script compatibility items

- `run_3_2_power_mode.sh`: R39 reports `jetson_clocks --show` CPU fields in a
  different format.  Matching must not loop waiting for the old R36 format.
- `run_10_2_tensorrt_test.sh`: hard-coded CUDA 12.6 packages must be selected by
  installed CUDA/L4T version.  Orin Nano has no DLA, so the DLA runtime check is
  reported as SKIP and does not block the TensorRT GPU FP16 test.
- `check.sh`: select `libcudnn9-cuda-13` on R39 instead of the CUDA 12 package.
- Ubuntu 24.04 may provide `glmark2-x11` or `glmark2-wayland` instead of the
  generic `glmark2` package.

## Build failures that were diagnosed

- The Jetson wheel index cannot be the only Python package index; ordinary
  packages such as `pip` need the PyPI fallback index.
- Installing PyTorch's `nvidia-cudnn-cu13` wheel beside JetPack cuDNN caused
  `CUDNN_STATUS_SUBLIBRARY_VERSION_MISMATCH`.  The pip cuDNN copy was removed so
  the container uses the matching JetPack CUDA stack.
- The external TVM selected by the original dependency graph lacked the Relax
  APIs required by MLC (`tirx` and `s_tir`).  Building MLC's bundled TVM fixed
  that API/ABI mismatch.
- R39 Orin must be compiled for compute capability SM87.  Server-only SM80/90/
  100/110/120 targets do not cover Orin.

The warning `InvalidDefaultArgInFrom` is a Dockerfile lint warning and was not
the cause of the failed builds.

## Historical validated six-model result

The complete script passed on 2026-07-27 with four prompts and 128 output
tokens per prompt:

| Model | Decode rate (tokens/s) |
| --- | ---: |
| Llama 3.1 8B | 14.39 |
| Llama 3.2 3B | 31.62 |
| Qwen2.5 7B | 15.93 |
| Gemma 2 2B | 34.04 |
| Phi 3.5 mini | 27.27 |
| SmolLM2 1.7B | 53.21 |

The R39 benchmark copy sets MLC's `ignore_eos` debug option so all models
generate exactly 128 tokens.  Without it, Qwen frequently stops around 30--40
tokens and the upstream benchmark retries forever.
