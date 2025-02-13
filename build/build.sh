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
    UBUNTU="ubuntu:24.04"
    BUILD_REDIS_VERSION=false
    BUILD_MYSQL_VERSION=false
    REDIS_SERVICE_FILE="$PATH_TO_BUILD/conf/redis-server.service"
}

setDefaultArgs(){
    default_misp_image="MISP"
    default_misp=false
    default_mysql_image="MySQL"
    default_mysql=false
    default_redis_image="Redis"
    default_redis=false
    default_modules_image="Modules"
    default_modules=false
    default_outputdir=""
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

installMISP(){
    local container_name="$1"

    sleep 2
    lxc exec "$container_name" -- sed -i "/#\$nrconf{restart} = 'i';/s/.*/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf
    lxc exec "$container_name" -- apt update
    lxc exec "$container_name" -- apt upgrade -y
    lxc exec "$container_name" -- apt install debconf-utils -y    

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
    lxc exec "$container_name" -- sudo -u "misp" -H sh -c "sudo bash /tmp/AIRGAP_INSTALL.sh -c -u"
    lxc exec "$container_name" -- sed -i "/^\$nrconf{restart} = 'a';/s/.*/#\$nrconf{restart} = 'i';/" /etc/needrestart/needrestart.conf
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

    okay "Starting cleanup ..."
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

generateName(){
    local name="$1"
    echo "${name}-$(date +%Y%m%d%H%M%S)"
}

addMISPInstallerInfo(){
    local container=$1
    local version
    version=$(getVersionGitTag "$container" "$MISP_PATH/MISP" "www-data")
    local misp_commit_id
    misp_commit_id=$(getCommitID "$container" "$MISP_PATH/MISP")

    local date
    date=$(date '+%Y-%m-%d %H:%M:%S')

    # Installer info
    local installer_commit_id
    installer_commit_id=$(getInstallerCommitID)

    # Modify the JSON template as needed using jq
    jq --arg version "$version" --arg commit_id "$misp_commit_id" --arg date "$date" --arg installer_commit_id "$installer_commit_id" --arg sha1 "$sha1" --arg sha256 "$sha256" --arg sha384 "$sha384" --arg sha512 "$sha512"\
   '.misp_version = $version | .commit_id = $commit_id | .creation_date = $date | .installer.commit_id = $installer_commit_id | .installer.sha1 = $sha1 | .installer.sha256 = $sha256 | .installer.sha384 = $sha384 | .installer.sha512 = $sha512' \
   "$MISP_INFO_TEMPLATE_FILE" > /tmp/info.json

    lxc exec "$container" -- mkdir -p /etc/misp_info
    lxc file push /tmp/info.json "${container}"/etc/misp_info/
    rm /tmp/info.json
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
    input=$(lxc exec $container -- mariadb --version)
    if $BUILD_MYSQL_VERSION; then
        version=$(echo "$input" | grep -oP 'mariadb from \K[0-9]+\.[0-9]+\.[0-9]+(?=-MariaDB)' || echo "Version not found")
    else
        version=$(echo "$input" | grep -oP 'Distrib \K[^,]+(?=-MariaDB)' || echo "Version not found")
    fi
    echo "$version"
}

installMISPModules(){
    local container=$1
    sleep 2
    lxc exec "$container" -- sed -i "/#\$nrconf{restart} = 'i';/s/.*/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf
    lxc exec "$container" -- apt update
    lxc exec "$container" -- apt upgrade -y
    lxc exec "$container" -- apt install python3-pip -y
    lxc exec "$container" -- pip install --upgrade pip
    lxc exec "$container" -- sudo apt-get install python3-dev python3-pip libpq5 libjpeg-dev tesseract-ocr libpoppler-cpp-dev imagemagick virtualenv libopencv-dev zbar-tools libzbar0 libzbar-dev libfuzzy-dev build-essential -y
    lxc exec "$container" -- mkdir -p /var/www/MISP
    lxc exec "$container" -- sudo chown -R www-data:www-data /var/www/MISP/
    lxc exec "$container" -- sudo -u www-data virtualenv -p python3 /var/www/MISP/venv
    lxc exec "$container" --cwd=/usr/local/src/ -- sudo chown -R www-data: .
    lxc exec "$container" --cwd=/usr/local/src/ -- sudo -u www-data git clone https://github.com/MISP/misp-modules.git
    lxc exec "$container" --cwd=/usr/local/src/misp-modules -- sudo -u www-data /var/www/MISP/venv/bin/pip install -I -r REQUIREMENTS
    lxc exec "$container" --cwd=/usr/local/src/misp-modules -- sudo -u www-data /var/www/MISP/venv/bin/pip install .

    # Configure MISP Modules to listen on external connections
    lxc exec "$container" -- sed -i 's/127\.0\.0\.1/0\.0\.0\.0/g' "/usr/local/src/misp-modules/etc/systemd/system/misp-modules.service"

    # Start misp-modules as a service
    lxc exec "$container" --cwd=/usr/local/src/misp-modules -- sudo cp etc/systemd/system/misp-modules.service /etc/systemd/system/
    lxc exec "$container" -- sudo systemctl daemon-reload
    lxc exec "$container" -- sudo systemctl enable --now misp-modules
    lxc exec "$container" -- sudo service misp-modules start
    lxc exec "$container" -- sed -i "/^\$nrconf{restart} = 'a';/s/.*/#\$nrconf{restart} = 'i';/" /etc/needrestart/needrestart.conf
}

addModulesInfo(){
    local container=$1
    local commit_id
    commit_id=$(getCommitID "$container" /usr/local/src/misp-modules)
    local date
    date=$(date '+%Y-%m-%d %H:%M:%S')

    # Modify the JSON template as needed using jq
    jq --arg commit_id "$commit_id" --arg date "$date" \
   '.commit_id = $commit_id | .creation_date = $date' \
   "$MODULES_INFO_TEMPLATE_FILE" > /tmp/info.json

    lxc exec "$container" -- mkdir -p /etc/misp_modules_info
    lxc file push /tmp/info.json ${container}/etc/misp_modules_info/
    rm /tmp/info.json
}

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo -e "  -h, --help                     Show this help message and exit."
    echo -e "  --misp                         Create a MISP image."
    echo -e "  --mysql                        Create a MySQL image."
    echo -e "  --redis                        Create a Redis image."
    echo -e "  --modules                      Create a Modules image."
    echo -e "  --misp-name NAME               Specify a custom name for the MISP image."
    echo -e "  --mysql-name NAME              Specify a custom name for the MySQL image."
    echo -e "  --redis-name NAME              Specify a custom name for the Redis image."
    echo -e "  --modules-name NAME            Specify a custom name for the Modules image."
    echo -e "  --redis-version VERSION        Specify a Redis version to build."
    echo -e "  --mysql-version VERSION        Specify a MySQL version to build."
    echo -e "  -o, --outputdir DIRECTORY      Specify the output directory for created images."
    echo -e "  -s, --sign                     Sign the created images."
    echo
    echo "Description:"
    echo "  This script facilitates the setup and creation of container images for"
    echo "  MISP (Malware Information Sharing Platform), MySQL, Redis, and MISP modules."
    echo "  It allows customizing image names, specifying versions, and output directories."
    echo "  Additionally, it can sign the created images for verification purposes."
    echo
}

getRedisVersion() {
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

    GPG_KEY_ID=$(jq -r '.EMAIL' "$SIGN_CONFIG_FILE")
    GPG_KEY_PASSPHRASE=$(jq -r '.PASSPHRASE' "$SIGN_CONFIG_FILE")

    # Check if the GPG key is available
    if ! gpg --list-keys | grep -q $GPG_KEY_ID; then
        warn "GPG key not found: $GPG_KEY_ID. Create new key."
        # Setup GPG key
        KEY_NAME=$(jq -r '.NAME' "$SIGN_CONFIG_FILE")
        KEY_EMAIL=$(jq -r '.EMAIL' "$SIGN_CONFIG_FILE")
        KEY_COMMENT=$(jq -r '.COMMENT' "$SIGN_CONFIG_FILE")
        KEY_EXPIRE=$(jq -r '.EXPIRE_DATE' "$SIGN_CONFIG_FILE")
        KEY_PASSPHRASE=$(jq -r '.PASSPHRASE' "$SIGN_CONFIG_FILE")
        BATCH_FILE=$(mktemp -d)/batch

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

        gpg --batch --generate-key "$BATCH_FILE" || { log "Failed to generate GPG key"; exit 1; }
        rm -r "$BATCH_FILE" || { log "Failed to remove batch file"; exit 1; }
    fi

    # Create a directory for the file and its signature
    # FILE_NAME="${file/.tar.gz/}"
    SIGN_DIR="${OUTPUTDIR}/${file/.tar.gz/}"
    mkdir -p "$SIGN_DIR"

    # Move the file to the new directory
    mv "${OUTPUTDIR}/${file}" "$SIGN_DIR"

    # Change to the directory
    pushd "$SIGN_DIR" || exit

    # Signing the file
    okay "Signing file: $file in directory: $SIGN_DIR with key: $GPG_KEY_ID"
    gpg --default-key "$GPG_KEY_ID" --pinentry-mode loopback --passphrase "$GPG_KEY_PASSPHRASE" --detach-sign "${file}"

    # Check if the signing was successful
    if [ $? -eq 0 ]; then
        okay "Successfully signed: $file"
    else
        error "Failed to sign: $file"
        exit 1
    fi
    popd || exit
}

successMessage(){
    component=$1
    echo "----------------------------------------"
    echo "$component image created successfully."
    echo "----------------------------------------"
}

createLXDImage(){
    local container_name="$1"
    local image_name="$2"
    local application="$3"
    case $application in 
        "MISP" )
            local commit_id
            commit_id=$(getCommitID "$container_name" "$MISP_PATH/MISP")
            local version
            version=$(getVersionGitTag "$container_name" "$MISP_PATH/MISP" "www-data")
            local new_name
            new_name=${image_name}_${version}_${commit_id}.tar.gz
            exportImage "$container_name" "$new_name" "$OUTPUTDIR"
            ;;
        "MySQL" )
            local version
            version=$(getMysqlVersion "$container_name")
            local new_name
            new_name=${image_name}_${version}.tar.gz
            exportImage "$container_name" "$new_name" "$OUTPUTDIR"
            ;;
        "Redis" )
            local version
            version=$(getRedisVersion "$container_name")
            local new_name
            new_name=${image_name}_${version}.tar.gz
            exportImage "$container_name" "$new_name" "$OUTPUTDIR"
            ;;
        "Modules" )
            local commit_id
            commit_id=$(getCommitID "$container_name" /usr/local/src/misp-modules)
            local version
            version=$(getVersionGitTag "$container_name" /usr/local/src/misp-modules "www-data")
            local new_name
            new_name=${image_name}_${version}_${commit_id}.tar.gz
            exportImage "$container_name" "$new_name" "$OUTPUTDIR"
            ;;
    esac
    sleep 2
    if $SIGN; then
        sign "$new_name"
    fi
}

