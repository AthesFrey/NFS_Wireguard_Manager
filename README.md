# NFS_Wireguard_Manager 3.1

用两个交互式 Bash 脚本，在 Debian 11/12/13 或 Ubuntu 20.04/22.04/24.04 上配置：

```text
Jellyfin VPS ── WireGuard ── NFS VPS
```

脚本默认使用：

```text
WireGuard UDP：35669
NFS TCP：8388
WireGuard 网段：10.96.0.0/16
NFS 版本：4.1
```

脚本自动安装所需的 WireGuard、NFS、nftables 和 Python 3，管理 `wg0` 上的 NFS TCP 8388 规则。**公网 WireGuard UDP 端口与云安全组由你手动配置。**脚本不会安装 Docker、修改 Jellyfin 镜像或自动重建已有容器。

## 文件

```text
scripts/install-jellyfin-client.sh
scripts/install-nfs-server.sh
```

首次安装时可以在隐藏提示中粘贴本机离线创建的 WireGuard 私钥；直接回车则由脚本生成新密钥。本机公钥由私钥派生，私钥保存在 `/etc/wireguard/wg0.key`，权限仅允许 root 读取。重新运行脚本时会沿用已有私钥。

本机私钥只输入到拥有该私钥的机器上，绝不能填入 Peer 公钥栏或传给对端。两台机器的 Peer 条目分别填写对方的公钥，格式是一行 44 字符的 Base64 字符串，通常以 `=` 结尾；不要加 `PublicKey =`、引号、注释或 JSON。WireGuard 公钥和私钥的编码格式相同，不能只靠外观区分。

## Jellyfin 客户端节点

先安装客户端，让脚本准备媒体根目录和挂载传播，再创建新容器。已有 Jellyfin 容器也可运行安装器；若卷仍是 `rprivate`，需要按后文调整。

在线执行（需要本项目的 v3.1 文件已发布到 GitHub）：

```bash
curl -fsSL https://raw.githubusercontent.com/AthesFrey/NFS_Wireguard_Manager/refs/heads/main/v3.1/scripts/install-jellyfin-client.sh | sudo bash
```

安装完成、宿主机 NFS 挂载就绪后，新部署可使用：

```bash
mkdir -p /opt/jellyfin/config /opt/jellyfin/cache

docker run -d \
  -e TZ=Asia/Shanghai \
  --name jellyfin \
  --restart always \
  -v /opt/jellyfin/config:/config \
  -v /opt/jellyfin/cache:/cache \
  -v /opt/jellyfin/media:/media:rslave \
  -p 6386:8096 \
  jellyfin/jellyfin
```

`rslave` 让宿主机后续的 NFS 子挂载和卸载传播到容器。脚本通过开机服务准备共享媒体目录，并每 30 秒重试缺失挂载；服务器晚启动后，文件系统就绪即可进入容器，媒体入库仍需要 Jellyfin 扫描。客户端依赖为 `wireguard`、`nfs-common`、`nftables`、`python3`。

脚本询问“本机”时，指当前 Jellyfin VPS；“Peer”提示指远端 NFS VPS。示例中 `hhost_jf` 是 Jellyfin 节点，`ddps_nft` 是 NFS 节点，地址分别为 `10.96.0.1` 和 `10.96.0.2`：

| 提示 | 填写示例 | 说明 |
| --- | --- | --- |
| 本机节点名称 | `hhost_jf` | 当前 Jellyfin VPS 的标签，不是公钥或 IP；回车使用默认值。 |
| 本机 WireGuard IPv4 地址 | `10.96.0.1` | Jellyfin VPS 的隧道地址；NFS Server 也要登记此地址。 |
| WireGuard 网段 | `10.96.0.0/16` | 两台机器必须相同；用默认值时直接回车。 |
| WireGuard UDP 监听端口 | `35669` | 本机 WireGuard 端口，默认通常直接回车。 |
| NFS Server Peer 名称 | `ddps_nft` | 填远端 NFS VPS 的节点名，不填 IP 或公钥。 |
| `ddps_nft` 的 WireGuard IPv4 地址 | `10.96.0.2` | 填 NFS VPS 的隧道内地址。 |
| `ddps_nft` 的 WireGuard 公钥 | NFS VPS 安装器输出的公钥 | 填服务端输出的一整行 44 字符公钥；不填节点名或 IP。 |
| `ddps_nft` 的公网 Endpoint | `203.0.113.10:35669` | 填 NFS VPS 公网 IP/域名及其 WireGuard UDP 监听端口；端口默认是 `35669`。 |
| Jellyfin 宿主机媒体根目录 | `/opt/jellyfin/media` | 保持默认时直接回车。 |
| 本地挂载目录 | `/opt/jellyfin/media/ddps_nft` | 必须位于媒体根目录下，只能使用安全路径字符；输入非法路径时会停留在此提示重新输入。容器内路径是 `/media/ddps_nft`。 |
| Jellyfin Docker 容器名 | `jellyfin` | 容器名不同才修改。 |

