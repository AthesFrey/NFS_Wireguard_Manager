# NFS_Wireguard_Manager 0.2.0

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

脚本不会安装或修改 nftables、UFW、Docker 或 Jellyfin 镜像。

## 文件

```text
scripts/install-jellyfin-client.sh
scripts/install-nfs-server.sh
```

两个脚本都会在本机生成 WireGuard 私钥。私钥保存在 `/etc/wireguard/wg0.key`，不会写入 GitHub。

两台机器交换的是脚本输出的 WireGuard **公钥**，私钥必须留在生成它的机器上，不能上传或粘贴到另一台机器。`.pub` 文件只放一行公钥：44 字符的 Base64 字符串，通常以 `=` 结尾；不要加 `PublicKey =`、引号、注释或 JSON。WireGuard 公钥和私钥使用相同的文本编码，程序无法只靠字符格式辨别误传的私钥；请按下文命令从客户端私钥派生公钥文件，只上传 `.pub` 文件，绝不要复制 `wg0.key`。

## Jellyfin 客户端节点

适用于已经运行以下容器的 VPS：

```bash
mkdir -p /opt/jellyfin/config /opt/jellyfin/cache /opt/jellyfin/media

docker run -d \
  -e TZ=Asia/Shanghai \
  --name jellyfin \
  --restart always \
  -v /opt/jellyfin/config:/config \
  -v /opt/jellyfin/cache:/cache \
  -v /opt/jellyfin/media:/media \
  -p 6386:8096 \
  jellyfin/jellyfin
```

脚本只安装 `wireguard` 和 `nfs-common`。它不会重建容器、修改端口或修改上述卷映射。

在线执行：

```bash
curl -fsSL https://raw.githubusercontent.com/AthesFrey/NFS_Wireguard_Manager/refs/heads/main/install-jellyfin-client.sh | sudo bash
```

脚本询问“本机”时，指当前 Jellyfin VPS；“Peer”提示指远端 NFS VPS。示例中 `hhost_jf` 是 Jellyfin 节点，`ddps_nft` 是 NFS 节点，地址分别为 `10.96.0.2` 和 `10.96.0.1`：

| 提示 | 填写示例 | 说明 |
| --- | --- | --- |
| 本机节点名称 | `hhost_jf` | 当前 Jellyfin VPS 的标签，不是公钥或 IP。 |
| 本机 WireGuard IPv4 地址 | `10.96.0.2` | Jellyfin VPS 的隧道地址；NFS Server 也要登记此地址。 |
| WireGuard 网段 | `10.96.0.0/16` | 两台机器必须相同；用默认值时直接回车。 |
| WireGuard UDP 监听端口 | `35669` | 本机 WireGuard 端口，默认通常直接回车。 |
| NFS Server Peer 名称 | `ddps_nft` | 填远端 NFS VPS 的节点名，不填 IP 或公钥。 |
| `ddps_nft` 的 WireGuard IPv4 地址 | `10.96.0.1` | 填 NFS VPS 的隧道内地址。 |
| `ddps_nft` 的 WireGuard 公钥 | NFS VPS 安装器输出的公钥 | 填服务端输出的一整行 44 字符公钥；不填节点名或 IP。 |
| `ddps_nft` 的公网 Endpoint | `203.0.113.10:35669` | 填 NFS VPS 公网 IP/域名及其 WireGuard UDP 监听端口；端口默认是 `35669`。 |
| Jellyfin 宿主机媒体根目录 | `/opt/jellyfin/media` | 保持默认时直接回车。 |
| 本地挂载目录 | `/opt/jellyfin/media/ddps_nft` | 默认在媒体根目录下；容器内路径是 `/media/ddps_nft`。 |
| Jellyfin Docker 容器名 | `jellyfin` | 容器名不同才修改。 |

“Peer 名称、WireGuard 地址、公钥”是三个不同输入：在 Jellyfin 客户端连接示例中的 NFS Peer，分别填 `ddps_nft`、`10.96.0.1`、NFS VPS 安装器输出的公钥。

