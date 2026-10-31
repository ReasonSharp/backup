#!/bin/bash

stateFile="${LocalBackupDir}/.backup-state"

lockWeekly="${scriptDir}/weekly.lock"
lockDaily="${scriptDir}/daily.lock"
lockHourly="${scriptDir}/hourly.lock"
lockCloud="${scriptDir}/cloud.lock"

LOCK_FD_WEEKLY=200
LOCK_FD_DAILY=201
LOCK_FD_HOURLY=202
LOCK_FD_CLOUD=203
MASTER_BINLOG_START_NAME="master-binlog-start"
CHAIN_CLOSED_NAME=".closed"
BINLOGS_REPLAYED_NAME="bkp_binlogs_replayed"
RESTORED_BINLOG_POS_NAME="bkp_restored_binlog_pos"

ALPINE_IMAGE="alpine:3.22"
BINLOG_UTILITY_IMAGE="bash:5.2.21-alpine3.19"
DB_START_TIMEOUT_SECONDS=60
FULL_BACKUP_MAX_AGE_DAYS=8
FULL_BACKUP_MAX_AGE_SECONDS=$((FULL_BACKUP_MAX_AGE_DAYS * 86400))
BINLOG_PURGE_MAX_AGE_DAYS=14
STATUS_MAX_LINES=48
STATUS_MAX_COLUMNS=128
STATUS_CLOUD_TIMEOUT_SECONDS=5
ZSTD_LEVEL=3
CLOUD_MANIFEST_NAME=".cloud-manifest"
CLOUD_PIECE_SUFFIX=".tar.zst.aes256"
UPLOAD_PROGRESS_NAME="upload.progress"
DOWNLOAD_PROGRESS_NAME="download.progress"
PROGRESS_LOG_INTERVAL_SECONDS=300
PROGRESS_TTY_INTERVAL_SECONDS=30
PROGRESS_STALLED_SECONDS=60

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

# prints the backup stream in a full/ or inc_*/ dir: zstd-compressed, or plain if made by a bkp version before compression
stream-file() {
 local streamFile
 for streamFile in "${1}/backup.xbstream.zst" "${1}/backup.xbstream"; do
  if [ -f "${streamFile}" ]; then
   echo "${streamFile}"
   return 0
  fi
 done
 return 1
}

extract-xbstream() {
 local streamFile="${1}"
 local targetDir="${2}"
 log-line msg "extracting ${streamFile} ($(size-of "${streamFile}")) -> ${targetDir}"
 mkdir -p "${targetDir}"
 local readStream=(cat)
 [[ "${streamFile}" == *.zst ]] && readStream=(zstd -dcq)
 if ! (set -o pipefail
       "${readStream[@]}" "${streamFile}" | docker run --rm -i \
        -v "${targetDir}":/workdir \
        "${DBBackupImage}" sh -c 'cd /workdir && mbstream -x && chown -R '$(id -u)':'$(id -g)' /workdir'); then
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

# streams a zstd-compressed backup into <targetDir>/backup.xbstream.zst, and keeps a copy of its LSN metadata in
# <targetDir>/lsn so the next incremental can be based on it without unpacking the stream; an incremental is based
# on <incrementalBaseDir>
run-mariadb-backup() {
 local containerName="${1}"
 local targetDir="${2}"
 local incrementalBaseDir="${3}"
 local streamFile="${targetDir}/backup.xbstream.zst"
 local backupLog="${targetDir}/mariadb-backup.log"
 local remotePassword="${DBRemotePassword:-${DBPassword}}"
 local baseMountArgs=()
 local incrementalArg=""
 if [ -n "${incrementalBaseDir}" ]; then
  baseMountArgs=(-v "${incrementalBaseDir}":/base:ro)
  incrementalArg="--incremental-basedir=/base"
 fi
 # with DBBinlogSource=master, the backup also records the master's binlog coordinates (mariadb_backup_slave_info) that
 # point-in-time restore replays from, and hourly backups need to know which master binlog to start fetching from
 local slaveInfoArg=""
 local masterStartFile=""
 if [ "${DBBinlogSource}" = "master" ]; then
  slaveInfoArg="--slave-info"
  masterStartFile=$(slave-status-field "$(docker exec "${DBContainerName}" mariadb -u"${DBUser}" -p"${DBPassword}" -e "SHOW SLAVE STATUS\G" 2>/dev/null)" "Relay_Master_Log_File")
  if [ -z "${masterStartFile}" ]; then
   log-line wrn "DBBinlogSource=master, but ${DBContainerName} isn't replicating - this backup can't be used for point-in-time restore"
  fi
 fi
 mkdir -p "${targetDir}"
 docker run --rm --name "${containerName}" \
            --log-driver none \
            -e TZ=UTC \
            -v "${DBDataDir}":/var/lib/mysql:ro \
            "${baseMountArgs[@]}" \
            -v "${targetDir}":/backup:rw \
            "${dbNetworkArgs[@]}" \
            "${DBBackupImage}" \
            bash -c 'mariadb-backup --backup \
                                    --target-dir=/backup \
                                    --extra-lsndir=/backup/lsn \
                                    '"${incrementalArg}"' \
                                    '"${slaveInfoArg}"' \
                                    --stream=xbstream \
                                    --host="'"${DBHost}"'" \
                                    --port="'"${DBPort}"'" \
                                    --user="'"${DBUser}"'" \
                                    --password="'"${remotePassword}"'" \
                     && chown -R "'"$(id -u)":"$(id -g)"'" /backup' 2> "${backupLog}" \
  | zstd -T0 -"${ZSTD_LEVEL}" -q -c > "${streamFile}"
 local exitCodes=("${PIPESTATUS[@]}")
 if [ "${exitCodes[0]}" -ne 0 ]; then
  log-line err "mariadb-backup failed with code ${exitCodes[0]}:"
  log-tail "${backupLog}"
  return 1
 fi
 if [ "${exitCodes[1]}" -ne 0 ]; then
  log-line err "compressing the backup stream into ${streamFile} failed (out of space on that volume?)"
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
 [ -n "${masterStartFile}" ] && echo "${masterStartFile}" > "${targetDir}/${MASTER_BINLOG_START_NAME}"
 log-line msg "backup file successfully created at ${streamFile} ($(size-of "${streamFile}"))"
}

bkp-db-weekly() {
 require-db-type
 require-vars DBHost DBPort DBUser DBPassword DBDataDir DBBackupImage
 require-tools docker flock pgrep tar zstd openssl gcloud
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
  if [[ -n "${prevBkp}" ]] && [ -f "${LocalBackupDir}/${prevBkp}/${CHAIN_CLOSED_NAME}" ]; then
   log-line msg "previous backup chain (${prevBkp}) was closed by a restore - nothing appended to it"
  elif [[ -n "${prevBkp}" ]]; then
   release-lock "${lockWeekly}" "${LOCK_FD_WEEKLY}"
   bkp-db-daily "${prevBkp}"
   if [ "${?}" -gt 0 ]; then
    log-line err "failed to append previous week - please run '${scriptName} bkp-db-daily \"${prevBkp}\"' manually"
    exit 1
   fi
   release-lock "${lockDaily}" "${LOCK_FD_DAILY}"
   # missing the last binlogs only limits point-in-time restore of the previous week's last hours, so unlike a missing
   # incremental, it doesn't stop the rollover
   if ! bkp-db-hourly "${prevBkp}"; then
    log-line wrn "couldn't append the last binlogs to previous week's backups - point-in-time restore of its last hours may not be possible"
   fi
   log-line msg "appended daily incremental and binlogs to previous backup archive (${prevBkp}) - ready for sending to cloud"
  else
   log-line msg "no previous full backup found - skipped daily incremental and binlog append"
  fi
  lastFullTs="${ts}"
  lastIncTs=""
  save-state
  # uploads can take hours - let daily and hourly backups run in the meantime
  release-lock "${lockWeekly}" "${LOCK_FD_WEEKLY}"
  local result=0
  if [[ -n "${prevBkp}" ]]; then
   if bkp-to-cloud "${prevBkp}"; then
    rm -rf "${LocalBackupDir:?}/${prevBkp}"
    log-line msg "previous week's backups are all in cloud - removed their local copy (${LocalBackupDir}/${prevBkp})"
   else
    log-line wrn "couldn't upload previous week's backups to cloud - keeping them locally (${LocalBackupDir}/${prevBkp})"
    result=1
   fi
  fi
  if ! bkp-to-cloud "${ts}"; then
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
 require-tools docker flock pgrep tar zstd openssl gcloud
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
 if ! stream-file "${bkpRoot}/full" >/dev/null; then
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
  local baseStream
  if ! baseStream=$(stream-file "${lastFullDir}"); then
   log-line err "no backup stream found in ${lastFullDir}, so it's a broken backup"
   log-line err "move ${lastFullDir} out of ${bkpRoot}, so the next daily backup is based on the backup before it"
   return 1
  fi
  extractDir=$(make-work-dir) || return 1
  if ! extract-xbstream "${baseStream}" "${extractDir}"; then
   remove-extracted "${extractDir}"
   return 1
  fi
  incBaseDir="${extractDir}"
  if ! has-lsn-metadata "${incBaseDir}"; then
   log-line err "${baseStream} contains no LSN metadata, so it's probably a broken backup"
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
  if [[ -z "${1}" ]]; then
   # the upload can take a while - let hourly backups run in the meantime
   release-lock "${lockDaily}" ${LOCK_FD_DAILY}
   if ! bkp-to-cloud "${fullTs}"; then
    log-line wrn "couldn't upload backup chain ${fullTs} to cloud (${LocalBackupDir}/${fullTs})"
    result=1
   fi
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
require-binlog-source() {
 require-vars DBContainerName DBUser DBPassword
 case "${DBBinlogSource}" in
  local)  require-vars DBDataDir DBBinlogBasename;;
  master) require-vars DBMasterHost DBMasterPort DBMasterUser DBMasterPassword DBBackupImage;;
  *)
   log-line err "unknown DBBinlogSource '${DBBinlogSource}' - use 'local' or 'master' (edit ${envFile})"
   exit 1;;
 esac
}