exportImage(){
    local container="$1"
    local new_name="$2"
    lxc stop "$container"
    lxc publish "$container" --alias "$container"
    lxc image export "$container" "$OUTPUTDIR"
    pushd "$OUTPUTDIR" && mv -i "$(ls -t | head -n1)" "$new_name"
    popd || exit
}

getVersionGitTag(){
    local container=$1
    local path=$2
    local user=$3
    local version
    version=$(lxc exec "$container" --cwd="$path" -- sudo -u "$user" bash -c "git tag | sort -V | tail -n 1")
    echo "$version"
}

getCommitID(){
    local container="$1"
    local path_to_repo="$2"
    local current_branch
    current_branch=$(lxc exec "$container" -- cat "$path_to_repo"/.git/HEAD | awk '{print $2}')
    local commit_id
    commit_id=$(lxc exec "$container" -- cat "$path_to_repo"/.git/"$current_branch")
    echo "$commit_id"
}

installRedisApt(){
    local container=$1
    lxc exec "$container" -- sed -i "/#\$nrconf{restart} = 'i';/s/.*/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf
    lxc exec "$container" -- apt update
    lxc exec "$container" -- apt upgrade -y
    lxc exec "$container" -- apt install redis-server -y
    lxc exec "$container" -- sed -i "/^\$nrconf{restart} = 'a';/s/.*/#\$nrconf{restart} = 'i';/" /etc/needrestart/needrestart.conf
}

