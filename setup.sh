#!/usr/bin/env bash
# Interactive setup wizard for the Google Drive Permission Sweeper.
#
# Walks you through:
#   0. Prerequisite check (docker)
#   1. Google Cloud Console — project, API, consent screen, OAuth client
#   2. Importing the downloaded credentials.json
#   3. Building the whitelist of allowed emails
#   4. Building the Docker image
#   5. One-time OAuth authorization (browser dance with port forwarding)
#   6. Dry run + audit-CSV review
#   7. Real execution (with explicit typed confirmation)

set -euo pipefail

# ---------------------------------------------------------------------------
# Pretty output
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
  BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=; GREEN=; YELLOW=; BLUE=; CYAN=; BOLD=; RESET=
fi

heading() {
  echo
  echo "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════════════${RESET}"
  echo "${BOLD}${BLUE}  $1${RESET}"
  echo "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════════════${RESET}"
  echo
}
substep() { echo; echo "${BOLD}${CYAN}▶ $1${RESET}"; }
info()    { echo "  $1"; }
ok()      { echo "${GREEN}✓${RESET} $1"; }
warn()    { echo "${YELLOW}⚠${RESET} $1"; }
err()     { echo "${RED}✗${RESET} $1" >&2; }
fatal()   { err "$1"; exit 1; }
pause()   { read -r -p "${BOLD}Press [Enter] when done...${RESET} " _; }

confirm() {
  # confirm "Prompt" [yes|no]   — returns 0 if user confirms
  local prompt=$1 default=${2:-no} response
  if [ "$default" = "yes" ]; then
    read -r -p "$prompt ${BOLD}[Y/n]${RESET} " response
    response=${response:-y}
  else
    read -r -p "$prompt ${BOLD}[y/N]${RESET} " response
    response=${response:-n}
  fi
  [[ "$response" =~ ^[Yy] ]]
}

# ---------------------------------------------------------------------------
# Paths & constants
# ---------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

IMAGE_NAME="gdrive-sweeper"
CREDS_PATH="$HERE/credentials.json"
TOKEN_PATH="$HERE/token.json"
WHITELIST_PATH="$HERE/whitelist.txt"
OAUTH_PORT="${OAUTH_PORT:-8080}"

# On Linux, run the container as the host user so output files aren't owned
# by root. Docker Desktop (macOS/Windows) maps ownership automatically.
USER_FLAG=()
if [ "$(uname -s)" = "Linux" ]; then
  USER_FLAG=(--user "$(id -u):$(id -g)")
fi

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
clear || true
cat <<BANNER
${BOLD}${BLUE}╔═══════════════════════════════════════════════════════════════════════╗
║         Google Drive Permission Sweeper — Setup Wizard                ║
║                                                                       ║
║  This wizard will:                                                    ║
║    1. Walk you through Google Cloud Console (manual, step-by-step)    ║
║    2. Help you build a whitelist of allowed email addresses           ║
║    3. Build a Docker image with the sweeper inside                    ║
║    4. Run the OAuth flow once to authorize the script                 ║
║    5. Run a dry-run so you can review what would change               ║
║    6. (Optionally) execute the real sweep                             ║
╚═══════════════════════════════════════════════════════════════════════╝${RESET}
BANNER
echo
confirm "Ready to start?" yes || { info "Aborted."; exit 0; }

# ---------------------------------------------------------------------------
# Phase 0  —  Prerequisites
# ---------------------------------------------------------------------------
heading "Phase 0  Checking prerequisites"

if ! command -v docker >/dev/null 2>&1; then
  fatal "Docker is not installed or not on PATH. Install it first: https://docs.docker.com/get-docker/"
fi
ok "Docker found: $(docker --version)"

if ! docker info >/dev/null 2>&1; then
  fatal "Docker daemon is not running. Start Docker and re-run this script."
fi
ok "Docker daemon is running."

if command -v lsof >/dev/null 2>&1 && lsof -iTCP:"$OAUTH_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  warn "Host port $OAUTH_PORT is already in use."
  warn "Either free it, or rerun with: OAUTH_PORT=8181 ./setup.sh"
  confirm "Continue anyway?" no || exit 1
fi

# ---------------------------------------------------------------------------
# Phase 1  —  Google Cloud Console (manual, guided)
# ---------------------------------------------------------------------------
heading "Phase 1  Create OAuth credentials in Google Cloud Console"