“Peer 名称、WireGuard 地址、公钥”是三个不同输入：在 Jellyfin 客户端连接示例中的 NFS Peer，分别填 `ddps_nft`、`10.96.0.2`、NFS VPS 的公钥。首次部署时可以直接粘贴离线创建的本机私钥和对端公钥；Endpoint 仍须填写 NFS VPS 的公网 IP 或域名及端口。

例如 NFS Server 名称为 `storage-a` 时，容器内路径为：

```text
/media/storage-a
```

每个 Peer 字段单独校验；错误输入会停留在当前字段重试。挂载目录必须是媒体根目录内的安全实际路径，不允许重复或互相嵌套；符号链接会按实际路径处理。媒体根目录不能是 `/`。

客户端媒体根目录须位于本地文件系统；把各个 NFS 共享挂到它的子目录，不要把根目录本身放在另一个 NFS/SMB 共享上。

### 已有容器使用 rprivate 时

查看当前卷信息：

```bash
docker inspect --format '{{range .Mounts}}{{printf "%s -> %s (propagation=%s)\n" .Source .Destination .Propagation}}{{end}}' jellyfin
```

若 `/media` 显示 `rprivate`，单纯 `docker restart` 只能让容器接收重启当时的挂载，**不能把绑定属性改成 `rslave`**。应使用原来的 Docker run 参数或 Compose 文件，将媒体卷改为 `/opt/jellyfin/media:/media:rslave`，再重新创建该容器。保留原来的配置、缓存卷、端口、用户和其他参数；不要直接用新部署示例覆盖自定义配置。

安装器不会自动重建容器。对正在运行且 `/media` 映射正确的 `rprivate` 容器，本次有成功挂载时会重启一次，并提示仍需调整卷参数；已经使用 `rslave`/`rshared` 的容器不因此重启。

如果看到 `Too many levels of symbolic links`，但宿主机目录正常、容器重启后恢复，应检查是否是旧的 autofs/NFS 子挂载留在容器里。宿主机 `/ shared` 不代表容器绑定已经启用传播。

## NFS Server 节点

在线执行：

```bash
curl -fsSL https://raw.githubusercontent.com/AthesFrey/NFS_Wireguard_Manager/refs/heads/main/v3.1/scripts/install-nfs-server.sh | sudo bash
```

脚本安装 `wireguard`、`nfs-kernel-server`、`nftables` 和 `python3`。脚本询问“本机”时，指当前 NFS VPS；示例中它叫 `ddps_nft`，隧道地址为 `10.96.0.2`：

| 提示 | 填写示例 | 说明 |
| --- | --- | --- |
| 本机节点名称 | `ddps_nft` | 当前 NFS VPS 的标签；回车使用默认值。 |
| 本机 WireGuard IPv4 地址 | `10.96.0.2` | NFS VPS 的隧道地址。 |
| WireGuard 网段 | `10.96.0.0/16` | 必须与 Jellyfin VPS 一致；使用默认值时回车。 |
| WireGuard UDP 监听端口 | `35669` | 默认值通常直接回车；公网防火墙放行此 UDP 端口。 |
| NFS 导出的媒体目录 | `/srv/media` | 填真实媒体目录；媒体盘若挂载到 `/data/media` 就填该路径。 |
| Jellyfin 客户端 Peer 名称 | `hhost_jf` | 输入客户端节点名以在首次安装时完成配对；留空会结束 Peer 清单。 |
| `hhost_jf` 的 WireGuard IPv4 地址 | `10.96.0.1` | Jellyfin VPS 的隧道内地址；回车使用默认值。 |
| `hhost_jf` 的 WireGuard 公钥 | Jellyfin 客户端公钥 | 填客户端公钥，不填私钥、节点名或 IP。 |

