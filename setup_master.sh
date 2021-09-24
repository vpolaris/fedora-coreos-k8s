#!/bin/bash

#Initialize script environment
conf_dir="/root/.k8s-install/config"
log_file="/root/.k8s-install//k8s-init.log"
export PODCIDR="10.244.0.0/16"
export SVCIDR="10.96.0.0/12"
# export c_version="$(rpm -qi cri-o | grep Version | cut  -d':' -f2 |xargs)"
export k_version="$(echo v"$(rpm -qi kubeadm | grep Version | cut  -d':' -f2 |xargs)")"
export TOKEN="$(kubeadm token create)"
export NETDEVICE="$(ip -br link | grep -Ev "^(lo|cni|veth|flannel|wlan)" | awk '{print $1}')"
export IPV4="$(ip -4 -br a s ${NETDEVICE} | awk '{print $3}' | cut -d'/' -f1)"
export NETRANGE="$(echo $IPV4|cut -d'.' -f1-3)"
export HOSTNAME="$(hostname -f)"
echo $IPV4 "$(hostname --short)".local >> /etc/avahi/hosts



#Copy service file
cp /usr/lib/systemd/system/kubelet.service /etc/systemd/system/
chmod 644 /etc/systemd/system/kubelet.service


#Initialize services
sed -i -z s+/usr/share/containers/oci/hooks.d+/etc/containers/oci/hooks.d+ /etc/crio/crio.conf
systemctl daemon-reload
systemctl enable --now crio && systemctl enable --now kubelet

#Retreive pi master config

curl -sSL https://raw.githubusercontent.com/vpolaris/fedora-coreos-k8s/main/config/Cluster_Configuration.template -o /tmp/Cluster_Configuration.template
curl -sSL https://raw.githubusercontent.com/vpolaris/fedora-coreos-k8s/main/config/Init_Configuration.template -o /tmp/Init_Configuration.template
curl -sSL https://raw.githubusercontent.com/vpolaris/fedora-coreos-k8s/main/config/Kubelet_Configuration.template -o /tmp/Kubelet_Configuration.template
curl -sSL https://raw.githubusercontent.com/vpolaris/fedora-coreos-k8s/main/config/KubeProxy_Configuration.template -o /tmp/KubeProxy_Configuration.template

envsubst '${k_version} ${TOKEN} ${IPV4} ${SHA} ${PODCIDR} ${SVCIDR}' < /tmp/Cluster_Configuration.template > "${conf_dir}/Cluster_Configuration.yaml"
envsubst '${k_version} ${TOKEN} ${IPV4} ${SHA} ${HOSTNAME}' < /tmp/Init_Configuration.template > "${conf_dir}/Init_Configuration.yaml"
envsubst '${k_version} ${TOKEN} ${IPV4} ${SHA} ${PODCIDR}' < /tmp/Kubelet_Configuration.template > "${conf_dir}/Kubelet_Configuration.yaml"
envsubst '${k_version} ${TOKEN} ${IPV4} ${SHA} ${PODCIDR}' < /tmp/KubeProxy_Configuration.template > "${conf_dir}/KubeProxy_Configuration.yaml"

#YAML file's merging
for yaml in $(ls ${conf_dir}/*.yaml); do
  printf "process file $yaml\n"
  cat "${yaml}" >> "${conf_dir}/Kubernetes.yaml"
  echo "---"  >> "${conf_dir}/Kubernetes.yaml"
done

kubeadm init phase certs all --config "${conf_dir}/Kubernetes.yaml"
export SHA="$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //')"

#Install Kubernetes
printf "K8S installtion started.\n "
kubeadm init --config "${conf_dir}/Kubernetes.yaml" --v=3 >> ${log_file}
if [ "$(grep 'Your Kubernetes control-plane has initialized successfully!' ${log_file})" != "" ]; then
  printf 'installation of K8S master success\n'
else
  printf 'installation of K8S master failed\n'
  exit 1
fi

printf "Post K8S installtion steps.\n "
mv "${conf_dir}/Kubernetes.yaml" "${conf_dir}/Kubernetes.yaml.bkp"
echo 'export KUBECONFIG=/etc/kubernetes/admin.conf' >> ~/.bash_profile
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl completion bash > /etc/bash_completion.d/kubectl
source /etc/bash_completion.d/kubectl

#Setup k8s environment fore user core
mkdir -p /home/core/.kube
sudo cp -i /etc/kubernetes/admin.conf /home/core/.kube/config
sudo chown -R core:core /home/core/.kube

kubectl taint nodes --all node-role.kubernetes.io/master-

sleep 120

#Deploy flannel
#https://github.com/flannel-io/flannel
printf "Flannel installtion started.\n "
PATCH="{\"spec\":{\"podCIDR\":\"${PODCIDR}\"}}"
kubectl patch node $(hostname) -p "${PATCH}"
curl -sSL https://raw.githubusercontent.com/vpolaris/fedora-coreos-k8s/main/config/flannel-arm64.yml -o "/tmp/flannel-arm64.template"
envsubst '${PODCIDR}' < /tmp/flannel-arm64.template > "${conf_dir}/flannel-arm64.yaml"
kubectl apply -f "${conf_dir}/flannel-arm64.yaml"
mv "${conf_dir}/flannel-arm64.yaml" "${conf_dir}/flannel-arm64.yaml.bkp"

# kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml >> ${log_file}
# kubectl patch configmaps -n kube-system kube-flannel-cfg  -p '{"data": {"net-conf.json": "{\n  \"Network\": \"10.11.0.0/16\",\n  \"Backend\": {\n    \"Type\": \"vxlan\"\n  }\n}\n"}}'

printf "Setup K8S master completed.\n "

systemctl disable install-k8s-2stage.service