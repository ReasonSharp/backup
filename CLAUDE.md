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
- `full/backup.xbstream.zst` — the weekly full backup (`bkp-db-weekly`), zstd-compressed as it's streamed out of the container. Backups made before compression was added are plain `backup.xbstream`; `stream-file` finds whichever exists, and everything that reads a stream handles both.
- `inc_<ts>/backup.xbstream.zst` — daily incrementals (`bkp-db-daily`), each based on the most recent prior incremental (or the full backup if none exists yet).
- `full/lsn/`, `inc_<ts>/lsn/` — a copy of each backup's checkpoint metadata (`mariadb-backup --extra-lsndir`), which is all `--incremental-basedir` needs, so a daily doesn't have to unpack its base. Backups made before this existed lack it; for those, the base stream is unpacked into `${WorkDir}` instead.
- `binlogs/` — binlogs captured hourly (`bkp-db-hourly`) since the full backup, used for point-in-time restore. Where they come from depends on `DBBinlogSource`: `local` copies the database's own binlogs from `${DBDataDir}` (a master, or a replica with `log_bin` + `log_slave_updates`; `local-binlog-problem` checks this and the hourly fails if they're unusable), `master` fetches the master's binlogs over the network (`mariadb-binlog --read-from-remote-server --raw`, using `DBMaster*`) for a replica without its own binlog. Relay logs are never usable: the replica purges them as soon as they're applied.
- `full/master-binlog-start`, `inc_<ts>/master-binlog-start` — with `DBBinlogSource=master`, the master binlog the replica was executing when the backup started, so `bkp-db-hourly` knows where to start fetching. Those backups also run with `--slave-info`, recording the master coordinates the restore replays from.
- `${LocalBackupDir}/<timestamp>/files/` — the configured `BackupFolders`, backed up by `bkp-folders` (called automatically by every `bkp-db-daily` run, before its cloud upload).
- `${LocalBackupDir}/<timestamp>/.cloud-manifest` — fingerprints of the pieces already uploaded to cloud (see below).

**Cloud layout**: a chain is uploaded piece by piece to `gs://${GCSBucket}/${BackupInstanceName}/<timestamp>/<piece>.tar.zst.aes256`, where a piece is `mariadb/full`, each `mariadb/inc_<ts>`, each `mariadb/binlogs/<file>`, or `files` (`list-chain-pieces`). Each is `tar | zstd | openssl | gcloud storage cp -`, streamed with no local temp file, uploaded under a `.partial` name and moved into place only once the whole pipeline succeeded. `bkp-to-cloud` uploads only pieces whose fingerprint (`piece-fingerprint`: file names, sizes, mtimes) differs from `.cloud-manifest`, or whose object is missing, and is serialized by `cloud.lock`. Weekly/daily release their own backup lock before uploading, so hourly binlog backups keep running during long uploads. Older bkp versions uploaded each chain as a single `<level>-backup.<instance>.<ts>.tar.bz2.aes256` at the bucket root; `restore-from-cloud` and `status` still read those.

`${LocalBackupDir}/.backup-state` tracks `lastFullTS`/`lastIncTS` so `bkp-db-daily`/`bkp-db-hourly` know which chain to append to when called with no explicit timestamp (as cron does).

**Failure handling**: every step checks the previous one (the backup container's exit code is `mariadb-backup`'s, not a trailing `chown`'s; a backup with an empty stream or no LSN metadata counts as failed), and `bkp-to-cloud` returns non-zero unless every piece uploaded. Temporary files (point-in-time restore binlogs, unpacking an old backup without `lsn/`) go in `${WorkDir}` (via `make-work-dir`), falling back to `/tmp` with a warning.

**Priority/locking**: weekly > daily > hourly, enforced via `flock` on `weekly.lock`/`daily.lock`/`hourly.lock` in `scriptDir`. Starting a higher-priority backup kills any lower-priority one currently running (`terminate-lower-priority`, matched via `pgrep -f` against the running script's own name). `bkp-db-daily`/`bkp-db-hourly` check `higher-priority-running` before acquiring their own lock and bail out (rather than queue) if a higher-priority run is active.

**Weekly rollover**: when `bkp-db-weekly` finds a previous full backup, it appends one final daily incremental + hourly binlog capture to that *previous* chain, uploads its remaining pieces to cloud (`bkp-to-cloud <prev>`), then deletes it locally — so the old chain is only ever destroyed after every piece of it is confirmed in cloud.

### Timestamps

Every timestamp bkp produces or takes is UTC: backup/chain timestamps, log lines, target datetimes for restore, and `end_time` in the backup metadata (backup containers run with `TZ=UTC`). Anything that comes from the system or gcloud (`date`, file mtimes, gcloud's creation times via `utc-ls-lines`) is converted to UTC before use; `mariadb-binlog` runs with `TZ=UTC`, and SQL that takes a datetime sets `time_zone = '+00:00'`. Cron schedules are the exception: cron interprets them in the system timezone (`status` notes this when it isn't UTC).

### Restore

`restore-db-local <timestamp> [target-datetime]` extracts the full backup + any needed incrementals (via `mariadb-backup --prepare`), stops `${DBContainerName}`, moves the corrupted datadir aside (`${DBDataDir}-corrupted-<ts>`), copies the backup into `${DBDataDir}`, restarts the container, and replays the saved binlogs (`perform-restore`, `apply-binlogs`): up to `target-datetime` for a point-in-time restore, or all of them without one. `plan-binlog-replay` picks the start position from the backup's contents rather than the restoring machine's config — the master's coordinates (`mariadb_backup_slave_info`) if those binlogs were saved, else the server's own (`mariadb_backup_binlog_info`) — so a master can be restored from a replica's backup (`restore-from-cloud --from-instance=<replica>`). It requires every binlog from the start file on, without gaps; with a target it fails before the database is touched otherwise, without one it warns and restores to the end of the backup. `find-replay-end` scans the binlogs first so the replay stops where a transaction starts (the first one at or after the target), never inside one, and knows the exact binlog position it ends at.

The replay runs with `--disable-log-bin`, so after it the server's own binlog position (`record-restored-binlog-pos`, logged and saved as `bkp_restored_binlog_pos` in the datadir, shown by `status`) is the same on every server restored to the same point: replicas restored with the same command start replicating from the restored master with `start-replica <file> <pos>`. A replica's backup contains no replication config (`master.info` isn't backed up), so a restored server never starts replicating on its own; `start-replica` without arguments resumes where the replay of the master's binlogs ended (`bkp_binlogs_replayed` in the datadir) — right only if the master itself wasn't restored — or, if nothing was replayed, from the position in the backup. mariadb-backup doesn't back up these marker files, and the restore removes any left over before replaying. After any restore, `close-backup-chains` marks every local chain `.closed` and clears `.backup-state`: the restored datadir no longer continues from those chains' LSNs, so the next run starts a new chain with a full backup, and the weekly rollover uploads and removes closed chains without appending to them. `restore-from-cloud` downloads/decrypts/extracts the nearest cloud archive at or before a given datetime, optionally replaces the local backup dir with it, and can chain into `restore-db-local`.

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