安装器最后输出本机 **WireGuard 公钥**。如果已经在本次 Peer 清单中输入 Jellyfin 客户端公钥，两端首次安装就完成了配对。Endpoint 填本机公网 IP 或域名加 WireGuard 监听端口，例如 `203.0.113.10:35669`；不要把隧道地址 `10.96.0.2` 当作公网 Endpoint。

导出目录可以改成实际磁盘路径，例如：

```text
/data/media
/mnt/storage/movies
```

如果输入的目录不存在，脚本会创建它。使用独立数据盘时，请先确认数据盘已经挂载，否则可能导出一个空目录。

NFS Server 使用 NFSv4 根导出，客户端挂载源为：

```text
<server-wireguard-ip>:/
```

## 推荐配置顺序

1. 先配置公网防火墙：DDPS 允许入站 WireGuard UDP 端口（默认 35669）；hhost 允许出站访问该端口，两端允许连接响应。TCP 8388 由安装器在隧道内管理。
2. 有离线密钥对时，互换公钥后先装 NFS Server，再装 Jellyfin 客户端。本机私钥只在所属机器的隐藏提示中输入。
3. 没有预先生成密钥时，可先安装 NFS Server，客户端 Peer 名称留空；记录其公钥。在 hhost 安装客户端并填写该服务端公钥，记录 hhost 公钥，再按下面的 `--add-client-peer` 把 hhost 加入 DDPS。配对完成前挂载未就绪是预期状态，完成后会自动重试。
4. 确认 hhost 的实际 NFS 来源是 `10.96.0.2:/`、端口为 8388，之后按上面的 `rslave` 示例部署新容器，或调整已有容器。
5. 确认容器内能列出媒体文件，在 Jellyfin 中添加 `/media/ddps_nft` 并执行“扫描媒体库”。

### 将 Jellyfin 公钥加入 NFS Server

在 **Jellyfin VPS** 上生成仅含公钥的文件。该命令从本机私钥计算公钥，不会复制或上传私钥：

```bash
sudo sh -c 'wg pubkey < /etc/wireguard/wg0.key > /tmp/hhost_jf.pub && chmod 0644 /tmp/hhost_jf.pub'
```

将这个 `.pub` 文件上传到 NFS VPS。示例中的 `admin` 和 `203.0.113.10` 分别替换为实际 SSH 登录用户名和 NFS VPS 公网 IP/域名：

```bash
scp /tmp/hhost_jf.pub admin@203.0.113.10:/tmp/hhost_jf.pub
```

接着在 **NFS VPS** 上运行下面命令。Peer 名称 `hhost_jf`、地址 `10.96.0.1` 和 `.pub` 内容，必须分别对应 Jellyfin VPS 的本机节点名、本机 WireGuard 地址和 Jellyfin 脚本输出的公钥：

```bash
curl -fsSL https://raw.githubusercontent.com/AthesFrey/NFS_Wireguard_Manager/refs/heads/main/v3.1/scripts/install-nfs-server.sh | sudo bash -s -- \
  --add-client-peer \
  --peer-name hhost_jf \
  --peer-address 10.96.0.1 \
  --public-key-file /tmp/hhost_jf.pub
```

这个模式更新 NFS Server 的 Peer 清单、WireGuard 配置、客户端 `/32` 回程路由、NFS 导出和隧道防火墙，不重新安装软件包。任一步失败会尝试恢复本次更新，已有的其他路由不会被覆盖。使用此模式前，需要完整运行一次本版本服务端安装器。新增其他 Jellyfin VPS 时，为每台机器生成独立的 `.pub`，并使用它自己的节点名和 WireGuard 地址重复此步骤。需要删除或整体重输 Peer 清单时，仍可运行交互式 NFS Server 安装器并按提示修改清单；已有私钥会保留。

