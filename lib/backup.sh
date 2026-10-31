#!/bin/bash

stateFile="${LocalBackupDir}/.backup-state"

lockWeekly="${scriptDir}/weekly.lock"
lockDaily="${scriptDir}/daily.lock"
lockHourly="${scriptDir}/hourly.lock"

LOCK_FD_WEEKLY=200
LOCK_FD_DAILY=201
LOCK_FD_HOURLY=202

ALPINE_IMAGE="alpine:3.22"
BINLOG_UTILITY_IMAGE="bash:5.2.21-alpine3.19"
DB_START_TIMEOUT_SECONDS=60
FULL_BACKUP_MAX_AGE_DAYS=8
FULL_BACKUP_MAX_AGE_SECONDS=$((FULL_BACKUP_MAX_AGE_DAYS * 86400))
BINLOG_PURGE_MAX_AGE_DAYS=14
STATUS_MAX_LINES=48
STATUS_MAX_COLUMNS=128
STATUS_CLOUD_TIMEOUT_SECONDS=5

scriptName=$(basename "${0}")

dbNetworkArgs=()
[ -n "${DBDockerNetwork}" ] && dbNetworkArgs=(--network "${DBDockerNetwork}")

# prints the path of a new temporary directory inside WorkDir (or /tmp, with a warning, if WorkDir isn't set)
make-work-dir() {
 local parentDir="${WorkDir}"
 if [ -z "${parentDir}" ]; then
  log-line wrn "WorkDir is not set in ${envFile} - using /tmp, which may be too small to hold unpacked backups" >&2
  parentDir="/tmp"
 fi
 if ! mkdir -p "${parentDir}" || ! mktemp -d -p "${parentDir}" bkp.XXXXXXXXXX; then
  log-line err "cannot create a temporary directory in ${parentDir}" >&2
  return 1
 fi
}

human-size() {
 local bytes="${1}"
 if [ "${bytes}" -lt 1024 ]; then
  echo "${bytes} B"
 else
  numfmt --to=iec-i --suffix=B --format=%.1f "${bytes}"
 fi
}
# apparent size of a file or directory, human-readable
size-of() {
 local bytes
 bytes=$(du -sb "${1}" 2>/dev/null | cut -f1)
 if [ -n "${bytes}" ]; then
  human-size "${bytes}"
 else
  echo "unknown size"
 fi
}

# logs the last lines of a failed step's captured stderr
log-tail() {
 local logFile="${1}"
 [ -s "${logFile}" ] || return 0
 local line
 tail -n 15 "${logFile}" | while IFS= read -r line; do
  log-line err "  ${line}"
 done
}

acquire-lock() {
 local lockFile="${1}"
 local fd="${2}"
 touch "${lockFile}"
 eval 'exec '${fd}'>"'${lockFile}'"'
 if ! flock -n "${fd}"; then
  log-line err "another backup process is already running (${lockFile}) - exiting"
  exit 1
 fi
 trap 'eval exec '${fd}'>&-; rm -f "'"${lockFile}"'"' EXIT
}
release-lock() {
 local lockFile="${1}"
 local fd="${2}"
 eval "exec ${fd}>&-"
 rm -f "${lockFile}"
}
higher-priority-running() {
 local lockFile="${1}"
 local tmpFD
 if ! eval 'exec '{tmpFD}'>"'${lockFile}'"' 2>/dev/null; then
  return 0
 fi
 if flock -n "${tmpFD}"; then
  eval 'exec '${tmpFD}'>&-'
  rm -f "${lockFile}"
  return 1
 else
  eval 'exec '${tmpFD}'>&-'
  return 0
 fi
}
terminate-lower-priority() {
 local myLevel="${1}"
 local pid
 for pid in $(pgrep -f "${scriptName} bkp-db-(hourly|daily|weekly)" | grep -v ${$}); do
  if grep -q "bkp-db-hourly" /proc/${pid}/cmdline 2>/dev/null && [ "${myLevel}" -gt 1 ]; then
   kill ${pid} 2>/dev/null || true
   docker run --rm -v "${LocalBackupDir}":/workdir "${ALPINE_IMAGE}" sh -c 'chown -R '$(id -u)':'$(id -g)' /workdir'
  fi
  if grep -q "bkp-db-daily" /proc/${pid}/cmdline 2>/dev/null && [ "${myLevel}" -gt 2 ]; then
   kill ${pid} 2>/dev/null || true
   docker run --rm -v "${LocalBackupDir}":/workdir "${ALPINE_IMAGE}" sh -c 'chown -R '$(id -u)':'$(id -g)' /workdir'
  fi
 done
}

load-state() {
 if [[ -f "${stateFile}" ]]; then
  source "${stateFile}"
 else
  lastFullTs=""; lastIncTs=""
 fi
}
save-state() {
 cat > "${stateFile}" <<EOF
lastFullTs="${lastFullTs}"
lastIncTs="${lastIncTs}"
EOF
 chmod 600 "${stateFile}"
}

full-backup-stale() {
 local fullTs="${1}"
 [[ -z "${fullTs}" ]] && return 0
 local fullEpoch
 fullEpoch=$(date -u -d "${fullTs:0:4}-${fullTs:4:2}-${fullTs:6:2} ${fullTs:8:2}:${fullTs:10:2}:${fullTs:12:2}" +%s 2>/dev/null) || return 0
 local nowEpoch
 nowEpoch=$(date -u +%s)
 [ $((nowEpoch - fullEpoch)) -gt "${FULL_BACKUP_MAX_AGE_SECONDS}" ]
}

extract-xbstream() {
 local streamFile="${1}"
 local targetDir="${2}"
 log-line msg "extracting ${streamFile} ($(size-of "${streamFile}")) -> ${targetDir}"
 mkdir -p "${targetDir}"
 if ! docker run --rm \
  -v "$(dirname "${streamFile}")":/source:ro \
  -v "${targetDir}":/workdir \
  "${DBBackupImage}" sh -c 'cd /workdir && mbstream -x < "/source/'"$(basename "${streamFile}")"'" \
                     && chown -R '$(id -u)':'$(id -g)' /workdir'; then
  log-line err "failed to extract ${streamFile} into ${targetDir} (out of space on that volume?)"
  return 1
 fi
}
remove-extracted() {
 [ -n "${1}" ] || return 0
 docker run --rm -v "$(dirname "${1}")":/workdir:rw "${ALPINE_IMAGE}" rm -rf /workdir/$(basename "${1}")
}
has-lsn-metadata() {
 [ -f "${1}/mariadb_backup_checkpoints" ] || [ -f "${1}/xtrabackup_checkpoints" ]
}

wait-for-db() {
 local container="${1}"
 local user="${2}"
 local pass="${3}"
 until docker exec "${container}" mariadb -u"${user}" -p"${pass}" -e "SELECT 1" >/dev/null 2>&1; do
  log-line msg "waiting for MariaDB to be ready..."
  sleep 1
 done
 log-line msg "MariaDB is ready"
}

###################################################################################################
######################################## DATABASE CONTROL #########################################
###################################################################################################

db-start() {
 require-db-type
 require-tools docker
 require-vars DBContainerName DBUser DBPassword
 log-line msg "=== STARTING DATABASE CONTAINER ==="
 if ! docker ps -a --filter "name=^/${DBContainerName}$" -q 2>/dev/null | grep -q .; then
  log-line err "no container named '${DBContainerName}' exists"
  return 1
 fi
 if docker ps --filter "name=^/${DBContainerName}$" --filter "status=running" -q 2>/dev/null | grep -q .; then
  log-line msg "container ${DBContainerName} is already running"
 elif ! docker start "${DBContainerName}" >/dev/null; then
  log-line err "container ${DBContainerName} didn't start"
  return 1
 fi
 log-line msg "waiting up to ${DB_START_TIMEOUT_SECONDS}s for ${DBContainerName} to accept connections..."
 local waited=0
 while [ "${waited}" -lt "${DB_START_TIMEOUT_SECONDS}" ]; do
  if ! docker ps --filter "name=^/${DBContainerName}$" --filter "status=running" -q 2>/dev/null | grep -q .; then
   log-line err "container ${DBContainerName} stopped unexpectedly while waiting for it to become healthy"
   return 1
  fi
  if docker exec "${DBContainerName}" mariadb -u"${DBUser}" -p"${DBPassword}" -e "SELECT 1" >/dev/null 2>&1; then
   log-line msg "=== DATABASE CONTAINER UP AND HEALTHY ==="
   return 0
  fi
  sleep 2
  waited=$((waited + 2))
 done
 log-line err "container ${DBContainerName} started but did not accept connections within ${DB_START_TIMEOUT_SECONDS}s"
 return 1
}

