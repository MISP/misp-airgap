#!/bin/bash

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Software Depedencies
DEPEDENCIES=(jq curl)

setVars(){
    REPO_URL="https://api.github.com/repos/MISP/misp-airgap"
    INFO_TEMPLATE_FILE="./templates/misp_info.json"
    MISP_PATH="/var/www/"
    PROJECT_NAME=$(generateName "misp")
    CONTAINER=$(generateName "misp")
    STORAGE_POOL_NAME=$(generateName "misp")
    NETWORK_NAME=$(generateName "net")
    NETWORK_NAME=${NETWORK_NAME:0:14}
}

setDefaultArgs(){
    default_image="misp"
    default_outputdir="/opt/misp_airgap/images/"
}

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


getInstallerCommitID(){
    commit_id=$(curl -s $REPO_URL/commits/main | jq -e -r '.sha // empty')
    if [ -z "$commit_id" ]; then
        error "Unable to retrieve commit ID."
        exit 1
    fi
    echo "$commit_id"
}

getInstallerHash(){
    sha_file=$1
    file_contents=$(curl -s "$REPO_URL/contents/build/$sha_file" | jq -e -r '.content // empty')
    if [ -z "$file_contents" ]; then
        error "Unable to retrieve hash from $sha_file."
        exit 1
    fi
    decoded_contents=$(echo "$file_contents" | base64 -d | cut -f1 -d\ )
    echo "$decoded_contents"
}

getMISPCommitID(){
    current_branch=$(lxc exec "$CONTAINER" -- cat $MISP_PATH/MISP/.git/HEAD | awk '{print $2}')

    echo "$(lxc exec "$CONTAINER" -- cat $MISP_PATH/MISP/.git/$current_branch)"
}

getMISPVersion(){
    echo "$(lxc exec "$CONTAINER" -- cat $MISP_PATH/MISP/VERSION.json | jq -r '.major, .minor, .hotfix' | tr '\n' '.' | sed 's/\.$//')"
}

createImage(){
    local container_name="$1"
    local image_name="$2"

    local version
    version=$(getMISPVersion)
    local commit_id
    commit_id=$(getMISPCommitID)

    lxc stop "$container_name"
    lxc publish "$container_name" --alias "$image_name"
    #setImageDescription "$version" "$commit_id" "$image_name"
    lxc image export "$image_name" "$OUTPUTDIR"
    # Workaround for renaming image
    cd "$OUTPUTDIR" && mv -i "$(ls -t | head -n1)" ${image_name}_v${version}_${commit_id}.tar.gz
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
}

waitForContainer() {
    local container_name="$1"

    sleep 1
    while true; do
        status=$(lxc list --format=json | jq -e --arg name "$container_name"  '.[] | select(.name == $name) | .status')
        if [ "$status" = "\"Running\"" ]; then
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

cleanup(){
    cleanupProject "$PROJECT_NAME"
    lxc storage delete "$STORAGE_POOL_NAME"
    lxc network delete "$NETWORK_NAME"
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
    # MISP info
    local version
    version=$(getMISPVersion)
    local misp_commit_id
    misp_commit_id=$(getMISPCommitID)

    local date
    date=$(date '+%Y-%m-%d %H:%M:%S')

    # Installer info
    local installer_commit_id
    installer_commit_id=$(getInstallerCommitID)
    local sha1
    sha1=$(getInstallerHash "AIRGAP_INSTALL.sh.sha1")
    local sha256
    sha256=$(getInstallerHash "AIRGAP_INSTALL.sh.sha256")
    local sha384
    sha384=$(getInstallerHash "AIRGAP_INSTALL.sh.sha384")
    local sha512
    sha512=$(getInstallerHash "AIRGAP_INSTALL.sh.sha512")

    # Modify the JSON template as needed using jq
    jq --arg version "$version" --arg commit_id "$misp_commit_id" --arg date "$date" --arg installer_commit_id "$installer_commit_id" --arg sha1 "$sha1" --arg sha256 "$sha256" --arg sha384 "$sha384" --arg sha512 "$sha512"\
   '.misp_version = $version | .commit_id = $commit_id | .creation_date = $date | .installer.commit_id = $installer_commit_id | .installer.sha1 = $sha1 | .installer.sha256 = $sha256 | .installer.sha384 = $sha384 | .installer.sha512 = $sha512' \
   "$INFO_TEMPLATE_FILE" > info.json

    lxc exec "$CONTAINER" -- mkdir -p /etc/misp_info
    lxc file push info.json ${CONTAINER}/etc/misp_info/
    rm info.json
}

checkSoftwareDependencies(){

    for dep in "$@"; do
        if ! command -v "$dep" &> /dev/null; then
            echo -e "${RED}Error: $dep is not installed.${NC}"
            exit 1
        fi
    done
}

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  -h, --help       Show this help message and exit."
    echo "  -n, --name       Specify the name of the image to create. Default is 'misp'."
    echo "  -o, --outputdir  Specify the output directory for the created image. Default is '/opt/misp_airgap/'."
    echo
    echo "Description:"
    echo "  This script sets up a container for MISP, installs MISP within it,"
    echo "  and then creates an image of this installation."
}

# Main
checkSoftwareDependencies "${DEPEDENCIES[@]}"
setVars
setDefaultArgs

VALID_ARGS=$(getopt -o hn:o: --long help,name:,outputdir:  -- "$@")
if [[ $? -ne 0 ]]; then
    exit 1;
fi

eval set -- "$VALID_ARGS"
while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help)
            usage
            exit 0 
            ;;
        -n | --name)
            image=$2
            shift 2
            ;;
        -o | --outputdir)
            outputdir=$2
            shift 2
            ;;
        *)  
            break 
            ;;
    esac
done

IMAGE=${image:-$default_image}
OUTPUTDIR=${outputdir:-$default_outputdir}
    

if [ ! -e "$OUTPUTDIR" ]; then
    echo -e "Error: The specified directory does not exist."
    exit 1
fi

trap cleanup EXIT

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

