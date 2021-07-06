#!/bin/bash

exec &> /var/log/bootstrap-nat64.log

set -o verbose
set -o errexit
set -o pipefail

# Variables get interpolated
export NAT64_CIDR="${nat64_ipv6_cidr}"
export VPC_CIDR="${vpc_ipv6_cidr}"

set -o nounset

## -------------------------------------------
## Install pre-requisites
## -------------------------------------------
apt update
apt upgrade -y
apt install -y build-essential pkg-config linux-headers-$(uname -r) libnl-genl-3-dev libxtables-dev dkms git autoconf selinux-utils libtool net-tools bind9 bind9-doc dnsutils tar curl
apt autoremove

export LOCAL_IP_ADDRESS=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)

## -------------------------------------------
## Kernel settings
## -------------------------------------------
# Enable forwarding for IPv4 and IPv6
cat <<EOF | tee /etc/sysctl.d/99-jool.conf
net.ipv4.conf.all.forwarding        = 1
net.ipv6.conf.all.forwarding        = 1
net.ipv4.ip_local_port_range        = "32768 40000"
EOF
sysctl --system

# setenforce returns non zero if already SE Linux is already disabled
is_enforced=$(getenforce)
if [[ $is_enforced != "Disabled" ]]; then
  setenforce 0
  sed -i 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config
fi

## -------------------------------------------
## Setting up NAT64
## -------------------------------------------
# Setup jool as a service
cat <<EOF | tee /etc/jool.conf
JOOL_IPV4_ADDRESS="$LOCAL_IP_ADDRESS"
JOOL_IPV6_POOL="$NAT64_CIDR"
JOOL_INSTANCE_NAME="nat64"
JOOL_NAPT_START="40001"
JOOL_NAPT_END="65535"
EOF

cat <<EOF | tee /etc/systemd/system/jool.service
[Unit]
Description=Jool - NAT64 Service
Requires=rc-local.service
After=network.target rc-local.service

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=/etc/jool.conf
ExecStart=/bin/sh -ec '\
    /sbin/modprobe jool; \
    /usr/local/bin/jool instance add "\$JOOL_INSTANCE_NAME" --iptables --pool6 \$JOOL_IPV6_POOL; \
    /sbin/ip6tables -t mangle -A PREROUTING -j JOOL --instance "\$JOOL_INSTANCE_NAME"; \
    /sbin/iptables  -t mangle -A PREROUTING -j JOOL --instance "\$JOOL_INSTANCE_NAME"; \
    /usr/local/bin/jool -i "\$JOOL_INSTANCE_NAME" pool4 add \$JOOL_IPV4_ADDRESS \$JOOL_NAPT_START-\$JOOL_NAPT_END --tcp; \
    /usr/local/bin/jool -i "\$JOOL_INSTANCE_NAME" pool4 add \$JOOL_IPV4_ADDRESS \$JOOL_NAPT_START-\$JOOL_NAPT_END --udp; \
    /usr/local/bin/jool -i "\$JOOL_INSTANCE_NAME" pool4 add \$JOOL_IPV4_ADDRESS \$JOOL_NAPT_START-\$JOOL_NAPT_END --icmp '

ExecStop=/sbin/ip6tables -t mangle -F
ExecStop=/sbin/iptables  -t mangle -F
ExecStop=/usr/local/bin/jool instance remove "\$JOOL_INSTANCE_NAME"
ExecStop=/sbin/modprobe -r jool

[Install]
WantedBy=multi-user.target
EOF

# Hook into rc-local.service so it loads /etc/rc.local
# This is needed to load the kernel module
cat <<EOF | tee /etc/rc.local
#!/bin/bash

set -o errexit
set -o pipefail

if ! /sbin/dkms status | grep 'jool' >/dev/null; then
  wget https://jool.mx/download/jool-4.1.5.tar.gz -O /tmp/jool-4.1.5.tar.gz && tar -xzf /tmp/jool-4.1.5.tar.gz -C /tmp
  /sbin/dkms install /tmp/jool-4.1.5/
  modprobe jool
  cd /tmp/jool-4.1.5
  ./configure
  make
  make install
else
  echo "Jool already loaded !"
fi

exit 0
EOF
chmod +x /etc/rc.local

cat <<EOF | tee /etc/systemd/system/rc-local.service
[Unit]
Description=/etc/rc.local Compatibility
After=network.target
ConditionPathExists=/etc/rc.local

[Service]
Type=forking
ExecStart=/etc/rc.local start
TimeoutSec=0
StandardOutput=tty
RemainAfterExit=yes
GuessMainPID=no

[Install]
WantedBy=multi-user.target
EOF

systemctl enable jool
systemctl enable rc-local

## -------------------------------------------
## Setting up DNS64
## -------------------------------------------

cat <<EOF | tee /etc/bind/named.conf.options
acl translator {
        # Please list all the translator's addresses here.
        localhost;
};
acl dns64-good-clients {
        # Please list here the clients that should be allowed to query
        # the DNS64 service.
        # "localnets" is a convenient moniker for devices sharing a
        # network with our DNS64.
        localnets;
        $VPC_CIDR;
};

options {
        # Ubuntu BIND's default options.
        directory "/var/cache/bind";
        recursion yes;
        auth-nxdomain no;    # conform to RFC1035
        listen-on-v6 { any; };

        forwarders { 8.8.8.8; 8.8.4.4; };

        # Make sure our nameserver is not abused by external
        # malicious users.
        allow-query { dns64-good-clients; };

        # This enables DNS64
        dns64 $NAT64_CIDR {
                # Though serving standard DNS to the translator device
                # is perfectly normal, we want to exclude it from DNS64.
                # Why? Well, one reason is that the translator is
                # already connected to both IP protocols, so its own
                # traffic doesn't need 64:ff9b for anything.
                # But a more important reason is that Jool can only
                # translate on PREROUTING [0]; it specifically excludes
                # local traffic. If the Jool device itself attempts to
                # communicate with 64:ff9b, it will fail.
                # Listing !translator before our good clients here
                # ensures the translator is excluded from DNS64, even
                # when it belongs to the client networks.
                clients { !translator; dns64-good-clients; };
        };
};
EOF

systemctl restart bind9
systemctl enable bind9

# Reboot to pick up the latest kernel
reboot