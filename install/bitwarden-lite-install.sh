#!/usr/bin/env bash
# Author: mimartin12
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/bitwarden/self-host (bitwarden-lite reference implementation)

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt install -y skopeo jq openssl unzip
msg_ok "Installed Dependencies"

msg_info "Installing .NET Runtime"
setup_deb822_repo \
  "microsoft-prod" \
  "https://packages.microsoft.com/keys/microsoft.asc" \
  "https://packages.microsoft.com/debian/12/prod" \
  "bookworm" \
  "main"
$STD apt update
$STD apt install -y aspnetcore-runtime-10.0
msg_ok "Installed .NET Runtime"

msg_info "Installing Nginx"
# bookworm's own nginx package predates 1.25.1, which lacks the `http2 on;`
# directive nginx-config.hbs now requires. nginx.org's own repo tracks current
# releases independent of the Debian release cycle.
setup_deb822_repo \
  "nginx" \
  "https://nginx.org/keys/nginx_signing.key" \
  "https://nginx.org/packages/debian" \
  "bookworm" \
  "nginx"
$STD apt update
$STD apt install -y nginx
msg_ok "Installed Nginx"

# /etc/bitwarden, /var/log/bitwarden and /tmp/bitwarden match bitwarden/self-host's own
# layout exactly - the vendored nginx/hbs config below hardcodes those paths (e.g.
# nginx-config.hbs's `alias /etc/bitwarden/attachments/`), so using anything else means
# patching every fetched file instead of just the parts we actually need to change.
mkdir -p /opt/bitwarden/{app,bin}
mkdir -p /etc/bitwarden/{Web,nginx,attachments/send,data-protection,licenses}
mkdir -p /var/log/bitwarden/nginx /tmp/bitwarden
chmod 700 /etc/bitwarden
# nginx-config.hbs hardcodes `root /app/Web`, so it needs to resolve to the same place
# hbs writes app-id.json (config.yaml's dest is /etc/bitwarden/Web/app-id.json).
mkdir -p /app
ln -sfn /etc/bitwarden/Web /app/Web

if [[ -z "${BW_DOMAIN:-}" ]]; then
  read -rp "${TAB3}Domain (blank uses the container IP): " BW_DOMAIN </dev/tty
fi
BW_DOMAIN="${BW_DOMAIN:-$(hostname -I | awk '{print $1}')}"

if [[ -z "${BW_INSTALLATION_ID:-}" ]]; then
  read -rp "${TAB3}Email to register a new installation id/key (blank to enter one you already have): " BW_INSTALL_EMAIL </dev/tty
  if [[ -n "$BW_INSTALL_EMAIL" ]]; then
    msg_info "Registering Installation"
    INSTALL_PAYLOAD=$(jq -n --arg email "$BW_INSTALL_EMAIL" '{email: $email}')
    INSTALL_RESPONSE=$(curl -fsSL -X POST "https://api.bitwarden.com/installations" \
      -H "Content-Type: application/json" --data-raw "$INSTALL_PAYLOAD")
    BW_INSTALLATION_ID=$(echo "$INSTALL_RESPONSE" | jq -r .id)
    BW_INSTALLATION_KEY=$(echo "$INSTALL_RESPONSE" | jq -r .key)
    if [[ -z "$BW_INSTALLATION_ID" || "$BW_INSTALLATION_ID" == "null" ]]; then
      msg_error "Failed to register an installation - enter one manually from https://bitwarden.com/host/"
      read -rp "${TAB3}Installation ID: " BW_INSTALLATION_ID </dev/tty
      read -rp "${TAB3}Installation Key: " BW_INSTALLATION_KEY </dev/tty
    else
      msg_ok "Registered Installation ${BW_INSTALLATION_ID}"
    fi
  else
    read -rp "${TAB3}Installation ID: " BW_INSTALLATION_ID </dev/tty
    read -rp "${TAB3}Installation Key: " BW_INSTALLATION_KEY </dev/tty
  fi
fi

