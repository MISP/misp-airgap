#!/bin/bash

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
VIOLET='\033[0;35m'
NC='\033[0m' # No Color

error() {
    local msg=$1
    echo -e "${RED}Error: $msg${NC}" > /dev/tty
}

warn() {
    local msg=$1
    echo -e "${YELLOW}Warning: $msg${NC}" > /dev/tty
}

okay() {
    local msg=$1
    echo -e "${GREEN}Info: $msg${NC}" > /dev/tty
}

usage() {
  echo "Usage: $0 -n <old-container-name> -f <image> [-o <new-container-name>]"
  echo "Options:"
  echo "  -n <old-container-name>  Set the name of the container to be updated"
  echo "  -f <path-to-image-file>  Set path to the new image file"
  echo "  -o <new-container-name>  Set the name of the updated container"
  exit 1
}

generate_name(){
    local name="$1"
    echo "${name}-$(date +%Y%m%d%H%M%S)"
}

check_resource_exists() {
    local resource_type="$1"
    local resource_name="$2"

    case "$resource_type" in
        "container")
            lxc info "$resource_name" &>/dev/null
            ;;
        "image")
            lxc image list --format=json | jq -e --arg alias "$resource_name" '.[] | select(.aliases[].name == $alias) | .fingerprint' &>/dev/null
            ;;
        "project")
            lxc project list --format=json | jq -e --arg name "$resource_name" '.[] | select(.name == $name) | .name' &>/dev/null
            ;;
        "storage")
            lxc storage list --format=json | jq -e --arg name "$resource_name" '.[] | select(.name == $name) | .name' &>/dev/null
            ;;
        "network")
            lxc network list --format=json | jq -e --arg name "$resource_name" '.[] | select(.name == $name) | .name' &>/dev/null
            ;;
        "profile")
            lxc profile list --format=json | jq -e --arg name "$resource_name" '.[] | select(.name == $name) | .name' &>/dev/null
            ;;
    esac

    return $?
}

get_current_lxd_project() {
    current_project=$(lxc project list | grep '(current)' | awk '{print $2}')

    if [ -z "$current_project" ]; then
        error "No LXD project found"
        exit 1
    else
        echo "$current_project"
    fi
}

checkSoftwareDependencies() {
    local dependencies=("jq" "yq")

    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            error "$dep is not installed."
            exit 1
        fi
    done
}

checkSoftwareDependencies

while getopts ":hn:f:p:o:" opt; do
  case $opt in
    n)
      MISP_CONTAINER="$OPTARG"
      ;;
    f)
      FILE="$OPTARG"
      ;;
    o)
      NEW_CONTAINER="$OPTARG"
      ;;
    h)
      usage
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      usage
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      usage
      ;;
  esac
done

if [ -z "$MISP_CONTAINER" ] || [ -z "$FILE" ]; then
  error "Both -n and -f options are mandatory." >&2
  usage
fi

if ! check_resource_exists "container" $MISP_CONTAINER; then
  error "Container does not exist. Please select the container running MISP."
  exit 1
fi

if check_resource_exists "container" $NEW_CONTAINER; then
    error "New container with name $NEW_CONTAINER already exists. Please use a new name."
    exit 1
fi

if [ ! -f "$FILE" ]; then
    error "The specified image file does not exist."
    exit 1
fi

PROJECT_NAME=$(get_current_lxd_project)

if [ -z "$NEW_CONTAINER" ]; then
    NEW_CONTAINER=$(generate_name "misp")
    NEW_IMAGE=$(generate_name "misp")
else
    NEW_IMAGE=$(generate_name "$NEW_CONTAINER")
fi

# check if image fingerprint already exists
hash=$(sha256sum $FILE | cut -c 1-64)
for image in $(lxc query "/1.0/images?recursion=1&project=${PROJECT_NAME}" | jq .[].fingerprint -r); do
    if [ "$image" = "$hash" ]; then
        error "Image $image already imported. Please check update file or delete current image."
        exit 1
    fi
done

