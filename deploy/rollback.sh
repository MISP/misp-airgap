#!/bin/bash

source .env

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <backup>"
    exit 1
fi

BACKUP=$1

# Check if the image alias exists
lxc image list --format=json | jq -e --arg alias "$BACKUP" '.[] | select(.aliases[].name == $alias) | .fingerprint' &>/dev/null
if [ $? -ne 0 ]; then
    echo "Error: Image alias '$BACKUP' does not exist."
    exit 1
fi

# Check if the container alias exists
lxc info $BACKUP &>/dev/null
if [ $? -ne 0 ]; then
    echo "Error: Container alias '$BACKUP' does not exist."
    exit 1
fi

# Switch Project
lxc project switch $PROJECT_NAME

# Delete instance
lxc stop $MISP_CONTAINER
lxc delete $MISP_CONTAINER

# Use "old" container
lxc mv $BACKUP $MISP_CONTAINER
lxc start $MISP_CONTAINER

# Delete image
lxc image delete misp

# Rename "old" image
lxc image alias rename $BACKUP misp

echo "Rollback completed successfully!"
