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
    PATH_TO_BUILD="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
    MISP_INFO_TEMPLATE_FILE="$PATH_TO_BUILD/templates/misp_info.json"
    MODULES_INFO_TEMPLATE_FILE="$PATH_TO_BUILD/templates/modules_info.json"
    MISP_PATH="/var/www/"
    PROJECT_NAME=$(generateName "misp")
    STORAGE_POOL_NAME=$(generateName "misp")
    NETWORK_NAME=$(generateName "net")
    NETWORK_NAME=${NETWORK_NAME:0:14}
    MISP_CONTAINER=$(generateName "misp")
    MYSQL_CONTAINER=$(generateName "mysql")
    REDIS_CONTAINER=$(generateName "redis")
    MODULES_CONTAINER=$(generateName "modules")
    UBUNTU="ubuntu:22.04"
    BUILD_REDIS_SOURCE=false
    BUILD_MYSQL_SOURCE=false
    REDIS_SERVICE_FILE="$PATH_TO_BUILD/conf/redis.service"
}

setDefaultArgs(){
    default_misp_image="misp"
    default_misp=false
    default_mysql_image="mysql"
    default_mysql=false
    default_redis_image="redis"
    default_redis=false
    default_modules_image="modules"
    default_modules=false
    default_outputdir="/opt/misp_airgap/images/"
    default_sign=false
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
    current_branch=$(lxc exec "$MISP_CONTAINER" -- cat $MISP_PATH/MISP/.git/HEAD | awk '{print $2}')

    echo "$(lxc exec "$MISP_CONTAINER" -- cat $MISP_PATH/MISP/.git/$current_branch)"
}

getMISPVersion(){
    echo "$(lxc exec "$MISP_CONTAINER" -- cat $MISP_PATH/MISP/VERSION.json | jq -r '.major, .minor, .hotfix' | tr '\n' '.' | sed 's/\.$//')"
}

