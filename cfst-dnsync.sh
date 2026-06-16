#!/bin/bash
# ============================================================================
# CFST-DNSync
# 基于 CloudflareSpeedTest 的自动优选 IP + Cloudflare DNS 同步工具
# https://github.com/mintdesu/CFST-DNSync
# CFST: https://github.com/XIU2/CloudflareSpeedTest
# ============================================================================

# ──────────────────── Cloudflare 配置 ───────────────────────
CF_API_TOKEN="你的Cloudflare_API_Token"
CF_DOMAIN="example.com"              # 你的根域名
CF_PROXIED=false
CF_TTL=60

# ──────────────────── 观察模式 ─────────────────────────────
# true = 只测速写入log和csv, 不操作DNS, 用于观察测速结果
DRY_RUN=false

# ──────────────────── 模式选择 ─────────────────────────────
# mix    = 混搭模式, 不管地区, 速度最快的直接全部解析到一个域名
# region = 分流模式, 按地区拆分到不同子域名, 每个地区单独测速
MODE="region"

# ──────────────────── mix 模式配置 ─────────────────────────
MIX_SUBDOMAIN="cf-cdn.example.com"    # 全部IP解析到这个子域名
MIX_TOP_N=15                          # 取速度最快的前N个写入DNS
MIX_SCAN_COUNT=40                     # 常规扫描测试数量, 应 >= MIX_TOP_N
MIX_MIN_SPEED=0                       # 最低下载速度 (MB/s), 0=不限
MIX_MAX_LATENCY=0                     # 最高平均延迟 (ms), 0=不限
MIX_CFST_ARGS="-n 200 -t 4 -dt 10 -tp 0.05 -sl 0.01 -tl 200"  # TCPing 模式参数

# ──────────────────── region 模式配置 ──────────────────────
# 格式: "地区码:子域名:取前N个"
#
# 常用地区码 (IATA机场码):
#   日本  - NRT(东京成田) KIX(大阪)
#   香港  - HKG
#   新加坡 - SIN
#   美西  - LAX(洛杉矶) SJC(圣何塞) SEA(西雅图)
#   美东  - IAD(华盛顿) EWR(纽瓦克)
#   欧洲  - FRA(法兰克福) CDG(巴黎) LHR(伦敦)
#
# 完整地区码列表: https://www.cloudflarestatus.com/
# 按需启用, 不用的行前面加 # 注释掉

REGION_MAP=(
    "NRT:cf-cdn-jp.example.com:10"
    "SIN:cf-cdn-sg.example.com:10"
    # "HKG:cf-cdn-hk.example.com:10"
    # "LAX:cf-cdn-us.example.com:10"
    # "FRA:cf-cdn-eu.example.com:10"
)

# -httping / -cfcolo / -dn / -p 由脚本自动拼接, 不要手动写在 REGION_CFST_ARGS 里
# 实际执行: cfst $REGION_CFST_ARGS -httping -cfcolo NRT -dn $REGION_SCAN_COUNT -p $REGION_SCAN_COUNT
REGION_CFST_ARGS="-n 200 -t 4 -dt 10 -tp 0.05 -sl 0.01 -tl 200"  # HTTPing 模式公共参数
REGION_SCAN_COUNT=20    # 常规扫描测试数量, 应 >= REGION_MAP 中的 TOP_N
REGION_MIN_SPEED=0      # 最低下载速度 (MB/s), 0=不限
REGION_MAX_LATENCY=0    # 最高平均延迟 (ms), 0=不限
REGION_SLEEP=120        # 每个地区测速之间等待秒数, 降低 HTTPing 被限速的风险
REGION_CACHE_SLEEP=30   # 常规扫描与IP库对比之间的等待秒数
REGION_CACHE_MAX=100    # 每个地区IP库最大缓存数
REGION_CACHE_TOP_N=10   # 每次从IP库取前N个做对比测速
REGION_CACHE_SORT="speed"  # IP库排序方式: speed(带宽优先) 或 latency(延迟优先)

# ============================================================================
# 以下内容无需修改
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CFST_BIN="${SCRIPT_DIR}/cfst"
IP_FILE="${SCRIPT_DIR}/ip.txt"
LOG_FILE="${SCRIPT_DIR}/cfst_update.log"
CACHE_DIR="${SCRIPT_DIR}/cache"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }
show() { echo "$*"; echo "$*" >> "$LOG_FILE"; }
die() { show "[ERROR] $*"; exit 1; }

