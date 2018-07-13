#!/bin/bash

# Save trace setting
XTRACE=$(set +o | grep xtrace)
set -o xtrace

# ARGS:
# $1: IP of second interface of master
# $2: IP of second interface of minion
# $3: netmask
# $4: Hostname of specific minion
# $5: Gateway IP

MASTER_OVERLAY_IP=$1
PUBLIC_IP=$2
PUBLIC_SUBNET_MASK=$3
MINION_NAME=$4
GW_IP=$5
OVN_EXTERNAL=$6

if [ -n "$OVN_EXTERNAL" ]; then
    PUBLIC_IP=`ifconfig enp0s8 | grep 'inet addr' | cut -d: -f2 | awk '{print $1}'`
    PUBLIC_SUBNET_MASK=`ifconfig enp0s8 | grep 'inet addr' | cut -d: -f4`
    GW_IP=`grep 'option routers' /var/lib/dhcp/dhclient.enp0s8.leases | head -1 | sed -e 's/;//' | awk '{print $3}'`
fi

MINION_OVERLAY_IP=$PUBLIC_IP

cat > setup_minion_args.sh <<EOL
MASTER_OVERLAY_IP=$MASTER_OVERLAY_IP
MINION_OVERLAY_IP=$MINION_OVERLAY_IP
PUBLIC_IP=$PUBLIC_IP
PUBLIC_SUBNET_MASK=$PUBLIC_SUBNET_MASK
MINION_NAME=$MINION_NAME
MINION_SUBNET=$MINION_SUBNET
GW_IP=$GW_IP
OVN_EXTERNAL=$OVN_EXTERNAL
EOL

# Comment out the next line if you prefer TCP instead of SSL.
SSL="true"

# FIXME(mestery): Remove once Vagrant boxes allow apt-get to work again
sudo rm -rf /var/lib/apt/lists/*

# Add external repos to install docker and OVS from packages.
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates
echo "deb http://18.191.116.101/openvswitch/stable /" |  sudo tee /etc/apt/sources.list.d/openvswitch.list
wget -O - http://18.191.116.101/openvswitch/keyFile |  sudo apt-key add -
sudo apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 58118E89F3A912897C070ADBF76221572C52609D
sudo su -c "echo \"deb https://apt.dockerproject.org/repo ubuntu-xenial main\" >> /etc/apt/sources.list.d/docker.list"
sudo apt-get update

# First, install docker
sudo apt-get purge lxc-docker
sudo apt-get install -y linux-image-extra-$(uname -r) linux-image-extra-virtual
sudo apt-get install -y docker-engine
sudo service docker start

# Install OVS and dependencies
sudo apt-get build-dep dkms
sudo apt-get install python-six openssl -y

sudo apt-get install openvswitch-datapath-dkms=2.9.2-1 -y
sudo apt-get install openvswitch-switch=2.9.2-1 openvswitch-common=2.9.2-1 libopenvswitch=2.9.2-1 -y
sudo -H pip install ovs

sudo apt-get install ovn-common=2.9.2-1 ovn-host=2.9.2-1 -y

if [ -n "$SSL" ]; then
    PROTOCOL=ssl
    echo "PROTOCOL=ssl" >> setup_minion_args.sh
    # Install certificates
    pushd /etc/openvswitch
    sudo ovs-pki req ovncontroller
    sudo ovs-pki -b -d /vagrant/pki sign ovncontroller switch
    popd
else
    PROTOCOL=tcp
    echo "PROTOCOL=tcp" >> setup_minion_args.sh
fi

# Install golang
wget -nv https://dl.google.com/go/go1.9.2.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.9.2.linux-amd64.tar.gz
export PATH="/usr/local/go/bin:echo $PATH"
export GOPATH=$HOME/work

# Setup CNI directory
sudo mkdir -p /opt/cni/bin/

# Install OVN+K8S Integration
mkdir -p $HOME/work/src/github.com/openvswitch
pushd $HOME/work/src/github.com/openvswitch
git clone https://github.com/openvswitch/ovn-kubernetes
popd
pushd $HOME/work/src/github.com/openvswitch/ovn-kubernetes/go-controller
make 1>&2 2>/dev/null
sudo make install
popd

# Install CNI
pushd ~/
wget -nv https://github.com/containernetworking/cni/releases/download/v0.5.2/cni-amd64-v0.5.2.tgz
popd
sudo mkdir -p /opt/cni/bin
pushd /opt/cni/bin
sudo tar xvzf ~/cni-amd64-v0.5.2.tgz
popd

# Create a kubeconfig file.
cat << KUBECONFIG >> ~/kubeconfig.yaml
apiVersion: v1
clusters:
- cluster:
    server: http://$MASTER_OVERLAY_IP:8080
  name: default-cluster
- cluster:
    server: http://$MASTER_OVERLAY_IP:8080
  name: local-server
- cluster:
    server: http://$MASTER_OVERLAY_IP:8080
  name: ubuntu
contexts:
- context:
    cluster: ubuntu
    user: ubuntu
  name: ubuntu
current-context: ubuntu
kind: Config
preferences: {}
users:
- name: ubuntu
  user:
    password: p1NVMZqhOOOqkWQq
    username: admin
KUBECONFIG

# Start k8s daemons
pushd k8s/server/kubernetes/server/bin
echo "Starting kubelet ..."
nohup sudo ./kubelet --kubeconfig $HOME/kubeconfig.yaml \
                     --v=2 --address=0.0.0.0 \
                     --fail-swap-on=false \
                     --runtime-cgroups=/systemd/system.slice \
                     --kubelet-cgroups=/systemd/system.slice \
                     --enable-server=true --network-plugin=cni \
                     --cni-conf-dir=/etc/cni/net.d \
                     --cni-bin-dir="/opt/cni/bin/" >/tmp/kubelet.log 2>&1 0<&- &
popd

# Initialize the minion and gateway.
if [ $PROTOCOL = "ssl" ]; then
  SSL_ARGS="-nb-client-privkey /etc/openvswitch/ovncontroller-privkey.pem \
    -nb-client-cert /etc/openvswitch/ovncontroller-cert.pem \
    -nb-client-cacert /etc/openvswitch/ovnnb-ca.cert \
    -sb-client-privkey /etc/openvswitch/ovncontroller-privkey.pem \
    -sb-client-cert /etc/openvswitch/ovncontroller-cert.pem \
    -sb-client-cacert /etc/openvswitch/ovnsb-ca.cert"
fi

nohup sudo ovnkube -k8s-kubeconfig $HOME/kubeconfig.yaml -loglevel=4 \
    -logfile="/var/log/openvswitch/ovnkube.log" \
    -k8s-apiserver="http://$MASTER_OVERLAY_IP:8080" \
    -init-node="$MINION_NAME"  \
    -nodeport \
    -nb-address="$PROTOCOL://$MASTER_OVERLAY_IP:6641" \
    -sb-address="$PROTOCOL://$MASTER_OVERLAY_IP:6642" \
    ${SSL_ARGS} \
    -k8s-token="test" \
    -init-gateways -gateway-interface=enp0s8 -gateway-nexthop="$GW_IP" \
    -service-cluster-ip-range=172.16.1.0/24 \
    -cluster-subnet="192.168.0.0/16" 2>&1 &

sleep 10

# Restore xtrace
$XTRACE
