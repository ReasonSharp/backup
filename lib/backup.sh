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

scriptName=$(basename "${0}")

dbNetworkArgs=()
[ -n "${DBDockerNetwork}" ] && dbNetworkArgs=(--network "${DBDockerNetwork}")

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
 log-line msg "extracting ${streamFile} -> ${targetDir}"
 mkdir -p "${targetDir}"
 docker run --rm \
  -v "$(dirname "${streamFile}")":/source:ro \
  -v "${targetDir}":/workdir \
  "${DBBackupImage}" sh -c 'cd /workdir && mbstream -x < "/source/'"$(basename "${streamFile}")"'"
                     chown -R '$(id -u)':'$(id -g)' /workdir'
}
remove-extracted() {
 docker run --rm -v "$(dirname "${1}")":/workdir:rw "${ALPINE_IMAGE}" rm -rf /workdir/$(basename "${1}")
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

bkp-db-weekly() {
 require-db-type
 require-vars DBHost DBPort DBUser DBPassword DBDataDir DBBackupImage
 log-line msg "=== STARTING WEEKLY BACKUP ==="
 acquire-lock "${lockWeekly}" ${LOCK_FD_WEEKLY}
 terminate-lower-priority 3
 local ts
 ts=$(date -u +"%Y%m%d%H%M%S")
 local bkpRoot="${LocalBackupDir}/${ts}/mariadb"
 local fullDir="${bkpRoot}/full"
 local streamFile="${fullDir}/backup.xbstream"
 local prevBkp=""
 local d
 for d in $(find "${LocalBackupDir}" -mindepth 1 -maxdepth 1 -type d -name '[0-9][0-9][0-9][0-9][0-1][0-9][0-3][0-9][0-2][0-9][0-5][0-9][0-5][0-9]' | sort -r); do
  if [[ "$(basename "${d}")" < "${ts}" ]]; then
   prevBkp="$(basename "${d}")"
   break
  fi
 done
 local remotePassword="${DBRemotePassword:-${DBPassword}}"
 mkdir -p "${fullDir}"
 if docker run --rm --name "mariadb-backup-full-${ts}" \
               --log-driver none \
               -v "${DBDataDir}":/var/lib/mysql:ro \
               -v "${fullDir}":/backup:rw \
               "${dbNetworkArgs[@]}" \
               "${DBBackupImage}" \
               bash -c 'mariadb-backup --backup \
                                       --target-dir=/backup \
                                       --stream=xbstream \
                                       --host="'"${DBHost}"'" \
                                       --port="'"${DBPort}"'" \
                                       --user="'"${DBUser}"'" \
                                       --password="'"${remotePassword}"'"
                        chown -R "'"$(id -u)":"$(id -g)"'" /backup' 2> /dev/null > "${streamFile}"; then
  log-line msg "backup file successfully created at ${streamFile}"
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
  if [[ -n "${prevBkp}" ]]; then
   bkp-to-cloud "${prevBkp}" "weekly"
   if [ "${?}" -eq 0 ]; then
    rm -rf "${LocalBackupDir}/${prevBkp}"
   else
    log-line wrn "couldn't upload previous week's backups to cloud (${LocalBackupDir}/${prevBkp})"
   fi
  fi
  bkp-to-cloud "${ts}" "daily"
  log-line msg "=== WEEKLY BACKUP COMPLETED ==="
 else
  rm -rf "${fullDir}"
  log-line err "weekly backup failed with code ${?}"
  return 1
 fi
}
bkp-db-daily() {
 require-db-type
 require-vars DBHost DBPort DBUser DBPassword DBDataDir DBBackupImage
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
 local lastStream="${lastFullDir}/backup.xbstream"
 local extractDir
 extractDir=$(mktemp -d)
 extract-xbstream "${lastStream}" "${extractDir}"
 local streamFile="${incDir}/backup.xbstream"
 local remotePassword="${DBRemotePassword:-${DBPassword}}"
 mkdir -p "${incDir}"
 if docker run --rm --name "mariadb-backup-inc-${ts}" \
               --log-driver none \
               -v "${DBDataDir}":/var/lib/mysql:ro \
               -v "${extractDir}":/base:ro \
               -v "${incDir}":/backup:rw \
               "${dbNetworkArgs[@]}" \
               "${DBBackupImage}" \
               bash -c 'mariadb-backup --backup \
                                       --target-dir=/backup \
                                       --incremental-basedir=/base \
                                       --stream=xbstream \
                                       --host="'"${DBHost}"'" \
                                       --port="'"${DBPort}"'" \
                                       --user="'"${DBUser}"'" \
                                       --password="'"${remotePassword}"'"
                        chown -R "'"$(id -u)":"$(id -g)"'" /backup' > "${streamFile}" 2> /dev/null; then
  log-line msg "backup file successfully created at ${streamFile}"
  remove-extracted "${extractDir}"
  lastIncTs="${ts}"
  save-state
  if [[ -z "${1}" ]]; then
   bkp-to-cloud "${fullTs}" "daily"
  fi
  log-line msg "=== DAILY BACKUP COMPLETED ==="
 else
  log-line err "daily backup failed with code ${?}"
  rm -rf "${incDir}"
  return 1
 fi
 bkp-folders "${fullTs}"
}
bkp-db-hourly() {
 require-db-type
 require-vars DBDataDir DBBinlogBasename DBContainerName DBUser DBPassword
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
                                                cp "${f}" /target/
                                               done
                                               chown '$(id -u)':'$(id -g)' "/target/"*'; then
  log-line msg "binlogs successfully copied to ${binlogDir}/"
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
 log-line msg "preparing backup chain (base = ${baseDir}, incrementals: ${#incDirs[@]}) ..."
 docker run --rm -v "${restoreDBDir}/${baseDir}":/backup:rw \
  "${DBBackupImage}" bash -c 'mariadb-backup --prepare --target-dir=/backup
                        chown -R "'"$(id -u)":"$(id -g)"'" /backup' 2> /dev/null
 local inc
 for inc in "${incDirs[@]}"; do
  local incName
  incName=$(basename "${inc}")
  log-line msg "-> applying incremental ${incName}"
  docker run --rm -v "${restoreDBDir}/${baseDir}":/base:rw -v "${restoreDBDir}/${inc}":/inc:rw \
   "${DBBackupImage}" bash -c 'mariadb-backup --prepare --target-dir=/base --incremental-dir=/inc
                         chown -R "'"$(id -u)":"$(id -g)"'" /base' 2> /dev/null
 done
 local backupEndDatetime
 backupEndDatetime=$(grep '^end_time' "${baseDir}/mariadb_backup_info" | awk -F '= ' '{gsub(/"/,"",$2); print $2}' | xargs)
 log-line msg "backup chain consistent as of: ${backupEndDatetime}"
 log-line msg "stopping MariaDB container..."
 docker stop "${DBContainerName}" || true
 log-line msg "saving corrupted/current data dir -> ${DBDataDir}-corrupted-$(date -u +"%Y%m%d%H%M%S")"
 mv "${DBDataDir}" "${DBDataDir}-corrupted-$(date -u +"%Y%m%d%H%M%S")"
 mkdir -p "${DBDataDir}"
 log-line msg "copying back data from backup..."
 docker run --rm -v "${DBDataDir}":/var/lib/mysql:rw -v "${restoreDBDir}/${baseDir}":/backup:ro \
  "${DBBackupImage}" mariadb-backup --copy-back --target-dir=/backup --datadir=/var/lib/mysql 2> /dev/null
 log-line msg "starting MariaDB container..."
 docker start "${DBContainerName}"
 wait-for-db "${DBContainerName}" "${DBUser}" "${DBPassword}"
 if [ "${isPITR}" = "1" ] && [[ "${backupEndDatetime}" < "${targetDatetimeStr}" ]]; then
  log-line msg "applying binary logs from ${backupEndDatetime} -> ${targetDatetimeStr}..."
  local pitrDir
  pitrDir=$(mktemp -d)
  mkdir -p "${pitrDir}"
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
 extract-xbstream "${fullStream}" "${restoreDBDir}/base"
 local i
 for ((i=0; i<${#selectedIncDirs[@]}; i++)); do
  local incStream="${selectedIncDirs[i]}/backup.xbstream"
  extract-xbstream "${incStream}" "${restoreDBDir}/_inc_${i}"
 done
 perform-restore "${isPITR}" "${targetDatetimeStr}" "${ts}"
 if [ "${?}" -ne 0 ]; then
  log-line err "there's been an error restoring the database"
  log-line err "fix the errors, then re-run restore with ${scriptName} restore-db-local \"${ts}\" \"${targetDatetimeStr}\""
 fi
 rm -rf "${restoreDBDir}"
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
 local ts="${1}"
 local level="${2}"
 if [ -z "${ts}" ] || [ -z "${level}" ]; then
  log-line err "usage: ${scriptName} bkp-to-cloud <timestamp> <weekly|daily>"
  return 1
 fi
 local archiveName="${level}-backup.${BackupInstanceName}.${ts}.tar.bz2"
 local archivePath="/tmp/${archiveName}"
 local encryptedPath="${archivePath}.aes256"
 tar -cvjf "${archivePath}" -C "${LocalBackupDir}/${ts}" . 2>/dev/null 2>&1
 export PASSPHRASE="${AESPassphrase}"
 openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -in "${archivePath}" -out "${encryptedPath}" -pass env:PASSPHRASE
 local cloudPath="gs://${GCSBucket}/${archiveName}.aes256"
 if gcloud storage ls "${cloudPath}" >/dev/null 2>&1; then
  gcloud storage rm "${cloudPath}" 2>/dev/null || true
 fi
 gcloud storage cp "${encryptedPath}" "${cloudPath}"
 if [ "${?}" -eq 0 ]; then
  if [ "${level}" = "weekly" ]; then
   gcloud storage rm -q "gs://${GCSBucket}/daily-backup.${BackupInstanceName}.*.tar.bz2.aes256" 2>/dev/null || true
  fi
  rm -f "${encryptedPath}"
 else
  log-line wrn "failed to upload encrypted archive to cloud, moving to restore directory"
  mkdir -p "${RestoreDir}"
  mv "${encryptedPath}" "${RestoreDir}"
 fi
 rm -f "${archivePath}"
}
restore-from-cloud() {
 require-cloud-provider
 require-vars GCSBucket AESPassphrase BackupInstanceName
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

status-db() {
 echo "${BOLD}${CYAN}Database${RESET}"
 dbUp=false
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

status-local-backups() {
 echo "${BOLD}${CYAN}Local backups${RESET}"
 load-state
 if [ -n "${lastFullTs}" ]; then
  echo "  last full backup:        ${lastFullTs} ($(format-backup-ts "${lastFullTs}"))"
 else
  echo "  last full backup:        none"
 fi
 if [ -n "${lastIncTs}" ]; then
  echo "  last incremental backup: ${lastIncTs} ($(format-backup-ts "${lastIncTs}"))"
 else
  echo "  last incremental backup: none"
 fi
 echo
}

status-cloud-backups() {
 echo "${BOLD}${CYAN}Cloud backups${RESET}"
 if [ "${CloudProvider}" != "gcloud" ] || [ -z "${GCSBucket}" ]; then
  echo "  not configured (CloudProvider=${CloudProvider:-unset}, GCSBucket=${GCSBucket:-unset})"
  echo
  return
 fi
 local lsOutput lsExit
 lsOutput=$(gcloud storage ls "gs://${GCSBucket}/*-backup.${BackupInstanceName}.*.tar.bz2.aes256" 2>&1)
 lsExit=${?}
 if [ ${lsExit} -ne 0 ] && ! grep -qi "matched no objects" <<< "${lsOutput}"; then
  echo "  ${RED}unable to reach gs://${GCSBucket}/${RESET} - check your internet/network connection"
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
 local latestFile="" latestTs="00000000000000"
 local line
 while IFS= read -r line; do
  local filename fileTs
  filename=$(basename "${line}")
  fileTs=$(echo "${filename}" | grep -oE '[0-9]{14}' || echo "00000000000000")
  if [[ "${fileTs}" > "${latestTs}" ]]; then
   latestTs="${fileTs}"
   latestFile="${line}"
  fi
 done <<< "${candidates}"
 local level
 level=$(basename "${latestFile}" | cut -d'-' -f1)
 echo "  last upload: ${level} backup, ${latestTs} ($(format-backup-ts "${latestTs}"))"
 echo "  object:      ${latestFile}"
 echo
}

status-replication() {
 echo "${BOLD}${CYAN}Replication${RESET}"
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

restart-replication() {
 require-db-type
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
 sleep 2
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
  log-line err "replication still not running (IO=${ioRunning}, SQL=${sqlRunning})"
  [ -n "${lastSqlErr}" ] && log-line err "last SQL error: ${lastSqlErr}"
  [ -n "${lastIoErr}" ] && log-line err "last IO error: ${lastIoErr}"
  return 1
 fi
}

status() {
 local dbUp=false
 echo "${BOLD}=== bkp status (${BackupInstanceName}) ===${RESET}"
 echo
 status-db
 status-schedule
 status-local-backups
 status-cloud-backups
 status-replication
}