# check if image alias already exists
for image in $(lxc image list --project="${PROJECT_NAME}" --format=json | jq -r '.[].aliases[].name'); do
    if [ "$image" = "$NEW_IMAGE" ]; then
        error "Image Name already exists."
        exit 1
    fi
done

# check if cotainer name already exists
for container in $(lxc query "/1.0/images?recursion=1&project=${PROJECT_NAME}" | jq .[].alias -r); do
    if [ "$container" = "$NEW_CONTAINER" ]; then
        error "Container Name already exists."
        exit 1
    fi
done

# Create a temporary directory
temp=$(mktemp -d)

# Check if the directory was created successfully
if [ -z "$temp" ]; then
    error "Creating temporary directory."
    exit 1
fi
okay "Created temporary directory $temp."


# switch to correct project
lxc project switch $PROJECT_NAME

# Pull config
echo "Extract config..."
lxc file pull -r $MISP_CONTAINER/var/www/MISP/app/files /tmp/$temp -v
lxc file pull -r $MISP_CONTAINER/var/www/MISP/app/tmp /tmp/$temp -v
lxc file pull -r $MISP_CONTAINER/var/www/MISP/app/Config /tmp/$temp -v
lxc file pull -r $MISP_CONTAINER/var/www/MISP/app/webroot/img /tmp/$temp/webroot/ -v
lxc file pull $MISP_CONTAINER/var/www/MISP/app/webroot/gpg.asc /tmp/$temp/webroot/ -v
lxc file pull -r $MISP_CONTAINER/var/www/MISP/app/View/Emails/html/Custom /tmp/$temp/View/Emails/html/ -v
lxc file pull -r $MISP_CONTAINER/var/www/MISP/app/View/Emails/text/Custom /tmp/$temp/View/Emails/text/ -v
lxc file pull $MISP_CONTAINER/var/www/MISP/app/Plugin/CakeResque/Config/config.php /tmp/$temp/Plugin/CakeResque/Config/ -v
okay "pulled files"

# stop current MISP container
lxc stop $MISP_CONTAINER
okay "container stopped"


# Import new image
lxc image import $FILE --alias $NEW_IMAGE
okay "Image imported"

# Create new instance
profile=$(lxc config show $MISP_CONTAINER | yq eval '.profiles | join(" ")' -)
lxc launch $NEW_IMAGE $NEW_CONTAINER --profile=$profile
okay "New conatiner created"


# Transfer files to new instance
echo "push config to new instance ..."
lxc file push -r /tmp/$temp/files $NEW_CONTAINER/var/www/MISP/app/ -v
lxc file push -r /tmp/$temp/tmp $NEW_CONTAINER/var/www/MISP/app/ -v
lxc file push -r /tmp/$temp/Config $NEW_CONTAINER/var/www/MISP/app/ -v
lxc file push -r /tmp/$temp/webroot/img $NEW_CONTAINER/var/www/MISP/app/webroot/ -v
lxc file push /tmp/$temp/webroot/gpg.asc $NEW_CONTAINER/var/www/MISP/app/webroot/ -v
lxc file push -r /tmp/$temp/View/Emails/html/Custom $NEW_CONTAINER/var/www/MISP/app/View/Emails/html/ -v
lxc file push -r /tmp/$temp/View/Emails/text/Custom $NEW_CONTAINER/var/www/MISP/app/View/Emails/text/ -v
lxc file push /tmp/$temp/Plugin/CakeResque/Config/config.php $NEW_CONTAINER/var/www/MISP/app/Plugin/CakeResque/Config/ -v
okay "pushed files"

# Set permissions
lxc exec $NEW_CONTAINER -- sudo chown -R www-data:www-data /var/www/MISP/
lxc exec $NEW_CONTAINER -- sudo chmod -R 775 /var/www/MISP/

# Update DB
lxc exec $NEW_CONTAINER -- bash -c 'sudo -u "www-data" -H sh -c "/var/www/MISP/app/Console/cake Admin runUpdates"'

# Cleanup: Remove the temporary directory
rm -r "$temp"
okay "Removed temporary directory."
