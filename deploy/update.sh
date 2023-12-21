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

    SNAP_NAME=$(generateName "update")
}

setDefaultArgs(){
    default_misp="no"
    default_misp_img=""
    default_current_misp=""
    default_new_misp=$(generateName "misp")

    default_mysql="no"
    default_mysql_img=""
    default_new_mysql=$(generateName "mysql")

    default_redis="no"
    default_redis_img=""
    default_new_redis=$(generateName "redis")
    
    default_modules="no"
    default_modules_img=""
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


usage() {
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  -h, --help                     Show this help message and exit."
    echo "  -p, --passwd <password>        Set the MySQL root password."
    echo "  --update-misp                  Update MISP container."
    echo "  --misp-image <image>           Specify the MISP image."
    echo "  --current-misp <name>          Specify the current MISP container name (Mandatory)."
    echo "  --new-misp <name>              Specify the new MISP container name."
    echo "  -a, --all                      Apply updates to all components."
    echo "  --update-mysql                 Update MySQL container."
    echo "  --mysql-image <image>          Specify the MySQL image."
    echo "  --new-mysql <name>             Specify the new MySQL container name."
    echo "  --update-redis                 Update Redis container."
    echo "  --redis-image <image>          Specify the Redis image."
    echo "  --new-redis <name>             Specify the new Redis container name."
    echo "  --update-modules               Update modules container."
    echo "  --modules-image <image>        Specify the modules image."
    echo "  --new-modules <name>           Specify the new modules container name."
    echo
    echo "Examples:"
    echo "  $0 --update-misp --misp-image new_misp_image.tar --current-misp current_misp_container --new-misp new_misp_container -p password"
    echo "  $0 --update-mysql --current-misp current_misp_container --mysql-image new_mysql_image.tar --new-mysql new_mysql_container -p password"
    echo
    echo "Note:"
    echo "  - The script updates specified containers to new versions using provided images."
    echo "  - Mandatory fields must be specified for each component you wish to update."
    echo "  - Use only alphanumeric characters and hyphens for container names."
    exit 1
}


nonInteractiveConfig(){
    VALID_ARGS=$(getopt -o h:ap: --long help,passwd:,update-misp,misp-image:,current-misp:,new-misp:,all,update-mysql,mysql-image:,new-mysql:,update-redis,redis-image:,new-redis:,update-modules,modules-image:,new-modules:  -- "$@")
    if [[ $? -ne 0 ]]; then
        exit 1;
    fi

    eval set -- "$VALID_ARGS"
    while [ $# -gt 0 ]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                shift 
                ;;
            -p | --passswd)
                MYSQL_ROOT_PASSWORD=$2
                shift 2
                ;;
            --update-misp)
                misp="y"
                shift 
                ;;
            --misp-image)
                misp_img=$2
                shift 2
                ;;
            --current-misp)
                current_misp=$2
                shift 2
                ;;
            --new-misp)
                new_misp=$2
                shift 2
                ;;
            -a | --all)
                misp="y"
                mysql="y"
                redis="y"
                modules="y"
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
                modules="y"
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
    misp=${misp:-$default_misp}
    MISP=$(echo "$misp" | grep -iE '^y(es)?$' > /dev/null && echo true || echo false)
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
    local mandatory=("CURRENT_MISP")
    local image=()

    # Check images and if args set
    if ! checkResourceExists "container" $CURRENT_MISP; then
        error "Container $CURRENT_MISP could not be found!"
        exit 1
    fi
    if $MISP; then
        mandatory+=("MISP_IMAGE" "MYSQL_ROOT_PASSWORD")
        image+=("MISP_IMAGE")
    fi
    if $MYSQL; then 
        mandatory+=("MYSQL_IMAGE" "MYSQL_ROOT_PASSWORD")
        image+=("MYSQL_IMAGE")
    fi
    if $REDIS; then 
        mandatory+=("REDIS_IMAGE")
        image+=("REDIS_IMAGE")
    fi
    if $MODULES; then 
        mandatory+=("MODULES_IMAGE")
        image+=("MODULES_IMAGE")
    fi

    for arg in "${mandatory[@]}"; do
        if [ -z "${!arg}" ]; then  
            error "$arg is not set!" 
            exit 1
        fi
    done
    for img in "${image[@]}"; do
        if [ ! -f "${!img}" ]; then
            error "Image ${!img} is not a file or could not be found!"
            exit 1
        fi
    done

    # Check if update is set
    if ! $MISP && ! $MYSQL && ! $REDIS && ! $MODULES; then
        error "No update set for any component. Cancel update ..."
        exit 1
    fi

    # Check if components are running
    if ! checkLXDContainerRunning "$CURRENT_MISP"; then
        error "Container $CURRENT_MISP is not running!"
    fi

    validateNewContainerSetup "$NEW_MISP" $MISP "MISP" "MISP_IMAGE"
    validateNewContainerSetup "$NEW_MYSQL" $MYSQL "MySQL" "MYSQL_IMAGE"
    validateNewContainerSetup "$NEW_REDIS" $REDIS "Redis" "REDIS_IMAGE"
    validateNewContainerSetup "$NEW_MODULES" $MODULES "Modules" "MODULES_IMAGE"

    # Check for duplicate names
    declare -A name_counts

    if $MISP; then
        ((name_counts["$NEW_MISP"]++))
    fi
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
}