例如 NFS Server 名称为 `storage-a` 时，容器内路径为：

```text
/media/storage-a
```

脚本挂载成功后，如果检测到现有 `jellyfin` 容器正在运行，会重启一次容器，使新的 NFS 子目录出现在 `/media` 映射中。容器名默认是 `jellyfin`，也可以在提示中修改。

## NFS Server 节点

在线执行：

```bash
curl -fsSL https://raw.githubusercontent.com/AthesFrey/NFS_Wireguard_Manager/refs/heads/main/install-nfs-server.sh | sudo bash
```

脚本安装 `wireguard` 和 `nfs-kernel-server`。脚本询问“本机”时，指当前 NFS VPS；示例中它叫 `ddps_nft`，隧道地址为 `10.96.0.1`：

| 提示 | 填写示例 | 说明 |
| --- | --- | --- |
| 本机节点名称 | `ddps_nft` | 当前 NFS VPS 的标签。 |
| 本机 WireGuard IPv4 地址 | `10.96.0.1` | NFS VPS 的隧道地址。 |
| WireGuard 网段 | `10.96.0.0/16` | 必须与 Jellyfin VPS 一致；使用默认值时回车。 |
| WireGuard UDP 监听端口 | `35669` | 默认值通常直接回车；公网防火墙放行此 UDP 端口。 |
| NFS 导出的媒体目录 | `/srv/media` | 填真实媒体目录；媒体盘若挂载到 `/data/media` 就填该路径。 |
| Jellyfin 客户端 Peer 名称 | 初次部署先留空并回车 | 客户端还没生成密钥；稍后使用 Peer 添加模式，无需重跑安装器。 |

记录安装器最后输出的 **WireGuard 公钥**，稍后填到 Jellyfin 客户端的 NFS Server Peer 公钥栏。Endpoint 填本机公网 IP 或域名加 WireGuard 监听端口，例如 `203.0.113.10:35669`；不要把隧道地址 `10.96.0.1` 当作公网 Endpoint。

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

1. 在 NFS VPS 运行 `install-nfs-server.sh`。初次安装时，Jellyfin 客户端 Peer 名称先留空并回车；记录服务端输出的公钥。
2. 在 Jellyfin VPS 运行 `install-jellyfin-client.sh`。NFS Peer 名称填 `ddps_nft`，地址填 `10.96.0.1`，公钥填刚才记录的 **NFS VPS 公钥**，Endpoint 填 NFS VPS 公网 IP/域名和 `35669`。
3. 记录 Jellyfin VPS 输出的公钥，在该客户端生成 `.pub` 文件并上传到 NFS VPS，然后运行下方的 `--add-client-peer` 命令。
4. 在 Jellyfin 中添加容器内路径 `/media/ddps_nft` 作为媒体库路径。

### 将 Jellyfin 公钥加入 NFS Server

在 **Jellyfin VPS** 上生成仅含公钥的文件。该命令从本机私钥计算公钥，不会复制或上传私钥：

```bash
sudo sh -c 'wg pubkey < /etc/wireguard/wg0.key > /tmp/hhost_jf.pub && chmod 0644 /tmp/hhost_jf.pub'
```

将这个 `.pub` 文件上传到 NFS VPS。示例中的 `admin` 和 `203.0.113.10` 分别替换为实际 SSH 登录用户名和 NFS VPS 公网 IP/域名：

```bash
scp /tmp/hhost_jf.pub admin@203.0.113.10:/tmp/hhost_jf.pub
```

接着在 **NFS VPS** 上运行下面命令。Peer 名称 `hhost_jf`、地址 `10.96.0.2` 和 `.pub` 内容，必须分别对应 Jellyfin VPS 的本机节点名、本机 WireGuard 地址和 Jellyfin 脚本输出的公钥：

