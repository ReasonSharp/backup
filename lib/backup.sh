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

extract-xbstream() {
 local streamFile="${1}"
 local targetDir="${2}"
 log-line msg "extracting ${streamFile} -> ${targetDir}"
 local tmpStream="${targetDir}/$(basename "${streamFile}")"
 mkdir -p "${targetDir}"
 rsync -a --delete "${streamFile}" "${tmpStream}"
 docker run --rm \
  -v "${targetDir}":/workdir \
  "${DBBackupImage}" sh -c 'cd /workdir && mbstream -x < "'"$(basename "${streamFile}")"'"
                     chown -R '$(id -u)':'$(id -g)' /workdir'
 rm -f "${tmpStream}"
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
 mkdir -p "${fullDir}"
 if docker run --rm --name "mariadb-backup-full-${ts}" \
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
                                       --password="'"${DBPassword}"'"
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
 if [[ -z "${fullTs}" ]] && [[ -z "${1}" ]]; then
  log-line err "no valid full backup found and no parameter is given - falling back to full backup"
  bkp-db-weekly
  rm -f "${lockDaily}"
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
 mkdir -p "${incDir}"
 if docker run --rm --name "mariadb-backup-inc-${ts}" \
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
                                       --password="'"${DBPassword}"'"
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
 require-vars DBDataDir DBBinlogBasename
 if higher-priority-running "${lockWeekly}" || higher-priority-running "${lockDaily}"; then
  log-line wrn "higher priority backup running - skipping hourly"
  return 1
 fi
 log-line msg "=== STARTING HOURLY BACKUP ==="
 acquire-lock "${lockHourly}" ${LOCK_FD_HOURLY}
 load-state
 local fullTs="${lastFullTs}"
 if [[ -z "${fullTs}" ]] && [[ -z "${1}" ]]; then
  log-line wrn "no full backup exists yet - skipping binlog backup"
  return 0
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