###################################################################################################
######################################### BACKUP DATABASE #########################################
###################################################################################################

# streams a backup into <targetDir>/backup.xbstream, and keeps a copy of its LSN metadata in <targetDir>/lsn so the
# next incremental can be based on it without unpacking the stream; an incremental is based on <incrementalBaseDir>
run-mariadb-backup() {
 local containerName="${1}"
 local targetDir="${2}"
 local incrementalBaseDir="${3}"
 local streamFile="${targetDir}/backup.xbstream"
 local backupLog="${targetDir}/mariadb-backup.log"
 local remotePassword="${DBRemotePassword:-${DBPassword}}"
 local baseMountArgs=()
 local incrementalArg=""
 if [ -n "${incrementalBaseDir}" ]; then
  baseMountArgs=(-v "${incrementalBaseDir}":/base:ro)
  incrementalArg="--incremental-basedir=/base"
 fi
 mkdir -p "${targetDir}"
 docker run --rm --name "${containerName}" \
            --log-driver none \
            -v "${DBDataDir}":/var/lib/mysql:ro \
            "${baseMountArgs[@]}" \
            -v "${targetDir}":/backup:rw \
            "${dbNetworkArgs[@]}" \
            "${DBBackupImage}" \
            bash -c 'mariadb-backup --backup \
                                    --target-dir=/backup \
                                    --extra-lsndir=/backup/lsn \
                                    '"${incrementalArg}"' \
                                    --stream=xbstream \
                                    --host="'"${DBHost}"'" \
                                    --port="'"${DBPort}"'" \
                                    --user="'"${DBUser}"'" \
                                    --password="'"${remotePassword}"'" \
                     && chown -R "'"$(id -u)":"$(id -g)"'" /backup' > "${streamFile}" 2> "${backupLog}"
 local exitCode=${?}
 if [ ${exitCode} -ne 0 ]; then
  log-line err "mariadb-backup failed with code ${exitCode}:"
  log-tail "${backupLog}"
  return 1
 fi
 if [ ! -s "${streamFile}" ]; then
  log-line err "mariadb-backup finished, but the backup stream is empty:"
  log-tail "${backupLog}"
  return 1
 fi
 if ! has-lsn-metadata "${targetDir}/lsn"; then
  log-line err "mariadb-backup finished, but saved no LSN metadata in ${targetDir}/lsn:"
  log-tail "${backupLog}"
  return 1
 fi
 rm -f "${backupLog}"
 log-line msg "backup file successfully created at ${streamFile} ($(size-of "${streamFile}"))"
}