节点名称可以自定义；本机和 Peer 的 WireGuard 地址必须位于两端共同使用的网段内，默认网段为 `10.96.0.0/16`。在 NFS Server 的客户端 Peer 提示中，名称填 Jellyfin 节点名 `hhost_jf`，地址填 `10.96.0.1`，公钥填 Jellyfin VPS 的公钥；不要把名称、地址或私钥填进公钥栏。

## 防火墙：公网手动，隧道内自动

云安全组过滤到达 VPS 的网络流量，主机 nftables 继续过滤进入本机的流量。公网加密 UDP 需要你在这两层放行；解密后的 NFS TCP 8388 在 `wg0` 上由安装器自动管理。

### 地址和 wg0 分别是什么

以下以 hhost 为 Jellyfin 客户端、DDPS 为 NFS Server，并沿用默认地址：

| 名称 | 含义 | 用在哪里 |
| --- | --- | --- |
| DDPS 公网 IP | 从互联网找到 DDPS 的地址 | hhost 的 Peer Endpoint，格式为 `DDPS公网IP:35669`。 |
| `wg0` | WireGuard 创建的虚拟网卡，两台机器各有一个 | `iifname "wg0"` 表示只匹配从隧道进入本机的流量。 |
| `10.96.0.1` | hhost 的隧道地址 | DDPS 上的客户端 Peer 地址和 NFS 导出授权地址。 |
| `10.96.0.2` | DDPS 的隧道地址 | hhost 上的服务端 Peer 地址和 NFS 挂载地址。 |
| `10.96.0.1/32` | 只匹配 `10.96.0.1` 这一个 IPv4 地址 | `/32` 是地址前缀长度，不是端口，也不包括其他客户端。 |
| `10.96.0.0/16` | 地址范围 `10.96.0.0` 至 `10.96.255.255` | 本工程分配隧道地址的范围；不必因此允许整个范围访问 NFS。 |

`wg0` 由 `wg-quick@wg0` 服务创建，配置文件是 `/etc/wireguard/wg0.conf`。它不需要在云平台申请，隧道地址也不需要购买。两端以及未来新增节点应使用不同的隧道地址，并避免与已有网络冲突。`ddps_nft` 只是示例节点名；NFS 是共享文件的服务，nftables 是防火墙工具。

```text
hhost / Jellyfin                         DDPS / NFS Server
wg0: 10.96.0.1                          wg0: 10.96.0.2
       └──── 隧道内：TCP → 10.96.0.2:8388 ────┘
       └──── 公网上：加密 UDP → DDPS公网IP:35669 ─┘
```

上面两行描述的是同一次文件访问的内外两层：TCP 8388 被包在加密的 UDP 35669 里面传输。因此云安全组通常只需要放行外层 UDP，不需要开放公网 TCP 8388。

DDPS 配置中 hhost Peer 的 `AllowedIPs = 10.96.0.1/32` 将该隧道地址绑定到 hhost 公钥；hhost 配置中 DDPS Peer 的 `AllowedIPs = 10.96.0.2/32` 将服务端地址绑定到 DDPS 公钥。它们用于 WireGuard 路由和来源校验，端口是否放行仍由防火墙决定，文件是否允许挂载还受 `/etc/exports` 限制。

别人只知道 DDPS 公钥，无法因此进入隧道或读取媒体。DDPS 必须登记那个客户端的公钥，对方还必须持有对应私钥，才能通过 WireGuard 身份验证。公网开放 WireGuard UDP 端口并不等于开放媒体访问权限。

### 两台机器分别放行什么

| 机器 | 方向 | 需要允许的流量 |
| --- | --- | --- |
| DDPS | 公网入站 | UDP 35669；hhost 公网 IP 固定时可限制来源为该公网 IP。 |
| DDPS | 隧道入站 | 从 `wg0` 来的 `10.96.0.1` → `10.96.0.2`，TCP 8388。 |
| DDPS | 出站 | 上述连接的响应；若出站默认允许，无需额外规则。 |
| hhost | 公网出站 | 到 DDPS 公网 IP 的 UDP 35669。 |
| hhost | 隧道出站 | 经 `wg0` 到 `10.96.0.2` 的 TCP 8388。 |
| hhost | 入站 | 允许已建立连接的响应，通常无需另外开放入站 UDP 35669 或 TCP 8388。 |