if [[ -z "${BW_DB_PROVIDER:-}" ]]; then
  echo -e "${TAB3}Database provider:"
  echo -e "${TAB3}  1) SQLite (default, no server)"
  echo -e "${TAB3}  2) MariaDB"
  echo -e "${TAB3}  3) PostgreSQL"
  echo -e "${TAB3}  4) MS SQL Server (amd64 only, unofficial - installed from Microsoft's Ubuntu repo, not Debian)"
  read -rp "${TAB3}Choice [1]: " BW_DB_CHOICE </dev/tty
  case "${BW_DB_CHOICE:-1}" in
  2) BW_DB_PROVIDER=mysql ;;
  3) BW_DB_PROVIDER=postgresql ;;
  4) BW_DB_PROVIDER=sqlserver ;;
  *) BW_DB_PROVIDER=sqlite ;;
  esac
fi

case "$BW_DB_PROVIDER" in
mysql)
  setup_mariadb
  MARIADB_DB_NAME="bitwarden_vault" MARIADB_DB_USER="bitwarden" setup_mariadb_db
  BW_DB_SERVER=localhost
  BW_DB_DATABASE="$MARIADB_DB_NAME"
  BW_DB_USERNAME="$MARIADB_DB_USER"
  BW_DB_PASSWORD="$MARIADB_DB_PASS"
  ;;
postgresql)
  setup_postgresql
  PG_DB_NAME="bitwarden_vault" PG_DB_USER="bitwarden" setup_postgresql_db
  BW_DB_SERVER=localhost
  BW_DB_DATABASE="$PG_DB_NAME"
  BW_DB_USERNAME="$PG_DB_USER"
  BW_DB_PASSWORD="$PG_DB_PASS"
  ;;
sqlserver)
  msg_info "Installing MS SQL Server"
  setup_deb822_repo \
    "mssql-server" \
    "https://packages.microsoft.com/keys/microsoft.asc" \
    "https://packages.microsoft.com/ubuntu/22.04/mssql-server-2022" \
    "jammy" \
    "main"
  $STD apt update
  $STD apt install -y mssql-server
  BW_DB_PASSWORD=$(openssl rand -base64 24)
  MSSQL_PID=Express ACCEPT_EULA=Y MSSQL_SA_PASSWORD="$BW_DB_PASSWORD" /opt/mssql/bin/mssql-conf -n setup accept-eula >/dev/null
  $STD apt install -y mssql-tools18 unixodbc-dev
  BW_DB_SERVER=localhost
  BW_DB_DATABASE=vault
  BW_DB_USERNAME=sa
  /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P "$BW_DB_PASSWORD" -Q "CREATE DATABASE $BW_DB_DATABASE;"
  msg_ok "Installed MS SQL Server"
  ;;
*)
  BW_DB_PROVIDER=sqlite
  BW_DB_FILE=/etc/bitwarden/vault.db
  ;;
esac

