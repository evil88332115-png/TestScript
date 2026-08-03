#!/usr/bin/env python3
"""Create and validate fixed-token TensorRT Edge-LLM benchmark inputs."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from tokenizers import Tokenizer


def formatted_prompt(template: dict, content: str) -> str:
    user = template["roles"]["user"]
    return user["prefix"] + content + user["suffix"] + template["generation_prompt"]


def find_content(tokenizer: Tokenizer, template: dict, target: int) -> tuple[str, int]:
    # A repeated common word gives one-token increments with Qwen tokenizers.  Try
    # several separators so this remains robust across Qwen3 and Qwen3.5.
    for unit in (" a", " test", " benchmark", " detail", "1"):
        for count in range(target * 3 + 1):
            content = "Benchmark GPU inference performance." + unit * count
            length = len(tokenizer.encode(formatted_prompt(template, content)).ids)
            if length == target:
                return content, length
            if length > target + 16:
                break
    raise RuntimeError(f"Could not construct a prompt of exactly {target} tokens")


def generate(args: argparse.Namespace) -> None:
    tokenizer_dir = Path(args.tokenizer_dir)
    tokenizer = Tokenizer.from_file(str(tokenizer_dir / "tokenizer.json"))
    template = json.loads((tokenizer_dir / "processed_chat_template.json").read_text())
    content, actual = find_content(tokenizer, template, args.target_tokens)

    request = {
        "messages": [{"role": "user", "content": content}],
    }
    payload = {
        "batch_size": 1,
        "temperature": 1.0,
        "top_p": 1.0,
        "top_k": 50,
        "max_generate_length": args.max_generate_length,
        "requests": [request for _ in range(args.requests)],
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(payload, indent=2) + "\n")
    metadata = {
        "purpose": "NVIDIA-table-compatible token shape; original NVIDIA prompt is not public",
        "target_prefill_tokens": args.target_tokens,
        "tokenizer_verified_tokens": actual,
        "requests": args.requests,
        "max_generate_length": args.max_generate_length,
        "tokenizer_dir": str(tokenizer_dir),
    }
    output.with_suffix(output.suffix + ".metadata.json").write_text(
        json.dumps(metadata, indent=2) + "\n"
    )
    print(f"Created {output}: {args.requests} requests, {actual} prefill tokens each")


def verify(args: argparse.Namespace) -> None:
    profile = json.loads(Path(args.profile).read_text())
    actual = float(profile["prefill"]["average_tokens_per_run"])
    if abs(actual - args.target_tokens) > 0.01:
        raise SystemExit(
            f"Profile token mismatch: expected {args.target_tokens}, measured {actual}"
        )
    print(f"Verified runtime profile prefill length: {actual:g} tokens")


def make_greedy(args: argparse.Namespace) -> None:
    payload = json.loads(Path(args.input).read_text())
    # TensorRT Edge-LLM v0.9.0 treats top_k=1 as greedy-compatible regardless
    # of the dataset's temperature/top_p values.  EAGLE3 and MTP otherwise
    # silently fall back to vanilla decoding.
    payload["top_k"] = 1
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(payload, indent=2) + "\n")
    print(f"Created greedy speculative-decoding input: {output}")


def stats(args: argparse.Namespace) -> None:
    tokenizer_dir = Path(args.tokenizer_dir)
    tokenizer = Tokenizer.from_file(str(tokenizer_dir / "tokenizer.json"))
    template = json.loads((tokenizer_dir / "processed_chat_template.json").read_text())
    payload = json.loads(Path(args.input).read_text())
    raw_lengths = []
    formatted_lengths = []
    for request in payload["requests"]:
        content = "".join(
            message["content"]
            for message in request["messages"]
            if message["role"] == "user"
        )
        raw_lengths.append(len(tokenizer.encode(content).ids))
        formatted_lengths.append(
            len(tokenizer.encode(formatted_prompt(template, content)).ids)
        )
    print(
        f"requests={len(raw_lengths)} "
        f"raw_avg={sum(raw_lengths) / len(raw_lengths):.3f} "
        f"formatted_avg={sum(formatted_lengths) / len(formatted_lengths):.3f} "
        f"raw_range={min(raw_lengths)}-{max(raw_lengths)} "
        f"formatted_range={min(formatted_lengths)}-{max(formatted_lengths)}"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    create = sub.add_parser("create")
    create.add_argument("--tokenizer-dir", required=True)
    create.add_argument("--output", required=True)
    create.add_argument("--target-tokens", type=int, required=True)
    create.add_argument("--requests", type=int, default=20)
    create.add_argument("--max-generate-length", type=int, default=512)
    create.set_defaults(func=generate)

    check = sub.add_parser("verify")
    check.add_argument("--profile", required=True)
    check.add_argument("--target-tokens", type=int, required=True)
    check.set_defaults(func=verify)

    greedy = sub.add_parser("greedy")
    greedy.add_argument("--input", required=True)
    greedy.add_argument("--output", required=True)
    greedy.set_defaults(func=make_greedy)

    inspect = sub.add_parser("stats")
    inspect.add_argument("--tokenizer-dir", required=True)
    inspect.add_argument("--input", required=True)
    inspect.set_defaults(func=stats)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
