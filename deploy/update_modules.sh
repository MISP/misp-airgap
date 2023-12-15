#!/bin/bash
# Color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
VIOLET='\033[0;35m'
NC='\033[0m' # No Color

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

checkModules(){
    if [ "$(${LXC_EXEC} systemctl is-active misp-modules)" = "active" ]; then
        okay "Service misp-modules is running."
    else
        error "Service misp-modules is not running."
        lxc stop "$NEW_MISP"
        exit 1
    fi
}

cleanup(){
    lxc image delete "$MODULES_IMAGE_NAME"
}

# Main
default_misp=""
default_new_modules=$(generateName "modules")
default_current_modules=""
default_modules_img=""

VALID_ARGS=$(getopt -o c:n:ap: --long misp:,current:,image:,new:  -- "$@")
if [[ $? -ne 0 ]]; then
    exit 1;
fi

eval set -- "$VALID_ARGS"
while [ $# -gt 0 ]; do
    case "$1" in
        -m | --misp)
            misp=$2
            shift 2
            ;;
        -i | --image)
            modules_img=$2
            shift 2
            ;;
        -c | --current)
            current_modules=$2
            shift 2
            ;;
        -n | --new)
            new_modules=$2
            shift 2
            ;;
        *)  
            break 
            ;;
    esac
done

# Set global values
MISP=${misp:-$default_misp}
NEW_MODULES=${new_modules:-$default_new_modules}
CURRENT_MODULES=${current_modules:-$default_current_modules}
MODULES_IMAGE=${modules_img:-$default_modules_img}

WWW_USER="www-data"
SUDO_WWW="sudo -H -u ${WWW_USER} "
PATH_TO_MISP="/var/www/MISP"
CAKE="${PATH_TO_MISP}/app/Console/cake"
LXC_MISP="lxc exec ${MISP}"

# start new
MODULES_IMAGE_NAME=$(generateName "modules")
lxc image import $MODULES_IMAGE --alias $MODULES_IMAGE_NAME
lxc launch $MODULES_IMAGE_NAME $NEW_MODULES
checkModules

# configure misp
${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Export_services_url" "$NEW_MODULES.lxd"
${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Import_services_url" "$NEW_MODULES.lxd"
${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Enrichment_services_url" "$NEW_MODULES.lxd"

# stop old
lxc stop $CURRENT_MODULES

cleanup
