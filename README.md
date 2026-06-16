# CFST-DNSync

用 [CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest) 测速，自动把最快的 IP 写入 Cloudflare DNS 做负载均衡。

NAS 任务计划 / crontab 定时跑，bash + curl 实现，不依赖额外工具。也可以在任意 Linux 发行版上运行。

## 工作流程

### mix 模式

```
定时触发 → CFST TCPing 测速 → 过滤不达标IP → 更新DNS → 清理旧记录 → 结束
```

### region 模式

```
定时触发 → 常规扫描(全量IP) → IP库对比(缓存精测) → 合并排序 → 末位淘汰取TOP N → 更新DNS → 更新IP库 → 下一个地区
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
- **IP 库缓存** — region 模式自动积累历史优质 IP，每次与常规扫描对比测速，越跑越准
- **质量门槛** — 各模式独立设置最低速度、最高延迟、最大丢包率，不达标的 IP 直接淘汰
- **增量更新** — 每次 Diff，只增删变化的记录，不动没变的
- **孤儿清理** — 不在名单里的旧记录自动删除
- **API 重试** — 遇到 429/5xx/网络故障自动重试，递增延迟
- **观察模式** — `DRY_RUN=true` 只测速看结果，不动 DNS，不调 API
- **日志轮转** — 自动保留最近 10 次记录

## IP 库缓存 (region 模式)

每个地区维护一个缓存文件 `cache/NRT.txt`，存储格式为 `IP,延迟,带宽`。

**流程：**

1. **常规扫描** — 用 `ip.txt` 全量测速，取 `REGION_SCAN_COUNT` 个结果
2. **IP 库对比** — 从缓存中按带宽(或延迟)排序取前 `REGION_CACHE_TOP_N` 个重新测速
3. **合并排序** — 两轮结果合并，同 IP 去重保留高速，按带宽降序
4. **末位淘汰** — 取前 `TOP_N` 写入 DNS，其余淘汰
5. **更新缓存** — 所有过门槛的 IP 写回缓存，去重后按带宽排序，超过 `REGION_CACHE_MAX` 自动截断

缓存会随着每次运行自动积累优质 IP，低速 IP 逐渐被挤出末尾。

可通过 `REGION_CACHE_ENABLED=false` 关闭。

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
├── cache/                  # IP库缓存目录
│   ├── NRT.txt             # 各地区缓存 (IP,延迟,带宽)
│   └── SIN.txt
├── result.csv              # mix 模式测速结果
├── result_NRT.csv          # region 模式各地区测速结果
├── result_SIN.csv
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
DRY_RUN=false      # true = 观察模式, 只测速不动DNS, 不调API
```

### mix 模式

```bash
MIX_SUBDOMAIN="cf-cdn.example.com"
MIX_TOP_N=15           # 写入DNS的IP数量
MIX_SCAN_COUNT=40      # 常规扫描测试数量, 应 >= MIX_TOP_N
MIX_MIN_SPEED=0        # 最低下载速度 (MB/s), 0=不限
MIX_MAX_LATENCY=0      # 最高平均延迟 (ms), 0=不限
MIX_CFST_ARGS="-n 200 -t 4 -dt 10 -tp 0.05 -sl 0.01 -tl 200"
```

### region 模式

```bash
REGION_MAP=(
    "NRT:cf-cdn-jp.example.com:10"
    "SIN:cf-cdn-sg.example.com:10"
    # "HKG:cf-cdn-hk.example.com:10"
)
REGION_CFST_ARGS="-n 200 -t 4 -dt 10 -tp 0.05 -sl 0.01 -tl 200"
REGION_SCAN_COUNT=20       # 常规扫描测试数量, 应 >= REGION_MAP 中的 TOP_N
REGION_MIN_SPEED=0         # 最低下载速度 (MB/s), 0=不限
REGION_MAX_LATENCY=0       # 最高平均延迟 (ms), 0=不限
REGION_SLEEP=120           # 地区间等待秒数
```

`-httping`、`-cfcolo`、`-dn`、`-p` 由脚本自动拼接，不用手动写在 `REGION_CFST_ARGS` 里。

### region IP 库缓存

```bash
REGION_CACHE_ENABLED=true  # 是否启用IP库缓存
REGION_CACHE_MAX=100       # 每个地区缓存上限
REGION_CACHE_TOP_N=10      # 每次从缓存取前N个对比测速
REGION_CACHE_SORT="speed"  # 排序方式: speed(带宽优先) 或 latency(延迟优先)
REGION_CACHE_SLEEP=30      # 常规扫描与缓存对比之间的等待秒数
```

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

[INFO] [1/2] 测速 NRT - 常规扫描 (HTTPing -cfcolo NRT)...

--- 有效结果: 20 个 ---
  172.64.52.181       41.06ms   69.66MB/s  NRT
  162.159.45.46       54.05ms   69.56MB/s  NRT
  ...

[INFO] [1/2] 测速 NRT - IP库对比 (库存85, 取前10测速, 按speed排序)...

--- 有效结果: 10 个 ---
  104.18.32.7         38.21ms   72.10MB/s  NRT
  ...

--- 合并结果 (按带宽排序) ---

--- 有效结果: 25 个 ---
  104.18.32.7         38.21ms   72.10MB/s  NRT
  172.64.52.181       41.06ms   69.66MB/s  NRT
  ...

=== NRT -> cf-cdn-jp.example.com ===
  172.64.53.1        [=]
  104.18.32.7        [+]
  108.162.198.153    [-]
  -- 5 保留 / 2 新增 / 1 删除 -> 共 7 条

[INFO] IP库已更新: 87 个IP (NRT)
[INFO] 等待 120s 后测速下一个地区...

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
- DNS 未填满 `TOP_N` 时会输出警告，提示可调整的配置项

## 感谢

- [XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest)
- [Claude Opus 4.6](https://claude.ai) — 脚本开发协助

## License

GPL-3.0
