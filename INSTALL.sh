#!/bin/bash

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
VIOLET='\033[0;35m'
NC='\033[0m' # No Color

# ========================== Helper Functions ==========================

getPHPVersion(){
    ${LXC_MISP} -- bash -c "php -v | head -n 1 | awk '{print \$2}' | cut -d '.' -f 1,2"
}

random_string() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1
}

info () {
    local step=$1
    local msg=$2
    echo -e "${BLUE}Step $step:${NC} ${GREEN}$msg${NC}" > /dev/tty
}

error() {
    local msg=$1
    echo -e "${RED}Error: $msg${NC}" > /dev/tty
}

warn() {
    local msg=$1
    echo -e "${YELLOW}Warning: $msg${NC}" > /dev/tty
}

checkRessourceExist() {
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

waitForContainer() {
    local container_name="$1"

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

generateName(){
    local name="$1"
    echo "${name}-$(date +%Y-%m-%d-%H-%M-%S)"
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

checkNamingConvention(){
    local input="$1"
    local pattern="^[a-zA-Z0-9-]+$"

    if ! [[ "$input" =~ $pattern ]]; then
        error "Invalid Name $input. Please use only alphanumeric characters and hyphens."
        # exit 1
        return 1
    fi
    return 0
}

err() {
    local parent_lineno="$1"
    local message="$2"
    local code="${3:-1}"

    if [[ -n "$message" ]] ; then
        error "Line ${parent_lineno}: ${message}: exiting with status ${code}"
    else
        error "Line ${parent_lineno}: exiting with status ${code}"
    fi

    deleteLXDProject "$PROJECT_NAME"
    lxc storage delete "$APP_STORAGE"
    lxc storage delete "$DB_STORAGE"
    lxc network delete "$NETWORK_NAME"
    exit "${code}"
}

interrupt() {
    warn "Script interrupted by user. Delete project and exit ..."
    deleteLXDProject "$PROJECT_NAME"
    lxc storage delete "$APP_STORAGE"
    lxc storage delete "$DB_STORAGE"
    lxc network delete "$NETWORK_NAME"
    exit 130
}

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  -i, --interactive               Activates an interactive installation process."
    echo "  -p, --production                Set the MISP application to run in production mode."
    echo "  --project <project_name>        Specify the name of the LXD project."
    echo "  --misp-image <image_file>       Specify the MISP instance image file."
    echo "  --misp-name <container_name>    Specify the MISP container name."
    echo "  --mysql-image <image_file>      Specify the MariaDB instance image file."
    echo "  --mysql-name <container_name>   Specify the MariaDB container name."
    echo "  --mysql-db <database_name>      Specify the MISP database name."
    echo "  --mysql-user <user_name>        Specify the MariaDB user name."
    echo "  --mysql-pwd <password>          Specify the MariaDB user password."
    echo "  --mysql-root-pwd <password>     Specify the MariaDB root password."
    echo "  --redis-image <image_file>      Specify the Redis instance image file."
    echo "  --redis-name <container_name>   Specify the Redis container name."
    echo "  --no-modules                    Disable the setup of MISP Modules."
    echo "  --modules-image <image_file>    Specify the MISP Modules image file."
    echo "  --modules-name <container_name> Specify the MISP Modules container name."
    echo "  --app-partition <partition>     Specify the MISP container partition."
    echo "  --db-partition <partition>      Specify the database container partition."
    echo
    echo "Examples:"
    echo "  $0 --interactive"
    echo "  $0 --production --project my_project --mysql-user admin --mysql-pwd securepassword"
    echo
    echo "Note:"
    echo "  - This script sets up and configures an LXD project environment for MISP."
    echo "  - Use only alphanumeric characters and hyphens for container names and partitions."
}

checkForDefault(){
    declare -A defaults=(
    ["MYSQL_PASSWORD"]=$default_mysql_pwd
    ["MYSQL_ROOT_PASSWORD"]=$default_mysql_root_pwd
    )

    for key in "${!defaults[@]}"; do
        if [ "${!key}" = "${defaults[$key]}" ]; then
            error "The value of '$key' is using the default value. Please modify all passwords before running the script in production."
            exit 1
        fi
    done
}

validateArgs(){
    # Check Names
    if [[ "$KS_CHOICE" == "redis" ]]; then
        local names=("$PROJECT_NAME" "$MISP_CONTAINER" "$MYSQL_CONTAINER" "$REDIS_CONTAINER")
    else
        local names=("$PROJECT_NAME" "$MISP_CONTAINER" "$MYSQL_CONTAINER" "$VALKEY_CONTAINER")
    fi
    for i in "${names[@]}"; do
        if ! checkNamingConvention "$i"; then
            exit 1
        fi
    done

    if $MODULES && ! checkNamingConvention "$MODULES_CONTAINER"; then
        exit 1
    fi

    # Check for Project
    if checkRessourceExist "project" "$PROJECT_NAME"; then
        error "Project '$PROJECT_NAME' already exists."
        exit 1
    fi

    # Check Container Names
    if [[ "$KS_CHOICE" == "redis" ]]; then
        local containers=("$MISP_CONTAINER" "$MYSQL_CONTAINER" "$REDIS_CONTAINER")
    else
        local containers=("$MISP_CONTAINER" "$MYSQL_CONTAINER" "$VALKEY_CONTAINER")
    fi

    declare -A name_counts
    for name in "${containers[@]}"; do
    ((name_counts["$name"]++))
    done

    if $MODULES;then
        ((name_counts["$MODULES_CONTAINER"]++))
    fi

    for name in "${!name_counts[@]}"; do
    if ((name_counts["$name"] >= 2)); then
        error "At least two container have the same name: $name"
        exit 1
    fi
    done

    # Check for files
    if [[ "$KS_CHOICE" == "redis" ]]; then
        local files=("$MISP_IMAGE" "$MYSQL_IMAGE" "$REDIS_IMAGE")
    else
        local files=("$MISP_IMAGE" "$MYSQL_IMAGE" "$VALKEY_IMAGE")
    fi

    for i in "${files[@]}"; do
        if [ ! -f "$i" ]; then
            error "The specified file $i does not exists"
            exit 1
        fi
    done

    if $MODULES && [ ! -f "$MODULES_IMAGE" ];then
        error "The specified file $MODULES_IMAGE does not exists"
        exit 1       
    fi 

    # Check for production mode
    if $PROD; then
        checkForDefault
    fi
}

cleanup(){
    # Remove imported images
    if [[ "$KS_CHOICE" == "redis" ]]; then
        images=("$MISP_IMAGE_NAME" "$MYSQL_IMAGE_NAME" "$REDIS_IMAGE_NAME")
    else
        images=("$MISP_IMAGE_NAME" "$MYSQL_IMAGE_NAME" "$VALKEY_IMAGE_NAME")
    fi
    for image in "${images[@]}"; do
        lxc image delete "$image"
    done
    if $MODULES; then
        lxc image delete "$MODULES_IMAGE_NAME"
    fi
}

# ========================== Installation Configuration ==========================

interactiveConfig(){
    # Installer output
    echo
    echo "################################################################################"
    echo -e "# Welcome to the ${BLUE}MISP-airgap${NC} Installer Script                                  #"
    echo "#------------------------------------------------------------------------------#"
    echo -e "# This installer script will guide you through the installation process of     #"
    echo -e "# ${BLUE}MISP${NC} using LXD.                                                              #"
    echo -e "#                                                                              #"
    echo -e "# ${VIOLET}Please note:${NC}                                                                 #"
    echo -e "# ${VIOLET}Default values provided below are for demonstration purposes only and should${NC} #"
    echo -e "# ${VIOLET}be changed in a production environment.${NC}                                      #"
    echo -e "#                                                                              #"
    echo "################################################################################"
    echo
    
    declare -A nameCheckArray

    # Ask for LXD project name
    while true; do 
        read -r -p "Name of the misp project (default: $default_misp_project): " misp_project
        PROJECT_NAME=${misp_project:-$default_misp_project}
        if ! checkNamingConvention "$PROJECT_NAME"; then
            continue
        fi
        if checkRessourceExist "project" "$PROJECT_NAME"; then
            error "Project '$PROJECT_NAME' already exists."
            continue
        fi
        break
    done

    # Ask for MISP image 
    while true; do 
        read -r -e -p "What is the path to the misp image (default: $default_misp_img): " misp_img
        misp_img=${misp_img:-$default_misp_img}
        if [ ! -f "$misp_img" ]; then
            error "The specified file does not exist."
            continue
        fi
        MISP_IMAGE=$misp_img
        break
    done

    # Ask for MISP container name
    while true; do 
        read -r -p "Name of the misp container (default: $default_misp_name): " misp_name
        MISP_CONTAINER=${misp_name:-$default_misp_name}
        if [[ ${nameCheckArray[$MISP_CONTAINER]+_} ]]; then
            error "Name '$MISP_CONTAINER' has already been used. Please choose a different name."
            continue
        fi
        if ! checkNamingConvention "$MISP_CONTAINER"; then
            continue
        fi
        nameCheckArray[$MISP_CONTAINER]=1
        break
    done

    # Ask for MySQL image
    while true; do 
        read -r -e -p "What is the path to the MySQL image (default: $default_mysql_img): " mysql_img
        mysql_img=${mysql_img:-$default_mysql_img}
        if [ ! -f "$mysql_img" ]; then
            error "The specified file does not exist."
            continue
        fi
        MYSQL_IMAGE=$mysql_img
        break
    done

    # Ask for MySQL container name
    while true; do 
        read -r -p "Name of the MySQL container (default: $default_mysql_name): " mysql_name
        MYSQL_CONTAINER=${mysql_name:-$default_mysql_name}
        if [[ ${nameCheckArray[$MYSQL_CONTAINER]+_} ]]; then
            error "Name '$MYSQL_CONTAINER' has already been used. Please choose a different name."
            continue
        fi
        if ! checkNamingConvention "$MYSQL_CONTAINER"; then
            continue
        fi
        nameCheckArray[$MYSQL_CONTAINER]=1
        break
    done

    # Ask for MySQL credentials
    read -r -p "MySQL Database (default: $default_mysql_db): " mysql_db
    MYSQL_DATABASE=${mysql_db:-$default_mysql_db}
    read -r -p "MySQL User (default: $default_mysql_user): " mysql_user
    MYSQL_USER=${mysql_user:-$default_mysql_user}
    read -r -p "MySQL User Password (default: $default_mysql_pwd): " mysql_pwd
    MYSQL_PASSWORD=${mysql_pwd:-$default_mysql_pwd}
    read -r -p "MySQL Root Password (default: $default_mysql_root_pwd): " mysql_root_pwd
    MYSQL_ROOT_PASSWORD=${mysql_root_pwd:-$default_mysql_root_pwd}

    while true; do
        read -r -p "Do you want to use Redis or Valkey? (redis/valkey) [default: valkey]: " choice
        KS_CHOICE=${KS_CHOICE:-valkey}
        if [[ "$KS_CHOICE" == "redis" || "$KS_CHOICE" == "valkey" ]]; then
            break
        else
            echo "Invalid choice. Please enter 'redis' or 'valkey'."
        fi
    done

    # Ask for Redis/Valkey image
    while true; do
        if [[ "$KS_CHOICE" == "redis" ]]; then
            read -r -e -p "What is the path to the Redis image (default: $default_redis_img): " redis_img
            redis_img=${redis_img:-$default_redis_img}
            if [ ! -f "$redis_img" ]; then
                error "The specified file does not exist."
                continue
            fi
            REDIS_IMAGE=$redis_img
            break
        else
            read -r -e -p "What is the path to the Valkey image (default: $default_valkey_img): " valkey_img
            valkey_img=${valkey_img:-$default_valkey_img}
            if [ ! -f "$valkey_img" ]; then
                error "The specified file does not exist."
                continue
            fi
            VALKEY_IMAGE=$valkey_img
            break
        fi
    done

    # Ask for Redis/Valkey container name
    while true; do
        if [[ "$KS_CHOICE" == "redis" ]]; then
            read -r -p "Name of the Redis container (default: $default_redis_name): " redis_name
            REDIS_CONTAINER=${redis_name:-$default_redis_name}
            if [[ ${nameCheckArray[$REDIS_CONTAINER]+_} ]]; then
                error "Name '$REDIS_CONTAINER' has already been used. Please choose a different name."
                continue
            fi
            if ! checkNamingConvention "$REDIS_CONTAINER"; then
                continue
            fi
            nameCheckArray[$REDIS_CONTAINER]=1
            break
        else
            read -r -p "Name of the Valkey container (default: $default_valkey_name): " valkey_name
            VALKEY_CONTAINER=${valkey_name:-$default_valkey_name}
            if [[ ${nameCheckArray[$VALKEY_CONTAINER]+_} ]]; then
                error "Name '$VALKEY_CONTAINER' has already been used. Please choose a different name."
                continue
            fi
            if ! checkNamingConvention "$VALKEY_CONTAINER"; then
                continue
            fi
            nameCheckArray[$VALKEY_CONTAINER]=1
            break
        fi
    done

    # Ask for MISP Modules installation
    read -r -p "Do you want to install MISP Modules (y/n, default: $default_modules): " modules
    modules=${modules:-$default_modules}
    MODULES=$(echo "$modules" | grep -iE '^y(es)?$' > /dev/null && echo true || echo false)
    if $MODULES; then

        # Ask for MISP Modules image
        while true; do
            read -r -e -p "What is the path to the Modules image (default: $default_modules_img): " modules_img
            modules_img=${modules_img:-$default_modules_img}
            if [ ! -f "$modules_img" ]; then
                error "The specified file does not exist."
                continue
            fi
            MODULES_IMAGE=$modules_img
            break
        done

        # Ask for MISP Modules container name
        while true; do
            read -r -p "Name of the Modules container (default: $default_modules_name): " modules_name
            MODULES_CONTAINER=${modules_name:-$default_modules_name}
            if [[ ${nameCheckArray[$MODULES_CONTAINER]+_} ]]; then
                error "Name '$MODULES_CONTAINER' has already been used. Please choose a different name."
                continue
            fi
            if ! checkNamingConvention "$MODULES_CONTAINER"; then
                continue
            fi
            nameCheckArray[$MODULES_CONTAINER]=1
            break
        done

    fi

    # Ask for dedicated partitions
    read -r -p "Dedicated partition for MISP container (leave blank if none): " app_partition
    APP_PARTITION=${app_partition:-$default_app_partition}
    read -r -p "Dedicated partition for DB container (leave blank if none): " db_partition
    DB_PARTITION=${db_partition:-$default_db_partition}

    # Ask if used in prod
    read -r -p "Do you want to use this setup in production (y/n, default: $default_prod): " prod
    prod=${prod:-$default_prod} 
    PROD=$(echo "$prod" | grep -iE '^y(es)?$' > /dev/null && echo true || echo false)

    if $PROD; then
        checkForDefault
    fi

    # Output values set by the user
    echo -e "\nValues set:"
    echo "--------------------------------------------------------------------------------------------------------------------"
    echo -e "PROJECT_NAME: ${GREEN}$PROJECT_NAME${NC}"
    echo "--------------------------------------------------------------------------------------------------------------------"
    echo -e "${BLUE}MISP:${NC}"
    echo -e "MISP_IMAGE: ${GREEN}$MISP_IMAGE${NC}"
    echo -e "MISP_CONTAINER: ${GREEN}$MISP_CONTAINER${NC}"
    echo "--------------------------------------------------------------------------------------------------------------------"
    echo -e "${BLUE}MySQL:${NC}"
    echo -e "MYSQL_IMAGE: ${GREEN}$MYSQL_IMAGE${NC}"
    echo -e "MYSQL_CONTAINER: ${GREEN}$MYSQL_CONTAINER${NC}"
    echo -e "MYSQL_DATABASE: ${GREEN}$MYSQL_DATABASE${NC}"
    echo -e "MYSQL_USER: ${GREEN}$MYSQL_USER${NC}"
    echo -e "MYSQL_PASSWORD: ${GREEN}$MYSQL_PASSWORD${NC}"
    echo -e "MYSQL_ROOT_PASSWORD: ${GREEN}$MYSQL_ROOT_PASSWORD${NC}"
    echo "--------------------------------------------------------------------------------------------------------------------"
    if [[ "$KS_CHOICE" == "redis" ]]; then
        echo -e "${BLUE}Redis:${NC}"
        echo -e "REDIS_IMAGE: ${GREEN}$REDIS_IMAGE${NC}"
        echo -e "REDIS_CONTAINER: ${GREEN}$REDIS_CONTAINER${NC}"
    else
        echo -e "${BLUE}Valkey:${NC}"
        echo -e "VALKEY_IMAGE: ${GREEN}$VALKEY_IMAGE${NC}"
        echo -e "VALKEY_CONTAINER: ${GREEN}$VALKEY_CONTAINER${NC}"
    fi
    echo "--------------------------------------------------------------------------------------------------------------------"
    echo -e "${BLUE}MISP Modules:${NC}"
    echo -e "MISP Modules: ${GREEN}$MODULES${NC}"
    if $MODULES; then
        echo -e "MODULES_IMAGE: ${GREEN}$MODULES_IMAGE${NC}"
        echo -e "MODULES_CONTAINER: ${GREEN}$MODULES_CONTAINER${NC}"
    fi
    echo "--------------------------------------------------------------------------------------------------------------------"
    echo -e "${BLUE}Storage:${NC}"
    echo -e "APP_PARTITION: ${GREEN}$APP_PARTITION${NC}"
    echo -e "DB_PARTITION: ${GREEN}$DB_PARTITION${NC}"
    echo "--------------------------------------------------------------------------------------------------------------------"
    echo -e "${BLUE}Security:${NC}"
    echo -e "PROD: ${GREEN}$PROD${NC}\n"
    echo "--------------------------------------------------------------------------------------------------------------------"

    # Ask for confirmation
    read -r -p "Do you want to proceed with the installation? (y/n): " confirm
    confirm=${confirm:-$default_confirm}
    if [[ $confirm != "y" ]]; then
        warn "Installation aborted."
        exit 1
    fi

}

nonInteractiveConfig(){
    VALID_ARGS=$(getopt -o ph --long help,production,project:,misp-image:,misp-name:,mysql-image:,mysql-name:,mysql-user:,mysql-pwd:,mysql-db:,mysql-root-pwd:,redis-image:,redis-name:,no-modules,modules-image:,modules-name:,app_partition:,db_partition:  -- "$@")
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
            -p | --production)
                prod="y"
                shift
                ;;
            --project)
                misp_project=$2
                shift 2
                ;;
            --misp-image)
                misp_img=$2
                shift 2
                ;;
            --misp-name)
                misp_name=$2
                shift 2
                ;;
            --mysql-image)
                mysql_img=$2
                shift 2
                ;;
            --mysql-name)
                mysql_name=$2
                shift 2
                ;;
            --mysql-user)
                mysql_user=$2
                shift 2
                ;;
            --mysql-pwd)
                mysql_pwd=$2
                shift 2
                ;;
            --mysql-db)
                mysql_db=$2
                shift 2
                ;;
            --mysql-root-pwd)
                mysql_root_pwd=$2
                shift 2
                ;;
            --redis-image)
                redis_img=$2
                KS_CHOICE="redis"
                shift 2
                ;;
            --redis-name)
                redis_name=$2
                shift 2
                ;;
            --valkey-image)
                valkey_img=$2
                shift 2
                ;;
            --valkey-name)
                valkey_name=$2
                shift 2
                ;;
            --no-modules)
                modules="n"
                shift
                ;;
            --modules-image)
                modules_img=$2
                shift 2
                ;;
            --modules-name)
                modules_name=$2
                shift 2
                ;;
            --app-partition)
                app_partition=$2
                shift 2
                ;;
            --db-partition)
                db_partition=$2
                shift 2
                ;;  
            *)  
                break 
                ;;
        esac
    done

    # Set global values
    PROJECT_NAME=${misp_project:-$default_misp_project}
    MISP_IMAGE=${misp_img:-$default_misp_img}
    MISP_CONTAINER=${misp_name:-$default_misp_name}
    MYSQL_IMAGE=${mysql_img:-$default_mysql_img}
    MYSQL_CONTAINER=${mysql_name:-$default_mysql_name}
    MYSQL_USER=${mysql_user:-$default_mysql_user}
    MYSQL_PASSWORD=${mysql_pwd:-$default_mysql_pwd}
    MYSQL_DATABASE=${mysql_db:-$default_mysql_db}
    MYSQL_ROOT_PASSWORD=${mysql_root_pwd:-$default_mysql_root_pwd}
    REDIS_IMAGE=${redis_img:-$default_redis_img}
    REDIS_CONTAINER=${redis_name:-$default_redis_name}
    VALKEY_IMAGE=${valkey_img:-$default_valkey_img}
    VALKEY_CONTAINER=${valkey_name:-$default_valkey_name}
    modules=${modules:-$default_modules}
    MODULES=$(echo "$modules" | grep -iE '^y(es)?$' > /dev/null && echo true || echo false)
    MODULES_IMAGE=${modules_img:-$default_modules_img}
    MODULES_CONTAINER=${modules_name:-$default_modules_name}
    APP_PARTITION=${app_partition:-$default_app_partition}
    DB_PARTITION=${db_partition:-$default_db_partition}
    prod=${prod:-$default_prod}
    PROD=$(echo "$prod" | grep -iE '^y(es)?$' > /dev/null && echo true || echo false)

    KS_CHOICE=${KS_CHOICE:-"valkey"}
}

