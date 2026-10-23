#!/bin/bash
# VCU128 openTPU: настройка порта 40G ПК (устанавливается как /usr/local/sbin/otpu-host-40g).
#   otpu-host-40g apply   — ethtool speed/autoneg off, MTU (только повышение), адрес
#   otpu-host-40g remove  — снять адрес OTPU_ADDR (скорость и MTU не трогаются)
#   otpu-host-40g status  — текущее состояние (root не нужен)
# Параметры — переменные окружения или /etc/default/otpu-host-40g:
#   OTPU_IFACE (enp8s0d1), OTPU_ADDR (192.168.41.1/24), OTPU_SPEED (40000), OTPU_MTU (9000,
#   0 — не трогать). OTPU_DRY_RUN=1 — только печать команд.
# Адрес добавляется `ip addr add` поверх профиля NetworkManager (на enp8s0d1 — vcu118-40g,
# 10.0.0.2/3): профиль не меняется; NM не снимает чужой адрес, пока профиль активен, а
# после Link Down адрес возвращает диспетчер NM (90-otpu-host-40g).
set -euo pipefail

if [[ -z "${OTPU_IFACE:-}" && -r /etc/default/otpu-host-40g ]]; then
    # shellcheck source=/dev/null
    . /etc/default/otpu-host-40g
fi
IFACE=${OTPU_IFACE:-enp8s0d1}
ADDR=${OTPU_ADDR:-192.168.41.1/24}
SPEED=${OTPU_SPEED:-40000}
MTU=${OTPU_MTU:-9000}
DRY=${OTPU_DRY_RUN:-0}

log() { echo "otpu-host-40g: $*"; }
run() {
    if [[ $DRY == 1 ]]; then echo "+ $*"; else "$@"; fi
}

wait_iface() {          # при загрузке устройство mlx4 может появиться позже юнита
    local i
    for ((i = 0; i < 60; i++)); do
        [[ -e /sys/class/net/$IFACE ]] && return 0
        [[ $DRY == 1 ]] && break
        sleep 0.5
    done
    log "no interface $IFACE"
    return 1
}

has_addr() { ip -4 -o addr show dev "$IFACE" | awk '{print $4}' | grep -qxF "$ADDR"; }

link_ok() {             # скорость и autoneg уже как нужно (при Link Down Speed: Unknown!)
    local s
    s=$(ethtool "$IFACE" 2>/dev/null) || return 1
    grep -q "^[[:space:]]*Speed: ${SPEED}Mb/s" <<<"$s" &&
        grep -q "^[[:space:]]*Auto-negotiation: off" <<<"$s"
}

apply() {
    wait_iface
    if link_ok; then
        log "$IFACE: speed $SPEED, autoneg off — ok"
    else
        run ethtool -s "$IFACE" speed "$SPEED" autoneg off
    fi
    if [[ $MTU != 0 ]]; then
        local cur
        cur=$(cat "/sys/class/net/$IFACE/mtu")
        if ((cur < MTU)); then
            run ip link set dev "$IFACE" mtu "$MTU"
        else
            log "$IFACE: mtu $cur >= $MTU — ok"
        fi
    fi
    if has_addr; then
        log "$IFACE: $ADDR — ok"
    else
        run ip addr add "$ADDR" dev "$IFACE"
    fi
}

remove() {
    [[ -e /sys/class/net/$IFACE ]] || return 0
    if has_addr; then
        run ip addr del "$ADDR" dev "$IFACE"
    fi
}

status() {
    echo "iface $IFACE, addr $ADDR, speed $SPEED, mtu $MTU"
    if [[ -e /sys/class/net/$IFACE ]]; then
        ip -br addr show dev "$IFACE"
        echo "mtu $(cat "/sys/class/net/$IFACE/mtu"), link $(cat "/sys/class/net/$IFACE/operstate")"
        ethtool "$IFACE" 2>/dev/null | grep -E "Speed:|Auto-negotiation:|Link detected:" || true
    else
        echo "no interface $IFACE"
    fi
}

case "${1:-}" in
    apply) apply ;;
    remove) remove ;;
    status) status ;;
    *) echo "usage: $0 apply|remove|status" >&2; exit 2 ;;
esac
