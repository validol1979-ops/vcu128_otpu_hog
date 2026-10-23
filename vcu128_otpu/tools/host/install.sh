#!/bin/bash
# VCU128 openTPU: однократная настройка ПК под 40G (root). Идемпотентен: повторный запуск
# заменяет только изменившиеся файлы.
#
#   sudo vcu128_otpu/tools/host/install.sh [опции]        установить и применить
#   vcu128_otpu/tools/host/install.sh --dry-run           показать действия (root не нужен)
#   sudo vcu128_otpu/tools/host/install.sh --uninstall    удалить
#
# Ставит:
#   /etc/sysctl.d/90-otpu-net.conf          net.core.rmem_max/wmem_max = 64 МиБ (окно чтения
#                                           EthTransport: read_window до 8 вместо 2)
#   /etc/default/otpu-host-40g              параметры порта (--iface/--addr/--speed/--mtu)
#   /usr/local/sbin/otpu-host-40g           apply|remove|status
#   /etc/systemd/system/otpu-host-40g.service   при загрузке: ethtool -s IFACE speed 40000
#                                           autoneg off, MTU не ниже 9000, адрес ADDR
#   /etc/NetworkManager/dispatcher.d/90-otpu-host-40g   адрес обратно после Link Down
#                                           (NM снимает адреса при деактивации профиля)
# Адрес добавляется `ip addr add` к устройству: профиль NetworkManager на нём (на
# enp8s0d1 — vcu118-40g, 10.0.0.2/3) не меняется.
#
# Опции:
#   --iface IF      порт ПК (enp8s0d1)        --addr A/N   адрес ПК (192.168.41.1/24)
#   --speed MBIT    скорость (40000)          --mtu N      минимальный MTU (9000; 0 — не трогать)
#   --no-start      только файлы: не применять sysctl и не запускать юнит сейчас
#   --root DIR      ставить в DIR вместо / (проверка; systemctl/sysctl не вызываются)
#   --dry-run       печатать команды, ничего не менять
#   --uninstall     удалить файлы и юнит, снять адрес (sysctl — до перезагрузки прежние)
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IFACE=enp8s0d1
ADDR=192.168.41.1/24
SPEED=40000
MTU=9000
ROOT=/
DRY=0
START=1
MODE=install

usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "$0"; }

while (($#)); do
    case $1 in
        --iface) IFACE=$2; shift ;;
        --addr) ADDR=$2; shift ;;
        --speed) SPEED=$2; shift ;;
        --mtu) MTU=$2; shift ;;
        --root) ROOT=$2; shift ;;
        --no-start) START=0 ;;
        --dry-run|-n) DRY=1 ;;
        --uninstall) MODE=uninstall ;;
        -h|--help) usage; exit 0 ;;
        *) echo "install.sh: unknown option $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