```bash
curl -fsSL https://raw.githubusercontent.com/AthesFrey/NFS_Wireguard_Manager/refs/heads/main/install-nfs-server.sh | sudo bash -s -- \
  --add-client-peer \
  --peer-name hhost_jf \
  --peer-address 10.96.0.2 \
  --public-key-file /tmp/hhost_jf.pub
```

这个模式只更新 NFS Server 的 Peer 清单、WireGuard 配置和 NFS 导出，不重新安装软件包，也不要求重填已有设置。新增其他 Jellyfin VPS 时，为每台机器生成独立的 `.pub`，并使用它自己的节点名和 WireGuard 地址重复此步骤。需要删除或整体重输 Peer 清单时，仍可运行交互式 NFS Server 安装器并按提示修改清单；已有私钥会保留。

节点名称可以自定义；本机和 Peer 的 WireGuard 地址必须位于两端共同使用的网段内，默认网段为 `10.96.0.0/16`。在 NFS Server 的客户端 Peer 提示中，名称填 Jellyfin 节点名 `hhost_jf`，地址填 `10.96.0.2`，公钥填 Jellyfin VPS 输出的公钥；不要把名称或地址填进公钥栏。

## nftables 手工规则

脚本不会修改防火墙。请根据自己的 nftables table 和 chain 名称手工添加规则。

公网入口至少需要：

```text
UDP 35669：WireGuard
```

如果 Peer 使用固定公网 IP，建议只允许这些 IP 访问 UDP 35669。动态公网 IP 时可以放宽 UDP 35669，但 WireGuard 公钥仍然会拒绝未授权 Peer。

NFS 只允许 WireGuard 接口和 WireGuard 网段访问：

```text
iifname "wg0" ip saddr 10.96.0.0/16 tcp dport 8388 accept
```

请不要从公网网卡放行 TCP 8388，也不要把 NFS 2049 暴露到公网。NFS 配置只启用 NFSv4.1，因此不需要为本方案开放 rpcbind 或 NFSv3 的辅助端口。

## 验证命令

在所有节点：

```bash
wg show
ip addr show wg0
```

在 Jellyfin 客户端：

```bash
findmnt -t nfs4
mountpoint /opt/jellyfin/media/<peer-name>
docker exec jellyfin ls -la /media/<peer-name>
```

在 NFS Server：

```bash
exportfs -v
ss -lntp | grep ':8388'
systemctl status nfs-server nfs-kernel-server --no-pager
```

WireGuard 和 NFS 服务端口分别为 `35669/udp` 和 `8388/tcp`，不是标准的 NFS `2049`。

## 故障说明

- 每个 NFS 挂载独立使用 `nofail`，某个 NFS VPS 离线时其他媒体源仍可使用。
- 离线的 NFS 路径可能在 Jellyfin 中显示为空；恢复连接后执行 `mount <挂载目录>`，再按需扫描媒体库。
- 如果 `wg show` 没有 latest handshake，先检查双方公钥、Endpoint、UDP 35669 和 `AllowedIPs`。
- 如果 WireGuard 正常但挂载失败，检查服务端是否监听 TCP 8388、nftables 是否允许 `wg0`、以及 NFS 导出客户端地址是否正确。
- 如果媒体目录为空，确认 NFS Server 的真实磁盘已挂载到脚本输入的目录。
- `root_squash` 会把 NFS 客户端的 root 身份映射为匿名用户；请确保媒体目录和文件对该匿名用户（通常需要目录 `x`、文件 `r`）可读。

## 本机状态文件

```text
/etc/nfs-wg-manager/node.conf
/etc/nfs-wg-manager/client-peers.tsv
/etc/nfs-wg-manager/server-peers.tsv
/etc/wireguard/wg0.conf
/etc/wireguard/wg0.key
```

配置文件权限仅允许 root 读取。脚本发现已有非本工具生成的 `wg0.conf` 或 Docker systemd drop-in 时会停止，避免覆盖现有配置。
