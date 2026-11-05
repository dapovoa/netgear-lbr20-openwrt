# Tutorial: NETGEAR LBR20 (Orbi 4G LTE) -> OpenWrt, LTE e modo loja

Passo a passo do que foi feito neste aparelho, na ordem em que foi feito, com as
verificações. Tudo medido; nada copiado sem confirmar.

Estado final: OpenWrt 25.12.6, LTE a 80 Mbps, Wi-Fi `dinaferreira.pt` para clientes e
o POS isolado por cabo numa rede própria.

---

## 0. Antes de tocar em nada

```sh
# o stock tem de estar em estado de fabrica conhecido
curl -s -H 'Host: orbilogin.com' http://192.168.1.1/currentsetting.htm
# Model=LBR20 Firmware=V2.6.5.2WW RegionTag=LBR20_WW isBlankState=? uptime=?
```

`isBlankState=1` = o wizard de fabrica nunca foi concluido. Consequencias:

- login de admin = `admin` / `password`
- **o menu `Advanced` nao existe** e portanto **nao ha Firmware Update** ate o wizard
  estar fechado. Isto e o que bloqueia o flash, nada mais.

## 1. Chegar ao aparelho quando o IPv4 nao responde

Sintoma real: sem IPv4 na LAN (ARP `FAILED`, sem DHCP), mas o aparelho esta vivo.
Chegar por IPv6 link-local (EUI-64 do MAC base):

```sh
ping -6 ff02::1%enp2s0                 # descobrir vizinhos
ip -6 neigh show dev enp2s0            # -> fe80::<eui64> (derivado do MAC)
curl -g -H 'Host: orbilogin.com' "http://[fe80::<eui64>%25enp2s0]/currentsetting.htm"
```

Sem o `Host: orbilogin.com` a UI redirecciona para `http://orbilogin.com` e vem vazio.
Browser: Firefox aceita `[fe80::...%25eth0]`, Chrome nao aceita scope id.

Se `192.168.1.1` tambem existir na Wi-Fi (router do ISP), o browser vai sempre ao
errado. Rota /32 forca o cabo sem tocar na default:

```sh
nmcli con modify "<cabo>" +ipv4.routes "192.168.1.1/32" && nmcli con up "<cabo>"
```

## 2. Fechar o wizard (obrigatorio)

UI -> aceitar termos -> APN `internet`, autenticacao `Nenhum`, user/pass vazios ->
ignorar satelites Orbi. Confirmar: `isBlankState=0`.

Se o APN falhar, nao importa: nao e preciso LTE para flashar.

## 3. Flash

```
AVANCADO -> Administracao -> Atualizacao de firmware
ficheiro: openwrt-25.12.6-ipq40xx-generic-netgear_lbr20-squashfs-factory.img
aviso "versao mais antiga" -> aceitar.  ~5 min, nao desligar.
```

Cabo na **LAN2** durante o flash. Stock: `4e1ee8ec...c657e` (13 500 545 B).

Se falhar: TFTP recovery (`sudo ./recover-tftp.sh` em `scripts/`), reset premido no
arranque, PC em `192.168.1.10`, UDP 69, e desligar o ufw.

## 4. LTE: o PDP type e a armadilha

O perfil ja traz `wan = qmi` em `/dev/cdc-wdm0`. **`pdptype='ipv4v6'` pendura** a
activacao: o `uqmi --start-network` do netifd nunca retorna, fica um cliente WDS preso,
e a partir daí todos os comandos QMI falham (`Failed to connect to service`).

```sh
uci set network.wan.pdptype='ipv4'
uci set network.wan.ipv6='0'
uci set network.wan.auth='none'
uci commit network
ifup wan
```

Se o QMI ja estiver preso:

```sh
killall -q uqmi
uqmi -d /dev/cdc-wdm0 --sync
printf 'AT+CFUN=1,1\r' > /dev/ttyUSB2     # reset do modem, re-enumera no USB, ~50 s
uqmi -d /dev/cdc-wdm0 --sync
ifup wan
```

Verificar:

```sh
ifstatus wan | grep '"up"'                  # true
ip -4 addr show wwan0 | grep inet           # 10.x.x.x (CGNAT)
ping -c3 1.1.1.1
```

Modem neste aparelho: Quectel **EG18-EA**, firmware `EG18EAPAR01A11M4G`, registado MCC 268.
`+CREG: 0,1` por AT. Nao afinar MTU: 1500 e um download de 20 MB passou limpo
(ao contrario de RNDIS, onde o MTU errado e o bug).

## 5. Config base

```sh
uci set network.lan.ipaddr='192.168.2.1/24'      # fora da rede do ISP
uci set system.@system[0].timezone='WET-0WEST,M3.5.0/1,M10.5.0'
uci set system.@system[0].zonename='Europe/Lisbon'
# sem IPv6 no LAN quando o uplink e IPv4
uci -q delete network.lan.ip6assign
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ra='disabled'
/etc/init.d/odhcpd disable
# servicos so na LAN
uci set uhttpd.main.listen_http='192.168.2.1:80'
uci set uhttpd.main.listen_https='192.168.2.1:443'
uci -q add_list dhcp.@dnsmasq[0].notinterface='wwan0'
uci set dropbear.main.Interface='lan'
uci set dropbear.main.GatewayPorts='0'
# CPU por pacote
uci set firewall.@defaults[0].flow_offloading='1'
uci set firewall.@defaults[0].flow_offloading_hw='0'
# radio
uci set wireless.radio0.country='PT'
uci set wireless.radio1.country='PT'
uci set wireless.default_radio0.ssid='<SSID>'
uci set wireless.default_radio0.encryption='psk2'
uci set wireless.default_radio0.key='<KEY>'
uci set wireless.default_radio0.disabled='0'
uci set wireless.default_radio1.ssid='<SSID>'
uci set wireless.default_radio1.encryption='psk2'
uci set wireless.default_radio1.key='<KEY>'
uci set wireless.default_radio1.disabled='0'
uci commit
```

