#!/usr/bin/env bash

LOG=/tmp/cp-common.log

set_aws_meta_url() {
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


set_this_fqdn() {
    if [ ! -z $THIS_FQDN ]; then
        echo "Already set THIS_FQDN to '$THIS_FQDN', nothing to do" >> $LOG
        return 0
    fi

    echo "Setting THIS_FQDN" >> $LOG
    set_aws_meta_url
    set_hosted_zone_dn

    RAW_FQDN=$(curl -f -s $murl_top/hostname)


    THIS_FQDN="${RAW_FQDN%%.*}.${HOSTED_ZONE_DN}"

    echo "Set THIS_FQDN to $THIS_FQDN" >> $LOG
}


# Add/update config file parameter
#	$1 : config file
#	$2 : property
#	$3 : new value
#	$4 (optional) : 0: delete old value; 1[default]: retain old value 
#
# The sed logic in this functions works given following limitations
#	1. At most one un-commented setting for a given parameter
#	2. If ONLY commented values exist, the FIRST ONE will be overwritten
#
set_property() {
	[ ! -f $1 ] && return 1

	local cfgFile=$1
	local property=$2
	local newValue=$3
	local doArchive=${4:-1}

	grep -q "^${property}=" $cfgFile
	overwriteMode=$?

	grep -q "^#${property}=" $cfgFile
	restoreMode=$?


	if [ $overwriteMode -eq 0 ] ; then
		if [ $doArchive -ne 0 ] ; then
				# Add the new setting, then comment out the old
			sed -i "/^${property}=/a ${property}=$newValue" $cfgFile
			sed -i "0,/^${property}=/s|^${property}=|# ${property}=|" $cfgFile
		else
			sed -i "s|^${property}=.*$|${property}=${newValue}|" $cfgFile
		fi
	elif [ $restoreMode -eq 0 ] ; then
				# "Uncomment" first entry, then replace it
				# This helps us by leaving the setting in the same place in the file
		sed -i "0,/^#${property}=/s|^#${property}=|${property}=|" $cfgFile
		sed -i "s|^${property}=.*$|${property}=${newValue}|" $cfgFile
	else 
		echo "" >> $cfgFile
		echo "${property}=${newValue}" >> $cfgFile

	fi
}