cat <<EOF
You need to register a small app in Google Cloud Console so the script can
talk to your Drive on your behalf. This is a one-time setup per Google
account and is entirely free.

At the end of this phase you will have downloaded a file called
${BOLD}credentials.json${RESET} (Google actually names it
client_secret_<long-random-string>.apps.googleusercontent.com.json — same thing,
we'll rename it for you in Phase 2).

If you already have credentials.json from a previous setup, you can skip
the walkthrough — we'll ask for its path next.

${YELLOW}Heads up:${RESET} Google reorganized this UI in 2024. Phase 1.3 below covers
the ${BOLD}new${RESET} "Google Auth Platform" flow that you will most likely see today.
If your screen looks different and shows an "OAuth consent screen" page with
"User Type" radio buttons instead, follow the ${BOLD}LEGACY${RESET} notes inside Step 1.3.
EOF
echo
if confirm "Skip the Google Cloud Console walkthrough?" no; then
  info "Skipping walkthrough."
else
  # -------------------------------------------------------------------------
  substep "Step 1.1  Create a Google Cloud project"
  # -------------------------------------------------------------------------
  info "1. In your web browser, open this exact URL:"
  info "     ${CYAN}https://console.cloud.google.com/projectcreate${RESET}"
  info "2. If asked to sign in, sign in with the same Google account whose Drive"
  info "   you want to clean up (so you only need one account for everything)."
  info "3. If you see a 'Welcome / Country / Terms of Service' screen, pick your"
  info "   country, tick the ${BOLD}I agree${RESET} checkbox, then click ${BOLD}Agree and continue${RESET}."
  info "4. On the ${BOLD}New Project${RESET} page, fill in:"
  info "     • ${BOLD}Project name${RESET}  →  type exactly: ${BOLD}drive-permission-sweeper${RESET}"
  info "     • ${BOLD}Project ID${RESET}    →  leave whatever Google auto-generates"
  info "     • ${BOLD}Location${RESET}      →  leave as ${BOLD}No organization${RESET} (the default)"
  info "5. Click the blue ${BOLD}CREATE${RESET} button (bottom of the form)."
  info "6. Wait ~10-30 seconds. A notification will appear in the top-right bell"
  info "   icon saying ${BOLD}Create Project: drive-permission-sweeper${RESET}."
  info "7. Click that notification (or the project name) to switch into the new"
  info "   project. Confirm the project picker at the very top of the page now"
  info "   says: ${BOLD}drive-permission-sweeper${RESET}."
  info ""
  info "${YELLOW}If you don't see it selected:${RESET} click the project dropdown at the top"
  info "of the page (next to the 'Google Cloud' logo) and pick"
  info "${BOLD}drive-permission-sweeper${RESET} from the list."
  pause

  # -------------------------------------------------------------------------
  substep "Step 1.2  Enable the Google Drive API"
  # -------------------------------------------------------------------------
  info "1. Open this exact URL in the same browser:"
  info "     ${CYAN}https://console.cloud.google.com/apis/library/drive.googleapis.com${RESET}"
  info "2. ${BOLD}CHECK THE TOP OF THE PAGE${RESET}: the project dropdown must say"
  info "   ${BOLD}drive-permission-sweeper${RESET}. If it says anything else, click it and"
  info "   select drive-permission-sweeper from the list."
  info "3. You should see a card titled ${BOLD}Google Drive API${RESET} with a blue ${BOLD}ENABLE${RESET}"
  info "   button. Click ${BOLD}ENABLE${RESET}."
  info "4. Wait ~15 seconds. The page will reload and now show:"
  info "     • A green check next to ${BOLD}API enabled${RESET}, or"
  info "     • A new page titled ${BOLD}Google Drive API${RESET} with tabs"
  info "       (Overview / Metrics / Quotas / Credentials)."
  info "   Either of those means it worked."
  pause

  # -------------------------------------------------------------------------
  substep "Step 1.3  Configure the consent screen (Google Auth Platform)"
  # -------------------------------------------------------------------------
  info "1. Open this exact URL:"
  info "     ${CYAN}https://console.cloud.google.com/auth/overview${RESET}"
  info "2. Confirm the project picker at the top still says"
  info "   ${BOLD}drive-permission-sweeper${RESET}."
  info ""
  info "${BOLD}You will see one of two possible screens. Find yours below:${RESET}"
  echo
  info "${BOLD}${GREEN}── SCREEN A (most common in 2025+): \"Google Auth Platform / Get started\" ──${RESET}"
  info "If you see a big page titled ${BOLD}Google Auth Platform${RESET} with a blue ${BOLD}GET STARTED${RESET}"
  info "button in the middle:"
  info ""
  info "  a. Click the blue ${BOLD}GET STARTED${RESET} button."
  info "  b. A multi-step form appears. Fill it like this:"
  info ""
  info "     ${BOLD}Step 1 of 4 — App Information${RESET}"
  info "       • ${BOLD}App name${RESET}              →  ${BOLD}Drive Permission Sweeper${RESET}"
  info "       • ${BOLD}User support email${RESET}    →  pick your own email from the dropdown"
  info "       • Click ${BOLD}NEXT${RESET}."
  info ""
  info "     ${BOLD}Step 2 of 4 — Audience${RESET}"
  info "       • Select the radio button ${BOLD}External${RESET}"
  info "         (NOT 'Internal' — that only works for Google Workspace org accounts)."
  info "       • Click ${BOLD}NEXT${RESET}."
  info ""
  info "     ${BOLD}Step 3 of 4 — Contact Information${RESET}"
  info "       • ${BOLD}Email addresses${RESET}        →  type your own email address"
  info "         and press Enter so it shows as a chip/tag."
  info "       • Click ${BOLD}NEXT${RESET}."
  info ""
  info "     ${BOLD}Step 4 of 4 — Finish${RESET}"
  info "       • Tick the checkbox ${BOLD}I agree to the Google API Services: User Data Policy${RESET}."
  info "       • Click ${BOLD}CONTINUE${RESET}, then click ${BOLD}CREATE${RESET}."
  info ""
  info "  c. You're now on the ${BOLD}Google Auth Platform${RESET} dashboard. Look for the"
  info "     left-hand menu and click ${BOLD}Audience${RESET}."
  info "  d. Scroll to the ${BOLD}Test users${RESET} section."
  info "     ${YELLOW}This step is critical — without this you'll get an 'access blocked' error.${RESET}"
  info "       • Click ${BOLD}+ ADD USERS${RESET}."
  info "       • In the popup, type the email address of the Google account whose"
  info "         Drive you want to sweep (the one you used to log in)."
  info "       • Press Enter so it shows as a chip."
  info "       • Click ${BOLD}SAVE${RESET}."
  info "  e. ${BOLD}LEAVE THE APP IN 'Testing' MODE.${RESET} Do NOT click 'Publish app'."
  info "     The ${BOLD}Publishing status${RESET} should say ${BOLD}Testing${RESET}."
  echo
  info "${BOLD}${GREEN}── SCREEN B (older / legacy UI): \"OAuth consent screen\" with User Type ──${RESET}"
  info "If you see a page titled ${BOLD}OAuth consent screen${RESET} asking you to pick a"
  info "${BOLD}User Type${RESET} with two radio buttons (Internal / External):"
  info ""
  info "  a. Select ${BOLD}External${RESET}, then click ${BOLD}CREATE${RESET}."
  info "  b. ${BOLD}Page 1 — App information${RESET}:"
  info "     • ${BOLD}App name${RESET}            →  ${BOLD}Drive Permission Sweeper${RESET}"
  info "     • ${BOLD}User support email${RESET}  →  pick your own email"
  info "     • Scroll to the bottom — ${BOLD}Developer contact information${RESET}:"
  info "       enter your own email address."
  info "     • Click ${BOLD}SAVE AND CONTINUE${RESET}."
  info "  c. ${BOLD}Page 2 — Scopes${RESET}: don't change anything."
  info "     • Click ${BOLD}SAVE AND CONTINUE${RESET}."
  info "  d. ${BOLD}Page 3 — Test users${RESET}:"
  info "     • Click ${BOLD}+ ADD USERS${RESET}."
  info "     • Type the email of the Google account whose Drive you want to sweep,"
  info "       press Enter, then click ${BOLD}ADD${RESET}."
  info "     • Click ${BOLD}SAVE AND CONTINUE${RESET}."
  info "  e. ${BOLD}Page 4 — Summary${RESET}: scroll down and click ${BOLD}BACK TO DASHBOARD${RESET}."
  info "  f. ${BOLD}LEAVE THE APP IN 'Testing'.${RESET} Do NOT click 'Publish app'."
  pause

  # -------------------------------------------------------------------------
  substep "Step 1.4  Create the OAuth client ID and download credentials.json"
  # -------------------------------------------------------------------------
  info "1. Open this exact URL:"
  info "     ${CYAN}https://console.cloud.google.com/auth/clients${RESET}"
  info ""
  info "   (If that page 404s for you, use the older URL instead:"
  info "     ${CYAN}https://console.cloud.google.com/apis/credentials${RESET})"
  info ""
  info "2. Confirm the project picker at the top says ${BOLD}drive-permission-sweeper${RESET}."
  info "3. Click the blue ${BOLD}+ CREATE CLIENT${RESET} button at the top of the page."
  info "   (On the legacy URL the button is labelled ${BOLD}+ CREATE CREDENTIALS${RESET} →"
  info "    pick ${BOLD}OAuth client ID${RESET} from the dropdown.)"
  info "4. Fill the form:"
  info "     • ${BOLD}Application type${RESET}  →  open the dropdown, pick ${BOLD}Desktop app${RESET}"
  info "       ${YELLOW}(NOT 'Web application' — Desktop is required for this script.)${RESET}"
  info "     • ${BOLD}Name${RESET}              →  type ${BOLD}drive-sweeper-cli${RESET}"
  info "5. Click the blue ${BOLD}CREATE${RESET} button at the bottom."
  info "6. A popup titled ${BOLD}OAuth client created${RESET} appears showing a Client ID"
  info "   and Client secret."
  info ""
  info "   ${BOLD}LOOK FOR THE 'DOWNLOAD JSON' BUTTON.${RESET}"
  info "     • In the new UI: click ${BOLD}DOWNLOAD JSON${RESET} in the popup."
  info "     • If you accidentally closed the popup: on the Clients list page,"
  info "       find your ${BOLD}drive-sweeper-cli${RESET} row, click the download icon"
  info "       (downward arrow ⬇) on the right side of the row."
  info ""
  info "7. Your browser saves a file named something like:"
  info "     ${BOLD}client_secret_123456789-abc...apps.googleusercontent.com.json${RESET}"
  info "   It usually lands in your ${BOLD}~/Downloads${RESET} folder."
  info "   ${BOLD}Remember (or copy) the full path${RESET} — Phase 2 will ask for it."
  pause
fi

# ---------------------------------------------------------------------------
# Phase 2  —  Import credentials.json
# ---------------------------------------------------------------------------
heading "Phase 2  Provide credentials.json"

while true; do
  if [ -f "$CREDS_PATH" ]; then
    info "Found existing credentials at: ${BOLD}$CREDS_PATH${RESET}"
    if confirm "Use this file?" yes; then
      ok "Using existing credentials.json"
      break
    fi
  fi

  read -r -p "Path to the credentials JSON you just downloaded: " CRED_INPUT
  CRED_INPUT="${CRED_INPUT/#\~/$HOME}"
  if [ ! -f "$CRED_INPUT" ]; then
    err "File not found: $CRED_INPUT"
    continue
  fi
  if ! grep -q "client_id" "$CRED_INPUT" 2>/dev/null; then
    warn "That file does not look like a Google OAuth credentials JSON (no 'client_id')."
    confirm "Use it anyway?" no || continue
  fi
  cp "$CRED_INPUT" "$CREDS_PATH"
  chmod 600 "$CREDS_PATH"
  ok "Saved credentials to: $CREDS_PATH"
  break
done

# ---------------------------------------------------------------------------
# Phase 3  —  Whitelist
# ---------------------------------------------------------------------------
heading "Phase 3  Build whitelist of allowed emails"

cat <<EOF
The whitelist is a plain text file: one email per line. Anyone NOT on it
will have their access ${BOLD}REVOKED${RESET}, including 'anyone with the link' shares
and domain-wide shares. You (the owner) are always skipped — you cannot
lose access to your own files.
EOF

build_whitelist=1
if [ -f "$WHITELIST_PATH" ]; then
  echo
  echo "Existing whitelist at: ${BOLD}$WHITELIST_PATH${RESET}"
  echo "${BOLD}Current contents:${RESET}"
  echo "────────────────────────────────────────"
  cat "$WHITELIST_PATH"
  echo "────────────────────────────────────────"
  if confirm "Keep this whitelist as-is?" yes; then
    build_whitelist=0
  fi
fi

if [ "$build_whitelist" -eq 1 ]; then
  echo
  echo "How do you want to provide the whitelist?"
  echo "  ${BOLD}1${RESET}) Enter emails interactively now"
  echo "  ${BOLD}2${RESET}) Open it in an editor (\$EDITOR or nano)"
  echo "  ${BOLD}3${RESET}) Point to an existing whitelist file on disk"
  read -r -p "Choose [1/2/3]: " choice

  case "$choice" in
    1)
      cat > "$WHITELIST_PATH" <<TEMPLATE
