#!/bin/bash

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
VIOLET='\033[0;35m'
NC='\033[0m' # No Color

setVars(){
    WWW_USER="www-data"
    SUDO_WWW="sudo -H -u ${WWW_USER} "
    PATH_TO_MISP="/var/www/MISP"
    CAKE="${PATH_TO_MISP}/app/Console/cake"
    MISP_BASEURL="${MISP_BASEURL:-""}"
    LXC_MISP="lxc exec ${MISP_CONTAINER}"
    LXC_MISP="lxc exec ${MISP_CONTAINER}"
    LXC_REDIS="lxc exec ${REDIS_CONTAINER}"
    LXC_MYSQL="lxc exec ${MYSQL_CONTAINER}"
    REDIS_CONTAINER_PORT="6380"
}

info () {
    local step=$1
    local msg=$2
    echo -e "${BLUE}Step $step:${NC} ${GREEN}$msg${NC}" > /dev/tty
}

error() {
    local msg=$1
    echo -e "${RED}Error: $msg${NC}" > /dev/tty
}

warn() {
    local msg=$1
    echo -e "${YELLOW}Warning: $msg${NC}" > /dev/tty
}

coreCAKE () {
    # IF you have logged in prior to running this, it will fail but the fail is NON-blocking
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} userInit -q

    # This makes sure all Database upgrades are done, without logging in.
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin runUpdates

    # The default install is Python >=3.6 in a virtualenv, setting accordingly
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.python_bin" "${PATH_TO_MISP}/venv/bin/python"

    # Tune global time outs
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Session.autoRegenerate" 0
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Session.timeout" 600
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Session.cookieTimeout" 3600
    
    # Set the default temp dir
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.tmpdir" "${PATH_TO_MISP}/app/tmp"

    # Change base url, either with this CLI command or in the UI
    [[ ! -z ${MISP_BASEURL} ]] && ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Baseurl $MISP_BASEURL
    # example: 'baseurl' => 'https://<your.FQDN.here>',
    # alternatively, you can leave this field empty if you would like to use relative pathing in MISP
    # 'baseurl' => '',
    # The base url of the application (in the format https://www.mymispinstance.com) as visible externally/by other MISPs.
    # MISP will encode this URL in sharing groups when including itself. If this value is not set, the baseurl is used as a fallback.
    [[ ! -z ${MISP_BASEURL} ]] && ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.external_baseurl" ${MISP_BASEURL}

    # Enable GnuPG
    echo $GPG_EMAIL_ADDRESSS
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "GnuPG.email" "${GPG_EMAIL_ADDRESS}" # Error
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "GnuPG.homedir" "${PATH_TO_MISP}/.gnupg"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "GnuPG.password" "${GPG_PASSPHRASE}"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "GnuPG.obscure_subject" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "GnuPG.key_fetching_disabled" false
    # FIXME: what if we have not gpg binary but a gpg2 one?
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "GnuPG.binary" "$(which gpg)"

    # LinOTP
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "LinOTPAuth.enabled" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "LinOTPAuth.baseUrl" "https://<your-linotp-baseUrl>"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "LinOTPAuth.realm" "lino"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "LinOTPAuth.verifyssl" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "LinOTPAuth.mixedauth" false

    # Enable installer org and tune some configurables
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.host_org_id" 1
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.email" "info@admin.test"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.disable_emailing" true --force
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.contact" "info@admin.test"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.disablerestalert" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.showCorrelationsOnIndex" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.default_event_tag_collection" 0

    # Provisional Cortex tunes
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Cortex_services_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Cortex_services_url" "http://127.0.0.1"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Cortex_services_port" 9000
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Cortex_timeout" 120
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Cortex_authkey" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Cortex_ssl_verify_peer" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Cortex_ssl_verify_host" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Cortex_ssl_allow_self_signed" true

    # Various plugin sightings settings
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Sightings_policy" 0
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Sightings_anonymise" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Sightings_anonymise_as" 1
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Sightings_range" 365
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Sightings_sighting_db_enable" false

    # TODO: Fix the below list
    # Set API_Required modules to false
    PLUGS=(Plugin.ElasticSearch_logging_enable
            Plugin.S3_enable)
    for PLUG in "${PLUGS[@]}"; do
        ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting ${PLUG} false 2> /dev/null
    done

    # Plugin CustomAuth tuneable
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.CustomAuth_disable_logout" false

    # RPZ Plugin settings
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.RPZ_policy" "DROP"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.RPZ_walled_garden" "127.0.0.1"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.RPZ_serial" "\$date00"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.RPZ_refresh" "2h"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.RPZ_retry" "30m"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.RPZ_expiry" "30d"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.RPZ_minimum_ttl" "1h"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.RPZ_ttl" "1w"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.RPZ_ns" "localhost."
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.RPZ_ns_alt" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.RPZ_email" "root.localhost"

    # Kafka settings
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_brokers" "kafka:9092"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_rdkafka_config" "/etc/rdkafka.ini"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_include_attachments" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_event_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_event_notifications_topic" "misp_event"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_event_publish_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_event_publish_notifications_topic" "misp_event_publish"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_object_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_object_notifications_topic" "misp_object"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_object_reference_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_object_reference_notifications_topic" "misp_object_reference"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_attribute_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_attribute_notifications_topic" "misp_attribute"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_shadow_attribute_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_shadow_attribute_notifications_topic" "misp_shadow_attribute"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_tag_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_tag_notifications_topic" "misp_tag"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_sighting_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_sighting_notifications_topic" "misp_sighting"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_user_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_user_notifications_topic" "misp_user"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_organisation_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_organisation_notifications_topic" "misp_organisation"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_audit_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Kafka_audit_notifications_topic" "misp_audit"

    # ZeroMQ settings
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_host" "127.0.0.1"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_port" 50000
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_redis_host" "$REDIS_CONTAINER.lxd"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_redis_port" $REDIS_CONTAINER_PORT
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_redis_database" 1
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_redis_namespace" "mispq"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_event_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_object_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_object_reference_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_attribute_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_sighting_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_user_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_organisation_notifications_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_include_attachments" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_tag_notifications_enable" false

    # Force defaults to make MISP Server Settings less RED
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.language" "eng"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.proposals_block_attributes" false

  # Redis block
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.redis_host" "$REDIS_CONTAINER.lxd"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.redis_port" $REDIS_CONTAINER_PORT 
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.redis_database" 13
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.redis_password" ""

    # Force defaults to make MISP Server Settings less YELLOW
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.ssdeep_correlation_threshold" 40
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.extended_alert_subject" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.default_event_threat_level" 4
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.newUserText" "Dear new MISP user,\\n\\nWe would hereby like to welcome you to the \$org MISP community.\\n\\n Use the credentials below to log into MISP at \$misp, where you will be prompted to manually change your password to something of your own choice.\\n\\nUsername: \$username\\nPassword: \$password\\n\\nIf you have any questions, don't hesitate to contact us at: \$contact.\\n\\nBest regards,\\nYour \$org MISP support team"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.passwordResetText" "Dear MISP user,\\n\\nA password reset has been triggered for your account. Use the below provided temporary password to log into MISP at \$misp, where you will be prompted to manually change your password to something of your own choice.\\n\\nUsername: \$username\\nYour temporary password: \$password\\n\\nIf you have any questions, don't hesitate to contact us at: \$contact.\\n\\nBest regards,\\nYour \$org MISP support team"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.enableEventBlocklisting" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.enableOrgBlocklisting" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.log_client_ip" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.log_auth" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.log_user_ips" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.log_user_ips_authkeys" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.disableUserSelfManagement" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.disable_user_login_change" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.disable_user_password_change" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.disable_user_add" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.block_event_alert" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.block_event_alert_tag" "no-alerts=\"true\""
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.block_old_event_alert" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.block_old_event_alert_age" ""
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.block_old_event_alert_by_date" ""
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.event_alert_republish_ban" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.event_alert_republish_ban_threshold" 5
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.event_alert_republish_ban_refresh_on_retry" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.incoming_tags_disabled_by_default" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.maintenance_message" "Great things are happening! MISP is undergoing maintenance, but will return shortly. You can contact the administration at \$email."
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.footermidleft" "This is an initial install"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.footermidright" "Please configure and harden accordingly"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.welcome_text_top" "Initial Install, please configure"
    # TODO: Make sure $FLAVOUR is correct
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.welcome_text_bottom" "Welcome to MISP on ${FLAVOUR}, change this message in MISP Settings"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.attachments_dir" "${PATH_TO_MISP}/app/files"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.download_attachments_on_load" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.event_alert_metadata_only" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.title_text" "MISP"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.terms_download" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.showorgalternate" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.event_view_filter_fields" "id, uuid, value, comment, type, category, Tag.name"

    # Force defaults to make MISP Server Settings less GREEN
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "debug" 0
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Security.auth_enforced" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Security.log_each_individual_auth_fail" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Security.rest_client_baseurl" ""
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Security.advanced_authkeys" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Security.password_policy_length" 12
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Security.password_policy_complexity" '/^((?=.*\d)|(?=.*\W+))(?![\n])(?=.*[A-Z])(?=.*[a-z]).*$|.{16,}/'

    # Appease the security audit, #hardening
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Security.disable_browser_cache" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Security.check_sec_fetch_site_header" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Security.csp_enforce" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Security.advanced_authkeys" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Security.do_not_log_authkeys" true

    # Appease the security audit, #loggin
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Security.username_in_response_header" true

}

