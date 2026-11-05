# Diagnóstico LBR20 — 26/27 de outubro de 2026

Aparelho: NETGEAR Orbi LBR20 (ipq40xx/generic, OpenWrt 25.12.6 r33311-981c978eff)
Modem: Quectel **EG18-EA**, `EG18EAPAR01A11M4G`, QMI (`/dev/cdc-wdm0`, AT em `/dev/ttyUSB2`)
Operador: MCC/MNC **268-02** (MEO), LTE FDD, 2CA B3 + B7

Este dossiê reúne o que foi medido e o que ficou aplicado. Não substitui o
`config/uci-export.txt` (fotografia do aparelho) nem os backups em `backup/2026-10-26/`.

---

## 1. Sintoma

«Telemóvel ligado ao SSID `dinaferreira.pt`, sem acesso à internet.» O cabo (RJ45)
funcionava; o uplink LTE é que caía: 8 quedas em 24 h, com `qmi=Failed to connect to
service` / `Failed to open device` e recuperações de 2–3 min.

---

## 2. Causa principal: antena de Wi-Fi (RP-SMA) nos conectores LTE

O LBR20 veio **sem antenas externas** («Two (2) External LTE antenna connectors (antennas
not included)», datasheet). Foram-lhe apertadas as antenas de Wi-Fi de uma motherboard
**ROG STRIX B650E-I GAMING WIFI** (2,4/5 GHz, ficha RP-SMA).

| Medição (PCC B3, EARFCN 1875, PCI 462) | com a antena Wi-Fi | sem antena |
|---|---|---|
| RSRP | -102 … **-117 dBm** | **-85 … -89 dBm** |
| RSSI | -71 … -87 dBm | -60 … -63 dBm |
| RSRQ | -9 … -13 dB | -9 … -11 dB |
| SINR | 17 → **4 dB** | 17 … 23 dB |
| `AT+QRSRP` (4 cadeias) | -122,-111,-140,-140 (saltos para -80/-91) | -88,-89,-78,-82 |
| Download 20–50 MB | 27 → **3,5 Mbps** | **80 / 100 Mbps** |
| Perda com download em paralelo | **36 – 60 %**, RTT até 1,5 s | **0 %**, RTT 36 ms |
| Quedas | 07:47 e 07:50 (173 s em baixo) | nenhuma em 4 h de observação |

**Porquê:** a ficha RP-SMA não faz contacto no pino central (o LBR20 pede SMA macho), e uma
antena de 2,4/5 GHz em 1800/2600 MHz tem desadaptação e ganho nulo. Pior que não ter antena:
o jack desliga a antena interna quando algo é apertado.

**Lição:** antena externa só **LTE 800–2600 MHz, ficha SMA macho (com pino)**. Validar
sempre com `AT+QRSRP` antes/depois — as cadeias têm de subir.

---

## 3. Antenas externas do utilizador (27/10): pioram ~20 dB

Testadas em 27/10 21:35 e removidas às 21:40.

| Medição | com as antenas | sem antenas (21:45) |
|---|---|---|
| PCC / SCC | B3 -110 / B7 -111 (+B8 -125) | B7 -95…-101 / B3 -91…-96 |
| RSRP | **-110 dBm** | -95 … -101 dBm |
| RSSI | -78 dBm | -57 … -74 dBm |
| RSRQ | -15 dB | -8 … -16 dB |
| SINR | 6,6 … 13,6 dB | 9 … 20 dB |
| `AT+QRSRP` | -110,-115,-140,-140 | -94 … -104 (2 cadeias vivas) |
| Download 50 MB | **40 Mbps** | 44 – 50 Mbps |
| Upload 15 MB | **3 Mbps / falhou** | 8 – 11 Mbps |
| Ping médio (máx) | **341 ms (753 ms)** | 46 – 56 ms |

Mesmo PCC possível, mesma célula: a perda de ~20 dB nas duas cadeias com sinal é assinatura
de ficha errada (RP-SMA) ou antena fora da banda. **As antenas internas do LBR20 são
melhores** — recomendação: deixar as internas.