createMISPImage(){
    local container_name="$1"
    local image_name="$2"

    local version
    version=$(getMISPVersion)
    local commit_id
    commit_id=$(getMISPCommitID)

    lxc stop "$container_name" > /dev/null
    lxc publish "$container_name" --alias "$image_name" > /dev/null
    lxc image export "$image_name" "$OUTPUTDIR" > /dev/null
    # Workaround for renaming image
    local new_name
    new_name=${image_name}_v${version}_${commit_id}.tar.gz
    pushd "$OUTPUTDIR" > /dev/null && mv -i "$(ls -t | head -n1)" $new_name 
    popd > /dev/null || exit
    echo $new_name
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

addMISPInstallerInfo(){
    local container=$1
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
   "$MISP_INFO_TEMPLATE_FILE" > info.json

    lxc exec "$container" -- mkdir -p /etc/misp_info
    lxc file push info.json ${container}/etc/misp_info/
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

getMysqlVersion() {
    local container=$1
    local input
    local version
    input=$(lxc exec $container -- mysql --version) 
    version=$(echo "$input" | grep -oP 'Distrib \K[^,]+' || echo "Version not found")
    echo "$version"
}

getModulesCommitID(){
    local container=$1
    local path=/usr/local/src/misp-modules
    current_branch=$(lxc exec $container -- cat $path/.git/HEAD | awk '{print $2}')
    echo "$(lxc exec $container -- cat $path/.git/$current_branch)" 
}

installMISPModules(){
    local container=$1
    sleep 2
    lxc exec $container -- apt update
    lxc exec $container -- apt install python3-pip -y
    lxc exec $container -- pip install --upgrade pip
    lxc exec $container -- sudo apt-get install python3-dev python3-pip libpq5 libjpeg-dev tesseract-ocr libpoppler-cpp-dev imagemagick virtualenv libopencv-dev zbar-tools libzbar0 libzbar-dev libfuzzy-dev build-essential -y
    lxc exec $container -- mkdir -p /var/www/MISP
    lxc exec $container -- sudo chown -R www-data:www-data /var/www/MISP/
    lxc exec $container -- sudo -u www-data virtualenv -p python3 /var/www/MISP/venv
    lxc exec $container --cwd=/usr/local/src/ -- sudo chown -R www-data: .
    lxc exec $container --cwd=/usr/local/src/ -- sudo -u www-data git clone https://github.com/MISP/misp-modules.git
    lxc exec $container --cwd=/usr/local/src/misp-modules -- sudo -u www-data /var/www/MISP/venv/bin/pip install -I -r REQUIREMENTS
    lxc exec $container --cwd=/usr/local/src/misp-modules -- sudo -u www-data /var/www/MISP/venv/bin/pip install .

    # Configure MISP Modules to listen on external connections
    lxc exec $container -- sed -i 's/127\.0\.0\.1/0\.0\.0\.0/g' "/usr/local/src/misp-modules/etc/systemd/system/misp-modules.service"

    # Start misp-modules as a service
    lxc exec $container --cwd=/usr/local/src/misp-modules -- sudo cp etc/systemd/system/misp-modules.service /etc/systemd/system/
    lxc exec $container -- sudo systemctl daemon-reload
    lxc exec $container -- sudo systemctl enable --now misp-modules
    lxc exec $container -- sudo service misp-modules start
}

createModulesImage(){
    container=$1
    image=$2
    commit_id=$(getModulesCommitID $container)
    lxc stop $container > /dev/null
    lxc publish $container --alias $image > /dev/null
    lxc image export $image $OUTPUTDIR > /dev/null
    # Workaround for renaming image
    local new_name
    new_name=${image}_${commit_id}.tar.gz
    pushd $OUTPUTDIR > /dev/null && mv -i "$(ls -t | head -n1)" $new_name
    popd > /dev/null || return
    echo "$new_name"
}

addModulesInfo(){
    local container=$1
    local commit_id=$(getModulesCommitID $container)
    local date=$(date '+%Y-%m-%d %H:%M:%S')

    # Modify the JSON template as needed using jq
    jq --arg commit_id "$commit_id" --arg date "$date" \
   '.commit_id = $commit_id | .creation_date = $date' \
   "$MODULES_INFO_TEMPLATE_FILE" > info.json

    lxc exec $container -- mkdir -p /etc/misp_modules_info
    lxc file push info.json ${container}/etc/misp_modules_info/
    rm info.json
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

get_redis_version() {
    local container=$1
    local input
    input=$(lxc exec $container -- redis-server --version) 
    local version

    version=$(echo "$input" | grep -oP 'v=\K[^ ]+' || echo "Version not found")
    echo "$version"
}

sign() {
    if ! command -v gpg &> /dev/null; then
        error "GPG is not installed. Please install it before running this script with signing."
        exit 1
    fi
    local file=$1

    # PATH_TO_BUILD="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
    SIGN_CONFIG_FILE="$PATH_TO_BUILD/conf/sign.json"

    if [[ ! -f "$SIGN_CONFIG_FILE" ]]; then
        error "Config file not found: $SIGN_CONFIG_FILE"
        exit 1
    fi

    GPG_KEY_ID=$(jq -r '.GPG_KEY_ID' "$SIGN_CONFIG_FILE")

    # Check if the GPG key is available
    if ! gpg --list-keys | grep -q $GPG_KEY_ID; then
        error "GPG key not found: $GPG_KEY_ID"
        exit 1
    fi

    # Create a directory for the file and its signature
    # FILE_NAME="${file/.tar.gz/}"
    SIGN_DIR="${OUTPUTDIR}${file/.tar.gz/}"
    mkdir -p "$SIGN_DIR"

    # Move the file to the new directory
    mv "${OUTPUTDIR}${file}" "$SIGN_DIR"

    # Change to the directory
    pushd "$SIGN_DIR" || exit

    # Signing the file
    okay "Signing file: $file in directory: $SIGN_DIR with key: $GPG_KEY_ID"
    gpg --default-key $GPG_KEY_ID --detach-sign "${file}"

    # Check if the signing was successful
    if [ $? -eq 0 ]; then
        okay "Successfully signed: $file"
    else
        error "Failed to sign: $file"
        exit 1
    fi
    popd || exit
}

# Main
checkSoftwareDependencies "${DEPEDENCIES[@]}"
setVars
setDefaultArgs

VALID_ARGS=$(getopt -o ho:s --long help,outputdir:,misp,mysql,redis,modules,misp-name:,mysql-name:,redis-name:,modules-name:,sign,redis-version:,mysql-version:  -- "$@")
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
        --misp)
            misp=true
            shift 
            ;;
        --mysql)
            mysql=true
            shift 
            ;;
        --redis)
            redis=true
            shift 
            ;;
        --modules)
            modules=true
            shift 
            ;;
        --misp-name)
            misp_image=$2
            shift 2
            ;;
        --mysql-name)
            mysql_image=$2
            shift 2
            ;;
        --redis-name)
            redis_image=$2
            shift 2
            ;;
        --modules-name)
            modules_image=$2
            shift 2
            ;;
        --redis-version)
            REDIS_VERSION=$2
            BUILD_REDIS_SOURCE=true
            shift 2
            ;;
        --mysql-version)
            MYSQL_VERSION=$2
            BUILD_MYSQL_SOURCE=true
            shift 2
            ;;
        -o | --outputdir)
            outputdir=$2
            shift 2
            ;;
        -s | --sign)
            sign=true
            shift 
            ;;
        *)  
            break 
            ;;
    esac
