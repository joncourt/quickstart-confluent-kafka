#!/usr/bin/env bash

THIS_SCRIPT=`readlink -f $0`
SCRIPTDIR=`dirname ${THIS_SCRIPT}`
LOG=/tmp/cp-dns.log

ROUTE53_DEFAULT=/etc/default/route53
ROUTE53_SVC_LOCKFILE=/var/lock/subsys/route53


HOSTED_ZONE_ID=$1
if [ -z $HOSTED_ZONE_ID ]; then
    echo "HOSTED_ZONE_ID is expected at position one for script $0, not found, not setting up dns" >> $LOG
    exit 0
else 
    echo "Using Hosted Zone ID '$HOSTED_ZONE_ID'" >> $LOG
fi 

TTL=$2
if [[ ! $TTL =~ ^-?[0-9]+$ ]]; then
    TTL=300
    echo "TTL is expected to be an integer at position two for script $0, not found, using $TTL" >> $LOG
else
    echo "TTL is set to '$TTL'" >> $LOG
fi


set_aws_meta_url() {
    if [ ! -z $murl_top ]; then
        echo "Already set AWS Meta URL to '$murl_top', nothing to do" >> $LOG
        return 0
    fi

    echo "Setting AWS Meta URL" >> $LOG

    # Extract useful details from the AWS MetaData
    # The information there should be treated as the source of truth,
    # even if the internal settings are temporarily incorrect.
    murl_top=http://169.254.169.254/latest/meta-data
}

source_route53_config_defaults() {
    if [ -z $HOSTED_ZONE_ID ]; then
        echo "No Hosted Zone ID set, no need to reload route53 defaults" >> $LOG
        return 0
    fi

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
        return 0
    fi

    echo "Setting Hosted Zone Domain Name" >> $LOG

    set_aws_meta_url
    source_route53_config_defaults

    if [ -z $HOSTED_ZONE_ID ]; then
        echo "HOSTED_ZONE_ID not set, no HOSTED_ZONE_DN to lookup, nothing to do" >> $LOG
        return 0
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
        return 0
    fi

    ## Strip the last '.' which Route53 appends to the DN
    HOSTED_ZONE_DN=${HOSTED_ZONE_DN: 0: -1}

    echo "Set HOSTED_ZONE_DN to $HOSTED_ZONE_DN" >> $LOG
}


set_this_host() {
    if [ ! -z $THIS_HOST ]; then
        echo "Already set THIS_HOST to '$THIS_HOST', nothing to do" >> $LOG
        return 0
    fi

    echo "Setting THIS_HOST" >> $LOG
    set_aws_meta_url
    set_hosted_zone_dn

    THIS_FQDN=$(curl -f -s $murl_top/hostname)


    THIS_HOST="${THIS_FQDN%%.*}.${HOSTED_ZONE_DN}"

    echo "Set THIS_HOST to $THIS_HOST" >> $LOG
}


add_dns_entry() {
    source_route53_config_defaults
    set_this_host 

    echo "Creating DNS entry for $THIS_HOST" >> $LOG 
    $SCRIPTDIR/route53/route53.sh --add
}

write_route53_default() {
    # the downstream scripts (route53.sh) depend on this so we create it here and use it everywhere else
    echo "Writing $ROUTE53_DEFAULT file, necessary for creating of DNS entries" >> $LOG

    cat > $ROUTE53_DEFAULT << EOF
TTL=${TTL}
HOSTED_ZONE_ID=${HOSTED_ZONE_ID}
EOF

    if [ $? -ne 0 ]; then
        echo "Failed to write to $ROUTE53_DEFAULT, aborting dns script" >>$LOG
        exit 1
    fi
}

modify_dhclient_for_dns() {

    if [ ! -z $DH_CLIENT_CONF ]; then
        echo "already done dhclient setup, doing nothing" >> $LOG
        return 0
    fi
    
    set_hosted_zone_dn

    if [ -z $HOSTED_ZONE_DN ]; then
        return
    fi

    echo "Updating dhclient.conf to set the correct domain for search to $HOSTED_ZONE_DN" >> $LOG

    # for Amazon Linux
    DH_CLIENT_CONF=/etc/dhcp/dhclient.conf

    # TODO: Add paths to dhclient.conf for Ubuntu and Centos

    INTERFACE_NAME=eth0
    
    cat >> $DH_CLIENT_CONF <<EOF
interface "$INTERFACE_NAME" {
    supersede domain-name "$HOSTED_ZONE_DN";
    supersede domain-search "$HOSTED_ZONE_DN";
}
EOF

    echo "Updated $DH_CLIENT_CONF - renewing lease for '$INTERFACE_NAME'" >> $LOG
    dhclient -r $INTERFACE_NAME
    dhclient $INTERFACE_NAME
}

register_route53_init() {

    # TODO: Test for chkconfig support in centos and ubuntu
    chkconfig --add route53
    
    # also ensure the lock file was created on first start so shutdown hooks work
    touch $ROUTE53_SVC_LOCKFILE
}

main () {
	echo "$0 script started at "`date` >> $LOG

    write_route53_default
    register_route53_init
    add_dns_entry
    modify_dhclient_for_dns
    
    echo "$0 script finished at "`date` >> $LOG
}

main
exitCode=$?

set +x

exit $exitCode