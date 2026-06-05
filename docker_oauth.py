"""One-shot OAuth bootstrap, designed to run inside the Docker container.

Why this exists separately from drive_permission_sweeper.py:
the sweeper uses InstalledAppFlow.run_local_server(port=0), which picks a
random port — that does not survive a fixed Docker port mapping. This
helper binds to a deterministic port (default 8080) so the wizard can
publish exactly that port from the container to the host, and the host
browser's redirect to http://localhost:8080/ lands inside the container.

The redirect URI advertised to Google stays http://localhost:<port>/
(which Google accepts for Desktop App clients on any port), while the
actual HTTP server is bound to 0.0.0.0 so traffic forwarded by Docker
is accepted.

Usage:
    python docker_oauth.py <credentials.json> <token.json>
"""

from __future__ import annotations

import json
import os
import sys

from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow

SCOPES = ["https://www.googleapis.com/auth/drive"]
PORT = int(os.environ.get("OAUTH_PORT", "8080"))


def _load_existing(token_file: str) -> Credentials | None:
    if not os.path.exists(token_file) or os.path.getsize(token_file) == 0:
        return None
    try:
        return Credentials.from_authorized_user_file(token_file, SCOPES)
    except (ValueError, json.JSONDecodeError):
        return None


def main(creds_file: str, token_file: str) -> int:
    creds = _load_existing(token_file)

    if creds and creds.valid:
        print(f"Existing token at {token_file} is already valid. Nothing to do.")
        return 0

    if creds and creds.expired and creds.refresh_token:
        print("Refreshing expired token (no browser needed)...")
        creds.refresh(Request())
        with open(token_file, "w") as fh:
            fh.write(creds.to_json())
        print(f"Token refreshed and saved to {token_file}.")
        return 0

    if not os.path.isfile(creds_file):
        print(f"ERROR: credentials file not found: {creds_file}", file=sys.stderr)
        return 2

    print(f"Starting OAuth callback server on port {PORT} (inside container).")
    print(f"Docker should be mapping this to host port {PORT}.")
    print()
    print("Copy the URL printed below into a browser on YOUR HOST machine,")
    print("complete the sign-in, and the page will return here automatically.")
    print()

    flow = InstalledAppFlow.from_client_secrets_file(creds_file, SCOPES)
    creds = flow.run_local_server(
        host="localhost",
        bind_addr="0.0.0.0",
        port=PORT,
        open_browser=False,
        success_message=(
            "Authentication complete. You can close this browser tab "
            "and return to the setup wizard."
        ),
    )

    with open(token_file, "w") as fh:
        fh.write(creds.to_json())
    print()
    print(f"Token saved to {token_file}.")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <credentials.json> <token.json>", file=sys.stderr)
        sys.exit(1)
    sys.exit(main(sys.argv[1], sys.argv[2]))
