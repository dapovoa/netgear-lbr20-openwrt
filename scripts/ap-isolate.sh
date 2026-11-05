#!/bin/sh
# Isolamento L2 entre clientes Wi-Fi.
# O ap_isolate=1 do hostapd so separa dentro da mesma BSS; isolar as portas da bridge
# e o que trava 2,4 GHz <-> 5 GHz. Nao afecta cliente -> router (o master da bridge
# nao e uma porta) nem o portatil na lan1.
# No arranque a AP pode existir antes de ser porta da bridge: dai as 10 rondas.

for round in 1 2 3 4 5 6 7 8 9 10; do
  pending=0
  for dir in /sys/class/net/phy*-ap*; do
    [ -e "$dir" ] || continue
    isolated="$dir/brport/isolated"
    if [ ! -e "$isolated" ]; then
      pending=1
      continue
    fi
    if [ "$(cat "$isolated" 2>/dev/null)" != "1" ]; then
      echo 1 > "$isolated" 2>/dev/null
      pending=1
    fi
  done
  [ "$pending" -eq 0 ] && exit 0
  sleep 2
done
exit 0
