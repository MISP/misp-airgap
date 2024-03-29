#!/bin/bash

SERVICE_FILE="updatetracker.service"
SERVICE_PATH="/etc/systemd/system/"
MISP_AIRGAP_PATH="/opt/misp_airgap"
DIR="$(dirname "$0")"
BUILD_DIR="${DIR}/../../build"


log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*"
}
echo "Updating updatetracker service ..."

if systemctl is-active --quiet updatetracker; then
    systemctl stop updatetracker || { log "Failed to stop service"; exit 1; }
    systemctl disable updatetracker || { log "Failed to disable service"; exit 1; }
fi

if [[ -f "$SERVICE_FILE" ]]; then
    cp "${SERVICE_FILE}" "${SERVICE_PATH}" || { log "Failed to copy service file"; exit 1; }
else
    log "Service file $SERVICE_FILE not found"
    exit 1
fi

if [[ -d "$BUILD_DIR" ]]; then
    cp -r "$BUILD_DIR" "$MISP_AIRGAP_PATH/" || { log "Failed to copy build directory"; exit 1; }
else
    log "Build directory $BUILD_DIR does not exist"
    exit 1
fi

systemctl daemon-reload || { log "Failed to reload systemd"; exit 1; }
systemctl enable updatetracker || { log "Failed to enable service"; exit 1; }
systemctl start updatetracker || { log "Failed to start service"; exit 1; }
