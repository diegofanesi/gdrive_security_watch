"""Google Drive Permission Sweeper.

Traverses all files/folders owned by the authenticated user, compares each
permission against a whitelist, and revokes any unapproved access.

Run `python drive_permission_sweeper.py --help` for CLI usage.
"""

from __future__ import annotations

import argparse
import csv
import json
import logging
import os
import random
import sys
import time
from datetime import datetime
from typing import Iterator

try:
    from google.auth.transport.requests import Request
    from google.oauth2.credentials import Credentials
    from google_auth_oauthlib.flow import InstalledAppFlow
    from googleapiclient.discovery import build
    from googleapiclient.errors import HttpError
except ImportError:
    # Deferred — let --help work even without the Google SDKs installed.
    Request = Credentials = InstalledAppFlow = build = HttpError = None  # type: ignore

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SCOPES = ["https://www.googleapis.com/auth/drive"]

PAGE_SIZE = 1000
FIELDS = (
    "nextPageToken, "
    "files(id, name, mimeType, webViewLink, owners, permissions)"
)
QUERY = "'me' in owners and trashed = false"

MAX_RETRIES = 6
BASE_BACKOFF = 1.0

# 403s are only retryable when Google says we're being throttled. Other 403s
# (cannotDeletePermission, insufficientFilePermissions, forbidden) are permanent
# and retrying them just burns ~30s of exponential backoff per failure.
RETRYABLE_403_REASONS = {
    "rateLimitExceeded",
    "userRateLimitExceeded",
    "sharingRateLimitExceeded",
    "quotaExceeded",
}


def _http_error_reason(err) -> str:
    """Extract the Drive API 'reason' string from an HttpError, or '' if absent."""
    try:
        body = json.loads(err.content.decode("utf-8") if isinstance(err.content, bytes) else err.content)
        errors = body.get("error", {}).get("errors") or []
        if errors:
            return errors[0].get("reason", "") or ""
    except (ValueError, AttributeError, KeyError):
        pass
    return ""


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="drive_permission_sweeper",
        description=(
            "Sweep your Google Drive and revoke access for anyone not on a "
            "whitelist. Deletes permissions by default — pass --dry-run to "
            "preview changes without modifying anything."
        ),
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
        epilog=(
            "Whitelist file format: one email address per line. Blank lines "
            "and lines starting with '#' are ignored. Matching is "
            "case-insensitive.\n\n"
            "Example:\n"
            "  python drive_permission_sweeper.py \\\n"
            "      --credentials ./credentials.json \\\n"
            "      --whitelist ./allowed_emails.txt\n\n"
            "To preview without making any changes, add --dry-run."
        ),
    )
    parser.add_argument(
        "-c", "--credentials",
        default="credentials.json",
        help="Path to the OAuth 2.0 Desktop App credentials JSON from Google Cloud Console.",
    )
    parser.add_argument(
        "-w", "--whitelist",
        required=True,
        help="Path to a text file with one allowed email address per line.",
    )
    parser.add_argument(
        "-t", "--token",
        default="token.json",
        help="Path to read/write the cached OAuth token.",
    )
    parser.add_argument(
        "-o", "--output-dir",
        default=".",
        help="Directory where the run log and CSV audit file are written.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview changes only — do not delete any permissions. Default is to execute.",
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Enable debug-level logging.",
    )
    return parser.parse_args(argv)


