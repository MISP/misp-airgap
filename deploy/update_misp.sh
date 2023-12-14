#!/bin/bash

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
VIOLET='\033[0;35m'
NC='\033[0m' # No Color

setVars(){
    MISP_IMAGE_NAME=$(generateName "misp")
    MYSQL_IMAGE_NAME=$(generateName "mysql")
    REDIS_IMAGE_NAME=$(generateName "redis")
    MODULES_IMAGE_NAME=$(generateName "modules")
}

setDefaultArgs(){
    default_misp_img=""
    default_current_misp=""
    default_new_misp=$(generateName "misp")

    default_php_ini="yes"

    default_mysql="no"
    default_mysql_img=""
    #default_current_mysql=""
    default_new_mysql=$(generateName "mysql")

    default_redis="no"
    default_redis_img=""
    #default_current_redis=""
    default_new_redis=$(generateName "redis")
    
    default_modules="no"
    default_modules_img=""
    #default_current_modules=""
    default_new_modules=$(generateName "modules")
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

generateName(){
    local name="$1"
    echo "${name}-$(date +%Y-%m-%d-%H-%M-%S)"
}

checkResourceExists() {
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

checkSoftwareDependencies() {
    local dependencies=("jq" "yq")

    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            error "$dep is not installed."
            exit 1
        fi
    done
}


usage(){
    echo "TODO"
}

nonInteractiveConfig(){
    ALL=false
    VALID_ARGS=$(getopt -o c:n:a --long no-php-ini,misp-image:,current-misp:,new-misp:,all,update-mysql,mysql-image:,new-mysql:,update-redis,redis-image:,new-redis:,update-modules,modules-image:,new-modules:  -- "$@")
    if [[ $? -ne 0 ]]; then
        exit 1;
    fi

    eval set -- "$VALID_ARGS"
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-php-ini)
                php_ini="n"
                shift
                ;;
            --misp-image)
                misp_img=$2
                shift 2
                ;;
            -c | --current-misp)
                current_misp=$2
                shift 2
                ;;
            -n | --new-misp)
                new_misp=$2
                shift 2
                ;;
            -a | --all)
                ALL=true
                shift
                ;;
            --update-mysql)
                mysql="y"
                shift
                ;;
            --mysql-image)
                mysql_img=$2
                shift 2
                ;;
            --new-mysql)
                new_mysql=$2
                shift 2
                ;;
            --update-redis)
                redis="y"
                shift
                ;;
            --redis-image)
                redis_img=$2
                shift 2
                ;;
            --new-redis)
                new_redis=$2
                shift 2
                ;;
            --update-modules)
                modules=$2
                shift
                ;;
            --modules-image)
                modules_img=$2
                shift 2
                ;;
            --new-modules)
                new_modules=$2
                shift 2
                ;;
            *)  
                break 
                ;;
        esac
    done

    # Set global values
    MISP_IMAGE=${misp_img:-$default_misp_img}
    CURRENT_MISP=${current_misp:-$default_current_misp}
    NEW_MISP=${new_misp:-$default_new_misp}

    mysql=${mysql:-$default_mysql}
    MYSQL=$(echo "$mysql" | grep -iE '^y(es)?$' > /dev/null && echo true || echo false)
    MYSQL_IMAGE=${mysql_img:-$default_mysql_img}
    NEW_MYSQL=${new_mysql:-$default_new_mysql}

    redis=${redis:-$default_redis}
    REDIS=$(echo "$redis" | grep -iE '^y(es)?$' > /dev/null && echo true || echo false)
    REDIS_IMAGE=${redis_img:-$default_redis_img}
    NEW_REDIS=${new_redis:-$default_new_redis}

    modules=${modules:-$default_modules}
    MODULES=$(echo "$modules" | grep -iE '^y(es)?$' > /dev/null && echo true || echo false)
    MODULES_IMAGE=${modules_img:-$default_modules_img}
    NEW_MODULES=${new_modules:-$default_new_modules}

    php_ini=${php_ini:-$default_php_ini}
    PHP_INI=$(echo "$php_ini" | grep -iE '^y(es)?$' > /dev/null && echo true || echo false)
}

checkNamingConvention(){
    local input="$1"
    local pattern="^[a-zA-Z0-9-]+$"

    if ! [[ "$input" =~ $pattern ]]; then
        return 1
    fi
    return 0
}


