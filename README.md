# NFS_Wireguard_Manager

用两个交互式 Bash 脚本，在 Debian 11/12 或 Ubuntu 20.04/22.04/24.04 上配置：

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
curl -fsSL https://raw.githubusercontent.com/AthesFrey/NFS_Wireguard_Manager/main/scripts/install-jellyfin-client.sh | sudo bash
```

脚本会询问：

- 本机节点名称
- 本机 WireGuard IPv4 地址
- WireGuard 网段和端口
- NFS Server 的名称、WireGuard 地址、公钥和公网 Endpoint
- Jellyfin 媒体根目录，默认 `/opt/jellyfin/media`
- 每个 NFS Server 的本地挂载目录，默认 `/opt/jellyfin/media/<peer-name>`；挂载目录必须位于媒体根目录下

例如 NFS Server 名称为 `storage-a` 时，容器内路径为：

```text
/media/storage-a
```

脚本挂载成功后，如果检测到现有 `jellyfin` 容器正在运行，会重启一次容器，使新的 NFS 子目录出现在 `/media` 映射中。容器名默认是 `jellyfin`，也可以在提示中修改。

## NFS Server 节点

在线执行：

```bash
curl -fsSL https://raw.githubusercontent.com/AthesFrey/NFS_Wireguard_Manager/main/scripts/install-nfs-server.sh | sudo bash
```

脚本安装 `wireguard` 和 `nfs-kernel-server`，然后询问：

- 本机节点名称
- 本机 WireGuard IPv4 地址
- WireGuard 网段和端口
- 导出的媒体目录，默认 `/srv/media`
- Jellyfin 客户端 Peer 名称、WireGuard 地址和公钥

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

1. 在每台 NFS VPS 运行 `install-nfs-server.sh`，暂时可以不填写客户端 Peer。
2. 记录 NFS VPS 输出的 WireGuard 公钥。
3. 在每台 Jellyfin VPS 运行 `install-jellyfin-client.sh`，输入 NFS VPS 的 Peer 信息。
4. 记录 Jellyfin VPS 输出的 WireGuard 公钥。
5. 重新运行 NFS Server 脚本，把 Jellyfin VPS 公钥加入客户端 Peer 清单。
6. 在 Jellyfin 中添加 `/media/<peer-name>` 作为媒体库路径。

重新运行脚本时，选择重新输入 Peer 清单即可增加或删除节点。已有私钥会保留。

节点名称可以自定义；本机和 Peer 的 WireGuard 地址必须位于脚本中输入的网段内，默认网段为 `10.96.0.0/16`。

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
