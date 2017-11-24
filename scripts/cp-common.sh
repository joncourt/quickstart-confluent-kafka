#!/usr/bin/env bash

LOG=/tmp/cp-install.log

set_aws_meta_url() {
    if [ ! -z $murl_top ]; then
        echo "Already set AWS Meta URL to '$murl_top', nothing to do" >> $LOG
        return
    fi

    echo "Setting AWS Meta URL" >> $LOG

    # Extract useful details from the AWS MetaData
    # The information there should be treated as the source of truth,
    # even if the internal settings are temporarily incorrect.
    murl_top=http://169.254.169.254/latest/meta-data
}

source_route53_config_defaults() {
    if [ ! -z $HOSTED_ZONE_ID ]; then
        echo "No Hosted Zone ID set, no need to reload route53 defaults" >> $LOG
        return
    fi

    ROUTE53_DEFAULT='/etc/default/route53'

    echo "Sourcing Route53 settings from $ROUTE53_DEFAULT" >> $LOG

    # Load environment variables that are mandatory
    if [[ -f $ROUTE53_DEFAULT ]]; then
        # Necessary details (e.g. Hosted Zone ID, etc.) should
        # have been passed down in the bootstrap process.
        source $ROUTE53_DEFAULT
    else
        echo "Unable to load environment variables from '$ROUTE53_DEFAULT', aborting..." >>$LOG
        exit 1
    fi
}

set_hosted_zone_dn() {

    if [ ! -z $HOSTED_ZONE_DN ]; then
        echo "Already set HOSTED_ZONE_DN to '$HOSTED_ZONE_DN', nothing to do" >> $LOG
        return
    fi

    echo "Setting Hosted Zone Domain Name" >> $LOG

    set_aws_meta_url
    source_route53_config_defaults

    if [ -z $HOSTED_ZONE_ID ]; then
        echo "HOSTED_ZONE_ID not set, no HOSTED_ZONE_DN to lookup, nothing to do" >> $LOG
        return
    fi

    # aws route53 get-hosted-zone seems a little unsteady sometimes - using a short retry cycle to compensate
    while : ; do
        this_retry=$[this_retry+1]

        # HOSTED_ZONE_ID is loaded from ROUTES53_DEFAULT, created in user-data script
        HOSTED_ZONE_DN=$(aws route53 get-hosted-zone --id  ${HOSTED_ZONE_ID} --query 'HostedZone.Name' --output text 2> /dev/null )

        if  [[ -z $HOSTED_ZONE_DN && $this_retry -lt 5 ]]; then
            echo "Failed to get HOSTED_ZONE_DN after attempt '$this_retry', pausing before retry" >> $LOG

            # sleep with a bit of randomness to prevent lockstep attempts - for the case that it is cross-server request collisions causing the instability
            sleep $[ ( $RANDOM % 5 )  + 1 ]
        else
            break
        fi
    done

    if [ -z $HOSTED_ZONE_DN ]; then
        attempts=$[this_retry-1]
        echo "Failed to get HOSTED_ZONE_DN after '$attempts' attempts, is '$HOSTED_ZONE_ID' the correct Hosted Zone Id?" >> $LOG
        return
    fi

    ## Strip the last '.' which Route53 appends to the DN
    HOSTED_ZONE_DN=${HOSTED_ZONE_DN: 0: -1}

    echo "Set HOSTED_ZONE_DN to $HOSTED_ZONE_DN" >> $LOG
}


set_this_host() {
    if [ ! -z $THIS_HOST ]; then
        echo "Already set THIS_HOST to '$THIS_HOST', nothing to do" >> $LOG
        return
    fi

    echo "Setting THIS_HOST" >> $LOG
    set_aws_meta_url
    set_hosted_zone_dn

    THIS_FQDN=$(curl -f -s $murl_top/hostname)


    THIS_HOST="${THIS_FQDN%%.*}.${HOSTED_ZONE_DN}"

    echo "Set THIS_HOST to $THIS_HOST" >> $LOG
}


maybe_append_domain_to_dhclient_conf() {
    if [ ! -z $DH_CLIENT_CONF ]; then
        echo "already updated '$DH_CLIENT_CONF', doing nothing" >> $LOG
        return
    fi

    set_hosted_zone_dn

    if [ -z $HOSTED_ZONE_DN ]; then
        return
    fi

    echo "Updating dhclient.conf to set the correct domain for search to $HOSTED_ZONE_DN" >> $LOG

    # for Amazon Linux
    DH_CLIENT_CONF=/etc/dhcp/dhclient.conf

    # TODO: Add paths to dhclient.conf for Ubuntu and Centos

    cat >> $DH_CLIENT_CONF <<EOF
interface "eth0" {
    supersede domain-name "$HOSTED_ZONE_DN";
    supersede domain-search "$HOSTED_ZONE_DN";
}
EOF

    echo "Updated $DH_CLIENT_CONF - renewing lease" >> $LOG
    dhclient -r
    dhclient
}