Canal 2,4 GHz por censo, nao por hábito:

```sh
iwinfo phy1-ap0 scan | awk -F: '/Channel:/{gsub(/ /,"",$2); print $2}' | sort -n | uniq -c
# neste local: ch1=9 APs, ch11=2  -> ficou ch11 ; 5 GHz em ch36 VHT80 (2 vizinhos)
```

**Cuidado com o "Bind to Interface" do LuCI:** escreve `dropbear.main._direct='1'` +
`DirectInterface='lan'`, que o init **nao usa** depois de um reload de rede, e o SSH morre
(`Connection refused`). Usar `Interface='lan'`. Sem SSH, corrige-se por ubus over HTTP:

```sh
curl -s -X POST http://192.168.2.1/ubus -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"call","params":["00000000000000000000000000000000",
      "session","login",{"username":"root","password":"<pw>"}]}'
# depois, com o ubus_rpc_session: uci delete/set + uci commit + uci apply
```

## 6. O arranque: a corrida que deixava o LTE em baixo

Ao arrancar, o netifd tenta o `wan` antes de o modem enumerar:

```
[13s] wan: The specified control device does not exist
[33s] cdc-wdm0: USB WDM device
[34s] wan: ls .../2-1:1.4/net: No such file or directory -> interface could not be found
```

O `qmi` falha, deixa clientes presos, e o `wan` fica `up: false` ate alguem la ir. Num
corte de luz o router ficava sem internet. Correccao (testada com reboot: sobe sozinho):

```sh
uci set network.wan.auto='0'; uci commit network     # nao tentar antes do device existir
```

`/etc/hotplug.d/net/30-wwan-ifup`:

```sh
[ "$INTERFACE" = "wwan0" ] || exit 0
( sleep 6; uqmi -d /dev/cdc-wdm0 --sync >/dev/null 2>&1; sleep 1; ifup wan ) &
```

`/etc/rc.local`:

```sh
( sleep 40; /usr/bin/watch-router.sh ) &
service sysntpd restart
exit 0
```

`/usr/bin/watch-router.sh` (ver `scripts/`), cron `* * * * *`:
ping a 1.1.1.1 e 9.9.9.8 por `wwan0` -> `--sync`+`ifup` -> `AT+CFUN=1,1` -> 3 falhas
seguidas = reboot do router. Log persistente em `/root/watch-router.log` (flash),
rodado a 300 linhas. Lock com expiracao de 5 min (`-mmin +5`): um lock preso bloqueia
todas as execucoes seguintes.

## 7. Modo loja: uma Wi-Fi, POS por cabo

Requisito: clientes entram por QR numa Wi-Fi unica; o POS (PC a parte, browser HTTPS
para a app da empresa) nao pode partilhar o segmento com eles.

```sh
# lan2 sai da bridge; fica rede propria
uci set network.@device[0].ports='lan1'
uci set network.pos=interface
uci set network.pos.proto='static'
uci set network.pos.device='lan2'
uci set network.pos.ipaddr='192.168.10.1/24'
uci set dhcp.pos=dhcp
uci set dhcp.pos.interface='pos'
uci set dhcp.pos.start='100'
uci set dhcp.pos.limit='50'
uci set dhcp.pos.leasetime='12h'
uci set dhcp.pos.dhcpv6='disabled'
uci set dhcp.pos.ra='disabled'
# zona isolada, so saida para a wan
uci add firewall zone
uci set firewall.@zone[-1].name='pos'
uci set firewall.@zone[-1].network='pos'
uci set firewall.@zone[-1].input='REJECT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'
uci set firewall.@zone[-1].masq='1'
uci set firewall.@zone[-1].mtu_fix='1'
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='pos'
uci set firewall.@forwarding[-1].dest='wan'
uci add firewall rule
uci set firewall.@rule[-1].name='pos-dhcp-dns'
uci set firewall.@rule[-1].src='pos'
uci set firewall.@rule[-1].proto='udp tcp'
uci set firewall.@rule[-1].dest_port='53 67'
uci set firewall.@rule[-1].target='ACCEPT'
uci commit
```

A zona nao e "para o cabo": e o que da NAT, bloqueia `pos -> lan`, bloqueia o POS ao
SSH/LuCI do router e abre so DHCP/DNS. Sem zona: ou nao ha internet, ou o POS fica no
mesmo segmento dos clientes.

Verificacao:

```sh
ping -c2 192.168.10.1        # da LAN: 100% loss  (isolamento)
nft list chain inet fw4 forward | grep lan2     # jump forward_pos
iwinfo | grep ESSID                             # so a SSID de clientes
```

## 8. Backup

```sh
sysupgrade -b /tmp/backup.tar.gz     # no router
# copiar: ssh ... 'cat /tmp/backup.tar.gz' > backup.tar.gz   (scp -B nao existe)
```

O backup **nao** contem firmware. Em equipamento limpo: flashar a factory primeiro.

## 9. Verificacao final (valores deste aparelho)

```
firmware  25.12.6 r33311-981c978eff      overlay 156 KB de 59,6 MB
RAM       68 MB de 505 MB                161 pacotes, 22 servicos
LAN       192.168.2.1/24                 LTE 10.x.x.x/28, 80 Mbps, ping 38-88 ms
wifi      ch11 VHT20 + ch36 VHT80        WPA2-CCMP
POS       192.168.10.0/24 na lan2        isolado
CPU       ~10% durante download a 80 Mbps nos 4 cores
```
