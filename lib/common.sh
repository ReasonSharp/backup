#!/bin/bash

if [ -z "${scriptDir}" ]; then
 echo "scriptDir not set: bug in bkp?" >&2
 exit 1
fi

log-line() {
 local level="${1}"
 local line="${2}"
 echo "[$(date +"%Y-%m-%d %H:%M:%S")] (${level}): ${line}"
}

require-vars() {
 local missing=()
 local varName
 for varName in "${@}"; do
  if [ -z "${!varName}" ]; then
   missing+=("${varName}")
  fi
 done
 if [ ${#missing[@]} -gt 0 ]; then
  log-line err "missing required configuration: ${missing[*]} (edit ${envFile})"
  exit 1
 fi
}

require-db-type() {
 if [ "${DbType}" != "mariadb" ]; then
  log-line err "unsupported DbType '${DbType}' (only 'mariadb' is supported for now)"
  exit 1
 fi
}

require-cloud-provider() {
 if [ "${CloudProvider}" != "gcloud" ]; then
  log-line err "unsupported CloudProvider '${CloudProvider}' (only 'gcloud' is supported for now)"
  exit 1
 fi
}
