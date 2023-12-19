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
    default_misp_img=""
    default_current_misp=""
    default_new_misp=$(generateName "misp")

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
    echo "  $0 --update-misp --misp-image new_misp_image.tar --current-misp current_misp_container --new-misp new_misp_container"
    echo "  $0 --update-mysql --mysql-image new_mysql_image.tar --new-mysql new_mysql_container"
    echo
    echo "Note:"
    echo "  - The script updates specified containers to new versions using provided images."
    echo "  - Mandatory fields must be specified for each component you wish to update."
    echo "  - Use only alphanumeric characters and hyphens for container names."
}


nonInteractiveConfig(){
    ALL=false
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

    # Check current container
    if ! checkResourceExists "container" $CURRENT_MISP; then
        error "Container $CURRENT_MISP could not be found!"
        exit 1
    fi
    if $MISP; then
        mandatory+=("MISP_IMAGE" "MYSQL_ROOT_PASSWORD")
        image+=("MISP_IMAGE")
    fi
    if $MYSQL; then 
        mandatory+=("MYSQL_IMAGE")
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

    validateNewContainerSetup "$NEW_MISP" $MISP "MISP" "MISP_IMAGE"
    validateNewContainerSetup "$NEW_MYSQL" $MYSQL "MySQL" "MYSQL_IMAGE"
    validateNewContainerSetup "$NEW_REDIS" $REDIS "Redis" "REDIS_IMAGE"
    validateNewContainerSetup "$NEW_MODULES" $MODULES "Modules" "MODULES_IMAGE"

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
    local current_container=("$CURRENT_MISP" "$CURRENT_MYSQL" "$CURRENT_REDIS" "$CURRENT_MODULES")
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
    lxc restore $CURRENT_MISP $SNAP_NAME
    if $MYSQL || $MISP; then
        lxc restore $CURRENT_MYSQL $SNAP_NAME
    fi
    if $REDIS; then
        lxc restore $CURRENT_REDIS $SNAP_NAME
    fi
    if $MODULES; then
        lxc restore $CURRENT_MODULES $SNAP_NAME
    fi

    for container in "${current_container[@]}"; do
        local status
        status=$(lxc list --format=json | jq -e --arg name "$container"  '.[] | select(.name == $name) | .status')
        if [ -n "$container" ] && [ "$status" == "\"Stopped\"" ]; then
            lxc start "$container" 
        fi
    done
}