Nota: os 44–50 Mbps de 27/10 21:45 **não** são regressão das antenas. Nessa janela o modem
escolheu **B7 (2600 MHz) como PCC** e era hora de ponta; quando trocou para B3 o RSRP subiu
a -91 e o débito manteve-se (44 Mbps), ou seja, o limite era a carga da célula. Os
100–125 Mbps de 26/10 foram medidos às 13:30.

---

## 4. Configuração que estava errada

| item | encontrado | aplicado |
|---|---|---|
| `network.wan.mtu` | `1400` em UCI (o ToH diz para **nunca** fixar MTU no wwan) | removido; kernel em 1500 |
| `firewall` `mtu_fix` | `1` nas zonas wan e pos → MSS 1460 para um path de **1400** | `0` + MSS fixo **1360** em `/etc/firewall.user` |
| Wi-Fi 5 GHz | SSID `dinaferreira.pt-5G`, `hidden=1`, `sae-mixed` | SSID `dinaferreira.pt` (um só nome), visível, `sae-mixed` + `ieee80211k` |
| Watchdog | reset de hardware GPIO do modem **em todos os arranques** | guarda `uptime < 180 s` (só garante `ifup`) |
| Backup de config | não incluía watchdog, hotplug nem `firewall.user` | acrescentados a `/etc/sysupgrade.conf` (52 ficheiros) |

A rede anuncia **PDP MTU 1400** (`uqmi --get-current-settings`). A interface fica em 1500
(valor documentado que funciona) e o MSS é fixado a 1360 = 1400 − 20 (IP) − 20 (TCP), sem
tocar no MTU da `wwan0`.

```sh
# /etc/config/firewall
config include
	option path '/etc/firewall.user'
	option fw4_compatible '1'

# /etc/firewall.user
nft add rule inet fw4 mangle_postrouting oifname "wwan0" meta nfproto ipv4 tcp flags syn tcp option maxseg size set 1360
nft add rule inet fw4 mangle_forward    iifname "wwan0" meta nfproto ipv4 tcp flags syn tcp option maxseg size set 1360
```

---

## 5. O bug de arranque do watchdog (dois problemas)

1. A guarda de 180 s fazia `exit` **antes** do `ifup` e, com `network.wan.auto='0'`,
   ninguém levantava a wan — 3 min sem internet em cada arranque. Agora a guarda só evita
   `uqmi`/reset; se a wan não estiver `up` nem `pending`, faz `ifup wan`.
2. A mesma guarda saía **antes** do `trap ... EXIT`, deixando o `mkdir` do lock e **nenhum**
   `loja.json`; o lock só caía por expiração (5 min) → watchdog morto 5 min por arranque.
   A guarda passou para depois do `trap`.

---

## 6. Topologia final (POS no cabo, clientes na Wi-Fi)

```
br-pos   bridge lan1 + lan2   192.168.10.1/24   POS (cabo) + administração
br-lan   sem portas físicas   192.168.2.1/24    só as duas Wi-Fi (clientes)
```

| acesso | WAN/LAN1 | LAN2 | Wi-Fi 192.168.2.x |
|---|---|---|---|
| gateway / DNS `192.168.10.1` | sim | sim | n/a (192.168.2.1) |
| LuCI `http://192.168.10.1` | sim | sim | **não** |
| SSH 22 | sim (chave) | sim (chave) | **não** |
| internet | sim | sim | sim |

Regras relevantes:

```
input_pos:  udp/tcp 53,67 ; 192.168.10.1:8080 ; 192.168.10.1:22,80,443 ; icmp echo -> ACCEPT
input_lan:  iifname "br-lan" tcp 22,80,443 -> REJECT    (antes do accept_from_lan)
```

**Lição:** no hook de *input* o tráfego chega como `br-lan`, nunca como `phy0-ap0`/`phy1-ap0`;
uma regra com `device phy*-ap0` é **silenciosamente ignorada** pelo fw4.