bkp-db-weekly() {
 require-db-type
 require-vars DBHost DBPort DBUser DBPassword DBDataDir DBBackupImage
 require-tools docker flock pgrep tar bzip2 openssl gcloud
 log-line msg "=== STARTING WEEKLY BACKUP ==="
 acquire-lock "${lockWeekly}" ${LOCK_FD_WEEKLY}
 terminate-lower-priority 3
 local ts
 ts=$(date -u +"%Y%m%d%H%M%S")
 local bkpRoot="${LocalBackupDir}/${ts}/mariadb"
 local fullDir="${bkpRoot}/full"
 local prevBkp=""
 local d
 for d in $(find "${LocalBackupDir}" -mindepth 1 -maxdepth 1 -type d -name '[0-9][0-9][0-9][0-9][0-1][0-9][0-3][0-9][0-2][0-9][0-5][0-9][0-5][0-9]' | sort -r); do
  if [[ "$(basename "${d}")" < "${ts}" ]]; then
   prevBkp="$(basename "${d}")"
   break
  fi
 done
 if run-mariadb-backup "mariadb-backup-full-${ts}" "${fullDir}"; then
  if [[ -n "${prevBkp}" ]]; then
   release-lock "${lockWeekly}" "${LOCK_FD_WEEKLY}"
   bkp-db-daily "${prevBkp}"
   if [ "${?}" -gt 0 ]; then
    log-line err "failed to append previous week - please run '${scriptName} bkp-db-daily \"${prevBkp}\"' manually"
    exit 1
   fi
   release-lock "${lockDaily}" "${LOCK_FD_DAILY}"
   bkp-db-hourly "${prevBkp}"
   if [ "${?}" -gt 0 ]; then
    log-line err "failed to append previous week - please run '${scriptName} bkp-db-hourly \"${prevBkp}\"' manually"
    exit 1
   fi
   log-line msg "appended daily incremental and binlogs to previous backup archive (${prevBkp}) - ready for sending to cloud"
  else
   log-line msg "no previous full backup found - skipped daily incremental and binlog append"
  fi
  lastFullTs="${ts}"
  lastIncTs=""
  save-state
  local result=0
  if [[ -n "${prevBkp}" ]]; then
   if bkp-to-cloud "${prevBkp}" "weekly"; then
    rm -rf "${LocalBackupDir}/${prevBkp}"
   else
    log-line wrn "couldn't upload previous week's backups to cloud - keeping them locally (${LocalBackupDir}/${prevBkp})"
    result=1
   fi
  fi
  if ! bkp-to-cloud "${ts}" "daily"; then
   log-line wrn "couldn't upload the new full backup to cloud (${LocalBackupDir}/${ts})"
   result=1
  fi
  if [ ${result} -eq 0 ]; then
   log-line msg "=== WEEKLY BACKUP COMPLETED ==="
  else
   log-line wrn "=== WEEKLY BACKUP COMPLETED WITH ERRORS ==="
  fi
  return ${result}
 else
  # the whole chain dir, not just full/ - an empty chain dir would be picked up as the previous week next time
  rm -rf "${LocalBackupDir:?}/${ts}"
  log-line err "weekly backup failed"
  return 1
 fi
}
bkp-db-daily() {
 require-db-type
 require-vars DBHost DBPort DBUser DBPassword DBDataDir DBBackupImage
 require-tools docker flock pgrep tar bzip2 openssl gcloud
 if higher-priority-running "${lockWeekly}"; then
  log-line wrn "weekly backup is running - skipping daily"
  return 1
 fi
 log-line msg "=== STARTING DAILY BACKUP ==="
 acquire-lock "${lockDaily}" ${LOCK_FD_DAILY}
 terminate-lower-priority 2
 load-state
 local fullTs="${lastFullTs}"
 if [[ -z "${1}" ]] && full-backup-stale "${fullTs}"; then
  if [[ -z "${fullTs}" ]]; then
   log-line err "no valid full backup found and no parameter is given - falling back to full backup"
  else
   log-line msg "last full backup (${fullTs}) is older than ${FULL_BACKUP_MAX_AGE_DAYS} days - running full backup instead"
  fi
  release-lock "${lockDaily}" ${LOCK_FD_DAILY}
  bkp-db-weekly
  return ${?}
 elif [[ -n "${1}" ]]; then
  fullTs="${1}"
 fi
 local bkpRoot="${LocalBackupDir}/${fullTs}/mariadb"
 if [[ ! -f "${bkpRoot}/full/backup.xbstream" ]]; then
  log-line err "no full backup found for ${fullTs} - error in ${stateFile}?"
  return 1
 fi
 local ts
 ts=$(date -u +"%Y%m%d%H%M%S")
 local incDir="${bkpRoot}/inc_${ts}"
 local lastFullDir
 lastFullDir=$(ls -d "${bkpRoot}"/full)
 local selectedFullTs="${fullTs}"
 local incDirs=($(ls -d "${bkpRoot}"/inc_* 2>/dev/null | sort))
 local maxIncTs="00010101-000000"
 local dir
 for dir in "${incDirs[@]}"; do
  local incTs=${dir##*/inc_}
  if [[ "${incTs}" > "${selectedFullTs}" ]] && [[ "${incTs}" < "${ts}" || "${incTs}" == "${ts}" ]]; then
   if [[ "${incTs}" > "${maxIncTs}" ]]; then
    maxIncTs="${incTs}"
   fi
  fi
 done
 if [ "${maxIncTs}" != "00010101-000000" ]; then
  lastFullDir="${bkpRoot}/inc_${maxIncTs}"
  log-line msg "found incremental backup at ${lastFullDir}"
 fi
 local incBaseDir="${lastFullDir}/lsn"
 local extractDir=""
 if ! has-lsn-metadata "${incBaseDir}"; then
  log-line msg "no LSN metadata saved alongside ${lastFullDir} (made by an older version of bkp) - unpacking it to read it"
  extractDir=$(make-work-dir) || return 1
  if ! extract-xbstream "${lastFullDir}/backup.xbstream" "${extractDir}"; then
   remove-extracted "${extractDir}"
   return 1
  fi
  incBaseDir="${extractDir}"
  if ! has-lsn-metadata "${incBaseDir}"; then
   log-line err "${lastFullDir}/backup.xbstream contains no LSN metadata, so it's probably a broken backup"
   log-line err "move ${lastFullDir} out of ${bkpRoot}, so the next daily backup is based on the backup before it"
   remove-extracted "${extractDir}"
   return 1
  fi
 fi
 if run-mariadb-backup "mariadb-backup-inc-${ts}" "${incDir}" "${incBaseDir}"; then
  remove-extracted "${extractDir}"
  lastIncTs="${ts}"
  save-state
  local result=0
  bkp-folders "${fullTs}"
  if [[ -z "${1}" ]] && ! bkp-to-cloud "${fullTs}" "daily"; then
   log-line wrn "couldn't upload backup chain ${fullTs} to cloud (${LocalBackupDir}/${fullTs})"
   result=1
  fi
  if [ ${result} -eq 0 ]; then
   log-line msg "=== DAILY BACKUP COMPLETED ==="
  else
   log-line wrn "=== DAILY BACKUP COMPLETED WITH ERRORS ==="
  fi
  return ${result}
 else
  remove-extracted "${extractDir}"
  rm -rf "${incDir}"
  log-line err "daily backup failed"
  return 1
 fi
}
bkp-db-hourly() {
 require-db-type
 require-vars DBDataDir DBBinlogBasename DBContainerName DBUser DBPassword
 require-tools docker flock
 if higher-priority-running "${lockWeekly}" || higher-priority-running "${lockDaily}"; then
  log-line wrn "higher priority backup running - skipping hourly"
  return 1
 fi
 log-line msg "=== STARTING HOURLY BACKUP ==="
 acquire-lock "${lockHourly}" ${LOCK_FD_HOURLY}
 load-state
 local fullTs="${lastFullTs}"
 if [[ -z "${1}" ]] && full-backup-stale "${fullTs}"; then
  if [[ -z "${fullTs}" ]]; then
   log-line wrn "no full backup exists yet - running full backup instead of binlog backup"
  else
   log-line msg "last full backup (${fullTs}) is older than ${FULL_BACKUP_MAX_AGE_DAYS} days - running full backup instead"
  fi
  release-lock "${lockHourly}" ${LOCK_FD_HOURLY}
  bkp-db-weekly
  return ${?}
 elif [[ -n "${1}" ]]; then
  fullTs="${1}"
 fi
 local ts
 ts=$(date -u +"%Y%m%d%H%M%S")
 local binlogDir="${LocalBackupDir}/${fullTs}/mariadb/binlogs"
 mkdir -p "${binlogDir}"
 local since="${fullTs}"
 log-line msg "archiving binlogs newer than ${since}"
 local sinceEpoch
 sinceEpoch=$(date -d "${since:0:4}-${since:4:2}-${since:6:2} ${since:8:2}:${since:10:2}:${since:12:2}" +%s 2>/dev/null || echo 0)
 local safeSinceEpoch=$((sinceEpoch - 7200))
 if docker run --rm -v "${DBDataDir}":/var/lib/mysql:ro \
               -v "${binlogDir}":/target \
               "${BINLOG_UTILITY_IMAGE}" bash -c 'cd /var/lib/mysql || exit 1
                                               files=()
                                               for f in "'"${DBBinlogBasename}"'".[0-9]* "'"${DBBinlogBasename}"'".index; do
                                                [[ -f "${f}" ]] || continue
                                                mtime=$(stat -c %Y "${f}" 2>/dev/null || echo 0)
                                                if [[ "${mtime}" -ge '"${safeSinceEpoch}"' ]]; then
                                                 files+=("${f}")
                                                fi
                                               done
                                               if [ ${#files[@]} -eq 0 ]; then
                                                echo "'"$(log-line msg "nothing to backup")"'"
                                                exit 0
                                               fi
                                               for f in ${files[@]}; do
                                                cp "${f}" /target/ || exit 1
                                               done
                                               chown '$(id -u)':'$(id -g)' "/target/"*'; then
  log-line msg "binlogs successfully copied to ${binlogDir}/ ($(size-of "${binlogDir}") in total)"
  purge-old-binlogs
  log-line msg "=== HOURLY BACKUP COMPLETED ==="
 else
  log-line err "hourly backup failed with code ${?}"
  return 1
 fi
}

###################################################################################################
######################################## RESTORE DATABASE #########################################
###################################################################################################

perform-restore() { # TODO: if isPITR=1, find the full backup that precedes targetDatetimeStr
 local isPITR="${1}"
 local targetDatetimeStr="${2}"
 local ts="${3}"
 local restoreDBDir="${RestoreDir}/mariadb"
 cd "${restoreDBDir}" || { log-line err "cannot cd to ${restoreDBDir}"; return 1; }
 local baseDir="./base"
 local incDirs=($(ls -d ./_inc_* 2>/dev/null | sort))
 local prepareLog="${restoreDBDir}/prepare.log"
 log-line msg "preparing backup chain (base = ${baseDir}, incrementals: ${#incDirs[@]}) ..."
 if ! docker run --rm -v "${restoreDBDir}/${baseDir}":/backup:rw \
  "${DBBackupImage}" bash -c 'mariadb-backup --prepare --target-dir=/backup \
                        && chown -R "'"$(id -u)":"$(id -g)"'" /backup' 2> "${prepareLog}"; then
  log-line err "preparing the full backup failed - the database was left untouched:"
  log-tail "${prepareLog}"
  return 1
 fi
 local inc
 for inc in "${incDirs[@]}"; do
  local incName
  incName=$(basename "${inc}")
  log-line msg "-> applying incremental ${incName}"
  # base and incremental in one mount: mariadb-backup moves files between them, which fails across mounts
  if ! docker run --rm -v "${restoreDBDir}":/restore:rw \
   "${DBBackupImage}" bash -c 'mariadb-backup --prepare --target-dir="/restore/'"${baseDir}"'" --incremental-dir="/restore/'"${incName}"'" \
                         && chown -R "'"$(id -u)":"$(id -g)"'" "/restore/'"${baseDir}"'"' 2> "${prepareLog}"; then
   log-line err "applying incremental ${incName} failed - the database was left untouched:"
   log-tail "${prepareLog}"
   return 1
  fi
 done
 rm -f "${prepareLog}"
 local backupEndDatetime
 backupEndDatetime=$(grep '^end_time' "${baseDir}/mariadb_backup_info" | awk -F '= ' '{gsub(/"/,"",$2); print $2}' | xargs)
 log-line msg "backup chain consistent as of: ${backupEndDatetime}"
 log-line msg "stopping MariaDB container..."
 docker stop "${DBContainerName}" || true
 local corruptedDir="${DBDataDir}-corrupted-$(date -u +"%Y%m%d%H%M%S")"
 log-line msg "saving corrupted/current data dir -> ${corruptedDir}"
 if ! mv "${DBDataDir}" "${corruptedDir}"; then
  log-line err "failed to move ${DBDataDir} aside - ${DBContainerName} is stopped, start it again with '${scriptName} db-start'"
  return 1
 fi
 mkdir -p "${DBDataDir}"
 log-line msg "copying back data from backup..."
 if ! docker run --rm -v "${DBDataDir}":/var/lib/mysql:rw -v "${restoreDBDir}/${baseDir}":/backup:ro \
  "${DBBackupImage}" mariadb-backup --copy-back --target-dir=/backup --datadir=/var/lib/mysql 2> "${prepareLog}"; then
  log-line err "copying back the backup into ${DBDataDir} failed - ${DBContainerName} was left stopped:"
  log-tail "${prepareLog}"
  log-line err "the previous data dir is at ${corruptedDir} - move it back to ${DBDataDir} to undo"
  return 1
 fi
 rm -f "${prepareLog}"
 log-line msg "starting MariaDB container..."
 docker start "${DBContainerName}"
 wait-for-db "${DBContainerName}" "${DBUser}" "${DBPassword}"
 if [ "${isPITR}" = "1" ] && [[ "${backupEndDatetime}" < "${targetDatetimeStr}" ]]; then
  log-line msg "applying binary logs from ${backupEndDatetime} -> ${targetDatetimeStr}..."
  local pitrDir
  if ! pitrDir=$(make-work-dir); then
   log-line err "binary logs not applied - the database is restored to ${backupEndDatetime}"
   return 1
  fi
  cp "${LocalBackupDir}/${ts}/mariadb/binlogs/"* "${pitrDir}"
  if [ "${?}" -ne 0 ]; then
   log-line msg "failed to copy binary logs to PITR folder"
  else
   local binlogFiles=($(ls "${pitrDir}"/"${DBBinlogBasename}".* 2>/dev/null | grep -v ".idx" | grep -v ".index" | sort))
   if [ ${#binlogFiles[@]} -gt 0 ]; then
    local binlogPosFile="${restoreDBDir}/base/mariadb_backup_binlog_info"
    local startFile
    startFile=$(awk '{print $1}' "${binlogPosFile}")
    local startPos
    startPos=$(awk '{print $2}' "${binlogPosFile}")
    local binlogCmd="mariadb-binlog --no-defaults --set-charset=utf8mb4"
    local started=0
    local bp bf
    for bp in "${binlogFiles[@]}"; do
     bf=$(basename "${bp}")
     if [[ "${bf}" < "${startFile}" ]]; then continue; fi
     if [[ "${bf}" == "${startFile}" ]]; then
      binlogCmd="${binlogCmd} \"/pitr/$(basename ${bf})\" --start-position=\"${startPos}\""
      started=1
     elif [ ${started} = 1 ]; then
      binlogCmd="${binlogCmd} \"/pitr/$(basename ${bf})\""
     fi
    done
    binlogCmd="${binlogCmd} --stop-datetime=\"${targetDatetimeStr}\""
    log-line msg "executing: ${binlogCmd} | mariadb"
    echo '#!/bin/bash' > ./import-script.sh
    echo "${binlogCmd} | mariadb -u "${DBUser}" -p${DBPassword}" >> ./import-script.sh
    echo "rm -rf /pitr" >> ./import-script.sh
    chmod +x ./import-script.sh
    docker cp ./import-script.sh "${DBContainerName}:/import-script.sh"
    docker cp "${pitrDir}" "${DBContainerName}:/pitr"
    docker exec "${DBContainerName}" /import-script.sh
    docker exec "${DBContainerName}" rm -rf /import-script.sh /pitr
    rm ./import-script.sh
    log-line msg "binary logs applied successfully"
   else
    log-line msg "no individual binlog files found after extraction"
   fi
  fi
  rm -rf "${pitrDir}"
 else
  if [ "${isPITR}" = "1" ]; then
   log-line msg "target time (${targetDatetimeStr}) is not after backup end time (${backupEndDatetime}) -> no binlog apply needed"
  fi
 fi
 log-line msg "=== RESTORE COMPLETED successfully ==="
}

restore-db-local() {
 require-db-type
 require-vars DBDataDir DBContainerName DBPassword DBBackupImage DBBinlogBasename
 require-tools docker
 local ts="${1}"
 local targetDatetimeStr="${2}"
 if [ -z "${ts}" ]; then
  log-line err "usage: ${scriptName} restore-db-local <timestamp> [target-datetime]"
  return 1
 fi
 local isPITR=0
 local targetTs="99999999999999"
 if [ -n "${targetDatetimeStr}" ]; then
  if ! date -d "${targetDatetimeStr}" >/dev/null 2>&1; then
   log-line err "invalid datetime format for ${targetDatetimeStr} (use yyyy-MM-dd HH:mm:ss)"
   return 1
  fi
  targetTs=$(date -d "${targetDatetimeStr}" +"%Y%m%d%H%M%S")
  isPITR=1
  log-line msg "=== POINT-IN-TIME RESTORE to ${targetDatetimeStr} ==="
 else
  log-line msg "=== RESTORE to latest available backup (no PITR) ==="
 fi
 local backupRoot="${LocalBackupDir}/${ts}/mariadb"
 local restoreDBDir="${RestoreDir}/mariadb"
 rm -rf "${restoreDBDir}"
 mkdir -p "${restoreDBDir}"
 local selectedFullDir="${backupRoot}/full"
 if [ ! -d "${selectedFullDir}" ]; then
  log-line err "no full backup found in ${selectedFullDir}"
  return 1
 fi
 log-line msg "found full backup: ${selectedFullDir}/"
 local incDirs=($(ls -d "${backupRoot}"/inc_* 2>/dev/null | sort))
 local selectedIncDirs=()
 local dir
 for dir in "${incDirs[@]}"; do
  local incTs=${dir##*/inc_}
  if [[ "${incTs}" > "${ts}" ]] && [[ "${incTs}" < "${targetTs}" || "${incTs}" == "${targetTs}" ]]; then
   selectedIncDirs+=("${dir}")
  fi
 done
 log-line msg "selected ${#selectedIncDirs[@]} incremental backup(s)"
 local fullStream="${selectedFullDir}/backup.xbstream"
 if ! extract-xbstream "${fullStream}" "${restoreDBDir}/base"; then
  remove-extracted "${restoreDBDir}"
  return 1
 fi
 local i
 for ((i=0; i<${#selectedIncDirs[@]}; i++)); do
  local incStream="${selectedIncDirs[i]}/backup.xbstream"
  if ! extract-xbstream "${incStream}" "${restoreDBDir}/_inc_${i}"; then
   remove-extracted "${restoreDBDir}"
   return 1
  fi
 done
 local result=0
 perform-restore "${isPITR}" "${targetDatetimeStr}" "${ts}"
 if [ "${?}" -ne 0 ]; then
  log-line err "there's been an error restoring the database"
  log-line err "fix the errors, then re-run restore with ${scriptName} restore-db-local \"${ts}\" \"${targetDatetimeStr}\""
  result=1
 fi
 rm -rf "${restoreDBDir}"
 return ${result}
}

###################################################################################################
############################################# FOLDERS ##############################################
###################################################################################################

bkp-folders() {
 local ts="${1}"
 if [ -z "${BackupFolders}" ]; then
  return 0
 fi
 local destRoot="${LocalBackupDir}/${ts}/files"
 mkdir -p "${destRoot}"
 local folder
 for folder in ${BackupFolders}; do
  if [ ! -d "${folder}" ]; then
   log-line err "configured backup folder does not exist, skipping: ${folder}"
   continue
  fi
  log-line msg "backing up folder ${folder}"
  cp -a "${folder}" "${destRoot}/"
 done
}

restore-folders-local() {
 local ts="${1}"
 if [ -z "${ts}" ]; then
  log-line err "usage: ${scriptName} restore-folders-local <timestamp>"
  return 1
 fi
 local srcRoot="${LocalBackupDir}/${ts}/files"
 if [ ! -d "${srcRoot}" ]; then
  log-line err "no folder backup found at ${srcRoot}"
  return 1
 fi
 local folder
 for folder in ${BackupFolders}; do
  local base
  base=$(basename "${folder}")
  if [ -d "${srcRoot}/${base}" ]; then
   log-line msg "restoring folder ${folder}"
   mkdir -p "$(dirname "${folder}")"
   rm -rf "${folder}"
   cp -a "${srcRoot}/${base}" "${folder}"
  else
   log-line wrn "no backup found for folder ${folder} in ${srcRoot}"
  fi
 done
}

###################################################################################################
######################################## CLOUD OPERATIONS #########################################
###################################################################################################

bkp-to-cloud() {
 require-cloud-provider
 require-vars GCSBucket AESPassphrase BackupInstanceName
 require-tools tar bzip2 openssl gcloud
 local ts="${1}"
 local level="${2}"
 if [ -z "${ts}" ] || [ -z "${level}" ]; then
  log-line err "usage: ${scriptName} bkp-to-cloud <timestamp> <weekly|daily>"
  return 1
 fi
 local srcDir="${LocalBackupDir}/${ts}"
 if [ ! -d "${srcDir}" ]; then
  log-line err "no local backup found at ${srcDir}"
  return 1
 fi
 local archiveName="${level}-backup.${BackupInstanceName}.${ts}.tar.bz2.aes256"
 local workDir
 workDir=$(make-work-dir) || return 1
 local encryptedPath="${workDir}/${archiveName}"
 local cloudPath="gs://${GCSBucket}/${archiveName}"
 log-line msg "archiving and encrypting ${srcDir} ($(size-of "${srcDir}")) -> ${encryptedPath}"
 export PASSPHRASE="${AESPassphrase}"
 if ! (set -o pipefail
       tar -cjf - -C "${srcDir}" . | openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -out "${encryptedPath}" -pass env:PASSPHRASE); then
  log-line err "failed to archive and encrypt ${srcDir} (out of space in ${workDir}?) - nothing was uploaded"
  rm -rf "${workDir}"
  return 1
 fi
 log-line msg "encrypted archive created ($(size-of "${encryptedPath}")), uploading to ${cloudPath}"
 # an existing object is only replaced once the new upload completes, so a failed upload leaves it intact
 if ! gcloud storage cp "${encryptedPath}" "${cloudPath}"; then
  log-line err "failed to upload encrypted archive to cloud, moving it to ${RestoreDir}"
  mkdir -p "${RestoreDir}"
  mv "${encryptedPath}" "${RestoreDir}"
  rm -rf "${workDir}"
  return 1
 fi
 log-line msg "uploaded ${cloudPath} ($(size-of "${encryptedPath}"))"
 rm -rf "${workDir}"
 if [ "${level}" = "weekly" ]; then
  gcloud storage rm -q "gs://${GCSBucket}/daily-backup.${BackupInstanceName}.*.tar.bz2.aes256" 2>/dev/null || true
 fi
}
restore-from-cloud() {
 require-cloud-provider
 require-vars GCSBucket AESPassphrase BackupInstanceName
 require-tools gcloud openssl tar bzip2 docker
 local targetDatetime="${1}"
 local ts
 ts=$(date -u +"%Y%m%d%H%M%S")
 local targetTs
 if [ -n "${targetDatetime}" ] && targetTs=$(date -u -d "${targetDatetime}" +"%Y%m%d%H%M%S" 2>/dev/null); then
  ts="${targetTs}"
 elif [ -n "${targetDatetime}" ]; then
  log-line err "invalid datetime format - use 'yyyy-MM-dd HH:mm:ss'"
  return 1
 fi
 local candidates
 candidates=$(gcloud storage ls "gs://${GCSBucket}/*-backup.${BackupInstanceName}.*.tar.bz2.aes256" 2>/dev/null | grep -E ".*-backup\.${BackupInstanceName}\.[0-9]{14}\.tar\.bz2\.aes256$")
 if [[ -z "${candidates}" ]]; then
  log-line err "no backups found before '${targetDatetime}'"
  return 1
 fi
 local latestFile=""
 local latestTs="00000000000000"
 local line
 while IFS= read -r line; do
  local filename
  filename=$(basename "${line}")
  local fileTs
  fileTs=$(echo "${filename}" | grep -oE '[0-9]{14}' || echo "00000000000000")
  if [[ "${fileTs}" > "${latestTs}" ]] && [[ ! "${fileTs}" > "${ts}" ]]; then
   latestTs="${fileTs}"
   latestFile="${line}"
  fi
 done <<< "${candidates}"
 if [[ -z "${latestFile}" ]]; then
  log-line err "no backups found before '${targetDatetime}'"
  return 1
 fi
 local archiveName
 archiveName=$(basename "${latestFile}")
 local localEncryptedPath="${RestoreDir}/${archiveName}"
 mkdir -p "${RestoreDir}"
 if ! gcloud storage cp "${latestFile}" "${localEncryptedPath}"; then
  log-line err "failed to download backup from cloud"
  return 1
 fi
 export PASSPHRASE="${AESPassphrase}"
 if ! openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 -in "${localEncryptedPath}" -out "${RestoreDir}/downloaded-backup.tar.bz2" -pass env:PASSPHRASE; then
  log-line err "decryption failed (incorrect passphrase?)"
  rm -f "${localEncryptedPath}"
  return 1
 fi
 if ! tar xvfj "${RestoreDir}/downloaded-backup.tar.bz2" -C "${RestoreDir}"; then
  log-line err "failed to extract archive"
  rm -f "${RestoreDir}/downloaded-backup.tar.bz2" "${localEncryptedPath}"
  return 1
 fi
 rm -f "${RestoreDir}/downloaded-backup.tar.bz2" "${localEncryptedPath}"
 sync
 local replaceLocal=false
 if [ ${#} -ge 2 ] && [ "${2}" = "--replace-local-backup" ]; then
  replaceLocal=true
 elif [ ${#} -ge 2 ]; then
  log-line msg "skip replacing local backup due to second argument value: ${2}"
 else
  if [ -d "${LocalBackupDir}/${latestTs}" ]; then
   echo "Replace existing local backup with the restored version?"
   echo "WARNING: This will remove the local backups folder, so it might be a good idea to back it up."
   read -r -p "Type 'replace' to confirm: " answer
   echo
   case "${answer}" in
    replace) replaceLocal=true;;
    *) replaceLocal=false;;
   esac
  fi
 fi
 if [ "${replaceLocal}" = true ] && [ -d "${LocalBackupDir}/${latestTs}" ]; then
  rm -rf "${LocalBackupDir}/${latestTs}"
  if [ "${?}" -ne 0 ]; then
   log-line err "failed to remove old backups directory - possible permissions issue"
   log-line err "resolve issue with ${LocalBackupDir} manually, then mv \"${RestoreDir}\" \"${LocalBackupDir}/${latestTs}\""
   return 1
  fi
  mv "${RestoreDir}" "${LocalBackupDir}/${latestTs}"
  if [ "${?}" -ne 0 ]; then
   log-line err "failed to move restored directory"
   log-line err "resolve issue with ${LocalBackupDir} manually, then mv \"${RestoreDir}\" \"${LocalBackupDir}/${latestTs}\""
   return 1
  fi
 elif [ ! -d "${LocalBackupDir}/${latestTs}" ]; then
  replaceLocal=true
  mv "${RestoreDir}" "${LocalBackupDir}/${latestTs}"
  if [ "${?}" -ne 0 ]; then
   log-line err "failed to move restored directory"
   log-line err "resolve issue with ${LocalBackupDir} manually, then mv \"${RestoreDir}\" \"${LocalBackupDir}/${latestTs}\""
   return 1
  fi
 else
  log-line msg "to use the freshly restored files as the new local backup at a later time, run 'mv \"${RestoreDir}\" \"${LocalBackupDir}/${latestTs}\"'"
 fi
 if [ "${replaceLocal}" = true ]; then
  restore-db-local "${latestTs}" "${targetDatetime}"
 fi
}

###################################################################################################
############################################## CRON ################################################
###################################################################################################

install-cron() {
 require-tools crontab
 mkdir -p "$(dirname "${LogFile}")"
 local exe="${scriptDir}/bkp"
 local weeklyLine="${CronWeekly} ${exe} bkp-db-weekly >> ${LogFile} 2>&1"
 local dailyLine="${CronDaily} ${exe} bkp-db-daily >> ${LogFile} 2>&1"
 local hourlyLine="${CronHourly} ${exe} bkp-db-hourly >> ${LogFile} 2>&1"
 (crontab -l 2>/dev/null | grep -v -F "${exe} bkp-db-weekly"; echo "${weeklyLine}") | crontab -
 (crontab -l 2>/dev/null | grep -v -F "${exe} bkp-db-daily"; echo "${dailyLine}") | crontab -
 (crontab -l 2>/dev/null | grep -v -F "${exe} bkp-db-hourly"; echo "${hourlyLine}") | crontab -
 log-line msg "cron jobs installed:"
 log-line msg "  weekly : ${CronWeekly}"
 log-line msg "  daily  : ${CronDaily}"
 log-line msg "  hourly : ${CronHourly}"
 log-line msg "logs will be appended to ${LogFile}"
}

###################################################################################################
############################################# STATUS ###############################################
###################################################################################################

format-backup-ts() {
 local ts="${1}"
 [ -z "${ts}" ] && return
 date -u -d "${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:8:2}:${ts:10:2}:${ts:12:2}" +"%Y-%m-%d %H:%M:%S UTC" 2>/dev/null
}

slave-status-field() {
 local text="${1}"
 local field="${2}"
 echo "${text}" | grep -E "^ *${field}: " | head -1 | sed -E "s/^ *${field}: ?//"
}

purge-old-binlogs() {
 require-vars DBContainerName DBUser DBPassword
 if ! docker ps --filter "name=^/${DBContainerName}$" --filter "status=running" -q 2>/dev/null | grep -q .; then
  log-line msg "database is not up - skipping binlog purge"
  return 1
 fi
 local slaveStatus
 slaveStatus=$(docker exec "${DBContainerName}" mariadb -u"${DBUser}" -p"${DBPassword}" -e "SHOW SLAVE STATUS\G" 2>/dev/null)
 if [ -z "${slaveStatus}" ]; then
  log-line msg "not a replica - skipping binlog purge"
  return 1
 fi
 local ioRunning sqlRunning
 ioRunning=$(slave-status-field "${slaveStatus}" "Slave_IO_Running")
 sqlRunning=$(slave-status-field "${slaveStatus}" "Slave_SQL_Running")
 if [ "${ioRunning}" != "Yes" ] || [ "${sqlRunning}" != "Yes" ]; then
  log-line wrn "replication not healthy (IO=${ioRunning}, SQL=${sqlRunning}) - skipping binlog purge"
  return 1
 fi
 local purgeBefore
 purgeBefore=$(date -u -d "-${BINLOG_PURGE_MAX_AGE_DAYS} days" +"%Y-%m-%d %H:%M:%S")
 log-line msg "replication healthy - purging binlogs older than ${purgeBefore} UTC"
 if docker exec "${DBContainerName}" mariadb -u"${DBUser}" -p"${DBPassword}" -e "PURGE BINARY LOGS BEFORE '${purgeBefore}';" 2>/dev/null; then
  log-line msg "old binlogs purged"
 else
  log-line err "failed to purge old binlogs"
  return 1
 fi
}

status-tools() {
 echo "${BOLD}${CYAN}Required tools${RESET}"
 local missing tool
 missing=$(missing-tools "${KNOWN_TOOLS[@]}")
 if [ -z "${missing}" ]; then
  echo "  all found"
 fi
 for tool in ${missing}; do
  echo "  ${RED}${tool} not found${RESET} - $(tool-install-hint "${tool}")"
 done
 echo
}

status-db() {
 echo "${BOLD}${CYAN}Database${RESET}"
 dbUp=false
 if ! command -v docker >/dev/null 2>&1; then
  echo "  container ${DBContainerName}: ${RED}cannot check${RESET} (docker not found)"
  echo
  return
 fi
 if [ -n "${DBContainerName}" ] && docker ps --filter "name=^/${DBContainerName}$" --filter "status=running" -q 2>/dev/null | grep -q .; then
  if docker exec "${DBContainerName}" mariadb -u"${DBUser}" -p"${DBPassword}" -e "SELECT 1" >/dev/null 2>&1; then
   dbUp=true
  fi
 fi
 if [ "${dbUp}" = true ]; then
  echo "  container ${DBContainerName}: ${GREEN}UP${RESET} (accepting connections)"
 else
  echo "  container ${DBContainerName}: ${RED}DOWN${RESET} (not running, or not accepting connections)"
  echo "    -> run '${scriptName} db-start' to start it"
 fi
 echo
}

status-schedule() {
 echo "${BOLD}${CYAN}Backup schedule (cron)${RESET}"
 if ! command -v crontab >/dev/null 2>&1; then
  echo "  ${RED}cannot check${RESET} (crontab not found)"
  echo
  return
 fi
 local exe="${scriptDir}/bkp"
 local cronList
 cronList=$(crontab -l 2>/dev/null)
 local missingCron=false
 local level
 for level in weekly daily hourly; do
  local pattern="${exe} bkp-db-${level}"
  local line
  line=$(echo "${cronList}" | grep -F "${pattern}" | head -1)
  if [ -n "${line}" ]; then
   local schedule
   schedule=$(echo "${line}" | awk '{print $1, $2, $3, $4, $5}')
   echo "  ${level}: ${GREEN}installed${RESET} (schedule: ${schedule})"
  else
   echo "  ${level}: ${YELLOW}not installed${RESET}"
   missingCron=true
  fi
 done
 [ "${missingCron}" = true ] && echo "    -> run '${scriptName} install-cron' to (re)install the schedule from .env"
 echo
}

# size of a backup stream file, flagging a missing or empty one
stream-size() {
 if [ ! -f "${1}" ]; then
  echo "${RED}missing${RESET} (${1})"
 elif [ ! -s "${1}" ]; then
  echo "${RED}EMPTY${RESET} - this backup is broken"
 else
  size-of "${1}"
 fi
}

status-local-backups() {
 echo "${BOLD}${CYAN}Local backups${RESET}"
 load-state
 local chainDir="${LocalBackupDir}/${lastFullTs}"
 if [ -n "${lastFullTs}" ]; then
  echo "  last full backup:        ${lastFullTs} ($(format-backup-ts "${lastFullTs}")), $(stream-size "${chainDir}/mariadb/full/backup.xbstream")"
 else
  echo "  last full backup:        none"
 fi
 if [ -n "${lastIncTs}" ]; then
  echo "  last incremental backup: ${lastIncTs} ($(format-backup-ts "${lastIncTs}")), $(stream-size "${chainDir}/mariadb/inc_${lastIncTs}/backup.xbstream")"
 else
  echo "  last incremental backup: none"
 fi
 if [ -n "${lastFullTs}" ] && [ -d "${chainDir}" ]; then
  echo "  current chain total:     $(size-of "${chainDir}") (full + incrementals + binlogs + folders)"
 fi
 echo "  all local backups:       $(size-of "${LocalBackupDir}") in ${LocalBackupDir}"
 echo
}

status-cloud-backups() {
 echo "${BOLD}${CYAN}Cloud backups${RESET}"
 if [ "${CloudProvider}" != "gcloud" ] || [ -z "${GCSBucket}" ]; then
  echo "  not configured (CloudProvider=${CloudProvider:-unset}, GCSBucket=${GCSBucket:-unset})"
  echo
  return
 fi
 if ! command -v gcloud >/dev/null 2>&1; then
  echo "  ${RED}gcloud CLI not found${RESET} - install the Google Cloud CLI to check cloud backups"
  echo
  return
 fi
 # local check (no network): an uninitialized gcloud has no active credentialed account
 local activeAccount
 activeAccount=$(timeout -k 1 "${STATUS_CLOUD_TIMEOUT_SECONDS}" gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null)
 if [ -z "${activeAccount}" ]; then
  echo "  ${RED}gcloud is not initialized${RESET} (no active account) - run 'gcloud init' or 'gcloud auth login' to set it up"
  echo
  return
 fi
 # output goes to a file rather than $(...), so stray gcloud subprocesses holding the pipe open can't outlive the timeout
 local lsOutput lsExit lsOutputFile
 lsOutputFile=$(mktemp)
 timeout -k 1 "${STATUS_CLOUD_TIMEOUT_SECONDS}" gcloud storage ls --long "gs://${GCSBucket}/*-backup.${BackupInstanceName}.*.tar.bz2.aes256" >"${lsOutputFile}" 2>&1
 lsExit=${?}
 lsOutput=$(cat "${lsOutputFile}")
 rm -f "${lsOutputFile}"
 if [ ${lsExit} -eq 124 ] || [ ${lsExit} -eq 137 ]; then
  echo "  ${RED}unable to reach gs://${GCSBucket}/${RESET} within ${STATUS_CLOUD_TIMEOUT_SECONDS}s - check your internet/network connection"
  echo
  return
 fi
 if [ ${lsExit} -ne 0 ] && ! grep -qi "matched no objects" <<< "${lsOutput}"; then
  local lsError
  lsError=$(grep -m1 "ERROR" <<< "${lsOutput}")
  if grep -qiE "do not currently have an active account|gcloud auth login|reauthenticat|invalid_grant" <<< "${lsOutput}"; then
   echo "  ${RED}gcloud is not authenticated${RESET} (account ${activeAccount}) - run 'gcloud auth login' to refresh credentials"
  else
   echo "  ${RED}unable to list gs://${GCSBucket}/${RESET} - check your internet/network connection and bucket access"
  fi
  [ -n "${lsError}" ] && echo "    ${lsError}"
  echo
  return
 fi
 local candidates
 candidates=$(grep -E ".*-backup\.${BackupInstanceName}\.[0-9]{14}\.tar\.bz2\.aes256$" <<< "${lsOutput}")
 if [ -z "${candidates}" ]; then
  echo "  no backups found in gs://${GCSBucket}/"
  echo
  return
 fi
 # each --long line is "<size> <creation time> <url>"; the object name's timestamp is the chain's full backup,
 # not the upload time (daily uploads re-archive the whole chain under its full backup's timestamp)
 local latestFile="" latestCreated="" latestSize="" latestTs=""
 local size created url
 while read -r size created url; do
  if [[ "${created}" > "${latestCreated}" ]]; then
   latestCreated="${created}"
   latestFile="${url}"
   latestSize="${size}"
  fi
 done <<< "${candidates}"
 latestTs=$(basename "${latestFile}" | grep -oE '[0-9]{14}')
 local level
 level=$(basename "${latestFile}" | cut -d'-' -f1)
 echo "  last upload: ${level} backup, uploaded $(date -u -d "${latestCreated}" +"%Y-%m-%d %H:%M:%S UTC" 2>/dev/null || echo "${latestCreated}")"
 if [ "${latestSize}" -lt 1024 ] 2>/dev/null; then
  echo "  size:        ${RED}$(human-size "${latestSize}")${RESET} - suspiciously small, probably a broken upload"
 else
  echo "  size:        $(human-size "${latestSize}")"
 fi
 echo "  chain:       full backup ${latestTs} ($(format-backup-ts "${latestTs}"))"
 echo "  object:      ${latestFile}"
 echo
}

status-replication() {
 echo "${BOLD}${CYAN}Replication${RESET}"
 if ! command -v docker >/dev/null 2>&1; then
  echo "  cannot check (docker not found)"
  echo
  return
 fi
 if [ "${dbUp}" != true ]; then
  echo "  cannot check (database is down)"
  echo
  return
 fi
 local slaveStatus
 slaveStatus=$(docker exec "${DBContainerName}" mariadb -u"${DBUser}" -p"${DBPassword}" -e "SHOW SLAVE STATUS\G" 2>/dev/null)
 if [ -z "${slaveStatus}" ]; then
  echo "  not a replica"
  echo
  return
 fi
 local ioRunning sqlRunning masterLogFile readPos relayMasterLogFile execPos secondsBehind lastSqlErr lastIoErr
 ioRunning=$(slave-status-field "${slaveStatus}" "Slave_IO_Running")
 sqlRunning=$(slave-status-field "${slaveStatus}" "Slave_SQL_Running")
 masterLogFile=$(slave-status-field "${slaveStatus}" "Master_Log_File")
 readPos=$(slave-status-field "${slaveStatus}" "Read_Master_Log_Pos")
 relayMasterLogFile=$(slave-status-field "${slaveStatus}" "Relay_Master_Log_File")
 execPos=$(slave-status-field "${slaveStatus}" "Exec_Master_Log_Pos")
 secondsBehind=$(slave-status-field "${slaveStatus}" "Seconds_Behind_Master")
 lastSqlErr=$(slave-status-field "${slaveStatus}" "Last_SQL_Error")
 lastIoErr=$(slave-status-field "${slaveStatus}" "Last_IO_Error")
 echo "  role: replica"
 if [ "${ioRunning}" = "Yes" ] && [ "${sqlRunning}" = "Yes" ]; then
  echo "  status: ${GREEN}running${RESET} (IO=${ioRunning}, SQL=${sqlRunning})"
 else
  echo "  status: ${RED}NOT running${RESET} (IO=${ioRunning}, SQL=${sqlRunning})"
  echo "    -> run '${scriptName} restart-replication' to (re)start it"
 fi
 echo "  master log file:  ${masterLogFile} (read pos ${readPos})"
 echo "  relay master log: ${relayMasterLogFile} (exec pos ${execPos})"
 echo "  seconds behind master: ${secondsBehind}"
 if [ -n "${lastSqlErr}" ]; then
  echo "  last error: ${RED}${lastSqlErr}${RESET}"
 elif [ -n "${lastIoErr}" ]; then
  echo "  last error: ${RED}${lastIoErr}${RESET}"
 else
  echo "  last error: none"
 fi
 echo
}

status-disk-space() {
 echo "${BOLD}${CYAN}Disk space${RESET}"
 local label varName dir
 for varName in DBDataDir LocalBackupDir; do
  [ "${varName}" = "DBDataDir" ] && label="DB data dir:" || label="backup dir: "
  dir="${!varName}"
  if [ -z "${dir}" ]; then
   echo "  ${label} not configured (${varName} is empty)"
   continue
  fi
  local size avail usePct mount
  if ! read -r size avail usePct mount < <(df -h --output=size,avail,pcent,target "${dir}" 2>/dev/null | tail -n +2) || [ -z "${size}" ]; then
   echo "  ${label} ${RED}cannot determine${RESET} (does ${varName} exist?)"
   continue
  fi
  echo "  ${label} ${avail} free of ${size} (${usePct} used, volume mounted at ${mount})"
 done
 echo
}

# truncates stdin to maxLines lines of at most maxCols visible characters (color codes don't count towards the width)
limit-output() {
 awk -v maxLines="${1}" -v maxCols="${2}" -v reset="${RESET}" '
  function fit(line,   plain, out, visible, i, n, c, seq) {
   plain = line
   gsub(esc "\\[[0-9;]*[A-Za-z]|" esc "\\([A-Za-z0-9]", "", plain)
   if (length(plain) <= maxCols) return line
   out = ""; visible = 0; n = length(line); i = 1
   while (i <= n && visible < maxCols - 3) {
    c = substr(line, i, 1)
    if (c == esc) {
     seq = c; c = substr(line, ++i, 1); seq = seq c; i++
     if (c == "[") {
      while (i <= n && substr(line, i, 1) !~ /[A-Za-z]/) seq = seq substr(line, i++, 1)
      seq = seq substr(line, i++, 1)
     } else if (c == "(") {
      seq = seq substr(line, i++, 1)
     }
     out = out seq
     continue
    }
    out = out c; visible++; i++
   }
   return out "..." reset
  }
  BEGIN { esc = "\033" }
  NR < maxLines { print fit($0); fflush(); next }
  NR == maxLines { held = $0; next }
  { extra++ }
  END {
   if (extra) print "... (" extra + 1 " more lines not shown)"
   else if (NR >= maxLines) print fit(held)
  }'
}

restart-replication() {
 require-db-type
 require-tools docker
 require-vars DBContainerName DBUser DBPassword
 if ! docker exec "${DBContainerName}" mariadb -u"${DBUser}" -p"${DBPassword}" -e "SELECT 1" >/dev/null 2>&1; then
  log-line err "database is not up - run '${scriptName} db-start' first"
  return 1
 fi
 local slaveStatus
 slaveStatus=$(docker exec "${DBContainerName}" mariadb -u"${DBUser}" -p"${DBPassword}" -e "SHOW SLAVE STATUS\G" 2>/dev/null)
 if [ -z "${slaveStatus}" ]; then
  log-line err "not a replica (no SHOW SLAVE STATUS output) - nothing to restart"
  return 1
 fi
 log-line msg "=== RESTARTING REPLICATION ==="
 docker exec "${DBContainerName}" mariadb -u"${DBUser}" -p"${DBPassword}" -e "STOP SLAVE;" 2>/dev/null
 if ! docker exec "${DBContainerName}" mariadb -u"${DBUser}" -p"${DBPassword}" -e "START SLAVE;" 2>/dev/null; then
  log-line err "failed to issue START SLAVE"
  return 1
 fi
 check-replication-running
}

check-replication-running() {
 sleep 2
 local slaveStatus
 slaveStatus=$(docker exec "${DBContainerName}" mariadb -u"${DBUser}" -p"${DBPassword}" -e "SHOW SLAVE STATUS\G" 2>/dev/null)
 local ioRunning sqlRunning lastSqlErr lastIoErr
 ioRunning=$(slave-status-field "${slaveStatus}" "Slave_IO_Running")
 sqlRunning=$(slave-status-field "${slaveStatus}" "Slave_SQL_Running")
 lastSqlErr=$(slave-status-field "${slaveStatus}" "Last_SQL_Error")
 lastIoErr=$(slave-status-field "${slaveStatus}" "Last_IO_Error")
 if [ "${ioRunning}" = "Yes" ] && [ "${sqlRunning}" = "Yes" ]; then
  log-line msg "=== REPLICATION RUNNING (IO=${ioRunning}, SQL=${sqlRunning}) ==="
  return 0
 else
  log-line err "replication not running (IO=${ioRunning}, SQL=${sqlRunning})"
  [ -n "${lastSqlErr}" ] && log-line err "last SQL error: ${lastSqlErr}"
  [ -n "${lastIoErr}" ] && log-line err "last IO error: ${lastIoErr}"
  return 1
 fi
}

sql-escape() {
 local str="${1//\\/\\\\}"
 echo "${str//\'/\\\'}"
}

# prints "<binlog file> <position>" recorded by mariadb-backup in the restored datadir
read-restored-binlog-pos() {
 local infoName info
 for infoName in xtrabackup_info mariadb_backup_info; do
  info=$(docker run --rm -v "${DBDataDir}":/datadir:ro "${ALPINE_IMAGE}" cat "/datadir/${infoName}" 2>/dev/null) && break
  info=""
 done
 if [ -z "${info}" ]; then
  log-line err "neither xtrabackup_info nor mariadb_backup_info found in ${DBDataDir} - has the database been restored from a backup?" >&2
  log-line err "pass the coordinates explicitly: ${scriptName} start-replica <master-log-file> <master-log-pos>" >&2
  return 1
 fi
 local logFile logPos
 logFile=$(sed -nE "s/^binlog_pos *= *filename '([^']+)'.*/\1/p" <<< "${info}" | head -1)
 logPos=$(sed -nE "s/^binlog_pos *= *.*position '?([0-9]+)'?.*/\1/p" <<< "${info}" | head -1)
 if [ -z "${logFile}" ] || [ -z "${logPos}" ]; then
  log-line err "cannot parse binlog file/position from the binlog_pos line in ${DBDataDir}/${infoName}" >&2
  log-line err "pass the coordinates explicitly: ${scriptName} start-replica <master-log-file> <master-log-pos>" >&2
  return 1
 fi
 log-line msg "found binlog coordinates in ${DBDataDir}/${infoName}" >&2
 echo "${logFile} ${logPos}"
}

start-replica() {
 require-db-type
 require-tools docker
 require-vars DBContainerName DBUser DBPassword DBMasterHost DBMasterPort DBMasterUser DBMasterPassword
 local masterLogFile="${1}"
 local masterLogPos="${2}"
 if [ -n "${masterLogFile}" ] && [ -z "${masterLogPos}" ]; then
  log-line err "usage: ${scriptName} start-replica [<master-log-file> <master-log-pos>]"
  return 1
 fi
 if ! [[ "${DBMasterPort}" =~ ^[0-9]+$ ]]; then
  log-line err "DBMasterPort must be a number, got '${DBMasterPort}' (edit ${envFile})"
  return 1
 fi
 if ! docker exec "${DBContainerName}" mariadb -u"${DBUser}" -p"${DBPassword}" -e "SELECT 1" >/dev/null 2>&1; then
  log-line err "database is not up - run '${scriptName} db-start' first"
  return 1
 fi
 local slaveStatus
 slaveStatus=$(docker exec "${DBContainerName}" mariadb -u"${DBUser}" -p"${DBPassword}" -e "SHOW SLAVE STATUS\G" 2>/dev/null)
 if [ -n "${slaveStatus}" ]; then
  log-line err "already configured as a replica of $(slave-status-field "${slaveStatus}" "Master_Host") - use '${scriptName} restart-replication' instead"
  return 1
 fi
 if [ -z "${masterLogFile}" ]; then
  require-vars DBDataDir
  local binlogPos
  binlogPos=$(read-restored-binlog-pos) || return 1
  read -r masterLogFile masterLogPos <<< "${binlogPos}"
 fi
 if ! [[ "${masterLogFile}" =~ ^[A-Za-z0-9._-]+\.[0-9]+$ ]]; then
  log-line err "invalid master log file '${masterLogFile}' (expected e.g. mysql-bin.000123)"
  return 1
 fi
 if ! [[ "${masterLogPos}" =~ ^[0-9]+$ ]]; then
  log-line err "invalid master log position '${masterLogPos}' (expected a number)"
  return 1
 fi
 log-line msg "=== STARTING REPLICATION from ${DBMasterUser}@${DBMasterHost}:${DBMasterPort} at ${masterLogFile}:${masterLogPos} ==="
 local changeMasterSQL changeMasterOutput
 changeMasterSQL="CHANGE MASTER TO MASTER_HOST='$(sql-escape "${DBMasterHost}")', MASTER_PORT=${DBMasterPort},"
 changeMasterSQL+=" MASTER_USER='$(sql-escape "${DBMasterUser}")', MASTER_PASSWORD='$(sql-escape "${DBMasterPassword}")',"
 changeMasterSQL+=" MASTER_LOG_FILE='${masterLogFile}', MASTER_LOG_POS=${masterLogPos}, MASTER_USE_GTID=no;"
 if ! changeMasterOutput=$(docker exec "${DBContainerName}" mariadb -u"${DBUser}" -p"${DBPassword}" -e "${changeMasterSQL}" 2>&1); then
  log-line err "CHANGE MASTER TO failed: ${changeMasterOutput}"
  return 1
 fi
 if ! docker exec "${DBContainerName}" mariadb -u"${DBUser}" -p"${DBPassword}" -e "START SLAVE;" 2>/dev/null; then
  log-line err "failed to issue START SLAVE"
  return 1
 fi
 check-replication-running
}

status() {
 local dbUp=false
 {
  echo "${BOLD}=== bkp status (${BackupInstanceName}) ===${RESET}"
  echo
  status-tools
  status-db
  status-schedule
  status-local-backups
  status-replication
  status-disk-space
  # last, since it depends on the network and may take up to STATUS_CLOUD_TIMEOUT_SECONDS
  status-cloud-backups
 } | limit-output "${STATUS_MAX_LINES}" "${STATUS_MAX_COLUMNS}"
}
