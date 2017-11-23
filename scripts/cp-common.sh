#!/usr/bin/env bash

LOG=/tmp/cp-install.log

set_aws_meta_url() {
    echo "Setting AWS Meta URL" >> $LOG
    # Extract useful details from the AWS MetaData
    # The information there should be treated as the source of truth,
    # even if the internal settings are temporarily incorrect.
    murl_top=http://169.254.169.254/latest/meta-data
}

set_hosted_zone_dn() {
    echo "Setting Hosted Zone Domain Name" >> $LOG
    
    set_aws_meta_url

    ROUTE53_DEFAULT='/etc/default/route53'
    
    # Load environment variables that are mandatory.
    if [[ -f $ROUTE53_DEFAULT ]]; then
        # Necessary details (e.g. Hosted Zone ID, etc.) should
        # have been passed down in the bootstrap process.
        source $ROUTE53_DEFAULT
    else
        echo "Unable to load environment variables from '$ROUTE53_DEFAULT', aborting..." >>$LOG
        exit 1
    fi
    
    if [ -z $HOSTED_ZONE_ID ]; then
        echo "HOSTED_ZONE_ID not set, no HOSTED_ZONE_DN to lookup, moving on" >> $LOG
        return
    fi
    
    # aws route53 get-hosted-zone seems a little unsteady sometimes - using a short retry cycle to compensate
    while : ; do
        this_retry=$[this_retry+1]

        # HOSTED_ZONE_ID is loaded from ROUTES53_DEFAULT, created in user-data script
        HOSTED_ZONE_DN=$(aws route53 get-hosted-zone --id  ${HOSTED_ZONE_ID} --query 'HostedZone.Name' --output text 2> /dev/null )
    
        if  [[ -z $HOSTED_ZONE_DN && $this_retry -lt 5 ]]; then
            echo "Failed to get HOSTED_ZONE_DN after attempt '$this_retry', pausing before retry" >> $LOG
            sleep 3
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
    set_aws_meta_url
    
    THIS_FQDN=$(curl -f -s $murl_top/hostname)
    [ -z "${THIS_FQDN}" ] && THIS_FQDN=$(hostname --fqdn)
    
    set_hosted_zone_dn
    
    THIS_HOST="${THIS_FQDN%%.*}.${HOSTED_ZONE_DN}"
    
    echo "Set THIS_HOST to $THIS_HOST" >> $LOG
}

