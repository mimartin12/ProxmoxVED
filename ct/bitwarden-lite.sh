#!/usr/bin/env bash
# Engine comes from community-scripts/core; this repo only ships the scripts.
# A local core checkout wins (COMMUNITY_SCRIPTS_CORE_DIR, else a sibling ../core),
# so a fork or branch of core can be tested without editing this file.
_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")
# Author: mimartin12
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://github.com/bitwarden/self-host (bitwarden-lite reference implementation)

# Not an official Bitwarden script.

APP="Bitwarden-Lite"
var_tags="${var_tags:-vault;password-manager}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-10}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_arm64="${var_arm64:-yes}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -d /opt/bitwarden ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  msg_info "Checking for Updates"
  VERSION_JSON=$(curl -fsSL https://raw.githubusercontent.com/bitwarden/self-host/main/version.json)
  LATEST_SERVER_TAG=$(echo "$VERSION_JSON" | jq -r .versions.coreVersion)
  LATEST_WEB_TAG=$(echo "$VERSION_JSON" | jq -r .versions.webVersion)
  CURRENT_SERVER_TAG=$(cat /opt/bitwarden/.server-version 2>/dev/null || echo "")
  CURRENT_WEB_TAG=$(cat /opt/bitwarden/.web-version 2>/dev/null || echo "")

  if [[ "$LATEST_SERVER_TAG" == "$CURRENT_SERVER_TAG" && "$LATEST_WEB_TAG" == "$CURRENT_WEB_TAG" ]]; then
    msg_ok "Already up to date (server ${CURRENT_SERVER_TAG}, web ${CURRENT_WEB_TAG})"
    exit
  fi
  msg_ok "Update available: server ${CURRENT_SERVER_TAG} -> ${LATEST_SERVER_TAG}, web ${CURRENT_WEB_TAG} -> ${LATEST_WEB_TAG}"

  msg_info "Stopping Bitwarden Services"
  systemctl stop bitwarden-admin bitwarden-api bitwarden-events bitwarden-icons \
    bitwarden-identity bitwarden-notifications bitwarden-scim bitwarden-sso 2>/dev/null || true
  msg_ok "Stopped Bitwarden Services"

  create_backup /etc/bitwarden /opt/bitwarden/bitwarden.env

  SERVER_TAG="$LATEST_SERVER_TAG" WEB_TAG="$LATEST_WEB_TAG" /opt/bitwarden/bin/fetch-all.sh

  restore_backup

  msg_info "Starting Bitwarden Services"
  /opt/bitwarden/bin/enabled-services.sh | xargs -r systemctl start
  systemctl restart nginx
  msg_ok "Started Bitwarden Services"
  msg_ok "Updated successfully!"
  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Access it using the following URL:${CL}"
echo -e "${GATEWAY}${BGN}https://${IP}${CL}"
echo -e "${INFO}${YW}Edit /opt/bitwarden/bitwarden.env (especially BW_INSTALLATION_ID/KEY from https://bitwarden.com/host/), then run 'bitwarden-reconfigure' to apply.${CL}"
