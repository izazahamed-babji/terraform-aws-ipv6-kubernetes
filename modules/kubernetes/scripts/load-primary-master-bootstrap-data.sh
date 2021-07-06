#!/bin/bash

exec &> /var/log/load-bootstrap-user-data.log

set -o verbose
set -o errexit
set -o pipefail

# Install pre-requisites
apt update
apt upgrade -qy
apt install -qy awscli

# Get the addons and base64 decode
mkdir -p /tmp/addons && cd /tmp/addons
aws s3 cp s3://${s3_bootstrap_user_data_bucket}/addons ./ --recursive
for addon_file in *; do
    encoded_file=$(basename -- "$addon_file")
    yaml_file="$${encoded_file%.*}"
    cat $encoded_file | base64 --decode | gunzip > /tmp/addons/$yaml_file
    rm -f $encoded_file
done

# Get all the bootstrap files and base64 decode
mkdir -p /bootstrap_data && cd /bootstrap_data
aws s3 cp s3://${s3_bootstrap_user_data_bucket}/ ./ --recursive --exclude "*" --include "*master-kubernetes*" --include "*primary-master-kubernetes*"
if [ -f "master-kubernetes-calico-encoded.enc" ];then
    cat master-kubernetes-calico-encoded.enc | base64 --decode | gunzip > /tmp/calico.yaml
fi
if [[ -f "primary-master-kubernetes-bootstrap-script.enc" ]]; then
    cat primary-master-kubernetes-bootstrap-script.enc | base64 --decode | gunzip > master-kubernetes-bootstrap-script.sh
    chmod +x master-kubernetes-bootstrap-script.sh
    ./master-kubernetes-bootstrap-script.sh
fi