def load_whitelist(path: str) -> set[str]:
    if not os.path.isfile(path):
        raise FileNotFoundError(f"Whitelist file not found: {path}")

    emails: set[str] = set()
    with open(path, "r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            emails.add(line.lower())

    if not emails:
        raise ValueError(f"Whitelist file {path} contains no email addresses.")
    return emails


# ---------------------------------------------------------------------------
# Authentication
# ---------------------------------------------------------------------------


def authenticate(credentials_file: str, token_file: str):
    if Request is None:
        raise ImportError(
            "Google API libraries not installed. Run:\n"
            "  pip install google-api-python-client google-auth-httplib2 google-auth-oauthlib"
        )
    creds = None
    if os.path.exists(token_file):
        creds = Credentials.from_authorized_user_file(token_file, SCOPES)

    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
        else:
            if not os.path.isfile(credentials_file):
                raise FileNotFoundError(
                    f"Credentials file not found: {credentials_file}"
                )
            flow = InstalledAppFlow.from_client_secrets_file(
                credentials_file, SCOPES
            )
            creds = flow.run_local_server(port=0)
        with open(token_file, "w") as token:
            token.write(creds.to_json())

    return build("drive", "v3", credentials=creds, cache_discovery=False)


# ---------------------------------------------------------------------------
# Retry helper — exponential backoff for 403/429/5xx
# ---------------------------------------------------------------------------


def _execute_with_backoff(request):
    for attempt in range(MAX_RETRIES):
        try:
            return request.execute()
        except HttpError as err:
            status = getattr(err.resp, "status", None)
            if status == 403:
                # Only retry rate-limit-style 403s; cannotDeletePermission and
                # friends are permanent and re-trying them wastes a minute per file.
                retryable = _http_error_reason(err) in RETRYABLE_403_REASONS
            else:
                retryable = status in (429, 500, 502, 503, 504)
            if not retryable or attempt == MAX_RETRIES - 1:
                raise
            sleep_for = BASE_BACKOFF * (2**attempt) + random.uniform(0, 1)
            logging.warning(
                "API error %s — backing off %.1fs (attempt %d/%d)",
                status,
                sleep_for,
                attempt + 1,
                MAX_RETRIES,
            )
            time.sleep(sleep_for)


# ---------------------------------------------------------------------------
# Traversal
# ---------------------------------------------------------------------------


def get_all_owned_files(service) -> Iterator[dict]:
    page_token = None
    while True:
        request = service.files().list(
            q=QUERY,
            fields=FIELDS,
            pageSize=PAGE_SIZE,
            pageToken=page_token,
            spaces="drive",
        )
        response = _execute_with_backoff(request)
        for f in response.get("files", []):
            yield f
        page_token = response.get("nextPageToken")
        if not page_token:
            return


# ---------------------------------------------------------------------------
# Processing
# ---------------------------------------------------------------------------


def _describe_permission(perm: dict) -> str:
    ptype = perm.get("type", "?")
    if ptype in ("user", "group"):
        return perm.get("emailAddress", f"<unknown {ptype}>")
    if ptype == "domain":
        return f"domain:{perm.get('domain', '?')}"
    if ptype == "anyone":
        return "anyone-with-link"
    return ptype


def _should_revoke(perm: dict, whitelist: set[str]) -> bool:
    if perm.get("role") == "owner":
        return False
    ptype = perm.get("type")
    if ptype in ("anyone", "domain"):
        return True
    if ptype in ("user", "group"):
        email = (perm.get("emailAddress") or "").lower()
        if not email:
            return False
        return email not in whitelist
    return False


def process_file(
    service,
    file: dict,
    whitelist: set[str],
    dry_run: bool,
    run_stamp: str,
    csv_writer,
) -> tuple[int, int, int]:
    """Return (kept, revoked, errors) counts for this file."""
    kept = revoked = errors = 0
    name = file.get("name", "<unnamed>")
    file_id = file.get("id")
    link = file.get("webViewLink", "")

    for perm in file.get("permissions", []) or []:
        if not _should_revoke(perm, whitelist):
            kept += 1
            continue

        target = _describe_permission(perm)
        perm_id = perm.get("id")

        if dry_run:
            logging.info("[DRY RUN] Would remove %s from %s (%s)", target, name, link)
            csv_writer.writerow(
                [run_stamp, "DRY_RUN", file_id, name, link, target, perm.get("role", ""), ""]
            )
            revoked += 1
            continue

        try:
            _execute_with_backoff(
                service.permissions().delete(
                    fileId=file_id,
                    permissionId=perm_id,
                    supportsAllDrives=True,
                )
            )
            logging.info("[EXECUTED] Removed %s from %s", target, name)
            csv_writer.writerow(
                [run_stamp, "EXECUTED", file_id, name, link, target, perm.get("role", ""), ""]
            )
            revoked += 1
        except HttpError as err:
            status = getattr(err.resp, "status", None)
            reason = _http_error_reason(err)
            if status == 404:
                # The permission was already gone — almost always because we
                # deleted the same principal from a parent folder earlier in
                # this run and Drive cascaded the removal to children.
                logging.info(
                    "Already removed: %s from %s (cascaded from parent)",
                    target, name,
                )
                csv_writer.writerow(
                    [run_stamp, "ALREADY_REMOVED", file_id, name, link, target,
                     perm.get("role", ""), ""]
                )
                revoked += 1
            elif status in (400, 403):
                # Inherited or otherwise undeletable permission (shared drive,
                # domain policy, etc.). The CSV row records the exact reason so
                # the user can see what's blocking it.
                logging.info(
                    "Skipping %s on %s — %s (HTTP %s)",
                    target, name, reason or "forbidden", status,
                )
                csv_writer.writerow(
                    [run_stamp, "SKIPPED_INHERITED", file_id, name, link, target,
                     perm.get("role", ""), f"HTTP {status} {reason}".strip()]
                )
            else:
                logging.error("Failed to remove %s from %s: %s", target, name, err)
                csv_writer.writerow(
                    [run_stamp, "ERROR", file_id, name, link, target,
                     perm.get("role", ""), str(err)]
                )
                errors += 1

    return kept, revoked, errors


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def _setup_logging(log_file: str, verbose: bool) -> None:
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        handlers=[
            logging.FileHandler(log_file),
            logging.StreamHandler(),
        ],
    )


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    dry_run = args.dry_run

    os.makedirs(args.output_dir, exist_ok=True)
    run_stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    log_file = os.path.join(args.output_dir, f"sweep_{run_stamp}.log")
    csv_file = os.path.join(args.output_dir, f"sweep_{run_stamp}.csv")

    _setup_logging(log_file, args.verbose)

    try:
        whitelist = load_whitelist(args.whitelist)
    except (FileNotFoundError, ValueError) as err:
        print(f"error: {err}", file=sys.stderr)
        return 2

    logging.info("Starting sweep (DRY_RUN=%s)", dry_run)
    logging.info("Credentials: %s", args.credentials)
    logging.info("Whitelist (%d entries): %s", len(whitelist), sorted(whitelist))

    if not dry_run:
        logging.warning(
            "EXECUTE MODE — permissions will actually be deleted."
        )

    service = authenticate(args.credentials, args.token)

    total_files = total_kept = total_revoked = total_errors = 0

    with open(csv_file, "w", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(
            ["run", "action", "file_id", "file_name", "link",
             "target", "role", "error"]
        )

        for idx, file in enumerate(get_all_owned_files(service), start=1):
            kept, revoked, errors = process_file(
                service, file, whitelist, dry_run, run_stamp, writer
            )
            total_files += 1
            total_kept += kept
            total_revoked += revoked
            total_errors += errors

            if idx % 100 == 0:
                logging.info(
                    "Progress: %d files processed, %d revocations, %d errors",
                    idx, total_revoked, total_errors,
                )

    logging.info("=" * 60)
    logging.info("Sweep complete (DRY_RUN=%s)", dry_run)
    logging.info("Files scanned:     %d", total_files)
    logging.info("Permissions kept:  %d", total_kept)
    logging.info("Permissions %s: %d",
                 "flagged" if dry_run else "revoked", total_revoked)
    logging.info("Errors:            %d", total_errors)
    logging.info("Log file: %s", log_file)
    logging.info("CSV file: %s", csv_file)
    return 0


if __name__ == "__main__":
    sys.exit(main())