# ========================== LXD Setup ==========================

setupLXD(){
    # Create Project 
    lxc project create "$PROJECT_NAME"
    lxc project switch "$PROJECT_NAME"

    # Create storage pools
    APP_STORAGE=$(generateName "app-storage")
    if checkRessourceExist "storage" "$APP_STORAGE"; then
        error "Storage '$APP_STORAGE' already exists."
        exit 1
    fi
    lxc storage create "$APP_STORAGE" zfs source="$APP_PARTITION"

    DB_STORAGE=$(generateName "db-storage")
    if checkRessourceExist "storage" "$DB_STORAGE"; then
        error "Storage '$DB_STORAGE' already exists."
        exit 1
    fi
    lxc storage create "$DB_STORAGE" zfs source="$DB_PARTITION"

    # Create Network
    NETWORK_NAME=$(generateName "net")
    # max len of 15 
    NETWORK_NAME=${NETWORK_NAME:0:14}
    if checkRessourceExist "network" "$NETWORK_NAME"; then
        error "Network '$NETWORK_NAME' already exists."
    fi
    lxc network create "$NETWORK_NAME" --type=bridge

    # Create Profiles
    APP_PROFILE=$(generateName "app")
    if checkRessourceExist "profile" "$APP_PROFILE"; then
        error "Profile '$APP_PROFILE' already exists."
    fi
    lxc profile create "$APP_PROFILE"
    lxc profile device add "$APP_PROFILE" root disk path=/ pool="$APP_STORAGE"
    lxc profile device add "$APP_PROFILE" eth0 nic name=eth0 network="$NETWORK_NAME"

    
    DB_PROFILE=$(generateName "db")
    echo "db-profile: $DB_PROFILE"
    if checkRessourceExist "profile" "$DB_PROFILE"; then
        error "Profile '$DB_PROFILE' already exists."
    fi
    lxc profile create "$DB_PROFILE"
    lxc profile device add "$DB_PROFILE" root disk path=/ pool="$DB_STORAGE"
    lxc profile device add "$DB_PROFILE" eth0 nic name=eth0 network="$NETWORK_NAME"   
}

