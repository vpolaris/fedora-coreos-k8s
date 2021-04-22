#!/bin/bash

sed -i -z s+/usr/share/containers/oci/hooks.d+/etc/containers/oci/hooks.d+ /etc/crio/crio.conf
printf "KUBELET_EXTRA_ARGS=--cgroup-driver=systemd\n" | tee /etc/sysconfig/kubelet

systemctl enable --now cri-o && systemctl enable --now kubelet
export k_version=$(echo v"$(rpm -qi kubeadm | grep Version | cut  -d':' -f2 |xargs)")
mkdir -p /root/.k8s-install/config
curl -sSL https://raw.githubusercontent.com/vpolaris/fedora-coreos-k8s/main/config/cluster_template.yml -o /tmp/cluster_template
envsubst '${k_version}' < /tmp/cluster_template > /root/.k8s-install/config/clusterconfig.yml
kubeadm init --config /root/.k8s-install/config/clusterconfig.yml > /tmp/k8s-init.log
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl taint nodes --all node-role.kubernetes.io/master-
sysctl net.bridge.bridge-nf-call-iptables=1
kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
systemctl disable install-k8s-1stage.service
rm /root/.k8s-install/1stage