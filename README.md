# MISP Air-Gapped <!-- omit in toc -->
MISP Air-Gapped is a project built on [MISP](https://github.com/MISP/MISP) and [LXD](https://ubuntu.com/lxd), designed to be used for air-gapped systems. For that LXD container images are created and compressed to `.tar` files so that they can be transferred to an air-gapped environment. The MISP installation in this project is based on the `INSTALL.sh` script available in the [MISP repository](https://github.com/MISP/MISP). 

## Table of Contents <!-- omit in toc -->
- [Requirements](#requirements)
- [Usage](#usage)
- [Update](#update)
- [Build](#build)


## Requirements

Before setting up your environment, ensure that you meet the following prerequisites:

- **Operating System:**
  - Ubuntu 22.04

- **Containerization:**
  - LXD 5.19

- **Additional Software:**
  - jq 1.6
  - yq 4.35.2


## Usage
First you have to [install LXD](https://ubuntu.com/lxd/install) on your air-gapped host system. Additionally you should install [jq](https://jqlang.github.io/jq/) and [yq](https://github.com/mikefarah/yq).

In order to be able to pull the images from an image server you should also install LXD on a networked system. 

After the install you can proceed with the followig steps:

<!-- 1. **Clone repo**:
   
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
    >**Note**: Renaming the exported `.tar` files with meaningful names can be helpful to keep track of their corresponding components. -->

1. **Pull Images**

   TODO

2. **Transfer images and repo to air-gapped system**:

   Transfer the exported images and the whole `deploy` directory to your air gapped system.

3. **Run install script**:
   
   On you host machine you can run the `install.sh` script:
   ```bash
   bash install.sh
   ```

   During the installation, set the necessary variables to configure the process:
   
   | Variable               | Default Value                                      | Description                                                                                                     |
   |------------------------|--------------------------------------------|-----------------------------------------------------------------------------------------------------------------|
   | `PROJECT_NAME`         | misp-project-<creation_time>                | Name of the LXD project used to organize and run the containers.                                                |
   | `MISP_IMAGE`           | ../build/images/misp.tar.gz                | The exported image file containing the configuration and setup of the MISP instance.                             |
   | `MISP_CONTAINER`       | misp-<creation_time>                        | The name of the container responsible for running the MISP application.                                          |
   | `MYSQL_IMAGE`          | ../build/images/mysql.tar.gz               | The exported image file of a MariaDB instance, containing the necessary configurations.                          |
   | `MYSQL_CONTAINER`      | mysql-<creation_time>                       | The name of the container running the MariaDB database for MISP.                                                 |
   | `MYSQL_DATABASE`       | misp                                       | The name of the database used by the MISP application.                                                           |
   | `MYSQL_USER`           | misp                                       | The database user for MISP to interact with the MariaDB database.                                                |
   | `MYSQL_PASSWORD`       | misp                                       | The password associated with the MISP database user.                                                             |
   | `MYSQL_ROOT_PASSWORD`  | misp                                       | The root user password for MariaDB.                                                                              |
   | `REDIS_IMAGE`          | ../build/images/redis.tar.gz               | The exported image file for the Redis instance, including necessary configurations.                              |
   | `REDIS_CONTAINER`      | redis-<creation_time>                       | The name of the container running the Redis server for MISP.                                                     |
   |  `MODULES`             | true                             | If set a container with MISP Modules gets set up.|
   |  `MODULES_IMAGE`        | ../build/images/modules.tar.gz                 | The exported image file of a MISP Modules instance, containing the necessary configurations. |
   |  `MODULES_CONTAINER`    | modules-<creation_time>                    | The name of the container running MISP Modules|
   | `APP_PARTITION`        |                                            | Dedicated partition for the sorage of the  MISP container                                                        |
   | `DB_PARTITION`         |                                            | Dedicated partition for the sorage of the  database container(s)                                                 |
   | `PROD`                 | false                                      | If set to true, the MISP application runs in production mode, activating the `islive` option and adjusting settings accordingly.|

   >**Note**: It is crucial to **modify all default credentials** when using this installation in a production environment. Specifically, if the PROD variable is set to true, the installer will not accept default values. Additionally, ensure that the paths to your image files align with the specifics of your individual setup.

After completing these steps, MISP should be up and running. Access the MISP web interface by navigating to the IP address displayed in the terminal after the installation process is finished. Alternatively, you can identify the IP addresses of all running containers within the project by executing the command `lxc list`. 

## Update
To update the system you have to pull a new misp image and export it as a  `.tar` file:
<!-- ```bash
lxc image copy <server>:misp local:
lxc image export misp .
``` -->
TODO

After that you have to transfer the file to your air-gapped system. On that system you can run `update.sh`:
```bash
bash update.sh <container-name> <path-to-new-image> [<new-container>]
```
<!-- >**Info**: The `update.sh` script will copy a bunch of config files from the old instance to the new updated one. However ... 

php.ini -->

## Build
Instead of pulling the images from a image server you can build them on your own by using the respective scripts in the `build` folder. 

To build all images simply run:
```bash
bash build_all.sh <output_path> misp mysql redis modules
```

This will build the images and export them to:
- misp_\<version\>_\<commit-id\>.tar.gz
- mysql.tar.gz
- redis.tar.gz
- modules_\<commit-id\>.tar.gz
