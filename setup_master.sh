#!/bin/bash

#Initialize script environment
conf_dir="/root/.k8s-install/config"
export c_version="$(rpm -qi cri-o | grep Version | cut  -d':' -f2 |xargs)"
export k_version="$(echo v"$(rpm -qi kubeadm | grep Version | cut  -d':' -f2 |xargs)")"
export TOKEN="$(kubeadm token create)"
export NETDEVICE="$(ip -br link | grep -Ev "^(lo|cni|veth|flannel|wlan)" | awk '{print $1}')"
export IPV4="$(ip -4 -br a s ${NETDEVICE} | awk '{print $3}' | cut -d'/' -f1)"
export NETRANGE="$(echo $IPV4|cut -d'.' -f1-3)"
kubeadm init phase certs all
export SHA="$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //')"
echo $IPV4 "$(hostname --short)".local >> /etc/avahi/hosts

#Copy service file
cp /usr/lib/systemd/system/kubelet.service /etc/systemd/system/
chmod 644 /usr/lib/systemd/system/kubelet.service

#Initialize services
sed -i -z s+/usr/share/containers/oci/hooks.d+/etc/containers/oci/hooks.d+ /etc/crio/crio.conf
systemctl daemon-reload
systemctl enable --now cri-o && systemctl enable --now kubelet

#Retreive pi master config
mkdir -p "${conf_dir}"
# curl -sSL https://raw.githubusercontent.com/vpolaris/fedora-coreos-k8s/main/config/cluster_template.yml -o /tmp/cluster_template.yaml
curl -sSL https://raw.githubusercontent.com/vpolaris/fedora-coreos-k8s/main/config/Cluster_Configuration.template -o /tmp/Cluster_Configuration.template
curl -sSL https://raw.githubusercontent.com/vpolaris/fedora-coreos-k8s/main/config/Init_Configuration.template -o /tmp/Init_Configuration.template
curl -sSL https://raw.githubusercontent.com/vpolaris/fedora-coreos-k8s/main/config/Kubelet_Configuration.template -o /tmp/Kubelet_Configuration.template
curl -sSL https://raw.githubusercontent.com/vpolaris/fedora-coreos-k8s/main/config/KubeProxy_Configuration.template -o /tmp/KubeProxy_Configuration.template

envsubst '${k_version} ${TOKEN} ${IPV4} ${SHA}' < /tmp/Cluster_Configuration.template > "${conf_dir}/Cluster_Configuration.yaml"
envsubst '${k_version} ${TOKEN} ${IPV4} ${SHA}' < /tmp/Init_Configuration.template > "${conf_dir}/Init_Configuration.yaml"
envsubst '${k_version} ${TOKEN} ${IPV4} ${SHA}' < /tmp/Kubelet_Configuration.template > "${conf_dir}/Kubelet_Configuration.yaml"
envsubst '${k_version} ${TOKEN} ${IPV4} ${SHA}' < /tmp/KubeProxy_Configuration.template > "${conf_dir}/KubeProxy_Configuration.yaml"

#YAML file's mergeing
for yaml in $(ls ${conf_dir}/*.yaml); do
  printf "process file $yaml\n"
  cat "${yaml}" >> "${conf_dir}/Kubernetes.yaml"
  echo "---"  >> "${conf_dir}/Kubernetes.yaml"
done

#Install Kubernetes
kubeadm init --config "${conf_dir}/Kubernetes.yaml" --v=3 > /tmp/k8s-init.log
if [ '$(grep "Your Kubernetes control-plane has initialized successfully!" /tmp/k8s-init.log)'!="" ]; then
  printf 'installation of k8s cluster success\n'
else
  printf 'installation of k8s cluster failed\n'
  exit 1
fi
rm "${conf_dir}/Kubernetes.yaml"
echo 'export KUBECONFIG=/etc/kubernetes/admin.conf' >> ~/.bash_profile
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl completion bash > /etc/bash_completion.d/kubectl
systemctl disable install-k8s-1stage.service

#Setup k8s environment fore user core
mkdir -p /home/core/.kube
sudo cp -i /etc/kubernetes/admin.conf /home/core/.kube/config
sudo chown core:core /home/core/.kube/config

rm /root/.k8s-install/1stage


# kubectl taint nodes --all node-role.kubernetes.io/master-
#Deploy flannel
kubectl patch node $(hostname) -p '{"spec":{"podCIDR":"10.11.0.0/16"}}'
kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
#Deploy Ingress NGINX
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.0.0/deploy/static/provider/baremetal/deploy.yaml
#Deploy MetalLB
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.10.2/manifests/namespace.yaml

kubectl apply -f - "apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: |     address-pools:
    - name: default
      protocol: layer2
      addresses:
      - ${NETRANGE}.210-${NETRANGE}.254"
      

#Install HAProxy
curl -fsSL https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 -o /tmp/get_helm.sh
chmod 700 /tmp/get_helm.sh
sh /tmp/get_helm.sh
/usr/local/bin/helm repo add haproxy-ingress https://haproxy-ingress.github.io/charts
echo -e "controller:\\n  hostNetwork: true" > "${conf_dir}/haproxy-ingress-values.yaml"
helm install haproxy-ingress haproxy-ingress/haproxy-ingress\
  --create-namespace --namespace ingress-controller\
  --version 0.13.1\
  -f "${conf_dir}/haproxy-ingress-values.yaml"

iptables -P FORWARD ACCEPT
iptables -A INPUT -p udp -m udp --dport 5353 -j ACCEPT
iptables -A INPUT -p tcp -m tcp --dport 8089 -j ACCEPT
iptables-save > /etc/sysconfig/iptables

#Setup mDNS web server
podman pull -q  docker.io/pierrezemb/gostatic
podman run -d -p 8089:8043 -v /var/srv/share:/srv/http --name goStatic pierrezemb/gostatic
curl -sSL https://raw.githubusercontent.com/vpolaris/fedora-coreos-k8s/main/config/http.service -o /etc/avahi/services/http.service


printf "NETDEVICE=${NETDEVICE}\n" > /srv/share/kubejoin.ini
printf "HOSTNAME=$(hostname -f)\n" >> /srv/share/kubejoin.ini
printf "IPV4=${IPV4}\n" >> /srv/share/kubejoin.ini
printf "TOKEN=${TOKEN}\n" >> /srv/share/kubejoin.ini
printf "SHA=${SHA}\n" >> /srv/share/kubejoin.ini
chown core:core /srv/share/kubejoin.ini
chmod 766 /srv/share/kubejoin.ini


