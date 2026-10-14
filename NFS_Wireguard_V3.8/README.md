# NFS_Wireguard_Manager v3.8

这是一套在 Debian stable VPS 上部署 NFS Server 和 Jellyfin NFS Client 的双脚本工具。WireGuard 隧道使用 IPv4 地址，NFS 使用 TCP 8388；公网 WireGuard UDP 端口由你的云安全组和公网防火墙负责。

v3.8 支持两种防火墙规则所有者：

- 原生 nftables：向 inet filter 的原生 input/output 链插入 NFS 规则，并维护运行时表 inet nfs_wg_manager。
- iptables-nft：如果 NekoBox、Sing-box 或其他程序拥有 ip filter 的 INPUT/OUTPUT 基链，使用 iptables 命令在链顶部添加带 nfs-wg-manager: 标记的 IPv4 放行规则。
- ip6 规则只读取和保留。当前状态文件没有 IPv6 Peer，脚本不会向 ip6 链写入规则。
- Docker、NekoBox、Sing-box 的其他规则、NAT、FORWARD、raw 表不会被清空或重排。

## 文件

~~~text
NFS_Wireguard_V3.8/
├── README.md
├── scripts/install-nfs-server.sh
├── scripts/install-jellyfin-client.sh
└── tests/test_runtime.py
~~~

脚本版本：

~~~bash
bash install-nfs-server.sh --version
bash install-jellyfin-client.sh --version
# 3.8
~~~

## 系统要求和依赖

只支持 Debian stable。安装器完整生成本工具管理的配置；遇到不能确认归属的配置或挂载时会停止对应操作。

服务端安装：

~~~text
wireguard nfs-kernel-server nftables iptables python3
~~~

客户端安装：

~~~text
wireguard nfs-common nftables iptables python3
~~~

脚本需要 root、apt-get、systemctl 和交互终端。每次正常运行都会让你选择新安装、追加 Peer、Force 安装或删除 Peer；--apply-firewall 是单独的防火墙维护操作。输入会自动去除首尾空格，变量不符合校验时会留在当前项重新输入。

## NFS Server

~~~bash
wget -O /root/install-nfs-server.sh https://raw.githubusercontent.com/AthesFrey/NFS_Wireguard_Manager/refs/heads/main/NFS_Wireguard_V3.8/scripts/install-nfs-server.sh
chmod +x /root/install-nfs-server.sh
bash install-nfs-server.sh
~~~

安装器会先询问本次操作：新安装、追加 Jellyfin Peer、Force 安装或删除 Peer。已有服务端配置时，默认选择追加 Peer；该路径直接读取已保存的节点设置，不会再次询问主机名或重新安装软件。

选择追加 Peer 后，按提示输入客户端名、WireGuard IPv4 地址和客户端生成的一行公钥文本（44 字符，直接粘贴，不用输入文件路径）。脚本会在线更新 Peer 清单、WireGuard、回程路由、防火墙和 NFS 导出。`exportfs -rav` 返回非零时会输出诊断和 NFS 服务状态；如果活动导出表与工具管理的目标完全一致，就按已生效处理，否则回滚本次 Peer 更新。诊断只读，不会再次重载导出。

选择 `4) 删除 Jellyfin 客户端 Peer` 后，脚本会显示带序号的 Peer 目标清单，包含地址和配置来源。按序号选择并确认；孤立的受管理导出 IP 也会单独列出，可单独清理。只删除工具标记块中的对应规则，其他导出内容会保留；重载返回非零且活动导出表未匹配目标时会恢复导出文件并重新加载原状态。

新安装和 Force 安装会询问本机节点、WireGuard IPv4、网段、UDP 监听端口、NFS 导出目录以及 Jellyfin Peer。默认示例是 nft_srv1、10.96.0.2、10.96.0.0/16、35669 和 /srv/media。

服务端只写现代 NFS 配置：

~~~text
/etc/nfs.conf.d/99-nfs-wg-manager.conf
~~~