updateGOWNT () {
    # Update the galaxies…
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin updateGalaxies
    # Updating the taxonomies…
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin updateTaxonomies
    # Updating the warning lists…
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin updateWarningLists
    # Updating the notice lists…
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin updateNoticeLists
    # Updating the object templates…
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin updateObjectTemplates "1337"
}

setupGnuPG() {

    GPG_REAL_NAME="Autogenerated Key"
    GPG_COMMENT="WARNING: MISP AutoGenerated Key consider this Key VOID!"
    GPG_EMAIL_ADDRESS="admin@admin.test"
    GPG_KEY_LENGTH="3072"
    GPG_PASSPHRASE="$(openssl rand -hex 32)"

    # Check if the .gnupg directory exists on the LXD container
    ${LXC_MISP} -- sudo -u www-data -H sh -c "[ -d $MISP_PATH/MISP/.gnupg ]" && {
        echo "Existing key found on the container. Deleting..."
        ${LXC_MISP} -- sudo -u www-data -H sh -c "rm -rf $MISP_PATH/MISP/.gnupg"
        echo "Existing key deleted"
    }

    # The email address should match the one set in the config.php
    # set in the configuration menu in the administration menu configuration file
    ${LXC_MISP} -- sudo -u www-data -H sh -c "echo \"%echo Generating a default key
        Key-Type: default
        Key-Length: $GPG_KEY_LENGTH
        Subkey-Type: default
        Name-Real: $GPG_REAL_NAME
        Name-Comment: $GPG_COMMENT
        Name-Email: $GPG_EMAIL_ADDRESS
        Expire-Date: 0
        Passphrase: $GPG_PASSPHRASE
        # Do a commit here, so that we can later print \"done\"
        %commit
    %echo done\" > /tmp/gen-key-script"

    ${LXC_MISP} -- sudo -u www-data -H sh -c "gpg --homedir $MISP_PATH/MISP/.gnupg --batch --gen-key /tmp/gen-key-script"

    # Export the public key to the webroot
    ${LXC_MISP} -- sudo -u www-data -H sh -c "gpg --homedir $MISP_PATH/MISP/.gnupg --export --armor $GPG_EMAIL_ADDRESS | tee $MISP_PATH/MISP/app/webroot/gpg.asc"
    ${LXC_MISP} -- rm /tmp/gen-key-script
}

