# MISP Air-Gapped <!-- omit in toc -->
MISP Air-Gapped is a project built on the [MISP](https://github.com/MISP/MISP) and [LXD](https://ubuntu.com/lxd), designed to be used for air-gapped systems. The MISP installation in this project is based on the `INSTALL.sh` script in the [MISP repository](https://github.com/MISP/MISP).

## Table of Contents <!-- omit in toc -->
- [Requirements](#requirements)
- [Usage](#usage)
- [Update](#update)
- [Rollback](#rollback)
- [Build](#build)


## Requirements
- Ubuntu:20.04 (tested)
- LXD 5.19 (tested)
- jq-1.6


## Usage
First you have to [install LXD](https://ubuntu.com/lxd/install) on your air-gapped host system. After that run the following command to configure LXD:
```bash
lxd init
```
>**Note**: You can use default configs

In order to be able to pull the images from an image server you should also install LXD on a networked system. 

After the install you can proceed with the followig steps:

1. **Clone repo**:
   
   On a networked system:
   ```bash
   git clone https://github.com/MISP/misp-airgap
   ```
2. **Pull LXD images**:

    On a networked system:
    ```bash
    lxc remote add <server>
    lxc image copy <server>:misp local:
    lxc image copy <server>:mysql local:
    lxc image copy <server>:redis local:
    ```
3. **Export images**:

    After pulling the images from the remote server you can export them into `.tar` files:
    ```bash
    lxc image export misp .
    lxc image export mysql .
    lxc image export redis .
    ```
    >**Note**: Rename the exported `.tar` files immediately with meaningful names to keep track of their corresponding components.

5. **Transfer images and repo to air-gapped system**:

   Transfer the exported images and the whole `deploy` directory to your air gapped system.

6. **Configure .env file**:
   
   You can use the `template.env` file to create a `.env` file:
   ```
   cp template.env .env
   ```
   After that you can modify the `.env` depending on your needs.
   >**Note**: We strongly recommend changing credentials in the `.env` file.

7. **Run install script**:
   
   On you host machine you can run the `install.sh` script:
   ```bash
   bash install.sh
   ```

After completing these steps, MISP should be up and running. Confirm this by running `lxc list` and accessing the web interface using the IP of the MISP container.


## Update
To update the system you have to pull a new misp image and export it as a  `.tar` file:
```bash
lxc image copy <server>:misp local:
lxc image export misp .
```
After that you have to transfer the file to your air-gapped system. On your system adjust the path of the `MISP_IMAGE` to the new `.tar` file and run `update.sh`:
```bash
bash update.sh <backup-name>
```
>**Info**: The `update.sh` script will stop the current instance, renaming it using the `backup-name` argument. The old instance remains on the system for potential reversion. Configuration files and logs will be copied to the new instance.


## Rollback
To roll back to a previous state you can use the `rollback.sh` file. 
```bash
bash rollback.sh <backup-container>
```
This script will **delete** the current instance and roll back to the specifed Backup instance.
>**Warning**: All changes made after th state of the backup machine will be lost!


## Build
Instead of pulling the images from a image server you can build them on your own by using the respective scripts in the `build` folder. 

To build all images simply run:
```bash
bash build_all.sh <output_path> misp mysql redis
```

This will build the images and export them to:
- misp.tar.gz
- mysql.tar.gz
- redis.tar.gz

