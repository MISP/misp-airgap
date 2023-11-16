#!/bin/bash

check_and_set_variable() {
    local variable_name="$1"
    local default_value="$2"

    if [ -z "${!variable_name}" ]; then
        echo "$variable_name is not set, using default value '$default_value'"
        eval "$variable_name=\"$default_value\""
    fi
}

check_resource_exists() {
    resource_type="$1"
    resource_name="$2"

    case "$resource_type" in
        "container")
            lxc info "$resource_name" &>/dev/null
            ;;
        "image_alias")
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
    esac

    if [ $? -eq 0 ]; then
        echo "Error: $resource_type '$resource_name' already exists."
        exit 1
    fi
}

wait_for_container() {
    local container_name="$1"

    while true; do
        status=$(lxc list --format=json | jq -e --arg name "$container_name"  '.[] | select(.name == $name) | .status')
        if [ $status = "\"Running\"" ]; then
            echo "$container_name is running."
            break
        fi
        echo "Waiting for $container_name container to start."
        sleep 5
    done
}


# Source environment variables
source .env

# Run multiple checks before starting the installation process
check_resource_exists "image_alias" "misp"
check_resource_exists "image_alias" "mysql"
check_resource_exists "image_alias" "redis"

check_and_set_variable "DB_STORAGE" "db-storage"
check_and_set_variable "APP_STORAGE" "app-storage"
check_resource_exists "storage" "$DB_STORAGE"
check_resource_exists "storage" "$APP_STORAGE"

check_and_set_variable "PROJECT_NAME" "misp-project"
check_resource_exists "project" "$PROJECT_NAME"

check_and_set_variable "NETWORK_NAME" "misp-net"
check_resource_exists "network" "$NETWORK_NAME"

# Create Project 
lxc project create "$PROJECT_NAME"
lxc project switch "$PROJECT_NAME"

# Container are not unique in over different projects
check_and_set_variable "MYSQL_CONTAINER" "mysql"
check_and_set_variable "MISP_CONTAINER" "app"
check_and_set_variable "REDIS_CONTAINER" "redis"
check_resource_exists "container" "$MISP_CONTAINER"
check_resource_exists "container" "$MYSQL_CONTAINER"
check_resource_exists "container" "$REDIS_CONTAINER"


# Create storage pools
check_and_set_variable "DB_PARTITION" ""
check_and_set_variable "APP_PARTITION" ""
lxc storage create "$DB_STORAGE" zfs source="$DB_PARTITION"
lxc storage create "$APP_STORAGE" zfs source="$APP_PARTITION"

# Create network
lxc network create "$NETWORK_NAME" --type=bridge

# Create Profiles
check_and_set_variable "DB_PROFILE" "db-profile"
check_and_set_variable "APP_PROFILE" "app-profile"
lxc profile create "$DB_PROFILE"
lxc profile create "$APP_PROFILE"
lxc profile device add "$DB_PROFILE" root disk path=/ pool="$DB_STORAGE"
lxc profile device add "$APP_PROFILE" root disk path=/ pool="$APP_STORAGE"

# Import Images
check_and_set_variable "MISP_IMAGE" "./../build/images/misp.tar.gz"
check_and_set_variable "MYSQL_IMAGE" "./../build/images/mysql.tar.gz"
check_and_set_variable "REDIS_IMAGE" "./../build/images/redis.tar.gz"
lxc image import $MISP_IMAGE --alias misp
lxc image import $MYSQL_IMAGE --alias mysql
lxc image import $REDIS_IMAGE --alias redis

# Launch Container
lxc init misp $MISP_CONTAINER --profile=$APP_PROFILE 
lxc network attach $NETWORK_NAME $MISP_CONTAINER eth0 eth0
lxc start $MISP_CONTAINER
lxc init mysql $MYSQL_CONTAINER --profile=$DB_PROFILE
lxc network attach $NETWORK_NAME $MYSQL_CONTAINER eth0 eth0
lxc start $MYSQL_CONTAINER
lxc init redis $REDIS_CONTAINER --profile=$DB_PROFILE
lxc network attach $NETWORK_NAME $REDIS_CONTAINER eth0 eth0
lxc start $REDIS_CONTAINER

