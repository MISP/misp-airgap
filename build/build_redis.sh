#!/bin/bash

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <image-name> <outputdir>"
    exit 1
fi

lxc launch ubuntu:20.04 redis

# Wait for the container to start
sleep 10

lxc exec "redis" -- sudo apt-get update
lxc exec "redis" -- sudo apt-get install redis-server -y

# Create Image
lxc stop redis
lxc publish redis --alias redis
lxc image export redis $2

# Workaround for renaming image
cd $2 && mv -i "$(ls -t | head -n1)" $1.tar.gz

# Cleanup
lxc delete misp
lxc image delete redis