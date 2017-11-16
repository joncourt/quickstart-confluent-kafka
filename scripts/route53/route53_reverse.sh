#!/bin/bash

set -e
set -u
set -o pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

readonly ROUTE53_DEFAULT='/etc/default/route53'
readonly LOCK_FILE="/var/lock/$(basename -- "$0").lock"
readonly EC2_METADATA_URL='http://169.254.169.254/latest/meta-data'

# Make sure files are 644 and directories are 755.
umask 022

[[ -e "/proc/$(cat $LOCK_FILE 2>/dev/null)" ]] || rm -f $LOCK_FILE

# Load environment variables that are mandatory.
if [[ -f $ROUTE53_DEFAULT ]]; then
    # Necessary details (e.g. Hosted Zone ID, etc.) should
    # have been passed down in the bootstrap process.
    source $ROUTE53_DEFAULT
else
    echo "Unable to load environment variables from '$ROUTE53_DEFAULT', aborting..."
    exit 1
fi

# Add, remove or check.
ACTION='UNKNOWN'
case "${1:-$ACTION}" in
    # Add (when missing) or update.
    -a|--add) ACTION='UPSERT' ;;
    -r|--remove) ACTION='DELETE' ;;
    -c|--check) ACTION='CHECK' ;;
    -h|--help)
        cat <<EOS | tee

Automatically add, remove or check a DNS entry in Route53 for this instance.

Usage:

  $(basename -- "$0") <OPTION>

  Options:

    --add    -a  Add a DNS entry into Route53.
    --remove -r  Remove a DNS entry from Route53.
    --check  -c  Check if a DNS entry exists in Route53.
    --help   -h  This help screen.

  Note: By default, the forward (A) and reverse (PTR)
        resource records are added into Rotue53.

EOS
        exit 1
    ;;
    *)
        echo "Unknown or no action given, aborting..."
        exit 1
    ;;
esac

# Check if environment variables are present and non-empty.
REQUIRED=(TTL PRIVATE_ZONE_ID REVERSE_ZONE_ID INSTANCE_ID REGION)
for v in ${REQUIRED[@]}; do
    eval VALUE='$'${v}
    if [[ -z $VALUE ]]; then
        echo "The '$v' environment variable has to be set, aborting..."
        exit 1
    fi
done

