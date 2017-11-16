#!/bin/bash -eu

#
# route53.sh
#
# The main tasks of this script are:
#
#   - Automatically add or remove a DNS entry in Route53 based
#     on *this* instance "Name" tag (assuming it was prior set
#     to a correct value);
#
# Auxiliary tasks of this script:
#
#   - Perform a look-up against the Route53 to check whether
#     a correct DNS entry exists there already, and report back.
#
# This script is to be installed as /usr/local/sbin/route53.
#

export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

readonly ROUTE53_DEFAULT='/etc/default/route53'
readonly EC2_METADATA_URL='http://169.254.169.254/latest/meta-data'
readonly LOCK_FILE="/var/lock/$(basename -- "$0").lock"

# Make sure files are 644 and directories are 755.
umask 022

[[ -e "/proc/$(cat $LOCK_FILE 2>/dev/null)" ]] || rm -f $LOCK_FILE

# Load environment variables that are mandatory.
if [[ -f $ROUTE53_DEFAULT ]]; then
    # Necessary details (e.g. Hosted Zone ID, etc.) should
    # have been passed down in the bootstrap process.
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

EOS
        exit 1
    ;;
    *)
        echo "Unknown or no action given, aborting..."
        exit 1
    ;;
esac

# Check if environment variables are present and non-empty.
REQUIRED=( TTL HOSTED_ZONE_ID INSTANCE_ID REGION )
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
    # file when terminating, and clean-up
    # the lock-file too.
    trap \
        "rm -f $LOCK_FILE $TEMPORARY_FILE; exit" \
            HUP INT KILL TERM QUIT EXIT

    # Fetch current private IP address of this instance.
    INSTANCE_IPV4=$(curl -s ${EC2_METADATA_URL}/local-ipv4)

    # Fetch current "Name" tag that was set for this
    # instance, as it will be used when adding (or
    # updating) a new DNS entry (of a type "A") in
    # Route53 service. The premise is that whatever
    # the aforementioned tag is, then the DNS entry
    # should be exactly the same.
    INSTANCE_NAME_TAG=$(
        aws ec2 describe-tags \
            --query 'Tags[*].Value' \
            --filters "Name=resource-id,Values=${INSTANCE_ID}" 'Name=key,Values=Name' \
            --region $REGION --output text 2>/dev/null
    )

    # Make sure that the "Name" tag was actually set.
    if [[ "x${INSTANCE_NAME_TAG}" == "x" ]]; then
        echo "The 'Name' tag is empty or has not been set, aborting..."
        exit 1
    fi

    if [[ $ACTION == 'CHECK' ]]; then
        # Fetch details (about every resource) about given Hosted
        # Zone from Route53 and format to make it easier to search
        # for a particular entry. Since the amount of records can
        # often be quiet large, store it in a temporary file.
        aws --color=off route53 list-resource-record-sets \
            --query 'ResourceRecordSets[*].[Type,TTL,Name,ResourceRecords[0].Value]' \
            --hosted-zone-id $HOSTED_ZONE_ID --region $REGION --output text | \
                sed -e 's/\s/,/g' 2>/dev/null > $TEMPORARY_FILE

        # Assemble entry for this instance.
        RESOURCE=$(printf "%s,%s,%s.,%s" "A" "$TTL" "$INSTANCE_NAME_TAG" "$INSTANCE_IPV4")
        if grep -q $RESOURCE $TEMPORARY_FILE &>/dev/null; then
            # Found? Then print using the JSON that can used to
            # make a change request against Reoute53, if needed.
            cat <<EOF
{
  "ResourceRecordSet": {
    "Name": "${INSTANCE_NAME_TAG}.",
    "Type": "A",
    "TTL": ${TTL},
    "ResourceRecords": [
      {
        "Value": "${INSTANCE_IPV4}"
      }
    ]
  }
}
EOF
            exit 0
        fi

        # Nothing to show? Then make
        # it a non-clean exit.
        exit 1
    else
        # Render details of the request (or a "change",
        # rather) which is going to be sent to Route53.
        # Note that the "UPSERT" action will both add
        # the entry if it does not exist yet or update
        # current value accordingly. Better option over
        # the "CREATE" action (which in turn would fail
        # if an entry exists already).
        cat <<EOF | tee $TEMPORARY_FILE
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
            "Value": "${INSTANCE_IPV4}"
          }
        ]
      }
    }
  ]
}
EOF

        # Route53 has a queue for incoming change requests.
        # When a task is placed in a queue successfully,
        # then a "Change ID" which represents a batch job
        # will be given back, and it can be used to track
        # progress (although, IAM role needs to be set
        # appropriately to allow access, etc.).
        aws route53 change-resource-record-sets \
            --hosted-zone-id $HOSTED_ZONE_ID \
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