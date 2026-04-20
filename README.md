# Google Drive Permission Sweeper

A Python script that walks every file and folder you own in Google Drive, compares each share against a whitelist you provide, and revokes access for anyone — or any "anyone with the link" / domain-wide share — that isn't on it.

- **Default**: actually deletes permissions.
- **`--dry-run`**: prints/logs what it *would* do, changes nothing.
- Every run produces a timestamped `.log` and `.csv` audit trail.

---

## 1. Prerequisites

- Python 3.9+
- A Google account (the one whose Drive you want to sweep)
- Terminal access

---

## 2. One-time Google Cloud setup

You need a `credentials.json` file that lets the script talk to the Drive API on your behalf. This is a one-time setup per Google account.

### 2.1 Create a Google Cloud project

1. Go to <https://console.cloud.google.com/>.
2. Click the project dropdown in the top bar → **New Project**.
3. Name it something like `drive-permission-sweeper` and click **Create**.
4. Make sure the new project is selected in the project dropdown.

### 2.2 Enable the Google Drive API

1. Go to <https://console.cloud.google.com/apis/library/drive.googleapis.com>.
2. Confirm your project is selected.
3. Click **Enable**.

### 2.3 Configure the OAuth consent screen

1. Go to **APIs & Services → OAuth consent screen** (<https://console.cloud.google.com/apis/credentials/consent>).
2. Pick **External** and click **Create**.
3. Fill in the required fields:
   - **App name**: `Drive Permission Sweeper`
   - **User support email**: your own email
   - **Developer contact email**: your own email
4. Click **Save and Continue**.
5. **Scopes**: you can skip — the script declares the scope at runtime. Click **Save and Continue**.
6. **Test users**: click **Add Users** and add the Google account whose Drive you will sweep. Click **Save and Continue**.
7. Click **Back to Dashboard**. Your app can stay in **Testing** mode — you do not need to publish it.

> The app will show an "unverified" warning during login. That's expected for a personal tool in Testing mode. You'll click through it once.

### 2.4 Create OAuth 2.0 credentials

1. Go to **APIs & Services → Credentials** (<https://console.cloud.google.com/apis/credentials>).
2. Click **Create Credentials → OAuth client ID**.
3. **Application type**: `Desktop app`.
4. **Name**: `drive-sweeper-cli` (or whatever you like).
5. Click **Create**.
6. In the popup, click **Download JSON**. Save the file as `credentials.json` in the same directory as the script (or anywhere — you'll pass the path with `-c`).

> Keep `credentials.json` private. Do not commit it to git.

---

## 3. Install Python dependencies

From the project directory:

```bash
pip install google-api-python-client google-auth-httplib2 google-auth-oauthlib
```

(A virtualenv is recommended but not required.)

---

## 4. Build your whitelist

Create a plain text file — e.g. `whitelist.txt` — with **one email address per line**. Blank lines and lines starting with `#` are ignored. Matching is case-insensitive.

```text
# people who are allowed to keep access
my.wife@gmail.com
my.second.account@gmail.com
trusted.colleague@example.com
```

See `whitelist.example.txt` for a template.

Anything NOT on this list gets revoked, including:
- individual users and groups not listed
- `anyone with the link` shares
- domain-wide shares

You (the file owner) are always skipped — you can't lose access to your own files.

---

## 5. First run — authorize the script

The very first time you run it, a browser window opens and asks you to sign in with the Google account whose Drive you want to sweep.

**Do your first run in dry-run mode** so you can review what will be revoked:

```bash
python drive_permission_sweeper.py \
    --credentials ./credentials.json \
    --whitelist ./whitelist.txt \
    --dry-run
```

What happens:
1. Browser opens → sign in with the account you added as a test user.
2. You'll see a warning that the app is unverified → click **Advanced → Go to Drive Permission Sweeper (unsafe)** → **Continue**.
3. Grant the requested Drive permission.
4. The browser tab says "The authentication flow has completed."
5. The script writes `token.json` next to your credentials so you don't have to log in again.
6. The sweep runs and produces `sweep_<timestamp>.log` and `sweep_<timestamp>.csv`.

> `token.json` is as sensitive as your password for this scope — keep it private.

Open the CSV in a spreadsheet and confirm that the `DRY_RUN` rows match your intent.

---

## 6. Execute the sweep

When you're satisfied with the dry-run output, re-run **without** `--dry-run`:

```bash
python drive_permission_sweeper.py \
    --credentials ./credentials.json \
    --whitelist ./whitelist.txt
```

The script will actually call `permissions.delete` for every flagged share and log each action as `EXECUTED` in the CSV.

---

## 7. CLI reference

```
python drive_permission_sweeper.py --help
```

| Flag | Default | Description |
|---|---|---|
| `-c`, `--credentials` | `credentials.json` | Path to the OAuth 2.0 Desktop App credentials JSON. |
| `-w`, `--whitelist` | *(required)* | Path to the whitelist text file, one email per line. |
| `-t`, `--token` | `token.json` | Where to cache the OAuth token between runs. |
| `-o`, `--output-dir` | `.` | Directory for the run log and CSV audit file. |
| `--dry-run` | off | Preview only — do not delete any permissions. |
| `-v`, `--verbose` | off | Debug-level logging. |

---

## 8. Output files

Each run creates two files in `--output-dir`:

- `sweep_<timestamp>.log` — human-readable log, same content as stdout.
- `sweep_<timestamp>.csv` — audit trail with one row per permission action.

CSV columns:

| column | meaning |
|---|---|
| `run` | run timestamp |
| `action` | `DRY_RUN`, `EXECUTED`, `SKIPPED_INHERITED`, or `ERROR` |
| `file_id` | Drive file ID |
| `file_name` | file/folder name |
| `link` | `webViewLink` — click to open in Drive |
| `target` | email, `domain:...`, or `anyone-with-link` |
| `role` | `reader`, `commenter`, `writer` |
| `error` | HTTP status or error message if applicable |

---

## 9. Troubleshooting

**"access_denied" / "This app is blocked"** — the Google account you're signing in with isn't on the test-users list. Go back to *OAuth consent screen → Test users* and add it.

**`ModuleNotFoundError: No module named 'google_auth_oauthlib'`** — run the `pip install` from step 3.

**`Credentials file not found`** — pass the correct path with `-c`, or place `credentials.json` in the working directory.

**Rate-limit / 403 errors** — the script already retries with exponential backoff. If you still hit limits on a very large drive, rerun — files already cleaned up will simply show zero revocations on the next pass.

**"Inherited" permissions can't be deleted on child files** — these are logged as `SKIPPED_INHERITED`. They get stripped when the script processes the parent folder, which it will, because the folder is also owned by you.

**I want to revoke the token** — delete `token.json` locally, and/or visit <https://myaccount.google.com/permissions> and remove the app.

---

## 10. Safety checklist

- [ ] Ran with `--dry-run` first and reviewed the CSV.
- [ ] Whitelist includes every account / collaborator you actually want to keep.
- [ ] `credentials.json` and `token.json` are not checked into source control.
- [ ] Kept the CSV audit file somewhere safe in case you need to restore access to anyone later.