# Configure MISP
wait_for_container $MISP_CONTAINER
## Edit database conf
lxc exec $MISP_CONTAINER -- sed -i "s/'database' => 'misp'/'database' => '$MYSQL_DATABASE'/" /var/www/MISP/app/Config/database.php
lxc exec $MISP_CONTAINER -- sed -i "s/localhost/$MYSQL_CONTAINER.lxd/" /var/www/MISP/app/Config/database.php
lxc exec $MISP_CONTAINER -- sed -i "s/'login' => '.*'/'login' => '$MYSQL_USER'/" "/var/www/MISP/app/Config/database.php"
lxc exec $MISP_CONTAINER -- sed -i "s/8889/3306/" /var/www/MISP/app/Config/database.php
lxc exec $MISP_CONTAINER -- sed -i "s/'password' => '.*'/'password' => '$MYSQL_PASSWORD'/" "/var/www/MISP/app/Config/database.php"
## Edit redis host 
lxc exec $MISP_CONTAINER -- sed -i "s/'redis_host' => '.*',/'redis_host' => '$REDIS_CONTAINER',/" "/var/www/MISP/app/Config/config.php"

# Configure MySQL
wait_for_container $MYSQL_CONTAINER
check_and_set_variable "MYSQL_USER" "misp"
check_and_set_variable "MYSQL_PASSWORD" "misp"
check_and_set_variable "MYSQL_DATABASE" "misp"
## Add user + DB
lxc exec $MYSQL_CONTAINER -- mysql -u root -e "CREATE DATABASE $MYSQL_DATABASE;"
lxc exec $MYSQL_CONTAINER -- mysql -u root -e "GRANT ALL PRIVILEGES ON $MYSQL_DATABASE.* TO '$MYSQL_USER'@'$MISP_HOST' IDENTIFIED BY '$MYSQL_PASSWORD';"

## Configure remote access
lxc exec $MYSQL_CONTAINER -- sed -i 's/bind-address            = 127.0.0.1/bind-address            = 0.0.0.0/' "/etc/mysql/mariadb.conf.d/50-server.cnf"
lxc exec $MYSQL_CONTAINER -- sudo systemctl restart mysql

## Check connection + import schema
table_count=$(lxc exec $MISP_CONTAINER -- mysql -u $MYSQL_USER --password="$MYSQL_PASSWORD" -h $MYSQL_CONTAINER.lxd -P 3306 $MYSQL_DATABASE -e "SHOW TABLES;" | wc -l)
if [ $? -eq 0 ]; then
                echo "Connected to database successfully!"
                if [ $table_count -lt 73 ]; then
                    echo "Database misp is empty, importing tables from misp container ..."
                    lxc exec $MISP_CONTAINER -- bash -c "mysql -u $MYSQL_USER --password=$MYSQL_PASSWORD $MYSQL_DATABASE -h $MYSQL_CONTAINER.lxd -P 3306 2>&1 < /var/www/MISP/INSTALL/MYSQL.sql"
                else
                    echo "Database misp available"
                fi
else
    echo "ERROR:"
    echo $table_count
fi

## Update Database
lxc exec $MISP_CONTAINER -- bash -c 'sudo -u "www-data" -H sh -c "/var/www/MISP/app/Console/cake Admin runUpdates"'


# Configure Redis
wait_for_container $REDIS_CONTAINER
## Cofigure remote access
lxc exec $REDIS_CONTAINER -- sed -i "s/^bind .*/bind 0.0.0.0/" "/etc/redis/redis.conf"
lxc exec $REDIS_CONTAINER -- systemctl restart redis-server


echo "Setup finished!"

misp_ip=$(lxc list $MISP_CONTAINER --format=json | jq -r '.[0].state.network.eth0.addresses[] | select(.family=="inet").address')

echo "MISP is up and running on $misp_ip"
