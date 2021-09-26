#!/bin/bash
CNI_VERSION="v1.0.1"
CRICTL_VERSION="v1.21.0"
KUBE_VERSION="v1.21.0"
DOWNLOAD_DIR=/usr/local/bin
ARCH="arm64"
conf_dir="/root/.k8s-install/config"
log_file="/root/.k8s-install//k8s-init.log"
export PODCIDR="10.244.0.0/16"
export NETDEVICE="$(ip -br link | grep -Ev "^(lo|cni|veth|flannel|wlan)" | awk '{print $1}')"
export IPV4="$(ip -4 -br a s ${NETDEVICE} | awk '{print $3}' | cut -d'/' -f1)"
export NETRANGE="$(echo $IPV4|cut -d'.' -f1-3)"
export KUBECONFIG=/etc/kubernetes/admin.conf


#Firewall rules
#https://kubernetes.io/docs/reference/ports-and-protocols/
#Kubernetes API server
iptables -A INPUT -p tcp -m tcp --dport 6443 -j ACCEPT
iptables -A OUTPUT -p tcp -m tcp --sport 6443 -j ACCEPT

#Kubelet API
iptables -A INPUT -p tcp -m tcp --dport 10250 -j ACCEPT
iptables -A OUTPUT -p tcp -m tcp --sport 10250 -j ACCEPT

#Kube Scheduler
iptables -A INPUT -p tcp -m tcp --dport 10259 -j ACCEPT
iptables -A OUTPUT -p tcp -m tcp --sport 10259 -j ACCEPT

#Kube Controller Manager
iptables -A INPUT -p tcp -m tcp --dport 10257 -j ACCEPT
iptables -A OUTPUT -p tcp -m tcp --sport 10257 -j ACCEPT

#Etcd server client API
iptables -A INPUT -p tcp -m tcp --dport 2379 -j ACCEPT
iptables -A OUTPUT -p tcp -m tcp --sport 2379 -j ACCEPT
iptables -A INPUT -p tcp -m tcp --dport 2380 -j ACCEPT
iptables -A OUTPUT -p tcp -m tcp --sport 2380 -j ACCEPT

#NodePort Services
iptables -A INPUT -p tcp --match multiport --dports 30000:32767 -j ACCEPT
iptables -A OUTPUT -p tcp --match multiport --sports 30000:32767 -j ACCEPT

iptables-save > /etc/sysconfig/iptables

mkdir -p /opt/cni/bin
mkdir -p "${conf_dir}"

#Install CNI Plugin
#https://github.com/containernetworking/plugins
curl -sSL  "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-${ARCH}-${CNI_VERSION}.tgz" | tar -C /opt/cni/bin-xz

#Install CRI-O
#https://github.com/kubernetes-sigs/cri-tools
printf " CRI-O installtion started.\n "
# curl -sSL https://raw.githubusercontent.com/cri-o/cri-o/main/scripts/get -o /tmp/get
# sh /tmp/get -a arm64 -t v1.21.0 > ${log_file}
curl -sSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz" | tar -C $DOWNLOAD_DIR -xz
crictl completion > /etc/bash_completion.d/crictl
curl -sSL "https://raw.githubusercontent.com/cri-o/cri-o/main/contrib/cni/11-crio-ipv4-bridge.conf" | sed "s:10.85.0.0/16:${DOWNLOAD_DIR}:g" | tee /etc/cni/net.d/11-crio-ipv4-bridge.conf 
curl -sSL "https://raw.githubusercontent.com/cri-o/cri-o/main/contrib/cni/99-loopback.conf" -o /etc/cni/net.d/99-loopback.conf
curl -sSL "https://raw.githubusercontent.com/cri-o/cri-o/main/contrib/systemd/crio.service" -o /etc/systemd/system/crio.service 

#Install  K8S
#https://kubernetes.io/docs/setup/production-environment/_print/#pg-a77d3feb6e6d9978f32fa14622642e9a
cd $DOWNLOAD_DIR
curl -sSL --remote-name-all https://storage.googleapis.com/kubernetes-release/release/${KUBE_VERSION}/bin/linux/${ARCH}/{kubeadm,kubelet,kubectl}
chmod u+x {kubeadm,kubelet,kubectl}
curl -sSL  https://raw.githubusercontent.com/kubernetes/release/master/cmd/kubepkg/templates/latest/rpm/kubelet/kubelet.service | sed "s:/usr/bin:${DOWNLOAD_DIR}:g" | tee /etc/systemd/system/kubelet.service

#Install conntrack and avahi
printf "  K8S and avahi deplyment started.\n "
rpm-ostree refresh-md
rpm-ostree install conntrack avahi avahi-tools nss-mdns --allow-inactive

#Install Helm
#https://helm.sh/docs/intro/install/
printf " Helm installtion started.\n "
echo "HELM_KUBECONFIG=${KUBECONFIG}" >> /etc/profile.d/helm.sh
echo "HELM_APISERVER=${IPV4}:6443" >> /etc/profile.d/helm.sh
source /etc/profile.d/helm.sh
curl -fsSL https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 -o /tmp/get_helm.sh
chmod 700 /tmp/get_helm.sh
sh /tmp/get_helm.sh >> ${log_file}
/usr/local/bin/helm completion bash > /etc/bash_completion.d/helm

systemctl disable install-k8s-1stage.service