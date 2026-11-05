#!/bin/sh
# Watchdog do uplink LTE, com registo de quedas para o PC da loja.
#
# Escada:
#   PDP caido (modem responde)  -> ifup; ao 3.o ciclo, reset do modem. NUNCA reboot.
#   registado mas sem dados     -> reset do modem; se continuar, reboot com travao.
#   sem registo na rede         -> cobertura, SIM ou plano: so novas tentativas, sem reboot.
#   modem sem resposta (QMI)    -> reset de hardware por GPIO (modem_switch), no maximo
#                                  1 por HWRESET_MIN_GAP segundos e nunca nos primeiros
#                                  180 s de uptime; sem reboot.
#
# Toda a chamada ao modem (uqmi, porta AT) tem limite de tempo: o busybox nao tem
# `timeout` e um modem bloqueado deixava o uqmi pendurado, e com ele o watchdog.
#
# Travao do reboot: minimo de uptime e no maximo 3 reboots sem recuperacao pelo
# meio (o contador apaga-se ao primeiro ping com sucesso). Linha parada nao conta
# como falha: o ping vai por wwan0, independente do trafego dos clientes.
#
# Registo: /root/rede-eventos.tsv (flash, so transicoes) e /tmp/loja/loja.json
# (tmpfs, reescrito em cada ciclo) - o segundo e o que o PC da loja le por HTTP.

LOG="${LOG:-/root/watch-router.log}"
LOCK="${LOCK:-/tmp/watch-router.lock}"
FAILS="${FAILS:-/root/watch-router.fails}"
REBOOTS="${REBOOTS:-/root/watch-router.reboots}"
LASTLOG="${LASTLOG:-/root/watch-router.lastlog}"
EVENTS="${EVENTS:-/root/rede-eventos.tsv}"
HWRESET_STAMP="${HWRESET_STAMP:-/root/watch-router.hwreset}"
MODEM_SWITCH="${MODEM_SWITCH:-/etc/init.d/modem_switch}"
STATUS_DIR="${STATUS_DIR:-/tmp/loja}"
STATUS=$STATUS_DIR/loja.json

REBOOT_MIN_UPTIME=900
REBOOT_MAX_CONSECUTIVE=3
QUIET_SECS=1800
EVENTS_MAX=500
HWRESET_MIN_GAP=600
QMI_TIMEOUT=8

if [ -d "$LOCK" ] && find "$LOCK" -maxdepth 0 -mmin +5 2>/dev/null | grep -q .; then
  rmdir "$LOCK" 2>/dev/null
fi
[ -d "$LOCK" ] && exit 0
mkdir "$LOCK" 2>/dev/null || exit 0

log() {
  echo "$(date '+%F %T') $*" >> "$LOG"
  if [ "$(wc -l < "$LOG")" -gt 300 ]; then
    tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  fi
  date +%s > "$LASTLOG"
}

# Falha que se repete (cobertura em baixo, PDP a cair): escreve no flash de meia em
# meia hora em vez de a cada minuto, para nao gastar a NAND.
log_quiet() {
  now="$(date +%s)"
  last="$(cat "$LASTLOG" 2>/dev/null || echo 0)"
  [ $((now - last)) -lt "$QUIET_SECS" ] && return 0
  log "$*"
}

count() {
  [ -f "$1" ] || { echo 0; return 0; }
  wc -l < "$1" | tr -d ' '
}

probe() {
  ping -c2 -W2 -I wwan0 1.1.1.1 >/dev/null 2>&1 && return 0
  ping -c2 -W2 -I wwan0 9.9.9.8 >/dev/null 2>&1 && return 0
  return 1
}

# Corre um comando com limite de tempo e devolve 124 se estourar. SIGTERM primeiro para
# o uqmi libertar o client id QMI; SIGKILL se nao sair.
tmo() {
  tmo_secs="$1"; shift
  "$@" &
  tmo_pid=$!
  ( sleep "$tmo_secs"; kill -TERM "$tmo_pid"; sleep 2; kill -KILL "$tmo_pid" ) >/dev/null 2>&1 &
  tmo_killer=$!
  wait "$tmo_pid" 2>/dev/null
  tmo_rc=$?
  kill "$tmo_killer" 2>/dev/null
  [ "$tmo_rc" -ge 128 ] && return 124
  return "$tmo_rc"
}