getOptionalContainer(){
    CURRENT_MYSQL=$(lxc exec "$CURRENT_MISP" -- bash -c "grep 'host' /var/www/MISP/app/Config/database.php | awk '{print \$3}' | sed "s/'.lxd'//g" | sed 's/[^a-zA-Z0-9-]//g'")
 
    if $REDIS; then
        local redis_host
        redis_host=$(lxc exec "$CURRENT_MISP" -- bash -c 'sudo -u "www-data" -H sh -c "/var/www/MISP/app/Console/cake Admin getSetting MISP.redis_host"')
        CURRENT_REDIS=$(echo $redis_host | jq -r '.value' | sed "s/\\.lxd$//")
    fi

    if $MODULES; then
        local modules_host
        modules_host=$(lxc exec "$CURRENT_MISP" -- bash -c 'sudo -u "www-data" -H sh -c "/var/www/MISP/app/Console/cake Admin getSetting Plugin.Enrichment_services_url"')
        CURRENT_MODULES=$(echo $modules_host | jq -r '.value' | sed "s/\\.lxd$//")
    fi
}

cleanupMISP(){
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

updateMISP(){
    okay "Update MISP"
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
    lxc file pull -r $CURRENT_MISP/var/www/MISP/.gnupg/openpgp-revocs.d /tmp/$TEMP/.gnupg/ -v
    lxc file pull -r $CURRENT_MISP/var/www/MISP/.gnupg/private-keys-v1.d /tmp/$TEMP/.gnupg/ -v
    lxc file pull $CURRENT_MISP/var/www/MISP/.gnupg/pubring.kbx /tmp/$TEMP/.gnupg/ -v
    lxc file pull $CURRENT_MISP/var/www/MISP/.gnupg/pubring.kbx~ /tmp/$TEMP/.gnupg/ -v
    lxc file pull $CURRENT_MISP/var/www/MISP/.gnupg/trustdb.gpg /tmp/$TEMP/.gnupg/ -v

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
    local profile
    profile=$(lxc config show $CURRENT_MISP | yq eval '.profiles | join(" ")' -)
    lxc launch $MISP_IMAGE_NAME $NEW_MISP --profile=$profile

    # Transfer files to new instance
    echo "Push files to new MISP instance"
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
    cleanupMISP

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
    okay "Update MySQL"
    local profile
    profile=$(lxc config show $CURRENT_MYSQL | yq eval '.profiles | join(" ")' -)
    lxc image import $MYSQL_IMAGE --alias $MYSQL_IMAGE_NAME
    lxc launch $MYSQL_IMAGE_NAME $NEW_MYSQL --profile=$profile

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
    #lxc exec $NEW_MISP -- bash -c "grep -q '^memory_limit' /etc/php/$PHP_VERSION/apache2/php.ini && sed -i 's/^memory_limit.*/memory_limit = $PHP_MEMORY_LIMIT/' /etc/php/$PHP_VERSION/apache2/php.ini || echo 'memory_limit = $PHP_MEMORY_LIMIT' >> /etc/php/$PHP_VERSION/apache2/php.ini"
    
    editMySQLConf "innodb_write_io_threads" "$INNODB_WRITE_IO_THREADS" "$NEW_MYSQL"
    editMySQLConf "innodb_stats_persistent" "$INNODB_STATS_PERISTENT" "$NEW_MYSQL"
    editMySQLConf "innodb_read_io_threads" "$INNODB_READ_IO_THREADS" "$NEW_MYSQL"
    editMySQLConf "innodb_log_files_in_group" "$INNODB_LOG_FILES_IN_GROUP" "$NEW_MYSQL"
    editMySQLConf "innodb_log_file_size" "$INNODB_LOG_FILE_SIZE" "$NEW_MYSQL"
    editMySQLConf "innodb_io_capacity_max" "$INNODB_IO_CAPACITY_MAX" "$NEW_MYSQL"
    editMySQLConf "innodb_io_capacity" "$INNODB_IO_CAPACITY" "$NEW_MYSQL"
    editMySQLConf "innodb_change_buffering" "$INNODB_CHANGE_BUFFERING" "$NEW_MYSQL"
    editMySQLConf "innodb_buffer_pool_size" "$INNODB_BUFFER_POOL_SIZE" "$NEW_MYSQL"


    # lxc exec $NEW_MYSQL -- bash -c "\
    # if grep -q '^$key' /etc/mysql/mariadb.conf.d/50-server.cnf; then \
    #     sed -i 's/^$key.*/$key = $INNODB_BUFFER_POOL_SIZE/' /etc/mysql/mariadb.conf.d/50-server.cnf; \
    # else \
    #     awk -v $key='$key = $INNODB_BUFFER_POOL_SIZE' \
    #     '/^\[mysqld\]/ {print; print $key; next} {print}' \
    #     /etc/mysql/mariadb.conf.d/50-server.cnf > /tmp/php.ini.modified && \
    #     mv /tmp/php.ini.modified /etc/mysql/mariadb.conf.d/50-server.cnf; \
    # fi"

    lxc exec $NEW_MYSQL -- sudo systemctl restart mysql

    # Move data 
    okay "Copying data to new database ..."
    TEMP=$(mktemp -d)
    lxc exec $CURRENT_MYSQL -- mysqldump -u root -p$MYSQL_ROOT_PASSWORD --all-databases > /tmp/$TEMP/backup.sql
    lxc exec $NEW_MYSQL -- mysql -u root -p < /tmp/$TEMP/backup.sql

    # Configure MISP
    lxc exec $CURRENT_MISP -- sed -i "s/$CURRENT_MYSQL.lxd/$NEW_MYSQL.lxd" $PATH_TO_MISP/app/Config/database.php

    lxc stop $CURRENT_MYSQL

    cleanupMySQL
}


cleanupRedis(){
    lxc image delete $REDIS_IMAGE_NAME
}

updateRedis(){
    okay "Updating Redis ..."
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
    lxc exec $CURRENT_MISP -- sed -i "s/'host' => '127.0.0.1'/'host' => '$NEW_REDIS.lxd'/; s/'port' => 6379/'port' => $port/" /var/www/MISP/app/Plugin/CakeResque/Config/config.php
    lxc exec $CURRENT_MISP -- sudo -H -u www-data -- /var/www/MISP/app/Console/cake Admin setSetting "Plugin.ZeroMQ_redis_host" "$NEW_REDIS.lxd"

    lxc stop $CURRENT_REDIS

    cleanupRedis
}

cleanupModules(){
    lxc image delete $MODULES_IMAGE_NAME
}

updateModules(){
    okay "Update Modules ..."
    local profile
    profile=$(lxc config show $CURRENT_MODULES | yq eval '.profiles | join(" ")' -)
    lxc image import $MODULES_IMAGE --alias $MODULES_IMAGE_NAME
    lxc launch $MODULES_IMAGE_NAME $NEW_MODULES --profile=$profile
    checkModules "$NEW_MODULES"

    # configure MISP
    lxc exec $CURRENT_MISP -- sudo -H -u www-data -- /var/www/MISP/app/Console/cake Admin setSetting "Plugin.Export_services_url" "$NEW_MODULES.lxd"
    lxc exec $CURRENT_MISP -- sudo -H -u www-data -- /var/www/MISP/app/Console/cake Admin setSetting "Plugin.Import_services_url" "$NEW_MODULES.lxd"
    lxc exec $CURRENT_MISP -- sudo -H -u www-data -- /var/www/MISP/app/Console/cake Admin setSetting "Plugin.Enrichment_services_url" "$NEW_MODULES.lxd"

    lxc stop $CURRENT_MODULES

    cleanupModules
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

# Make snapshots
lxc snapshot "$CURRENT_MISP" "$SNAP_NAME"
if $MYSQL || $MISP; then 
    lxc snapshot "$CURRENT_MYSQL" "$SNAP_NAME"
fi
if $REDIS; then
    lxc snapshot "$CURRENT_REDIS" "$SNAP_NAME"
fi
if $MODULES; then
    lxc snapshot "$CURRENT_MODULES" "$SNAP_NAME"
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