配置只启用 NFSv4.1，NFS 内核端口为 TCP 8388，关闭 NFSv2、NFSv3、NFSv4.0、NFSv4.2 和 UDP。工具不会生成 `rdma = no`：Debian nfs-utils 会把 `rdma` 值当作端口名解析，`no` 会导致 `rpc.nfsd: unable to interpret port name no`。服务由 Debian stable 的 nfs-server.service 管理，导出根为：

~~~text
10.96.0.2:/
~~~

## Jellyfin Client

~~~bash
wget -O /root/install-jellyfin-client.sh https://raw.githubusercontent.com/AthesFrey/NFS_Wireguard_Manager/refs/heads/main/NFS_Wireguard_V3.8/scripts/install-jellyfin-client.sh
chmod +x /root/install-jellyfin-client.sh
bash install-jellyfin-client.sh
~~~

客户端每次运行都会让你选择新安装、追加 NFS Server Peer、Force 安装或删除 NFS Server Peer；已有客户端配置时默认选择追加。追加路径保留节点名称、私钥、媒体根目录和容器设置，只询问新 NFS Server 的 WireGuard 地址、一行公钥文本、公网 Endpoint 和挂载目录，然后更新 WireGuard、路由、防火墙、fstab 和 automount。

选择 `4) 删除 NFS Server Peer` 后，脚本会显示带序号的目标清单，包含地址、挂载路径、来源及挂载状态。Peer 配置、WireGuard、fstab 和活动挂载残留会合并显示；重复挂载层会逐项列出。按序号选中任一重复层后，脚本停止该 Peer 的 automount 和 mount，并清理这个 Peer 的全部已确认挂载层、Peer 清单、WireGuard、回程路由、fstab、automount drop-in 和 Docker 挂载依赖，不会自动重新挂载。若挂载来源不符或无法确认归属，脚本会保留配置和挂载并停止操作。取消或输入无效序号不会修改配置；删除只尝试移除空挂载目录，不删除其中的数据。失败时会回滚文件、WireGuard、路由和挂载恢复任务。

新安装和 Force 安装会询问本机节点、WireGuard 地址、NFS Server Peer、公网 Endpoint、媒体根目录、挂载目录和 Docker 容器名。NFS Server 的挂载源固定为：

~~~text
10.96.0.2:/  ->  /opt/jellyfin/media/nft_srv1
~~~

媒体根目录映射到 Docker 时使用递归传播：

~~~text
/opt/jellyfin/media:/media:rslave
~~~

客户端在媒体根目录上建立独立的 shared bind 挂载，并用运行时挂载 ID 记录身份。服务重启和 Force 安装会复用可确认的根挂载；根目录仍有旧 Peer 子挂载时，会先停止并清理能够确认归属的挂载层。若存在未知或异源挂载，安装器会停止而不会继续叠加挂载。重复 NFS 层不视为正常挂载就绪状态。

脚本不会安装或重建 Jellyfin 镜像；已有容器的其他参数需要保留。

## Force 安装和防火墙维护

在交互菜单中选择 `3) Force 安装` 可覆盖冲突配置。直接传入 `--force` 会把 Force 安装设为默认选项，但脚本仍会显示菜单。一般新安装会拒绝覆盖未标记文件：

~~~bash
sudo bash install-nfs-server.sh --force
sudo bash install-jellyfin-client.sh --force
~~~

Force 安装会覆盖没有项目标记的 WireGuard、NFS、systemd drop-in、运行 helper 和 Docker drop-in；已保存的节点变量、私钥和 Peer 清单仍作为默认值保留。/etc/exports、/etc/fstab 只替换本项目标记块，其他内容保留。覆盖前会创建 .nfs-wg-manager.bak；追加 Peer 仍使用事务备份和失败回滚。

## 防火墙架构