# prints why the database's own binlogs can't be used for point-in-time restore - nothing if they can, or if the
# database isn't up to check
local-binlog-problem() {
 local settings
 settings=$(docker exec "${DBContainerName}" mariadb -u"${DBUser}" -p"${DBPassword}" -N -B \
             -e "SELECT CONCAT_WS('|', IF(@@log_bin, 1, 0), IFNULL(@@log_bin_basename, ''), IF(@@log_slave_updates, 1, 0))" 2>/dev/null) || return 0
 local logBin binlogPath slaveUpdates
 IFS='|' read -r logBin binlogPath slaveUpdates <<< "${settings}"
 local binlogName
 binlogName=$(basename "${binlogPath}")
 if [ "${logBin}" != "1" ]; then
  echo "${DBContainerName} doesn't write a binlog (log_bin=0) - enable log_bin, or if it's a replica, set DBBinlogSource=master"
 elif [ "${binlogName}" != "${DBBinlogBasename}" ]; then
  echo "DBBinlogBasename is '${DBBinlogBasename}', but ${DBContainerName}'s binlog is '${binlogName}' - set DBBinlogBasename=\"${binlogName}\""
 elif [ "${slaveUpdates}" != "1" ] \
      && [ -n "$(docker exec "${DBContainerName}" mariadb -u"${DBUser}" -p"${DBPassword}" -e "SHOW SLAVE STATUS\G" 2>/dev/null)" ]; then
  echo "${DBContainerName} is a replica without log_slave_updates, so its binlog lacks the replicated changes - enable log_slave_updates, or set DBBinlogSource=master"
 fi
}

copy-local-binlogs() {
 local fullTs="${1}"
 local binlogDir="${2}"
 local problem
 problem=$(local-binlog-problem)
 if [ -n "${problem}" ]; then
  log-line err "binlogs can't be used for point-in-time restore: ${problem}"
  return 1
 fi
 log-line msg "archiving binlogs newer than ${fullTs}"
 local sinceEpoch
 sinceEpoch=$(date -u -d "${fullTs:0:4}-${fullTs:4:2}-${fullTs:6:2} ${fullTs:8:2}:${fullTs:10:2}:${fullTs:12:2}" +%s 2>/dev/null || echo 0)
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
                                                cp -p "${f}" /target/ || exit 1
                                               done
                                               chown '$(id -u)':'$(id -g)' "/target/"*'; then
  log-line msg "binlogs successfully copied to ${binlogDir}/ ($(size-of "${binlogDir}") in total)"
 else
  log-line err "copying binlogs failed"
  return 1
 fi
}

fetch-master-binlogs() {
 local chainDir="${1}"
 local binlogDir="${2}"
 # the earliest master binlog any backup of this chain starts in
 local startFile
 startFile=$(cat "${chainDir}/mariadb/full/${MASTER_BINLOG_START_NAME}" "${chainDir}"/mariadb/inc_*/"${MASTER_BINLOG_START_NAME}" 2>/dev/null \
              | sort | head -1)
 if [ -z "${startFile}" ]; then
  log-line wrn "no backup of chain $(basename "${chainDir}") recorded where it is in the master's binlogs (made by an older bkp version, or not with DBBinlogSource=master)"
  log-line wrn "nothing to fetch - point-in-time restore becomes possible from the next daily or weekly backup on"
  return 0
 fi
 # the newest binlog fetched so far may have grown since, so fetching resumes from it
 local fetched
 fetched=$(ls "${binlogDir}" 2>/dev/null | grep -E "^${startFile%.*}\.[0-9]+$" | sort | tail -1)
 [[ -n "${fetched}" ]] && [[ "${fetched}" > "${startFile}" ]] && startFile="${fetched}"
 log-line msg "fetching the master's binlogs from ${startFile} on, from ${DBMasterHost}:${DBMasterPort}"
 local fetchLog="${binlogDir}/.fetch.log"
 if ! docker run --rm "${dbNetworkArgs[@]}" -e TZ=UTC \
               -v "${binlogDir}":/target \
               "${DBBackupImage}" bash -c 'cd /target \
                                           && mariadb-binlog --read-from-remote-server --raw --to-last-log \
                                                             --host="'"${DBMasterHost}"'" --port="'"${DBMasterPort}"'" \
                                                             --user="'"${DBMasterUser}"'" --password="'"${DBMasterPassword}"'" \
                                                             "'"${startFile}"'" \
                                           && chown '$(id -u)':'$(id -g)' /target/*' 2> "${fetchLog}"; then
  log-line err "fetching the master's binlogs failed:"
  log-tail "${fetchLog}"
  rm -f "${fetchLog}"
  return 1
 fi
 rm -f "${fetchLog}"
 log-line msg "master's binlogs successfully fetched to ${binlogDir}/ ($(size-of "${binlogDir}") in total)"
}

bkp-db-hourly() {
 require-db-type
 require-binlog-source
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
 local binlogDir="${LocalBackupDir}/${fullTs}/mariadb/binlogs"
 mkdir -p "${binlogDir}"
 local result=0
 if [ "${DBBinlogSource}" = "master" ]; then
  fetch-master-binlogs "${LocalBackupDir}/${fullTs}" "${binlogDir}" || result=1
 else
  copy-local-binlogs "${fullTs}" "${binlogDir}" || result=1
 fi
 if [ ${result} -ne 0 ]; then
  log-line err "hourly backup failed"
  return 1
 fi
 purge-old-binlogs
 log-line msg "=== HOURLY BACKUP COMPLETED ==="
}

###################################################################################################
######################################## RESTORE DATABASE #########################################
###################################################################################################