installRedisSource(){
    local container=$1
    local version=$2
    lxc exec "$container" -- sed -i "/#\$nrconf{restart} = 'i';/s/.*/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf
    lxc exec "$container" -- apt update
    lxc exec "$container" -- apt upgrade -y
    lxc exec "$container" -- apt install -y wget build-essential tcl
    lxc exec "$container" -- wget http://download.redis.io/releases/redis-$version.tar.gz && \
    lxc exec "$container" -- tar xzf redis-$version.tar.gz && \
    lxc exec "$container" --cwd=/root/redis-$version -- make && \
    lxc exec "$container" --cwd=/root/redis-$version -- make install
    lxc exec "$container" -- sed -i "/^\$nrconf{restart} = 'a';/s/.*/#\$nrconf{restart} = 'i';/" /etc/needrestart/needrestart.conf
    lxc exec "$container" -- mkdir -p /etc/redis
    lxc exec "$container" --cwd=/root/redis-$version -- cp redis.conf /etc/redis/redis.conf
    lxc exec "$container" -- sed -i 's|^dir \./|dir /var/lib/redis|' /etc/redis/redis.conf
    lxc exec "$container" -- sed -i 's|^pidfile /var/run/redis_6379.pid|pidfile /var/run/redis/redis-server.pid|' /etc/redis/redis.conf
    lxc exec "$container" -- sed -i 's/^protected-mode yes/protected-mode no/' /etc/redis/redis.conf
    lxc file push "$REDIS_SERVICE_FILE" $container/etc/systemd/system/redis-server.service -v
    lxc exec "$container" -- adduser --system --group --no-create-home redis
    lxc exec "$container" -- mkdir -p /var/lib/redis
    lxc exec "$container" -- chown redis:redis /var/lib/redis
    lxc exec "$container" -- chmod 770 /var/lib/redis
    lxc exec "$container" -- mkdir -p /var/run/redis
    lxc exec "$container" -- chown redis:redis /var/run/redis
    lxc exec "$container" -- chmod 770 /var/run/redis
    lxc exec "$container" -- systemctl daemon-reload
    lxc exec "$container" -- systemctl enable redis-server
    lxc exec "$container" -- systemctl start redis-server
    lxc exec "$container" -- sed -i "/^\$nrconf{restart} = 'a';/s/.*/#\$nrconf{restart} = 'i';/" /etc/needrestart/needrestart.conf
}