importImages(){
    # Import Images
    MISP_IMAGE_NAME=$(generateName "misp")
    echo "image: $MISP_IMAGE_NAME"
    if checkRessourceExist "image" "$MISP_IMAGE_NAME"; then
        error "Image '$MISP_IMAGE_NAME' already exists."
    fi
    lxc image import "$MISP_IMAGE" --alias "$MISP_IMAGE_NAME"

    MYSQL_IMAGE_NAME=$(generateName "mysql")
    if checkRessourceExist "image" "$MYSQL_IMAGE_NAME"; then
        error "Image '$MYSQL_IMAGE_NAME' already exists."
    fi
    lxc image import "$MYSQL_IMAGE" --alias "$MYSQL_IMAGE_NAME"
    
    if [[ "$KS_CHOICE" == "redis" ]]; then
        REDIS_IMAGE_NAME=$(generateName "redis")
        if checkRessourceExist "image" "$REDIS_IMAGE_NAME"; then
            error "Image '$REDIS_IMAGE_NAME' already exists."
        fi
        lxc image import "$REDIS_IMAGE" --alias "$REDIS_IMAGE_NAME"
    else
        VALKEY_IMAGE_NAME=$(generateName "redis")
        if checkRessourceExist "image" "$VALKEY_IMAGE_NAME"; then
            error "Image '$VALKEY_IMAGE_NAME' already exists."
        fi
        lxc image import "$VALKEY_IMAGE" --alias "$VALKEY_IMAGE_NAME"
    fi

    if $MODULES; then
        MODULES_IMAGE_NAME=$(generateName "modules")
        if checkRessourceExist "image" "$MODULES_IMAGE_NAME"; then
            error "Image '$MODULES_IMAGE_NAME' already exists."
        fi
        lxc image import "$MODULES_IMAGE" --alias "$MODULES_IMAGE_NAME"
    fi
}


