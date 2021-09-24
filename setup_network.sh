conf_dir="/root/.k8s-install/config"
log_file="/root/.k8s-install//k8s-init.log"

#Deploy flannel
#https://github.com/flannel-io/flannel
printf "Flannel installtion started.\n "
PATCH="{\"spec\":{\"podCIDR\":\"${PODCIDR}\"}}"
kubectl patch node $(hostname) -p "${PATCH}"
curl -sSL https://raw.githubusercontent.com/vpolaris/fedora-coreos-k8s/main/config/flannel-arm64.yml -o "/tmp/flannel-arm64.template"
envsubst '${PODCIDR}' < /tmp/flannel-arm64.template > "${conf_dir}/flannel-arm64.yaml"
kubectl apply -f "${conf_dir}/flannel-arm64.yaml"
mv "${conf_dir}/flannel-arm64.yaml" "${conf_dir}/flannel-arm64.yaml.bkp"


HLBIN="/usr/local/bin/helm"

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

KUBCONFIG="${SHARE}/kubejoin.ini"
printf "NETDEVICE=${NETDEVICE}\n" > ${KUBCONFIG}
printf "HOSTNAME=$(hostname -f)\n" >> ${KUBCONFIG}
printf "IPV4=${IPV4}\n" >> ${KUBCONFIG}
printf "TOKEN=${TOKEN}\n" >> ${KUBCONFIG}
printf "SHA=${SHA}\n" >> ${KUBCONFIG}
chown core:core ${KUBCONFIG}
chmod 766 ${KUBCONFIG}

systemctl disable install-k8s-3stage.service