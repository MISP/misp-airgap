#!/bin/bash

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
VIOLET='\033[0;35m'
NC='\033[0m' # No Color

getInstallerCommitID(){
    commit_id=$(curl -s "$REPO_URL/commits/main" | jq -r '.sha')
    echo "Current commit ID: $commit_id"
}

getInstallerHashes(){
    sha_file=$1
    file_contents=$(curl -s "$REPO_URL/contents/build/$sha_file" | jq -r '.content')
    decoded_contents=$(echo "$file_contents" | base64 -d)
    echo "Hash: $decoded_contents"
}

getMISPCommitID(){
    current_branch=$(lxc exec $CONTAINER -- cat $MISP_PATH/MISP/.git/HEAD | awk '{print $2}')

    echo "$(lxc exec $CONTAINER -- cat $MISP_PATH/MISP/.git/$current_branch)"
}

getMISPVersion(){
    echo "$(lxc exec $CONTAINER -- cat $MISP_PATH/MISP/VERSION.json | jq -r '.major, .minor, .hotfix' | tr '\n' '.' | sed 's/\.$//')"
}

createImage(){
    local container_name="$1"
    local image_name="$2"

    local version=$(getMISPVersion)
    local commit_id=$(getMISPCommitID)

    lxc stop $container_name
    lxc publish $container_name --alias $image_name
    #setImageDescription "$version" "$commit_id" "$image_name"
    lxc image export $image_name $OUTPUTDIR
    # Workaround for renaming image
    cd $OUTPUTDIR && mv -i "$(ls -t | head -n1)" ${image_name}_v${version}_${commit_id}.tar.gz
}

installMISP(){
    local container_name="$1"

    sleep 2
    lxc exec "$container_name" -- apt update
    # Add MISP user
    lxc exec "$container_name" -- useradd -m -s /bin/bash "misp"

    if lxc exec "$container_name" -- id "misp" &>/dev/null; then
        # Add the user to the sudo group
        lxc exec "$container_name" -- usermod -aG sudo "misp"
        echo "User misp has been added to the sudoers group."
    else
        echo "User misp does not exist."
        exit 1
    fi

    lxc exec "$container_name" -- bash -c "echo 'misp ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/misp"
    lxc exec "$container_name" -- wget --no-cache -O /tmp/AIRGAP_INSTALL.sh https://raw.githubusercontent.com/MISP/misp-airgap/main/build/AIRGAP_INSTALL.sh
    lxc exec "$container_name" -- sudo -u "misp" -H sh -c "bash /tmp/AIRGAP_INSTALL.sh -c"

    # set misp.live false
    lxc exec $container_name -- sudo -u www-data -H sh -c "$MISP_PATH/MISP/app/Console/cake Admin setSetting MISP.live false --force"
}

waitForContainer() {
    local container_name="$1"

    sleep 1
    while true; do
        status=$(lxc list --format=json | jq -e --arg name "$container_name"  '.[] | select(.name == $name) | .status')
        if [ $status = "\"Running\"" ]; then
            echo -e "${BLUE}$container_name ${GREEN}is running.${NC}"
            break
        fi
        echo "Waiting for $container_name container to start."
        sleep 5
    done
}

cleanupProject(){
    local project="$1"

    echo "Starting cleanup ..."
    echo "Deleting container in project"
    for container in $(lxc query "/1.0/containers?recursion=1&project=${project}" | jq .[].name -r); do
        lxc delete --project "${project}" -f "${container}"
    done

    echo "Deleting images in project"
    for image in $(lxc query "/1.0/images?recursion=1&project=${project}" | jq .[].fingerprint -r); do
        lxc image delete --project "${project}" "${image}"
    done

    echo "Deleting project"
    lxc project delete "${project}"
}

checkRessourcExist() {
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


generateName(){
    local name="$1"
    echo "${name}-$(date +%Y%m%d%H%M%S)"
}

addInstallerInfo(){
    # TODO: Add installer info
    lxc exec $CONTAINER -- apt install curl -y
    lxc exec $CONTAINER -- apt install jq -y
    getInstallerCommitID
    getInstallerHashes "AIRGAP_INSTALL.sh.sha1"

    local version=$(getMISPVersion)
    local commit_id=$(getMISPCommitID)
    local date=$(date '+%Y-%m-%d %H:%M:%S')

    # Modify the JSON template as needed using jq
    jq --arg version "$version" --arg commit_id "$commit_id" --arg date "$date" \
   '.misp_version = $version | .commit_id = $commit_id | .creation_date = $date' \
   "$INFO_TEMPLATE_FILE" > info.json

    lxc exec $CONTAINER -- mkdir -p /etc/misp_info
    lxc file push info.json ${CONTAINER}/etc/misp_info/
    rm info.json
}

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <image-name> <outputdir>"
    exit 1
fi

IMAGE=$1
OUTPUTDIR=$2

if [ ! -e "$OUTPUTDIR" ]; then
    echo -e "${RED}Error${NC}: The specified directory does not exist."
    exit 1
fi

REPO_URL="https://api.github.com/repos/MISP/misp-airgap/"
INFO_TEMPLATE_FILE="./templates/misp_info.json"
MISP_PATH="/var/www/"
CONFIG_TEMPLATE="./conf/config.yaml"
PROJECT_NAME=$(generateName "misp")
CONTAINER=$(generateName "misp")
STORAGE_POOL_NAME=$(generateName "misp")
NETWORK_NAME=$(generateName "net")
NETWORK_NAME=${NETWORK_NAME:0:15}

lxc project create "$PROJECT_NAME"
lxc project switch "$PROJECT_NAME"

lxc storage create "$STORAGE_POOL_NAME" "dir" 

lxc network create "$NETWORK_NAME"

lxc launch ubuntu:20.04 "$CONTAINER" -p default --storage "$STORAGE_POOL_NAME" --network "$NETWORK_NAME"
waitForContainer "$CONTAINER"
installMISP "$CONTAINER"

# Push info to container
addInstallerInfo

# Create image
createImage "$CONTAINER" "$IMAGE"

cleanupProject "$PROJECT_NAME"
lxc storage delete "$STORAGE_POOL_NAME"
lxc network delete "$NETWORK_NAME"