if (set -o noclobber; echo $$ > $LOCK_FILE) &>/dev/null; then
    # Make a secure temporary file name, needed later.
    TEMPORARY_FILE=$(mktemp -ut "$(basename $0).XXXXXXXX")

    # Make sure to remove the temporary
    # file when terminating, and clean-up
    # the lock-file too.
    trap \
        "rm -f $LOCK_FILE $TEMPORARY_FILE; exit" \
            HUP INT KILL TERM QUIT EXIT

    if [[ "x${INSTANCE_ID}" == "x" ]]; then
        # Fetch the EC2 instance ID.
        INSTANCE_ID=$(curl -s ${EC2_METADATA_URL}/instance-id)
    fi

    # Fetch current private IP address of this instance.
    PRIVATE_IP_ADDRESS=$(curl -s ${EC2_METADATA_URL}/local-ipv4)

    # Make the in-addr.arpa. address for this instance.
    INSTANCE_PTR=$(echo "$(printf '%s.' $PRIVATE_IP_ADDRESS | tac -s'.')in-addr.arpa.")

    # Fetch current "Name" tag that was set for this
    # instance, as it will be used when adding (or
    # updating) a new DNS entry (of a type "A") in
    # Route53 service. The premise is that whatever
    # the aforementioned tag is, then the DNS entry
    # should be exactly the same.
    INSTANCE_NAME_TAG=$(aws ec2 describe-tags \
        --query 'Tags[*].Value' \
        --filters "Name=resource-id,Values=${INSTANCE_ID}" 'Name=key,Values=Name' \
        --region $REGION --output text 2>/dev/null)

    # Make sure that the "Name" tag was actually set.
    if [[ "x${INSTANCE_NAME_TAG}" == "x" ]]; then
        echo "The 'Name' tag is empty or has not been set, aborting..."
        exit 1
    fi

    if [[ $ACTION == 'CHECK' ]]; then
        # Keep a track of resource records.
        SEEN_RESOURCES=0

        # Fetch details (about every resource) about given Hosted
        # Zone (both forward and reverse) from Route53 and format
        # to make it easier to search for a particular entry,
        # and filter the A and PTR resource records only.
        for zone in PRIVATE_ZONE_ID REVERSE_ZONE_ID; do
            eval VALUE='$'${zone}

            aws route53 list-resource-record-sets \
                --query 'ResourceRecordSets[*].[Type,TTL,Name,ResourceRecords[0].Value]' \
                --hosted-zone-id $VALUE \
                --region $REGION --output text | \
                    grep -E '^(A|PTR)' | sed -e 's/\s/,/g' | \
                        tee -a $TEMPORARY_FILE >/dev/null || true
        done

        # Assemble the A resource record for this instance.
        RESOURCE=$(printf "%s,%s,%s.,%s" "A" "$TTL" "$INSTANCE_NAME_TAG" "$PRIVATE_IP_ADDRESS")
        if grep -q $RESOURCE $TEMPORARY_FILE &>/dev/null; then
            echo $RESOURCE | awk -F',' '{ print $3, $1, $4, $2 }'
            SEEN_RESOURCES+=1
        fi

        # Assemble the PTR resource record for this instance.
        RESOURCE=$(printf "%s,%s,%s,%s" "PTR" "$TTL" "$INSTANCE_PTR" "$INSTANCE_NAME_TAG")
        if grep -q $RESOURCE $TEMPORARY_FILE &>/dev/null; then
            echo $RESOURCE | awk -F',' '{ print $3, $1, $4, $2 }'
            SSEEN_RESOURCESEEN+=1
        fi

        if (( $SEEN_RESOURCES < 1 )); then
          # If there is nothing to show or a records are missing,
          # then we make it a non-clean exit.
          echo "No resource records found, aborting..." >&2
          exit 1
        fi

        exit 0
    else
        # Render details of the request (or a "change",
        # rather) which is going to be sent to Route53.
        # Note that the "UPSERT" action will both add
        # the entry if it does not exist yet or update
        # current value accordingly. Better option over
        # the "CREATE" action (which in turn would fail
        # if an entry exists already).
        cat <<EOF > $TEMPORARY_FILE
{
  "Changes": [
    {
      "Action": "${ACTION}",
      "ResourceRecordSet": {
        "Name": "${INSTANCE_NAME_TAG}.",
        "Type": "A",
        "TTL": ${TTL},
        "ResourceRecords": [
          {
            "Value": "${PRIVATE_IP_ADDRESS}"
          }
        ]
      }
    }
  ]
}
EOF

        # Route53 has a queue for incoming change requests.
        # When a task is placed in a queue successfully,
        # then a "Change ID" which represents a batch job
        # will be given back, and it can be used to track
        # progress (although, IAM role needs to be set
        # appropriately to allow access, etc.).
        #
        # Add the A resource record into Route53.
        aws route53 change-resource-record-sets \
            --hosted-zone-id $PRIVATE_ZONE_ID \
            --change-batch file://${TEMPORARY_FILE} \
            --region $REGION

        cat <<EOF > $TEMPORARY_FILE
{
  "Changes": [
    {
      "Action": "${ACTION}",
      "ResourceRecordSet": {
        "Name": "${INSTANCE_PTR}",
        "Type": "PTR",
        "TTL": ${TTL},
        "ResourceRecords": [
          {
            "Value": "${INSTANCE_NAME_TAG}"
          }
        ]
      }
    }
  ]
}
EOF
        # Add the PTR resource record into Route53.
        aws route53 change-resource-record-sets \
            --hosted-zone-id $REVERSE_ZONE_ID \
            --change-batch file://${TEMPORARY_FILE} \
            --region $REGION
    fi

    rm -f $LOCK_FILE $TEMPORARY_FILE &>/dev/null

    # Reset traps to their default behaviour.
    trap - HUP INT KILL TERM QUIT EXIT
else
    echo "Unable to create lock file (current owner: "$(cat $LOCK_FILE 2>/dev/null)")."
    exit 1
fi
