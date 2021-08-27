#!/bin/bash
mkdir -p /root/.k8s-install/config
sed -i -z s+/usr/share/containers/oci/hooks.d+/etc/containers/oci/hooks.d+ /etc/crio/crio.conf
printf "KUBELET_EXTRA_ARGS=--cgroup-driver=systemd\n" | tee /etc/sysconfig/kubelet

export c_version="$(rpm -qi cri-o | grep Version | cut  -d':' -f2 |xargs)"
export k_version="$(echo v"$(rpm -qi kubeadm | grep Version | cut  -d':' -f2 |xargs)")"

systemctl enable --now cri-o && systemctl enable --now kubelet


curl -sSL https://raw.githubusercontent.com/vpolaris/fedora-coreos-k8s/main/config/cluster_template.yml -o /tmp/cluster_template
envsubst '${k_version}' < /tmp/cluster_template > /root/.k8s-install/config/clusterconfig.yml
kubeadm init phase kubelet-start
kubeadm init --config /root/.k8s-install/config/clusterconfig.yml > /tmp/k8s-init.log

if [ '$(grep "Your Kubernetes control-plane has initialized successfully!" /tmp/k8s-init.log)'!="" ]; then
  export KDATA=$(tail -2 /tmp/k8s-init.log |tr '\n' '\r' |sed -r s'/.* --token (.*) \\\r.* sha256:/\1 /'|tr '\r' '\n')
  read -r TOKEN SHA <<< "${KDATA}"

else
  printf 'installation of k8s cluster failed'
  exit 1
fi
echo 'export KUBECONFIG=/etc/kubernetes/admin.conf' > ~/.bash_profile
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl completion bash >/etc/bash_completion.d/kubectl
systemctl disable install-k8s-1stage.service
rm /root/.k8s-install/1stage


kubectl taint nodes --all node-role.kubernetes.io/master-
kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
NETDEVICE="$(ip -br link | grep -Ev "^(lo|cni|veth|flannel|wlan)" | awk '{print $1}')"
IPV4="$(ip -4 -br a s ${NETDEVICE} | awk '{print $3}' | cut -d'/' -f1)"
echo $IPV4 "$(hostname --short)".local >> /etc/avahi/hosts

iptables -P FORWARD ACCEPT
iptables -A INPUT -p udp -m udp --dport 5353 -j ACCEPT
iptables -A INPUT -p tcp -m tcp --dport 8089 -j ACCEPT
iptables-save > /etc/sysconfig/iptables

podman pull -q  docker.io/pierrezemb/gostatic
podman run -d -p 8089:8043 -v /var/srv/share:/srv/http --name goStatic pierrezemb/gostatic

printf "NETDEVICE=${NETDEVICE}\n" > /srv/share/kubejoin.ini
printf "HOSTNAME=$(hostname -f)\n" >> /srv/share/kubejoin.ini
printf "IPV4=${IPV4}\n" >> /srv/share/kubejoin.ini
printf "TOKEN=${TOKEN}\n" >> /srv/share/kubejoin.ini
printf "SHA=${SHA}\n" >> /srv/share/kubejoin.ini

curl -sSL https://raw.githubusercontent.com/vpolaris/fedora-coreos-k8s/main/config/http.service -o /etc/avahi/services/http.service
