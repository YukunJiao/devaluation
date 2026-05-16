#!/usr/bin/env python3
"""Extract KWIC rows from American Stories year archives.

The American Stories dataset is distributed as one compressed archive per year
on Hugging Face. This script streams or caches those yearly archives, scans the
article text, and writes keyword-in-context rows to CSV.
"""

from __future__ import annotations

import argparse
import csv
import gzip
import io
import json
import os
import re
import shutil
import ssl
import sys
import tarfile
import tempfile
import time
import urllib.request
from pathlib import Path
from typing import BinaryIO, Iterator


BASE_URL = (
    "https://huggingface.co/datasets/dell-research-harvard/"
    "AmericanStories/resolve/main/faro_{year}.tar.gz"
)

TOKEN_RE = re.compile(r"[A-Za-z]+(?:['-][A-Za-z]+)?|\d+|[^\w\s]", re.UNICODE)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Extract keyword-in-context rows from American Stories."
    )
    parser.add_argument(
        "--years",
        nargs="+",
        required=True,
        help="Years to scan, e.g. --years 1870 1880 1890",
    )
    parser.add_argument(
        "--terms",
        nargs="+",
        default=[],
        help="Keywords or phrases to match. Combine with --terms-file if needed.",
    )
    parser.add_argument(
        "--terms-file",
        help="Plain text file with one keyword or phrase per line.",
    )
    parser.add_argument(
        "--window",
        type=int,
        default=50,
        help="Number of tokens to keep on each side of the matched term.",
    )
    parser.add_argument(
        "--out",
        required=True,
        help="Output CSV path.",
    )
    parser.add_argument(
        "--cache-dir",
        help=(
            "Optional directory for yearly tar.gz archives. If omitted, archives "
            "are streamed into a temporary file and removed after each year."
        ),
    )
    parser.add_argument(
        "--keep-archives",
        action="store_true",
        help="Keep downloaded archives in --cache-dir. Requires --cache-dir.",
    )
    parser.add_argument(
        "--case-sensitive",
        action="store_true",
        help="Match terms case-sensitively.",
    )
    parser.add_argument(
        "--max-rows",
        type=int,
        help="Stop after writing this many KWIC rows. Useful for pilot runs.",
    )
    parser.add_argument(
        "--max-rows-per-term",
        type=int,
        help=(
            "Stop collecting each keyword after this many KWIC rows. Useful "
            "when high-frequency terms would otherwise dominate a pilot sample."
        ),
    )
    parser.add_argument(
        "--max-rows-per-year-term",
        type=int,
        help=(
            "Stop collecting each keyword within each year after this many "
            "KWIC rows. This is usually the right limit for multi-year samples."
        ),
    )
    parser.add_argument(
        "--max-articles",
        type=int,
        help="Stop after scanning this many articles across all selected years.",
    )
    parser.add_argument(
        "--max-articles-per-year",
        type=int,
        help="Stop scanning each year after this many articles, then continue to the next year.",
    )
    parser.add_argument(
        "--timeout-seconds",
        type=int,
        help="Stop cleanly after this many seconds.",
    )
    parser.add_argument(
        "--progress-every",
        type=int,
        default=1000,
        help="Print progress after this many scanned articles. Use 0 to disable.",
    )
    return parser.parse_args()


def read_terms(args: argparse.Namespace) -> list[str]:
    terms = list(args.terms)
    if args.terms_file:
        with open(args.terms_file, "r", encoding="utf-8") as handle:
            terms.extend(
                line.strip()
                for line in handle
                if line.strip() and not line.lstrip().startswith("#")
            )
    deduped = []
    seen = set()
    for term in terms:
        key = term if args.case_sensitive else term.lower()
        if key not in seen:
            seen.add(key)
            deduped.append(term)
    if not deduped:
        raise SystemExit("No terms supplied. Use --terms or --terms-file.")
    return deduped


def term_tokens(term: str) -> list[str]:
    return TOKEN_RE.findall(term)


def download_year(year: str, target: Path) -> None:
    url = BASE_URL.format(year=year)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_suffix(target.suffix + ".tmp")
    print(f"Downloading {year}: {url}", file=sys.stderr)
    with urllib.request.urlopen(url, context=https_context()) as response, open(tmp, "wb") as out:
        shutil.copyfileobj(response, out)
    tmp.replace(target)


def https_context() -> ssl.SSLContext:
    if os.environ.get("AMSTORIES_INSECURE_SSL") == "1":
        return ssl._create_unverified_context()
    try:
        import certifi

        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ssl.create_default_context()