# Whitelist for Drive Permission Sweeper.
# One email per line. Blank lines and lines starting with '#' are ignored.
# Anyone NOT on this list will lose access when the sweep runs.
TEMPLATE
      echo
      echo "Enter email addresses one at a time. Blank line (or ${BOLD}done${RESET}) to finish."
      while true; do
        read -r -p "  email > " email || break
        email="${email// /}"
        if [ -z "$email" ] || [ "$email" = "done" ]; then
          break
        fi
        if [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
          echo "$email" >> "$WHITELIST_PATH"
          ok "Added: $email"
        else
          warn "Doesn't look like an email — skipped: $email"
        fi
      done
      ;;
    2)
      if [ ! -f "$WHITELIST_PATH" ]; then
        cat > "$WHITELIST_PATH" <<TEMPLATE
# Whitelist for Drive Permission Sweeper.
# One email per line. Blank lines and lines starting with '#' are ignored.
# Anyone NOT on this list will lose access when the sweep runs.

# example@gmail.com
TEMPLATE
      fi
      "${EDITOR:-nano}" "$WHITELIST_PATH"
      ;;
    3)
      read -r -p "Path to your whitelist file: " WL_INPUT
      WL_INPUT="${WL_INPUT/#\~/$HOME}"
      [ -f "$WL_INPUT" ] || fatal "File not found: $WL_INPUT"
      cp "$WL_INPUT" "$WHITELIST_PATH"
      ;;
    *)
      fatal "Invalid choice."
      ;;
  esac

  if ! grep -vE '^\s*(#|$)' "$WHITELIST_PATH" >/dev/null 2>&1; then
    fatal "Whitelist has no entries. Aborting — an empty whitelist would revoke all sharing."
  fi
  ok "Whitelist saved to: $WHITELIST_PATH"
  echo "Whitelisted emails:"
  grep -vE '^\s*(#|$)' "$WHITELIST_PATH" | sed 's/^/    • /'
