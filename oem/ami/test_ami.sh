#!/bin/bash
#
# This expects to run on an EC2 instance.
#
# mad props to Eric Hammond for the initial script
#  https://github.com/alestic/alestic-hardy-ebs/blob/master/bin/alestic-hardy-ebs-build-ami

# This script will launch three ec2 nodes with shared user-data, and then 
# then test of the cluster is bootstrapped

# Set pipefail along with -e in hopes that we catch more errors
set -e -o pipefail

USAGE="Usage: $0 -a ami-id
    -a ami-id   ID of the AMI to be tests
    -V VERSION  Find AMI by CoreOS version.
    -b BOARD    Set to the board name, default is amd64-usr
    -g GROUP    Set the update group, default is alpha
    -h          this ;-)
    -v          Verbose, see all the things!

The AMI to test must be specified by -a or -V.
This script must be run from an ec2 host with the ec2 tools installed.
"

AMI=
HVM=
VER=
BOARD="amd64-usr"
GROUP="alpha"

clean_version() {
    sed -e 's%[^A-Za-z0-9()\\./_-]%_%g' <<< "$1"
}

while getopts "a:V:b:g:hv" OPTION
do
    case $OPTION in
        a) AMI="$OPTARG";;
        V) VER="$OPTARG";;
        b) BOARD="$OPTARG";;
        g) GROUP="$OPTARG";;
        h) echo "$USAGE"; exit;;
        v) set -x;;
        *) exit 1;;
    esac
done

if [[ $(id -u) -eq 0 ]]; then
    echo "$0: This command should not be ran run as root!" >&2
    exit 1
fi

zoneurl=http://instance-data/latest/meta-data/placement/availability-zone
zone=$(curl --fail -s $zoneurl)
region=$(echo $zone | sed 's/.$//')
export EC2_URL="http://ec2.${region}.amazonaws.com"

if [[ -z "$AMI" && -n "$VER" ]]; then
    search_name=$(clean_version "CoreOS-$GROUP-$VER")
    AMI=$(ec2-describe-images -F name="${search_name}" | grep -m1 ^IMAGE \
        | cut -f2) || true # Don't die silently, error messages are good
    if [[ -z "$AMI" ]]; then
        echo "$0: Cannot find an AMI named $search_name" >&2
        exit 1
    fi
    HVM=$(ec2-describe-images -F name="${search_name}-hvm" \
        | grep -m1 ^IMAGE | cut -f2) || true
    if [[ -z "$HVM" ]]; then
        echo "$0: Cannot find an AMI named ${search_name}-hvm" >&2
        exit 1
    fi
elif [[ -n "$AMI" ]]; then
    # check to make sure this is a valid image
    if ! ec2-describe-images -F image-id="$AMI" | grep -q "$AMI"; then
        echo "$0: Unknown image: $AMI" >&2
        exit 1
    fi
else
    echo "$0: AMI id or version required (-a or -V options)" >&2
    echo "$USAGE" >&2
    exit 1
fi

echo -n "Creating keys and security group... "
key_name="autotest-`date +%s`"
key_file="/tmp/$key_name"
ec2-create-keypair $key_name | grep -v KEYPAIR > $key_file
chmod 600 $key_file

sg_name=$key_name
sg=$(ec2-create-group $sg_name --description "$sg_name" | cut -f2)
ec2-authorize "$sg_name" -P tcp -p 4001 > /dev/null
ec2-authorize "$sg_name" -P tcp -p 7001 > /dev/null
ec2-authorize "$sg_name" -P tcp -p 22 > /dev/null
echo "OK ($key_name)"

discovery=$(curl --fail -s https://discovery.etcd.io/new)
userdata="#cloud-config

coreos:
    etcd:
        discovery: $discovery
        addr: \$public_ipv4:4001
        peer-addr: \$public_ipv4:7001
    units:
      - name: etcd.service
        command: start
      - name: fleet.service
        command: start
"

echo -n "Booting instances... "
# Add in 1 HVM instance if available.
if [[ -z "$HVM" ]]; then
  instances=$(ec2-run-instances \
    --user-data "$userdata" \
    --instance-type "t1.micro" \
    --instance-count 3 \
    --group "$sg_name" \
    --key "$key_name" $AMI | \
       grep INSTANCE | cut -f2)
else
  instances=$(ec2-run-instances \
    --user-data "$userdata" \
    --instance-type "t1.micro" \
    --instance-count 2 \
    --group "$sg_name" \
    --key "$key_name" $AMI | \
       grep INSTANCE | cut -f2)
  instances+=" "
  instances+=$(ec2-run-instances \
    --user-data "$userdata" \
    --instance-type "m3.medium" \
    --instance-count 1 \
    --group "$sg_name" \
    --key "$key_name" $HVM | \
       grep INSTANCE | cut -f2)
fi
# little hack to create a describe instances command that only 
# pulls data for these instances
ec2_cmd=$(echo $instances | sed 's/ / --filter instance-id=/g')
ec2_cmd="ec2-describe-instances --filter instance-id=$ec2_cmd"

while $ec2_cmd | grep INSTANCE | grep -q pending
  do sleep 10; done

declare -a ips=($($ec2_cmd | grep INSTANCE | cut -f4))

# sleep until all the sockets we need come up
for host in ${ips[@]}; do
    for port in 22 4001 7001; do
        timeout 120 perl -MIO::Socket::INET -e "
            until(new IO::Socket::INET('$host:$port')){sleep 1}"
    done
done
echo "OK ($instances)"

echo "Running coretest..."
for host in ${ips[@]}; do
    if ! ssh -i "$key_file" -l core -o StrictHostKeyChecking=no "$host" \
            coretest -test.v=true -test.parallel=8
    then
        echo "coretest failed for $host" >&2
        exit 1
    fi
done
echo "OK"

echo -n "Testing etcd... "
test_key="v1/keys/test"
token=$(uuidgen)
# XXX: the sleep *should never* be required, this is a bug in etcd
sleep 5
curl --fail -s -L "${ips[0]}:4001/$test_key" -d value="$token" > /dev/null
sleep 5
for host in ${ips[@]}; do
    if ! curl --fail -s -L "${host}:4001/$test_key" | grep -q $token; then
        echo "etcd bootstrap appears to have failed for $host" >&2
        exit 1
    fi
done
echo "OK"

echo -n "Cleaning up environment... "
ec2-terminate-instances $instances > /dev/null
while ! $ec2_cmd | grep INSTANCE | grep -q terminated
  do sleep 10; done

# The security group may take a little longer to free up
while ! ec2-delete-group $sg_name > /dev/null
  do sleep 10; done
ec2-delete-keypair $key_name > /dev/null
rm $key_file
echo "OK"