installMySQLApt(){
    local container=$1
    lxc exec "$container" -- sed -i "/#\$nrconf{restart} = 'i';/s/.*/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf
    lxc exec "$container" -- apt update
    lxc exec "$container" -- apt upgrade -y
    lxc exec "$container" -- apt install -y mariadb-server
    lxc exec "$container" -- sed -i "/^\$nrconf{restart} = 'a';/s/.*/#\$nrconf{restart} = 'i';/" /etc/needrestart/needrestart.conf
}

installMySQLSource(){
    local container=$1
    local version=$2
    lxc exec "$container" -- sed -i "/#\$nrconf{restart} = 'i';/s/.*/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf
    lxc exec "$container" -- apt update
    lxc exec "$container" -- apt upgrade -y
    lxc exec "$container" -- apt install -y apt-transport-https curl lsb-release
    lxc exec "$container" -- mkdir -p /etc/apt/keyrings
    lxc exec "$container" -- curl -o /etc/apt/keyrings/mariadb-keyring.pgp 'https://mariadb.org/mariadb_release_signing_key.pgp'
    lxc exec "$container" -- bash -c "echo 'deb [signed-by=/etc/apt/keyrings/mariadb-keyring.pgp] https://mirror.23m.com/mariadb/repo/$version/ubuntu $(lsb_release -cs) main' > /etc/apt/sources.list.d/mariadb.list"
    lxc exec "$container" -- apt update
    lxc exec "$container" -- apt install -y mariadb-server
    lxc exec "$container" -- sed -i "/^\$nrconf{restart} = 'a';/s/.*/#\$nrconf{restart} = 'i';/" /etc/needrestart/needrestart.conf
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
            BUILD_REDIS_VERSION=true
            shift 2
            ;;
        --mysql-version)
            MYSQL_VERSION=$2
            BUILD_MYSQL_VERSION=true
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

