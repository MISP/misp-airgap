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

    PATH_TO_MISP="/var/www/MISP/"
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
    VALID_ARGS=$(getopt -o c:n:ap: --long passwd:,misp-image:,current-misp:,new-misp:,all,update-mysql,mysql-image:,new-mysql:,update-redis,redis-image:,new-redis:,update-modules,modules-image:,new-modules:  -- "$@")
    if [[ $? -ne 0 ]]; then
        exit 1;
    fi

    eval set -- "$VALID_ARGS"
    while [ $# -gt 0 ]; do
        case "$1" in
            -p | --passswd)
                MYSQL_ROOT_PASSWORD=$2
                shift 2
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
    local mandatory=("CURRENT_MISP" "MISP_IMAGE" "MYSQL_ROOT_PASSWORD")
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

errDB(){
    lxc exec $CURRENT_MYSQL -- mysql -u root -p$MYSQL_ROOT_PASSWORD -e "RENAME USER '$MYSQL_USER'@'$NEW_MISP.lxd' TO '$MYSQL_USER'@'$CURRENT_MISP.lxd';"
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
    CURRENT_MYSQL=$(lxc exec "$CURRENT_MISP" -- bash -c "grep 'host' /var/www/MISP/app/Config/database.php | awk '{print \$3}' | sed "s/'.lxd'//g" | sed 's/[^a-zA-Z0-9-]//g'")

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

cleanup(){
    lxc image delete $MISP_IMAGE_NAME
    rm -r "$TEMP"
}

createRedisSocket(){
    local file_path="/etc/redis/redis.conf"
    local lines_to_add="# create a unix domain socket to listen on\nunixsocket /var/run/redis/redis.sock\n# set permissions for the socket\nunixsocketperm 775"

    lxc exec $NEW_MISP -- usermod -g www-data redis
    lxc exec $NEW_MISP -- mkdir -p /var/run/redis/
    lxc exec $NEW_MISP -- chown -R redis:www-data /var/run/redis
    lxc exec $NEW_MISP -- cp "$file_path" "$file_path.bak"
    lxc exec $NEW_MISP -- bash -c "echo -e \"$lines_to_add\" | cat - \"$file_path\" >tempfile && mv tempfile \"$file_path\""
    lxc exec $NEW_MISP -- usermod -aG redis www-data
    lxc exec $NEW_MISP -- service redis-server restart

    # Modify php.ini
    local php_ini_path="/etc/php/$PHP_VERSION/apache2/php.ini" 
    local socket_path="/var/run/redis/redis.sock"
    lxc exec $NEW_MISP -- sed -i "s|;session.save_path = \"/var/lib/php/sessions\"|session.save_path = \"$socket_path\"|; s|session.save_handler = files|session.save_handler = redis|" $php_ini_path
    lxc exec $NEW_MISP -- sudo service apache2 restart
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
okay "Extract files from current MISP..."
lxc file pull -r $CURRENT_MISP/var/www/MISP/app/files /tmp/$TEMP -v
lxc file pull -r $CURRENT_MISP/var/www/MISP/app/tmp /tmp/$TEMP -v
lxc file pull -r $CURRENT_MISP/var/www/MISP/app/Config /tmp/$TEMP -v
lxc file pull -r $CURRENT_MISP/var/www/MISP/app/webroot/img /tmp/$TEMP/webroot/ -v
lxc file pull $CURRENT_MISP/var/www/MISP/app/webroot/gpg.asc /tmp/$TEMP/webroot/ -v
lxc file pull -r $CURRENT_MISP/var/www/MISP/app/View/Emails/html/Custom /tmp/$TEMP/View/Emails/html/ -v
lxc file pull -r $CURRENT_MISP/var/www/MISP/app/View/Emails/text/Custom /tmp/$TEMP/View/Emails/text/ -v
lxc file pull $CURRENT_MISP/var/www/MISP/app/Plugin/CakeResque/Config/config.php /tmp/$TEMP/Plugin/CakeResque/Config/ -v
lxc file pull -r $CURRENT_MISP/var/www/MISP/.gnupg /tmp/$TEMP/ -v

okay "Get additional config..."
MYSQL_USER=$(lxc exec "$CURRENT_MISP" -- bash -c "grep 'login' /var/www/MISP/app/Config/database.php | awk '{print \$3}' | sed 's/[^a-zA-Z0-9]//g'")
PHP_VERSION=$(lxc exec "$CURRENT_MISP" -- bash -c "php -v | head -n 1 | awk '{print \$2}' | cut -d '.' -f 1,2")
PHP_MEMORY_LIMIT=$(lxc exec "$CURRENT_MISP" -- sudo -H -u www-data -- grep "memory_limit" /etc/php/$PHP_VERSION/apache2/php.ini | awk -F' = ' '{print $2}')
PHP_MAX_EXECUTION_TIME=$(lxc exec "$CURRENT_MISP" -- sudo -H -u www-data -- grep "max_execution_time" /etc/php/$PHP_VERSION/apache2/php.ini | awk -F' = ' '{print $2}')
PHP_UPLOAD_MAX_FILESIZE=$(lxc exec "$CURRENT_MISP" -- sudo -H -u www-data -- grep "upload_max_filesize" /etc/php/$PHP_VERSION/apache2/php.ini | awk -F' = ' '{print $2}')
PHP_POST_MAX_SIZE=$(lxc exec "$CURRENT_MISP" -- sudo -H -u www-data -- grep "post_max_size" /etc/php/$PHP_VERSION/apache2/php.ini | awk -F' = ' '{print $2}')

# stop current MISP container
okay "Stopping current MISP instance..."
lxc stop $CURRENT_MISP


# Import new image
okay "Import image..."
lxc image import $MISP_IMAGE --alias $MISP_IMAGE_NAME


# Create new instance
okay "Create new MISP instance..."
profile=$(lxc config show $CURRENT_MISP | yq eval '.profiles | join(" ")' -)
lxc launch $MISP_IMAGE_NAME $NEW_MISP --profile=$profile


# Transfer files to new instance
echo "Push fies to new MISP instance"
lxc file push -r /tmp/$TEMP/files $NEW_MISP/var/www/MISP/app/ -v
lxc file push -r /tmp/$TEMP/tmp $NEW_MISP/var/www/MISP/app/ -v
lxc file push -r /tmp/$TEMP/Config $NEW_MISP/var/www/MISP/app/ -v
lxc file push -r /tmp/$TEMP/webroot/img $NEW_MISP/var/www/MISP/app/webroot/ -v
lxc file push /tmp/$TEMP/webroot/gpg.asc $NEW_MISP/var/www/MISP/app/webroot/ -v
lxc file push -r /tmp/$TEMP/View/Emails/html/Custom $NEW_MISP/var/www/MISP/app/View/Emails/html/ -v
lxc file push -r /tmp/$TEMP/View/Emails/text/Custom $NEW_MISP/var/www/MISP/app/View/Emails/text/ -v
lxc file push /tmp/$TEMP/Plugin/CakeResque/Config/config.php $NEW_MISP/var/www/MISP/app/Plugin/CakeResque/Config/ -v
lxc file push -r /tmp/$TEMP/.gnupg $NEW_MISP/var/www/MISP/ -v

# Set permissions
lxc exec $NEW_MISP -- sudo chown -R www-data:www-data $PATH_TO_MISP
lxc exec $NEW_MISP -- sudo chmod -R 750 $PATH_TO_MISP
lxc exec $NEW_MISP -- sudo chmod -R g+ws ${PATH_TO_MISP}/app/tmp
lxc exec $NEW_MISP -- sudo chmod -R g+ws ${PATH_TO_MISP}/app/files
lxc exec $NEW_MISP -- sudo chmod -R g+ws ${PATH_TO_MISP}/app/files/scripts/tmp

# Change host address on MySQL
trap 'errDB' ERR 
lxc exec $CURRENT_MYSQL -- mysql -u root -p$MYSQL_ROOT_PASSWORD -e "RENAME USER '$MYSQL_USER'@'$CURRENT_MISP.lxd' TO '$MYSQL_USER'@'$NEW_MISP.lxd';"

# Apply php.ini config
lxc exec $NEW_MISP -- bash -c "grep -q '^memory_limit' /etc/php/$PHP_VERSION/apache2/php.ini && sed -i 's/^memory_limit.*/memory_limit = $PHP_MEMORY_LIMIT/' /etc/php/$PHP_VERSION/apache2/php.ini || echo 'memory_limit = $PHP_MEMORY_LIMIT' >> /etc/php/$PHP_VERSION/apache2/php.ini"
lxc exec $NEW_MISP -- bash -c "grep -q '^max_execution_time' /etc/php/$PHP_VERSION/apache2/php.ini && sed -i 's/^max_execution_time.*/max_execution_time = $PHP_MAX_EXECUTION_TIME/' /etc/php/$PHP_VERSION/apache2/php.ini || echo 'max_execution_time = $PHP_MAX_EXECUTION_TIME' >> /etc/php/$PHP_VERSION/apache2/php.ini"
lxc exec $NEW_MISP -- bash -c "grep -q '^upload_max_filesize' /etc/php/$PHP_VERSION/apache2/php.ini && sed -i 's/^upload_max_filesize.*/upload_max_filesize = $PHP_UPLOAD_MAX_FILESIZE/' /etc/php/$PHP_VERSION/apache2/php.ini || echo 'upload_max_filesize = $PHP_UPLOAD_MAX_FILESIZE' >> /etc/php/$PHP_VERSION/apache2/php.ini"
lxc exec $NEW_MISP -- bash -c "grep -q '^mempost_max_sizeory_limit' /etc/php/$PHP_VERSION/apache2/php.ini && sed -i 's/^post_max_size.*/post_max_size = $PHP_POST_MAX_SIZE/' /etc/php/$PHP_VERSION/apache2/php.ini || echo 'post_max_size = $PHP_POST_MAX_SIZE' >> /etc/php/$PHP_VERSION/apache2/php.ini"
lxc exec $NEW_MISP -- sudo service apache2 restart

createRedisSocket

# Update
lxc exec $NEW_MISP -- sudo -u www-data bash -c "$PATH_TO_MISP/app/Console/cake Admin runUpdates"

# Start workers
lxc exec $NEW_MISP --cwd=${PATH_TO_MISP}/app/Console/worker -- sudo -u "www-data" -H sh -c "bash start.sh"

# Cleanup: Remove the temporary directory
cleanup

# Print info
misp_ip=$(lxc list $NEW_MISP --format=json | jq -r '.[0].state.network.eth0.addresses[] | select(.family=="inet").address')
echo "--------------------------------------------------------------------------------------------"
echo -e "${BLUE}MISP ${NC}is up and running on $misp_ip"
echo "--------------------------------------------------------------------------------------------"
echo -e "The following files were created and need either ${RED}protection${NC} or ${RED}removal${NC} (shred on the CLI)"
echo -e "${RED}/home/misp/mysql.txt${NC}"
echo "Contents:"
lxc exec $NEW_MISP -- cat /home/misp/mysql.txt
echo -e "${RED}/home/misp/MISP-authkey.txt${NC}"
echo "Contents:"
lxc exec $NEW_MISP -- cat /home/misp/MISP-authkey.txt
echo "--------------------------------------------------------------------------------------------"
echo "User: admin@admin.test"
echo "Password: admin"
echo "--------------------------------------------------------------------------------------------"