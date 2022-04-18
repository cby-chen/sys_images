# 背景



​	在安装kubernetes时会出现无法访问镜像站的情况，通过GitHub将kubernetes镜像推送到阿里云之后，即可使用阿里云地址引用所需镜像，现已同步镜像5000+，当前还在陆续同步。



# 代码仓库


https://github.com/cby-chen/sys_images
若有需要自行研究 后续更新会在仓库更新


# 目前有如下镜像仓库，后续会陆续增加

```
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
  k8s.gcr.io:
    - etcd
    - kube-proxy
    - kube-apiserver
    - kube-scheduler
    - kube-controller-manager
    - coredns/coredns
    - dns/k8s-dns-node-cache
    - metrics-server/metrics-server
    - ingress-nginx/controller
    - ingress-nginx/kube-webhook-certgen
    - kube-state-metrics/kube-state-metrics
    - prometheus-adapter/prometheus-adapter
    - sig-storage/nfs-subdir-external-provisioner
    - sig-storage/csi-node-driver-registrar
    - sig-storage/csi-provisioner
    - sig-storage/csi-resizer
    - sig-storage/csi-snapshotter
    - sig-storage/csi-attacher
  gcr.io:
    - kaniko-project/executor
    
```

# 使用方式

```
docker.elastic.co/kibana/{image_name}  ==>  registry.cn-hangzhou.aliyuncs.com/chenby/{image_name}
quay.io/csiaddons/{image_name}  ==>  registry.cn-hangzhou.aliyuncs.com/chenby/{image_name}
k8s.gcr.io/{image_name}  ==>  registry.cn-hangzhou.aliyuncs.com/chenby/{image_name}
....
```

# 拉去镜像
```
docker pull registry.cn-hangzhou.aliyuncs.com/chenby/kube-scheduler:[镜像版本号]
```

https://www.oiox.cn/

https://www.chenby.cn/

https://cby-chen.github.io/

https://weibo.com/u/5982474121

https://blog.csdn.net/qq_33921750

https://my.oschina.net/u/3981543

https://www.zhihu.com/people/chen-bu-yun-2

https://segmentfault.com/u/hppyvyv6/articles

https://juejin.cn/user/3315782802482007

https://space.bilibili.com/352476552/article

https://cloud.tencent.com/developer/column/93230

https://www.jianshu.com/u/0f894314ae2c

https://www.toutiao.com/c/user/token/MS4wLjABAAAAeqOrhjsoRZSj7iBJbjLJyMwYT5D0mLOgCoo4pEmpr4A/

CSDN、GitHub、知乎、开源中国、思否、掘金、简书、腾讯云、哔哩哔哩、今日头条、新浪微博、个人博客、全网可搜《小陈运维》