bring_up() {
  tmo 10 uqmi -d /dev/cdc-wdm0 --sync >/dev/null 2>&1
  ifup wan >/dev/null 2>&1
}

reset_modem() {
  tmo 5 sh -c "printf 'AT+CFUN=1,1\r' > /dev/ttyUSB2" >/dev/null 2>&1
}

# Modem bloqueado (QMI e porta AT mortos): so o reset por GPIO, igual ao do arranque
# do router, o recupera. Limitado a um por HWRESET_MIN_GAP segundos.
hw_reset_modem() {
  now="$(date +%s)"
  last="$(cat "$HWRESET_STAMP" 2>/dev/null || echo 0)"
  if [ $((now - last)) -lt "$HWRESET_MIN_GAP" ]; then
    log_quiet "$1 - reset de hardware ja feito ha menos de ${HWRESET_MIN_GAP}s, a aguardar"
    return 1
  fi
  echo "$now" > "$HWRESET_STAMP"
  log "$1 - reset de hardware do modem (GPIO)"
  ifdown wan >/dev/null 2>&1
  stuck="$(ps | awk '/[u]qmi -d \/dev\/cdc-wdm0/ {print $1}')"
  [ -n "$stuck" ] && kill -9 $stuck 2>/dev/null
  "$MODEM_SWITCH" boot >/dev/null 2>&1
  sleep 45
  bring_up
  sleep 20
  return 0
}

last_event() {
  [ -f "$EVENTS" ] || { printf '0\tinicio\n'; return 0; }
  tail -n 1 "$EVENTS" | cut -f1,2
}

append_event() {
  printf '%s\t%s\t%s\n' "$(date +%s)" "$1" "${2:-}" >> "$EVENTS"
  if [ "$(count "$EVENTS")" -gt "$EVENTS_MAX" ]; then
    tail -n 200 "$EVENTS" > "$EVENTS.tmp" && mv "$EVENTS.tmp" "$EVENTS"
  fi
}

recovered() {
  log "recuperado: $1"
  rm -f "$FAILS" "$REBOOTS"
  append_event recuperado "$1"
  exit 0
}

bump_fails() {
  n=$(( $(cat "$FAILS" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$FAILS"
  echo "$n"
}

# Contadores e ultima queda a partir do TSV, como fragmento de JSON.
counters_json() {
  [ -f "$EVENTS" ] || { echo '"quedas24h":0,"downSecs":0,"ultimaQueda":null'; return 0; }
  awk -F'\t' -v now="$(date +%s)" '
    BEGIN { day = now - 86400; q = 0; down = 0; open = 0; lastTs = 0; lastSecs = 0 }
    $2 == "queda" { if ($1 >= day) q++; open = $1; lastTs = $1; lastSecs = 0 }
    $2 == "recuperado" {
      if (open > 0) {
        if ($1 > day) {
          start = (open > day) ? open : day
          down += $1 - start
          if (open == lastTs) lastSecs = $1 - open
        }
        open = 0
      }
    }
    END {
      if (open > 0) {
        start = (open > day) ? open : day
        down += now - start
        if (open == lastTs) lastSecs = now - open
      }
      last = (lastTs > 0) ? sprintf("{\"ts\":%d,\"secs\":%d}", lastTs, lastSecs) : "null"
      printf "\"quedas24h\":%d,\"downSecs\":%d,\"ultimaQueda\":%s", q, down, last
    }
  ' "$EVENTS"
}

write_status() {
  mkdir -p "$STATUS_DIR" 2>/dev/null || return 0
  now="$(date +%s)"
  last="$(last_event)"
  lastTs="$(printf '%s' "$last" | cut -f1)"
  lastTipo="$(printf '%s' "$last" | cut -f2)"
  estado="ok"
  [ "$lastTipo" = "queda" ] && estado="queda"
  [ "$lastTs" = "0" ] && lastTs="$now"

  sig="$(tmo 4 uqmi -d /dev/cdc-wdm0 -t 2000 --get-data-status 2>/dev/null | tr -d ' \n')"
  lte="null"
  [ -n "$sig" ] && lte="{\"data\":$sig}"

  {
    printf '{\n'
    printf '  "atualizado": %s,\n' "$now"
    printf '  "estado": "%s",\n' "$estado"
    printf '  "desde": %s,\n' "$lastTs"
    printf '  "uptimeSecs": %s,\n' "$(cut -d. -f1 /proc/uptime)"
    printf '  "lte": %s,\n' "$lte"
    printf '  %s\n' "$(counters_json)"
    printf '}\n'
  } > "$STATUS.tmp" 2>/dev/null && mv "$STATUS.tmp" "$STATUS"
}

trap 'write_status; rmdir "$LOCK" 2>/dev/null' EXIT

[ -f "$EVENTS" ] || append_event inicio arranque

# Nos primeiros 3 minutos o modem ainda esta a enumerar no USB e a registar-se: o uqmi
# estoura por timeout e o watchdog respondia com reset de hardware por GPIO. Era o que
# acontecia em TODOS os arranques (USB disconnect + "SIM in illegal state" + ~3 min sem
# internet). Aqui so se garante que a wan e TENTADA (auto='0', ninguem a levanta sozinho);
# nada de uqmi nem de reset. Se ja esta up ou a subir, nao se toca.
if [ "$(cut -d. -f1 /proc/uptime)" -lt 180 ]; then
  wan_status="$(ubus call network.interface.wan status 2>/dev/null)"
  case "$wan_status" in
  *'"up": true'*) ;;
  *'"pending": true'*) ;;
  *) ifup wan >/dev/null 2>&1 ;;
  esac
  exit 0