checkRessourceExist() {
    local resource_type="$1"
    local resource_name="$2"

    case "$resource_type" in
        "container")
            lxc info "$resource_name" &>/dev/null
            ;;
        "image")
            lxc image list --format=json | jq -e --arg alias "$resource_name" '.[] | select(.aliases[].name == $alias) | .fingerprint' &>/dev/null
            ;;
        "project")
            lxc project list --format=json | jq -e --arg name "$resource_name" '.[] | select(.name == $name) | .name' &>/dev/null
            ;;
        "storage")
            lxc storage list --format=json | jq -e --arg name "$resource_name" '.[] | select(.name == $name) | .name' &>/dev/null
            ;;
        "network")
            lxc network list --format=json | jq -e --arg name "$resource_name" '.[] | select(.name == $name) | .name' &>/dev/null
            ;;
        "profile")
            lxc profile list --format=json | jq -e --arg name "$resource_name" '.[] | select(.name == $name) | .name' &>/dev/null
            ;;
    esac

    return $?
}

checkForDefaultValue(){
    echo "TODO"
}

waitForContainer() {
    local container_name="$1"

    while true; do
        status=$(lxc list --format=json | jq -e --arg name "$container_name"  '.[] | select(.name == $name) | .status')
        if [ $status = "\"Running\"" ]; then
            echo -e "${BLUE}$container_name ${GREEN}is running.${NC}"
            break
        fi
        echo "Waiting for $container_name container to start."
        sleep 5
    done
}

generateName(){
    local name="$1"
    echo "${name}-$(date +%Y-%m-%d-%H-%M-%S)"
}

checkSoftwareDependencies() {
    local dependencies=("jq")

    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo -e "${RED}Error: $dep is not installed.${NC}"
            exit 1
        fi
    done
}

