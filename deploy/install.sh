#!/bin/bash

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
VIOLET='\033[0;35m'
NC='\033[0m' # No Color

check_resource_exists() {
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


wait_for_container() {
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

generate_name(){
    local name="$1"
    echo "${name}-$(date +%Y%m%d%H%M%S)"
}

if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is not installed.${NC}"
    exit 1
fi

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

# set default values
MISP_PATH="/var/www/"
default_confirm="no"
default_prod="no"
default_misp_project=$(generate_name "misp-project")

default_misp_img="./../build/images/misp.tar.gz"
default_misp_name=$(generate_name "misp")

default_mysql="yes"
default_mysql_img="../build/images/mysql.tar.gz"
default_mysql_name=$(generate_name "mysql")
default_mysql_user="misp"
default_mysql_pwd="misp"
default_mysql_db="misp"
default_mysql_root_pwd="misp"

default_redis="yes"
default_redis_img="../build/images/redis.tar.gz"
default_redis_name=$(generate_name "redis")

default_app_partition=""
default_db_partition=""

# Ask for confirmation
read -p "Do you want to proceed with the installation? (y/n): " confirm
confirm=${confirm:-$default_confirm}
if [[ $confirm != "y" ]]; then
  echo "Installation aborted."
  exit 1
fi

# Ask for LXD project name
read -p "Name of the misp project (default: $default_misp_project): " misp_project
PROJECT_NAME=${misp_project:-$default_misp_project}
if check_resource_exists "project" "$PROJECT_NAME"; then
    echo -e "${RED}Error: Project '$PROJECT_NAME' already exists.${NC}"
    exit 1
fi

# Ask for misp image 
read -e -p "What is the path to the misp image (default: $default_misp_img): " misp_img
misp_img=${misp_img:-$default_misp_img}
if [ ! -e "$misp_img" ]; then
    echo -e "${RED}Error${NC}: The specified file does not exist."
    exit 1
fi
MISP_IMAGE=$misp_img
# Ask for name
read -p "Name of the misp container (default: $default_misp_name): " misp_name
MISP_CONTAINER=${misp_name:-$default_misp_name}
if check_resource_exists "container" "$MISP_CONTAINER"; then
    echo -e "${RED}Error: Container '$MISP_CONTAINER' already exists.${NC}"
    exit 1
fi


# Ask for mysql installation
read -p "Do you want to install a mysql instance (y/n, default: $default_mysql): " mysql
mysql=${mysql:-$default_mysql}
mysql=$(echo "$mysql" | grep -iE '^y(es)?$' > /dev/null && echo true || echo false)
if $mysql; then
    # Ask for image
    read -e -p "What is the path to the mysql image (default: $default_mysql_img): " mysql_img
    mysql_img=${mysql_img:-$default_mysql_img}
    if [ ! -e "$mysql_img" ]; then
        echo -e "${RED}Error${NC}: The specified file does not exist."
        exit 1
    fi
    MYSQL_IMAGE=$mysql_img
    # Ask for name
    read -p "Name of the mysql container (default: $default_mysql_name): " mysql_name
    MYSQL_CONTAINER=${mysql_name:-$default_mysql_name}
    if check_resource_exists "container" "$MYSQL_CONTAINER"; then
    echo -e "${RED}Error: Container '$MYSQL_CONTAINER' already exists.${NC}"
    exit 1
    fi
    # Ask for credetials
    read -p "MySQL Database (default: $default_mysql_db): " mysql_db
    MYSQL_DATABASE=${mysql_db:-default_mysql_db}
    read -p "MySQL User (default: $default_mysql_user): " mysql_user
    MYSQL_USER=${mysql_user:-default_mysql_user}
    read -p "MySQL User Password (default: $default_mysql_pwd): " mysql_pwd
    MYSQL_PASSWORD=${mysql_pwd:-default_mysql_pwd}
    read -p "MySQL Root Password (default: $default_mysql_root_pwd): " mysql_root_pwd
    MYSQL_ROOT_PASSWORD=${mysql_root_pwd:-default_mysql_root_pwd}
fi

# Ask for redis installation 
read -p "Do you want to install a redis instance (y/n, default: $default_redis): " redis
redis=${redis:-$default_redis}
redis=$(echo "$redis" | grep -iE '^y(es)?$' > /dev/null && echo true || echo false)
if $redis; then
    # Ask for image
    read -e -p "What is the path to the redis image (default: $default_redis_img): " redis_img
    redis_img=${redis_img:-$default_redis_img}
    if [ ! -e "$redis_img" ]; then
        echo -e "${RED}Error${NC}: The specified file does not exist."
        exit 1
    fi
    REDIS_IMAGE=$redis_img
    # Ask for name
    read -p "Name of the Redis container (default: $default_redis_name): " redis_name
    REDIS_CONTAINER=${redis_name:-$default_redis_name}
    if check_resource_exists "container" "$REDIS_CONTAINER"; then
        echo -e "${RED}Error: Container '$REDIS_CONTAINER' already exists.${NC}"
        exit 1
    fi
fi

# Ask for dedicated partitions
read -p "Dedicated partition for MISP container (leave blank if none): " app_partition
APP_PARTITION=${app_partition:-$default_app_partition}
if $mysql || $redis; then
    read -p "Dedicated partition for DB container(s) (leave blank if none): " db_partition
    DB_PARTITION=${db_partition:-$default_db_partition}
fi

# Ask if used in prod
read -p "Do you want to use this setup in production (y/n, default: $default_prod): " prod
prod=${prod:-$default_prod} 
PROD=$(echo "$prod" | grep -iE '^y(es)?$' > /dev/null && echo true || echo false)





# Create Project 
echo "Project: $PROJECT_NAME"
lxc project create "$PROJECT_NAME"
lxc project switch "$PROJECT_NAME"

# Create storage pools
APP_STORAGE=$(generate_name "app-storage")
if check_resource_exists "storage" "$APP_STORAGE"; then
    echo -e "${RED}Error: Storage '$APP_STORAGE' already exists.${NC}"
    exit 1
fi
lxc storage create "$APP_STORAGE" zfs source="$APP_PARTITION"


if $redis || $mysql; then
    DB_STORAGE=$(generate_name "db-storage")
    if check_resource_exists "storage" "$DB_STORAGE"; then
        echo -e "${RED}Error: Storage '$DB_STORAGE' already exists.${NC}"
        exit 1
    fi
    lxc storage create "$DB_STORAGE" zfs source="$DB_PARTITION"
fi

# Create Network
NETWORK_NAME=$(generate_name "net")
# max len of 15 
NETWORK_NAME=${NETWORK_NAME:0:15}
if check_resource_exists "network" "$NETWORK_NAME"; then
    echo -e "${RED}Error: Network '$NETWORK_NAME' already exists.${NC}"
fi
lxc network create "$NETWORK_NAME" --type=bridge

# Create Profiles
APP_PROFILE=$(generate_name "app")
if check_resource_exists "profile" "$APP_PROFILE"; then
    echo -e "${RED}Error: Profile '$APP_PROFILE' already exists.${NC}"
fi
lxc profile create "$APP_PROFILE"

DB_PROFILE=$(generate_name "db")
echo "db-profile: $DB_PROFILE"
if check_resource_exists "profile" "$DB_PROFILE"; then
    echo -e "${RED}Error: Profile '$DB_PROFILE' already exists.${NC}"
fi
lxc profile create "$DB_PROFILE"

lxc profile device add "$DB_PROFILE" root disk path=/ pool="$DB_STORAGE"
lxc profile device add "$DB_PROFILE" eth0 nic name=eth0 network="$NETWORK_NAME"

lxc profile device add "$APP_PROFILE" root disk path=/ pool="$APP_STORAGE"
lxc profile device add "$APP_PROFILE" eth0 nic name=eth0 network="$NETWORK_NAME"

# Import Images
MISP_IMAGE_NAME=$(generate_name "misp")
echo "image: $MISP_IMAGE_NAME"
if check_resource_exists "image" "$MISP_IMAGE_NAME"; then
    echo -e "${RED}Error: Image '$MISP_IMAGE_NAME' already exists.${NC}"
fi
lxc image import $MISP_IMAGE --alias $MISP_IMAGE_NAME

MYSQL_IMAGE_NAME=$(generate_name "mysql")
if check_resource_exists "image" "$MYSQL_IMAGE_NAME"; then
    echo -e "${RED}Error: Image '$MYSQL_IMAGE_NAME' already exists.${NC}"
fi
lxc image import $MYSQL_IMAGE --alias $MYSQL_IMAGE_NAME

REDIS_IMAGE_NAME=$(generate_name "redis")
if check_resource_exists "image" "$REDIS_IMAGE_NAME"; then
    echo -e "${RED}Error: Image '$REDIS_IMAGE_NAME' already exists.${NC}"
fi
lxc image import $REDIS_IMAGE --alias $REDIS_IMAGE_NAME

# Launch Containers
echo "Create containers ..."
lxc launch $MISP_IMAGE_NAME $MISP_CONTAINER --profile=$APP_PROFILE 
lxc launch $MYSQL_IMAGE_NAME $MYSQL_CONTAINER --profile=$DB_PROFILE
lxc launch $REDIS_IMAGE_NAME $REDIS_CONTAINER --profile=$DB_PROFILE 

# Configure MISP
wait_for_container $MISP_CONTAINER
## Set misp.live
if $PROD; then
    lxc exec $MISP_CONTAINER -- sudo -u www-data -H sh -c "$MISP_PATH/MISP/app/Console/cake Admin setSetting MISP.live true"
    echo "${YELLOW}MISP runs in production mode!${NC}"
fi


## Edit redis host
lxc exec $MISP_CONTAINER -- sudo -u www-data -H sh -c "$MISP_PATH/MISP/app/Console/cake Admin setSetting MISP.redis_host $REDIS_CONTAINER.lxd"
## Edit database conf
lxc exec $MISP_CONTAINER -- sed -i "s/'database' => 'misp'/'database' => '$MYSQL_DATABASE'/" $MISP_PATH/MISP/app/Config/database.php
lxc exec $MISP_CONTAINER -- sed -i "s/localhost/$MYSQL_CONTAINER.lxd/" $MISP_PATH/MISP/app/Config/database.php
lxc exec $MISP_CONTAINER -- sed -i "s/'login' => '.*'/'login' => '$MYSQL_USER'/" "$MISP_PATH/MISP/app/Config/database.php"
lxc exec $MISP_CONTAINER -- sed -i "s/8889/3306/" $MISP_PATH/MISP/app/Config/database.php
lxc exec $MISP_CONTAINER -- sed -i "s/'password' => '.*'/'password' => '$MYSQL_PASSWORD'/" "$MISP_PATH/MISP/app/Config/database.php"
 

# Configure MySQL
wait_for_container $MYSQL_CONTAINER
## Add user + DB
lxc exec $MYSQL_CONTAINER -- mysql -u root -e "CREATE DATABASE $MYSQL_DATABASE;"
lxc exec $MYSQL_CONTAINER -- mysql -u root -e "GRANT ALL PRIVILEGES ON $MYSQL_DATABASE.* TO '$MYSQL_USER'@'$MISP_HOST' IDENTIFIED BY '$MYSQL_PASSWORD';"

## Configure remote access
lxc exec $MYSQL_CONTAINER -- sed -i 's/bind-address            = 127.0.0.1/bind-address            = 0.0.0.0/' "/etc/mysql/mariadb.conf.d/50-server.cnf"
lxc exec $MYSQL_CONTAINER -- sudo systemctl restart mysql

## Check connection + import schema
table_count=$(lxc exec $MISP_CONTAINER -- mysql -u $MYSQL_USER --password="$MYSQL_PASSWORD" -h $MYSQL_CONTAINER.lxd -P 3306 $MYSQL_DATABASE -e "SHOW TABLES;" | wc -l)
if [ $? -eq 0 ]; then
                echo -e "${GREEN}Connected to database successfully!${NC}"
                if [ $table_count -lt 73 ]; then
                    echo "Database misp is empty, importing tables from misp container ..."
                    lxc exec $MISP_CONTAINER -- bash -c "mysql -u $MYSQL_USER --password=$MYSQL_PASSWORD $MYSQL_DATABASE -h $MYSQL_CONTAINER.lxd -P 3306 2>&1 < $MISP_PATH/MISP/INSTALL/MYSQL.sql"
                else
                    echo "Database misp available"
                fi
else
    echo -e "${RED}ERROR${NC}:"
    echo $table_count
fi

## secure mysql installation
lxc exec $MYSQL_CONTAINER -- mysqladmin -u root password "$MYSQL_ROOT_PASSWORD"
lxc exec $MYSQL_CONTAINER -- mysql -u root -p"$MYSQL_ROOT_PASSWORD" <<EOF
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
EOF

## Update Database
lxc exec $MISP_CONTAINER -- sudo -u www-data -H sh -c "$MISP_PATH/MISP/app/Console/cake Admin runUpdates"


# Configure Redis
wait_for_container $REDIS_CONTAINER
## Cofigure remote access
lxc exec $REDIS_CONTAINER -- sed -i "s/^bind .*/bind 0.0.0.0/" "/etc/redis/redis.conf"
lxc exec $REDIS_CONTAINER -- systemctl restart redis-server


echo -e "${GREEN}Setup finished!${NC}"

misp_ip=$(lxc list $MISP_CONTAINER --format=json | jq -r '.[0].state.network.eth0.addresses[] | select(.family=="inet").address')

echo -e "${BLUE}MISP ${NC}is up and running on $misp_ip"

# print credentials