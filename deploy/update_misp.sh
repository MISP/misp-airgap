#!/bin/bash

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
VIOLET='\033[0;35m'
NC='\033[0m' # No Color

setDefaultArgs(){
    default_misp_img="../build/images/misp.tar.gz"
    default_current_misp=""
    default_new_misp=$(generateName "misp")

    default_php_ini="yes"

    default_mysql="no"
    default_mysql_img="../build/images/mysql.tar.gz"
    #default_current_mysql=""
    default_new_mysql=$(generateName "mysql")

    default_redis="no"
    default_redis_img="../build/images/redis.tar.gz"
    #default_current_redis=""
    default_new_redis=$(generateName "redis")
    
    default_modules="no"
    default_modules_img="../build/images/modules.tar.gz"
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

generate_name(){
    local name="$1"
    echo "${name}-$(date +%Y%m%d%H%M%S)"
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

usage(){
    echo "TODO"
}

nonInteraciveConfig(){
    ALL=false
    VALID_ARGS=$(getopt -o ic:n:a --long interactive,no-php-ini,misp-image:,current-misp:,new-misp:,all,update-mysql,mysql-image:,new-mysql:,update-redis,redis-image:,new-redis:,update-modules,modules-image:,new-modules:  -- "$@")
    if [[ $? -ne 0 ]]; then
        exit 1;
    fi

    eval set -- "$VALID_ARGS"
    while [ $# -gt 0 ]; do
        case "$1" in
            -i | --interactive)
                INTERACTIVE=true
                break
                ;;
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

    MYSQL=${mysql:-$default_mysql}
    MYSQL_IMAGE=${mysql_img:-$default_mysql_img}
    NEW_MYSQL=${new_mysql:-$default_new_mysql}

    REDIS=${redis:-$default_redis}
    REDIS_IMAGE=${redis_img:-$default_redis_img}
    NEW_REDIS=${new_redis:-$default_new_redis}

    MODULES=${modules:-$default_modules}
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
    # Names
    if ! checkNamingConvention $NEW_MISP; then
        error "Name $NEW_MISP for MISP container is not valid. Please use only alphanumeric characters and hyphens."
    fi
    if MYSQL && ! checkNamingConvention $NEW_MYSQL; then
        error "Name $NEW_MYSQL for MySQL container is not valid. Please use only alphanumeric characters and hyphens."
    fi
    if REDIS && ! checkNamingConvention $NEW_REDIS; then
        error "Name $NEW_REDIS for Redis container is not valid. Please use only alphanumeric characters and hyphens."
    fi
    if MODULES && ! checkNamingConvention $NEW_MODULES; then
        error "Name $NEW_MODULES for Modules container is not valid. Please use only alphanumeric characters and hyphens."
    fi

    # Check current container
    if ! checkResourceExists "container" $CURRENT_MISP; then
        error "Container $CURRENT_MISP could not be found!"
    fi

    # Files
    

}

# main
checkSoftwareDependencies
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
    interactiveConfig
else
    nonInteractiveConfig "$@"
fi

validateArgs
# if [ -z "$CURRENT_MISP" ] || [ -z "$FILE" ]; then
#   error "Both -n and -f options are mandatory." >&2
#   usage
# fi

# if ! checkResourceExists "container" $CURRENT_MISP; then
#   error "Container does not exist. Please select the container running MISP."
#   exit 1
# fi

# if checkResourceExists "container" $NEW_MISP; then
#     error "New container with name $NEW_MISP already exists. Please use a new name."
#     exit 1
# fi

# if [ ! -f "$FILE" ]; then
#     error "The specified image file does not exist."
#     exit 1
# fi

PROJECT_NAME=$(get_current_lxd_project)

if [ -z "$NEW_MISP" ]; then
    NEW_MISP=$(generate_name "misp")
    MISP_IMAGE=$(generate_name "misp")
else
    MISP_IMAGE=$(generate_name "$NEW_MISP")
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
    if [ "$image" = "$MISP_IMAGE" ]; then
        error "Image Name already exists."
        exit 1
    fi
done

# check if cotainer name already exists
for container in $(lxc query "/1.0/images?recursion=1&project=${PROJECT_NAME}" | jq .[].alias -r); do
    if [ "$container" = "$NEW_MISP" ]; then
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
lxc file pull -r $CURRENT_MISP/var/www/MISP/app/files /tmp/$temp -v
lxc file pull -r $CURRENT_MISP/var/www/MISP/app/tmp /tmp/$temp -v
lxc file pull -r $CURRENT_MISP/var/www/MISP/app/Config /tmp/$temp -v
lxc file pull -r $CURRENT_MISP/var/www/MISP/app/webroot/img /tmp/$temp/webroot/ -v
lxc file pull $CURRENT_MISP/var/www/MISP/app/webroot/gpg.asc /tmp/$temp/webroot/ -v
lxc file pull -r $CURRENT_MISP/var/www/MISP/app/View/Emails/html/Custom /tmp/$temp/View/Emails/html/ -v
lxc file pull -r $CURRENT_MISP/var/www/MISP/app/View/Emails/text/Custom /tmp/$temp/View/Emails/text/ -v
lxc file pull $CURRENT_MISP/var/www/MISP/app/Plugin/CakeResque/Config/config.php /tmp/$temp/Plugin/CakeResque/Config/ -v
okay "pulled files"

# stop current MISP container
lxc stop $CURRENT_MISP
okay "container stopped"


# Import new image
lxc image import $FILE --alias $MISP_IMAGE
okay "Image imported"

# Create new instance
profile=$(lxc config show $CURRENT_MISP | yq eval '.profiles | join(" ")' -)
lxc launch $MISP_IMAGE $NEW_MISP --profile=$profile
okay "New conatiner created"


# Transfer files to new instance
echo "push config to new instance ..."
lxc file push -r /tmp/$temp/files $NEW_MISP/var/www/MISP/app/ -v
lxc file push -r /tmp/$temp/tmp $NEW_MISP/var/www/MISP/app/ -v
lxc file push -r /tmp/$temp/Config $NEW_MISP/var/www/MISP/app/ -v
lxc file push -r /tmp/$temp/webroot/img $NEW_MISP/var/www/MISP/app/webroot/ -v
lxc file push /tmp/$temp/webroot/gpg.asc $NEW_MISP/var/www/MISP/app/webroot/ -v
lxc file push -r /tmp/$temp/View/Emails/html/Custom $NEW_MISP/var/www/MISP/app/View/Emails/html/ -v
lxc file push -r /tmp/$temp/View/Emails/text/Custom $NEW_MISP/var/www/MISP/app/View/Emails/text/ -v
lxc file push /tmp/$temp/Plugin/CakeResque/Config/config.php $NEW_MISP/var/www/MISP/app/Plugin/CakeResque/Config/ -v
okay "pushed files"

# Set permissions
lxc exec $NEW_MISP -- sudo chown -R www-data:www-data /var/www/MISP/
lxc exec $NEW_MISP -- sudo chmod -R 775 /var/www/MISP/

# Update
lxc exec $NEW_MISP -- bash -c 'sudo -u "www-data" -H sh -c "/var/www/MISP/app/Console/cake Admin runUpdates"'

# Cleanup: Remove the temporary directory
rm -r "$temp"
okay "Removed temporary directory."

# Add mysql config change 
# update order?
#