done

MISP=${misp:-$default_misp}
MYSQL=${mysql:-$default_mysql}
REDIS=${redis:-$default_redis}
MODULES=${modules:-$default_modules}
MISP_IMAGE=${misp_image:-$default_misp_image}
MYSQL_IMAGE=${mysql_image:-$default_mysql_image}
REDIS_IMAGE=${redis_image:-$default_redis_image}
MODULES_IMAGE=${modules_image:-$default_modules_image}
OUTPUTDIR=${outputdir:-$default_outputdir}
SIGN=${sign:-$default_sign}
    
if [ ! -e "$OUTPUTDIR" ]; then
    error "The specified directory does not exist."
    exit 1
fi

if ! $MISP && ! $MYSQL && ! $REDIS && ! $MODULES; then
    error "No image specified!"
    exit 1
fi

trap cleanup EXIT

# Project setup
lxc project create "$PROJECT_NAME"
lxc project switch "$PROJECT_NAME"
lxc storage create "$STORAGE_POOL_NAME" "dir" 
lxc network create "$NETWORK_NAME"

if $MISP; then
    # lxc launch $UBUNTU "$MISP_CONTAINER" -p default --storage "$STORAGE_POOL_NAME" --network "$NETWORK_NAME"
    lxc launch ubuntu:20.04 "$MISP_CONTAINER" -p default --storage "$STORAGE_POOL_NAME" --network "$NETWORK_NAME"
    waitForContainer "$MISP_CONTAINER"
    installMISP "$MISP_CONTAINER"
    # Push info to container
    addMISPInstallerInfo "$MISP_CONTAINER"
    # Create image
    misp_image_name=$(createMISPImage "$MISP_CONTAINER" "$MISP_IMAGE")
    warn $misp_image_name
    if $SIGN; then
        sign $misp_image_name
    fi
fi

if $MYSQL; then
    lxc launch $UBUNTU "$MYSQL_CONTAINER" -p default --storage "$STORAGE_POOL_NAME" --network "$NETWORK_NAME"
    waitForContainer "$MYSQL_CONTAINER"
    # Install MySQL
    lxc exec $MYSQL_CONTAINER -- apt update
    lxc exec $MYSQL_CONTAINER -- apt install -y mariadb-server
    mysql_version=$(getMysqlVersion $MYSQL_CONTAINER)
    # Create Image
    lxc stop $MYSQL_CONTAINER
    lxc publish $MYSQL_CONTAINER --alias $MYSQL_IMAGE
    lxc image export $MYSQL_IMAGE $OUTPUTDIR
    # Workaround for renaming image
    mysql_image_name=${MYSQL_IMAGE}_${mysql_version}.tar.gz
    pushd $OUTPUTDIR && mv -i "$(ls -t | head -n1)" $mysql_image_name
    popd || exit 
    if $SIGN; then
        sign $mysql_image_name
    fi
