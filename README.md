# CFST-DNSync

用 [CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest) 测速，自动把最快的 IP 写入 Cloudflare DNS 做负载均衡。

NAS 任务计划 / crontab 定时跑，bash + curl 实现，不依赖额外工具。也可以在任意 Linux 发行版上运行。

## 工作流程

```
定时触发 → CFST 测速 → 过滤无效/不达标IP → 按模式更新DNS → 清理旧记录 → 结束
```

## 两种模式

**mix (混搭)** — TCPing 跑一次，不管地区，速度最快的全部解析到一个子域名：
```
前15最快IP → cf-cdn.example.com
```

**region (分流)** — 每个地区单独 HTTPing + `-cfcolo` 测速，结果分别解析到各自子域名：
```
NRT 前10 → cf-cdn-jp.example.com
SIN 前10 → cf-cdn-sg.example.com
```

切换只改一行：`MODE="mix"` 或 `MODE="region"`

## 功能

- **地区分流** — 按 IATA 机场码拆分线路，每个地区独立测速
- **质量门槛** — 可设置最低速度和最高延迟，不达标的 IP 不写入 DNS
- **增量更新** — 每次 Diff，只增删变化的记录，不动没变的
- **孤儿清理** — 不在名单里的旧记录自动删除
- **观察模式** — `DRY_RUN=true` 只测速看结果，不动 DNS
- **日志轮转** — 自动保留最近 10 次记录

## 目录结构

将以下文件放在同一目录下，脚本会自动识别所在目录：

```
cfst-dnsync/
├── cfst-dnsync.sh          # 主脚本
├── cfst                    # CFST 可执行文件 (从 CFST 发行版解压)
├── ip.txt                  # Cloudflare IPv4 段 (从 CFST 发行版解压)
│
│   以下为运行后自动生成:
│
├── result.csv              # mix 模式测速结果
├── result_NRT.csv          # region 模式各地区测速结果
├── result_SIN.csv          #
└── cfst_update.log         # 运行日志
```

## 部署

1. 下载 [CFST](https://github.com/XIU2/CloudflareSpeedTest/releases)，解压得到 `cfst` 和 `ip.txt`

2. 把 `cfst`、`ip.txt`、`cfst-dnsync.sh` 放同一个目录

3. 改脚本顶部配置：

```bash
CF_API_TOKEN="你的Token"
CF_DOMAIN="example.com"
MODE="region"
```

4. 运行：

```bash
chmod +x cfst cfst-dnsync.sh
bash cfst-dnsync.sh
```

5. 没问题就扔进 NAS 任务计划或 crontab 定时跑

> Windows 下编辑过的脚本上传 Linux 前记得处理换行符：`sed -i 's/\r$//' cfst-dnsync.sh`

## 配置速查

### 通用

```bash
DRY_RUN=false      # true = 观察模式, 只测速不动DNS
MIN_SPEED=0        # 最低下载速度 (MB/s), 0=不限
MAX_LATENCY=0      # 最高平均延迟 (ms), 0=不限
```

### mix 模式

```bash
MIX_SUBDOMAIN="cf-cdn.example.com"
MIX_TOP_N=15
MIX_CFST_ARGS="-n 200 -t 4 -dn 40 -dt 10 -p 40 -sl 0.01 -tl 200"
```

### region 模式

```bash
REGION_MAP=(
    "NRT:cf-cdn-jp.example.com:10"
    "SIN:cf-cdn-sg.example.com:10"
    # "HKG:cf-cdn-hk.example.com:10"
    # "LAX:cf-cdn-us.example.com:10"
    # "FRA:cf-cdn-eu.example.com:10"
)
REGION_CFST_ARGS="-n 200 -t 4 -dt 10 -sl 0.01 -tl 200"
REGION_SLEEP=120
```

`-httping`、`-cfcolo`、`-dn`、`-p` 由脚本根据 `REGION_MAP` 自动拼接，不用手动写。

### 常用地区码

| 地区 | 代码 |
|------|------|
| 日本 | NRT(东京) KIX(大阪) |
| 香港 | HKG |
| 新加坡 | SIN |
| 美西 | LAX(洛杉矶) SJC(圣何塞) SEA(西雅图) |
| 美东 | IAD(华盛顿) EWR(纽瓦克) |
| 欧洲 | FRA(法兰克福) CDG(巴黎) LHR(伦敦) |

完整列表: [Cloudflare Status](https://www.cloudflarestatus.com/)

## 日志示例

```
=================================================
  CFST-DNSync - 2026-06-06 04:00:01
  Mode: region
  Filter: speed>=10MB/s latency<=100ms
=================================================

[INFO] 查询 example.com 的 Zone ID...
[INFO] Zone ID: a1b2c3d4e5f6...

[INFO] [1/2] 测速 NRT (HTTPing -cfcolo NRT)...

--- 有效结果: 10 个 ---
  172.64.52.181       41.06ms   69.66MB/s  NRT
  162.159.45.46       54.05ms   69.56MB/s  NRT
  ...

=== NRT -> cf-cdn-jp.example.com ===
  172.64.53.1        [=]
  172.64.52.181      [+]
  108.162.198.153    [-]
  -- 5 保留 / 2 新增 / 1 删除 -> 共 7 条

[INFO] 等待 120s 后测速下一个地区...

[INFO] [2/2] 测速 SIN (HTTPing -cfcolo SIN)...

...

=================================================
  任务完成
=================================================
```

`[=]` 保留 &nbsp; `[+]` 新增 &nbsp; `[-]` 删除

## 注意

- 脚本会完全管理目标子域名的 A 记录，不在名单里的会被删掉，请使用**专用子域名**
- 测速时确保流量不走代理，否则延迟显示 0.xx，结果不准
- region 模式使用 HTTPing，本质上是网络扫描行为。高频运行可能被运营商或 Cloudflare 触发临时限速，建议降低并发(`-n`)并适当拉长 `REGION_SLEEP` 间隔
- 测不到 IP 的地区会清空该子域名的旧记录，避免僵尸 IP 残留

## 感谢

- [XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest)
- [Claude Opus 4.6](https://claude.ai) — 脚本开发协助

## License

GPL-3.0
