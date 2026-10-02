# NFS_Wireguard_Manager v3.2

这是一套在 Debian stable VPS 上部署 NFS Server 和 Jellyfin NFS Client 的双脚本工具。WireGuard 隧道使用 IPv4 地址，NFS 使用 TCP 8388；公网 WireGuard UDP 端口由你的云安全组和公网防火墙负责。

v3.2 的防火墙适配同时照顾两种规则所有者：

- 原生 nftables：向 inet filter 的原生 input/output 链插入 NFS 规则，并维护运行时表 inet nfs_wg_manager。
- iptables-nft：如果 NekoBox、Sing-box 或其他程序拥有 ip filter 的 INPUT/OUTPUT 基链，使用 iptables 命令在链顶部添加带 nfs-wg-manager: 标记的 IPv4 放行规则。
- ip6 规则只读取和保留。当前状态文件没有 IPv6 Peer，脚本不会向 ip6 链写入规则。
- Docker、NekoBox、Sing-box 的其他规则、NAT、FORWARD、raw 表不会被清空或重排。

## 文件

~~~text
v3.2/
├── README.md
├── scripts/install-nfs-server.sh
├── scripts/install-jellyfin-client.sh
└── tests/test_runtime.py
~~~

脚本版本：

~~~bash
bash install-nfs-server.sh --version
bash install-jellyfin-client.sh --version
# 3.2.0
~~~

## 系统要求和依赖

只支持 Debian stable。脚本不保留 Ubuntu、旧 Debian 包、旧 NFS 配置入口或版本分支。

服务端安装：

~~~text
wireguard nfs-kernel-server nftables iptables python3
~~~

客户端安装：

~~~text
wireguard nfs-common nftables iptables python3
~~~

脚本需要 root、apt-get、systemctl 和交互终端。--apply-firewall、--add-client-peer 属于已安装后的非交互操作。

## NFS Server

~~~bash
curl -fsSL https://raw.githubusercontent.com/AthesFrey/NFS_Wireguard_Manager/refs/heads/main/v3.2/scripts/install-nfs-server.sh | sudo bash
~~~

安装器会询问本机节点、WireGuard IPv4、网段、UDP 监听端口、NFS 导出目录以及 Jellyfin Peer。默认示例是 ddps_nft、10.96.0.2、10.96.0.0/16、35669 和 /srv/media。

服务端只写现代 NFS 配置：

~~~text
/etc/nfs.conf.d/99-nfs-wg-manager.conf
~~~

配置只启用 NFSv4.1，NFS 内核端口为 TCP 8388，关闭 NFSv2、NFSv3、NFSv4.0、NFSv4.2、UDP 和 RDMA。服务由 Debian stable 的 nfs-server.service 管理，导出根为：

~~~text
10.96.0.2:/
~~~

新增 Jellyfin Peer：

~~~bash
sudo bash install-nfs-server.sh --add-client-peer \
  --peer-name hhost_jf \
  --peer-address 10.96.0.1 \
  --public-key-file /root/hhost_jf.pub
~~~

这一步在线更新 Peer 清单、WireGuard、回程路由、NFS 导出和两层防火墙规则；失败时恢复本次事务。

## Jellyfin Client

~~~bash
curl -fsSL https://raw.githubusercontent.com/AthesFrey/NFS_Wireguard_Manager/refs/heads/main/v3.2/scripts/install-jellyfin-client.sh | sudo bash
~~~

客户端会询问本机节点、WireGuard 地址、NFS Server Peer、公网 Endpoint、媒体根目录、挂载目录和 Docker 容器名。NFS Server 的挂载源固定为：

~~~text
10.96.0.2:/  ->  /opt/jellyfin/media/ddps_nft
~~~

媒体根目录映射到 Docker 时使用递归传播：

~~~text
/opt/jellyfin/media:/media:rslave
~~~

脚本不会安装或重建 Jellyfin 镜像；已有容器的其他参数需要保留。

## 强制覆盖安装

默认情况下，存在未标记配置时脚本停止。使用 --force 可覆盖冲突文件：

~~~bash
sudo bash install-nfs-server.sh --force
sudo bash install-jellyfin-client.sh --force
sudo bash install-nfs-server.sh --add-client-peer --force \
  --peer-name hhost_jf --peer-address 10.96.0.1 \
  --public-key-file /root/hhost_jf.pub
~~~

--force 会覆盖没有项目标记的 WireGuard、NFS、systemd drop-in、运行 helper 和 Docker drop-in；已保存的节点变量、私钥和 Peer 清单仍作为默认值保留。/etc/exports、/etc/fstab 只替换本项目标记块，其他内容保留。覆盖前会创建 .nfs-wg-manager.bak，Peer 更新仍使用事务备份和失败回滚。

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

ip6 filter 只读不写。若 iptables-managed IPv6 链被外部程序设置为 DROP，IPv4 NFS 不会经过它；IPv6 NFS 不属于 v3.2 的功能范围。

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
findmnt --kernel --nocanonicalize --mountpoint /opt/jellyfin/media/ddps_nft \
  -o TARGET,SOURCE,FSTYPE,OPTIONS,PROPAGATION
sudo systemctl status nfs-wg-mounts.timer --no-pager
docker inspect --format '{{range .Mounts}}{{printf "%s -> %s (%s)\\n" .Source .Destination .Propagation}}{{end}}' jellyfin
docker exec jellyfin ls -la /media/ddps_nft
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

测试只使用隔离的规则模型和命令 stub，不连接真实 nft、iptables、Docker、WireGuard、NFS 或 systemd：

~~~bash
python3 -B v3.2/tests/test_runtime.py
~~~

测试覆盖原生 inet filter、inet nfs_wg_manager、非空 iptables-managed ip filter/INPUT、IPv6 只读、iptables 规则回滚、强制覆盖、现代 NFS 配置、systemd drop-in、挂载传播和 Docker 依赖。

