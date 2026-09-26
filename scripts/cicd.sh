#!/usr/bin/env bash
# 构建机 CICD 的开机 / 停机 / 看状态 —— 开机时【必须】说清这次是什么负载，按负载换机型再开。
#
#   bash scripts/cicd.sh status
#   bash scripts/cicd.sh start <light|kernel|module|rom|clean>
#   bash scripts/cicd.sh stop
#
# 档位怎么选、为什么是这些机型：docs/build-machine.md。简表：
#   light   D4as_v5   4 vCPU / 16 GB   不跑 `m` 的活：同步设备树、传文件、R2、看日志、release.sh --no-build
#   kernel  D16as_v5  16 vCPU / 64 GB  编内核（~/gk3-kernel）
#   module  D16as_v5  16 vCPU / 64 GB  单编模块 / selinux_policy（时间大头是 Soong 分析，核多了也闲着）
#   rom     D32as_v5  32 vCPU / 128 GB 整包增量构建（m bacon superimage / release.sh 不带 --no-build）
#   clean   D64as_v5  64 vCPU / 256 GB 冷构建（新 out 目录、repo sync 之后、clean）。⬜ 新盘上未实测
#
# ⚠️ 这个脚本只调 az，【要留在沙箱内跑】（CLAUDE.md 运维坑 2：az 在沙箱内 + 下面那个环境变量；
#    绕沙箱跑 az 会 Certificate verification failed，而那可能是一次没停下来的 deallocate）。
#    ssh 相反要绕沙箱 —— 所以"停机前看看机器上有没有别人的构建"不在这里，见 docs/build-machine.md §3。
# ⚠️ 机器正在运行时【不换机型】：换机型要先 deallocate，而跑着的机器可能是另一个会话在用
#    （2026-09-26 就有两个会话同时在做事）。够用就照用，不够用就退出码 3，让人决定。
# ★ 判据一律看服务端回读的真实状态，不信命令自己的输出（运维坑 1）。
set -euo pipefail
export AZURE_CLI_DISABLE_CONNECTION_VERIFICATION=1
RG=AIROUTER_GROUP
VM=CICD

die() { echo "✗ $*" >&2; exit 1; }
ok()  { echo "✓ $*"; }
az_q() { az "$@" 2>/dev/null; }   # az 会往 stderr 打 WARNING（关了证书校验），不当输出

power() { az_q vm get-instance-view -g "$RG" -n "$VM" \
          --query "instanceView.statuses[?starts_with(code,'PowerState/')].code | [0]" -o tsv | sed 's#PowerState/##'; }
size()  { az_q vm show -g "$RG" -n "$VM" --query hardwareProfile.vmSize -o tsv; }
ip()    { az_q vm list-ip-addresses -g "$RG" -n "$VM" \
          --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" -o tsv; }
vcpus() { echo "$1" | sed -E 's/^Standard_D([0-9]+)as_v5$/\1/'; }

profile_size() {
    case "$1" in
        light)  echo Standard_D4as_v5 ;;
        kernel) echo Standard_D16as_v5 ;;
        module) echo Standard_D16as_v5 ;;
        rom)    echo Standard_D32as_v5 ;;
        clean)  echo Standard_D64as_v5 ;;
        *) die "不认识的档位 '$1' —— light / kernel / module / rom / clean，见 docs/build-machine.md" ;;
    esac
}

status() {
    local disk
    disk=$(az_q disk list -g "$RG" --query "[?contains(name,'${VM}_OsDisk')].sku.name | [0]" -o tsv)
    echo "power=$(power)  size=$(size)  disk=$disk  ip=$(ip)"
}

case "${1:-}" in
status)
    status ;;

start)
    want=$(profile_size "${2:-}")
    cur=$(size); st=$(power)
    [ -n "$cur" ] && [ -n "$st" ] || die "读不到构建机状态（az 登录？在沙箱内跑？）"
    if [ "$st" = running ]; then
        if [ "$(vcpus "$cur")" -ge "$(vcpus "$want")" ]; then
            ok "已经在运行（$cur ≥ 档位要的 ${want}），照用 —— 可能是别的会话开的，用完别急着停，先看 docs/build-machine.md §3"
            echo "ip=$(ip)"; exit 0
        fi
        echo "✗ 已经在运行，但机型 $cur 比 '$2' 档要的 $want 小。" >&2
        echo "  换机型要先停机，而跑着的机器可能是别的会话在用 —— 先确认没人在用（§3），再 stop + start。" >&2
        exit 3
    fi
    if [ "$cur" != "$want" ]; then
        echo "═══ 换机型：$cur → ${want}（'$2' 档）═══"
        az_q vm resize -g "$RG" -n "$VM" --size "$want" >/dev/null || die "resize 失败（配额？DASv5 家族上限 65 vCPU，停机的也算）"
        [ "$(size)" = "$want" ] || die "resize 之后回读的机型是 $(size)，不是 $want"
        ok "机型已是 $want"
    else
        ok "机型已经是 ${want}，不用换"
    fi
    echo "═══ 开机 ═══"
    az_q vm start -g "$RG" -n "$VM" >/dev/null || true   # 结果以回读为准
    [ "$(power)" = running ] || die "开机后回读的电源状态是 $(power)"
    ok "running  size=$(size)  ip=$(ip)"
    echo "  ⚠️ 用完 bash scripts/cicd.sh stop（按分钟计费）" ;;

stop)
    st=$(power)
    [ "$st" = deallocated ] && { ok "本来就是 deallocated"; exit 0; }
    echo "═══ 停机（deallocate）═══  ⚠️ 确认过机器上没有别的会话的构建了吗？（docs/build-machine.md §3）"
    az_q vm deallocate -g "$RG" -n "$VM" >/dev/null || true
    st=$(power)
    [ "$st" = deallocated ] || die "deallocate 之后回读的电源状态是 '$st' —— 还在计费，去查"
    ok "deallocated（size=$(size) 保留到下次 start 时再按档位换）" ;;

*)
    sed -n '2,6p' "$0"; exit 2 ;;
esac