getIntallationConfig(){
    # Installer output
    echo
    echo "################################################################################"
    echo -e "# Welcome to the ${BLUE}MISP-airgap${NC} Installer Script                                  #"
    echo "#------------------------------------------------------------------------------#"
    echo -e "# This installer script will guide you through the installation process of     #"
    echo -e "# ${BLUE}MISP${NC} using LXD.                                                              #"
    echo -e "#                                                                              #"
    echo -e "# ${VIOLET}Please note:${NC}                                                                 #"
    echo -e "# ${VIOLET}Default values provided below are for demonstration purposes only and should${NC} #"
    echo -e "# ${VIOLET}be changed in a production environment.${NC}                                      #"
    echo -e "#                                                                              #"
    echo "################################################################################"
    echo

    # set default values
    MISP_PATH="/var/www/"
    default_confirm="no"
    default_prod="no"
    default_misp_project=$(generateName "misp-project")

    default_misp_img="../build/images/misp.tar.gz"
    default_misp_name=$(generateName "misp")

#    default_mysql="yes"
    default_mysql_img="../build/images/mysql.tar.gz"
    default_mysql_name=$(generateName "mysql")
    default_mysql_user="misp"
    default_mysql_pwd="misp"
    default_mysql_db="misp"
    default_mysql_root_pwd="misp"

#    default_redis="yes"
    default_redis_img="../build/images/redis.tar.gz"
    default_redis_name=$(generateName "redis")

    default_modules="yes"
    default_modules_img="../build/images/modules.tar.gz"
    default_modules_name=$(generateName "modules")

    default_app_partition=""
    default_db_partition=""

    # Ask for LXD project name
    read -p "Name of the misp project (default: $default_misp_project): " misp_project
    PROJECT_NAME=${misp_project:-$default_misp_project}
    if checkRessourceExist "project" "$PROJECT_NAME"; then
        error "Project '$PROJECT_NAME' already exists."
        exit 1
    fi

    # Ask for misp image 
    read -e -p "What is the path to the misp image (default: $default_misp_img): " misp_img
    misp_img=${misp_img:-$default_misp_img}
    if [ ! -f "$misp_img" ]; then
        error "The specified file does not exist."
        exit 1
    fi
    MISP_IMAGE=$misp_img
    # Ask for name
    read -p "Name of the misp container (default: $default_misp_name): " misp_name
    MISP_CONTAINER=${misp_name:-$default_misp_name}
    if checkRessourceExist "container" "$MISP_CONTAINER"; then
        error "Container '$MISP_CONTAINER' already exists."
        exit 1
    fi

    # Ask for mysql installation
    # read -p "Do you want to install a mysql instance (y/n, default: $default_mysql): " mysql
    # mysql=${mysql:-$default_mysql}
    # mysql=$(echo "$mysql" | grep -iE '^y(es)?$' > /dev/null && echo true || echo false)
    # if $mysql; then
    # Ask for image
    read -e -p "What is the path to the MySQL image (default: $default_mysql_img): " mysql_img
    mysql_img=${mysql_img:-$default_mysql_img}
    if [ ! -f "$mysql_img" ]; then
        error "The specified file does not exist."
        exit 1
    fi
    MYSQL_IMAGE=$mysql_img
    # Ask for name
    read -p "Name of the MySQL container (default: $default_mysql_name): " mysql_name
    MYSQL_CONTAINER=${mysql_name:-$default_mysql_name}
    if checkRessourceExist "container" "$MYSQL_CONTAINER"; then
    error "Container '$MYSQL_CONTAINER' already exists."
    exit 1
    fi
    # Ask for credentials
    read -p "MySQL Database (default: $default_mysql_db): " mysql_db
    MYSQL_DATABASE=${mysql_db:-$default_mysql_db}
    read -p "MySQL User (default: $default_mysql_user): " mysql_user
    MYSQL_USER=${mysql_user:-$default_mysql_user}
    read -p "MySQL User Password (default: $default_mysql_pwd): " mysql_pwd
    MYSQL_PASSWORD=${mysql_pwd:-$default_mysql_pwd}
    read -p "MySQL Root Password (default: $default_mysql_root_pwd): " mysql_root_pwd
    MYSQL_ROOT_PASSWORD=${mysql_root_pwd:-$default_mysql_root_pwd}
    # fi

    # Ask for redis installation 
    # read -p "Do you want to install a Redis instance (y/n, default: $default_redis): " redis
    # redis=${redis:-$default_redis}
    # redis=$(echo "$redis" | grep -iE '^y(es)?$' > /dev/null && echo true || echo false)
    # if $redis; then
    # Ask for image
    read -e -p "What is the path to the Redis image (default: $default_redis_img): " redis_img
    redis_img=${redis_img:-$default_redis_img}
    if [ ! -f "$redis_img" ]; then
        error "The specified file does not exist."
        exit 1
    fi
    REDIS_IMAGE=$redis_img
    # Ask for name
    read -p "Name of the Redis container (default: $default_redis_name): " redis_name
    REDIS_CONTAINER=${redis_name:-$default_redis_name}
    if checkRessourceExist "container" "$REDIS_CONTAINER"; then
        error "Container '$REDIS_CONTAINER' already exists."
        exit 1
    fi
    # fi

    # Ask for modules installation
    read -p "Do you want to install MISP Modules (y/n, default: $default_modules): " modules
    modules=${modules:-$default_modules}
    modules=$(echo "$modules" | grep -iE '^y(es)?$' > /dev/null && echo true || echo false)
    if $modules; then
        # Ask for image
        read -e -p "What is the path to the Modules image (default: $default_modules_img): " modules_img
        modules_img=${modules_img:-$default_modules_img}
        if [ ! -f "$modules_img" ]; then
            error "The specified file does not exist."
            exit 1
        fi
        MODULES_IMAGE=$modules_img
        # Ask for name
        read -p "Name of the Modules container (default: $default_modules_name): " modules_name
        MODULES_CONTAINER=${modules_name:-$default_modules_name}
        if checkRessourceExist "container" "$MODULES_CONTAINER"; then
            error "Container '$MODULES_CONTAINER' already exists."
            exit 1
        fi

    fi

    # Ask for dedicated partitions
    read -p "Dedicated partition for MISP container (leave blank if none): " app_partition
    APP_PARTITION=${app_partition:-$default_app_partition}
    # if $mysql || $redis; then
    read -p "Dedicated partition for DB container (leave blank if none): " db_partition
    DB_PARTITION=${db_partition:-$default_db_partition}
    # fi

    # Ask if used in prod
    read -p "Do you want to use this setup in production (y/n, default: $default_prod): " prod
    prod=${prod:-$default_prod} 
    PROD=$(echo "$prod" | grep -iE '^y(es)?$' > /dev/null && echo true || echo false)

    # Output values set by the user
    echo -e "\nValues set:"
    echo "--------------------------------------------------------------------------------------------------------------------"
    echo -e "PROJECT_NAME: ${GREEN}$PROJECT_NAME${NC}"
    echo "--------------------------------------------------------------------------------------------------------------------"
    echo -e "${BLUE}MISP:${NC}"
    echo -e "MISP_IMAGE: ${GREEN}$MISP_IMAGE${NC}"
    echo -e "MISP_CONTAINER: ${GREEN}$MISP_CONTAINER${NC}"
    #echo -e "MYSQL: ${GREEN}$mysql${NC}"
    # if $mysql; then
    echo "--------------------------------------------------------------------------------------------------------------------"
    echo -e "${BLUE}MySQL:${NC}"
    echo -e "MYSQL_IMAGE: ${GREEN}$MYSQL_IMAGE${NC}"
    echo -e "MYSQL_CONTAINER: ${GREEN}$MYSQL_CONTAINER${NC}"
    echo -e "MYSQL_DATABASE: ${GREEN}$MYSQL_DATABASE${NC}"
    echo -e "MYSQL_USER: ${GREEN}$MYSQL_USER${NC}"
    echo -e "MYSQL_PASSWORD: ${GREEN}$MYSQL_PASSWORD${NC}"
    echo -e "MYSQL_ROOT_PASSWORD: ${GREEN}$MYSQL_ROOT_PASSWORD${NC}"
    # fi
    #echo -e "REDIS: ${GREEN}$redis${NC}"
    # if $redis; then
    echo "--------------------------------------------------------------------------------------------------------------------"
    echo -e "${BLUE}Redis:${NC}"
    echo -e "REDIS_IMAGE: ${GREEN}$REDIS_IMAGE${NC}"
    echo -e "REDIS_CONTAINER: ${GREEN}$REDIS_CONTAINER${NC}"
    # fi
    echo "--------------------------------------------------------------------------------------------------------------------"
    echo -e "${BLUE}MISP Modules:${NC}"
    echo -e "MISP Modules: ${GREEN}$modules${NC}"
    if $modules; then
        echo -e "MODULES_IMAGE: ${GREEN}$MODULES_IMAGE${NC}"
        echo -e "MODULES_CONTAINER: ${GREEN}$MODULES_CONTAINER${NC}"
    fi
    echo "--------------------------------------------------------------------------------------------------------------------"
    echo -e "${BLUE}Storage:${NC}"
    echo -e "APP_PARTITION: ${GREEN}$APP_PARTITION${NC}"
    # if $mysql || $redis; then
    echo -e "DB_PARTITION: ${GREEN}$DB_PARTITION${NC}"
    # fi
    echo "--------------------------------------------------------------------------------------------------------------------"
    echo -e "${BLUE}Security:${NC}"
    echo -e "PROD: ${GREEN}$PROD${NC}\n"
    echo "--------------------------------------------------------------------------------------------------------------------"

    # Ask for confirmation
    read -p "Do you want to proceed with the installation? (y/n): " confirm
    confirm=${confirm:-$default_confirm}
    if [[ $confirm != "y" ]]; then
    echo "Installation aborted."
    exit 1
    fi

}