echo "----------------------------------------"
echo "Starting MISP-airgap build script ..."
echo "----------------------------------------"

trap cleanup EXIT

# Project setup
lxc project create "$PROJECT_NAME"
lxc project switch "$PROJECT_NAME"
lxc storage create "$STORAGE_POOL_NAME" "dir" 
lxc network create "$NETWORK_NAME"

if $MISP; then
    lxc launch $UBUNTU "$MISP_CONTAINER" -p default --storage "$STORAGE_POOL_NAME" --network "$NETWORK_NAME"
    waitForContainer "$MISP_CONTAINER"
    installMISP "$MISP_CONTAINER"
    addMISPInstallerInfo "$MISP_CONTAINER"
    createLXDImage "$MISP_CONTAINER" "$MISP_IMAGE" "MISP"
    successMessage "MISP"
fi

if $MYSQL; then
    lxc launch $UBUNTU "$MYSQL_CONTAINER" -p default --storage "$STORAGE_POOL_NAME" --network "$NETWORK_NAME"
    waitForContainer "$MYSQL_CONTAINER"

    if $BUILD_MYSQL_VERSION; then
        installMySQLSource "$MYSQL_CONTAINER" "$MYSQL_VERSION"
    else
        installMySQLApt "$MYSQL_CONTAINER"
    fi

    createLXDImage "$MYSQL_CONTAINER" "$MYSQL_IMAGE" "MySQL"
    successMessage "MySQL"
fi

if $REDIS; then
    lxc launch $UBUNTU "$REDIS_CONTAINER" -p default --storage "$STORAGE_POOL_NAME" --network "$NETWORK_NAME"
    waitForContainer "$REDIS_CONTAINER"

    if $BUILD_REDIS_VERSION; then
        installRedisSource "$REDIS_CONTAINER" "$REDIS_VERSION"
    else
        installRedisApt "$REDIS_CONTAINER"
    fi

    createLXDImage "$REDIS_CONTAINER" "$REDIS_IMAGE" "Redis"
    successMessage "Redis"
fi

if $MODULES; then
    lxc launch $UBUNTU "$MODULES_CONTAINER" -p default --storage "$STORAGE_POOL_NAME" --network "$NETWORK_NAME"
    installMISPModules "$MODULES_CONTAINER"
    addModulesInfo "$MODULES_CONTAINER"

    sleep 10
    if [ "$(lxc exec "$MODULES_CONTAINER" systemctl is-active misp-modules)" = "active" ]; then
        okay "Service misp-modules is running."
    else
        error "Service misp-modules is not running."
        lxc stop "$MODULES_CONTAINER"
        cleanup
        exit 1
    fi

    createLXDImage "$MODULES_CONTAINER" "$MODULES_IMAGE" "Modules"
    successMessage "Modules"
fi

echo "----------------------------------------"
echo "Build script finished."
echo "----------------------------------------"
