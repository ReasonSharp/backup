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
 if [ "${DBType}" != "mariadb" ]; then
  log-line err "unsupported DBType '${DBType}' (only 'mariadb' is supported for now)"
  exit 1
 fi
}

require-cloud-provider() {
 if [ "${CloudProvider}" != "gcloud" ]; then
  log-line err "unsupported CloudProvider '${CloudProvider}' (only 'gcloud' is supported for now)"
  exit 1
 fi
}

# external tools bkp depends on, in the order missing ones are reported
KNOWN_TOOLS=(docker gcloud tar bzip2 openssl flock pgrep crontab envsubst)

tool-install-hint() {
 case "${1}" in
  docker)   echo "install Docker Engine: https://docs.docker.com/engine/install/";;
  gcloud)   echo "install the Google Cloud CLI: https://cloud.google.com/sdk/docs/install, then run 'gcloud init'";;
  tar)      echo "install the tar package (e.g. 'sudo apt install tar')";;
  bzip2)    echo "install the bzip2 package (e.g. 'sudo apt install bzip2')";;
  openssl)  echo "install the openssl package (e.g. 'sudo apt install openssl')";;
  flock)    echo "install the util-linux package (e.g. 'sudo apt install util-linux')";;
  pgrep)    echo "install the procps package (e.g. 'sudo apt install procps')";;
  crontab)  echo "install the cron package (e.g. 'sudo apt install cron')";;
  envsubst) echo "install the gettext-base package (e.g. 'sudo apt install gettext-base') - until then, .env isn't regenerated from .env.template";;
 esac
}

missing-tools() {
 local tool
 for tool in "${@}"; do
  command -v "${tool}" >/dev/null 2>&1 || echo "${tool}"
 done
}

warn-missing-tools() {
 local tool
 for tool in $(missing-tools "${KNOWN_TOOLS[@]}"); do
  log-line wrn "${tool} not found - $(tool-install-hint "${tool}")" >&2
 done
}

require-tools() {
 local missing=($(missing-tools "${@}"))
 if [ ${#missing[@]} -gt 0 ]; then
  log-line err "cannot run '${cmd:-this command}' - missing required tool(s): ${missing[*]} (see the warnings above for how to install them)"
  exit 1
 fi
}
