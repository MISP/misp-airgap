#!/bin/bash

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <image-name> <outputdir>"
    exit 1
fi

lxc launch ubuntu:20.04 mysql

# Wait for the container to start
sleep 10

# Install MySQL
lxc exec "mysql" -- apt update
lxc exec "mysql" -- apt install -y mariadb-server

# Create Image
lxc stop mysql
lxc publish mysql --alias mysql
lxc image export mysql $2

# Workaround for renaming image
cd $2 && mv -i "$(ls -t | head -n1)" $1.tar.gz

# Cleanup
lxc delete mysql
lxc image delete mysqls