validateArgs(){
    local mandatory=("CURRENT_MISP" "MISP_IMAGE")
    for arg in "${mandatory[@]}"; do
        if [ -z "${!arg}" ]; then  
            error "$arg is not set!" 
            exit 1
        fi
    done

    validateContainerSetup "$NEW_MISP" true "MISP" "MISP_IMAGE"
    validateContainerSetup "$NEW_MYSQL" $MYSQL "MySQL" "MYSQL_IMAGE"
    validateContainerSetup "$NEW_REDIS" $REDIS "Redis" "REDIS_IMAGE"
    validateContainerSetup "$NEW_MODULES" $MODULES "Modules" "MODULES_IMAGE"

    # Check for duplicate names
    declare -A name_counts
    ((name_counts["$NEW_MISP"]++))
    if $MYSQL;then
        ((name_counts["$NEW_MYSQL"]++))
    fi
    if $REDIS;then
        ((name_counts["$NEW_REDIS"]++))
    fi
    if $MODULES;then
        ((name_counts["$NEW_MODULES"]++))
    fi

    for name in "${!name_counts[@]}"; do
        if ((name_counts["$name"] >= 2)); then
            error "At least two container have the same new name: $name"
            exit 1
        fi
    done

    # Check current container
    if ! checkResourceExists "container" $CURRENT_MISP; then
        error "Container $CURRENT_MISP could not be found!"
        exit 1
    fi

}

validateContainerSetup() {
    local name=$1
    local flag=$2
    local type=$3
    local image_var_name=$4

    if [ "$flag" = true ]; then
        if ! checkNamingConvention "$name"; then
            error "Name $name for $type container is not valid. Please use only alphanumeric characters and hyphens."
            exit 1
        fi

        if checkResourceExists "container" "$name"; then
            error "Container $name already exists in the current project. Please choose a new name."
            exit 1
        fi

        if [ ! -f "${!image_var_name}" ]; then
            if [ -z "${!image_var_name}" ]; then
                error "No update image for $type specified!"
                exit 1
            fi
            error "The specified image ${!image_var_name} for $type does not exist"
            exit 1       
        fi
    fi
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

    reset
    exit "${code}"
}

interrupt() {
    warn "Script interrupted by user. Delete project and exit ..."
    reset
    exit 130
}

reset(){
    local new_container=("$NEW_MISP" "$NEW_MYSQL" "$NEW_REDIS" "$NEW_MODULES")
    local current_container=("$CURRENT_MISP" "$CURRENT_MYSQL" "$CURRENT_REDIS" "$CURRENT_MODULES")
    local images=("$MISP_IMAGE_NAME" "$MYSQL_IMAGE_NAME" "$REDIS_IMAGE_NAME" "$MODULES_IMAGE_NAME")

    for container in "${new_container[@]}"; do
        for i in $(lxc list --format=json | jq -r '.[].name'); do
            if [ "$i" == "$container" ]; then
                lxc delete "$container" --force
            fi
        done
    done

    for container in "${current_container[@]}"; do
        local status=$(lxc list --format=json | jq -e --arg name "$container"  '.[] | select(.name == $name) | .status')
        if [ -n "$container" ] && [ "$status" == "\"Stopped\"" ]; then
            lxc start "$container" 
        fi
    done

    for image in "${images[@]}";do 
        for i in $(lxc image list --format=json | jq -r '.[].aliases[].name'); do
            if [ "$i" == "$image" ]; then
                lxc image delete "$image"
            fi
        done
    done

    rm -r "$TEMP"
}

