#!/bin/bash

exec &> /var/log/bootstrap-kubernetes-master.log

set -o verbose
set -o errexit
set -o pipefail

# Variables get interpolated
export AWS_REGION=${aws_region}
export KUBERNETES_VERSION="${kubernetes_version}"
export KUBERNETES_API_SERVER_PORT="${kubernetes_api_server_port}"
export KUBEADM_TOKEN=${kubeadm_token}
export DNS_NAME=${dns_name}
export CLUSTER_NAME=${cluster_name}
export POD_SUBNET_CIDR="${pod_subnet_cidr}"
export SERVICE_SUBNET_CIDR="${service_subnet_cidr}"
export DNS64_HOST_IP="${dns64_host_ip}"

export ASG_NAME=${asg_name}
export ASG_MIN_NODES="${asg_min_nodes}"
export ASG_MAX_NODES="${asg_max_nodes}"

# Set this only after setting the defaults
set -o nounset

# Get information from EC2 metadata
LOCAL_IPV4_ADDRESS=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
FULL_HOSTNAME="$(curl -s http://169.254.169.254/latest/meta-data/hostname)"
MAC_ADDRESS=$(curl -s http://169.254.169.254/latest/meta-data/mac)
LOCAL_IPV6_ADDRESS=$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/$MAC_ADDRESS/ipv6s)
arr=($LOCAL_IPV6_ADDRESS)
# If multiple IPv6s just pick the first on the list
if [ $${#arr[@]} -ge 2 ]; then
  LOCAL_IPV6_ADDRESS=$${arr[0]}
fi

# Make DNS lowercase
DNS_NAME=$(echo "$DNS_NAME" | tr 'A-Z' 'a-z')

# Install pre-requisites
apt update
apt upgrade -qy
apt install -qy curl wget net-tools selinux-utils apt-transport-https ca-certificates gnupg lsb-release

# ------------------------------------------
# Disable SELinux
# ------------------------------------------
# setenforce returns non zero if already SE Linux is already disabled
is_enforced=$(getenforce)
if [[ $is_enforced != "Disabled" ]]; then
  setenforce 0
  sed -i 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config
fi

# ------------------------------------------
# Configure DNS resolver
# ------------------------------------------
if [[ -f /etc/systemd/resolved.conf ]]; then
  sed -i "s/#DNS=/DNS=$DNS64_HOST_IP/g" /etc/systemd/resolved.conf
  service systemd-resolved restart
fi

# ------------------------------------------
# Install containerd
# ------------------------------------------
cat <<EOF | tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# Setup required sysctl params, these persist across reboots.
cat <<EOF | tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv6.conf.all.forwarding        = 1
EOF

# Apply sysctl params without reboot
sysctl --system

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo \
  "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
apt update -qy
apt install -qy containerd.io
apt-mark hold containerd.io

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i '/^          \[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\.runtimes\.runc\.options\]/a \            SystemdCgroup = true' /etc/containerd/config.toml
systemctl restart containerd

# ------------------------------------------
# Install calicoctl
# ------------------------------------------
curl -o /usr/local/bin/calicoctl -O -L  "https://github.com/projectcalico/calicoctl/releases/download/v3.19.1/calicoctl" 
chmod +x /usr/local/bin/calicoctl

# ------------------------------------------
# Install Kubernetes components
# ------------------------------------------
curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | tee /etc/apt/sources.list.d/kubernetes.list
apt update -qy
apt install -qy kubelet=$KUBERNETES_VERSION-00 kubectl=$KUBERNETES_VERSION-00 kubeadm=$KUBERNETES_VERSION-00
apt-mark hold kubelet kubeadm kubectl 

# Start services
systemctl enable kubelet
systemctl start kubelet

# ------------------------------------------
# Initialize the cluster
# ------------------------------------------
cat >/tmp/kubeadm.yaml <<EOF
---
apiVersion: kubeadm.k8s.io/v1beta2
kind: InitConfiguration
bootstrapTokens:
- groups:
  - system:bootstrappers:kubeadm:default-node-token
  token: $KUBEADM_TOKEN
  ttl: 0s
  usages:
  - signing
  - authentication
localAPIEndpoint:
  advertiseAddress: "::"
  bindPort: $KUBERNETES_API_SERVER_PORT
nodeRegistration:
  name: $FULL_HOSTNAME
  criSocket: "/run/containerd/containerd.sock"
  kubeletExtraArgs:
    node-ip: "::"
    read-only-port: "10255"
    fail-swap-on: "false"
    container-runtime: remote
    container-runtime-endpoint: unix:///run/containerd/containerd.sock
    cgroup-driver: systemd
    v: "4"
  taints:
  - effect: NoSchedule
    key: node-role.kubernetes.io/master
---
apiVersion: kubeadm.k8s.io/v1beta2
kind: ClusterConfiguration
clusterName: $CLUSTER_NAME
imageRepository: k8s.gcr.io
kubernetesVersion: v$KUBERNETES_VERSION
certificatesDir: /etc/kubernetes/pki
apiServer:
  certSANs:
  - $LOCAL_IPV6_ADDRESS
  - $DNS_NAME
  - $LOCAL_IPV4_ADDRESS
  - $FULL_HOSTNAME
  extraArgs:
    bind-address: "::"
  timeoutForControlPlane: 5m0s
  extraArgs:
controllerManager:
  extraArgs:
    bind-address: "::"
    configure-cloud-routes: "false"
networking:
  dnsDomain: cluster.local
  podSubnet: $POD_SUBNET_CIDR
  serviceSubnet: $SERVICE_SUBNET_CIDR
dns:
  type: CoreDNS
etcd:
  local:
    dataDir: /var/lib/etcd
scheduler:
  extraArgs:
    address: "::"
    bind-address: "::1"
    v: "4"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
address: "::"
healthzBindAddress: "::"
imageGCHighThresholdPercent: 100
evictionHard:
  nodefs.available: "0%"
  nodefs.inodesFree: "0%"
  imagefs.available: "0%"
EOF

kubeadm reset --force
kubeadm init --config /tmp/kubeadm.yaml

# Use the local kubectl config for further kubectl operations
export KUBECONFIG=/etc/kubernetes/admin.conf

# Install calico
kubectl apply -f /tmp/calico.yaml
rm -f /tmp/calico.yaml

# ------------------------------------------
# Create user and kubeconfig files
# ------------------------------------------
# Allow the user to administer the cluster
kubectl create clusterrolebinding admin-cluster-binding --clusterrole=cluster-admin --user=$CLUSTER_NAME-admin

# Prepare the kubectl config file for download to client (IP address)
mkdir -p /home/ubuntu/.kube
export KUBECONFIG_IP_OUTPUT=/home/ubuntu/.kube/config_ip
export KUBECONFIG_OUTPUT=/home/ubuntu/.kube/config
kubeadm alpha kubeconfig user --client-name admin --config /tmp/kubeadm.yaml > $KUBECONFIG_IP_OUTPUT
cp $KUBECONFIG_IP_OUTPUT $KUBECONFIG_OUTPUT
sed -i "s/server: https:\/\/.*:$KUBERNETES_API_SERVER_PORT/server: https:\/\/$LOCAL_IPV6_ADDRESS:$KUBERNETES_API_SERVER_PORT/g" $KUBECONFIG_IP_OUTPUT
sed -i "s/server: https:\/\/.*:$KUBERNETES_API_SERVER_PORT/server: https:\/\/$DNS_NAME:$KUBERNETES_API_SERVER_PORT/g" $KUBECONFIG_OUTPUT
chown ubuntu:ubuntu $KUBECONFIG_IP_OUTPUT
chmod 0600 $KUBECONFIG_IP_OUTPUT
chown ubuntu:ubuntu $KUBECONFIG_OUTPUT
chmod 0600 $KUBECONFIG_OUTPUT
cp -f $KUBECONFIG_OUTPUT /home/ubuntu/kubeconfig
chown ubuntu:ubuntu /home/ubuntu/kubeconfig

# ------------------------------------------
# Install addons
# ------------------------------------------
files=$(shopt -s nullglob dotglob; echo /tmp/addons/*)
if [[ $${#files} ]]; then
  kubectl apply -f /tmp/addons
  rm -rf /tmp/addons
fi

apt autoremove