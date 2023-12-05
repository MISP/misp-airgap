#!/bin/bash

# Script to build images using default names (misp, mysql, redis)
if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <output_path> <component_names>"
    echo "Available component names: misp, mysql, redis, modules"
    exit 1
fi

OUTPUTDIR=$1

for arg in "${@:2}"; do
    case "$arg" in
        "misp")
            echo "Building misp image..."
            ./build_misp.sh misp $OUTPUTDIR
            ;;
        "mysql")
            echo "Building mysql image..."
            ./build_mysql.sh mysql $OUTPUTDIR
            ;;
        "redis")
            echo "Building redis image..."
            ./build_redis.sh redis $OUTPUTDIR
            ;;
        "modules")
            echo "Building modules image..."
            ./build_redis.sh modules $OUTPUTDIR
            ;;
        *)
            echo "Unknown argument: $arg"
            ;;
    esac
done