# 日志轮转: 只保留最近 10 次运行记录
LOG_KEEP=10
if [ -f "$LOG_FILE" ]; then
    RUN_COUNT=$(grep -c "^  CFST-DNSync" "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$RUN_COUNT" -gt "$LOG_KEEP" ]; then
        KEEP_LINE=$(grep -n "^  CFST-DNSync" "$LOG_FILE" | tail -n "$LOG_KEEP" | head -1 | cut -d: -f1)
        KEEP_FROM=$((KEEP_LINE - 2))
        [ "$KEEP_FROM" -lt 1 ] && KEEP_FROM=1
        tail -n +"$KEEP_FROM" "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
fi

CF_API_RETRIES=3
CF_API_RETRY_DELAY=5

cf_api() {
    local method="$1" endpoint="$2" data="$3"
    local args=(-s -w "\n%{http_code}" -X "$method" -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")
    [ -n "$data" ] && args+=(-d "$data")

    local attempt=1 resp body http_code
    while [ "$attempt" -le "$CF_API_RETRIES" ]; do
        resp=$(curl "${args[@]}" "https://api.cloudflare.com/client/v4${endpoint}")
        http_code=$(echo "$resp" | tail -1)
        body=$(echo "$resp" | sed '$d')

        if echo "$http_code" | grep -qE '^[23]'; then
            echo "$body"
            return 0
        fi

        # 4xx (非429) 客户端错误不重试
        if echo "$http_code" | grep -qE '^4[0-9]{2}$' && [ "$http_code" != "429" ]; then
            echo "$body"
            return 0
        fi

        # 429 / 5xx / 网络失败 (空或000) 都重试
        if [ "$attempt" -lt "$CF_API_RETRIES" ]; then
            local wait=$((CF_API_RETRY_DELAY * attempt))
            show "[WARN] API ${method} ${endpoint} 返回 ${http_code:-超时}, ${wait}s 后重试 (${attempt}/${CF_API_RETRIES})"
            sleep "$wait"
        fi

        attempt=$((attempt + 1))
    done

    echo "$body"
}

# ──────────────────── DNS 更新函数 ────────────────────────
# 参数: $1=标签 $2=子域名 $3=IP列表文件
update_dns() {
    local LABEL="$1" SUBDOMAIN="$2" IP_FILE_IN="$3"
    local COUNT=0
    [ -f "$IP_FILE_IN" ] && COUNT=$(wc -l < "$IP_FILE_IN" | tr -d ' ')

    show "=== ${LABEL} -> ${SUBDOMAIN} ==="

    # 观察模式: 只展示待同步IP, 不操作DNS
    if [ "$DRY_RUN" = "true" ]; then
        if [ "$COUNT" -eq 0 ]; then
            show "  (无可用IP)"
        else
            while read -r ip; do show "  ${ip}"; done < "$IP_FILE_IN"
            show "  -- 共 ${COUNT} 条 (DRY RUN, 未操作DNS)"
        fi
        show ""
        return
    fi

    # 获取该子域名现有A记录
    local EXISTING="${SCRIPT_DIR}/.existing_dns.tmp"
    : > "$EXISTING"

    local PAGE=1
    while true; do
        local RESP=$(cf_api GET "/zones/${CF_ZONE_ID}/dns_records?type=A&name=${SUBDOMAIN}&per_page=100&page=${PAGE}")
        local SUCCESS=$(echo "$RESP" | grep -o '"success":\s*[a-z]*' | head -1 | grep -o 'true\|false')
        if [ "$SUCCESS" != "true" ]; then
            show "  [ERROR] API查询失败: $RESP"
            rm -f "$EXISTING"
            return
        fi

        echo "$RESP" | grep -o '"id":"[^"]*"[^}]*"type":"A"[^}]*"content":"[^"]*"' | \
        while IFS= read -r line; do
            local rid=$(echo "$line" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
            local rip=$(echo "$line" | grep -o '"content":"[^"]*"' | head -1 | cut -d'"' -f4)
            [ -n "$rid" ] && [ -n "$rip" ] && echo "${rid}|${rip}" >> "$EXISTING"
        done

        local TP=$(echo "$RESP" | grep -o '"total_pages":[0-9]*' | grep -o '[0-9]*')
        [ "$PAGE" -ge "${TP:-1}" ] && break
        PAGE=$((PAGE + 1))
    done

    local EXISTING_COUNT=$(wc -l < "$EXISTING" | tr -d ' ')

    # 测不到IP: 清空该子域名的旧记录
    if [ "$COUNT" -eq 0 ]; then
        if [ "$EXISTING_COUNT" -gt 0 ]; then
            show "  [WARN] 本次未测到可用IP, 清空旧记录"
            while IFS='|' read -r rid rip; do
                local R=$(cf_api DELETE "/zones/${CF_ZONE_ID}/dns_records/${rid}")
                if echo "$R" | grep -q '"success":\s*true'; then
                    show "  ${rip}  [-]"
                else
                    show "  ${rip}  [FAIL]"
                fi
                sleep 0.3
            done < "$EXISTING"
            show "  -- 0 保留 / 0 新增 / ${EXISTING_COUNT} 删除 -> 共 0 条"
        else
            show "  [WARN] 未测到可用IP, 无旧记录, 跳过"
        fi
        show ""
        rm -f "$EXISTING"
        return
    fi

    # Diff
    local ADD="${SCRIPT_DIR}/.add_dns.tmp"
    local DEL="${SCRIPT_DIR}/.del_dns.tmp"
    : > "$ADD"; : > "$DEL"

    while read -r ip; do
        grep -q "|${ip}$" "$EXISTING" 2>/dev/null || echo "$ip" >> "$ADD"
    done < "$IP_FILE_IN"

    while IFS='|' read -r rid rip; do
        grep -qx "$rip" "$IP_FILE_IN" 2>/dev/null || echo "${rid}|${rip}" >> "$DEL"
    done < "$EXISTING"

    local ADD_N=$(wc -l < "$ADD" | tr -d ' ')
    local DEL_N=$(wc -l < "$DEL" | tr -d ' ')
    local KEEP_N=$((COUNT - ADD_N))

    # 保留
    while read -r ip; do
        if grep -q "|${ip}$" "$EXISTING" 2>/dev/null; then
            show "  ${ip}  [=]"
        fi
    done < "$IP_FILE_IN"

    # 添加
    while read -r ip; do
        local DATA="{\"type\":\"A\",\"name\":\"${SUBDOMAIN}\",\"content\":\"${ip}\",\"ttl\":${CF_TTL},\"proxied\":${CF_PROXIED}}"
        local R=$(cf_api POST "/zones/${CF_ZONE_ID}/dns_records" "$DATA")
        if echo "$R" | grep -q '"success":\s*true'; then
            show "  ${ip}  [+]"
        else
            show "  ${ip}  [FAIL] $(echo "$R" | grep -o '"message":"[^"]*"' | head -1)"
        fi
        sleep 0.3
    done < "$ADD"

    # 删除孤儿
    while IFS='|' read -r rid rip; do
        local R=$(cf_api DELETE "/zones/${CF_ZONE_ID}/dns_records/${rid}")
        if echo "$R" | grep -q '"success":\s*true'; then
            show "  ${rip}  [-]"
        else
            show "  ${rip}  [FAIL]"
        fi
        sleep 0.3
    done < "$DEL"

    show "  -- ${KEEP_N} 保留 / ${ADD_N} 新增 / ${DEL_N} 删除 -> 共 ${COUNT} 条"
    show ""

    rm -f "$EXISTING" "$ADD" "$DEL"
}

# ──────────────────── 展示测速结果 ────────────────────────
# 参数: $1=csv文件
show_results() {
    local CSV="$1"
    local CLEAN="${CSV}.clean"

    # 过滤: 去掉速度0.00和地区N/A
    tail -n +2 "$CSV" | awk -F',' '{
        speed=$6; region=$7;
        gsub(/ /,"",speed); gsub(/ /,"",region);
        if (speed+0 > 0 && region != "N/A") print $0
    }' > "$CLEAN"

    local TOTAL=$(wc -l < "$CLEAN" | tr -d ' ')
    show ""
    show "--- 有效结果: ${TOTAL} 个 ---"

    while IFS=',' read -r ip sent recv loss latency speed region; do
        ip=$(echo "$ip" | sed 's/ //g')
        latency=$(echo "$latency" | sed 's/ //g')
        speed=$(echo "$speed" | sed 's/ //g')
        region=$(echo "$region" | sed 's/ //g')
        printf "  %-18s %7sms  %8sMB/s  %s\n" "$ip" "$latency" "$speed" "$region"
        printf "  %-18s %7sms  %8sMB/s  %s\n" "$ip" "$latency" "$speed" "$region" >> "$LOG_FILE"
    done < "$CLEAN"

    show ""
    rm -f "$CLEAN"
}

# ──────────────────── 前置检查 ────────────────────────────
show ""
show "================================================="
show "  CFST-DNSync - $(date '+%Y-%m-%d %H:%M:%S')"
show "  Mode: ${MODE}"
if [ "$MODE" = "mix" ]; then
    _MIN_SPD="$MIX_MIN_SPEED"; _MAX_LAT="$MIX_MAX_LATENCY"
else
    _MIN_SPD="$REGION_MIN_SPEED"; _MAX_LAT="$REGION_MAX_LATENCY"
fi
GATE_INFO=""
[ "$_MIN_SPD" != "0" ] && GATE_INFO="speed>=${_MIN_SPD}MB/s"
[ "$_MAX_LAT" != "0" ] && GATE_INFO="${GATE_INFO:+${GATE_INFO} }latency<=${_MAX_LAT}ms"
[ -n "$GATE_INFO" ] && show "  Filter: ${GATE_INFO}"
[ "$DRY_RUN" = "true" ] && show "  *** DRY RUN - 观察模式, 不操作DNS ***"
show "================================================="

[ -f "$CFST_BIN" ] || die "未找到 cfst"
[ -x "$CFST_BIN" ] || chmod +x "$CFST_BIN"
[ -f "$IP_FILE" ]  || die "未找到 ip.txt"

cd "$SCRIPT_DIR" || die "无法进入工作目录"

if [ "$DRY_RUN" != "true" ]; then
    show ""
    show "[INFO] 查询 ${CF_DOMAIN} 的 Zone ID..."
    ZONE_RESP=$(cf_api GET "/zones?name=${CF_DOMAIN}&status=active")
    CF_ZONE_ID=$(echo "$ZONE_RESP" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [ -z "$CF_ZONE_ID" ]; then
        die "无法获取 Zone ID, 请检查 CF_DOMAIN 和 API Token"
    fi
    show "[INFO] Zone ID: ${CF_ZONE_ID}"
fi

# ══════════════════════════════════════════════════════════
# mix 模式
# ══════════════════════════════════════════════════════════
if [ "$MODE" = "mix" ]; then

    RESULT_FILE="${SCRIPT_DIR}/result.csv"
    rm -f "$RESULT_FILE"

    show ""
    show "[INFO] 开始测速 (TCPing)..."

    # shellcheck disable=SC2086
    "$CFST_BIN" $MIX_CFST_ARGS -dn "$MIX_SCAN_COUNT" -p "$MIX_SCAN_COUNT" -o "$RESULT_FILE" -f "$IP_FILE" 2>&1
    CFST_EXIT=$?

    if [ $CFST_EXIT -ne 0 ] || [ ! -s "$RESULT_FILE" ]; then
        die "测速失败或结果为空, exit: $CFST_EXIT"
    fi

    show_results "$RESULT_FILE"

    # 取前N个IP (过滤后, 含质量门槛)
    MIX_IPS="${SCRIPT_DIR}/.ips_mix.tmp"
    tail -n +2 "$RESULT_FILE" | awk -F',' -v min_spd="$MIX_MIN_SPEED" -v max_lat="$MIX_MAX_LATENCY" '{
        speed=$6; latency=$5; region=$7;
        gsub(/ /,"",speed); gsub(/ /,"",latency); gsub(/ /,"",region);
        if (speed+0 <= 0 || region == "N/A") next;
        if (min_spd+0 > 0 && speed+0 < min_spd+0) next;
        if (max_lat+0 > 0 && latency+0 > max_lat+0) next;
        print $1
    }' | sed 's/ //g' | head -n "$MIX_TOP_N" > "$MIX_IPS"

    update_dns "MIX" "$MIX_SUBDOMAIN" "$MIX_IPS"
    rm -f "$MIX_IPS"

# ══════════════════════════════════════════════════════════
# region 模式
# ══════════════════════════════════════════════════════════
else

    mkdir -p "$CACHE_DIR"
    REGION_INDEX=0
    REGION_TOTAL=${#REGION_MAP[@]}

    for entry in "${REGION_MAP[@]}"; do
        IFS=':' read -r REGION SUBDOMAIN TOP_N <<< "$entry"
        REGION_INDEX=$((REGION_INDEX + 1))

        RESULT_FILE="${SCRIPT_DIR}/result_${REGION}.csv"
        RESULT_CACHE="${SCRIPT_DIR}/result_${REGION}_cache.csv"
        RESULT_MERGED="${SCRIPT_DIR}/result_${REGION}_merged.csv"
        CACHE_FILE="${CACHE_DIR}/${REGION}.txt"
        rm -f "$RESULT_FILE" "$RESULT_CACHE" "$RESULT_MERGED"

        # ── Pass 1: 常规全量扫描 ──
        show ""
        show "[INFO] [${REGION_INDEX}/${REGION_TOTAL}] 测速 ${REGION} - 常规扫描 (HTTPing -cfcolo ${REGION})..."

        # shellcheck disable=SC2086
        "$CFST_BIN" $REGION_CFST_ARGS -httping -cfcolo "$REGION" -dn "$REGION_SCAN_COUNT" -p "$REGION_SCAN_COUNT" -o "$RESULT_FILE" -f "$IP_FILE" 2>&1
        CFST_EXIT=$?

        NORMAL_OK=false
        if [ $CFST_EXIT -eq 0 ] && [ -s "$RESULT_FILE" ]; then
            NORMAL_OK=true
            show_results "$RESULT_FILE"
        else
            show "[WARN] ${REGION} 常规扫描失败或结果为空, exit: $CFST_EXIT"
        fi

        # ── Pass 2: IP库对比测速 ──
        CACHE_OK=false
        CACHE_INPUT="${SCRIPT_DIR}/.cache_input_${REGION}.tmp"
        if [ -f "$CACHE_FILE" ] && [ -s "$CACHE_FILE" ]; then
            CACHE_TOTAL=$(wc -l < "$CACHE_FILE" | tr -d ' ')
            if [ "$REGION_CACHE_SORT" = "latency" ]; then
                sort -t',' -k2 -n "$CACHE_FILE" | head -n "$REGION_CACHE_TOP_N" | cut -d',' -f1 > "$CACHE_INPUT"
            else
                sort -t',' -k3 -rn "$CACHE_FILE" | head -n "$REGION_CACHE_TOP_N" | cut -d',' -f1 > "$CACHE_INPUT"
            fi
            CACHE_N=$(wc -l < "$CACHE_INPUT" | tr -d ' ')

            show ""
            show "[INFO] [${REGION_INDEX}/${REGION_TOTAL}] 测速 ${REGION} - IP库对比 (库存${CACHE_TOTAL}, 取前${CACHE_N}测速, 按${REGION_CACHE_SORT}排序)..."
            sleep "$REGION_CACHE_SLEEP"

            # shellcheck disable=SC2086
            "$CFST_BIN" $REGION_CFST_ARGS -httping -cfcolo "$REGION" -dn "$CACHE_N" -p "$CACHE_N" -o "$RESULT_CACHE" -f "$CACHE_INPUT" 2>&1
            CFST_EXIT=$?

            if [ $CFST_EXIT -eq 0 ] && [ -s "$RESULT_CACHE" ]; then
                CACHE_OK=true
                show_results "$RESULT_CACHE"
            else
                show "[WARN] ${REGION} IP库扫描失败, exit: $CFST_EXIT"
            fi
        fi
        rm -f "$CACHE_INPUT"

        # ── 合并结果, 按带宽排序末位淘汰 ──
        if [ "$NORMAL_OK" = "false" ] && [ "$CACHE_OK" = "false" ]; then
            EMPTY_FILE="${SCRIPT_DIR}/.ips_empty.tmp"
            : > "$EMPTY_FILE"
            update_dns "$REGION" "$SUBDOMAIN" "$EMPTY_FILE"
            rm -f "$EMPTY_FILE"

            if [ "$REGION_INDEX" -lt "$REGION_TOTAL" ]; then
                show "[INFO] 等待 ${REGION_SLEEP}s 后测速下一个地区..."
                sleep "$REGION_SLEEP"
            fi
            continue
        fi

        if [ "$NORMAL_OK" = "true" ] && [ "$CACHE_OK" = "true" ]; then
            head -1 "$RESULT_FILE" > "$RESULT_MERGED"
            {
                tail -n +2 "$RESULT_FILE"
                tail -n +2 "$RESULT_CACHE"
            } | awk -F',' '{
                ip=$1; gsub(/ /,"",ip);
                speed=$6; gsub(/ /,"",speed);
                if (!(ip in best) || speed+0 > best[ip]+0) {
                    best[ip]=speed+0; line[ip]=$0
                }
            } END {
                n=0
                for (ip in best) { n++; ips[n]=ip; spd[n]=best[ip] }
                for (i=1;i<=n;i++) for (j=i+1;j<=n;j++) {
                    if (spd[j]>spd[i]) {
                        t=spd[i];spd[i]=spd[j];spd[j]=t
                        t=ips[i];ips[i]=ips[j];ips[j]=t
                    }
                }
                for (i=1;i<=n;i++) print line[ips[i]]
            }' >> "$RESULT_MERGED"
            FINAL_CSV="$RESULT_MERGED"
            show ""
            show "--- 合并结果 (按带宽排序) ---"
            show_results "$FINAL_CSV"
        elif [ "$NORMAL_OK" = "true" ]; then
            FINAL_CSV="$RESULT_FILE"
        else
            FINAL_CSV="$RESULT_CACHE"
        fi

        # 提取IP (含质量门槛)
        REGION_IPS="${SCRIPT_DIR}/.ips_${REGION}.tmp"
        tail -n +2 "$FINAL_CSV" | awk -F',' -v min_spd="$REGION_MIN_SPEED" -v max_lat="$REGION_MAX_LATENCY" '{
            speed=$6; latency=$5; region=$7;
            gsub(/ /,"",speed); gsub(/ /,"",latency); gsub(/ /,"",region);
            if (speed+0 <= 0 || region == "N/A") next;
            if (min_spd+0 > 0 && speed+0 < min_spd+0) next;
            if (max_lat+0 > 0 && latency+0 > max_lat+0) next;
            print $1
        }' | sed 's/ //g' | head -n "$TOP_N" > "$REGION_IPS"

        FINAL_N=$(wc -l < "$REGION_IPS" | tr -d ' ')
        if [ "$FINAL_N" -lt "$TOP_N" ]; then
            show "[WARN] ${REGION} 仅获得 ${FINAL_N}/${TOP_N} 个IP, 未填满DNS上限, 可增大 REGION_SCAN_COUNT 扩大常规扫描范围, 增大 REGION_CACHE_TOP_N 让更多缓存IP参与对比, 或放宽 REGION_MIN_SPEED / REGION_MAX_LATENCY 质量门槛"
        fi

        # 更新IP库: 所有过门槛IP带延迟+带宽入库, 去重保留高速, 排序截断
        NEW_CACHE="${SCRIPT_DIR}/.cache_new_${REGION}.tmp"
        tail -n +2 "$FINAL_CSV" | awk -F',' -v min_spd="$REGION_MIN_SPEED" -v max_lat="$REGION_MAX_LATENCY" '{
            ip=$1; lat=$5; spd=$6; rgn=$7
            gsub(/ /,"",ip); gsub(/ /,"",lat); gsub(/ /,"",spd); gsub(/ /,"",rgn)
            if (spd+0 <= 0 || rgn == "N/A") next
            if (min_spd+0 > 0 && spd+0 < min_spd+0) next
            if (max_lat+0 > 0 && lat+0 > max_lat+0) next
            print ip "," lat "," spd
        }' > "$NEW_CACHE"

        if [ -s "$NEW_CACHE" ]; then
            {
                cat "$NEW_CACHE"
                [ -f "$CACHE_FILE" ] && cat "$CACHE_FILE"
            } | awk -F',' '{
                ip=$1; spd=$3+0
                if (!(ip in best) || spd > best[ip]+0) { best[ip]=spd; line[ip]=$0 }
            } END { for (ip in best) print line[ip] }' | \
            sort -t',' -k3 -rn | head -n "$REGION_CACHE_MAX" > "${CACHE_FILE}.tmp"
            mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
            CACHE_TOTAL=$(wc -l < "$CACHE_FILE" | tr -d ' ')
            show "[INFO] IP库已更新: ${CACHE_TOTAL} 个IP (${REGION})"
        fi
        rm -f "$NEW_CACHE"

        update_dns "$REGION" "$SUBDOMAIN" "$REGION_IPS"
        rm -f "$REGION_IPS" "$RESULT_CACHE" "$RESULT_MERGED"

        if [ "$REGION_INDEX" -lt "$REGION_TOTAL" ]; then
            show "[INFO] 等待 ${REGION_SLEEP}s 后测速下一个地区..."
            sleep "$REGION_SLEEP"
        fi
    done
fi

# ──────────────────── 结束 ────────────────────────────────
show "================================================="
show "  任务完成"
show "================================================="
show ""

exit 0