fi

# ---------------------------------------------------------------------------
# Phase 4  —  Build Docker image
# ---------------------------------------------------------------------------
heading "Phase 4  Build the Docker image"

rebuild=1
if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
  if ! confirm "Docker image '$IMAGE_NAME' already exists. Rebuild?" no; then
    rebuild=0
    ok "Reusing existing image '$IMAGE_NAME'."
  fi
fi
if [ "$rebuild" -eq 1 ]; then
  docker build -t "$IMAGE_NAME" "$HERE"
  ok "Built image '$IMAGE_NAME'."
fi

# ---------------------------------------------------------------------------
# Phase 5  —  OAuth authorization
# ---------------------------------------------------------------------------
heading "Phase 5  Authorize the application (one-time browser sign-in)"

run_oauth=1
if [ -s "$TOKEN_PATH" ]; then
  if confirm "Existing token.json found. Reuse it?" yes; then
    run_oauth=0
    ok "Reusing existing token."
  fi
fi

if [ "$run_oauth" -eq 1 ]; then
  cat <<EOF
The container will start a small web server on port ${BOLD}$OAUTH_PORT${RESET} and print a
URL. You must:

  1. Copy the URL it prints.
  2. Open it in a browser on this machine.
  3. Sign in with the Google account you added as a test user.
  4. Expect an "unverified app" warning. Click:
        ${BOLD}Advanced  →  Go to Drive Permission Sweeper (unsafe)  →  Continue${RESET}
  5. Grant the Drive permission.
  6. The browser will say "Authentication complete." Return here.

