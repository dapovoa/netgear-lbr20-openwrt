#!/usr/bin/env bash
# Verificacoes antes do flash do NETGEAR LBR20. Nao precisa de sudo.
# Uso: ./preflight.sh

set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
IFACE="${IFACE:-enp2s0}"
FAIL=0

ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  AVISO %s\n' "$*"; }
bad()  { printf '  FALHA %s\n' "$*"; FAIL=1; }

echo "== ficheiros"
for f in \
  "openwrt/openwrt-25.12.6-ipq40xx-generic-netgear_lbr20-squashfs-factory.img" \
  "netgear-stock/LBR20_V2.7.7.10.zip"
do
  if [ -f "$DIR/$f" ]; then
    ok "$f ($(stat -c%s "$DIR/$f") B)"
  else
    bad "$f em falta"
  fi
done

echo "== hashes (contra sha256sums oficial)"
if [ -f "$DIR/openwrt/sha256sums" ]; then
  ( cd "$DIR/openwrt" && sha256sum -c sha256sums --ignore-missing 2>&1 |
      sed 's/^/  /' )
else
  warn "openwrt/sha256sums em falta, sem validacao"
fi

echo "== ligacao fisica ($IFACE)"
if [ ! -d "/sys/class/net/$IFACE" ]; then
  bad "interface $IFACE inexistente"
else
  speed="$(cat "/sys/class/net/$IFACE/speed" 2>/dev/null || echo '?')"
  state="$(cat "/sys/class/net/$IFACE/operstate")"
  [ "$state" = "up" ] && ok "link $state a ${speed} Mb/s" || bad "link $state"
fi

echo "== router responde no cabo"
body="$(curl -s --interface "$IFACE" -m 5 \
  "http://192.168.1.1/currentsetting.htm" 2>/dev/null | tr '\r' '\n' || true)"
if printf '%s' "$body" | grep -q "Model=LBR20"; then
  field() { printf '%s\n' "$body" | sed -n "s/^$1=//p" | head -1; }
  ok "LBR20, firmware $(field Firmware), blankState=$(field isBlankState), internet=$(field InternetConnectionStatus)"
else
  bad "sem resposta de 192.168.1.1 em $IFACE (cabo na porta certa?)"
fi

echo "== portas abertas no stock"
open="$(curl -s --interface "$IFACE" -m 3 -o /dev/null -w '%{http_code}' \
  "http://192.168.1.1/" 2>/dev/null || echo 000)"
case "$open" in
  200) ok "web UI em 80 (e 443)";;
  *)   warn "web UI nao respondeu ($open)";;
esac

echo "== papel do router no portatil"
nd="$(nmcli -g ipv4.never-default con show "Ligação com fios 1" 2>/dev/null)"
case "$nd" in
  yes|sim) ok "cabo sem default route (internet e sessao ficam no Wi-Fi)";;
  *)       warn "cabo pode ganhar default route: nmcli con modify 'Ligação com fios 1' ipv4.never-default yes";;
esac

echo
if [ "$FAIL" -eq 0 ]; then
  echo "PREFLIGHT OK - pode flashar"
  cat <<'EOF'

Antes de carregar em Update:
  1. cabo na porta LAN2 (nao na WAN/LAN1)
  2. nano-SIM inserida
  3. ter aberto noutra janela, pronto a correr:
       sudo ./recover-tftp.sh

No UI http://192.168.1.1 (admin / password):
  Advanced > Administration > Firmware Update
  upload: openwrt/openwrt-25.12.6-ipq40xx-generic-netgear_lbr20-squashfs-factory.img
  aceitar o aviso de "versao mais antiga", nao desligar (~5 min)
EOF
else
  echo "PREFLIGHT FALHOU - resolver os pontos acima primeiro"
  exit 1
fi
