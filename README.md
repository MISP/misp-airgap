# MISP Air-Gapped
MISP Air-Gapped is a project that facilitates the deployment and maintenance of [MISP](https://github.com/MISP/MISP), in air-gapped environments. It utilizes [LXD](https://ubuntu.com/lxd), a popular Linux containerization platform, to create and manage isolated containers for MISP and its associated databases.

## Key Feautures
- Automated setup and configuration of MISP in a secure, isolated environment.
- Containerized approach using LXD for easy management and isolation.
- Support for both interactive and non-interactive installation modes.
- Comprehensive validation and security checks, ensuring secure deployment.
- Modular setup allowing for easy updates and maintenance.

## Requirements

Before setting up your environment, ensure that you meet the following prerequisites on your host system:

- **Operating System:**
  - Ubuntu 22.04
- **Containerization:**
  - LXD 5.19
- **Additional Software:**
  - jq 1.6
  - yq 4.35.2


## Installation
First, [install LXD](https://ubuntu.com/lxd/install) on your air-gapped host system. Additionally, install the [additional software](#requirements) needed.

After installation, proceed with the following steps:

1. **Pull Images**

   TODO

2. **Transfer images and repo to air-gapped system**:

   Transfer the exported images and the whole `deploy` directory to your air gapped system.

### Interactive Mode

Run the script with the `--interactive` flag to enter the interactive mode, which guides you through the configuration process:

```bash
bash install.sh --interactive
```

### Non-Interactive Mode
For a non-interactive setup, use command-line arguments to set configurations:

**Example:**
```bash
bash install.sh --misp-image <path-to-image> --mysql-image <path-to-image> --redis-image <path-to-image> --no-modules
```

Below is the table summarizing the script flags and variables:

| Variable              | Default Value                  | Flag                              | Description                                                                                                                      |
| --------------------- | ------------------------------ | --------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `INTERACTIVE_MODE`    | N/A                            | `-i`, `--interactive`             | Activates an interactive installation process.                                                                                   |
| `PROJECT_NAME`        | `misp-project-<creation_time>` | `--project <project_name>`        | Name of the LXD project used to organize and run the containers.                                                                 |
| `MISP_IMAGE`          | `<none>`                       | `--misp-image <image_file>`       | The exported image file containing the configuration and setup of the MISP instance.                                             |
| `MISP_CONTAINER`      | `misp-<creation_time>`         | `--misp-name <container_name>`    | The name of the container responsible for running the MISP application.                                                          |
| `MYSQL_IMAGE`         | `<none>`                       | `--mysql-image <image_file>`      | The exported image file of a MariaDB instance, containing the necessary configurations.                                          |
| `MYSQL_CONTAINER`     | `mysql-<creation_time>`        | `--mysql-name <container_name>`   | The name of the container running the MariaDB database for MISP.                                                                 |
| `MYSQL_DATABASE`      | `misp`                         | `--mysql-db <database_name>`      | The name of the database used by the MISP application.                                                                           |
| `MYSQL_USER`          | `misp`                         | `--mysql-user <user_name>`        | The database user for MISP to interact with the MariaDB database.                                                                |
| `MYSQL_PASSWORD`      | `misp`                         | `--mysql-pwd <password>`          | The password associated with the MISP database user.                                                                             |
| `MYSQL_ROOT_PASSWORD` | `misp`                         | `--mysql-root-pwd <password>`     | The root user password for MariaDB.                                                                                              |
| `REDIS_IMAGE`         | `<none>`                       | `--redis-image <image_file>`      | The exported image file for the Redis instance, including necessary configurations.                                              |
| `REDIS_CONTAINER`     | `redis-<creation_time>`        | `--redis-name <container_name>`   | The name of the container running the Redis server for MISP.                                                                     |
| `MODULES`             | `yes`                          | `--no-modules`                    | If set, a container with MISP Modules gets set up.                                                                               |
| `MODULES_IMAGE`       | `<none>`                       | `--modules-image <image_file>`    | The exported image file of a MISP Modules instance, containing the necessary configurations.                                     |
| `MODULES_CONTAINER`   | `modules-<creation_time>`      | `--modules-name <container_name>` | The name of the container running MISP Modules.                                                                                  |
| `APP_PARTITION`       | `<none>`                       | `--app-partition <partition>`     | Dedicated partition for the storage of the MISP container.                                                                       |
| `DB_PARTITION`        | `<none>`                       | `--db-partition <partition>`      | Dedicated partition for the storage of the database container(s).                                                                |
| `PROD`                | `no`                           | `-p`, `--production`              | If set to true, the MISP application runs in production mode, activating the `islive` option and adjusting settings accordingly. |


>**Note**: It is crucial to **modify all default credentials** when using this installation in a production environment. Specifically, if the PROD variable is set to true, the installer will not accept default values.

After completing these steps, MISP should be up and running. Access the MISP web interface by navigating to the IP address displayed in the terminal after the installation process is finished. Alternatively, you can identify the IP addresses of all running containers within the project by executing the command `lxc list`. 

## Update
1. **Pull Images**

   TODO

2. **Transfer images to air-gapped system**:

   Transfer the exported images to your air gapped system.

### Interactive Mode

Run the script with the `--interactive` flag to enter the interactive mode, which guides you through the configuration process:

```bash
bash update.sh --interactive
```

### Non-Interactive Mode
For a non-interactive setup, use command-line arguments to set configurations:

**Example:**
```bash
bash update_misp.sh --current-misp <current-misp-container> --update-misp -p <mysql-root-pwd> --misp-image <path-to-image>
```

Below is the table summarizing the script flags and variables:


| Variable              | Default Value             | Flag                        | Description                                          |
| --------------------- | ------------------------- | --------------------------- | ---------------------------------------------------- |
| `INTERACTIVE_MODE`    | N/A                       | `-i`, `--interactive`       | Activates an interactive installation process.       |
| `MYSQL_ROOT_PASSWORD` | User Input Required       | `-p`, `--passwd <password>` | Set the MySQL root password.                         |
| `MISP`                | `no`                      | `--update-misp`             | Update MISP container.                               |
| `MISP_IMAGE`          | `<none>`                  | `--misp-image <image>`      | Specify the MISP image.                              |
| `CURRENT_MISP`        | `<none>`                  | `--current-misp <name>`     | Specify the current MISP container name (Mandatory). |
| `NEW_MISP`            | `misp-<creation_time>`    | `--new-misp <name>`         | Specify the new MISP container name.                 |
| Multiple              | N/A                       | `-a`, `--all`               | Apply updates to all components.                     |
| `MYSQL`               | `no`                      | `--update-mysql`            | Update MySQL container.                              |
| `MYSQL_IMAGE`         | `<none>`                  | `--mysql-image <image>`     | Specify the MySQL image.                             |
| `NEW_MYSQL`           | `mysql-<creation_time>`   | `--new-mysql <name>`        | Specify the new MySQL container name.                |
| `REDIS`               | `no`                      | `--update-redis`            | Update Redis container.                              |
| `REDIS_IMAGE`         | `<none>`                  | `--redis-image <image>`     | Specify the Redis image.                             |
| `NEW_REDIS`           | `redis-<creation_time>`   | `--new-redis <name>`        | Specify the new Redis container name.                |
| `MODULES`             | `no`                      | `--update-modules`          | Update modules container.                            |
| `MODULES_IMAGE`       | `<none>`                  | `--modules-image <image>`   | Specify the modules image.                           |
| `NEW_MODULES`         | `modules-<creation_time>` | `--new-modules <name>`      | Specify the new modules container name.              |