EOF
  pause

  # Touch token.json so the bind mount maps a file (not a directory).
  : > "$TOKEN_PATH"
  chmod 600 "$TOKEN_PATH"

  docker run --rm -it \
    "${USER_FLAG[@]}" \
    -p "$OAUTH_PORT:$OAUTH_PORT" \
    -e "OAUTH_PORT=$OAUTH_PORT" \
    -v "$CREDS_PATH:/app/credentials.json:ro" \
    -v "$TOKEN_PATH:/app/token.json" \
    "$IMAGE_NAME" \
    python docker_oauth.py /app/credentials.json /app/token.json

  if [ ! -s "$TOKEN_PATH" ]; then
    fatal "Token was not produced. OAuth flow failed — re-run $0."
  fi
  ok "Authorization complete. Token cached at: $TOKEN_PATH"
fi

# ---------------------------------------------------------------------------
# Phase 6  —  Dry run
# ---------------------------------------------------------------------------
heading "Phase 6  Dry run (no changes will be made)"

info "Sweeping your Drive in ${BOLD}DRY-RUN${RESET} mode. This may take a while on a large drive."
echo

docker run --rm \
  "${USER_FLAG[@]}" \
  -v "$CREDS_PATH:/app/credentials.json:ro" \
  -v "$TOKEN_PATH:/app/token.json" \
  -v "$WHITELIST_PATH:/app/whitelist.txt:ro" \
  -v "$HERE:/app/output" \
  "$IMAGE_NAME" \
  python drive_permission_sweeper.py \
    --credentials /app/credentials.json \
    --token /app/token.json \
    --whitelist /app/whitelist.txt \
    --output-dir /app/output \
    --dry-run