checkLXDContainerRunning() {
    local container_name=$1
    local state=$(lxc list "^${container_name}$" --format csv -c s)

    if [ "$state" == "RUNNING" ]; then
        return 0
    fi
    return 1
}

validateNewContainerSetup() {
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
    warn "Script interrupted by user!"
    reset
    exit 130
}

reset(){
    local new_container=("$NEW_MISP" "$NEW_MYSQL" "$NEW_REDIS" "$NEW_MODULES")
    local backup_container=("$BACKUP_MISP" "$BACKUP_MYSQL" "$BACKUP_REDIS" "$BACKUP_MODULES")
    local images=("$MISP_IMAGE_NAME" "$MYSQL_IMAGE_NAME" "$REDIS_IMAGE_NAME" "$MODULES_IMAGE_NAME")

    warn "Reset to state before updating ..."
    sleep 5

    for container in "${new_container[@]}"; do
        for i in $(lxc list --format=json | jq -r '.[].name'); do
            if [ "$i" == "$container" ]; then
                lxc delete "$container" --force
            fi
        done
    done

    for image in "${images[@]}";do 
        for i in $(lxc image list --format=json | jq -r '.[].aliases[].name'); do
            if [ "$i" == "$image" ]; then
                lxc image delete "$image"
            fi
        done
    done

    warn "Restore snapshots ..."
    lxc restore $BACKUP_MISP $SNAP_NAME
    lxc restore $BACKUP_MYSQL $SNAP_NAME
    lxc restore $BACKUP_REDIS $SNAP_NAME
    if $CUSTOM_MODULES; then
        lxc restore $BACKUP_MODULES $SNAP_NAME
    fi

    for container in "${backup_container[@]}"; do
        local status
        status=$(lxc list --format=json | jq -e --arg name "$container"  '.[] | select(.name == $name) | .status')
        if [ -n "$container" ] && [ "$status" == "\"Stopped\"" ]; then
            lxc start "$container" 
        fi
    done

    # Delete snapshots
    lxc delete $BACKUP_MISP/$SNAP_NAME
    lxc delete $BACKUP_MYSQL/$SNAP_NAME
    lxc delete $BACKUP_REDIS/$SNAP_NAME
    if $CUSTOM_MODULES; then
        lxc delete $BACKUP_MODULES/$SNAP_NAME
    fi
}