launchContainers(){
    # Launch Containers
    lxc launch $MISP_IMAGE_NAME $MISP_CONTAINER --profile=$APP_PROFILE 
    lxc launch $MYSQL_IMAGE_NAME $MYSQL_CONTAINER --profile=$DB_PROFILE

    if [[ "$KS_CHOICE" == "redis" ]]; then
        lxc launch $REDIS_IMAGE_NAME $REDIS_CONTAINER --profile=$DB_PROFILE 
    else
        lxc launch $VALKEY_IMAGE_NAME $VALKEY_CONTAINER --profile=$DB_PROFILE 
    fi
    if $MODULES; then
        lxc launch $MODULES_IMAGE_NAME $MODULES_CONTAINER --profile=$APP_PROFILE
    fi
}

deleteLXDProject(){
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

    echo "Deleting profiles in project"
    for profile in $(lxc query "/1.0/profiles?recursion=1&project=${project}" | jq .[].name -r); do
    if [ "${profile}" = "default" ]; then
        printf 'config: {}\ndevices: {}' | lxc profile edit --project "${project}" default
        continue
    fi
    lxc profile delete --project "${project}" "${profile}"
    done

    echo "Deleting project"
    lxc project delete "${project}"
}

# ========================== MySQL Configuration ==========================

editMySQLConf(){
    local key=$1
    local value=$2
    local container=$3

    lxc exec $container -- bash -c "\
    if grep -q '^$key' /etc/mysql/mariadb.conf.d/50-server.cnf; then \
        sed -i 's/^$key.*/$key = $value/' /etc/mysql/mariadb.conf.d/50-server.cnf; \
    else \
        awk -v $key='$key = $value' \
        '/^\[mysqld\]/ {print; print $key; next} {print}' \
        /etc/mysql/mariadb.conf.d/50-server.cnf > /tmp/php.ini.modified && \
        mv /tmp/php.ini.modified /etc/mysql/mariadb.conf.d/50-server.cnf; \
    fi"
}

