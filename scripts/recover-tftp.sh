#!/usr/bin/env bash
# TFTP recovery para NETGEAR LBR20 (bootloader stock da Netgear).
#
# Uso:
#   sudo ./recover-tftp.sh                      # serve o stock V2.7.7.10
#   sudo ./recover-tftp.sh <imagem>             # serve outra imagem
#   IFACE=eth1 sudo ./recover-tftp.sh           # outra interface
#
# O que faz:
#   1. tira a interface das maos do NetworkManager e poe 192.168.1.10/24
#   2. desliga o ufw (bloqueia UDP 69) e volta a liga-lo no fim
#   3. arranca um servidor TFTP (dnsmasq) na pasta da imagem
#   4. fica a registar os pedidos do bootloader e no fim repoe tudo
#
# Sequencia fisica (lado do router), nesta ordem:
#   desligar da corrente -> manter RESET premido -> ligar -> largar RESET
#   quando a luz da torre piscar a branco e o LED de power piscar a vermelho.
#   A janela dura ~20 s. Por isso o script tem de estar a correr ANTES.
#
# O cabo tem de estar na porta LAN2.

set -euo pipefail

IFACE="${IFACE:-eno1}"
HOST_IP="${HOST_IP:-192.168.1.10}"
WAIT_SECS="${WAIT_SECS:-300}"

if [ -n "${SUDO_USER:-}" ]; then
  USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
  USER_HOME="$HOME"
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
STOCK_DIR="$HERE/../firmware"
STOCK_ZIP="$STOCK_DIR/LBR20_V2.7.7.10.zip"
STOCK_IMG="$STOCK_DIR/LBR20-V2.7.7.10.img"
LOG="/tmp/lbr20-tftp.log"

say() { printf '%s\n' "$*"; }
die() { printf 'erro: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "precisa de root (corre com sudo)"

IMAGE="${1:-$STOCK_IMG}"
if [ "$IMAGE" = "$STOCK_IMG" ] && [ ! -f "$IMAGE" ]; then
  [ -f "$STOCK_ZIP" ] || die "nao encontrei $STOCK_ZIP"
  say "a extrair $(basename "$STOCK_ZIP")"
  unzip -o -q "$STOCK_ZIP" -d "$STOCK_DIR"
fi
[ -f "$IMAGE" ] || die "imagem inexistente: $IMAGE"
IMAGE="$(readlink -f "$IMAGE")"
IMGDIR="$(dirname "$IMAGE")"
say "imagem : $IMAGE ($(stat -c%s "$IMAGE") bytes)"

for alias in chk LBR20.img firmware.img LBR20-V2.7.7.10.img; do
  [ -e "$IMGDIR/$alias" ] || ln "$IMAGE" "$IMGDIR/$alias" 2>/dev/null || true
done
say "nomes   : $(cd "$IMGDIR" && ls -1 | tr '\n' ' ')"

ip link show "$IFACE" >/dev/null 2>&1 || die "interface inexistente: $IFACE"

CON_NAME="$(nmcli -t -f NAME,DEVICE con show 2>/dev/null |
  awk -F: -v d="$IFACE" '$2==d {print $1; exit}')"

UFW_WAS_ACTIVE=0
if ufw status 2>/dev/null | grep -q "^Status: active"; then
  UFW_WAS_ACTIVE=1
fi

cleanup() {
  if [ "${CLEANED:-0}" -eq 1 ]; then
    return
  fi
  CLEANED=1
  say ""
  say "a repor o sistema..."
  if [ -n "${TFTP_PID:-}" ] && kill -0 "$TFTP_PID" 2>/dev/null; then
    kill "$TFTP_PID" 2>/dev/null || true
  fi
  ip addr flush dev "$IFACE" 2>/dev/null || true
  if [ "$UFW_WAS_ACTIVE" -eq 1 ]; then
    ufw --force enable >/dev/null 2>&1 || true
    say "  ufw: ligado outra vez"
  fi
  nmcli device set "$IFACE" managed yes >/dev/null 2>&1 || true
  if [ -n "$CON_NAME" ]; then
    nmcli con up "$CON_NAME" >/dev/null 2>&1 || true
    say "  NetworkManager: $CON_NAME reactivado"
  fi
  say "  log: $LOG"
}
trap cleanup EXIT INT TERM

if [ "$UFW_WAS_ACTIVE" -eq 1 ]; then
  say "a desligar o ufw (bloqueia UDP 69)"
  ufw --force disable >/dev/null
fi

if [ -n "$CON_NAME" ]; then
  say "a libertar $IFACE do NetworkManager ($CON_NAME)"
  nmcli con down "$CON_NAME" >/dev/null 2>&1 || true
fi
# O NM volta a agarrar o dispositivo (autoconnect) e limpa os IPs estaticos a meio da
# recuperacao. Marcar o dispositivo como nao-gerido e o unico travao que dura.
nmcli device set "$IFACE" managed no >/dev/null 2>&1 || true

ip addr flush dev "$IFACE"
ip addr add "$HOST_IP/24" dev "$IFACE"
for extra in 192.168.1.2 192.168.1.100; do
  ip addr add "$extra/24" dev "$IFACE" 2>/dev/null && say "alias       $extra"
done
ip link set "$IFACE" up
say "interface: $IFACE = $HOST_IP/24 (+ alias)"

: > "$LOG"
dnsmasq --no-daemon --port=0 --enable-tftp --tftp-root="$IMGDIR" \
  --user=root --log-facility="$LOG" &
TFTP_PID=$!
sleep 1
kill -0 "$TFTP_PID" 2>/dev/null || die "dnsmasq nao arrancou (ver $LOG)"
say "servidor TFTP a escutar em $HOST_IP:69, raiz $IMGDIR"

say ""
say "AGORA, no router:"
say "  1. desligar da corrente"
say "  2. premir e MANTER o RESET"
say "  3. ligar a corrente, continuar a segurar ~30 s"
say "  4. largar quando a torre piscar a branco e o power a vermelho"
say ""
say "a esperar pedidos (Ctrl-C para sair)..."

SEEN=0
DEADLINE=$((SECONDS + WAIT_SECS))
while [ "$SECONDS" -lt "$DEADLINE" ]; do
  if ! kill -0 "$TFTP_PID" 2>/dev/null; then
    say "o servidor TFTP morreu - ver $LOG"
    break
  fi
  TOTAL=$(wc -l < "$LOG")
  if [ "$TOTAL" -gt "$SEEN" ]; then
    sed -n "$((SEEN + 1)),$TOTAL p" "$LOG" | grep -i "tftp" | while read -r line; do
      say "  $line"
      case "$line" in
        *"not found"*)
          say "  ^ o bootloader pediu este nome: copia a imagem para esse nome em $IMGDIR"
          ;;
      esac
    done
    SEEN=$TOTAL
  fi
  sleep 2
done

say ""
if grep -qi "sent" "$LOG" 2>/dev/null; then
  say "--- pedidos servidos:"
  grep -i "sent" "$LOG"
else
  say "--- nenhum pedido do bootloader em ${WAIT_SECS}s. Verificar:"
  say "    - cabo na porta LAN2 do LBR20 (nao na WAN/LAN1)"
  say "    - ciclo de corrente com RESET premido ANTES de ligar"
  say "    - RESET largado so quando a torre pisca a branco + power a vermelho"
fi
