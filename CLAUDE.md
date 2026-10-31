# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A standalone hot-backup/restore tool for MariaDB, extracted from a larger platform's `osai` scripts. It performs weekly full + daily incremental + hourly binlog backups of a MariaDB database (via `mariadb-backup`, run in ephemeral Docker containers), optionally backs up a configurable list of local folders alongside it, and can archive/encrypt/upload everything to Google Cloud Storage. There is no build step, package manager, or test suite — this is a small set of bash scripts.

## Running commands

```
./bkp <command> [params...]
./bkp help
```

There's no test suite; validate changes with `bash -n <file>` for syntax and by exercising commands directly (e.g. `./bkp bkp-db-weekly` against a real MariaDB container). `require-vars`/`require-db-type`/`require-cloud-provider` (in `lib/common.sh`) will fail fast with a clear message if `.env` is missing required values, which is a fast way to sanity-check config wiring.

## Architecture

- **`bkp`** — entrypoint. Resolves its own real path (`get-script-dir`, symlink-safe), loads `.env` if present, seeds defaults for unset vars, then **regenerates `.env` from `.env.template` via `envsubst`** on every invocation. This means: values already in `.env` survive, new variables added to `.env.template` show up empty in `.env` for the user to fill in, and defaults seeded in `bkp` (e.g. `DBType=mariadb`, `DBPort=3306`) get baked into `.env` the first time it's created. After that, it sources `lib/common.sh` and `lib/backup.sh` and dispatches to the requested command.
- **`lib/common.sh`** — `log-line`, config guards (`require-vars`, `require-db-type`, `require-cloud-provider`) that other functions call before touching the DB/cloud, and tool checks: `bkp` warns about every missing tool in `KNOWN_TOOLS` on each run (except `status`, which lists them in its own section and degrades per section), and each command calls `require-tools` for the ones it needs, refusing to run without them.
- **`lib/backup.sh`** — all backup/restore/cron logic, organized in sections: BACKUP DATABASE, RESTORE DATABASE, FOLDERS, CLOUD OPERATIONS, CRON.
- **`.env.template`** → **`.env`** — the only configuration mechanism. `.env` is gitignored (holds `DBPassword`/`AESPassphrase`); `.env.template` is the source of truth for what variables exist.

### Backup chain model

Backups live under `${LocalBackupDir}/<timestamp>/mariadb/`, where `<timestamp>` is the UTC `date -u +%Y%m%d%H%M%S` of the **full** backup that anchors the chain:
- `full/backup.xbstream` — the weekly full backup (`bkp-db-weekly`).
- `inc_<ts>/backup.xbstream` — daily incrementals (`bkp-db-daily`), each based on the most recent prior incremental (or the full backup if none exists yet).
- `full/lsn/`, `inc_<ts>/lsn/` — a copy of each backup's checkpoint metadata (`mariadb-backup --extra-lsndir`), which is all `--incremental-basedir` needs, so a daily doesn't have to unpack its base. Backups made before this existed lack it; for those, the base stream is unpacked into `${WorkDir}` instead.
- `binlogs/` — binlogs captured hourly (`bkp-db-hourly`) since the full backup, used for point-in-time restore.
- `${LocalBackupDir}/<timestamp>/files/` — the configured `BackupFolders`, backed up by `bkp-folders` (called automatically at the end of every `bkp-db-daily` run).

`${LocalBackupDir}/.backup-state` tracks `lastFullTS`/`lastIncTS` so `bkp-db-daily`/`bkp-db-hourly` know which chain to append to when called with no explicit timestamp (as cron does).

**Failure handling**: every step checks the previous one (the backup container's exit code is `mariadb-backup`'s, not a trailing `chown`'s; a backup with an empty stream or no LSN metadata counts as failed), and `bkp-to-cloud` returns non-zero unless the upload succeeded. `gcloud storage cp` replaces an existing object only once the upload completes, so a failed upload leaves the previous cloud copy intact. Temporary files go in `${WorkDir}` (via `make-work-dir`), falling back to `/tmp` with a warning.

**Priority/locking**: weekly > daily > hourly, enforced via `flock` on `weekly.lock`/`daily.lock`/`hourly.lock` in `scriptDir`. Starting a higher-priority backup kills any lower-priority one currently running (`terminate-lower-priority`, matched via `pgrep -f` against the running script's own name). `bkp-db-daily`/`bkp-db-hourly` check `higher-priority-running` before acquiring their own lock and bail out (rather than queue) if a higher-priority run is active.

**Weekly rollover**: when `bkp-db-weekly` finds a previous full backup, it appends one final daily incremental + hourly binlog capture to that *previous* chain, uploads it to cloud (`bkp-to-cloud ... weekly`), then deletes it locally — so the old chain is only ever destroyed after a successful cloud upload confirms it. Cloud upload for a `weekly`-level archive also prunes any older `daily-backup.*` objects from GCS (dailies are only useful until the next weekly supersedes them).

### Restore

`restore-db-local <timestamp> [target-datetime]` extracts the full backup + any needed incrementals (via `mariadb-backup --prepare`), stops `${DBContainerName}`, moves the corrupted datadir aside (`${DBDataDir}-corrupted-<ts>`), copies the backup into `${DBDataDir}`, restarts the container, and — if a `target-datetime` was given — replays binlogs up to that point (`perform-restore`, point-in-time recovery). `restore-from-cloud` downloads/decrypts/extracts the nearest cloud archive at or before a given datetime, optionally replaces the local backup dir with it, and can chain into `restore-db-local`.

### Docker dependency

All `mariadb-backup`/`mariadb-binlog` operations run inside ephemeral containers using the `${DBBackupImage}` image (its major version must match the real server's), with `${DBDataDir}` bind-mounted directly — this is a genuine hot-backup pattern reading the live datadir, not a client-side dump. `${DBDockerNetwork}` is only added to `docker run` when set (needed if `${DBHost}` is only reachable via a specific Docker network; omit it if the DB is reachable directly). Restore additionally does `docker stop`/`docker start` on `${DBContainerName}` by name.

### Naming conventions (enforced, not just style preference)

- `.env` / config variables: **PascalCase** (e.g. `LocalBackupDir`, `DBHost`).
- Local/script variables: **camelCase** (e.g. `fullTS`, `incDir`).
- True initialisms (each letter stands for a separate word) are fully uppercased at the point they'd normally be capitalized: `DB`, `AES`, `GCS`, `PITR`, `FD` → `DBHost`, `AESPassphrase`, `GCSBucket`, `isPITR`, `tmpFD`. This does *not* apply to informal truncations that aren't real acronyms — `ts`, `bkp`, `inc`, `dir` stay lowercase-first-letter as ordinary words (`fullTS` but `incDir`, not `incDIR`).
- Non-configurable constants: **SCREAMING_SNAKE_CASE** (e.g. `LOCK_FD_WEEKLY`, `ALPINE_IMAGE`).
- Functions: kebab-case (e.g. `bkp-db-weekly`, `require-db-type`), matching the CLI command names where the function implements a command directly.

### Adding a new config variable

Add it to `.env.template` (quoted `Foo="${Foo}"` for strings, unquoted `Foo=${Foo}` for numbers), and if it needs a default, seed it in `bkp` via `[ -z "${Foo}" ] && Foo="default"` *before* the `set -a; export ...; set +a; envsubst ...` block — otherwise it will regenerate empty in `.env` until the user fills it in by hand.
