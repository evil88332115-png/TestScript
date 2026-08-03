#!/usr/bin/env python3
"""Select a small COCO subset matching a target average Qwen3-VL image-token count."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

from PIL import Image


def smart_resize_tokens(height: int, width: int, *, factor: int = 32,
                        min_pixels: int = 100352, max_pixels: int = 2097152) -> int:
    resized_h = round(height / factor) * factor
    resized_w = round(width / factor) * factor
    if resized_h * resized_w > max_pixels:
        beta = math.sqrt((height * width) / max_pixels)
        resized_h = math.floor(height / beta / factor) * factor
        resized_w = math.floor(width / beta / factor) * factor
    elif resized_h * resized_w < min_pixels:
        beta = math.sqrt(min_pixels / (height * width))
        resized_h = math.ceil(height * beta / factor) * factor
        resized_w = math.ceil(width * beta / factor) * factor
    return (resized_h // factor) * (resized_w // factor)


def image_path(request: dict) -> Path:
    for message in request.get("messages", []):
        content = message.get("content", [])
        if not isinstance(content, list):
            continue
        for item in content:
            if item.get("type") == "image" and item.get("image"):
                return Path(item["image"])
    raise ValueError("request has no image path")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--requests", type=int, default=20)
    parser.add_argument("--average-image-tokens", type=int, default=265)
    args = parser.parse_args()

    data = json.loads(args.input.read_text(encoding="utf-8"))
    requests = data["requests"]
    target = args.requests * args.average_image_tokens
    token_counts: list[int] = []
    for request in requests:
        with Image.open(image_path(request)) as image:
            width, height = image.size
        token_counts.append(smart_resize_tokens(height, width))

    states: list[dict[int, tuple[int, ...]]] = [dict() for _ in range(args.requests + 1)]
    states[0][0] = ()
    for index, tokens in enumerate(token_counts):
        for count in range(min(args.requests, index + 1), 0, -1):
            for subtotal, chosen in list(states[count - 1].items()):
                new_total = subtotal + tokens
                if new_total <= target and new_total not in states[count]:
                    states[count][new_total] = chosen + (index,)
        if target in states[args.requests]:
            break

    chosen = states[args.requests].get(target)
    if chosen is None:
        raise SystemExit(f"no {args.requests}-request subset totals exactly {target} image tokens")

    output = dict(data)
    output["requests"] = [requests[index] for index in chosen]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"selected indices: {','.join(map(str, chosen))}")
    print(f"image tokens: {sum(token_counts[index] for index in chosen)}")
    print(f"average image tokens: {args.average_image_tokens}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
