#!/usr/bin/env python3
"""Submit, check, download, and list IPUMS USA extract files.

The targets pipeline calls this script as the external data step. It uses only
the Python standard library so it can run without creating another environment.
"""

from __future__ import annotations

import argparse
import json
import os
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


BASE_URL = "https://api.ipums.org/extracts"
COLLECTION = "usa"
VERSION = "2"
REQUEST_PATH = Path("data/ipums/metadata/ipums_usa_1850_1880_extract_request.json")
STATUS_PATH = Path("data/ipums/metadata/ipums_usa_1850_1880_extract_status.json")
RAW_DIR = Path("data/ipums/raw")
MANIFEST_PATH = Path("data/ipums/metadata/ipums_usa_1850_1880_manifest.json")


def load_renviron(path: Path = Path(".Renviron")) -> None:
    if not path.exists():
        return
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, value = line.split("=", 1)
        os.environ.setdefault(name.strip(), value.strip().strip('"').strip("'"))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Manage the IPUMS USA 1850-1880 extract.")
    parser.add_argument(
        "command",
        choices=["submit", "status", "download", "ensure", "manifest"],
        help="Action to run.",
    )
    parser.add_argument("--extract-number", help="Existing IPUMS extract number.")
    parser.add_argument(
        "--wait",
        action="store_true",
        help="For ensure/download, poll until the extract is ready.",
    )
    parser.add_argument(
        "--poll-seconds",
        type=int,
        default=60,
        help="Seconds between status checks when --wait is used.",
    )
    parser.add_argument(
        "--max-wait-seconds",
        type=int,
        default=3600,
        help="Maximum wait time when --wait is used.",
    )
    return parser.parse_args()


def endpoint(number: str | int | None = None) -> str:
    path = BASE_URL if number is None else f"{BASE_URL}/{number}"
    query = urllib.parse.urlencode({"collection": COLLECTION, "version": VERSION})
    return f"{path}?{query}"


def https_context() -> ssl.SSLContext:
    if os.environ.get("IPUMS_INSECURE_SSL") == "1":
        return ssl._create_unverified_context()
    try:
        import certifi

        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ssl.create_default_context()


def api_key() -> str:
    key = os.environ.get("IPUMS_API_KEY", "")
    if not key:
        raise SystemExit("Add your IPUMS token to .Renviron as IPUMS_API_KEY=...")
    return key


def read_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")


def request_json(url: str, method: str = "GET", payload: dict | None = None) -> dict:
    body = None
    headers = {
        "Authorization": api_key(),
        "Content-Type": "application/json",
    }
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, context=https_context()) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise SystemExit(f"IPUMS request failed: HTTP {error.code}: {detail}") from error


def submit_extract() -> dict:
    payload = read_json(REQUEST_PATH)
    status = request_json(endpoint(), method="POST", payload=payload)
    write_json(STATUS_PATH, status)
    print(f"Submitted extract {status.get('number')} with status {status.get('status')}")
    return status


def extract_number(args: argparse.Namespace) -> str:
    if args.extract_number:
        return args.extract_number
    if not STATUS_PATH.exists():
        raise SystemExit("No status file found. Run submit or ensure first.")
    status = read_json(STATUS_PATH)
    number = status.get("number")
    if number is None:
        raise SystemExit("Status file does not include an extract number.")
    return str(number)


def check_status(args: argparse.Namespace) -> dict:
    status = request_json(endpoint(extract_number(args)))
    write_json(STATUS_PATH, status)
    print(f"Extract {status.get('number')} status: {status.get('status')}")
    return status


def download_url(url: str, path: Path) -> None:
    request = urllib.request.Request(url, headers={"Authorization": api_key()})
    path.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(request, context=https_context()) as response, path.open("wb") as handle:
        handle.write(response.read())


def get_download_links(status: dict) -> dict:
    return status.get("downloadLinks") or status.get("download_links") or {}


def write_manifest() -> dict:
    files = []
    if RAW_DIR.exists():
        patterns = ("*.csv", "*.csv.gz", "*.dat.gz", "*.xml", "*.do", "*.R")
        for pattern in patterns:
            files.extend(str(path.as_posix()) for path in RAW_DIR.glob(pattern))
    manifest = {"files": sorted(set(files))}
    write_json(MANIFEST_PATH, manifest)
    print(json.dumps(manifest, indent=2))
    return manifest


def download_extract(status: dict | None = None) -> dict:
    if status is None:
        status = read_json(STATUS_PATH) if STATUS_PATH.exists() else {}
    links = get_download_links(status)
    data_link = links.get("data", {})
    data_url = data_link.get("url") if isinstance(data_link, dict) else None
    if not data_url:
        raise SystemExit("No data download link yet. Run status again after IPUMS completes the extract.")

    download_url(data_url, RAW_DIR / Path(urllib.parse.urlparse(data_url).path).name)
    for key in ("basicCodebook", "rCommandFile", "stataCommandFile", "ddiCodebook"):
        link = links.get(key, {})
        url = link.get("url") if isinstance(link, dict) else None
        if url:
            download_url(url, RAW_DIR / Path(urllib.parse.urlparse(url).path).name)
    return write_manifest()


def ensure_extract(args: argparse.Namespace) -> dict:
    if not STATUS_PATH.exists():
        status = submit_extract()
    else:
        status = check_status(args)

    started = time.monotonic()
    while status.get("status") != "published" or not get_download_links(status):
        if not args.wait:
            print("IPUMS extract files are not ready yet. Re-run with --wait or run status later.")
            return write_manifest()
        if time.monotonic() - started >= args.max_wait_seconds:
            write_manifest()
            raise SystemExit("Timed out waiting for IPUMS extract.")
        time.sleep(args.poll_seconds)
        status = check_status(args)
    return download_extract(status)


def main() -> int:
    load_renviron()
    args = parse_args()
    if args.command == "submit":
        submit_extract()
    elif args.command == "status":
        check_status(args)
    elif args.command == "download":
        status = check_status(args)
        if status.get("status") != "published" and args.wait:
            ensure_extract(args)
        else:
            download_extract(status)
    elif args.command == "ensure":
        ensure_extract(args)
    elif args.command == "manifest":
        write_manifest()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
