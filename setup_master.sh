#!/bin/bash

#Initialize script environment
conf_dir="/root/.k8s-install/config"
log_file="/tmp/k8s-init.log"
export PODCIDR="10.244.0.0/16"
export SVCIDR="10.96.0.0/12"
# export c_version="$(rpm -qi cri-o | grep Version | cut  -d':' -f2 |xargs)"
export k_version="$(echo v"$(rpm -qi kubeadm | grep Version | cut  -d':' -f2 |xargs)")"
export TOKEN="$(kubeadm token create)"
export NETDEVICE="$(ip -br link | grep -Ev "^(lo|cni|veth|flannel|wlan)" | awk '{print $1}')"
export IPV4="$(ip -4 -br a s ${NETDEVICE} | awk '{print $3}' | cut -d'/' -f1)"
export NETRANGE="$(echo $IPV4|cut -d'.' -f1-f3)"
export HOSTNAME="$(hostname -f)"
echo $IPV4 "$(hostname --short)".local >> /etc/avahi/hosts

mkdir -p "${conf_dir}"

#Copy service file
cp /usr/lib/systemd/system/kubelet.service /etc/systemd/system/
chmod 644 /etc/systemd/system/kubelet.service

#install CRI-O
curl -sSL https://raw.githubusercontent.com/cri-o/cri-o/main/scripts/get -o /tmp/get
sh /tmp/get -a arm64 -t v1.21.0
rm /etc/cni/net.d/10-crio-bridge.conf

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
kubeadm init --config "${conf_dir}/Kubernetes.yaml" --v=3 > ${log_file}
if [ "$(grep 'Your Kubernetes control-plane has initialized successfully!' /tmp/k8s-init.log)" != "" ]; then
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

systemctl disable install-k8s-1stage.service

#Setup k8s environment fore user core
mkdir -p /home/core/.kube
sudo cp -i /etc/kubernetes/admin.conf /home/core/.kube/config
sudo chown -R core:core /home/core/.kube

rm /root/.k8s-install/1stage
kubectl taint nodes --all node-role.kubernetes.io/master-

sleep 120

#Deploy flannel
#https://github.com/flannel-io/flannel
printf "Flannel installtion started.\n "
PATCH="{\"spec\":{\"podCIDR\":\"${PODCIDR}/24\"}}"
kubectl patch node $(hostname) -p "${PATCH}"
curl -sSL https://raw.githubusercontent.com/vpolaris/fedora-coreos-k8s/main/config/flannel-arm64.yml -o "/tmp/flannel-arm64.template"
envsubst '${PODCIDR}' < /tmp/flannel-arm64.template > "${conf_dir}/flannel-arm64.yaml"
kubectl apply -f "${conf_dir}/flannel-arm64.yaml"
mv "${conf_dir}/flannel-arm64.yaml" "${conf_dir}/flannel-arm64.yaml.bkp"

# kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml >> ${log_file}
# kubectl patch configmaps -n kube-system kube-flannel-cfg  -p '{"data": {"net-conf.json": "{\n  \"Network\": \"10.11.0.0/16\",\n  \"Backend\": {\n    \"Type\": \"vxlan\"\n  }\n}\n"}}'

sleep 120

#Install Helm
#https://helm.sh/docs/intro/install/
printf " Helm installtion started.\n "
echo "HELM_KUBECONFIG=${KUBECONFIG}" >> /etc/profile.d/helm.sh
echo "HELM_APISERVER=${IPV4}:6443" >> /etc/profile.d/helm.sh
source /etc/profile.d/helm.sh
curl -fsSL https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 -o /tmp/get_helm.sh
chmod 700 /tmp/get_helm.sh
sh /tmp/get_helm.sh
HLBIN="/usr/local/bin/helm"
${HLBIN} completion bash > /etc/bash_completion.d/helm

printf " Helm setup started.\n "
${HLBIN} repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
${HLBIN} repo add metallb https://metallb.github.io/metallb
${HLBIN} repo add haproxy-ingress https://haproxy-ingress.github.io/charts
${HLBIN} repo update

#Deploy Ingress NGINX
#https://kubernetes.github.io/ingress-nginx/deploy/

printf " Ingress NGINX installtion started.\n "

${HLBIN} install ingress-nginx ingress-nginx/ingress-nginx --create-namespace -n network >> ${log_file}
# kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.0.0/deploy/static/provider/baremetal/deploy.yaml

POD_NAME=$(kubectl get pods -l app.kubernetes.io/name=ingress-nginx -n network -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n network -it $POD_NAME -- /nginx-ingress-controller  --version >> ${log_file}

sleep 120

#Deploy MetalLB
#https://metallb.universe.tf/
printf "MetalLB installtion started.\n "
MLBCONFIG="${conf_dir}/metallb_values.yaml"
# cat << EOF | kubectl apply -f -
cat << EOF > ${MLBCONFIG}
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: -n network
  name: config
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - ${NETRANGE}.210-${NETRANGE}.254
EOF

kubectl create secret generic -n network metallb-memberlist --from-literal=secretkey="$(openssl rand -base64 128)"  
${HLBIN} install metallb metallb/metallb -n network -f ${MLBCONFIG} >> ${log_file}
# kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.10.2/manifests/namespace.yaml
# kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.10.2/manifests/metallb.yaml
    
mv "${MLBCONFIG}" "${MLBCONFIG}.bkp"

sleep 120

#Install HAProxy
printf "HAProxy installtion started.\n "
HACONFIG="${conf_dir}/haproxy-ingress-values.yaml"
echo -e "controller:\\n  hostNetwork: true" > ${HACONFIG}
${HLBIN} install haproxy-ingress haproxy-ingress/haproxy-ingress -n network -f "${HACONFIG}" >> ${log_file}
mv "${HACONFIG}"  "${HACONFIG}.bkp"

#Setup network rules
iptables -P FORWARD ACCEPT
iptables -A INPUT -p udp -m udp --dport 5353 -j ACCEPT
iptables -A INPUT -p tcp -m tcp --dport 8089 -j ACCEPT
iptables-save > /etc/sysconfig/iptables

#Setup mDNS web server
printf "Setup mDNS web server.\n "
SHARE="/var/srv/share"
mkdir -p ${SHARE}
curl -sSL https://raw.githubusercontent.com/vpolaris/fedora-coreos-k8s/main/config/http.service -o /etc/avahi/services/http.service
curl -sSL https://raw.githubusercontent.com/vpolaris/fedora-coreos-k8s/main/config/web_mdns_server.yaml -o /tmp/web_mdns_server.template
envsubst '${HOSTNAME}' < /tmp/web_mdns_server.template > "${conf_dir}/web_mdns_server.yaml"
kubectl apply -f "${conf_dir}/web_mdns_server.yaml"
# podman pull -q  docker.io/pierrezemb/gostatic
# podman run -dt -p 8089:8043 -v ${SHARE}:/srv/http --name goStatic pierrezemb/gostatic

KUBCONFIG="${SHARE}/kubejoin.ini"
printf "NETDEVICE=${NETDEVICE}\n" > ${KUBCONFIG}
printf "HOSTNAME=$(hostname -f)\n" >> ${KUBCONFIG}
printf "IPV4=${IPV4}\n" >> ${KUBCONFIG}
printf "TOKEN=${TOKEN}\n" >> ${KUBCONFIG}
printf "SHA=${SHA}\n" >> ${KUBCONFIG}
chown core:core ${KUBCONFIG}
chmod 766 ${KUBCONFIG}

printf "Setup K8S master completed.\n "