~~~mermaid
flowchart TD
    A[/etc/nftables.conf] --> B[nftables.service]
    B --> C[内核运行时规则集]
    C --> D[table inet filter]
    C --> E[table inet nfs_wg_manager]
    F[firewall_nft_manager.sh] --> G[/etc/nftables.conf.nftfw]
    G --> D
    H[NFS helper Python] --> E
    H --> D
    H --> I[iptables 命令]
    I --> J[table ip filter INPUT/OUTPUT]
    K[NekoBox / Sing-box / Docker] --> J
    K --> L[table ip/ip6 nat, raw, FORWARD]
~~~

/etc/nftables.conf 和 /etc/nftables.conf.nftfw 是持久化文本；table inet filter、table inet nfs_wg_manager 和 table ip filter 是内核运行时对象。NFS helper 创建的 inet nfs_wg_manager 不会自动写回 /etc/nftables.conf。

安装完成后的关键对象：

~~~text
table inet filter
├── input      ← firewall_nft_manager.sh 的原生规则 + nfs-wg-manager:* 规则
├── forward
└── output     ← firewall_nft_manager.sh 的原生规则 + nfs-wg-manager:* 规则

table inet nfs_wg_manager
├── input      ← helper 自己的优先级 -10 链
└── output

table ip filter
├── INPUT      ← NekoBox/Sing-box/其他 iptables-nft 规则 + helper IPv4 规则
├── OUTPUT
└── FORWARD   ← 外部所有者，helper 不修改

table ip6 filter/nat、table ip nat/raw
└── 外部所有者，helper 不写入 IPv6 规则
~~~

表的身份是 family + table name，所以 ip filter 和 inet filter 不是同一张表。inet 可以匹配 IPv4/IPv6；本项目实际 Peer 和 WireGuard 地址是 IPv4。

## 两层 IPv4 NFS 放行

服务端入站请求和客户端出站请求都会同时获得两层放行：

~~~mermaid
sequenceDiagram
    participant W as wg0 解密后的 IPv4 TCP
    participant N as inet filter
    participant P as iptables-nft ip filter
    participant S as NFS 服务/客户端
    W->>N: iif/oif wg0、Peer 地址、TCP 8388
    N-->>W: nfs-wg-manager 标记规则 accept
    W->>P: 同一数据包继续经过 ip INPUT/OUTPUT
    P-->>W: iptables 顶部标记规则 accept
    W->>S: 允许访问
~~~

服务端规则：

~~~text
INPUT : -i wg0 -s <client> -d <server> -p tcp --dport 8388 -j ACCEPT
OUTPUT: -o wg0 -s <server> -d <client> -p tcp --sport 8388 ESTABLISHED,RELATED -j ACCEPT
~~~

客户端规则：

~~~text
OUTPUT: -o wg0 -s <client> -d <server> -p tcp --dport 8388 -j ACCEPT
INPUT : -i wg0 -s <server> -d <client> -p tcp --sport 8388 ESTABLISHED,RELATED -j ACCEPT
~~~

这些规则只使用当前 Peer 的单个 IPv4 地址，不开放整个 WireGuard 网段。helper 只删除和重建带 nfs-wg-manager: 标记的规则；不会执行 iptables -F、nft flush ruleset 或修改其他程序的规则。

ip6 filter 只读不写。若 iptables-managed IPv6 链被外部程序设置为 DROP，IPv4 NFS 不会经过它；IPv6 NFS 不属于 v3.8 的功能范围。

如果外部程序重新生成了 ip filter，需要重新应用：

~~~bash
sudo bash install-nfs-server.sh --apply-firewall
sudo bash install-jellyfin-client.sh --apply-firewall
~~~

inet filter 必须由原生 nftables 管理并包含原生 input、output 基链。若它被 iptables、UFW 或 firewalld 管理，helper 会停止，避免同时拥有同一原生表。

## 公网和隧道端口

| 流量 | 端口 | 负责者 |
| --- | --- | --- |
| 公网 WireGuard 握手 | UDP 35669 | 云安全组和公网防火墙 |
| 隧道内 NFS 请求 | TCP 8388，经 wg0 | 两个安装脚本 |
| 标准公网 NFS 2049 | 不开放 | 脚本不会启用 |