setupLXD(){
    # Create Project 
    lxc project create "$PROJECT_NAME"
    lxc project switch "$PROJECT_NAME"

    # Create storage pools
    APP_STORAGE=$(generateName "app-storage")
    if checkRessourceExist "storage" "$APP_STORAGE"; then
        error "Storage '$APP_STORAGE' already exists."
        exit 1
    fi
    lxc storage create "$APP_STORAGE" zfs source="$APP_PARTITION"

    DB_STORAGE=$(generateName "db-storage")
    if checkRessourceExist "storage" "$DB_STORAGE"; then
        error "Storage '$DB_STORAGE' already exists."
        exit 1
    fi
    lxc storage create "$DB_STORAGE" zfs source="$DB_PARTITION"

    # Create Network
    NETWORK_NAME=$(generateName "net")
    # max len of 15 
    NETWORK_NAME=${NETWORK_NAME:0:15}
    if checkRessourceExist "network" "$NETWORK_NAME"; then
        error "Network '$NETWORK_NAME' already exists."
    fi
    lxc network create "$NETWORK_NAME" --type=bridge

    # Create Profiles
    APP_PROFILE=$(generateName "app")
    if checkRessourceExist "profile" "$APP_PROFILE"; then
        error "Profile '$APP_PROFILE' already exists."
    fi
    lxc profile create "$APP_PROFILE"
    lxc profile device add "$APP_PROFILE" root disk path=/ pool="$APP_STORAGE"
    lxc profile device add "$APP_PROFILE" eth0 nic name=eth0 network="$NETWORK_NAME"

    
    DB_PROFILE=$(generateName "db")
    echo "db-profile: $DB_PROFILE"
    if checkRessourceExist "profile" "$DB_PROFILE"; then
        error "Profile '$DB_PROFILE' already exists."
    fi
    lxc profile create "$DB_PROFILE"
    lxc profile device add "$DB_PROFILE" root disk path=/ pool="$DB_STORAGE"
    lxc profile device add "$DB_PROFILE" eth0 nic name=eth0 network="$NETWORK_NAME"   
}

