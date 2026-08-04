#!/usr/bin/env python3
"""Parse TensorRT Edge-LLM v0.9.0 llm_inference profile JSON files."""

from __future__ import annotations

import argparse
import csv
import json
import re
from pathlib import Path


MODELS = {
    "01": ("Qwen3-0.6B", "LLM", "Vanilla", "INT4 AWQ", "-"),
    "02": ("Qwen3-1.7B", "LLM", "Vanilla", "INT4 AWQ", "-"),
    "03": ("Qwen3-1.7B", "LLM", "EAGLE3", "INT4 AWQ / INT4 AWQ", "-"),
    "04": ("Qwen3-VL-2B-Instruct", "VLM", "Vanilla", "INT4 AWQ / FP16", "COCO"),
    "05": ("Qwen3.5-0.8B", "VLM", "Vanilla", "INT4 AWQ / FP16", "COCO"),
    "06": ("Qwen3.5-0.8B", "VLM", "MTP", "INT4 AWQ / INT4 AWQ / FP16", "COCO"),
    "07": ("Qwen3.5-0.8B-LLM", "LLM", "Vanilla", "INT4 AWQ", "-"),
    "08": ("Qwen3.5-2B", "VLM", "Vanilla", "INT4 AWQ / FP16", "COCO"),
    "09": ("Qwen3.5-2B-LLM", "LLM", "Vanilla", "INT4 AWQ", "-"),
}

FIELDS = [
    "Model", "Kind", "Mode", "Precision", "Dataset", "Batch",
    "Prefill Seq Len", "Prefill Time (ms)", "Prefill (tok/s)",
    "ViT Time (ms)", "ViT Tok/Run", "ViT (tok/s)",
    "Generation (tok/s)", "Accept Rate", "GPU Mem (MB)", "Profile",
]


def nested(data: dict, *keys: str):
    value = data
    for key in keys:
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value


def number(value, digits=1):
    if value is None:
        return "-"
    try:
        return f"{float(value):,.{digits}f}"
    except (TypeError, ValueError):
        return "-"


def parse_profile(path: Path) -> dict[str, str]:
    match = re.match(r"(\d{2})_", path.name)
    if not match or match.group(1) not in MODELS:
        raise ValueError(f"unrecognized profile filename: {path.name}")
    model_id = match.group(1)
    model, kind, mode, precision, dataset = MODELS[model_id]
    with path.open(encoding="utf-8") as handle:
        data = json.load(handle)

    prefill_tokens = nested(data, "prefill", "average_tokens_per_run")
    prefill_ms = nested(data, "prefill", "average_time_per_run_ms")
    prefill_tps = nested(data, "prefill", "tokens_per_second")

    generation_section = "generation"
    if mode == "EAGLE3":
        generation_section = "eagle_generation"
    elif mode == "MTP":
        generation_section = "mtp_generation"
    generation_tps = nested(data, generation_section, "tokens_per_second")
    if mode != "Vanilla":
        generation_tps = nested(
            data, generation_section,
            "overall_tokens_per_second_excluding_base_prefill",
        ) or generation_tps
    accept_rate = nested(data, generation_section, "average_acceptance_rate")

    runs = nested(data, "multimodal", "total_runs")
    total_image_tokens = nested(data, "multimodal", "total_image_tokens")
    vit_ms_per_token = nested(data, "multimodal", "average_time_per_token_ms")
    vit_tokens = vit_time = vit_tps = None
    if runs and total_image_tokens is not None:
        vit_tokens = float(total_image_tokens) / float(runs)
        if vit_ms_per_token is not None:
            vit_time = float(vit_ms_per_token) * vit_tokens
            vit_tps = 1000.0 / float(vit_ms_per_token)

    return {
        "Model": model,
        "Kind": kind,
        "Mode": mode,
        "Precision": precision,
        "Dataset": dataset,
        "Batch": "1",
        "Prefill Seq Len": number(prefill_tokens, 0),
        "Prefill Time (ms)": number(prefill_ms),
        "Prefill (tok/s)": number(prefill_tps),
        "ViT Time (ms)": number(vit_time),
        "ViT Tok/Run": number(vit_tokens, 0),
        "ViT (tok/s)": number(vit_tps),
        "Generation (tok/s)": number(generation_tps),
        "Accept Rate": number(accept_rate, 2),
        "GPU Mem (MB)": number(data.get("peak_unified_memory_mb"), 0),
        "Profile": path.name,
        "_id": model_id,
    }


def markdown(rows: list[dict[str, str]]) -> str:
    shown = FIELDS[:-1]
    lines = [
        "# TensorRT Edge-LLM v0.9.0 — Jetson Orin Nano 8GB",
        "",
        "| " + " | ".join(shown) + " |",
        "| " + " | ".join(["---"] * len(shown)) + " |",
    ]
    for row in rows:
        lines.append("| " + " | ".join(row[field] for field in shown) + " |")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("profiles_dir", type=Path)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()

    profiles = sorted(args.profiles_dir.glob("*.profile.json"))
    if not profiles:
        parser.error(f"no *.profile.json files in {args.profiles_dir}")
    rows = sorted((parse_profile(path) for path in profiles), key=lambda row: row["_id"])
    args.output_dir.mkdir(parents=True, exist_ok=True)

    csv_path = args.output_dir / "benchmark-results.csv"
    with csv_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)

    md_path = args.output_dir / "benchmark-results.md"
    md_path.write_text(markdown(rows), encoding="utf-8")
    json_path = args.output_dir / "benchmark-results.json"
    json_path.write_text(
        json.dumps([{k: v for k, v in row.items() if k != "_id"} for row in rows], indent=2),
        encoding="utf-8",
    )
    print(markdown(rows), end="")
    print(f"Wrote {csv_path}, {md_path}, and {json_path}")
    missing = sorted(set(MODELS) - {row["_id"] for row in rows})
    if missing:
        print("Partial run; missing model IDs: " + ", ".join(missing))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