公网 UDP 35669 不是脚本的过滤目标；请在 NFS Server 入站和客户端出站路径放行。公网 TCP 8388、2049、rpcbind 和 NFSv3 辅助端口不需要开放。

## systemd 与运行时文件

~~~text
/etc/nfs-wg-manager/node.conf
/etc/nfs-wg-manager/server-peers.tsv
/etc/nfs-wg-manager/client-peers.tsv
/etc/wireguard/wg0.conf
/etc/wireguard/wg0.key
/usr/local/libexec/nfs-wg-manager/firewall
/usr/local/libexec/nfs-wg-manager/mounts
~~~

服务和 drop-in：

~~~text
nfs-wg-firewall.service
nftables.service.d/nfs-wg-manager.conf
wg-quick@wg0.service.d/nfs-wg-manager.conf
nfs-wg-media-root.service
nfs-wg-mounts.service
nfs-wg-mounts.timer
~~~

写入 systemd 文件后脚本执行 systemctl daemon-reload。nftables.service 成功加载或重载后通过 ExecStartPost/ExecReload 重新应用 NFS helper。

## 验证命令

~~~bash
sudo systemctl status nfs-wg-firewall --no-pager
sudo systemctl status wg-quick@wg0 --no-pager
sudo nft list table inet filter
sudo nft list table inet nfs_wg_manager
sudo iptables -S INPUT
sudo iptables -S OUTPUT
sudo ip6tables -S INPUT
sudo wg show
~~~

服务端：

~~~bash
sudo exportfs -v
cat /proc/fs/nfsd/versions
cat /proc/fs/nfsd/portlist
sudo ss -lnt 'sport = :8388'
sudo systemctl status nfs-server --no-pager
~~~

客户端：

~~~bash
findmnt --kernel --nocanonicalize --mountpoint /opt/jellyfin/media/nft_srv1 \
  -o TARGET,SOURCE,FSTYPE,OPTIONS,PROPAGATION
sudo systemctl status nfs-wg-mounts.timer --no-pager
docker inspect --format '{{range .Mounts}}{{printf "%s -> %s (%s)\\n" .Source .Destination .Propagation}}{{end}}' jellyfin
docker exec jellyfin ls -la /media/nft_srv1
~~~

## 故障排查

- 没有 WireGuard handshake：检查双方公钥、Endpoint、AllowedIPs、NFS Server 入站 UDP 35669 和客户端出站 UDP 35669。
- WireGuard 正常但挂载失败：确认服务端监听 TCP 8388、Peer 地址与 /etc/exports 一致，并检查 inet filter 和 iptables -S INPUT/OUTPUT 中的 nfs-wg-manager: 规则。
- inet filter 报 iptables/UFW/firewalld 管理：保留该管理器作为唯一所有者，改用原生 nftables 的 table inet filter。
- iptables 规则消失：外部工具重建了 ip filter；重新执行 --apply-firewall。
- 宿主机有挂载、容器没有：检查 /media 的 Docker 传播属性，应为 rslave 或 rshared。
- 媒体目录为空：确认真实数据盘已挂载到脚本输入的目录，避免导出空目录。
- 不要执行 iptables -F、nft flush ruleset 或删除外部表；这些命令会破坏 NekoBox、Sing-box、Docker 或主防火墙规则。

## 本地回归测试

测试默认使用隔离的规则模型和命令 stub，不连接真实 nft、iptables、Docker、WireGuard、NFS 或 systemd；若环境提供 `exportfs` 和用户命名空间，还会在隔离目录中解析双 Peer 导出配置：

~~~bash
python3 -B NFS_Wireguard_V3.8/tests/test_runtime.py
~~~

回归套件覆盖原生 inet filter、iptables 规则回滚、IPv6 只读、交互变量校验、双端序号删除清单、孤立导出 IP 清理与回滚、Peer 配置失败回滚、挂载栈识别与重复层清理、媒体根挂载身份复用、systemd drop-in 和 Docker 依赖。
