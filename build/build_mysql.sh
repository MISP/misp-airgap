#!/bin/bash

setVars(){
    PROJECT_NAME=$(generateName "misp")
    CONTAINER=$(generateName "mysql")
    STORAGE_POOL_NAME=$(generateName "misp")
    NETWORK_NAME=$(generateName "net")
    NETWORK_NAME=${NETWORK_NAME:0:15}
    LXC_EXEC="lxc exec $CONTAINER"
}

setDefaultArgs(){
    default_image="mysql"
    default_outputdir="/opt/misp_airgap/images/"
}

generateName(){
    local name="$1"
    echo "${name}-$(date +%Y%m%d%H%M%S)"
}

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  -h, --help       Show this help message and exit."
    echo "  -n, --name       Specify the name of the image to create. Default is 'misp'."
    echo "  -o, --outputdir  Specify the output directory for the created image. Default is '/opt/misp_airgap/'."
}

cleanup(){
    cleanupProject "$PROJECT_NAME"
    lxc storage delete "$STORAGE_POOL_NAME"
    lxc network delete "$NETWORK_NAME"
}

get_distribution_version() {
    local input
    input=$(${LXC_EXEC} -- mysql --version) 
    local version

    version=$(echo "$input" | grep -oP 'Distrib \K[^,]+' || echo "Version not found")
    echo "$version"
}

cleanupProject(){
    local project="$1"

    echo "Starting cleanup ..."
    echo "Deleting container in project"
    for container in $(lxc query "/1.0/containers?recursion=1&project=${project}" | jq .[].name -r); do
        lxc delete --project "${project}" -f "${container}"
    done

    echo "Deleting images in project"
    for image in $(lxc query "/1.0/images?recursion=1&project=${project}" | jq .[].fingerprint -r); do
        lxc image delete --project "${project}" "${image}"
    done

    echo "Deleting project"
    lxc project delete "${project}"
}

# Main
setDefaultArgs

VALID_ARGS=$(getopt -o hn:o: --long help,name:,outputdir:  -- "$@")
if [[ $? -ne 0 ]]; then
    exit 1;
fi

eval set -- "$VALID_ARGS"
while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help)
            usage
            exit 0 
            ;;
        -n | --name)
            image=$2
            shift 2
            ;;
        -o | --outputdir)
            outputdir=$2
            shift 2
            ;;
        *)  
            break 
            ;;
    esac
done

IMAGE=${image:-$default_image}
OUTPUTDIR=${outputdir:-$default_outputdir}

if [ ! -e "$OUTPUTDIR" ]; then
    echo -e "${RED}Error${NC}: The specified directory does not exist."
    exit 1
fi

setVars

trap cleanup EXIT

lxc project create "$PROJECT_NAME"
lxc project switch "$PROJECT_NAME"
lxc storage create "$STORAGE_POOL_NAME" "dir"
lxc network create "$NETWORK_NAME"

lxc launch ubuntu:22.04 "$CONTAINER" -p default --storage "$STORAGE_POOL_NAME" --network "$NETWORK_NAME"

# Wait for the container to start
sleep 10

# Install $IMAGE
${LXC_EXEC} -- apt update
${LXC_EXEC} -- apt install -y mariadb-server

version=$(get_distribution_version)

# Create Image
lxc stop $CONTAINER
lxc publish $CONTAINER --alias $IMAGE
lxc image export $IMAGE $OUTPUTDIR

# Workaround for renaming image
cd $OUTPUTDIR && mv -i "$(ls -t | head -n1)" ${IMAGE}_${version}.tar.gz