# prints "<coordinates> <start position> <binlog file>..." to replay on top of the prepared backup in <backupDir>, from
# the binlogs saved in <binlogDir>: the master's binlogs (coordinates "master") if the backup was made on a replica
# with DBBinlogSource=master (so a master can be restored from a replica's backup too), or the server's own binlogs
# (coordinates "own") otherwise; reasons it can't are logged at <level> (default err)
plan-binlog-replay() {
 local backupDir="${1}"
 local binlogDir="${2}"
 local level="${3:-err}"
 local positions=() kinds=()
 local info
 info=$(cat "${backupDir}/mariadb_backup_slave_info" "${backupDir}/xtrabackup_slave_info" 2>/dev/null)
 if [ -n "${info}" ]; then
  positions+=("$(sed -nE "s/.*MASTER_LOG_FILE *= *'([^']+)'.*MASTER_LOG_POS *= *([0-9]+).*/\1 \2/Ip" <<< "${info}" | head -1)")
  kinds+=("master")
 fi
 info=$(cat "${backupDir}/mariadb_backup_binlog_info" "${backupDir}/xtrabackup_binlog_info" 2>/dev/null | head -1)
 if [ -n "${info}" ]; then
  positions+=("$(awk '{ print $1, $2 }' <<< "${info}")")
  kinds+=("own")
 fi
 local i startFile="" startPos="" coordinates="" triedFiles=""
 for ((i=0; i<${#positions[@]}; i++)); do
  read -r startFile startPos <<< "${positions[i]}"
  coordinates="${kinds[i]}"
  [ -n "${startFile}" ] && [ -n "${startPos}" ] && [ -f "${binlogDir}/${startFile}" ] && break
  triedFiles+=" ${startFile}"
  startFile=""
 done
 if [ -z "${startFile}" ]; then
  if [ -z "${triedFiles// /}" ]; then
   log-line "${level}" "the backup didn't record a binlog position - it was made on a server without a binlog, and not with DBBinlogSource=master" >&2
  else
   log-line "${level}" "the binlog the backup ends in (${triedFiles# }) wasn't saved in ${binlogDir}" >&2
  fi
  return 1
 fi
 # every binlog from the start file on, without gaps
 local baseName="${startFile%.*}"
 local startNumber="${startFile##*.}"
 local expected=$((10#${startNumber}))
 local files=()
 local path name
 for path in "${binlogDir}/${baseName}".*; do
  name=$(basename "${path}")
  [[ "${name}" =~ ^.+\.[0-9]+$ ]] || continue
  [[ "${name}" < "${startFile}" ]] && continue
  if [ $((10#${name##*.})) -ne ${expected} ]; then
   log-line "${level}" "$(printf "%s.%0${#startNumber}d" "${baseName}" "${expected}") is missing from ${binlogDir}" >&2
   return 1
  fi
  files+=("${name}")
  expected=$((expected + 1))
 done
 echo "${coordinates} ${startPos} ${files[*]}"
}

# finds where replaying the binlogs in <pitrDir> (from <start position> in the first one) has to end, so it ends
# between two transactions: before the first one that started at or after <target> (yyyyMMddHHmmss, UTC; empty means
# replay everything); prints "<index of the last file to replay> <stop position in it, 0 for its end> <binlog file>
# <position>" the replay ends at, in the binlogs' own coordinates, and "<time of the last replayed event>"
find-replay-end() {
 local pitrDir="${1}"
 local startPos="${2}"
 local targetTs="${3}"
 shift 3
 # one file at a time, since mariadb-binlog doesn't mark where one file ends and the next begins
 docker run --rm -e TZ=UTC -v "${pitrDir}":/pitr:ro "${DBBackupImage}" bash -c '
  startPos="${1}"; shift
  for file in "${@}"; do
   echo "@@FILE ${file}"
   mariadb-binlog --no-defaults --base64-output=decode-rows --start-position="${startPos}" "/pitr/${file}" || exit 1
   startPos=4
  done' _ "${startPos}" "${@}" \
  | awk -v target="${targetTs}" -v endFile="${1}" -v endPos="${startPos}" '
   found { next }
   /^@@FILE / { file = $2; fileIndex++; next }
   /^# at [0-9]+$/ { at = $3; next }
   /^#[0-9][0-9][0-9][0-9][0-9][0-9] +[0-9]+:[0-9][0-9]:[0-9][0-9] server id / {
    split($2, t, ":")
    ts = sprintf("20%s%02d%s%s", substr($1, 2), t[1], t[2], t[3])
    # every transaction starts with a GTID event
    if (target != "" && index($0, "\tGTID ") && ts >= target) {
     printf "%d %d %s %d %s\n", fileIndex - 1, at, file, at, lastTs
     found = 1
     next
    }
    lastTs = ts
    for (i = 1; i < NF; i++) if ($i == "end_log_pos" && $(i + 1) > 0) { endFile = file; endPos = $(i + 1) }
    if (match($0, /\tRotate to [^ ]+ +pos: [0-9]+/)) { split(substr($0, RSTART + 11), r, " "); endFile = r[1]; endPos = r[3] }
   }
   END { if (!found) printf "%d 0 %s %d %s\n", fileIndex - 1, endFile, endPos, lastTs }'
 local status=("${PIPESTATUS[@]}")
 [ "${status[0]}" -eq 0 ] && [ "${status[1]}" -eq 0 ]
}

# yyyyMMddHHmmss -> yyyy-MM-dd HH:mm:ss
format-ts() {
 local ts="${1}"
 echo "${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:8:2}:${ts:10:2}:${ts:12:2}"
}

# writes stdin to <name> in ${DBDataDir}
write-datadir-file() {
 docker run --rm -i -v "${DBDataDir}":/datadir "${ALPINE_IMAGE}" sh -c 'cat > "/datadir/${1}"' _ "${1}"
}

read-datadir-file() {
 docker run --rm -v "${DBDataDir}":/datadir:ro "${ALPINE_IMAGE}" cat "/datadir/${1}" 2>/dev/null
}

# prints the value of <key> in the "key=value" lines of <content>
value-of-key() {
 sed -n "s/^${2}=//p" <<< "${1}" | head -1
}

# replays <binlogPlan> (from plan-binlog-replay) up to <targetDatetimeStr> (UTC; empty replays every saved binlog),
# then records in BINLOGS_REPLAYED_NAME where in those binlogs the replay ended, for start-replica
apply-binlogs() {
 local binlogPlan="${1}"
 local binlogDir="${2}"
 local targetDatetimeStr="${3}"
 local coordinates startPos
 local files=()
 read -r coordinates startPos _ <<< "${binlogPlan}"
 read -r -a files <<< "$(cut -d' ' -f3- <<< "${binlogPlan}")"
 local pitrDir
 if ! pitrDir=$(make-work-dir); then
  log-line err "binlogs not applied"
  return 1
 fi
 local file
 for file in "${files[@]}"; do
  if ! cp "${binlogDir}/${file}" "${pitrDir}/"; then
   log-line err "failed to copy ${binlogDir}/${file} to ${pitrDir} - binlogs not applied"
   rm -rf "${pitrDir}"
   return 1
  fi
 done
 local targetTs=""
 [ -n "${targetDatetimeStr}" ] && targetTs=$(date -u -d "${targetDatetimeStr}" +"%Y%m%d%H%M%S")
 local replayEnd lastIndex stopPos endFile endPos lastEventTs
 if ! replayEnd=$(find-replay-end "${pitrDir}" "${startPos}" "${targetTs}" "${files[@]}") || [ -z "${replayEnd}" ]; then
  log-line err "failed to read the binlogs copied to ${pitrDir} - binlogs not applied"
  rm -rf "${pitrDir}"
  return 1
 fi
 read -r lastIndex stopPos endFile endPos lastEventTs <<< "${replayEnd}"
 local reachedDatetime
 if [ "${stopPos}" -gt 0 ]; then
  reachedDatetime="${targetDatetimeStr}"
 else
  reachedDatetime=$(format-ts "${lastEventTs}")
  if [ -n "${targetTs}" ] && [[ "${lastEventTs}" < "${targetTs}" ]]; then
   log-line wrn "the saved binlogs only reach ${reachedDatetime} UTC - the database can only be brought forward to then, not to ${targetDatetimeStr} UTC"
  fi
 fi
 files=("${files[@]:0:lastIndex+1}")
 local result=0
 if [ "${lastIndex}" -eq 0 ] && [ "${stopPos}" -gt 0 ] && [ "${stopPos}" -le "${startPos}" ]; then
  log-line msg "no transactions between the end of the backup and ${targetDatetimeStr} UTC - no binlogs to replay"
 else
  log-line msg "replaying ${#files[@]} binlog(s) from ${files[0]}:${startPos} to ${endFile}:${endPos} (up to ${reachedDatetime} UTC)..."
  local fileArgs="" stopArg=""
  for file in "${files[@]}"; do
   fileArgs+=" \"/pitr/${file}\""
  done
  # --stop-position applies to the last file; stopping where a transaction starts never leaves half of one applied
  [ "${stopPos}" -gt 0 ] && stopArg=" --stop-position=${stopPos}"
  # --disable-log-bin: the replayed transactions don't go into this server's binlog, so its binlog position after the
  # restore is where it starts writing new transactions (see record-restored-binlog-pos)
  cat > "${pitrDir}/import-script.sh" <<IMPORT
#!/bin/bash
set -o pipefail
TZ=UTC mariadb-binlog --no-defaults --disable-log-bin --set-charset=utf8mb4 --start-position="${startPos}"${stopArg}${fileArgs} \\
 | mariadb -u"${DBUser}" -p"${DBPassword}"
IMPORT
  chmod +x "${pitrDir}/import-script.sh"
  docker exec "${DBContainerName}" rm -rf /pitr
  if ! docker cp "${pitrDir}" "${DBContainerName}:/pitr" >/dev/null; then
   log-line err "failed to copy binlogs into ${DBContainerName} - binlogs not applied"
   result=1
  elif ! docker exec "${DBContainerName}" /pitr/import-script.sh; then
   log-line err "replaying binlogs failed - the database is restored to the end of the backup, plus whatever was replayed before the error"
   result=1
  else
   log-line msg "binlogs replayed up to ${reachedDatetime} UTC"
  fi
  docker exec "${DBContainerName}" rm -rf /pitr
 fi
 rm -rf "${pitrDir}"
 [ ${result} -ne 0 ] && return ${result}
 # the position the backup recorded is out of date now - start-replica resumes from where the replay ended instead
 printf "replayed_to=%s\ncoordinates=%s\nend_file=%s\nend_pos=%s\n" "${reachedDatetime}" "${coordinates}" "${endFile}" "${endPos}" \
  | write-datadir-file "${BINLOGS_REPLAYED_NAME}"
 # only worth mentioning on a replica: a master restored from a replica's backup replays the same binlogs
 if [ "${coordinates}" = "master" ] && [ -n "${DBMasterHost}" ]; then
  log-line msg "if the master wasn't restored, '${scriptName} start-replica' resumes replicating where the replay ended (${endFile}:${endPos})"
  log-line msg "if it was restored the same way, start replicating with the position its restore logged: ${scriptName} start-replica <file> <pos>"
 fi
}

# records this server's own binlog position right after a restore in RESTORED_BINLOG_POS_NAME (replayed binlogs don't
# go into it): a replica restored the same way starts replicating from this server there
record-restored-binlog-pos() {
 local masterStatus logFile logPos
 masterStatus=$(docker exec "${DBContainerName}" mariadb -u"${DBUser}" -p"${DBPassword}" -N -B -e "SHOW MASTER STATUS" 2>/dev/null)
 read -r logFile logPos _ <<< "${masterStatus}"
 if [ -z "${logFile}" ] || [ -z "${logPos}" ]; then
  return 0
 fi
 printf "restored_at=%s\nfile=%s\npos=%s\n" "$(date -u +"%Y-%m-%d %H:%M:%S")" "${logFile}" "${logPos}" \
  | write-datadir-file "${RESTORED_BINLOG_POS_NAME}"
 log-line msg "binlog position after the restore: ${logFile}:${logPos} - replicas restored with the same command start replicating from here with:"
 log-line msg "  ${scriptName} start-replica ${logFile} ${logPos}"
}

# the restored database no longer continues from the LSNs the local backup chains end in, so the next backup has to
# be a full one, and no chain can have an incremental appended at the next weekly rollover
close-backup-chains() {
 local chainDir
 for chainDir in "${LocalBackupDir}"/[0-9]*; do
  [ -d "${chainDir}" ] && touch "${chainDir}/${CHAIN_CLOSED_NAME}"
 done
 lastFullTs=""
 lastIncTs=""
 save-state
 log-line msg "the next backup will be a full one, starting a new backup chain"
}

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
 log-line msg "backup chain consistent as of: ${backupEndDatetime} UTC"
 local binlogDir="${LocalBackupDir}/${ts}/mariadb/binlogs"
 local binlogPlan=""
 if [ "${isPITR}" = "1" ]; then
  if [[ "${backupEndDatetime}" < "${targetDatetimeStr}" ]] && ! binlogPlan=$(plan-binlog-replay "${restoreDBDir}/base" "${binlogDir}"); then
   log-line err "can't replay binlogs from the end of the backup (${backupEndDatetime} UTC) to ${targetDatetimeStr} UTC - the database was left untouched"
   return 1
  fi
 elif [ -z "$(ls -A "${binlogDir}" 2>/dev/null)" ]; then
  log-line msg "no binlogs saved after the backup - restoring to the end of the backup (${backupEndDatetime} UTC)"
 elif ! binlogPlan=$(plan-binlog-replay "${restoreDBDir}/base" "${binlogDir}" wrn); then
  log-line wrn "the saved binlogs can't be replayed - restoring to the end of the backup (${backupEndDatetime} UTC)"
 fi
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
 # in case a backup made after an earlier restore carried them along
 docker run --rm -v "${DBDataDir}":/datadir "${ALPINE_IMAGE}" \
  rm -f "/datadir/${BINLOGS_REPLAYED_NAME}" "/datadir/${RESTORED_BINLOG_POS_NAME}"
 close-backup-chains
 log-line msg "starting MariaDB container..."
 docker start "${DBContainerName}"
 wait-for-db "${DBContainerName}" "${DBUser}" "${DBPassword}"
 if [ -n "${binlogPlan}" ]; then
  apply-binlogs "${binlogPlan}" "${binlogDir}" "${targetDatetimeStr}" || return 1
 elif [ "${isPITR}" = "1" ]; then
  log-line msg "target time (${targetDatetimeStr} UTC) is not after backup end time (${backupEndDatetime} UTC) -> no binlog apply needed"
 fi
 record-restored-binlog-pos
 log-line msg "=== RESTORE COMPLETED successfully ==="
}

restore-db-local() {
 require-db-type
 require-vars DBDataDir DBContainerName DBPassword DBBackupImage DBBinlogBasename
 require-tools docker zstd
 local ts="${1}"
 local targetDatetimeStr="${2}"
 if [ -z "${ts}" ]; then
  log-line err "usage: ${scriptName} restore-db-local <timestamp> [target-datetime]"
  return 1
 fi
 local isPITR=0
 local targetTs="99999999999999"
 if [ -n "${targetDatetimeStr}" ]; then
  if ! date -u -d "${targetDatetimeStr}" >/dev/null 2>&1; then
   log-line err "invalid datetime format for ${targetDatetimeStr} (use yyyy-MM-dd HH:mm:ss)"
   return 1
  fi
  targetTs=$(date -u -d "${targetDatetimeStr}" +"%Y%m%d%H%M%S")
  targetDatetimeStr=$(date -u -d "${targetDatetimeStr}" +"%Y-%m-%d %H:%M:%S")
  isPITR=1
  log-line msg "=== POINT-IN-TIME RESTORE to ${targetDatetimeStr} UTC ==="
 else
  log-line msg "=== RESTORE to the latest point the backup chain reaches ==="
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
 local fullStream
 if ! fullStream=$(stream-file "${selectedFullDir}"); then
  log-line err "no backup stream found in ${selectedFullDir}"
  return 1
 fi
 if ! extract-xbstream "${fullStream}" "${restoreDBDir}/base"; then
  remove-extracted "${restoreDBDir}"
  return 1
 fi
 local i
 for ((i=0; i<${#selectedIncDirs[@]}; i++)); do
  local incStream
  if ! incStream=$(stream-file "${selectedIncDirs[i]}") || ! extract-xbstream "${incStream}" "${restoreDBDir}/_inc_${i}"; then
   [ -z "${incStream}" ] && log-line err "no backup stream found in ${selectedIncDirs[i]}"
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

# each backup chain is uploaded piece by piece to gs://${GCSBucket}/${BackupInstanceName}/<chain timestamp>/, one
# object per piece, so a daily upload only sends what's new: the full backup and each incremental once, binlogs once
# they stop changing, and the backed up folders whenever they change

# pieces of a backup chain, relative to the chain dir
list-chain-pieces() {
 local chainDir="${1}"
 local path
 [ -d "${chainDir}/mariadb/full" ] && echo "mariadb/full"
 for path in "${chainDir}"/mariadb/inc_*; do
  [ -d "${path}" ] && echo "mariadb/$(basename "${path}")"
 done
 for path in "${chainDir}"/mariadb/binlogs/*; do
  [ -f "${path}" ] && echo "mariadb/binlogs/$(basename "${path}")"
 done
 [ -d "${chainDir}/files" ] && echo "files"
}
# changes whenever a file in the piece is added, removed, resized or modified
piece-fingerprint() {
 (cd "${1}" && find "${2}" -type f -printf '%p %s %T@\n' | sort | md5sum | cut -d' ' -f1)
}
uploaded-fingerprint() {
 awk -v piece="${2}" '$1 == piece { print $2 }' "${1}/${CLOUD_MANIFEST_NAME}" 2>/dev/null
}
record-uploaded-piece() {
 local manifest="${1}/${CLOUD_MANIFEST_NAME}"
 { awk -v piece="${2}" '$1 != piece' "${manifest}" 2>/dev/null; echo "${2} ${3}"; } > "${manifest}.new" && mv "${manifest}.new" "${manifest}"
}
cloud-chain-url() {
 echo "gs://${GCSBucket}/${BackupInstanceName}/${1}"
}

# a cloud transfer (upload or download) keeps its progress in ${scriptDir}/<progress file> as key=value lines, rewritten
# at the start of each piece, while dd counts the bytes of the current piece that went through the pipeline so far
# into <progress file>.bytes; the file stays behind if the transfer is killed, which status reports

# writes <key=value>... to <progress file>
write-progress() {
 local progressFile="${1}"
 shift
 printf "%s\n" "${@}" > "${progressFile}.new" && mv "${progressFile}.new" "${progressFile}"
}

# a pipeline stage that passes its input through, counting the bytes into <counter file> about once a second
count-bytes() {
 LC_ALL=C dd bs=1M status=progress 2> "${1}"
}

counted-bytes() {
 local bytes
 bytes=$(tr '\r' '\n' < "${1}" 2>/dev/null | sed -nE 's/^([0-9]+) bytes.*/\1/p' | tail -1)
 echo "${bytes:-0}"
}

format-duration() {
 local seconds="${1}"
 if [ "${seconds}" -ge 3600 ]; then
  echo "$((seconds / 3600))h$((seconds % 3600 / 60))m"
 elif [ "${seconds}" -ge 60 ]; then
  echo "$((seconds / 60))m$((seconds % 60))s"
 else
  echo "${seconds}s"
 fi
}

# <part> of <whole>, as a percentage
percent-of() {
 if [ "${2}" -gt 0 ]; then
  echo "$(( ${1} * 100 / ${2} ))%"
 else
  echo "100%"
 fi
}

# prints "<direction> <chain> <piece number> <pieces> <piece> <piece bytes done> <piece bytes> <bytes done>
# <total bytes> <bytes per second> <seconds left, -1 if unknown> <failed pieces> <time of the last progress, epoch>
# <pid>" for the transfer in <progress file>, or fails if there's none
transfer-progress() {
 local progressFile="${1}"
 local progress
 progress=$(cat "${progressFile}" 2>/dev/null)
 [ -n "${progress}" ] || return 1
 local pieceBytes doneBytes totalBytes started
 pieceBytes=$(value-of-key "${progress}" piece_bytes)
 doneBytes=$(value-of-key "${progress}" done_bytes)
 totalBytes=$(value-of-key "${progress}" total_bytes)
 started=$(value-of-key "${progress}" started)
 local pieceDone
 pieceDone=$(counted-bytes "${progressFile}.bytes")
 # an upload is measured against the size of the piece's files, and its encrypted stream can be a bit larger (or, for
 # compressible files, much smaller)
 [ "${pieceDone}" -gt "${pieceBytes}" ] && pieceDone="${pieceBytes}"
 local bytesDone=$((doneBytes + pieceDone))
 local lastProgress
 lastProgress=$(stat -c %Y "${progressFile}.bytes" 2>/dev/null || stat -c %Y "${progressFile}")
 local elapsed=$((lastProgress - started))
 [ ${elapsed} -lt 1 ] && elapsed=1
 local rate=$((bytesDone / elapsed))
 local secondsLeft=-1
 [ ${rate} -gt 0 ] && secondsLeft=$(((totalBytes - bytesDone) / rate))
 echo "$(value-of-key "${progress}" direction) $(value-of-key "${progress}" chain)" \
      "$(value-of-key "${progress}" piece_number) $(value-of-key "${progress}" pieces) $(value-of-key "${progress}" piece)" \
      "${pieceDone} ${pieceBytes} ${bytesDone} ${totalBytes} ${rate} ${secondsLeft}" \
      "$(value-of-key "${progress}" failed) ${lastProgress} $(value-of-key "${progress}" pid)"
}

# whether the bkp process <pid> is still running
bkp-running() {
 [ -n "${1}" ] && tr '\0' ' ' 2>/dev/null < "/proc/${1}/cmdline" | grep -qF "${scriptName}"
}

# a one-line summary of the transfer in <progress file>, for the log
progress-log-line() {
 local fields
 fields=$(transfer-progress "${1}") || return 1
 local direction chain pieceNumber pieces piece pieceDone pieceBytes bytesDone totalBytes rate secondsLeft failed lastProgress pid
 read -r direction chain pieceNumber pieces piece pieceDone pieceBytes bytesDone totalBytes rate secondsLeft failed lastProgress pid <<< "${fields}"
 local line="${direction} progress: piece ${pieceNumber} of ${pieces} (${piece}) $(human-size "${pieceDone}") of $(human-size "${pieceBytes}")"
 line+=" ($(percent-of "${pieceDone}" "${pieceBytes}")), total $(human-size "${bytesDone}") of $(human-size "${totalBytes}")"
 line+=" ($(percent-of "${bytesDone}" "${totalBytes}")), $(human-size "${rate}")/s"
 local idle=$(($(date +%s) - lastProgress))
 if [ ${idle} -ge ${PROGRESS_STALLED_SECONDS} ]; then
  line+=" - no progress for $(format-duration "${idle}")"
 elif [ "${secondsLeft}" -ge 0 ]; then
  line+=", about $(format-duration "${secondsLeft}") left"
 fi
 echo "${line}"
}

# logs the progress of the transfer in <progress file> every PROGRESS_LOG_INTERVAL_SECONDS (more often on a terminal),
# in the background, until stop-progress-monitor; stops by itself if bkp is gone
start-progress-monitor() {
 local progressFile="${1}"
 local interval=${PROGRESS_LOG_INTERVAL_SECONDS}
 [ -t 1 ] && interval=${PROGRESS_TTY_INTERVAL_SECONDS}
 local bkpPid=$$
 (
  waited=0
  while sleep 5 && [ -d "/proc/${bkpPid}" ]; do
   waited=$((waited + 5))
   if [ ${waited} -ge ${interval} ]; then
    waited=0
    progress-log-line "${progressFile}" | while IFS= read -r line; do log-line msg "${line}"; done
   fi
  done
 ) &
 progressMonitorPid=$!
}

stop-progress-monitor() {
 [ -n "${progressMonitorPid}" ] || return 0
 kill "${progressMonitorPid}" 2>/dev/null
 wait "${progressMonitorPid}" 2>/dev/null
 progressMonitorPid=""
}

# prints the progress of the transfer in <progress file> for status, or fails if there's none
show-transfer-progress() {
 local fields
 fields=$(transfer-progress "${1}") || return 1
 local direction chain pieceNumber pieces piece pieceDone pieceBytes bytesDone totalBytes rate secondsLeft failed lastProgress pid
 read -r direction chain pieceNumber pieces piece pieceDone pieceBytes bytesDone totalBytes rate secondsLeft failed lastProgress pid <<< "${fields}"
 if ! bkp-running "${pid}"; then
  echo "  no ${direction} running - the last one, of chain ${chain}, was ${RED}interrupted${RESET}"
  echo "    in piece ${pieceNumber} of ${pieces}, after $(human-size "${bytesDone}") of $(human-size "${totalBytes}") ($(percent-of "${bytesDone}" "${totalBytes}"))," \
       "last progress at $(date -u -d "@${lastProgress}" +"%Y-%m-%d %H:%M:%S") UTC"
  if [ "${direction}" = "upload" ]; then
   echo "    -> the pieces it didn't upload are uploaded by the next daily or weekly backup, or run '${scriptName} bkp-to-cloud ${chain}'"
  fi
  return 0
 fi
 echo "  ${direction}ing chain ${chain}, piece ${pieceNumber} of ${pieces}: ${piece}"
 echo "  piece: $(human-size "${pieceDone}") of $(human-size "${pieceBytes}") ($(percent-of "${pieceDone}" "${pieceBytes}"))"
 local line="  total: $(human-size "${bytesDone}") of $(human-size "${totalBytes}") ($(percent-of "${bytesDone}" "${totalBytes}")), $(human-size "${rate}")/s"
 local idle=$(($(date +%s) - lastProgress))
 [ ${idle} -lt ${PROGRESS_STALLED_SECONDS} ] && [ "${secondsLeft}" -ge 0 ] && line+=", about $(format-duration "${secondsLeft}") left"
 echo "${line}"
 [ "${failed}" -gt 0 ] && echo "  ${RED}${failed} piece(s) failed${RESET} so far - they'll be retried on the next upload"
 if [ ${idle} -ge ${PROGRESS_STALLED_SECONDS} ]; then
  echo "  ${YELLOW}no progress for $(format-duration "${idle}")${RESET} - check the internet/network connection"
 fi
}

status-cloud-upload() {
 echo "${BOLD}${CYAN}Cloud upload${RESET}"
 show-transfer-progress "${scriptDir}/${UPLOAD_PROGRESS_NAME}" || echo "  no upload running"
 show-transfer-progress "${scriptDir}/${DOWNLOAD_PROGRESS_NAME}"
 echo
}

upload-status() {
 status-cloud-upload | limit-output "${STATUS_MAX_LINES}" "${STATUS_MAX_COLUMNS}"
}

# downloads, decrypts and unpacks "<object URL> <size>"... of chain <chain> into RestoreDir; <decompress> is the
# command that decompresses them (zstd, or bzip2 for archives uploaded by older bkp versions)
download-objects() {
 local chain="${1}"
 local decompress="${2}"
 shift 2
 local urls=() sizes=()
 local totalBytes=0
 while [ ${#} -ge 2 ]; do
  urls+=("${1}")
  sizes+=("${2}")
  totalBytes=$((totalBytes + ${2}))
  shift 2
 done
 log-line msg "downloading ${#urls[@]} piece(s) of backup chain ${chain} ($(human-size "${totalBytes}"))"
 local progressFile="${scriptDir}/${DOWNLOAD_PROGRESS_NAME}"
 local started
 started=$(date +%s)
 local doneBytes=0 result=0 i piece
 start-progress-monitor "${progressFile}"
 for ((i=0; i<${#urls[@]}; i++)); do
  piece="${urls[i]#*/${chain}/}"
  piece="${piece%"${CLOUD_PIECE_SUFFIX}"}"
  [ "${piece}" = "${urls[i]}" ] && piece=$(basename "${urls[i]}")
  write-progress "${progressFile}" direction=download "chain=${chain}" "pid=$$" "started=${started}" \
   "total_bytes=${totalBytes}" "done_bytes=${doneBytes}" "pieces=${#urls[@]}" "piece_number=$((i + 1))" \
   "piece=${piece}" "piece_bytes=${sizes[i]}" failed=0
  : > "${progressFile}.bytes"
  log-line msg "downloading ${urls[i]} ($(human-size "${sizes[i]}"))"
  if ! (set -o pipefail
        gcloud storage cat "${urls[i]}" \
         | count-bytes "${progressFile}.bytes" \
         | openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 -pass env:PASSPHRASE \
         | "${decompress}" -dcq \
         | tar -xf - -C "${RestoreDir}"); then
   log-line err "failed to download, decrypt or extract ${urls[i]} (incorrect passphrase?)"
   result=1
   break
  fi
  doneBytes=$((doneBytes + sizes[i]))
 done
 stop-progress-monitor
 rm -f "${progressFile}" "${progressFile}.bytes"
 return ${result}
}
# a piece needs uploading if it changed since its last upload, or its object isn't in <cloud object URLs>
piece-needs-upload() {
 local chainDir="${1}"
 local piece="${2}"
 local objectURL="${3}"
 local cloudObjects="${4}"
 [ "$(uploaded-fingerprint "${chainDir}" "${piece}")" != "$(piece-fingerprint "${chainDir}" "${piece}")" ] \
  || ! grep -qxF "${objectURL}" <<< "${cloudObjects}"
}

# uploads <piece> of <chain dir>, counting the bytes handed to gcloud into <progress file>.bytes: counted any earlier,
# they'd run ahead of the upload by what zstd reads ahead
upload-piece() {
 local chainDir="${1}"
 local piece="${2}"
 local objectURL="${3}"
 local progressFile="${4}"
 local partialURL="${objectURL}.partial"
 log-line msg "uploading ${piece} ($(size-of "${chainDir}/${piece}")) -> ${objectURL}"
 export PASSPHRASE="${AESPassphrase}"
 # streamed straight to cloud, so no local disk space is needed; zstd barely slows down on already compressed streams
 if ! (set -o pipefail
       tar -cf - -C "${chainDir}" "${piece}" \
        | zstd -T0 -"${ZSTD_LEVEL}" -q -c \
        | openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -pass env:PASSPHRASE \
        | count-bytes "${progressFile}.bytes" \
        | gcloud storage cp - "${partialURL}"); then
  log-line err "failed to upload ${piece}"
  gcloud storage rm "${partialURL}" >/dev/null 2>&1
  return 1
 fi
 # a failed or interrupted stream may still leave a complete-looking object behind, so the upload goes to a temporary
 # name first, and only replaces the previous upload of this piece once the whole stream is known to have made it
 if ! gcloud storage mv "${partialURL}" "${objectURL}" >/dev/null 2>&1; then
  log-line err "failed to move ${partialURL} to ${objectURL}"
  return 1
 fi
 local objectSize
 objectSize=$(gcloud storage ls --long "${objectURL}" 2>/dev/null | awk 'NR == 1 { print $1 }')
 log-line msg "uploaded ${objectURL} ($(human-size "${objectSize:-0}"))"
}

bkp-to-cloud() {
 require-cloud-provider
 require-vars GCSBucket AESPassphrase BackupInstanceName
 require-tools tar zstd openssl gcloud flock
 local ts="${1}"
 if [ -z "${ts}" ]; then
  log-line err "usage: ${scriptName} bkp-to-cloud <timestamp>"
  return 1
 fi
 local chainDir="${LocalBackupDir}/${ts}"
 if [ ! -d "${chainDir}" ]; then
  log-line err "no local backup found at ${chainDir}"
  return 1
 fi
 eval 'exec '${LOCK_FD_CLOUD}'>"'${lockCloud}'"'
 if ! flock -n ${LOCK_FD_CLOUD}; then
  log-line msg "waiting for another cloud upload to finish..."
  flock ${LOCK_FD_CLOUD}
 fi
 local chainURL
 chainURL=$(cloud-chain-url "${ts}")
 local cloudObjects
 cloudObjects=$(gcloud storage ls "${chainURL}/**" 2>/dev/null)
 local pieces=()
 mapfile -t pieces < <(list-chain-pieces "${chainDir}")
 local piece bytes
 local toUpload=() sizes=()
 local totalBytes=0
 for piece in "${pieces[@]}"; do
  piece-needs-upload "${chainDir}" "${piece}" "${chainURL}/${piece}${CLOUD_PIECE_SUFFIX}" "${cloudObjects}" || continue
  bytes=$(du -sb "${chainDir}/${piece}" 2>/dev/null | cut -f1)
  toUpload+=("${piece}")
  sizes+=("${bytes:-0}")
  totalBytes=$((totalBytes + ${bytes:-0}))
 done
 [ ${#toUpload[@]} -gt 0 ] && log-line msg "uploading ${#toUpload[@]} piece(s) of backup chain ${ts} ($(human-size "${totalBytes}"))"
 local progressFile="${scriptDir}/${UPLOAD_PROGRESS_NAME}"
 local started
 started=$(date +%s)
 local objectURL fingerprint i
 local uploaded=0 failed=0 doneBytes=0
 start-progress-monitor "${progressFile}"
 for ((i=0; i<${#toUpload[@]}; i++)); do
  piece="${toUpload[i]}"
  objectURL="${chainURL}/${piece}${CLOUD_PIECE_SUFFIX}"
  write-progress "${progressFile}" direction=upload "chain=${ts}" "pid=$$" "started=${started}" \
   "total_bytes=${totalBytes}" "done_bytes=${doneBytes}" "pieces=${#toUpload[@]}" "piece_number=$((i + 1))" \
   "piece=${piece}" "piece_bytes=${sizes[i]}" "failed=${failed}"
  : > "${progressFile}.bytes"
  fingerprint=$(piece-fingerprint "${chainDir}" "${piece}")
  if upload-piece "${chainDir}" "${piece}" "${objectURL}" "${progressFile}"; then
   record-uploaded-piece "${chainDir}" "${piece}" "${fingerprint}"
   uploaded=$((uploaded + 1))
  else
   failed=$((failed + 1))
  fi
  doneBytes=$((doneBytes + sizes[i]))
 done
 stop-progress-monitor
 rm -f "${progressFile}" "${progressFile}.bytes"
 eval 'exec '${LOCK_FD_CLOUD}'>&-'
 if [ ${failed} -gt 0 ]; then
  log-line err "${failed} piece(s) of backup chain ${ts} failed to upload - they'll be retried on the next upload"
  return 1
 fi
 log-line msg "backup chain ${ts} is fully uploaded to ${chainURL}/ (${uploaded} new or changed piece(s) this time)"
}
restore-from-cloud() {
 require-cloud-provider
 require-vars GCSBucket AESPassphrase BackupInstanceName
 require-tools gcloud openssl zstd tar docker
 # --from-instance=<name> restores another instance's backups, e.g. a replica's onto its master
 local BackupInstanceName="${BackupInstanceName}"
 local args=()
 local arg
 for arg in "${@}"; do
  case "${arg}" in
   --from-instance=*) BackupInstanceName="${arg#*=}";;
   *)                 args+=("${arg}");;
  esac
 done
 set -- "${args[@]}"
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
 if [ -n "$(ls -A "${RestoreDir}" 2>/dev/null)" ]; then
  log-line err "${RestoreDir} isn't empty - move its contents elsewhere first"
  return 1
 fi
 # chains uploaded piece by piece, and single-archive chains uploaded by older bkp versions
 local chainTs
 chainTs=$(gcloud storage ls "gs://${GCSBucket}/${BackupInstanceName}/" 2>/dev/null \
            | sed -nE 's#.*/([0-9]{14})/$#\1#p' | awk -v maxTs="${ts}" '$1 <= maxTs' | sort | tail -1)
 local legacyFile=""
 local legacyTs=""
 local line fileTs
 while IFS= read -r line; do
  fileTs=$(basename "${line}" | grep -oE '[0-9]{14}')
  if [[ -n "${fileTs}" ]] && [[ ! "${fileTs}" > "${ts}" ]] && [[ "${fileTs}" > "${legacyTs}" ]]; then
   legacyTs="${fileTs}"
   legacyFile="${line}"
  fi
 done < <(gcloud storage ls "gs://${GCSBucket}/*-backup.${BackupInstanceName}.*.tar.bz2.aes256" 2>/dev/null \
           | grep -E ".*-backup\.${BackupInstanceName}\.[0-9]{14}\.tar\.bz2\.aes256$")
 local latestTs
 if [[ -z "${chainTs}" ]] && [[ -z "${legacyTs}" ]]; then
  log-line err "no backups found before '${targetDatetime}'"
  return 1
 fi
 mkdir -p "${RestoreDir}"
 export PASSPHRASE="${AESPassphrase}"
 if [[ -n "${chainTs}" ]] && [[ ! "${chainTs}" < "${legacyTs}" ]]; then
  latestTs="${chainTs}"
  local chainURL
  chainURL=$(cloud-chain-url "${chainTs}")
  # "<size> <url>" of each piece; skips the summary line and unfinished (.partial) uploads
  local objects=()
  mapfile -t objects < <(gcloud storage ls --long "${chainURL}/**" 2>/dev/null \
                          | awk -v suffix="${CLOUD_PIECE_SUFFIX}" '$3 ~ /^gs:/ && substr($3, length($3) - length(suffix) + 1) == suffix { print $3, $1 }')
  if [ ${#objects[@]} -eq 0 ]; then
   log-line err "failed to list the pieces of backup chain ${chainTs} in ${chainURL}/"
   return 1
  fi
  download-objects "${chainTs}" zstd ${objects[*]} || return 1
  # the downloaded pieces are already in cloud, so they don't get uploaded again once this becomes a local chain
  local piece
  for piece in $(list-chain-pieces "${RestoreDir}"); do
   record-uploaded-piece "${RestoreDir}" "${piece}" "$(piece-fingerprint "${RestoreDir}" "${piece}")"
  done
 else
  require-tools bzip2
  latestTs="${legacyTs}"
  local legacySize
  legacySize=$(gcloud storage ls --long "${legacyFile}" 2>/dev/null | awk '$3 ~ /^gs:/ { print $1; exit }')
  download-objects "${legacyTs}" bzip2 "${legacyFile}" "${legacySize:-0}" || return 1
 fi
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

# normalizes the creation time column of 'gcloud storage ls --long' lines to UTC (YYYY-MM-DDTHH:MM:SSZ)
utc-ls-lines() {
 local lines
 lines=$(grep -E '^ *[0-9]+ +[^ ]+ +gs://')
 [ -n "${lines}" ] || return 0
 paste -d' ' <(awk '{ print $1 }' <<< "${lines}") \
             <(awk '{ print $2 }' <<< "${lines}" | date -u -f - +"%Y-%m-%dT%H:%M:%SZ") \
             <(awk '{ print $3 }' <<< "${lines}")
}

format-iso-time() {
 date -u -d "${1}" +"%Y-%m-%d %H:%M:%S UTC" 2>/dev/null || echo "${1}"
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
 if [ "$(docker exec "${DBContainerName}" mariadb -u"${DBUser}" -p"${DBPassword}" -N -B -e "SELECT @@log_bin" 2>/dev/null)" != "1" ]; then
  log-line msg "${DBContainerName} doesn't write a binlog - nothing to purge"
  return 0
 fi
 local purgeBefore
 purgeBefore=$(date -u -d "-${BINLOG_PURGE_MAX_AGE_DAYS} days" +"%Y-%m-%d %H:%M:%S")
 log-line msg "replication healthy - purging binlogs older than ${purgeBefore} UTC"
 # the server reads the cutoff in its session time zone, so that's set to UTC too
 if docker exec "${DBContainerName}" mariadb -u"${DBUser}" -p"${DBPassword}" -e "SET time_zone = '+00:00'; PURGE BINARY LOGS BEFORE '${purgeBefore}';" 2>/dev/null; then
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
 if [ "$(date +%z)" != "+0000" ]; then
  echo "  ${YELLOW}note${RESET}: cron runs these in the system timezone ($(date +"%Z, UTC%:z")), not in UTC"
 fi
 echo
}

# size of a backup stream file, flagging a missing or empty one
# size of the backup stream in a full/ or inc_*/ dir, flagging a missing or empty one
stream-size() {
 local streamFile
 if ! streamFile=$(stream-file "${1}"); then
  echo "${RED}missing${RESET} (no backup stream in ${1})"
 elif [ ! -s "${streamFile}" ]; then
  echo "${RED}EMPTY${RESET} - this backup is broken"
 elif [[ "${streamFile}" == *.zst ]]; then
  echo "$(size-of "${streamFile}") (compressed)"
 else
  echo "$(size-of "${streamFile}") (uncompressed)"
 fi
}

status-local-backups() {
 echo "${BOLD}${CYAN}Local backups${RESET}"
 load-state
 local chainDir="${LocalBackupDir}/${lastFullTs}"
 if [ -n "${lastFullTs}" ]; then
  echo "  last full backup:        ${lastFullTs} ($(format-backup-ts "${lastFullTs}")), $(stream-size "${chainDir}/mariadb/full")"
 else
  echo "  last full backup:        none"
 fi
 if [ -n "${lastIncTs}" ]; then
  echo "  last incremental backup: ${lastIncTs} ($(format-backup-ts "${lastIncTs}")), $(stream-size "${chainDir}/mariadb/inc_${lastIncTs}")"
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
 timeout -k 1 "${STATUS_CLOUD_TIMEOUT_SECONDS}" gcloud storage ls --long "gs://${GCSBucket}/${BackupInstanceName}/**" \
                                                "gs://${GCSBucket}/*-backup.${BackupInstanceName}.*.tar.bz2.aes256" >"${lsOutputFile}" 2>&1
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
 # each --long line is "<size> <creation time> <url>"; creation times are converted to UTC, whatever timezone gcloud uses
 lsOutput=$(utc-ls-lines <<< "${lsOutput}")
 local chainsURL="gs://${GCSBucket}/${BackupInstanceName}"
 local chainLines legacyLines
 chainLines=$(grep -E " ${chainsURL}/[0-9]{14}/.*${CLOUD_PIECE_SUFFIX//./\\.}$" <<< "${lsOutput}")
 legacyLines=$(grep -E -- "-backup\.${BackupInstanceName}\.[0-9]{14}\.tar\.bz2\.aes256$" <<< "${lsOutput}")
 if [ -z "${chainLines}" ] && [ -z "${legacyLines}" ]; then
  echo "  no backups found in gs://${GCSBucket}/"
  echo
  return
 fi
 if [ -n "${chainLines}" ]; then
  local chainTs
  chainTs=$(awk '{ print $3 }' <<< "${chainLines}" | sed -nE "s#^${chainsURL}/([0-9]{14})/.*#\1#p" | sort | tail -1)
  local pieceCount totalSize lastCreated lastObject
  read -r pieceCount totalSize lastCreated lastObject < <(awk -v prefix="${chainsURL}/${chainTs}/" '
   index($3, prefix) == 1 { n++; total += $1; if ($2 > last) { last = $2; object = $3 } }
   END { printf "%d %.0f %s %s\n", n, total, last, substr(object, length(prefix) + 1) }' <<< "${chainLines}")
  echo "  latest chain:  ${chainTs} ($(format-backup-ts "${chainTs}")) - ${pieceCount} piece(s), $(human-size "${totalSize}")"
  echo "  last upload:   ${lastObject%"${CLOUD_PIECE_SUFFIX}"}, $(format-iso-time "${lastCreated}")"
 else
  echo "  latest chain:  none uploaded piece by piece yet"
 fi
 load-state
 if [ -n "${lastFullTs}" ] && [ -d "${LocalBackupDir}/${lastFullTs}" ]; then
  local chainDir="${LocalBackupDir}/${lastFullTs}"
  local cloudObjects
  cloudObjects=$(awk '{ print $3 }' <<< "${chainLines}")
  local piece pending=0
  for piece in $(list-chain-pieces "${chainDir}"); do
   piece-needs-upload "${chainDir}" "${piece}" "$(cloud-chain-url "${lastFullTs}")/${piece}${CLOUD_PIECE_SUFFIX}" "${cloudObjects}" \
    && pending=$((pending + 1))
  done
  if [ ${pending} -eq 0 ]; then
   echo "  not uploaded:  none (local chain ${lastFullTs} is fully uploaded)"
  else
   echo "  not uploaded:  ${YELLOW}${pending} piece(s)${RESET} of local chain ${lastFullTs} - uploaded after each daily backup, or run '${scriptName} bkp-to-cloud ${lastFullTs}'"
  fi
 fi
 if [ -n "${legacyLines}" ]; then
  local legacyCount legacySize legacyCreated legacyObject
  legacyCount=$(wc -l <<< "${legacyLines}")
  read -r legacySize legacyCreated legacyObject < <(sort -k3 <<< "${legacyLines}" | tail -1)
  local legacyTs
  legacyTs=$(basename "${legacyObject}" | grep -oE '[0-9]{14}')
  local legacySizeText
  legacySizeText=$(human-size "${legacySize}")
  [ "${legacySize}" -lt 1024 ] && legacySizeText="${RED}${legacySizeText}${RESET} - suspiciously small, probably a broken upload"
  echo "  older format:  ${legacyCount} single-archive backup(s), latest chain ${legacyTs} ($(format-backup-ts "${legacyTs}")), uploaded $(format-iso-time "${legacyCreated}"), ${legacySizeText}"
 fi
 echo
}

status-binlogs() {
 echo "${BOLD}${CYAN}Binlogs (point-in-time restore)${RESET}"
 local binlogPattern
 if [ "${DBBinlogSource}" = "master" ]; then
  echo "  source:      the master's binlogs, fetched hourly from ${DBMasterHost:-(DBMasterHost not set)}:${DBMasterPort}"
  binlogPattern='^.+\.[0-9]+$'
 elif [ "${DBBinlogSource}" = "local" ]; then
  echo "  source:      ${DBContainerName}'s own binlogs (${DBBinlogBasename:-DBBinlogBasename not set}), copied hourly"
  binlogPattern="^${DBBinlogBasename}\.[0-9]+$"
  local problem=""
  if [ "${dbUp}" = true ]; then
   problem=$(local-binlog-problem)
  fi
  [ -n "${problem}" ] && echo "  ${RED}unusable${RESET}:    ${problem}"
 else
  echo "  source:      ${RED}unknown DBBinlogSource '${DBBinlogSource}'${RESET} - use 'local' or 'master'"
  echo
  return
 fi
 load-state
 local binlogDir="${LocalBackupDir}/${lastFullTs}/mariadb/binlogs"
 local latest=""
 [ -n "${lastFullTs}" ] && latest=$(ls "${binlogDir}" 2>/dev/null | grep -E "${binlogPattern}" | grep -v relay | sort | tail -1)
 if [ -n "${latest}" ]; then
  echo "  last saved:  ${latest} ($(size-of "${binlogDir}/${latest}")), modified $(date -u -d "@$(stat -c %Y "${binlogDir}/${latest}")" +"%Y-%m-%d %H:%M:%S UTC")"
 else
  echo "  last saved:  ${YELLOW}none${RESET} in the current chain - point-in-time restore only reaches the last daily backup"
 fi
 echo
}

# the binlog positions the last restore recorded, for starting replication after it
status-restored-binlog-pos() {
 local restored replayed
 restored=$(read-datadir-file "${RESTORED_BINLOG_POS_NAME}")
 replayed=$(read-datadir-file "${BINLOGS_REPLAYED_NAME}")
 if [ -n "${restored}" ]; then
  local file pos
  file=$(value-of-key "${restored}" file)
  pos=$(value-of-key "${restored}" pos)
  echo "  restored $(value-of-key "${restored}" restored_at) UTC, binlog position after the restore: ${file}:${pos}"
  echo "    -> on replicas restored the same way, run '${scriptName} start-replica ${file} ${pos}'"
 fi
 if [ -n "${replayed}" ] && [ -n "${DBMasterHost}" ] && [ "$(value-of-key "${replayed}" coordinates)" = "master" ]; then
  echo "  restored up to $(value-of-key "${replayed}" replayed_to) UTC from the master's binlogs, ending at $(value-of-key "${replayed}" end_file):$(value-of-key "${replayed}" end_pos)"
  echo "    -> if the master wasn't restored, run '${scriptName} start-replica' to resume replication there"
 fi
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
  status-restored-binlog-pos
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

# prints the master's "<binlog file> <position>" the restored datadir continues from: where the restore's binlog replay
# ended, if it replayed the master's binlogs, otherwise what mariadb-backup recorded: the master's position if the
# backup was made on a replica (with DBBinlogSource=master), otherwise the backed up server's own binlog position
read-restored-binlog-pos() {
 local replayed
 replayed=$(read-datadir-file "${BINLOGS_REPLAYED_NAME}")
 if [ -n "${replayed}" ]; then
  local replayedTo
  replayedTo=$(value-of-key "${replayed}" replayed_to)
  if [ "$(value-of-key "${replayed}" coordinates)" != "master" ]; then
   log-line err "the restore replayed this server's own binlogs (up to ${replayedTo} UTC), so the master position its backup recorded is out of date" >&2
   log-line err "pass the master's binlog position to resume from explicitly: ${scriptName} start-replica <master-log-file> <master-log-pos>" >&2
   return 1
  fi
  log-line msg "resuming where the restore's replay of the master's binlogs ended (up to ${replayedTo} UTC)" >&2
  log-line msg "if the master was restored as well, pass the position its restore logged instead: ${scriptName} start-replica <file> <pos>" >&2
  echo "$(value-of-key "${replayed}" end_file) $(value-of-key "${replayed}" end_pos)"
  return 0
 fi
 local infoName info logFile logPos
 for infoName in mariadb_backup_slave_info xtrabackup_slave_info; do
  info=$(read-datadir-file "${infoName}") || continue
  logFile=$(sed -nE "s/.*MASTER_LOG_FILE *= *'([^']+)'.*/\1/Ip" <<< "${info}" | head -1)
  logPos=$(sed -nE "s/.*MASTER_LOG_POS *= *([0-9]+).*/\1/Ip" <<< "${info}" | head -1)
  if [ -n "${logFile}" ] && [ -n "${logPos}" ]; then
   log-line msg "found the master's binlog coordinates in ${DBDataDir}/${infoName} (restored from a replica's backup)" >&2
   echo "${logFile} ${logPos}"
   return 0
  fi
 done
 for infoName in xtrabackup_info mariadb_backup_info; do
  info=$(read-datadir-file "${infoName}") && break
  info=""
 done
 if [ -z "${info}" ]; then
  log-line err "neither xtrabackup_info nor mariadb_backup_info found in ${DBDataDir} - has the database been restored from a backup?" >&2
  log-line err "pass the coordinates explicitly: ${scriptName} start-replica <master-log-file> <master-log-pos>" >&2
  return 1
 fi
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
  status-binlogs
  status-disk-space
  status-cloud-upload
  # last, since it depends on the network and may take up to STATUS_CLOUD_TIMEOUT_SECONDS
  status-cloud-backups
 } | limit-output "${STATUS_MAX_LINES}" "${STATUS_MAX_COLUMNS}"
}
