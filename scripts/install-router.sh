#!/bin/sh
set -eu

# Põe no router (NETGEAR LBR20 com OpenWrt) os scripts desta pasta, o /etc/rc.local,
# a regra de firewall e o cron que eles precisam. Idempotente: correr as vezes que
# forem precisas. No fim compara o sha256 dos dois lados — se divergir, avisa.
#
# Uso: ./install-router.sh                (cabo na lan1, portátil em 192.168.2.x)
#      ./install-router.sh --verify       (só compara, não escreve)
#      ROUTER=root@192.168.10.1 IFACE=eno1 ./install-router.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROUTER="${ROUTER:-root@192.168.2.1}"
IFACE="${IFACE:-enp2s0}"
MODE="${1:-apply}"
CRON_LINE='* * * * * /usr/bin/watch-router.sh'

SSH_OPTS="-B $IFACE -o BatchMode=yes -o ConnectTimeout=5"

say() { printf '%s\n' "$*"; }
die() { printf 'erro: %s\n' "$*" >&2; exit 1; }

ssh $SSH_OPTS "$ROUTER" 'true' 2>/dev/null || die "sem ssh para $ROUTER por $IFACE"

copy() {
  ssh $SSH_OPTS "$ROUTER" "cat > $2 && chmod $3 $2" < "$SCRIPT_DIR/$1"
}

if [ "$MODE" != "--verify" ]; then
  say "a copiar scripts para $ROUTER"
  copy watch-router.sh /usr/bin/watch-router.sh 755
  copy ap-isolate.sh /usr/bin/ap-isolate.sh 755
  copy 30-wwan-ifup /etc/hotplug.d/net/30-wwan-ifup 755
  copy 40-ap-isolate /etc/hotplug.d/net/40-ap-isolate 755

  say "a escrever /etc/rc.local"
  ssh $SSH_OPTS "$ROUTER" 'cat > /etc/rc.local && chmod 755 /etc/rc.local' <<'RCLOCAL'
# Put your custom commands here that should be executed once
# the system init finished. By default this file does nothing.

for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  echo ondemand > "$f" 2>/dev/null
done

( sleep 40; /usr/bin/watch-router.sh ) &
( sleep 25; /usr/bin/ap-isolate.sh ) &
service sysntpd restart
exit 0
RCLOCAL

  say "a aplicar configuracao (uhttpd, firewall, cron)"
  ssh $SSH_OPTS "$ROUTER" "LINE='$CRON_LINE' sh -s" <<'REMOTE'
set -e

mkdir -p /tmp/loja

if ! uci -q get uhttpd.loja >/dev/null; then
  uci set uhttpd.loja=uhttpd
  uci set uhttpd.loja.listen_http='192.168.10.1:8080'
  uci set uhttpd.loja.home='/tmp/loja'
  uci set uhttpd.loja.index_page='loja.json'
  uci commit uhttpd
  /etc/init.d/uhttpd restart >/dev/null 2>&1
  echo "  uhttpd.loja criado (192.168.10.1:8080)"
else
  echo "  uhttpd.loja ja existia"
fi

if ! uci show firewall | grep -q "pos-loja-status"; then
  uci add firewall rule >/dev/null
  uci set firewall.@rule[-1].name='pos-loja-status'
  uci set firewall.@rule[-1].src='pos'
  uci set firewall.@rule[-1].proto='tcp'
  uci set firewall.@rule[-1].dest_ip='192.168.10.1'
  uci set firewall.@rule[-1].dest_port='8080'
  uci set firewall.@rule[-1].target='ACCEPT'
  uci commit firewall
  fw4 reload >/dev/null 2>&1
  echo "  regra pos-loja-status criada"
else
  echo "  regra pos-loja-status ja existia"
fi

if [ -f /usr/bin/wan-watchdog.sh ]; then
  rm -f /usr/bin/wan-watchdog.sh
  echo "  script antigo /usr/bin/wan-watchdog.sh removido"
fi

for pair in wan-watchdog.log:watch-router.log wan-watchdog.fails:watch-router.fails \
            wan-watchdog.reboots:watch-router.reboots wan-watchdog.lastlog:watch-router.lastlog \
            wan-eventos.tsv:rede-eventos.tsv; do
  old="/root/${pair%%:*}"
  new="/root/${pair##*:}"
  if [ -f "$old" ] && [ ! -f "$new" ]; then
    mv "$old" "$new"
    echo "  estado migrado $old -> $new"
  fi
done

if crontab -l 2>/dev/null | grep -qxF "$LINE"; then
  echo "  cron ja tinha a linha correcta"
else
  (crontab -l 2>/dev/null | grep -vF 'wan-watchdog.sh' || true; echo "$LINE") | crontab -
  echo "  cron actualizado"
fi

/usr/bin/ap-isolate.sh
/usr/bin/watch-router.sh || true
REMOTE
fi

say "a verificar sha256"
FAIL=0
check() {
  local_sum="$(sha256sum "$SCRIPT_DIR/$1" | cut -d' ' -f1)"
  remote_sum="$(ssh $SSH_OPTS "$ROUTER" "sha256sum $2 2>/dev/null | cut -d' ' -f1")"
  if [ "$local_sum" = "$remote_sum" ]; then
    say "  ok    $2"
  else
    say "  DIFERENTE $2"
    FAIL=1
  fi
}

check watch-router.sh /usr/bin/watch-router.sh
check ap-isolate.sh /usr/bin/ap-isolate.sh
check 30-wwan-ifup /etc/hotplug.d/net/30-wwan-ifup
check 40-ap-isolate /etc/hotplug.d/net/40-ap-isolate

say ""
if [ "$FAIL" -eq 0 ]; then
  say "scripts == router. Estado do uplink:"
  ssh $SSH_OPTS "$ROUTER" 'cat /tmp/loja/loja.json 2>/dev/null || echo "(sem loja.json: correr o watch-router.sh)"'
else
  die "os ficheiros no router nao batem com esta pasta"
fi