def open_archive(year: str, args: argparse.Namespace) -> tuple[BinaryIO, Path | None]:
    if args.cache_dir:
        archive = Path(args.cache_dir) / f"faro_{year}.tar.gz"
        if not archive.exists():
            download_year(year, archive)
        return open(archive, "rb"), archive

    tmp = tempfile.NamedTemporaryFile(prefix=f"faro_{year}_", suffix=".tar.gz", delete=False)
    tmp_path = Path(tmp.name)
    tmp.close()
    download_year(year, tmp_path)
    return open(tmp_path, "rb"), tmp_path


def iter_json_members(fileobj: BinaryIO) -> Iterator[dict]:
    with tarfile.open(fileobj=fileobj, mode="r|gz") as archive:
        for member in archive:
            if not member.isfile() or not member.name.endswith(".json"):
                continue
            extracted = archive.extractfile(member)
            if extracted is None:
                continue
            try:
                payload = extracted.read().decode("utf-8")
                data = json.loads(payload)
            except (UnicodeDecodeError, json.JSONDecodeError, EOFError, gzip.BadGzipFile):
                continue
            yield {"path": member.name, "data": data}


def scan_id_parts(path: str) -> dict[str, str]:
    stem = Path(path).name.rsplit(".", 1)[0]
    parts = stem.split("_")
    out = {"scan_id": stem, "date": "", "page": "", "edition": ""}
    if len(parts) >= 2:
        out["date"] = parts[0]
        out["page"] = parts[1]
    if len(parts) >= 3:
        out["edition"] = parts[-2].replace("edition", "")
    return out


def normalize_token(token: str, case_sensitive: bool) -> str:
    return token if case_sensitive else token.lower()


def find_matches(
    tokens: list[str],
    term_map: list[tuple[str, list[str]]],
    case_sensitive: bool,
) -> Iterator[tuple[int, int, str]]:
    haystack = [normalize_token(token, case_sensitive) for token in tokens]
    for label, needles in term_map:
        n = len(needles)
        if n == 0:
            continue
        for i in range(0, len(haystack) - n + 1):
            if haystack[i : i + n] == needles:
                yield i, i + n, label


def emit_kwic_rows(
    article: str,
    term_map: list[tuple[str, list[str]]],
    window: int,
    case_sensitive: bool,
) -> Iterator[dict[str, str | int]]:
    tokens = TOKEN_RE.findall(article)
    for start, end, label in find_matches(tokens, term_map, case_sensitive):
        left = tokens[max(0, start - window) : start]
        match = tokens[start:end]
        right = tokens[end : min(len(tokens), end + window)]
        yield {
            "keyword": label,
            "match": " ".join(match),
            "left": " ".join(left),
            "right": " ".join(right),
            "context": " ".join(left + match + right),
            "token_start": start,
            "token_end": end - 1,
        }


def iter_article_records(year: str, fileobj: BinaryIO) -> Iterator[dict[str, str]]:
    for wrapped in iter_json_members(fileobj):
        path = wrapped["path"]
        data = wrapped["data"]
        if not isinstance(data, dict) or "full articles" not in data:
            continue
        lccn = data.get("lccn") or {}
        newspaper_name = lccn.get("title", "") if isinstance(lccn, dict) else ""
        scan = scan_id_parts(path)
        for article in data.get("full articles") or []:
            if not isinstance(article, dict):
                continue
            article_text = article.get("article") or ""
            if not article_text:
                continue
            article_id = f"{article.get('full_article_id', '')}_{scan['scan_id']}"
            yield {
                "year": year,
                "article_id": article_id,
                "newspaper_name": newspaper_name,
                "date": scan["date"],
                "page": scan["page"],
                "edition": scan["edition"],
                "headline": article.get("headline") or "",
                "byline": article.get("byline") or "",
                "article": article_text,
            }


