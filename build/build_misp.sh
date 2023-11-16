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

# Wait for the MISP container to be ready
sleep 10

# Execute commands inside the container to install MISP
lxc exec "$IMAGE" -- apt update

# Add MISP user
lxc exec "$IMAGE" -- useradd -m -s /bin/bash "misp"

if lxc exec "$IMAGE" -- id "misp" &>/dev/null; then
    # Add the user to the sudo group
    lxc exec "$IMAGE" -- usermod -aG sudo "misp"
    echo "User misp has been added to the sudoers group."
else
    echo "User misp does not exist."
    exit 1
fi

lxc exec "$IMAGE" -- bash -c "echo 'misp ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/misp"

# Install MISP
lxc exec "$IMAGE" -- su "misp" -c "wget --no-cache -O /tmp/INSTALL.sh https://raw.githubusercontent.com/MISP/MISP/2.4/INSTALL/INSTALL.sh"
lxc exec "$IMAGE" -- sudo -u "misp" -H sh -c "bash /tmp/INSTALL.sh -c"

# Create Image
lxc stop $IMAGE

lxc publish misp --alias misp
lxc image export misp $OUTPUTDIR

# Workaround for renaming image
cd $OUTPUTDIR && mv -i "$(ls -t | head -n1)" $IMAGE.tar.gz

# Cleanup
lxc delete $IMAGE
lxc image delete $IMAGE