getAdditionalContainer(){
    CURRENT_MYSQL=$(lxc exec "$CURRENT_MISP" -- bash -c "grep 'host' /var/www/MISP/app/Config/database.php | awk '{print \$3}' | sed "s/'.lxd'//g" | sed 's/[^a-zA-Z0-9-]//g'")

    if ! checkLXDContainerRunning "$CURRENT_MYSQL"; then
        error "Container $CURRENT_MYSQL is not running!"
    fi

    # Check root pwd
    if $MISP || $MYSQL; then
        if ! lxc exec $CURRENT_MYSQL -- mysql -u "root" -p"$MYSQL_ROOT_PASSWORD" -e "quit" > /dev/null 2>&1; then
            error "MySQL root pwd is invalid!"
            exit 1
        fi
    fi

    local redis_host
    redis_host=$(lxc exec "$CURRENT_MISP" -- bash -c 'sudo -u "www-data" -H sh -c "/var/www/MISP/app/Console/cake Admin getSetting MISP.redis_host"')
    CURRENT_REDIS=$(echo $redis_host | jq -r '.value' | sed "s/\\.lxd$//")

    if ! checkLXDContainerRunning "$CURRENT_REDIS"; then
        error "Container $CURRENT_REDIS is not running!"
    fi


    CUSTOM_MODULES=true
    local modules_host
    modules_host=$(lxc exec "$CURRENT_MISP" -- bash -c 'sudo -u "www-data" -H sh -c "/var/www/MISP/app/Console/cake Admin getSetting Plugin.Enrichment_services_url"')
    CURRENT_MODULES=$(echo $modules_host | jq -r '.value' | sed "s/\\.lxd$//")
    if [ "$CURRENT_MODULES" == "http://127.0.0.1" ]; then
        CUSTOM_MODULES=false
    fi
    if $CUSTOM_MODULES; then
        if ! checkLXDContainerRunning "$CURRENT_MODULES"; then
            error "Container $CURRENT_MODULES is not running!"
        fi
    fi
}

cleanupMISP(){
    lxc image delete $MISP_IMAGE_NAME
    rm -r "$TEMP"
}

createRedisSocket(){
    trap 'err ${LINENO}' ERR
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

updateMISP(){
    trap 'err ${LINENO}' ERR
    okay "Update MISP ..."
    TEMP=$(mktemp -d)

    # Check if the directory was created successfully
    if [ -z "$TEMP" ]; then
        error "Creating temporary directory."
        exit 1
    fi
    okay "Created temporary directory $TEMP."

    # Pull config
    okay "Extract files from current MISP..."
    lxc file pull -r $CURRENT_MISP/var/www/MISP/app/files $TEMP -v
    lxc file pull -r $CURRENT_MISP/var/www/MISP/app/tmp $TEMP -v
    lxc file pull -r $CURRENT_MISP/var/www/MISP/app/Config $TEMP -v
    lxc file pull -r $CURRENT_MISP/var/www/MISP/app/webroot/img $TEMP/webroot/ -v
    lxc file pull $CURRENT_MISP/var/www/MISP/app/webroot/gpg.asc $TEMP/webroot/ -v
    lxc file pull -r $CURRENT_MISP/var/www/MISP/app/View/Emails/html/Custom $TEMP/View/Emails/html/ -v
    lxc file pull -r $CURRENT_MISP/var/www/MISP/app/View/Emails/text/Custom $TEMP/View/Emails/text/ -v
    lxc file pull $CURRENT_MISP/var/www/MISP/app/Plugin/CakeResque/Config/config.php $TEMP/Plugin/CakeResque/Config/ -v
    lxc file pull -r $CURRENT_MISP/var/www/MISP/.gnupg/openpgp-revocs.d $TEMP/.gnupg/ -v
    lxc file pull -r $CURRENT_MISP/var/www/MISP/.gnupg/private-keys-v1.d $TEMP/.gnupg/ -v
    lxc file pull $CURRENT_MISP/var/www/MISP/.gnupg/pubring.kbx $TEMP/.gnupg/ -v
    lxc file pull $CURRENT_MISP/var/www/MISP/.gnupg/pubring.kbx~ $TEMP/.gnupg/ -v
    lxc file pull $CURRENT_MISP/var/www/MISP/.gnupg/trustdb.gpg $TEMP/.gnupg/ -v

    okay "Get additional config..."
    MYSQL_USER=$(lxc exec "$CURRENT_MISP" -- bash -c "grep 'login' /var/www/MISP/app/Config/database.php | awk '{print \$3}' | sed 's/[^a-zA-Z0-9]//g'")
    PHP_VERSION=$(lxc exec "$CURRENT_MISP" -- bash -c "php -v | head -n 1 | awk '{print \$2}' | cut -d '.' -f 1,2")
    PHP_MEMORY_LIMIT=$(lxc exec "$CURRENT_MISP" -- sudo -H -u www-data -- grep "memory_limit" /etc/php/$PHP_VERSION/apache2/php.ini | awk -F' = ' '{print $2}')
    PHP_MAX_EXECUTION_TIME=$(lxc exec "$CURRENT_MISP" -- sudo -H -u www-data -- grep "max_execution_time" /etc/php/$PHP_VERSION/apache2/php.ini | awk -F' = ' '{print $2}')
    PHP_UPLOAD_MAX_FILESIZE=$(lxc exec "$CURRENT_MISP" -- sudo -H -u www-data -- grep "upload_max_filesize" /etc/php/$PHP_VERSION/apache2/php.ini | awk -F' = ' '{print $2}')
    PHP_POST_MAX_SIZE=$(lxc exec "$CURRENT_MISP" -- sudo -H -u www-data -- grep "post_max_size" /etc/php/$PHP_VERSION/apache2/php.ini | awk -F' = ' '{print $2}')

    # Import new image
    okay "Import image..."
    lxc image import $MISP_IMAGE --alias $MISP_IMAGE_NAME

    # Create new instance
    okay "Create new MISP instance..."
    local profile
    profile=$(lxc config show $CURRENT_MISP | yq eval '.profiles | join(" ")' -)
    lxc launch $MISP_IMAGE_NAME $NEW_MISP --profile=$profile

    # Transfer files to new instance
    echo "Push files to new MISP instance"
    lxc file push -r $TEMP/files $NEW_MISP/var/www/MISP/app/ -v
    lxc file push -r $TEMP/tmp $NEW_MISP/var/www/MISP/app/ -v
    lxc file push -r $TEMP/Config $NEW_MISP/var/www/MISP/app/ -v
    lxc file push -r $TEMP/webroot/img $NEW_MISP/var/www/MISP/app/webroot/ -v
    lxc file push $TEMP/webroot/gpg.asc $NEW_MISP/var/www/MISP/app/webroot/ -v
    lxc file push -r $TEMP/View/Emails/html/Custom $NEW_MISP/var/www/MISP/app/View/Emails/html/ -v
    lxc file push -r $TEMP/View/Emails/text/Custom $NEW_MISP/var/www/MISP/app/View/Emails/text/ -v
    lxc file push $TEMP/Plugin/CakeResque/Config/config.php $NEW_MISP/var/www/MISP/app/Plugin/CakeResque/Config/ -v
    lxc file push -r $TEMP/.gnupg $NEW_MISP/var/www/MISP/ -v

    # Set permissions
    lxc exec $NEW_MISP -- sudo chown -R www-data:www-data $PATH_TO_MISP
    lxc exec $NEW_MISP -- sudo chmod -R 750 $PATH_TO_MISP
    lxc exec $NEW_MISP -- sudo chmod -R g+ws ${PATH_TO_MISP}/app/tmp
    lxc exec $NEW_MISP -- sudo chmod -R g+ws ${PATH_TO_MISP}/app/files
    lxc exec $NEW_MISP -- sudo chmod -R g+ws ${PATH_TO_MISP}/app/files/scripts/tmp

    # Change host address on MySQL
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
    # lxc exec $NEW_MISP --cwd=${PATH_TO_MISP}/app/Console/worker -- sudo -u "www-data" -H sh -c "bash start.sh"

    okay "Stopping current MISP instance..."
    lxc stop $CURRENT_MISP

    cleanupMISP
}

cleanupMySQL(){
    lxc image delete $MYSQL_IMAGE_NAME
    rm -r $TEMP
}

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

updateMySQL(){
    trap 'err ${LINENO}' ERR
    okay "Update MySQL ..."
    local profile
    profile=$(lxc config show $CURRENT_MYSQL | yq eval '.profiles | join(" ")' -)
    lxc image import $MYSQL_IMAGE --alias $MYSQL_IMAGE_NAME
    lxc launch $MYSQL_IMAGE_NAME $NEW_MYSQL --profile=$profile
    sleep 2

    # Apply config
    lxc exec $NEW_MYSQL -- sed -i 's/bind-address            = 127.0.0.1/bind-address            = 0.0.0.0/' "/etc/mysql/mariadb.conf.d/50-server.cnf"
    INNODB_BUFFER_POOL_SIZE=$(lxc exec "$CURRENT_MYSQL" -- grep "innodb_buffer_pool_size" /etc/mysql/mariadb.conf.d/50-server.cnf | awk -F '=' '/^innodb_buffer_pool_size=/ {print $2}')
    INNODB_CHANGE_BUFFERING=$(lxc exec "$CURRENT_MYSQL" -- grep "innodb_change_buffering" /etc/mysql/mariadb.conf.d/50-server.cnf | awk -F '=' '/^innodb_change_buffering=/ {print $2}')
    INNODB_IO_CAPACITY=$(lxc exec "$CURRENT_MYSQL" -- grep "innodb_io_capacity" /etc/mysql/mariadb.conf.d/50-server.cnf | awk -F '=' '/^innodb_io_capacity=/ {print $2}')
    INNODB_IO_CAPACITY_MAX=$(lxc exec "$CURRENT_MYSQL" -- grep "innodb_io_capacity_max" /etc/mysql/mariadb.conf.d/50-server.cnf | awk -F '=' '/^innodb_io_capacity_max=/ {print $2}')
    INNODB_LOG_FILE_SIZE=$(lxc exec "$CURRENT_MYSQL" -- grep "innodb_log_file_size" /etc/mysql/mariadb.conf.d/50-server.cnf | awk -F '=' '/^innodb_log_file_size=/ {print $2}')
    INNODB_LOG_FILES_IN_GROUP=$(lxc exec "$CURRENT_MYSQL" -- grep "innodb_log_files_in_group" /etc/mysql/mariadb.conf.d/50-server.cnf | awk -F '=' '/^innodb_log_files_in_group=/ {print $2}')
    INNODB_READ_IO_THREADS=$(lxc exec "$CURRENT_MYSQL" -- grep "innodb_read_io_threads" /etc/mysql/mariadb.conf.d/50-server.cnf | awk -F '=' '/^innodb_read_io_threads=/ {print $2}')
    INNODB_STATS_PERISTENT=$(lxc exec "$CURRENT_MYSQL" -- grep "innodb_stats_persistent" /etc/mysql/mariadb.conf.d/50-server.cnf | awk -F '=' '/^innodb_stats_persistent=/ {print $2}')
    INNODB_WRITE_IO_THREADS=$(lxc exec "$CURRENT_MYSQL" -- grep "innodb_write_io_threads" /etc/mysql/mariadb.conf.d/50-server.cnf | awk -F '=' '/^innodb_write_io_threads=/ {print $2}')

    # Modify the configuration file in the new container
    if [ -n "$INNODB_WRITE_IO_THREADS" ]; then
        editMySQLConf "innodb_write_io_threads" "$INNODB_WRITE_IO_THREADS" "$NEW_MYSQL"
    fi
    if [ -n "$INNODB_STATS_PERISTENT" ]; then
        editMySQLConf "innodb_stats_persistent" "$INNODB_STATS_PERISTENT" "$NEW_MYSQL"
    fi
    if [ -n "$INNODB_READ_IO_THREADS" ]; then
        editMySQLConf "innodb_read_io_threads" "$INNODB_READ_IO_THREADS" "$NEW_MYSQL"
    fi
    if [ -n "$INNODB_LOG_FILES_IN_GROUP" ]; then
        editMySQLConf "innodb_log_files_in_group" "$INNODB_LOG_FILES_IN_GROUP" "$NEW_MYSQL"
    fi
    if [ -n "$INNODB_LOG_FILE_SIZE" ]; then
        editMySQLConf "innodb_log_file_size" "$INNODB_LOG_FILE_SIZE" "$NEW_MYSQL"
    fi
    if [ -n "$INNODB_IO_CAPACITY_MAX" ]; then
        editMySQLConf "innodb_io_capacity_max" "$INNODB_IO_CAPACITY_MAX" "$NEW_MYSQL"
    fi
    if [ -n "$INNODB_IO_CAPACITY" ]; then
        editMySQLConf "innodb_io_capacity" "$INNODB_IO_CAPACITY" "$NEW_MYSQL"
    fi
    if [ -n "$INNODB_CHANGE_BUFFERING" ]; then
        editMySQLConf "innodb_change_buffering" "$INNODB_CHANGE_BUFFERING" "$NEW_MYSQL"
    fi
    if [ -n "$INNODB_BUFFER_POOL_SIZE" ]; then
        editMySQLConf "innodb_buffer_pool_size" "$INNODB_BUFFER_POOL_SIZE" "$NEW_MYSQL"
    fi

    # Move data 
    okay "Copying data to new database ..."
    TEMP=$(mktemp -d)
    lxc exec $CURRENT_MYSQL -- mysqldump -u root -p$MYSQL_ROOT_PASSWORD --all-databases > $TEMP/backup.sql
    lxc exec $NEW_MYSQL -- mysql -u root -p$MYSQL_ROOT_PASSWORD < $TEMP/backup.sql

     lxc exec $NEW_MYSQL -- sudo systemctl restart mysql

    # Configure MISP
    lxc exec $CURRENT_MISP -- sed -i "s|$CURRENT_MYSQL.lxd|$NEW_MYSQL.lxd|" "$PATH_TO_MISP/app/Config/database.php"

    lxc stop $CURRENT_MYSQL

    cleanupMySQL
}


cleanupRedis(){
    lxc image delete $REDIS_IMAGE_NAME
}

updateRedis(){
    trap 'err ${LINENO}' ERR
    okay "Update Redis ..."
    local profile
    profile=$(lxc config show $CURRENT_REDIS | yq eval '.profiles | join(" ")' -)
    lxc image import $REDIS_IMAGE --alias $REDIS_IMAGE_NAME
    lxc launch $REDIS_IMAGE_NAME $NEW_REDIS --profile=$profile

    # Configure new Redis
    local port
    port=$(lxc exec "$CURRENT_REDIS" -- grep "port" /etc/redis/redis.conf | awk '/^port/ {print $2}')
    lxc exec $NEW_REDIS -- sed -i "s/^bind .*/bind 0.0.0.0/" "/etc/redis/redis.conf"
    lxc exec $NEW_REDIS -- sed -i "s/^port .*/port $port/" "/etc/redis/redis.conf"
    lxc exec $NEW_REDIS -- systemctl restart redis-server

    # Configure MISP
    lxc exec $CURRENT_MISP -- sed -i "s/'host' => '$CURRENT_REDIS.lxd'/'host' => '$NEW_REDIS.lxd'/; s/'port' => 6379/'port' => $port/" /var/www/MISP/app/Plugin/CakeResque/Config/config.php
    lxc exec $CURRENT_MISP -- sudo -H -u www-data -- /var/www/MISP/app/Console/cake Admin setSetting "Plugin.ZeroMQ_redis_host" "$NEW_REDIS.lxd"
    lxc exec $CURRENT_MISP -- sudo -H -u www-data -- /var/www/MISP/app/Console/cake Admin setSetting "MISP.redis_host" "$NEW_REDIS.lxd"

    lxc stop $CURRENT_REDIS

    cleanupRedis
}

cleanupModules(){
    lxc image delete $MODULES_IMAGE_NAME
}

checkModules(){
    local instance=$1
    if [ "$(lxc exec $instance -- systemctl is-active misp-modules)" = "active" ]; then
        okay "Service misp-modules is running."
    else
        error "Service misp-modules is not running."
        lxc stop "$instance"
        return 1
    fi
}

updateModules(){
    trap 'err ${LINENO}' ERR
    okay "Update Modules ..."
    local profile
    profile=$(lxc config show $CURRENT_MODULES | yq eval '.profiles | join(" ")' -)
    lxc image import $MODULES_IMAGE --alias $MODULES_IMAGE_NAME
    lxc launch $MODULES_IMAGE_NAME $NEW_MODULES --profile=$profile
    sleep 5

    checkModules "$NEW_MODULES"

    # configure MISP
    lxc exec $CURRENT_MISP -- sudo -H -u www-data -- /var/www/MISP/app/Console/cake Admin setSetting "Plugin.Export_services_url" "$NEW_MODULES.lxd"
    lxc exec $CURRENT_MISP -- sudo -H -u www-data -- /var/www/MISP/app/Console/cake Admin setSetting "Plugin.Import_services_url" "$NEW_MODULES.lxd"
    lxc exec $CURRENT_MISP -- sudo -H -u www-data -- /var/www/MISP/app/Console/cake Admin setSetting "Plugin.Enrichment_services_url" "$NEW_MODULES.lxd"

    lxc stop $CURRENT_MODULES

    cleanupModules
}

interactiveConfig(){
    # Installer output
    echo
    echo "################################################################################"
    echo -e "# Welcome to the ${BLUE}MISP-airgap${NC} Update Script                                     #"
    echo "#------------------------------------------------------------------------------#"
    echo -e "# This update script will guide you through the process of updating your       #"
    echo -e "# ${BLUE}MISP${NC} installation within an LXD environment.                                 #"
    echo -e "#                                                                              #"
    echo -e "# ${VIOLET}Attention:${NC}                                                                   #"
    echo -e "# ${VIOLET}It is recommended to back up your current configuration and data before      ${NC}#"
    echo -e "# ${VIOLET}proceeding with the update to prevent any potential data loss.              ${NC} #"
    echo -e "#                                                                              #"
    echo -e "# ${VIOLET}The update process will try to retain your settings, but it is advisable to ${NC} #"
    echo -e "# ${VIOLET}review them post-update to ensure everything is configured as expected.${NC}      #"
    echo -e "#                                                                              #"
    echo "################################################################################"
    echo

    declare -A nameCheckArray

    # Ask for current MISP
    while true; do 
        read -r -p "Name of the current misp container: " current_misp
        CURRENT_MISP=${current_misp:-$default_current_misp}
        if ! checkResourceExists "container" "$CURRENT_MISP"; then
            error "Container '$CURRENT_MISP' does not exist."
            continue
        fi
        break
    done

    # Ask for MISP update
    read -r -p "Do you want to update MISP (y/n, default: $default_misp): " misp
    misp=${misp:-$default_misp}
    MISP=$(echo "$misp" | grep -iE '^y(es)?$' > /dev/null && echo true || echo false)
    if $MISP; then

        # Ask for MISP image
        while true; do
            read -r -e -p "What is the path to the MISP image (default: $default_misp_img): " misp_img
            misp_img=${misp_img:-$default_misp_img}
            if [ ! -f "$misp_img" ]; then
                error "The specified file does not exist."
                continue
            fi
            MISP_IMAGE=$misp_img
            break
        done

        # Ask for new MISP container name
        while true; do
            read -r -p "Name of the new MISP container (default: $default_new_misp): " new_misp
            NEW_MISP=${new_misp:-$default_new_misp}
            if [[ ${nameCheckArray[$NEW_MISP]+_} ]]; then
                error "Name '$NEW_MISP' has already been used. Please choose a different name."
                continue
            fi
            if checkResourceExists "container" "$NEW_MISP"; then
                error "Container '$NEW_MISP' already exists."
                continue
            fi
            if ! checkNamingConvention "$NEW_MISP"; then
                continue
            fi
            nameCheckArray[$NEW_MISP]=1
            break
        done

        while true; do
            read -r -p "Please enter your MySQL root pwd: " root_pwd
            MYSQL_ROOT_PASSWORD=${root_pwd}
            # Add check?
            break
        done
    fi

    # Ask for MySQL update
    read -r -p "Do you want to update MySQL (y/n, default: $default_mysql): " mysql
    mysql=${mysql:-$default_mysql}
    MYSQL=$(echo "$mysql" | grep -iE '^y(es)?$' > /dev/null && echo true || echo false)
    if $MYSQL; then

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

        # Ask for new MySQL container name
        while true; do
            read -r -p "Name of the new MySQL container (default: $default_new_mysql): " new_mysql
            NEW_MYSQL=${new_mysql:-$default_new_mysql}
            if [[ ${nameCheckArray[$NEW_MYSQL]+_} ]]; then
                error "Name '$NEW_MYSQL' has already been used. Please choose a different name."
                continue
            fi
            if checkResourceExists "container" "$NEW_MYSQL"; then
                error "Container '$NEW_MYSQL' already exists."
                continue
            fi
            if ! checkNamingConvention "$NEW_MYSQL"; then
                continue
            fi
            nameCheckArray[$NEW_MYSQL]=1
            break
        done

        if ! $MISP; then
            while true; do
                read -r -p "Please enter your MySQL root pwd: " root_pwd
                MYSQL_ROOT_PASSWORD=${root_pwd}
                # Add check?
                break
            done
        fi
    fi

    read -r -p "Do you want to update Redis (y/n, default: $default_redis): " redis
    redis=${redis:-$default_redis}
    REDIS=$(echo "$redis" | grep -iE '^y(es)?$' > /dev/null && echo true || echo false)
    if $REDIS; then

        # Ask for Redis image
        while true; do
            read -r -e -p "What is the path to the Redis image (default: $default_redis_img): " redis_img
            redis_img=${redis_img:-$default_redis_img}
            if [ ! -f "$redis_img" ]; then
                error "The specified file does not exist."
                continue
            fi
            REDIS_IMAGE=$redis_img
            break
        done

        # Ask for new Redis container name
        while true; do
            read -r -p "Name of the new Redis container (default: $default_new_redis): " new_redis
            NEW_REDIS=${new_redis:-$default_new_redis}
            if [[ ${nameCheckArray[$NEW_REDIS]+_} ]]; then
                error "Name '$NEW_REDIS' has already been used. Please choose a different name."
                continue
            fi
            if checkResourceExists "container" "$NEW_REDIS"; then
                error "Container '$NEW_REDIS' already exists."
                continue
            fi
            if ! checkNamingConvention "$NEW_REDIS"; then
                continue
            fi
            nameCheckArray[$NEW_REDIS]=1
            break
        done
    fi

    read -r -p "Do you want to update Modules (y/n, default: $default_modules): " modules
    modules=${modules:-$default_modules}
    MODULES=$(echo "$modules" | grep -iE '^y(es)?$' > /dev/null && echo true || echo false)
    if $MODULES; then
        # Ask for Modules image
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

        # Ask for new Modules container name
        while true; do
            read -r -p "Name of the new Modules container (default: $default_new_modules): " new_modules
            NEW_MODULES=${new_modules:-$default_new_modules}
            if [[ ${nameCheckArray[$NEW_MODULES]+_} ]]; then
                error "Name '$NEW_MODULES' has already been used. Please choose a different name."
                continue
            fi
            if checkResourceExists "container" "$NEW_MODULES"; then
                error "Container '$NEW_MODULES' already exists."
                continue
            fi
            if ! checkNamingConvention "$NEW_MODULES"; then
                continue
            fi
            nameCheckArray[$NEW_MODULES]=1
            break
        done
    fi

    # Output values set by the user
    echo -e "\nValues set:"
    echo "--------------------------------------------------------------------------------------------------------------------"
    echo -e "Current MISP Container: ${GREEN}$CURRENT_MISP${NC}"
    echo -e "Update MISP: ${GREEN}$MISP${NC}"
    if $MISP; then
        echo -e "New MISP Image Path: ${GREEN}$MISP_IMAGE${NC}"
        echo -e "New MISP Container Name: ${GREEN}$NEW_MISP${NC}"
        echo -e "MySQL Root Password: ${GREEN}$MYSQL_ROOT_PASSWORD${NC}"
    fi
    echo "--------------------------------------------------------------------------------------------------------------------"
    echo -e "Update MySQL: ${GREEN}$MYSQL${NC}"
    if $MYSQL; then
        echo -e "New MySQL Image Path: ${GREEN}$MYSQL_IMAGE${NC}"
        echo -e "New MySQL Container Name: ${GREEN}$NEW_MYSQL${NC}"
        echo -e "MySQL Root Password: ${GREEN}$MYSQL_ROOT_PASSWORD${NC}"
    fi
    echo "--------------------------------------------------------------------------------------------------------------------"
    echo -e "Update Redis: ${GREEN}$REDIS${NC}"
    if $REDIS; then
        echo -e "New Redis Image Path: ${GREEN}$REDIS_IMAGE${NC}"
        echo -e "New Redis Container Name: ${GREEN}$NEW_REDIS${NC}"
    fi
    echo "--------------------------------------------------------------------------------------------------------------------"
    echo -e "Update Modules: ${GREEN}$MODULES${NC}"
    if $MODULES; then
        echo -e "New Modules Image Path: ${GREEN}$MODULES_IMAGE${NC}"
        echo -e "New Modules Container Name: ${GREEN}$NEW_MODULES${NC}"
    fi
    echo "--------------------------------------------------------------------------------------------------------------------"

    # Ask for confirmation
    read -r -p "Do you want to proceed with the installation? (y/n): " confirm
    confirm=${confirm:-$default_confirm}
    if [[ $confirm != "y" ]]; then
        warn "Installation aborted."
        exit 1
    fi
}

# main
if [ -z "$1" ]; then
    usage
fi
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
    interactiveConfig
else
    nonInteractiveConfig "$@"
fi

validateArgs

getAdditionalContainer

# Make snapshots
BACKUP_MISP=$CURRENT_MISP
BACKUP_MYSQL=$CURRENT_MYSQL
BACKUP_REDIS=$CURRENT_REDIS
BACKUP_MODULES=$CURRENT_MODULES

lxc snapshot "$BACKUP_MISP" "$SNAP_NAME"
lxc snapshot "$BACKUP_MYSQL" "$SNAP_NAME"
lxc snapshot "$BACKUP_REDIS" "$SNAP_NAME"

if $CUSTOM_MODULES; then
    lxc snapshot "$BACKUP_MODULES" "$SNAP_NAME"
fi

trap 'interrupt' INT
trap 'err ${LINENO}' ERR

if $MISP; then
    updateMISP
    CURRENT_MISP=$NEW_MISP
fi
if $MYSQL; then
    updateMySQL
    CURRENT_MYSQL=$NEW_MYSQL
fi
if $REDIS; then
    updateRedis
    CURRENT_REDIS=$NEW_REDIS
fi
if $MODULES; then
    updateModules
    CURRENT_MODULES=$NEW_MODULES
fi

# Restart worker
lxc exec $CURRENT_MISP  -- sudo -H -u "www-data" -- ${PATH_TO_MISP}/app/Console/cake CakeResque.CakeResque stop --all
lxc exec $CURRENT_MISP  -- sudo -H -u "www-data" -- ${PATH_TO_MISP}/app/Console/cake CakeResque.CakeResque start --interval 5 --queue default
lxc exec $CURRENT_MISP  -- sudo -H -u "www-data" -- ${PATH_TO_MISP}/app/Console/cake CakeResque.CakeResque start --interval 5 --queue prio
lxc exec $CURRENT_MISP  -- sudo -H -u "www-data" -- ${PATH_TO_MISP}/app/Console/cake CakeResque.CakeResque start --interval 5 --queue cache
lxc exec $CURRENT_MISP  -- sudo -H -u "www-data" -- ${PATH_TO_MISP}/app/Console/cake CakeResque.CakeResque start --interval 5 --queue email
lxc exec $CURRENT_MISP  -- sudo -H -u "www-data" -- ${PATH_TO_MISP}/app/Console/cake CakeResque.CakeResque start --interval 5 --queue update
lxc exec $CURRENT_MISP  -- sudo -H -u "www-data" -- ${PATH_TO_MISP}/app/Console/cake CakeResque.CakeResque startscheduler --interval 5

# Print info
misp_ip=$(lxc list $CURRENT_MISP --format=json | jq -r '.[0].state.network.eth0.addresses[] | select(.family=="inet").address')
echo "--------------------------------------------------------------------------------------------"
echo -e "${BLUE}MISP ${NC}is up and running on $misp_ip"
echo "--------------------------------------------------------------------------------------------"