getOptionalContainer(){
    # MYSQL
    CURRENT_MYSQL=$(lxc exec "$CURRENT_MISP" -- bash -c "grep 'host' /var/www/MISP/app/Config/database.php | awk '{print \$3}' | sed "s/'.lxd'//g" | sed 's/[^a-zA-Z0-9]//g'")

    # Redis 
    if $REDIS; then
        local redis_host
        redis_host=$(lxc exec "$CURRENT_MISP" -- bash -c 'sudo -u "www-data" -H sh -c "/var/www/MISP/app/Console/cake Admin getSetting MISP.redis_host" | sed "s/\\.lxd$//"')
        CURRENT_REDIS=$(echo $redis_host | jq -r '.value')
    fi

    # Modules
    if $MODULES; then
        local modules_host
        modules_host=$(lxc exec "$CURRENT_MISP" -- bash -c 'sudo -u "www-data" -H sh -c "/var/www/MISP/app/Console/cake Admin getSetting Plugin.Enrichment_services_url" | sed "s/\\.lxd$//"')
        CURRENT_MODULES=$(echo $modules_host | jq -r '.value')
    fi
}

# main
checkSoftwareDependencies
setVars
setDefaultArgs

# Check for interactive install
INTERACTIVE=false
for arg in "$@"; do
    if [[ $arg == "-i" ]] || [[ $arg == "--interactive" ]]; then
        INTERACTIVE=true
        break
    fi
done

if [ "$INTERACTIVE" = true ]; then
    echo "TODO"
    exit 1
    #interactiveConfig
else
    nonInteractiveConfig "$@"
fi

validateArgs

# # check if image fingerprint already exists
# hash=$(sha256sum $FILE | cut -c 1-64)
# for image in $(lxc query "/1.0/images?recursion=1&project=${PROJECT_NAME}" | jq .[].fingerprint -r); do
#     if [ "$image" = "$hash" ]; then
#         error "Image $image already imported. Please check update file or delete current image."
#         exit 1
#     fi
# done

# # check if image alias already exists
# for image in $(lxc image list --project="${PROJECT_NAME}" --format=json | jq -r '.[].aliases[].name'); do
#     if [ "$image" = "$MISP_IMAGE" ]; then
#         error "Image Name already exists."
#         exit 1
#     fi
# done

getOptionalContainer

trap 'interrupt' INT
trap 'err ${LINENO}' ERR

# Create a temporary directory
TEMP=$(mktemp -d)

# Check if the directory was created successfully
if [ -z "$TEMP" ]; then
    error "Creating temporary directory."
    exit 1
fi
okay "Created temporary directory $TEMP."

# Pull config
echo "Extract config..."
lxc file pull -r $CURRENT_MISP/var/www/MISP/app/files /tmp/$TEMP -v
lxc file pull -r $CURRENT_MISP/var/www/MISP/app/tmp /tmp/$TEMP -v
lxc file pull -r $CURRENT_MISP/var/www/MISP/app/Config /tmp/$TEMP -v
lxc file pull -r $CURRENT_MISP/var/www/MISP/app/webroot/img /tmp/$TEMP/webroot/ -v
lxc file pull $CURRENT_MISP/var/www/MISP/app/webroot/gpg.asc /tmp/$TEMP/webroot/ -v
lxc file pull -r $CURRENT_MISP/var/www/MISP/app/View/Emails/html/Custom /tmp/$TEMP/View/Emails/html/ -v
lxc file pull -r $CURRENT_MISP/var/www/MISP/app/View/Emails/text/Custom /tmp/$TEMP/View/Emails/text/ -v
lxc file pull $CURRENT_MISP/var/www/MISP/app/Plugin/CakeResque/Config/config.php /tmp/$TEMP/Plugin/CakeResque/Config/ -v
okay "pulled files"

MYSQL_USER=$(lxc exec "$CURRENT_MISP" -- bash -c "grep 'login' /var/www/MISP/app/Config/database.php | awk '{print \$3}' | sed 's/[^a-zA-Z0-9]//g'")

# stop current MISP container
lxc stop $CURRENT_MISP
okay "container stopped"


# Import new image
lxc image import $MISP_IMAGE --alias $MISP_IMAGE_NAME
okay "Image imported"

# Create new instance
profile=$(lxc config show $CURRENT_MISP | yq eval '.profiles | join(" ")' -)
lxc launch $MISP_IMAGE_NAME $NEW_MISP --profile=$profile
okay "New conatiner created"


# Transfer files to new instance
echo "push config to new instance ..."
lxc file push -r /tmp/$TEMP/files $NEW_MISP/var/www/MISP/app/ -v
lxc file push -r /tmp/$TEMP/tmp $NEW_MISP/var/www/MISP/app/ -v
lxc file push -r /tmp/$TEMP/Config $NEW_MISP/var/www/MISP/app/ -v
lxc file push -r /tmp/$TEMP/webroot/img $NEW_MISP/var/www/MISP/app/webroot/ -v
lxc file push /tmp/$TEMP/webroot/gpg.asc $NEW_MISP/var/www/MISP/app/webroot/ -v
lxc file push -r /tmp/$TEMP/View/Emails/html/Custom $NEW_MISP/var/www/MISP/app/View/Emails/html/ -v
lxc file push -r /tmp/$TEMP/View/Emails/text/Custom $NEW_MISP/var/www/MISP/app/View/Emails/text/ -v
lxc file push /tmp/$TEMP/Plugin/CakeResque/Config/config.php $NEW_MISP/var/www/MISP/app/Plugin/CakeResque/Config/ -v
okay "pushed files"

# Set permissions
lxc exec $NEW_MISP -- sudo chown -R www-data:www-data /var/www/MISP/
lxc exec $NEW_MISP -- sudo chmod -R 775 /var/www/MISP/

# Configure MySQL DB to accept connection from new MISP host
MYSQL_ROOT_PASSWORD="misp"

# get mysql user
# MYSQL_USER=$(lxc exec "$CURRENT_MISP" -- bash -c "grep 'login' /var/www/MISP/app/Config/database.php | awk -F\\\" '{print \$4}'")
# echo $MYSQL_USER  

lxc exec $CURRENT_MYSQL -- mysql -u root -p$MYSQL_ROOT_PASSWORD -e "RENAME USER '$MYSQL_USER'@'$CURRENT_MISP.lxd' TO '$MYSQL_USER'@'$NEW_MISP.lxd';"

# Update
lxc exec $NEW_MISP -- bash -c 'sudo -u "www-data" -H sh -c "/var/www/MISP/app/Console/cake Admin runUpdates"'


# Cleanup: Remove the temporary directory
rm -r "$TEMP"

# Add mysql config change 
# update order? -> add update scripts for different containers
# php ini