configureMySQL(){
    ## Add user + DB
    lxc exec $MYSQL_CONTAINER -- mariadb -u root -e "CREATE DATABASE $MYSQL_DATABASE;"
    lxc exec $MYSQL_CONTAINER -- mariadb -u root -e "GRANT ALL PRIVILEGES ON $MYSQL_DATABASE.* TO '$MYSQL_USER'@'$MISP_CONTAINER.lxd' IDENTIFIED BY '$MYSQL_PASSWORD';"

    ## Configure remote access
    lxc exec $MYSQL_CONTAINER -- sed -i 's/bind-address            = 127.0.0.1/bind-address            = 0.0.0.0/' "/etc/mysql/mariadb.conf.d/50-server.cnf"

    editMySQLConf "innodb_write_io_threads" "$INNODB_WRITE_IO_THREADS" "$MYSQL_CONTAINER"
    editMySQLConf "innodb_stats_persistent" "$INNODB_STATS_PERISTENT" "$MYSQL_CONTAINER"
    editMySQLConf "innodb_read_io_threads" "$INNODB_READ_IO_THREADS" "$MYSQL_CONTAINER"
    editMySQLConf "innodb_log_files_in_group" "$INNODB_LOG_FILES_IN_GROUP" "$MYSQL_CONTAINER"
    editMySQLConf "innodb_log_file_size" "$INNODB_LOG_FILE_SIZE" "$MYSQL_CONTAINER"
    editMySQLConf "innodb_io_capacity_max" "$INNODB_IO_CAPACITY_MAX" "$MYSQL_CONTAINER"
    editMySQLConf "innodb_io_capacity" "$INNODB_IO_CAPACITY" "$MYSQL_CONTAINER"
    editMySQLConf "innodb_change_buffering" "$INNODB_CHANGE_BUFFERING" "$MYSQL_CONTAINER"
    editMySQLConf "innodb_buffer_pool_size" "$INNODB_BUFFER_POOL_SIZE" "$MYSQL_CONTAINER"

    lxc exec $MYSQL_CONTAINER -- sudo systemctl restart mariadb

    ## secure MySQL installation
    lxc exec $MYSQL_CONTAINER -- mariadb-admin -u root password "$MYSQL_ROOT_PASSWORD"
    lxc exec $MYSQL_CONTAINER -- mariadb -u root -p"$MYSQL_ROOT_PASSWORD" <<EOF
    DELETE FROM mysql.user WHERE User='';
    DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
    DROP DATABASE IF EXISTS test;
    FLUSH PRIVILEGES;
EOF
}

initializeDB(){
    ## Check connection + import schema to MySQL
    table_count=$(${LXC_MISP} -- mysql -u $MYSQL_USER --password="$MYSQL_PASSWORD" -h $MYSQL_CONTAINER.lxd -P 3306 $MYSQL_DATABASE -e "SHOW TABLES;" | wc -l)
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Connected to database successfully!${NC}"
        if [ $table_count -lt 73 ]; then
            echo "Database misp is empty, importing tables from misp container ..."
            ${LXC_MISP} -- bash -c "mysql -u $MYSQL_USER --password=$MYSQL_PASSWORD $MYSQL_DATABASE -h $MYSQL_CONTAINER.lxd -P 3306 2>&1 < $PATH_TO_MISP/INSTALL/MYSQL.sql"
        else
            echo "Database misp available"
        fi
    else
        error $table_count
    fi
    # Update DB
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin runUpdates
}

# ========================== Redis Configuration ==========================

configureRedisContainer(){
    ## Cofigure remote access
    lxc exec $REDIS_CONTAINER -- sed -i "s/^bind .*/bind 0.0.0.0/" "/etc/redis/redis.conf"
    lxc exec $REDIS_CONTAINER -- sed -i "s/^port .*/port $REDIS_CONTAINER_PORT/" "/etc/redis/redis.conf"
    lxc exec $REDIS_CONTAINER -- systemctl restart redis-server
}

# ========================== Valkey Configuration ==========================

configureValkey(){
    lxc exec $VALKEY_CONTAINER -- sed -i "s/^bind .*/bind 0.0.0.0/" "/etc/valkey/valkey.conf"
    lxc exec $VALKEY_CONTAINER -- sed -i "s/^port .*/port $VALKEY_CONTAINER_PORT/" "/etc/valkey/valkey.conf"
    lxc exec $VALKEY_CONTAINER -- systemctl restart valkey
}

# ========================== MISP Configuration ==========================

updateGOWNT () {
    # Update the galaxies…
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin updateGalaxies
    # Updating the taxonomies…
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin updateTaxonomies
    # Updating the warning lists…
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin updateWarningLists
    # Updating the notice lists…
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin updateNoticeLists
    # Updating the object templates…
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin updateObjectTemplates "1337"
}

setupGnuPG() {
    GPG_EMAIL_ADDRESS="admin@admin.test"
    GPG_PASSPHRASE="$(openssl rand -hex 32)"

    ${LXC_MISP} -- sudo -u ${WWW_USER} gpg --homedir $PATH_TO_MISP/.gnupg --quick-generate-key --batch --passphrase "$GPG_PASSPHRASE" "$GPG_EMAIL_ADDRESS" ed25519 sign never

    # Ensure the webroot directory exists
    ${LXC_MISP} -- sudo -u ${WWW_USER} mkdir -p "$PATH_TO_MISP/app/webroot"

    # Correctly write the exported key to gpg.asc
    ${LXC_MISP} -- sudo -u ${WWW_USER} bash -c "gpg --homedir $PATH_TO_MISP/.gnupg --export --armor '$GPG_EMAIL_ADDRESS' > '$PATH_TO_MISP/app/webroot/gpg.asc'"

}

createRedisSocket(){
    local file_path="/etc/redis/redis.conf"
    local lines_to_add="# create a unix domain socket to listen on\nunixsocket /var/run/redis/redis.sock\n# set permissions for the socket\nunixsocketperm 775"

    ${LXC_MISP} -- usermod -g www-data redis
    ${LXC_MISP} -- mkdir -p /var/run/redis/
    ${LXC_MISP} -- chown -R redis:www-data /var/run/redis
    ${LXC_MISP} -- cp "$file_path" "$file_path.bak"
    ${LXC_MISP} -- bash -c "echo -e \"$lines_to_add\" | cat - \"$file_path\" >tempfile && mv tempfile \"$file_path\""
    ${LXC_MISP} -- usermod -aG redis www-data
    ${LXC_MISP} -- service redis-server restart

    # Modify php.ini
    local php_ini_path="/etc/php/$PHP_VERSION/apache2/php.ini" 
    local socket_path="/var/run/redis/redis.sock"
    ${LXC_MISP} -- sed -i "s|;session.save_path = \"/var/lib/php/sessions\"|session.save_path = \"$socket_path\"|; s|session.save_handler = files|session.save_handler = redis|" $php_ini_path
    ${LXC_MISP} -- sudo service apache2 restart
}