主机防火墙一般用 `ct state established,related accept` 允许连接响应。云安全组若有状态，也会自动允许响应；无状态 ACL 则还需要单独允许回程流量。hhost 若默认允许出站，并已允许连接响应，通常无需新增本工程的主机防火墙规则。Jellyfin 网页端口和 SSH 端口是另外的服务，应保留原有规则。

**你负责公网 UDP：**

- **NFS Server：**开放入站 UDP 35669，供 WireGuard 握手；hhost 公网地址固定时可限制来源为该公网 IP。
- **Jellyfin VPS：**允许出站 UDP 访问 NFS Server 的 35669。通常无需开放入站 UDP 35669，因为客户端发起连接后，服务器响应走已有连接。
- 两端需要允许公网连接的响应。若出站策略为拒绝，DDPS 也要允许 WireGuard 的响应；脚本不会替你添加公网 UDP 或通用连接响应规则。
- 修改 WireGuard 监听端口后，用实际端口替换 35669。云安全组不需要开放 TCP 8388。

**脚本负责隧道内 TCP 8388：**

- DDPS 只接受从 `wg0` 进入、来源为已登记客户端地址、目标为本机隧道地址的 NFS 请求，拒绝其他来源的 TCP 8388，并允许 NFS 响应经隧道返回。
- hhost 只增加到已登记 NFS Peer 的隧道内 TCP 8388 出站规则及对应连接的入站响应规则；不会新增公网 NFS 入口。
- 使用 Peer 的单个地址，不对整个 `10.96.0.0/16` 网段授权。增加或移除 Peer 时同步更新规则。
- 通过原生 nftables 的实际 `ip/inet input/output` 过滤链接入，避免另一条默认拒绝链继续拦截。规则使用 `nfs-wg-manager:` 标记和保留表 `inet nfs_wg_manager`；请不要在该表内添加自己的规则。
- 不清空主机规则、不改变链的默认策略、不覆盖 SSH、Docker NAT/FORWARD 等其他业务规则。检测到托管主机过滤链、冲突的保留表或其他无法自动处理的过滤链时会报错；这不是 UFW/firewalld/iptables 主机防火墙管理器。

只启用 NFSv4.1，因此客户端不需要开放公网 TCP/UDP 2049、rpcbind 或 NFSv3 辅助端口。服务端根据安装的 NFS 版本选择生效的配置入口，并检查内核实际协议和监听端口；Debian 11/Ubuntu 20.04 的旧软件包使用 `RPCNFSDOPTS`，现代软件包使用 `nfs.conf.d`。

### 开机与防火墙重载

安装器部署 `nfs-wg-firewall.service`，并在 `nftables.service` 成功启动或重载后重新应用本工程规则，不覆盖 `/etc/nftables.conf`，也不主动重载你的整套防火墙。

如果你绕过服务，直接执行 `nft -f` 或其他命令替换了规则集，应在对应机器重新应用本工程规则：

```bash
# hhost：使用本地保存的客户端安装脚本
sudo bash install-jellyfin-client.sh --apply-firewall

# DDPS：使用本地保存的服务端安装脚本
sudo bash install-nfs-server.sh --apply-firewall
```

这两个命令不重新安装软件包、不要求重新输入 Peer、不重启 WireGuard。反复执行不会叠加本工程规则。公网 UDP 规则的持久化仍由你的主防火墙配置负责。

## 验证命令

在所有节点：

```bash
wg show
ip addr show wg0
```

在 Jellyfin 客户端，以下使用本文示例节点名 `ddps_nft`；如果你使用其他节点名，请替换路径中的 `ddps_nft`：

```bash
findmnt --kernel --nocanonicalize --mountpoint /opt/jellyfin/media/ddps_nft -o TARGET,SOURCE,FSTYPE,OPTIONS,PROPAGATION
systemctl status nfs-wg-media-root nfs-wg-mounts.timer --no-pager
docker exec jellyfin ls -la /media/ddps_nft
```

