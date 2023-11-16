#!/bin/bash

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <image-name> <outputdir>"
    exit 1
fi

IMAGE=$1
OUTPUTDIR=$2

lxc info "$IMAGE" &>/dev/null

if [ $? -eq 0 ]; then
    echo "Container '$IMAGE' exists."
    exit 1
fi 

lxc launch ubuntu:20.04 $IMAGE

# Wait for the container to start
sleep 10

lxc exec "$IMAGE" -- sudo apt-get update
lxc exec "$IMAGE" -- sudo apt-get install redis-server -y

# Create Image
lxc stop $IMAGE
lxc publish $IMAGE --alias $IMAGE
lxc image export $IMAGE $2

# Workaround for renaming image
cd $2 && mv -i "$(ls -t | head -n1)" $1.tar.gz

# Cleanup
lxc delete $IMAGE
lxc image delete $IMAGE