msg_info "Fetching Bitwarden Version Information"
VERSION_JSON=$(curl -fsSL https://raw.githubusercontent.com/bitwarden/self-host/main/version.json)
SERVER_TAG=$(echo "$VERSION_JSON" | jq -r .versions.coreVersion)
WEB_TAG=$(echo "$VERSION_JSON" | jq -r .versions.webVersion)
msg_ok "Fetched Bitwarden Version Information (server ${SERVER_TAG}, web ${WEB_TAG})"

cat <<'EOF' >/opt/bitwarden/bin/fetch-image.sh
#!/usr/bin/env bash
# Extracts /app from a container image without a Docker daemon, matching
# what bitwarden-lite's Dockerfile does with `COPY --from=<image> /app ...`.
# Every bitwarden/* image shares the same base layers, so a shared blob dir
# (skopeo's oci: transport, not dir:) lets skopeo skip re-downloading them
# for every service - it prints "Skipping blob ... (already present)".
set -euo pipefail
image="$1"
tag="$2"
dest="$3"

blobs=/opt/bitwarden/bin/.blob-cache
mkdir -p "$blobs"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

skopeo copy --remove-signatures --dest-shared-blob-dir "$blobs" \
  "docker://${image}:${tag}" "oci:${work}/img:latest" >/dev/null

manifest_digest=$(jq -r '.manifests[0].digest' "${work}/img/index.json" | sed 's/^sha256://')
mkdir -p "${work}/rootfs"
for digest in $(jq -r '.layers[].digest' "${blobs}/sha256/${manifest_digest}" | sed 's/^sha256://'); do
  tar -xf "${blobs}/sha256/${digest}" -C "${work}/rootfs"
done

rm -rf "$dest"
mkdir -p "$dest"
cp -a "${work}/rootfs/app/." "${dest}/"
EOF
chmod +x /opt/bitwarden/bin/fetch-image.sh

cat <<'EOF' >/opt/bitwarden/bin/fetch-all.sh
#!/usr/bin/env bash
# Standalone helper (also called from ct/bitwarden-lite.sh's update_script), so it
# doesn't rely on the framework's msg_info/msg_ok - those aren't sourced here.
# Fetches run in parallel: they're independent, and serial skopeo pulls were the
# main reason installs took several minutes.
set -euo pipefail
: "${SERVER_TAG:?}" "${WEB_TAG:?}"

pids=()
for svc in Admin Api Events Icons Identity Notifications Scim Sso; do
  ( echo "[${svc}] fetching..."
    /opt/bitwarden/bin/fetch-image.sh "ghcr.io/bitwarden/${svc,,}" "$SERVER_TAG" "/opt/bitwarden/app/${svc}"
    echo "[${svc}] done" ) &
  pids+=("$!")
done
( echo "[Web] fetching..."
  /opt/bitwarden/bin/fetch-image.sh "ghcr.io/bitwarden/web" "$WEB_TAG" "/etc/bitwarden/Web"
  echo "[Web] done" ) &
pids+=("$!")

status=0
for pid in "${pids[@]}"; do
  wait "$pid" || status=1
done
((status == 0)) || { echo "One or more image fetches failed" >&2; exit 1; }

echo -n "$SERVER_TAG" >/opt/bitwarden/.server-version
echo -n "$WEB_TAG" >/opt/bitwarden/.web-version
EOF
chmod +x /opt/bitwarden/bin/fetch-all.sh

cat <<'EOF' >/opt/bitwarden/bin/enabled-services.sh
#!/usr/bin/env bash
set -a
source /opt/bitwarden/bitwarden.env
set +a
[[ "${BW_ENABLE_ADMIN:-true}" == "true" ]] && echo bitwarden-admin
[[ "${BW_ENABLE_API:-true}" == "true" ]] && echo bitwarden-api
[[ "${BW_ENABLE_EVENTS:-false}" == "true" ]] && echo bitwarden-events
[[ "${BW_ENABLE_ICONS:-true}" == "true" ]] && echo bitwarden-icons
[[ "${BW_ENABLE_IDENTITY:-true}" == "true" ]] && echo bitwarden-identity
[[ "${BW_ENABLE_NOTIFICATIONS:-true}" == "true" ]] && echo bitwarden-notifications
[[ "${BW_ENABLE_SCIM:-false}" == "true" ]] && echo bitwarden-scim
[[ "${BW_ENABLE_SSO:-false}" == "true" ]] && echo bitwarden-sso
EOF
chmod +x /opt/bitwarden/bin/enabled-services.sh

SERVER_TAG="$SERVER_TAG" WEB_TAG="$WEB_TAG" /opt/bitwarden/bin/fetch-all.sh

msg_info "Writing Configuration"
IDENTITY_KEY=$(openssl rand -hex 30)
OIDC_CLIENT_KEY=$(openssl rand -hex 30)
DUO_AKEY=$(openssl rand -hex 30)
CERT_PASSWORD=$(openssl rand -hex 16)

cat <<EOF >/opt/bitwarden/bitwarden.env
ASPNETCORE_ENVIRONMENT="Production"
DOTNET_SYSTEM_GLOBALIZATION_INVARIANT="false"
BW_DOMAIN="${BW_DOMAIN}"
BW_ENABLE_SSL="true"
BW_ENABLE_ADMIN="true"
BW_ENABLE_API="true"
BW_ENABLE_EVENTS="false"
BW_ENABLE_ICONS="true"
BW_ENABLE_IDENTITY="true"
BW_ENABLE_NOTIFICATIONS="true"
BW_ENABLE_SCIM="false"
BW_ENABLE_SSO="false"
globalSettings__selfHosted="true"
globalSettings__liteDeployment="true"
globalSettings__pushRelayBaseUri="https://push.bitwarden.com"
globalSettings__baseServiceUri__vault="https://${BW_DOMAIN}"
globalSettings__baseServiceUri__internalVault="https://localhost:443"
globalSettings__baseServiceUri__internalAdmin="http://localhost:5000"
globalSettings__baseServiceUri__internalApi="http://localhost:5001"
globalSettings__baseServiceUri__internalEvents="http://localhost:5003"
globalSettings__baseServiceUri__internalIcons="http://localhost:5004"
globalSettings__baseServiceUri__internalIdentity="http://localhost:5005"
globalSettings__baseServiceUri__internalNotifications="http://localhost:5006"
globalSettings__baseServiceUri__internalScim="http://localhost:5002"
globalSettings__baseServiceUri__internalSso="http://localhost:5007"
globalSettings__installation__id="${BW_INSTALLATION_ID:-00000000-0000-0000-0000-000000000000}"
globalSettings__installation__key="${BW_INSTALLATION_KEY:-}"
globalSettings__internalIdentityKey="${IDENTITY_KEY}"
globalSettings__oidcIdentityClientKey="${OIDC_CLIENT_KEY}"
globalSettings__duo__aKey="${DUO_AKEY}"
globalSettings__identityServer__certificatePassword="${CERT_PASSWORD}"
globalSettings__databaseProvider="${BW_DB_PROVIDER}"
globalSettings__mysql__connectionString="server=${BW_DB_SERVER:-};port=${BW_DB_PORT:-3306};database=${BW_DB_DATABASE:-};user=${BW_DB_USERNAME:-};password=${BW_DB_PASSWORD:-}"
globalSettings__postgreSql__connectionString="Host=${BW_DB_SERVER:-};Port=${BW_DB_PORT:-5432};Database=${BW_DB_DATABASE:-};Username=${BW_DB_USERNAME:-};Password=${BW_DB_PASSWORD:-}"
globalSettings__sqlServer__connectionString="Server=${BW_DB_SERVER:-},${BW_DB_PORT:-1433};Database=${BW_DB_DATABASE:-};User Id=${BW_DB_USERNAME:-};Password=${BW_DB_PASSWORD:-};Encrypt=True;TrustServerCertificate=True"
globalSettings__sqlite__connectionString="Data Source=${BW_DB_FILE:-/etc/bitwarden/vault.db};"
globalSettings__dataProtection__directory="/etc/bitwarden/data-protection"
globalSettings__attachment__baseDirectory="/etc/bitwarden/attachments"
globalSettings__send__baseDirectory="/etc/bitwarden/attachments/send"
globalSettings__licenseDirectory="/etc/bitwarden/licenses"
globalSettings__logDirectoryByProject="false"
globalSettings__logRollBySizeLimit="1073741824"
EOF
chmod 600 /opt/bitwarden/bitwarden.env
msg_ok "Wrote Configuration"

msg_info "Generating Certificates"
openssl req -x509 -newkey rsa:4096 -sha256 -nodes -days 36500 \
  -keyout /etc/bitwarden/identity.key -out /etc/bitwarden/identity.crt \
  -subj "/CN=Bitwarden IdentityServer"
openssl pkcs12 -export -out /etc/bitwarden/identity.pfx \
  -inkey /etc/bitwarden/identity.key -in /etc/bitwarden/identity.crt \
  -passout pass:"$CERT_PASSWORD"
rm -f /etc/bitwarden/identity.key /etc/bitwarden/identity.crt
cp /etc/bitwarden/identity.pfx /opt/bitwarden/app/Identity/identity.pfx
cp /etc/bitwarden/identity.pfx /opt/bitwarden/app/Sso/identity.pfx

TMP_OPENSSL_CONF=$(mktemp)
cat /etc/ssl/openssl.cnf >"$TMP_OPENSSL_CONF"
printf "\n[SAN]\nsubjectAltName=DNS:%s\nbasicConstraints=CA:true\n" "$BW_DOMAIN" >>"$TMP_OPENSSL_CONF"
openssl req -x509 -newkey rsa:4096 -sha256 -nodes -days 36500 \
  -keyout /etc/bitwarden/ssl.key -out /etc/bitwarden/ssl.crt \
  -reqexts SAN -extensions SAN -config "$TMP_OPENSSL_CONF" \
  -subj "/C=US/ST=California/L=Santa Barbara/O=Bitwarden Inc./OU=Bitwarden/CN=${BW_DOMAIN}"
rm -f "$TMP_OPENSSL_CONF"
cp /etc/bitwarden/ssl.crt /usr/local/share/ca-certificates/bitwarden.crt
update-ca-certificates >/dev/null
msg_ok "Generated Certificates"

msg_info "Configuring Nginx"
mkdir -p /etc/hbs
for f in nginx.conf proxy.conf mime.types security-headers.conf security-headers-ssl.conf; do
  curl -fsSL "https://raw.githubusercontent.com/bitwarden/self-host/main/bitwarden-lite/nginx/${f}" -o "/etc/nginx/${f}"
done
for f in nginx-config.hbs app-id.hbs config.yaml; do
  curl -fsSL "https://raw.githubusercontent.com/bitwarden/self-host/main/bitwarden-lite/hbs/${f}" -o "/etc/hbs/${f}"
done

HBS_ARCH=$(dpkg --print-architecture)
case "$HBS_ARCH" in
amd64) HBS_ASSET="hbs_linux-x64.zip" ;;
arm64) HBS_ASSET="hbs_linux-arm64.zip" ;;
*) HBS_ASSET="hbs_linux-arm.zip" ;;
esac
HBS_TAG=$(curl -fsSL https://api.github.com/repos/bitwarden/Handlebars.conf/git/refs/tags | jq -r 'last(.[].ref)' | sed 's#refs/tags/##')
curl -fsSL "https://github.com/bitwarden/Handlebars.conf/releases/download/${HBS_TAG}/${HBS_ASSET}" -o /tmp/hbs.zip
unzip -o /tmp/hbs.zip -d /usr/local/bin >/dev/null
mv /usr/local/bin/hbs* /usr/local/bin/hbs
chmod +x /usr/local/bin/hbs
rm -f /tmp/hbs.zip

set -a
source /opt/bitwarden/bitwarden.env
set +a
/usr/local/bin/hbs

rm -f /etc/nginx/sites-enabled/default
nginx -t
msg_ok "Configured Nginx"

msg_info "Creating Services"
declare -A SERVICE_PORTS=(
  [Admin]=5000 [Api]=5001 [Scim]=5002 [Events]=5003
  [Icons]=5004 [Identity]=5005 [Notifications]=5006 [Sso]=5007
)
for svc in "${!SERVICE_PORTS[@]}"; do
  port="${SERVICE_PORTS[$svc]}"
  unit="bitwarden-${svc,,}"
  cat <<EOF >"/etc/systemd/system/${unit}.service"
[Unit]
Description=Bitwarden ${svc}
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/bitwarden/app/${svc}
EnvironmentFile=/opt/bitwarden/bitwarden.env
Environment=ASPNETCORE_URLS=http://+:${port}
ExecStart=/opt/bitwarden/app/${svc}/${svc}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
done

cat <<'EOF' >/usr/local/bin/bitwarden-reconfigure
#!/usr/bin/env bash
set -euo pipefail
set -a
source /opt/bitwarden/bitwarden.env
set +a
/usr/local/bin/hbs
mapfile -t services < <(/opt/bitwarden/bin/enabled-services.sh)
systemctl restart "${services[@]}" nginx
EOF
chmod +x /usr/local/bin/bitwarden-reconfigure

systemctl daemon-reload
mapfile -t ENABLED_SERVICES < <(/opt/bitwarden/bin/enabled-services.sh)
systemctl enable -q --now "${ENABLED_SERVICES[@]}"
systemctl enable -q --now nginx
msg_ok "Created Services"

motd_ssh
customize
cleanup_lxc