fi

if probe; then
  rm -f "$FAILS" "$REBOOTS"
  if [ "$(last_event | cut -f2)" = "queda" ]; then
    append_event recuperado "ping ok"
    log "recuperado sem intervencao"
  fi
  exit 0
fi

raw="$(tmo "$QMI_TIMEOUT" uqmi -d /dev/cdc-wdm0 --get-data-status 2>/dev/null)"
qrc=$?
status="$(printf '%s' "$raw" | tr -d '"')"
[ "$qrc" -eq 124 ] && status="sem-resposta"
log "uplink morto (qmi=${status:-sem-resposta}) - a reiniciar a wan"
[ "$(last_event | cut -f2)" = "queda" ] || append_event queda "wan morta"

if [ "$qrc" -eq 124 ]; then
  if hw_reset_modem "controlo QMI sem resposta"; then
    probe && recovered "reset de hardware do modem"
    log_quiet "modem continua sem uplink depois do reset de hardware - novas tentativas"
  fi
  exit 0
fi

bring_up
sleep 20
probe && recovered "ifup wan"

if [ "$status" = "disconnected" ]; then
  n="$(bump_fails)"
  if [ "$n" -lt 3 ]; then
    log_quiet "PDP caido (modem responde) - ifup tentado, ciclo $n/3, sem reboot"
    exit 0
  fi
  log "PDP caido ha $n ciclos - reset do modem (sem reboot)"
  reset_modem
  sleep 55
  bring_up
  sleep 20
  probe && recovered "reset do modem, PDP reactivado"
  log_quiet "PDP continua caido depois do reset - sem reboot, novas tentativas"
  exit 0
fi

if ! tmo "$QMI_TIMEOUT" uqmi -d /dev/cdc-wdm0 --get-serving-system 2>/dev/null | grep -q '"registration": "registered"'; then
  log_quiet "modem sem registo na rede (cobertura, SIM ou plano) - sem reboot"
  exit 0
fi

log "registado mas sem dados - reset do modem"
reset_modem
sleep 55
bring_up
sleep 20
probe && recovered "reset do modem"

n="$(bump_fails)"
if [ "$n" -lt 3 ]; then
  log "FALHOU ($n/3) - sem uplink"
  exit 0
fi

reboots="$(count "$REBOOTS")"
if [ "$reboots" -ge "$REBOOT_MAX_CONSECUTIVE" ]; then
  log_quiet "FALHOU (3/3) - ja $reboots reboots sem recuperar; nao reinicio mais, ficam as tentativas"
  exit 0
fi

uptime="$(cut -d. -f1 /proc/uptime)"
if [ "$uptime" -lt "$REBOOT_MIN_UPTIME" ]; then
  log_quiet "FALHOU (3/3) mas uptime ${uptime}s < ${REBOOT_MIN_UPTIME}s - sem reboot"
  exit 0
fi

date +%s >> "$REBOOTS"
log "3 falhas seguidas - a reiniciar o router (reboot $((reboots + 1))/${REBOOT_MAX_CONSECUTIVE} sem recuperar)"
sync
reboot
