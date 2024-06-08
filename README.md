# 经GitHub将kubernetes镜像推送到阿里云

# 背景

在安装kubernetes时会出现无法访问镜像站的情况，通过GitHub将kubernetes镜像推送到阿里云之后，即可使用阿里云地址引用所需镜像，现已同步镜像5000+，当前还在陆续同步。

# 代码仓库

https://github.com/cby-chen/sys_images
若有需要自行研究 后续更新会在仓库更新


# 目前有如下镜像仓库，后续会陆续增加

```
images:
  docker.elastic.co:
    - elasticsearch/elasticsearch
    - kibana/kibana
    - logstash/logstash
    - beats/filebeat
    - beats/heartbeat
    - beats/packetbeat
    - beats/auditbeat
    - beats/journalbeat
    - beats/metricbeat
    - apm/apm-server
    - app-search/app-search
  quay.io:
    - coreos/flannel
    - ceph/ceph
    - cephcsi/cephcsi
    - csiaddons/k8s-sidecar
    - csiaddons/volumereplication-operator
    - prometheus/prometheus
    - prometheus/alertmanager
    - prometheus/pushgateway
    - prometheus/blackbox-exporter
    - prometheus/node-exporter
    - prometheus-operator/prometheus-config-reloader
    - prometheus-operator/prometheus-operator
    - brancz/kube-rbac-proxy
    - cilium/cilium
    - cilium/tetragon
    - cilium/operator
    - cilium/operator-generic
    - thanos/thanos
    - cilium/certgen
    - cilium/hubble-relay
    - cilium/hubble-ui
    - cilium/hubble-ui-backend
    - cilium/hubble-ui
    - cilium/cilium-envoy
    - cilium/cilium-etcd-operator
    - cilium/operator
    - cilium/startup-script
    - cilium/clustermesh-apiserver
    - coreos/etcd
  k8s.gcr.io:
    - dns/k8s-dns-node-cache
    - metrics-server/metrics-server
    - kube-state-metrics/kube-state-metrics
    - prometheus-adapter/prometheus-adapter
    - sig-storage/nfs-subdir-external-provisioner
    - sig-storage/csi-node-driver-registrar
    - sig-storage/csi-provisioner
    - sig-storage/csi-resizer
    - sig-storage/csi-snapshotter
    - sig-storage/csi-attacher
    - sig-storage/nfsplugin
  registry.k8s.io:
    - pause
    - etcd
    - conformance
    - kube-proxy
    - kube-apiserver
    - kube-scheduler
    - kube-controller-manager
    - coredns/coredns
    - ingress-nginx/controller
    - ingress-nginx/controller-chroot
    - ingress-nginx/kube-webhook-certgen
    - metrics-server/metrics-server
    - dns/k8s-dns-node-cache
    - sig-storage/nfs-subdir-external-provisioner
    - sig-storage/csi-node-driver-registrar
    - sig-storage/csi-provisioner
    - sig-storage/csi-resizer
    - sig-storage/csi-snapshotter
    - sig-storage/csi-attacher
    - kube-state-metrics/kube-state-metrics
    - prometheus-adapter/prometheus-adapter
  gcr.io:
    - kaniko-project/executor
    - google-samples/xtrabackup
  docker.io:
    - calico/node
    - calico/typha
    - calico/cni
    - calico/kube-controllers
    - calico/pod2daemon-flexvol
    - flannel/flannel
    - flannel/flannel-cni-plugin
  ghcr.io:
    - coroot/coroot
    - coroot/coroot-cluster-agent
    - coroot/coroot-node-agent
```

# 使用方式

```
docker.elastic.co/kibana/[镜像名称]:[版本版本号]  ==>  registry.aliyuncs.com/chenby/[镜像名称]:[版本版本号]
quay.io/csiaddons/[镜像名称]:[版本版本号]  ==>  registry.aliyuncs.com/chenby/[镜像名称]:[版本版本号]
k8s.gcr.io/[镜像名称]:[版本版本号]  ==>  registry.aliyuncs.com/chenby/[镜像名称]:[版本版本号]
....
```

# 拉去镜像
```
registry.aliyuncs.com/chenby/[镜像名称]:[版本版本号]
registry.aliyuncs.com/chenby/kube-apiserver:v1.30.1
```

# 声明
此仓库基于  https://github.com/lework/sync_image  修改得来


> **关于**
>
> https://www.oiox.cn/
>
> https://www.oiox.cn/index.php/start-page.html
>
> **CSDN、GitHub、知乎、开源中国、思否、掘金、简书、华为云、阿里云、腾讯云、哔哩哔哩、今日头条、新浪微博、个人博客**
>
> **全网可搜《小陈运维》**
>
> **文章主要发布于微信公众号**