setMISPConfig () {
    # IF you have logged in prior to running this, it will fail but the fail is NON-blocking
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} userInit -q

    # This makes sure all Database upgrades are done, without logging in.
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin runUpdates

    # The default install is Python >=3.6 in a virtualenv, setting accordingly
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.python_bin" "${PATH_TO_MISP}/venv/bin/python"

    # Tune global time outs
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Session.autoRegenerate" 0
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Session.timeout" 600
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Session.cookieTimeout" 3600
    
    # Set the default temp dir
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.tmpdir" "${PATH_TO_MISP}/app/tmp"

    # Change base url, either with this CLI command or in the UI
    [[ ! -z ${MISP_BASEURL} ]] && ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Baseurl $MISP_BASEURL
    [[ ! -z ${MISP_BASEURL} ]] && ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.external_baseurl" ${MISP_BASEURL}

    # Enable GnuPG
    echo $GPG_EMAIL_ADDRESS
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "GnuPG.email" "${GPG_EMAIL_ADDRESS}" # Error
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "GnuPG.homedir" "${PATH_TO_MISP}/.gnupg"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "GnuPG.password" "${GPG_PASSPHRASE}"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "GnuPG.obscure_subject" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "GnuPG.key_fetching_disabled" false
    # FIXME: what if we have not gpg binary but a gpg2 one?
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "GnuPG.binary" "$(which gpg)"

    # LinOTP
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "LinOTPAuth.enabled" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "LinOTPAuth.baseUrl" "https://<your-linotp-baseUrl>"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "LinOTPAuth.realm" "lino"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "LinOTPAuth.verifyssl" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "LinOTPAuth.mixedauth" false

    # Enable installer org and tune some configurables
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.host_org_id" 1
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.email" "info@admin.test"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.disable_emailing" true --force
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.contact" "info@admin.test"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.disablerestalert" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.showCorrelationsOnIndex" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.default_event_tag_collection" 0

    # Provisional Cortex tunes
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Cortex_services_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Cortex_services_url" "http://127.0.0.1"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Cortex_services_port" 9000
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Cortex_timeout" 120
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Cortex_authkey" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Cortex_ssl_verify_peer" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Cortex_ssl_verify_host" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Cortex_ssl_allow_self_signed" true

    # Provisional Action tunes
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Action_services_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Action_services_url" "http://127.0.0.1"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Action_services_port" 6666
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Action_timeout" 10

    # Various plugin sightings settings
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Sightings_policy" 0
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Sightings_anonymise" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Sightings_anonymise_as" 1
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Sightings_range" 365
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Sightings_sighting_db_enable" false

    # TODO: Fix the below list
    # Set API_Required modules to false
    PLUGS=(Plugin.ElasticSearch_logging_enable
            Plugin.S3_enable)
    for PLUG in "${PLUGS[@]}"; do
        ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting ${PLUG} false 2> /dev/null
    done

    # Plugin CustomAuth tuneable
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.CustomAuth_disable_logout" false

    # RPZ Plugin settings
    #${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.RPZ_policy" "DROP"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.RPZ_walled_garden" "127.0.0.1"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.RPZ_serial" "\$date00"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.RPZ_refresh" "2h"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.RPZ_retry" "30m"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.RPZ_expiry" "30d"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.RPZ_minimum_ttl" "1h"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.RPZ_ttl" "1w"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.RPZ_ns" "localhost."
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.RPZ_ns_alt" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.RPZ_email" "root.localhost"

    # Kafka settings
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_brokers" "kafka:9092"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_rdkafka_config" "/etc/rdkafka.ini"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_include_attachments" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_event_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_event_notifications_topic" "misp_event"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_event_publish_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_event_publish_notifications_topic" "misp_event_publish"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_object_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_object_notifications_topic" "misp_object"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_object_reference_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_object_reference_notifications_topic" "misp_object_reference"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_attribute_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_attribute_notifications_topic" "misp_attribute"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_shadow_attribute_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_shadow_attribute_notifications_topic" "misp_shadow_attribute"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_tag_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_tag_notifications_topic" "misp_tag"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_sighting_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_sighting_notifications_topic" "misp_sighting"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_user_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_user_notifications_topic" "misp_user"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_organisation_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_organisation_notifications_topic" "misp_organisation"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_audit_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_audit_notifications_topic" "misp_audit"

    # ZeroMQ settings
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_host" "127.0.0.1"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_port" 50000
    if [[ "$KS_CHOICE" == "redis" ]]; then
        ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_redis_host" "$REDIS_CONTAINER.lxd"
        ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_redis_port" $REDIS_CONTAINER_PORT
    else
        ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_redis_host" "$VALKEY_CONTAINER.lxd"
        ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_redis_port" $VALKEY_CONTAINER_PORT
    fi
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_redis_database" 1
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_redis_namespace" "mispq"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_event_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_object_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_object_reference_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_attribute_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_sighting_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_user_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_organisation_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_include_attachments" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_tag_notifications_enable" false

    # Force defaults to make MISP Server Settings less RED
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.language" "eng"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.proposals_block_attributes" false

  # Redis block
    if [[ "$KS_CHOICE" == "redis" ]]; then
        ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.redis_host" "$REDIS_CONTAINER.lxd"
        ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.redis_port" $REDIS_CONTAINER_PORT 
    else
        ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.redis_host" "$VALKEY_CONTAINER.lxd"
        ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.redis_port" $VALKEY_CONTAINER_PORT 
    fi
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.redis_database" 13
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.redis_password" ""

    # Force defaults to make MISP Server Settings less YELLOW
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.ssdeep_correlation_threshold" 40
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.extended_alert_subject" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.default_event_threat_level" 4
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.newUserText" "Dear new MISP user,\\n\\nWe would hereby like to welcome you to the \$org MISP community.\\n\\n Use the credentials below to log into MISP at \$misp, where you will be prompted to manually change your password to something of your own choice.\\n\\nUsername: \$username\\nPassword: \$password\\n\\nIf you have any questions, don't hesitate to contact us at: \$contact.\\n\\nBest regards,\\nYour \$org MISP support team"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.passwordResetText" "Dear MISP user,\\n\\nA password reset has been triggered for your account. Use the below provided temporary password to log into MISP at \$misp, where you will be prompted to manually change your password to something of your own choice.\\n\\nUsername: \$username\\nYour temporary password: \$password\\n\\nIf you have any questions, don't hesitate to contact us at: \$contact.\\n\\nBest regards,\\nYour \$org MISP support team"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.enableEventBlocklisting" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.enableOrgBlocklisting" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.log_client_ip" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.log_auth" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.log_user_ips" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.log_user_ips_authkeys" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.disableUserSelfManagement" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.disable_user_login_change" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.disable_user_password_change" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.disable_user_add" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.block_event_alert" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.block_event_alert_tag" "no-alerts=\"true\""
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.block_old_event_alert" false
    #${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.block_old_event_alert_age" ""
    #${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.block_old_event_alert_by_date" ""
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.event_alert_republish_ban" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.event_alert_republish_ban_threshold" 5
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.event_alert_republish_ban_refresh_on_retry" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.incoming_tags_disabled_by_default" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.maintenance_message" "Great things are happening! MISP is undergoing maintenance, but will return shortly. You can contact the administration at \$email."
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.footermidleft" "This is an initial install"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.footermidright" "Please configure and harden accordingly"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.welcome_text_top" "Initial Install, please configure"
    # TODO: Make sure $FLAVOUR is correct
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.welcome_text_bottom" "Welcome to MISP on ${FLAVOUR}, change this message in MISP Settings"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.attachments_dir" "${PATH_TO_MISP}/app/files"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.download_attachments_on_load" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.event_alert_metadata_only" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.title_text" "MISP"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.terms_download" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.showorgalternate" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.event_view_filter_fields" "id, uuid, value, comment, type, category, Tag.name"

    # Force defaults to make MISP Server Settings less GREEN
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "debug" 0
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Security.auth_enforced" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Security.log_each_individual_auth_fail" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Security.rest_client_baseurl" ""
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Security.advanced_authkeys" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Security.password_policy_length" 12
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Security.password_policy_complexity" '/^((?=.*\d)|(?=.*\W+))(?![\n])(?=.*[A-Z])(?=.*[a-z]).*$|.{16,}/'

    # Appease the security audit, #hardening
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Security.disable_browser_cache" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Security.check_sec_fetch_site_header" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Security.csp_enforce" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Security.advanced_authkeys" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Security.do_not_log_authkeys" true

    # Appease the security audit, #loggin
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Security.username_in_response_header" true

    # Configure background workers
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "SimpleBackgroundJobs.enabled" 1 
    if [[ "$KS_CHOICE" == "redis" ]]; then
        ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "SimpleBackgroundJobs.redis_host" "$REDIS_CONTAINER.lxd" 
        ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "SimpleBackgroundJobs.redis_port" $REDIS_CONTAINER_PORT 
    else
        ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "SimpleBackgroundJobs.redis_host" "$VALKEY_CONTAINER.lxd" 
        ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "SimpleBackgroundJobs.redis_port" $VALKEY_CONTAINER_PORT 
    fi
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "SimpleBackgroundJobs.redis_database" 13 
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "SimpleBackgroundJobs.redis_password" "" 
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "SimpleBackgroundJobs.redis_namespace" "background_jobs" 
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "SimpleBackgroundJobs.supervisor_host" "localhost" 
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "SimpleBackgroundJobs.supervisor_port" 9001 
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "SimpleBackgroundJobs.supervisor_user" ${SUPERVISOR_USER} 
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "SimpleBackgroundJobs.supervisor_password" ${SUPERVISOR_PASSWORD} 
    #${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "SimpleBackgroundJobs.redis_serializer" "JSON" 
}