Outros ajustes necessários para a mudança: `dropbear.main.Interface` removido (prendia o SSH
a 192.168.2.1) e `uhttpd.main.listen_http/https` com `192.168.2.1` **e** `192.168.10.1`.

---

## 7. Autonomia (testada com reboots reais)

```
reboot -> sistema em baixo ~10 s -> SSH de volta aos ~30 s de uptime
wan up ~70 s -> ping 1.1.1.1 OK aos 82 s e aos 93 s de uptime (2 ensaios)
dmesg "USB disconnect": 0   (o reset GPIO no arranque desapareceu)
```

| evento | reacção automática |
|---|---|
| corte de luz / reboot | `modem_switch` liga o modem, hotplug → `ifup`, internet em ~82 s |
| PDP cai | cron 1 min: `ifup`; ao 3.º ciclo `AT+CFUN=1,1`; nunca reboot |
| sem registo (cobertura/SIM/plano) | tenta a cada minuto, sem reset nem reboot |
| modem mudo (QMI sem resposta) | reset GPIO (`modem_switch boot`), máx. 1/10 min |
| registado mas sem dados | reset do modem → reboot com travão (15 min uptime, 3 seguidos) |
| kernel pendurado | `procd` + `/dev/watchdog` (hardware) |

Só exige mão humana: bootloader/overlay corrupto (TFTP com PC e cabo) e ausência total de
cobertura/plano.

---

## 8. Números finais (26/10, sem antenas externas)

```
LTE          RSRP -89 … -90 dBm, RSRQ -9, SINR 18–22, 2CA B3+B7
router       50 MB a 100 Mbps, upload 10–17 Mbps, ping 36 ms, 0 % perda
telemóvel    5 GHz -40…-45 dBm, 866/780 Mbps de PHY, esperado 679 Mbps
             108,3/10,7 → 121,1/13,9-15 → 127,6/20,5 Mbps (LTE, não Wi-Fi)
cabo (PC)    120,7 / 21,1 Mbps, IP público 176.223.x (MEO), ping 41 ms
modem        SIM READY, 29–34 °C, EG18EAPAR01A11M4G
```

---

## 9. Referências consultadas

- OpenWrt ToH do LBR20 — https://openwrt.org/toh/netgear/lbr20
  («DO NOT set the MTU… modem may work for 2 minutes then crash hard»; MBIM define o MTU
  sozinho e provoca o mesmo crash)
- openwrt/openwrt#19432 — LBR20 + EG18-EA A11: em QMI só liga após reboot com PDP `ipv4`;
  MBIM resolve o arranque mas as quedas de ~24 h mantêm-se nos dois modos
- openwrt/openwrt#21617 — lock-up do Quectel com MTU definido (QMI e MBIM/ModemManager)
- https://openwrt.org/docs/guide-user/network/wan/wwan/ltedongle — MSS fixo em vez de MTU,
  watchdog, reboot agendado do modem
- NETGEAR Community — «LBR20 keeps disconnecting from LTE» (relatos de quedas com sinal baixo)

---

## 10. Não fazer

- Não apertar antenas de Wi-Fi (RP-SMA) nos SMA do LTE.
- Não definir `option mtu` na `wan`/`wwan0` (crasha o Quectel); não mudar para MBIM.
- Não flashar o firmware do modem para A13 (não faz downgrade).
- Não repor `mtu_fix='1'` (volta a dar MSS 1460 num path de 1400).
- Não usar band lock: o modem gere B3/B7 conforme a carga e o ToH desaconselha.

---

## 11. Pendente

- Medições fora da hora de ponta: `/root/speedtest.sh` no aparelho escreve em
  `/root/speedtest.log` (uma linha por execução). Baseline de 27/10 21:45: **44 / 8 Mbps,
  RSRP -97, SINR 17**. As execuções agendadas para 22:45 e 23:45 perderam-se por o router
  ter sido desligado.
- Instalação na loja: confirmar `quedas24h` em `http://192.168.10.1:8080/loja.json` e, se o
  sinal local for pior que -100 dBm, considerar antena LTE em condições (medir `AT+QRSRP`).
