#!/usr/bin/env bash

THIS_SCRIPT=`readlink -f $0`
SCRIPTDIR=`dirname ${THIS_SCRIPT}`
LOG=/tmp/cp-dns.log

source $SCRIPTDIR/cp-common.sh

ROUTE53_DEFAULT=/etc/default/route53

while getopts "z: d: n: t:" opt; do
    case ${opt} in
        z)
            HOSTED_ZONE_ID=$OPTARG
            ;;
        t)
            TTL=$OPTARG
            ;;
        :) 
            echo "${OPTARG} requires an argument"
            ;;
        ?)
            echo "Usage: $(basename $0) -z hosted-zone-id [-t ttl: 300]"
            ;;
    esac
done

if [ -z $HOSTED_ZONE_ID ]; then
    echo "HOSTED_ZONE_ID (option -z) is required to set up DNS, doing nothing." >> $LOG
    exit 0
else 
    echo "Using Hosted Zone ID '$HOSTED_ZONE_ID'" >> $LOG
fi 

if [[ ! $TTL =~ ^-?[0-9]+$ ]]; then
    TTL=300
    echo "TTL (option -t) not set. Defaulting to 300." >> $LOG
else
    echo "TTL is set to '$TTL'" >> $LOG
fi



#add_dns_entry() {
#    source_route53_config_defaults
#    set_this_host 
#
#    echo "Creating DNS entry for $THIS_HOST" >> $LOG 
#    $SCRIPTDIR/route53/route53.sh --add
#}

write_route53_default() {
    # the downstream scripts (route53.sh) depend on this so we create it here and use it everywhere else
    echo "Writing $ROUTE53_DEFAULT file, necessary for creating DNS entries" >> $LOG

    cat > $ROUTE53_DEFAULT << EOF
TTL=${TTL}
HOSTED_ZONE_ID=${HOSTED_ZONE_ID}
EOF

    if [ $? -ne 0 ]; then
        echo "Failed to write to $ROUTE53_DEFAULT, aborting dns script" >>$LOG
        exit 1
    fi
}

set_linux_flavor() {
    if [ ! -z $LINUX_FLAVOR ]; then
        return
    fi

    LINUX_ISSUE="$(python -mplatform):$(uname -a):$(cat /etc/issue)"

    echo $LINUX_ISSUE | grep -qi ubuntu
    case "$?" in
        0)
            LINUX_FLAVOR="ubuntu"
            ;;
        *)
            echo $LINUX_ISSUE | grep -qi amazon
            case "$?" in
                0)
                    LINUX_FLAVOR="amazon"
                    ;;
                *)
                    echo $LINUX_ISSUE | grep -qi centos
                    case "$?" in
                        0)
                            LINUX_FLAVOR="centos"
                            ;;
                        *)
                            LINUX_FLAVOR="unknown"
                            echo "Unable to determine Linux flavor from /etc/issue of '$LINUX_ISSUE'. Setting flavor to 'unknown'." >> $LOG
                            ;;
                    esac
                    ;;
            esac
            ;;
    esac

    echo "Setting linux flavor to '$LINUX_FLAVOR' detected from text '$LINUX_ISSUE'" >> $LOG
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
    set_linux_flavor
    echo "Registering Route53 services on $LINUX_FLAVOR" >> $LOG

    ROUTE53_SVC_LOCKFILE="/var/lock/subsys/route53"

    case "$LINUX_FLAVOR" in
        ubuntu)
            # add the startup hook
            systemctl enable route53 >> %LOG
            systemctl start route53 >> $LOG
            
#            # add the shutdown hook(s)
#            ln -s /etc/rc0.d/K99route53 route53
#            ln -s /etc/rc6.d/K99route53 route53
            ;;
        amazon)
            # add the startup and shutdown hooks
            chkconfig --add route53 >> $LOG

            service route53 start >> $LOG
            ;;
        centos)
            systemctl enable route53 >> %LOG

            # link a shutdown hook
            ln -s /etc/rc.d/init.d/route53 /etc/rc.d/rc.shutdown
            
            systemctl start route53 >> $LOG
            ;;
        *)
            echo "Unsupported linux flavor - unable to register route53.init correctly" >> $LOG
            ;;
    esac
}

main () {
	echo "$0 script started at "`date` >> $LOG

    write_route53_default
    modify_dhclient_for_dns
    register_route53_init
    
    echo "$0 script finished at "`date` >> $LOG
}

main
exitCode=$?

set +x

exit $exitCode