importImages(){
    # Import Images
    MISP_IMAGE_NAME=$(generateName "misp")
    echo "image: $MISP_IMAGE_NAME"
    if checkRessourceExist "image" "$MISP_IMAGE_NAME"; then
        error "Image '$MISP_IMAGE_NAME' already exists."
    fi
    lxc image import $MISP_IMAGE --alias $MISP_IMAGE_NAME

    MYSQL_IMAGE_NAME=$(generateName "mysql")
    if checkRessourceExist "image" "$MYSQL_IMAGE_NAME"; then
        error "Image '$MYSQL_IMAGE_NAME' already exists."
    fi
    lxc image import $MYSQL_IMAGE --alias $MYSQL_IMAGE_NAME

    REDIS_IMAGE_NAME=$(generateName "redis")
    if checkRessourceExist "image" "$REDIS_IMAGE_NAME"; then
        error "Image '$REDIS_IMAGE_NAME' already exists."
    fi
    lxc image import $REDIS_IMAGE --alias $REDIS_IMAGE_NAME

    if $modules; then
        MODULES_IMAGE_NAME=$(generateName "modules")
        if checkRessourceExist "image" "$MODULES_IMAGE_NAME"; then
            error "Image '$MODULES_IMAGE_NAME' already exists."
        fi
        lxc image import $MODULES_IMAGE --alias $MODULES_IMAGE_NAME
    fi
}


launchContainers(){
    # Launch Containers
    lxc launch $MISP_IMAGE_NAME $MISP_CONTAINER --profile=$APP_PROFILE 
    lxc launch $MYSQL_IMAGE_NAME $MYSQL_CONTAINER --profile=$DB_PROFILE
    lxc launch $REDIS_IMAGE_NAME $REDIS_CONTAINER --profile=$DB_PROFILE 
    if $modules; then
        lxc launch $MODULES_IMAGE_NAME $MODULES_CONTAINER --profile=$APP_PROFILE
    fi
}


configureMISPForDB(){
    ## Edit database conf
    ${LXC_MISP} -- sed -i "s/'database' => 'misp'/'database' => '$MYSQL_DATABASE'/" $MISP_PATH/MISP/app/Config/database.php
    ${LXC_MISP} -- sed -i "s/localhost/$MYSQL_CONTAINER.lxd/" $MISP_PATH/MISP/app/Config/database.php
    ${LXC_MISP} -- sed -i "s/'login' => '.*'/'login' => '$MYSQL_USER'/" "$MISP_PATH/MISP/app/Config/database.php"
    ${LXC_MISP} -- sed -i "s/8889/3306/" $MISP_PATH/MISP/app/Config/database.php
    ${LXC_MISP} -- sed -i "s/'password' => '.*'/'password' => '$MYSQL_PASSWORD'/" "$MISP_PATH/MISP/app/Config/database.php"

    # Write credentials to MISP
    ${LXC_MISP} -- sh -c "echo 'Admin (root) DB Password: $MYSQL_ROOT_PASSWORD \nUser ($MYSQL_USER) DB Password: $MYSQL_PASSWORD' > /home/misp/mysql.txt"
}

