#!/bin/bash

DIR="$(dirname "$0")"
SERVICE_FILE="updatetracker.service"
SERVICE_PATH="/etc/systemd/system/"
MISP_AIRGAP_PATH="/opt/misp_airgap"
BUILD_DIR="${DIR}/../../build"
BATCH_FILE="/tmp/key_batch"
SIGN_CONFIG_FILE="../conf/sign.json"

log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*"
}

echo "Start setting up updatetracker service ..."

if [[ $EUID -ne 0 ]]; then
    log "This script must be run as root or with sudo privileges"
    exit 1
fi

if [[ ! -d "$MISP_AIRGAP_PATH" ]]; then
    mkdir -p "$MISP_AIRGAP_PATH"/images || { log "Failed to create directory $MISP_AIRGAP_PATH"; exit 1; }
fi

if [[ -d "$BUILD_DIR" ]]; then
    cp -r "$BUILD_DIR" "$MISP_AIRGAP_PATH/" || { log "Failed to copy build directory"; exit 1; }
else
    log "Build directory $BUILD_DIR does not exist"
    exit 1
fi

# Create user if it doesn't exist
if ! id "updatetracker" &>/dev/null; then
    useradd -r -s /bin/false updatetracker || { log "Failed to create user updatetracker"; exit 1; }
fi

# Set ownership and permissions
chown -R updatetracker: "$MISP_AIRGAP_PATH" || { log "Failed to change ownership"; exit 1; }
chmod -R u+x "$MISP_AIRGAP_PATH/build/"*.py || { log "Failed to set execute permission on scripts"; exit 1; }
chmod -R u+x "$MISP_AIRGAP_PATH/build/"*.sh || { log "Failed to set execute permission on scripts"; exit 1; }
chmod -R u+w "$MISP_AIRGAP_PATH/images/" || { log "Failed to set execute permission on images dir"; exit 1; }

# Add user to lxd group
sudo usermod -aG lxd updatetracker || { log "Failed to add user updatetracker to lxd group"; exit 1; }
mkdir -p /home/updatetracker || { log "Failed to create directory /home/updatetracker"; exit 1; }

# Setup GPG key
KEY_NAME=$(jq -r '.NAME' "$SIGN_CONFIG_FILE")
KEY_EMAIL=$(jq -r '.EMAIL' "$SIGN_CONFIG_FILE")
KEY_COMMENT=$(jq -r '.COMMENT' "$SIGN_CONFIG_FILE")
KEY_EXPIRE=$(jq -r '.EXPIRE_DATE' "$SIGN_CONFIG_FILE")
KEY_PASSPHRASE=$(jq -r '.PASSPHRASE' "$SIGN_CONFIG_FILE")

cat > "$BATCH_FILE" <<EOF
%echo Generating a basic OpenPGP key
Key-Type: default
Subkey-Type: default
Name-Real: ${KEY_NAME}
Name-Comment: ${KEY_COMMENT}
Name-Email: ${KEY_EMAIL}
Expire-Date: ${KEY_EXPIRE}
Passphrase: ${KEY_PASSPHRASE}
%commit
%echo done
EOF

sudo -u updatetracker gpg --batch --generate-key "$BATCH_FILE" || { log "Failed to generate GPG key"; exit 1; }
rm "$BATCH_FILE" || { log "Failed to remove batch file"; exit 1; }

# Copy service file
if [[ -f "$SERVICE_FILE" ]]; then
    cp "${SERVICE_FILE}" "${SERVICE_PATH}" || { log "Failed to copy service file"; exit 1; }
else
    log "Service file $SERVICE_FILE not found"
    exit 1
fi

# Reload systemd, enable and start the service
systemctl daemon-reload || { log "Failed to reload systemd daemon"; exit 1; }
systemctl enable "${SERVICE_FILE}" || { log "Failed to enable service"; exit 1; }
systemctl start "${SERVICE_FILE}" || { log "Failed to start service"; exit 1; }

log "Service setup completed successfully."
