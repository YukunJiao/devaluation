#!/usr/bin/env python3
"""Subset a large GloVe text file to words observed in KWIC contexts."""

from __future__ import annotations

import argparse
import csv
import re
from pathlib import Path


TOKEN_RE = re.compile(r"[a-z]+(?:['-][a-z]+)?")
DEFAULT_EXTRA_WORDS = [
    "she",
    "he",
    "her",
    "his",
    "woman",
    "man",
    "women",
    "men",
    "female",
    "male",
    "girl",
    "boy",
    "mother",
    "father",
    "daughter",
    "son",
    "wife",
    "husband",
    "ladies",
    "gentlemen",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Create a small GloVe CSV for KWIC vocabulary.")
    parser.add_argument("--kwic", required=True, help="American Stories KWIC CSV.")
    parser.add_argument("--glove", required=True, help="Full GloVe text vector file.")
    parser.add_argument("--out", required=True, help="Output CSV for matched vectors.")
    parser.add_argument(
        "--context-column",
        default="context",
        help="KWIC CSV column containing context text.",
    )
    parser.add_argument(
        "--keyword-column",
        default="keyword",
        help="KWIC CSV column containing matched keyword.",
    )
    parser.add_argument(
        "--extra-words",
        nargs="*",
        default=DEFAULT_EXTRA_WORDS,
        help="Additional words to force into the subset, e.g. seed words.",
    )
    return parser.parse_args()


def tokens(text: str) -> list[str]:
    return TOKEN_RE.findall(text.lower())


def read_vocab(path: Path, context_column: str, keyword_column: str) -> set[str]:
    vocab: set[str] = set()
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            vocab.update(tokens(row.get(context_column, "")))
            vocab.update(tokens(row.get(keyword_column, "")))
    return vocab


def subset_glove(glove_path: Path, out_path: Path, vocab: set[str]) -> int:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    matched = 0
    dims: int | None = None

    with glove_path.open("r", encoding="utf-8", errors="replace") as glove, out_path.open(
        "w", encoding="utf-8", newline=""
    ) as out:
        writer = None
        for line in glove:
            parts = line.rstrip().split(" ")
            if len(parts) < 3:
                continue
            word = parts[0]
            if word not in vocab:
                continue
            values = parts[1:]
            if dims is None:
                dims = len(values)
                writer = csv.writer(out)
                writer.writerow(["word"] + [f"d{i + 1}" for i in range(dims)])
            if writer is None or len(values) != dims:
                continue
            writer.writerow([word] + values)
            matched += 1
    return matched


def main() -> int:
    args = parse_args()
    vocab = read_vocab(Path(args.kwic), args.context_column, args.keyword_column)
    vocab.update(word.lower() for word in args.extra_words)
    matched = subset_glove(Path(args.glove), Path(args.out), vocab)
    print(f"Matched {matched} of {len(vocab)} KWIC vocabulary terms")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