configureMySQL(){
    ## Add user + DB
    lxc exec $MYSQL_CONTAINER -- mysql -u root -e "CREATE DATABASE $MYSQL_DATABASE;"
    lxc exec $MYSQL_CONTAINER -- mysql -u root -e "GRANT ALL PRIVILEGES ON $MYSQL_DATABASE.* TO '$MYSQL_USER'@'$MISP_HOST' IDENTIFIED BY '$MYSQL_PASSWORD';"

    ## Configure remote access
    lxc exec $MYSQL_CONTAINER -- sed -i 's/bind-address            = 127.0.0.1/bind-address            = 0.0.0.0/' "/etc/mysql/mariadb.conf.d/50-server.cnf"
    lxc exec $MYSQL_CONTAINER -- sudo systemctl restart mysql

    # ## Check connection + import schema
    # table_count=$(${LXC_MISP} -- mysql -u $MYSQL_USER --password="$MYSQL_PASSWORD" -h $MYSQL_CONTAINER.lxd -P 3306 $MYSQL_DATABASE -e "SHOW TABLES;" | wc -l)
    # if [ $? -eq 0 ]; then
    #                 echo -e "${GREEN}Connected to database successfully!${NC}"
    #                 if [ $table_count -lt 73 ]; then
    #                     echo "Database misp is empty, importing tables from misp container ..."
    #                     ${LXC_MISP} -- bash -c "mysql -u $MYSQL_USER --password=$MYSQL_PASSWORD $MYSQL_DATABASE -h $MYSQL_CONTAINER.lxd -P 3306 2>&1 < $MISP_PATH/MISP/INSTALL/MYSQL.sql"
    #                 else
    #                     echo "Database misp available"
    #                 fi
    # else
    #     error $table_count
    # fi

    ## secure mysql installation
    lxc exec $MYSQL_CONTAINER -- mysqladmin -u root password "$MYSQL_ROOT_PASSWORD"
    lxc exec $MYSQL_CONTAINER -- mysql -u root -p"$MYSQL_ROOT_PASSWORD" <<EOF
    DELETE FROM mysql.user WHERE User='';
    DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
    DROP DATABASE IF EXISTS test;
    FLUSH PRIVILEGES;
EOF

    ## Update Database
    #${LXC_MISP} -- sudo -u www-data -H sh -c "$MISP_PATH/MISP/app/Console/cake Admin runUpdates"

}

configureRedisContainer(){
    ## Cofigure remote access
    lxc exec $REDIS_CONTAINER -- sed -i "s/^bind .*/bind 0.0.0.0/" "/etc/redis/redis.conf"
    lxc exec $REDIS_CONTAINER -- sed -i "s/^port .*/port $REDIS_CONTAINER_PORT/" "/etc/redis/redis.conf"
    lxc exec $REDIS_CONTAINER -- systemctl restart redis-server
}

configureMISPforRedis(){
    # CakeResque redis
    ${LXC_MISP} -- sed -i "s/'host' => '127.0.0.1'/'host' => '$REDIS_CONTAINER.lxd'/; s/'port' => 6379/'port' => $REDIS_CONTAINER_PORT/" /var/www/MISP/app/Plugin/CakeResque/Config/config.php
    # # ZeroMQ redis
    # ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_redis_host" "$REDIS_CONTAINER.lxd"
    # ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.ZeroMQ_redis_port" $REDIS_CONTAINER_PORT
    # # MISP redis
    # ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.redis_host" "$REDIS_CONTAINER.lxd"
    # ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "MISP.redis_port" $REDIS_CONTAINER_PORT 
}

createRedisSocket(){
    local file_path="/etc/redis/redis.conf"
    local lines_to_add="# create a unix domain socket to listen on\nunixsocket /var/run/redis/redis.sock\n# set permissions for the socket\nunixsocketperm 775"

    ${LXC_MISP} -- usermod -g www-data redis
    ${LXC_MISP} -- mkdir -p /var/run/redis/
    ${LXC_MISP} -- chown -R redis:www-data /var/run/redis
    ${LXC_MISP} -- cp "$file_path" "$file_path.bak"
    ${LXC_MISP} -- bash -c "echo -e \"$lines_to_add\" | cat - \"$file_path\" >tempfile && mv tempfile \"$file_path\""
    ${LXC_MISP} -- usermod -aG redis www-data
    ${LXC_MISP} -- service redis-server restart

    # Modify php.ini
    local php_ini_path="/etc/php/7.4/apache2/php.ini" 
    local socket_path="/var/run/redis/redis.sock"
    ${LXC_MISP} -- sed -i "s|;session.save_path = \"/var/lib/php/sessions\"|session.save_path = \"$socket_path\"|; s|session.save_handler = files|session.save_handler = redis|" $php_ini_path
    ${LXC_MISP} -- sudo service apache2 restart
}

initializeDB(){
    ## Check connection + import schema to MySQL
    table_count=$(${LXC_MISP} -- mysql -u $MYSQL_USER --password="$MYSQL_PASSWORD" -h $MYSQL_CONTAINER.lxd -P 3306 $MYSQL_DATABASE -e "SHOW TABLES;" | wc -l)
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Connected to database successfully!${NC}"
        if [ $table_count -lt 73 ]; then
            echo "Database misp is empty, importing tables from misp container ..."
            ${LXC_MISP} -- bash -c "mysql -u $MYSQL_USER --password=$MYSQL_PASSWORD $MYSQL_DATABASE -h $MYSQL_CONTAINER.lxd -P 3306 2>&1 < $MISP_PATH/MISP/INSTALL/MYSQL.sql"
        else
            echo "Database misp available"
        fi
    else
        error $table_count
    fi
    # Update DB
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin runUpdates
}