setupSupervisor(){
        local config_file="/etc/supervisor/supervisord.conf"
        ${LXC_MISP} -- sed -i "s/^password=.*/password=$SUPERVISOR_PASSWORD/" "$config_file"

        # Restart Supervisor to apply changes
        ${LXC_MISP} -- sudo systemctl restart supervisor
}

# ========================== MISP Modules Configuration ==========================

configureMISPModules(){
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Enrichment_services_enable" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Enrichment_hover_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Enrichment_hover_popover_only" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Enrichment_timeout" 300
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Enrichment_hover_timeout" 150
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Enrichment_services_url" "$MODULES_CONTAINER.lxd"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Enrichment_services_port" 6666
 
    # Enable Import modules
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Import_services_enable" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Import_services_url" "$MODULES_CONTAINER.lxd"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Import_services_port" 6666
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Import_timeout" 300

    # Enable export modules
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Export_services_enable" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Export_services_url" "$MODULES_CONTAINER.lxd"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Export_services_port" 6666
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Export_timeout" 300

    # Enable additional module settings
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_bgpranking_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_countrycode_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_cve_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_cve_advanced_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_cpe_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_dns_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_eql_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_btc_steroids_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_ipasn_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_reversedns_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_yara_syntax_validator_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_yara_query_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_wiki_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_threatminer_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_threatcrowd_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_hashdd_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_rbl_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_sigma_syntax_validator_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_stix2_pattern_syntax_validator_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_sigma_queries_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_dbl_spamhaus_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_btc_scam_check_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_macvendors_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_qrcode_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_ocr_enrich_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_pdf_enrich_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_docx_enrich_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_xlsx_enrich_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_pptx_enrich_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_ods_enrich_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_odt_enrich_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_urlhaus_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_malwarebazaar_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_html_to_markdown_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_socialscan_enabled" true

    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Import_ocr_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Import_mispjson_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Import_openiocimport_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Import_threatanalyzer_import_enabled" true
    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Import_csvimport_enabled" true

    ${LXC_MISP} -- ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Export_pdfexport_enabled" true

    # Set API_Required modules to false
    PLUGS=(Plugin.Enrichment_cuckoo_submit_enabled
         Plugin.Enrichment_vmray_submit_enabled
         Plugin.Enrichment_circl_passivedns_enabled
         Plugin.Enrichment_circl_passivessl_enabled
         Plugin.Enrichment_domaintools_enabled
         Plugin.Enrichment_eupi_enabled
         Plugin.Enrichment_farsight_passivedns_enabled
         Plugin.Enrichment_passivetotal_enabled
         Plugin.Enrichment_passivetotal_enabled
         Plugin.Enrichment_virustotal_enabled
         Plugin.Enrichment_whois_enabled
         Plugin.Enrichment_shodan_enabled
         Plugin.Enrichment_geoip_asn_enabled
         Plugin.Enrichment_geoip_city_enabled
         Plugin.Enrichment_geoip_country_enabled
         Plugin.Enrichment_iprep_enabled
         Plugin.Enrichment_otx_enabled
         Plugin.Enrichment_vulndb_enabled
         Plugin.Enrichment_crowdstrike_falcon_enabled
         Plugin.Enrichment_onyphe_enabled
         Plugin.Enrichment_xforceexchange_enabled
         Plugin.Enrichment_vulners_enabled
         Plugin.Enrichment_macaddress_io_enabled
         Plugin.Enrichment_intel471_enabled
         Plugin.Enrichment_backscatter_io_enabled
         Plugin.Enrichment_hibp_enabled
         Plugin.Enrichment_greynoise_enabled
         Plugin.Enrichment_joesandbox_submit_enabled
         Plugin.Enrichment_virustotal_public_enabled
         Plugin.Enrichment_apiosintds_enabled
         Plugin.Enrichment_urlscan_enabled
         Plugin.Enrichment_securitytrails_enabled
         Plugin.Enrichment_apivoid_enabled
         Plugin.Enrichment_assemblyline_submit_enabled
         Plugin.Enrichment_assemblyline_query_enabled
         Plugin.Enrichment_ransomcoindb_enabled
         Plugin.Enrichment_lastline_query_enabled
         Plugin.Enrichment_sophoslabs_intelix_enabled
         Plugin.Enrichment_cytomic_orion_enabled
         Plugin.Enrichment_censys_enrich_enabled
         Plugin.Enrichment_trustar_enrich_enabled
         Plugin.Enrichment_recordedfuture_enabled
         Plugin.ElasticSearch_logging_enable
         Plugin.S3_enable)
  for PLUG in "${PLUGS[@]}"; do
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting ${PLUG} false 2> /dev/null
  done
}


# ========================== MAIN ==========================

if [ -z "$1" ]; then
    usage
    exit 0
fi
checkSoftwareDependencies

default_confirm="no"
default_prod="no"
default_misp_project=$(generateName "misp-project")

default_misp_img=""
default_misp_name=$(generateName "misp")

default_mysql_img=""
default_mysql_name=$(generateName "mysql")
default_mysql_user="misp"
default_mysql_pwd="misp"
default_mysql_db="misp"
default_mysql_root_pwd="misp"

default_redis_img=""
default_redis_name=$(generateName "redis")

default_valkey_img=""
default_valkey_name=$(generateName "valkey")

default_modules="yes"
default_modules_img=""
default_modules_name=$(generateName "modules")

default_app_partition=""
default_db_partition=""

# Check for interactive install
INTERACTIVE=false
for arg in "$@"; do
    if [[ $arg == "-i" ]] || [[ $arg == "--interactive" ]]; then
        INTERACTIVE=true
        break
    fi
done

if [ "$INTERACTIVE" = true ]; then
    interactiveConfig
else
    nonInteractiveConfig "$@"
fi

validateArgs

WWW_USER="www-data"
SUDO_WWW="sudo -H -u ${WWW_USER} "
PATH_TO_MISP="/var/www/MISP"
CAKE="${PATH_TO_MISP}/app/Console/cake"
MISP_BASEURL="${MISP_BASEURL:-""}"
LXC_MISP="lxc exec ${MISP_CONTAINER}"
REDIS_CONTAINER_PORT="6380"
VALKEY_CONTAINER_PORT="6380"

