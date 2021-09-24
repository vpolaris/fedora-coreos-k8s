#!/bin/bash

conf_dir="/root/.k8s-install/config"
mkdir -p "${conf_dir}"
log_file="/root/.k8s-install//k8s-init.log"
export NETDEVICE="$(ip -br link | grep -Ev "^(lo|cni|veth|flannel|wlan)" | awk '{print $1}')"
export IPV4="$(ip -4 -br a s ${NETDEVICE} | awk '{print $3}' | cut -d'/' -f1)"
export NETRANGE="$(echo $IPV4|cut -d'.' -f1-3)"
export KUBECONFIG=/etc/kubernetes/admin.conf

#Install CRI-O
printf " CRI-O installtion started.\n "
curl -sSL https://raw.githubusercontent.com/cri-o/cri-o/main/scripts/get -o /tmp/get
sh /tmp/get -a arm64 -t v1.21.0 > ${log_file}

#install K8S and avahi
printf "  K8S and avahi deplyment started.\n "
rpm-ostree refresh-md
rpm-ostree install conntrack kubelet-1.21.5 kubeadm-1.21.5 kubectl-1.21.5 avahi avahi-tools nss-mdns --allow-inactive

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