configureMISPModules(){
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Enrichment_services_enable" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Enrichment_hover_enable" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Enrichment_hover_popover_only" false
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Enrichment_timeout" 300
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Enrichment_hover_timeout" 150
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Enrichment_services_url" "$MODULES_CONTAINER.lxd"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Enrichment_services_port" 6666
 
    # Enable Import modules
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Import_services_enable" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Import_services_url" "$MODULES_CONTAINER.lxd"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Import_services_port" 6666
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Import_timeout" 300

    # Enable export modules
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Export_services_enable" true
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Export_services_url" "$MODULES_CONTAINER.lxd"
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Export_services_port" 6666
    ${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} Admin setSetting "Plugin.Export_timeout" 300

    # # Enable additional module settings
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_bgpranking_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_countrycode_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_cve_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_cve_advanced_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_cpe_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_dns_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_eql_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_btc_steroids_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_ipasn_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_reversedns_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_yara_syntax_validator_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_yara_query_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_wiki_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_threatminer_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_threatcrowd_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_hashdd_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_rbl_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_sigma_syntax_validator_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_stix2_pattern_syntax_validator_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_sigma_queries_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_dbl_spamhaus_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_btc_scam_check_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_macvendors_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_qrcode_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_ocr_enrich_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_pdf_enrich_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_docx_enrich_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_xlsx_enrich_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_pptx_enrich_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_ods_enrich_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_odt_enrich_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_urlhaus_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_malwarebazaar_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_html_to_markdown_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Enrichment_socialscan_enabled" true

    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Import_ocr_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Import_mispjson_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Import_openiocimport_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Import_threatanalyzer_import_enabled" true
    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Import_csvimport_enabled" true

    # ${SUDO_WWW} ${RUN_PHP} -- ${CAKE} Admin setSetting "Plugin.Export_pdfexport_enabled" true
}

# Main
checkSoftwareDependencies
getIntallationConfig
setVars
info "1" "Setup LXD Project"
setupLXD

info "2" "Import Images"
importImages

info "3" "Create Container"
launchContainers

info "4" "Configure and Update MySQL DB"
waitForContainer $MYSQL_CONTAINER
configureMySQL

info "5" "Configure Redis"
waitForContainer $REDIS_CONTAINER
configureRedisContainer
createRedisSocket

info "6" "Edit MISP Config"
waitForContainer $MISP_CONTAINER
configureMISPForDB
configureMISPforRedis
initializeDB
# start workers
${LXC_MISP} --cwd=${PATH_TO_MISP}/app/Console/worker -- ${SUDO_WWW} -- bash start.sh

info "7" "Create Keys"
setupGnuPG
# Create new auth key
${LXC_MISP} -- ${SUDO_WWW} -- ${CAKE} UserInit
AUTH_KEY=$(${LXC_MISP} -- sudo -u www-data -H sh -c "$MISP_PATH/MISP/app/Console/cake user change_authkey admin@admin.test | grep -oP ': \K.*'")
lxc exec "$MISP_CONTAINER" -- sh -c "echo 'Authkey: $AUTH_KEY' > /home/misp/MISP-authkey.txt"

info "8" "Set MISP Settings"
coreCAKE
if $modules; then
    configureMISPModules
fi
info "9" "Update Galaxies, ObjectTemplates, Warninglists, Noticelists and Templates"
updateGOWNT

if $PROD; then
    info "10" "Set MISP.live for production"
    ${LXC_MISP} -- sudo -u www-data -H sh -c "$MISP_PATH/MISP/app/Console/cake Admin setSetting MISP.live true"
    warn "MISP runs in production mode!"
fi

misp_ip=$(lxc list $MISP_CONTAINER --format=json | jq -r '.[0].state.network.eth0.addresses[] | select(.family=="inet").address')

# Print info
echo "--------------------------------------------------------------------------------------------"
echo -e "${BLUE}MISP ${NC}is up and running on $misp_ip"
echo "--------------------------------------------------------------------------------------------"
echo -e "The following files were created and need either ${RED}protection${NC} or ${RED}removal${NC} (shred on the CLI)"
echo -e "${RED}/home/misp/mysql.txt${NC}"
echo "Contents:"
${LXC_MISP} -- cat /home/misp/mysql.txt
echo -e "${RED}/home/misp/MISP-authkey.txt${NC}"
echo "Contents:"
${LXC_MISP} -- cat /home/misp/MISP-authkey.txt
echo "--------------------------------------------------------------------------------------------"
echo "User: admin@admin.test"
echo "Password: admin"
echo "--------------------------------------------------------------------------------------------"
echo "GnuPG passphrase: $GPG_PASSPHRASE"
echo "--------------------------------------------------------------------------------------------"