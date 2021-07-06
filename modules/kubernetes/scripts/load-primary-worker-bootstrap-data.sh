#!/bin/bash

exec &> /var/log/load-bootstrap-user-data.log

set -o verbose
set -o errexit
set -o pipefail

# Install pre-requisites
apt update
apt upgrade -qy
apt install -qy awscli

mkdir -p /bootstrap_data && cd /bootstrap_data
aws s3 cp s3://${s3_bootstrap_user_data_bucket}/ ./ --recursive --exclude "*" --include "*primary-worker-kubernetes*"

if [[ -f "primary-worker-kubernetes-bootstrap-script.enc" ]]; then
    cat primary-worker-kubernetes-bootstrap-script.enc | base64 --decode | gunzip > worker-kubernetes-bootstrap-script.sh
    chmod +x worker-kubernetes-bootstrap-script.sh
    ./worker-kubernetes-bootstrap-script.sh
fi