确认容器内能看到文件后，在 Jellyfin 控制台的媒体库设置中添加路径 `/media/ddps_nft`，并执行“扫描媒体库”。重启容器不会保证媒体库已经完成扫描；宿主机路径 `/opt/jellyfin/media/ddps_nft` 不应填入容器内运行的 Jellyfin。不要把带尖括号的占位符直接粘贴到 Shell，Shell 会把它当作重定向符号。

在 NFS Server：

```bash
exportfs -v
cat /proc/fs/nfsd/versions
cat /proc/fs/nfsd/portlist
ip route get 10.96.0.1
ss -lnt 'sport = :8388'
systemctl status nfs-server --no-pager
```

两端还可检查本工程防火墙状态：

```bash
systemctl status nfs-wg-firewall --no-pager
nft list table inet nfs_wg_manager
```

挂载应显示 `SOURCE=10.96.0.2:/`、`FSTYPE=nfs4`，选项包含 `ro,vers=4.1,proto=tcp,port=8388`。仅看到目录存在、`mountpoint` 成功或 `autofs` 不代表 NFS 已就绪。

WireGuard 和 NFS 服务端口分别为 `35669/udp` 和 `8388/tcp`，不是标准的 NFS `2049`。

## 故障说明

- 每个挂载独立设置 `nofail` 和 30 秒挂载超时。恢复任务并行请求缺失挂载，某个服务器离线不会阻止其他节点发起挂载。
- 已挂载 NFS 使用 `hard`，服务器断线时进行中的文件读取可能等待；`nofail` 并不保证 Jellyfin 的扫描或播放立即返回。已有连接恢复不一定需要重新挂载。
- 开机未挂上、之后服务器恢复时，任务会约每 30 秒补挂。可执行 `sudo systemctl start nfs-wg-mounts.service` 提前请求一次，随后检查实际挂载和容器内容，再扫描媒体库。
- 错误来源、协议或端口的挂载不会被当作成功，也不会被恢复任务强制卸载；查看 `journalctl -u nfs-wg-mounts.service -n 50 --no-pager` 按提示处理。
- 只有宿主机可见、容器不可见时，检查 `/media` 的来源与 `rslave` 属性。新容器应在安装器准备好媒体根目录后创建。
- 如果 `wg show` 没有 latest handshake，先检查 NFS Server 入站 UDP 35669、Jellyfin VPS 出站 UDP 35669、双方公钥、NFS Server 公网 Endpoint 和 `AllowedIPs`。
- 如果 WireGuard 正常但挂载失败，检查 NFS Server 是否监听 TCP 8388、NFS Server 的 `wg0` 规则是否允许 Jellyfin 隧道地址、以及 NFS 导出客户端地址是否正确。公网只检查 UDP 35669，不要用公网地址测试 TCP 8388。
- 如果媒体目录为空，确认 NFS Server 的真实磁盘已挂载到脚本输入的目录。
- `root_squash` 会把 NFS 客户端的 root 身份映射为匿名用户；请确保媒体目录和文件对该匿名用户（列目录需要目录 `r+x`，读取文件需要文件 `r`）可读。

## 本机状态文件

```text
/etc/nfs-wg-manager/node.conf
/etc/nfs-wg-manager/client-peers.tsv
/etc/nfs-wg-manager/server-peers.tsv
/etc/wireguard/wg0.conf
/etc/wireguard/wg0.key
```

配置文件权限仅允许 root 读取。脚本发现已有非本工具生成的 `wg0.conf` 或 Docker systemd drop-in 时会停止，避免覆盖现有配置。

## 本地回归检查

```bash
python3 -B v3.1/tests/test_runtime.py
```

测试提取脚本内的运行助手，在 `/srv/paseo/cache/data_share/` 创建并清理隔离数据，通过命令 stub、规则模型、fstab 生成器和 systemd 离线检查验证；不启动真实 Docker、WireGuard、防火墙或服务。systemd 检查使用临时 C stub 把工具写死的 `/tmp` 工作目录也重定向到测试缓存；缺少该检查所需的 systemd 工具或 C 编译器时，该项会明确显示跳过。真实 NFS 联网、挂载传播和整机重启需要在独立测试 VPS 验收。