DRY_CSV="$(ls -t "$HERE"/sweep_*.csv 2>/dev/null | head -n1 || true)"
if [ -n "${DRY_CSV:-}" ] && [ -f "$DRY_CSV" ]; then
  COUNT="$(grep -c ',DRY_RUN,' "$DRY_CSV" || true)"
  echo
  ok "Dry-run audit written to: ${BOLD}$DRY_CSV${RESET}"
  echo "  ${BOLD}$COUNT${RESET} permission(s) would be revoked."
  echo "  Open the CSV in a spreadsheet to review every row before executing."
fi

# ---------------------------------------------------------------------------
# Phase 7  —  Real execution
# ---------------------------------------------------------------------------
heading "Phase 7  Execute the sweep (irreversible)"

cat <<EOF
${YELLOW}${BOLD}⚠  This step REALLY deletes permissions on Google Drive.${RESET}
   • Have you already reviewed the dry-run CSV above?
   • The CSV from this run is your audit trail in case you need to
     re-share with anyone later.
   • There is no undo — restoring access means re-sharing manually.

EOF

if ! confirm "Execute the sweep now?" no; then
  info "Skipping execution. You can re-run this wizard at any time, or run"
  info "the sweep directly with the command shown below."
  cat <<EOF

  ${BOLD}Manual execute command (run later):${RESET}
  docker run --rm \\
      -v "$CREDS_PATH:/app/credentials.json:ro" \\
      -v "$TOKEN_PATH:/app/token.json" \\
      -v "$WHITELIST_PATH:/app/whitelist.txt:ro" \\
      -v "$HERE:/app/output" \\
      $IMAGE_NAME \\
      python drive_permission_sweeper.py \\
          --credentials /app/credentials.json \\
          --token /app/token.json \\
          --whitelist /app/whitelist.txt \\
          --output-dir /app/output

EOF
  exit 0
fi

read -r -p "${RED}${BOLD}Type EXECUTE to confirm:${RESET} " final
if [ "$final" != "EXECUTE" ]; then
  fatal "Confirmation not given — aborted."
fi

docker run --rm \
  "${USER_FLAG[@]}" \
  -v "$CREDS_PATH:/app/credentials.json:ro" \
  -v "$TOKEN_PATH:/app/token.json" \
  -v "$WHITELIST_PATH:/app/whitelist.txt:ro" \
  -v "$HERE:/app/output" \
  "$IMAGE_NAME" \
  python drive_permission_sweeper.py \
    --credentials /app/credentials.json \
    --token /app/token.json \
    --whitelist /app/whitelist.txt \
    --output-dir /app/output

heading "Done"
ok "Sweep complete. Logs and CSV audit are in: ${BOLD}$HERE${RESET}"
info "Re-run any time with: ${BOLD}./setup.sh${RESET} (subsequent runs will skip the manual steps you've already done)."