fi

if $REDIS; then
    lxc launch $UBUNTU "$REDIS_CONTAINER" -p default --storage "$STORAGE_POOL_NAME" --network "$NETWORK_NAME"
    waitForContainer "$REDIS_CONTAINER"

    if $BUILD_REDIS_SOURCE; then
        # Install Redis
        lxc exec $REDIS_CONTAINER -- apt update
        lxc exec $REDIS_CONTAINER -- apt install -y wget build-essential tcl
        lxc exec $REDIS_CONTAINER -- wget http://download.redis.io/releases/redis-$REDIS_VERSION.tar.gz && \
        lxc exec $REDIS_CONTAINER -- tar xzf redis-$REDIS_VERSION.tar.gz && \
        lxc exec $REDIS_CONTAINER --cwd=/root/redis-$REDIS_VERSION -- make && \
        lxc exec $REDIS_CONTAINER --cwd=/root/redis-$REDIS_VERSION -- make install
        # Create redis service
        lxc exec $REDIS_CONTAINER -- mkdir -p /etc/redis
        lxc exec $REDIS_CONTAINER --cwd=/root/redis-$REDIS_VERSION -- cp redis.conf /etc/redis/redis.conf
        lxc file push $REDIS_SERVICE_FILE $REDIS_CONTAINER/etc/systemd/system/redis.service -v
        lxc exec $REDIS_CONTAINER -- adduser --system --group --no-create-home redis
        lxc exec $REDIS_CONTAINER -- mkdir -p /var/lib/redis
        lxc exec $REDIS_CONTAINER -- chown redis:redis /var/lib/redis
        lxc exec $REDIS_CONTAINER -- chmod 770 /var/lib/redis
        lxc exec $REDIS_CONTAINER -- systemctl daemon-reload
        lxc exec $REDIS_CONTAINER -- systemctl enable redis
        lxc exec $REDIS_CONTAINER -- systemctl start redis
    else
        lxc exec $REDIS_CONTAINER -- apt update 
        lxc exec $REDIS_CONTAINER -- apt install redis-server -y
    fi

    redis_version=$(get_redis_version $REDIS_CONTAINER)
    # Create Image
    lxc stop $REDIS_CONTAINER
    lxc publish $REDIS_CONTAINER --alias $REDIS_IMAGE
    lxc image export $REDIS_IMAGE $OUTPUTDIR
    # Workaround for renaming image
    redis_image_name=${REDIS_IMAGE}_${redis_version}.tar.gz
    pushd $OUTPUTDIR && mv -i "$(ls -t | head -n1)" $redis_image_name
    popd || exit
    if $SIGN; then
        sign $redis_image_name
    fi
fi

if $MODULES; then
    lxc launch $UBUNTU "$MODULES_CONTAINER" -p default --storage "$STORAGE_POOL_NAME" --network "$NETWORK_NAME"
    installMISPModules $MODULES_CONTAINER
    addModulesInfo $MODULES_CONTAINER
    sleep 10
    if [ "$(lxc exec $MODULES_CONTAINER systemctl is-active misp-modules)" = "active" ]; then
        okay "Service misp-modules is running."
    else
        error "Service misp-modules is not running."
        lxc stop $MODULES_CONTAINER
        cleanup
        exit 1
    fi
    mysql_image_name=$(createModulesImage $MODULES_CONTAINER $MODULES_IMAGE)
    if $SIGN; then
        sign $mysql_image_name
    fi
fi

