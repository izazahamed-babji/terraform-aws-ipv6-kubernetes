#!/bin/bash

exec &> /var/log/bootstrap-kubernetes-worker.log

set -o verbose
set -o errexit
set -o pipefail

# Variables get interpolated
export AWS_REGION=${aws_region}
export KUBERNETES_VERSION="${kubernetes_version}"
export KUBERNETES_API_SERVER_PORT="${kubernetes_api_server_port}"
export KUBEADM_TOKEN=${kubeadm_token}
export MASTER_IP=${master_ip}
export DNS_NAME=${dns_name}
export DNS64_HOST_IP="${dns64_host_ip}"

# Set this only after setting the defaults
set -o nounset

# We to match the hostname expected by kubeadm an the hostname used by kubelet
LOCAL_IP_ADDRESS=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
FULL_HOSTNAME="$(curl -s http://169.254.169.254/latest/meta-data/hostname)"
EC2_INSTANCE_ID="$(curl -s http://169.254.169.254/latest/meta-data/instance-id)"

# Disable Source-Dest checks
aws ec2 modify-instance-attribute --no-source-dest-check --instance-id $EC2_INSTANCE_ID --region $AWS_REGION

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
# Joining the cluster
# ------------------------------------------
cat >/tmp/kubeadm.yaml <<EOF
---
apiVersion: kubeadm.k8s.io/v1beta2
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: "[$MASTER_IP]:$KUBERNETES_API_SERVER_PORT"
    token: $KUBEADM_TOKEN
    unsafeSkipCAVerification: true
  timeout: 5m0s
  tlsBootstrapToken: $KUBEADM_TOKEN
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
    v: "5"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
address: "::"
healthzBindAddress: "::"
cgroupDriver: systemd
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeProxyConfiguration
bindAddress: "::"
---
EOF

kubeadm reset --force
kubeadm join --config /tmp/kubeadm.yaml

apt autoremove