[[ $IFACE =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || { echo "bad --iface $IFACE" >&2; exit 2; }
[[ $ADDR =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || { echo "bad --addr $ADDR" >&2; exit 2; }
[[ $SPEED =~ ^[0-9]+$ && $MTU =~ ^[0-9]+$ ]] || { echo "bad --speed/--mtu" >&2; exit 2; }

ROOT=${ROOT%/}
LIVE=0                                  # ставим в живую систему: systemctl/sysctl/ip
[[ -z $ROOT ]] && LIVE=1
if ((!DRY)) && ((LIVE)) && ((EUID != 0)); then
    echo "install.sh: нужен root (sudo $0 ...), или --dry-run" >&2
    exit 1
fi

F_SYSCTL=$ROOT/etc/sysctl.d/90-otpu-net.conf
F_DEFAULT=$ROOT/etc/default/otpu-host-40g
F_HELPER=$ROOT/usr/local/sbin/otpu-host-40g
F_UNIT=$ROOT/etc/systemd/system/otpu-host-40g.service
D_DISP=$ROOT/etc/NetworkManager/dispatcher.d
F_DISP=$D_DISP/90-otpu-host-40g
UNIT=otpu-host-40g.service

log() { echo "install.sh: $*"; }
run() {
    if ((DRY)); then echo "+ $*"; else "$@"; fi
}

put() {                                 # put SRC DST MODE — только если содержимое другое
    local src=$1 dst=$2 mode=$3
    if [[ -f $dst ]] && cmp -s "$src" "$dst"; then
        log "$dst — без изменений"
        return 1
    fi
    run install -D -m "$mode" "$src" "$dst"
    return 0
}

TMP=
trap '[[ -n $TMP ]] && rm -f "$TMP"' EXIT

do_install() {
    local changed=0
    TMP=$(mktemp)
    {
        sed -n '1p' "$HERE/otpu-host-40g.default"
        printf 'OTPU_IFACE=%s\nOTPU_ADDR=%s\nOTPU_SPEED=%s\nOTPU_MTU=%s\n' \
            "$IFACE" "$ADDR" "$SPEED" "$MTU"
    } >"$TMP"

    put "$HERE/90-otpu-net.conf" "$F_SYSCTL" 0644 || true
    if ((LIVE)) && [[ -r $F_DEFAULT ]] && ! cmp -s "$TMP" "$F_DEFAULT"; then
        # параметры сменились: прежний адрес снять прежними параметрами (ExecStop при
        # restart прочтёт уже новый файл)
        OTPU_IFACE='' OTPU_DRY_RUN=$DRY "$HERE/otpu-host-40g.sh" remove || true
    fi
    put "$TMP" "$F_DEFAULT" 0644 && changed=1
    put "$HERE/otpu-host-40g.sh" "$F_HELPER" 0755 && changed=1
    put "$HERE/otpu-host-40g.service" "$F_UNIT" 0644 && changed=1
    if [[ -d $D_DISP ]] || ((!LIVE)); then
        put "$HERE/90-otpu-host-40g.dispatcher" "$F_DISP" 0755 || true
    else
        log "нет $D_DISP (NetworkManager не установлен) — диспетчер не ставится"
    fi
    ((LIVE)) || { log "--root $ROOT: systemctl/sysctl пропущены"; return; }

    ((changed)) && run systemctl daemon-reload
    run systemctl enable "$UNIT"
    if ((START)); then
        run sysctl -q -p "$F_SYSCTL"
        # restart, а не start: oneshot с RemainAfterExit не перезапускается сам; apply
        # идемпотентен (ethtool -s только если скорость/autoneg другие)
        run systemctl restart "$UNIT"
        if ((!DRY)); then
            sysctl net.core.rmem_max net.core.wmem_max
            "$F_HELPER" status || true
        fi
    fi
}

do_uninstall() {
    if ((LIVE)); then
        if systemctl list-unit-files "$UNIT" 2>/dev/null | grep -q "^$UNIT"; then
            run systemctl disable --now "$UNIT"      # ExecStop снимает адрес
        elif [[ -x $F_HELPER ]]; then
            OTPU_DRY_RUN=$DRY run "$F_HELPER" remove
        fi
    fi
    local f
    for f in "$F_DISP" "$F_UNIT" "$F_HELPER" "$F_DEFAULT" "$F_SYSCTL"; do
        if [[ -e $f ]]; then run rm -f "$f"; else log "$f — нет"; fi
    done
    if ((LIVE)); then
        run systemctl daemon-reload
        log "net.core.rmem_max/wmem_max остаются $(sysctl -n net.core.rmem_max) до перезагрузки"
    fi
}

if ((DRY)) && ((LIVE)); then
    log "--dry-run: команды не выполняются"
    OTPU_IFACE=$IFACE OTPU_ADDR=$ADDR OTPU_SPEED=$SPEED OTPU_MTU=$MTU OTPU_DRY_RUN=1 \
        "$HERE/otpu-host-40g.sh" "$([[ $MODE == install ]] && echo apply || echo remove)" ||
        true
fi
"do_$MODE"
