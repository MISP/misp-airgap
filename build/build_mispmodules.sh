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

generateName(){
    local name="$1"
    echo "${name}-$(date +%Y%m%d%H%M%S)"
}

setVars(){
    PROJECT_NAME=$(generateName "misp")
    CONTAINER=$(generateName "modules")
    STORAGE_POOL_NAME=$(generateName "misp")
    NETWORK_NAME=$(generateName "net")
    NETWORK_NAME=${NETWORK_NAME:0:15}
    LXC_EXEC="lxc exec $CONTAINER"
    INFO_TEMPLATE_FILE="./templates/modules_info.json"
}

setupLXD(){
lxc project create "$PROJECT_NAME"
lxc project switch "$PROJECT_NAME"
lxc storage create "$STORAGE_POOL_NAME" "dir"
lxc network create "$NETWORK_NAME"
}

installMISPModules(){
    sleep 2
    ${LXC_EXEC} -- apt update
    ${LXC_EXEC} -- apt install python3-pip -y
    ${LXC_EXEC} -- pip install --upgrade pip
    ${LXC_EXEC} -- sudo apt-get install python3-dev python3-pip libpq5 libjpeg-dev tesseract-ocr libpoppler-cpp-dev imagemagick virtualenv libopencv-dev zbar-tools libzbar0 libzbar-dev libfuzzy-dev build-essential -y
    # ${LXC_EXEC} -- mkdir /var/www
    ${LXC_EXEC} -- mkdir -p /var/www/MISP
    ${LXC_EXEC} -- sudo chown -R www-data:www-data /var/www/MISP/
    ${LXC_EXEC} -- sudo -u www-data virtualenv -p python3 /var/www/MISP/venv
    ${LXC_EXEC} --cwd=/usr/local/src/ -- sudo chown -R www-data: .
    ${LXC_EXEC} --cwd=/usr/local/src/ -- sudo -u www-data git clone https://github.com/MISP/misp-modules.git
    ${LXC_EXEC} --cwd=/usr/local/src/misp-modules -- sudo -u www-data /var/www/MISP/venv/bin/pip install -I -r REQUIREMENTS
    ${LXC_EXEC} --cwd=/usr/local/src/misp-modules -- sudo -u www-data /var/www/MISP/venv/bin/pip install .

    # Configure MISP Modules to listen on external connections
    ${LXC_EXEC} -- sed -i 's/127\.0\.0\.1/0\.0\.0\.0/g' "/usr/local/src/misp-modules/etc/systemd/system/misp-modules.service"

    # Start misp-modules as a service
    ${LXC_EXEC} --cwd=/usr/local/src/misp-modules -- sudo cp etc/systemd/system/misp-modules.service /etc/systemd/system/
    ${LXC_EXEC} -- sudo systemctl daemon-reload
    ${LXC_EXEC} -- sudo systemctl enable --now misp-modules
    ${LXC_EXEC} -- sudo service misp-modules start
}

createImage(){
    commit_id=$(getModulesCommitID)
    lxc stop $CONTAINER
    lxc publish $CONTAINER --alias $IMAGE
    #setImageDescription "$version" "$commit_id" "$IMAGE"
    lxc image export $IMAGE $OUTPUTDIR
    # Workaround for renaming image
    cd $OUTPUTDIR && mv -i "$(ls -t | head -n1)" ${IMAGE}_${commit_id}.tar.gz
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

checkSoftwareDependencies() {
    local dependencies=("jq")

    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo -e "${RED}Error: $dep is not installed.${NC}"
            exit 1
        fi
    done
}

getModulesCommitID(){
    local path=/usr/local/src/misp-modules
    current_branch=$(lxc exec $CONTAINER -- cat $path/.git/HEAD | awk '{print $2}')
    echo "$(lxc exec $CONTAINER -- cat $path/.git/$current_branch)" 
}


addModulesInfo(){
    local commit_id=$(getModulesCommitID)
    local date=$(date '+%Y-%m-%d %H:%M:%S')

    # Modify the JSON template as needed using jq
    jq --arg commit_id "$commit_id" --arg date "$date" \
   '.commit_id = $commit_id | .creation_date = $date' \
   "$INFO_TEMPLATE_FILE" > info.json

    lxc exec $CONTAINER -- mkdir -p /etc/misp_modules_info
    lxc file push info.json ${CONTAINER}/etc/misp_modules_info/
    rm info.json
}

# Main
checkSoftwareDependencies
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
setVars
setupLXD
lxc launch ubuntu:22.04 "$CONTAINER" -p default --storage "$STORAGE_POOL_NAME" --network "$NETWORK_NAME"
installMISPModules
addModulesInfo
sleep 10
if [ "$(${LXC_EXEC} systemctl is-active misp-modules)" = "active" ]; then
    okay "Service misp-modules is running."
else
    error "Service misp-modules is not running."
    lxc stop $CONTAINER
    cleanupProject "$PROJECT_NAME"
    lxc storage delete "$STORAGE_POOL_NAME"
    lxc network delete "$NETWORK_NAME"
    exit 1
fi
createImage
cleanupProject "$PROJECT_NAME"
lxc storage delete "$STORAGE_POOL_NAME"
lxc network delete "$NETWORK_NAME"