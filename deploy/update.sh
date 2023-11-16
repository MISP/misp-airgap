#!/bin/bash

source .env

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <backup-name> <source-file>"
    exit 1
fi

BACKUPNAME=$1
FILE=$2

# check whether image fingerprint already exists
hash=$(sha256sum $FILE)
for image in $(lxc query "/1.0/images?recursion=1&project=${project}" | jq .[].fingerprint -r); do
    if [ "$image" = "$hash" ]; then
        echo "Image $image already imported. Please check update file or delete present image."
        exit 1
    fi
done


for image in $(lxc image list --project="${PROJECT_NAME}" --format=json | jq -r '.[].aliases[].name'); do
    if [ "$image" = "$BACKUPNAME" ]; then
        echo "Image Name already exists. Please choose a different backup-name."
        exit 1
    fi
done


for container in $(lxc query "/1.0/images?recursion=1&project=${PROJECT_NAME}" | jq .[].alias -r); do
    if [ "$container" = "$BACKUPNAME" ]; then
        echo "Container Name already exists. Please choose a different backup-name."
        exit 1
    fi
done

# Create a temporary directory
temp=$(mktemp -d)

# Check if the directory was created successfully
if [ -z "$temp" ]; then
    echo "Error creating temporary directory."
    exit 1
fi
echo "Created temporary directory $temp."


# switch to correct project
lxc project switch $PROJECT_NAME

# Pull config
echo "Extract config..."
lxc file pull -r $MISP_CONTAINER/var/www/MISP/app/files /tmp/$temp 
echo "pulled files"
lxc file pull -r $MISP_CONTAINER/var/www/MISP/app/tmp /tmp/$temp 
echo "pulled tmp"
lxc file pull -r $MISP_CONTAINER/var/www/MISP/app/Config /tmp/$temp 
echo "pulled conf"


# stop current MISP container
lxc stop $MISP_CONTAINER
echo "container stopped"

# Rename old container
lxc mv $MISP_CONTAINER $BACKUPNAME
echo "renamed container"

# Import new image
lxc image alias rename misp $BACKUPNAME
lxc image import $FILE --alias misp
echo "Image imported"

# Create new insance
lxc init misp $MISP_CONTAINER --profile=$APP_PROFILE 
lxc network attach $NETWORK_NAME $MISP_CONTAINER eth0 eth0
lxc start $MISP_CONTAINER
echo "New conatiner created"

# Transfer files to new instance
echo "push config to new instance ..."
lxc file push -r /tmp/$temp/files $MISP_CONTAINER/var/www/MISP/app/
echo "pushed files"
lxc file push -r /tmp/$temp/tmp $MISP_CONTAINER/var/www/MISP/app/
echo "pushed tmp"
lxc file push -r /tmp/$temp/Config $MISP_CONTAINER/var/www/MISP/app/
echo "pushed conf"


# Update DB
lxc exec $MISP_CONTAINER -- bash -c 'sudo -u "www-data" -H sh -c "/var/www/MISP/app/Console/cake Admin runUpdates"'


# Cleanup: Remove the temporary directory
rm -r "$temp"
echo "Removed temporary directory."