INNODB_BUFFER_POOL_SIZE="2147483648"
INNODB_CHANGE_BUFFERING="none"
INNODB_IO_CAPACITY="1000"
INNODB_IO_CAPACITY_MAX="2000"
INNODB_LOG_FILE_SIZE="629145600"
INNODB_LOG_FILES_IN_GROUP="2"
INNODB_READ_IO_THREADS="16"
INNODB_STATS_PERISTENT="ON"
INNODB_WRITE_IO_THREADS="4"

SUPERVISOR_USER='supervisor'
SUPERVISOR_PASSWORD="$(random_string)"
MISP_DOMAIN='misp.local'

trap 'interrupt' INT
trap 'err ${LINENO}' ERR

# ----------------- LXD setup -----------------
info "1" "Setup LXD Project"
setupLXD

info "2" "Import Images"
importImages

info "3" "Create Container"
launchContainers
waitForContainer $MISP_CONTAINER
PHP_VERSION=$(getPHPVersion)

# ----------------- MySQL config -----------------
info "4" "Configure and Update MySQL DB"
waitForContainer $MYSQL_CONTAINER
configureMySQL

# ----------------- Valkey/Redis config -----------------
if [[ "$KS_CHOICE" == "redis" ]]; then 
    info "5" "Configure Redis"
    waitForContainer $REDIS_CONTAINER
    configureRedisContainer
else
    info "5" "Configure Valkey"
    waitForContainer $VALKEY_CONTAINER
    configureValkey
fi

# ----------------- MISP config -----------------
info "6" "Configure MISP"
createRedisSocket

# Set MISP DB config
${LXC_MISP} -- sed -i "s/'database' => 'misp'/'database' => '$MYSQL_DATABASE'/" $PATH_TO_MISP/app/Config/database.php
${LXC_MISP} -- sed -i "s/localhost/$MYSQL_CONTAINER.lxd/" $PATH_TO_MISP/app/Config/database.php
${LXC_MISP} -- sed -i "s/'login' => '.*'/'login' => '$MYSQL_USER'/" "$PATH_TO_MISP/app/Config/database.php"
${LXC_MISP} -- sed -i "s/8889/3306/" $PATH_TO_MISP/app/Config/database.php
${LXC_MISP} -- sed -i "s/'password' => '.*'/'password' => '$MYSQL_PASSWORD'/" "$PATH_TO_MISP/app/Config/database.php"

# Write credentials to MISP
${LXC_MISP} -- sh -c "echo 'Admin (root) DB Password: $MYSQL_ROOT_PASSWORD \nUser ($MYSQL_USER) DB Password: $MYSQL_PASSWORD' > /home/misp/mysql.txt"

# Set MISP Redis config
if [[ "$KS_CHOICE" == "redis" ]]; then 
    ${LXC_MISP} -- sed -i "s/'host' => 'localhost'/'host' => '$REDIS_CONTAINER.lxd'/; s/'port' => 6379/'port' => $REDIS_CONTAINER_PORT/" /var/www/MISP/app/Plugin/CakeResque/Config/config.php
else
    ${LXC_MISP} -- sed -i "s/'host' => 'localhost'/'host' => '$VALKEY_CONTAINER.lxd'/; s/'port' => 6379/'port' => $VALKEY_CONTAINER_PORT/" /var/www/MISP/app/Plugin/CakeResque/Config/config.php
fi

initializeDB

setupGnuPG

# Create new auth key
${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} UserInit
AUTH_KEY=$(${LXC_MISP} -- sudo -u www-data -H sh -c "$PATH_TO_MISP/app/Console/cake user change_authkey admin@admin.test | grep -oP ': \K.*'")
lxc exec "$MISP_CONTAINER" -- sh -c "echo 'Authkey: $AUTH_KEY' > /home/misp/MISP-authkey.txt"

setMISPConfig

setupSupervisor

# ----------------- MISP Modules config -----------------
if $MODULES; then
    configureMISPModules
fi

updateGOWNT

if $PROD; then
    info "7" "Set MISP.live for production"
    ${LXC_MISP} -- sudo -u www-data -H sh -c "$PATH_TO_MISP/app/Console/cake Admin setSetting MISP.live true"
    warn "MISP runs in production mode!"
fi

cleanup

# Save settings to settings file
INSTALLATION_LOG_FILE="/var/log/misp_settings.txt"
current_date=$(date -u +"[%a %b %d %T UTC %Y]")

${LXC_MISP} -- bash -c "cat <<EOL | sudo tee $INSTALLATION_LOG_FILE > /dev/null
$current_date MISP-Airgap installation

[MISP admin user]
- Admin Username: admin@admin.test
- Admin Password: admin
- Admin API key: $AUTH_KEY

[MYSQL ADMIN]
- Username: root
- Password: $MYSQL_ROOT_PASSWORD

[MYSQL MISP]
- Username: $MYSQL_USER
- Password: $MYSQL_PASSWORD

[MISP internal]
- Path: $PATH_TO_MISP
- Apache user: $WWW_USER
- GPG Email: $GPG_EMAIL_ADDRESS
- GPG Passphrase: $GPG_PASSPHRASE
- SUPERVISOR_USER: $SUPERVISOR_USER
- SUPERVISOR_PASSWORD: $SUPERVISOR_PASSWORD
EOL
"

# Delete old install log
${LXC_MISP} -- sudo rm /var/log/misp_install.log

# Print info
misp_ip=$(lxc list $MISP_CONTAINER --format=json | jq -r '.[0].state.network.eth0.addresses[] | select(.family=="inet").address')

echo "███    ███ ██ ███████ ██████         █████  ██ ██████   ██████   █████  ██████  "
echo "████  ████ ██ ██      ██   ██       ██   ██ ██ ██   ██ ██       ██   ██ ██   ██ "
echo "██ ████ ██ ██ ███████ ██████  █████ ███████ ██ ██████  ██   ███ ███████ ██████  "
echo "██  ██  ██ ██      ██ ██            ██   ██ ██ ██   ██ ██    ██ ██   ██ ██      "
echo "██      ██ ██ ███████ ██            ██   ██ ██ ██   ██  ██████  ██   ██ ██      "
echo "--------------------------------------------------------------------------------------------"
echo -e "${BLUE}MISP ${NC}is up and running on $misp_ip"
echo "--------------------------------------------------------------------------------------------"
echo -e "The following files were created and need either ${RED}protection${NC} or ${RED}removal${NC} (shred on the CLI)"
echo -e "${RED}/home/misp/mysql.txt${NC}"
echo "Contents:"
${LXC_MISP} -- cat /home/misp/mysql.txt
echo -e "${RED}/home/misp/MISP-authkey.txt${NC}"
echo "Contents:"
${LXC_MISP} -- cat /home/misp/MISP-authkey.txt
echo -e "${RED}/var/log/misp_settings.log${NC}"
echo "Contents:"
${LXC_MISP} -- cat $INSTALLATION_LOG_FILE
echo "--------------------------------------------------------------------------------------------"
echo "Hint: You can add the following line to your /etc/hosts file to access MISP through $MISP_DOMAIN:"
echo "$misp_ip $MISP_DOMAIN"