def main() -> int:
    started_at = time.monotonic()
    args = parse_args()
    terms = read_terms(args)
    term_map = [
        (
            term,
            [normalize_token(token, args.case_sensitive) for token in term_tokens(term)],
        )
        for term in terms
    ]
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    fieldnames = [
        "year",
        "date",
        "newspaper_name",
        "article_id",
        "page",
        "edition",
        "headline",
        "byline",
        "keyword",
        "match",
        "left",
        "right",
        "context",
        "token_start",
        "token_end",
    ]

    rows_written = 0
    articles_scanned = 0
    articles_scanned_by_year = {year: 0 for year in args.years}
    rows_by_term = {term: 0 for term in terms}
    rows_by_year_term = {
        year: {term: 0 for term in terms}
        for year in args.years
    }
    with open(out_path, "w", encoding="utf-8", newline="") as out:
        writer = csv.DictWriter(out, fieldnames=fieldnames)
        writer.writeheader()
        for year in args.years:
            if args.max_rows_per_year_term and all(
                count >= args.max_rows_per_year_term
                for count in rows_by_year_term[year].values()
            ):
                print(f"Skipping {year}; all year-term quotas already filled", file=sys.stderr)
                continue
            if args.max_rows_per_term and all(
                count >= args.max_rows_per_term for count in rows_by_term.values()
            ):
                break
            fileobj, archive_path = open_archive(year, args)
            try:
                print(f"Scanning {year}", file=sys.stderr)
                for record in iter_article_records(year, fileobj):
                    articles_scanned += 1
                    articles_scanned_by_year[year] += 1
                    if args.progress_every and articles_scanned % args.progress_every == 0:
                        print(
                            "Progress: "
                            f"{articles_scanned} articles scanned, "
                            f"{rows_written} rows written, "
                            f"rows by term: {rows_by_term}",
                            file=sys.stderr,
                            flush=True,
                        )
                    for kwic in emit_kwic_rows(
                        record["article"],
                        term_map,
                        args.window,
                        args.case_sensitive,
                    ):
                        if (
                            args.max_rows_per_term
                            and rows_by_term[kwic["keyword"]] >= args.max_rows_per_term
                        ):
                            continue
                        if (
                            args.max_rows_per_year_term
                            and rows_by_year_term[year][kwic["keyword"]]
                            >= args.max_rows_per_year_term
                        ):
                            continue
                        row = {key: record.get(key, "") for key in fieldnames}
                        row.update(kwic)
                        writer.writerow(row)
                        rows_written += 1
                        rows_by_term[kwic["keyword"]] += 1
                        rows_by_year_term[year][kwic["keyword"]] += 1
                        if args.max_rows and rows_written >= args.max_rows:
                            print(f"Wrote {rows_written} rows", file=sys.stderr)
                            print(f"Rows by term: {rows_by_term}", file=sys.stderr)
                            print(f"Rows by year and term: {rows_by_year_term}", file=sys.stderr)
                            return 0
                        if (
                            args.timeout_seconds
                            and time.monotonic() - started_at >= args.timeout_seconds
                        ):
                            print(
                                f"Stopped after timeout of {args.timeout_seconds} seconds",
                                file=sys.stderr,
                            )
                            print(f"Wrote {rows_written} rows", file=sys.stderr)
                            print(f"Rows by term: {rows_by_term}", file=sys.stderr)
                            return 0
                    if args.max_articles and articles_scanned >= args.max_articles:
                        print(
                            f"Stopped after scanning {articles_scanned} articles",
                            file=sys.stderr,
                        )
                        print(f"Wrote {rows_written} rows", file=sys.stderr)
                        print(f"Rows by term: {rows_by_term}", file=sys.stderr)
                        return 0
                    if (
                        args.max_articles_per_year
                        and articles_scanned_by_year[year] >= args.max_articles_per_year
                    ):
                        print(
                            f"Stopped {year} after scanning "
                            f"{articles_scanned_by_year[year]} articles",
                            file=sys.stderr,
                        )
                        break
                    if (
                        args.timeout_seconds
                        and time.monotonic() - started_at >= args.timeout_seconds
                    ):
                        print(
                            f"Stopped after timeout of {args.timeout_seconds} seconds",
                            file=sys.stderr,
                        )
                        print(f"Wrote {rows_written} rows", file=sys.stderr)
                        print(f"Rows by term: {rows_by_term}", file=sys.stderr)
                        return 0
                    if args.max_rows_per_term and all(
                        count >= args.max_rows_per_term
                        for count in rows_by_term.values()
                    ):
                        break
                    if args.max_rows_per_year_term and all(
                        count >= args.max_rows_per_year_term
                        for count in rows_by_year_term[year].values()
                    ):
                        break
            finally:
                fileobj.close()
                if archive_path and (not args.keep_archives):
                    if not args.cache_dir or archive_path.parent == Path(args.cache_dir):
                        try:
                            archive_path.unlink()
                        except FileNotFoundError:
                            pass
            print(f"Finished {year}; cumulative rows: {rows_written}", file=sys.stderr)
    print(f"Wrote {rows_written} rows to {out_path}", file=sys.stderr)
    print(f"Rows by term: {rows_by_term}", file=sys.stderr)
    print(f"Rows by year and term: {rows_by_year_term}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
