# NETGEAR Orbi 4G LTE Router LBR20 - OpenWrt

Substituto do Cudy LT300 (ver [[cudy-lt300-openwrt]]). Chegou a 2026-10-25.
Estado: stock Netgear, nunca configurado. Ainda não flashado.

## Hardware

- SoC Qualcomm IPQ4019 (4x Cortex-A7, 717 MHz) + QCA9888 para a 3.ª rádio
- Wi-Fi AC2200 tri-band: 2,4 GHz 400 + 5 GHz 866 + 5 GHz 866 (backhaul dedicado)
- Modem interno **Quectel EG18** Cat 18, **QMI** (`/dev/cdc-wdm0`, `wwan0`), AT em `/dev/ttyUSB2`
- 2 portas GbE: `WAN/LAN1` e `LAN2` (usar sempre a **LAN2** para configurar)
- 2 conectores SMA para antena LTE externa + **nano-SIM** (confirmado no datasheet)
- RAM/flash: **não documentado** (a tabela da ToH vem vazia). A confirmar no aparelho.

## Unidade em casa (identificada 2026-10-25)

Endpoint não autenticado `http://192.168.1.1/currentsetting.htm`:

```
Model=LBR20            Firmware=V2.6.5.2WW    RegionTag=LBR20_WW   Region=ww
isBlankState=1         InternetConnectionStatus=Down
LoginMethod=2.0        SOAPVersion=3.76       XCloudSupported=1
```

- MAC base `c8:9e:43:xx:xx:xx` (OUI NETGEAR). LAN stock `192.168.1.1`, web UI
  apresenta-se como "NETGEAR Router Orbi" - **é o mesmo aparelho que aparecia como
  "Orbi" no cabo**, não havia um segundo dispositivo.
- Portas à escuta (stock): `53/tcp`, `80`, `443`. Sem SSH.
- `isBlankState=1` = nunca passou o setup. Neste estado o DHCP entrega IP e DNS mas
  **não anuncia opção router** -> o cliente fica com IP e sem default route
  (foi o que se viu: `192.168.1.2/24`, gateway vazio, `curl --interface enp2s0` = 000).
- Colisão: a LAN stock é `192.168.1.1`, igual ao TP-Link da fibra (mesma armadilha
  ARP flux do LT300). Mudar para `192.168.2.1`.

## Suporte OpenWrt: confirmado (3 vias)

```
target            : ipq40xx/generic
profile           : netgear_lbr20
supported_devices : ["netgear,lbr20"]
presente em       : 24.10.5 e 25.12.6 (25.12.6 é a última release)
ToH               : https://openwrt.org/toh/netgear/lbr20
```

Imagens 25.12.6:

| Ficheiro | Bytes | sha256 |
|---|---|---|
| `...-netgear_lbr20-squashfs-factory.img` | 13 500 545 | `4e1ee8ecb765d0a0b30adb7302e26ff856d1a1ab066dbb9cfae47a727c6c657e` |
| `...-netgear_lbr20-squashfs-sysupgrade.bin` | 8 591 906 | `9b9c6f079075d13e184436eebe319ab371921372e88b389bdf76ea9d6eeff1da` |
| `...-netgear_lbr20-initramfs-zImage.itb` | 7 918 052 | `e4bffb96323537d706b3ef67b52026fa26eb76e23b02a28bf3ca0513267e7b14` |

`device_packages`: `ipq-wifi-netgear_lbr20 ath10k-firmware-qca9888-ct
kmod-usb-net-qmi-wwan kmod-usb-serial-option uqmi`. Limite de kernel 7 MiB.

## Instalação (OEM easy, sem abrir a caixa)

1. `factory.img` pelo UI do Netgear (Firmware Update). Aparece aviso de "versão mais
   antiga" -> aceitar. O stock da Netgear **não** tem o drama do firmware intermédio
   assinado da Cudy: não é preciso stepping stone.
2. A NVRAM (config Netgear/Voxel) **não é apagada**; voltar ao stock recupera as
   definições anteriores.
3. **Bug conhecido:** o `sysupgrade` entre versões de OpenWrt pode acabar em TFTP
   recovery. Fazer backup e ter TFTP à mão antes de qualquer upgrade.

### TFTP recovery (o mesmo caminho serve de debrick)

1. Tirar a corrente, **manter RESET** (clip de SIM) e voltar a ligar.
2. Esperar ~30 s antes de largar. Sinal: luz branca da torre a piscar + LED de power
   vermelho intermitente (junto à ficha).
3. PC em `192.168.1.10`, TFTP UDP 69, porta **LAN2** (nunca `WAN/LAN1`).
4. Enviar a imagem (stock ou OpenWrt factory).

## Armadilhas que matam (verificadas na ToH)

- **NUNCA fixar MTU** na interface `wwan`/QMI. O modem funciona ~2 min e crasha a
  sério, obrigando a reboot. MBIM faz o mesmo porque define MTU sozinho.
  Isto é o **inverso** da lição do LT300, onde MTU 1464 era obrigatório. Com QMI o
  MTU vem negociado do modem.
- **NUNCA** ligar os LEDs da torre (`backlights` no LuCI) a tráfego de `wwan0`:
  causa interferência de hardware e derruba o modem. Sólido por link status é OK.
- Firmware do modem (só se flasha a partir do stock Netgear/Voxel):
  NA = A05/A06 (A06 01.008, 05/2024, estável); EA = A08/A11/A13 (A13 de 07/2025,
  estável mas **não faz downgrade** - fica inutilizável). Deltas só `A08<->A11` (EA)
  e `A05<->A06` (NA); o resto exige `qfirehose -f /tmp`.
  A08 stock tem desligamentos -> precisa de `watch-router.sh` em cron.
- **Cat 18 é marketing:** só 2 antenas estão ligadas ao modem (ANTMAIN/ANTDIV);
  MIMO1/MIMO2 não têm sinal (`AT+QNWCFG="mimo_ctrl"` -> `0`; `AT+QRSRP` devolve
  `-140,-140` nos dois últimos). Logo, no máximo 2 bandas em agregação, nunca 1,2 Gbps.
- Modem em QMI por omissão. Para mudar:
  `echo -n -e 'AT+QCFG="usbnet",0\r\n' > /dev/ttyUSB2` (0=QMI, 2=MBIM).
- OpenWrt traz só IPv4 no wwan por omissão; `downloads.openwrt.org` tem tido problemas
  com IPv4 -> pôr `pdptype 'ipv4v6'` no `/etc/config/network`.

### Config UCI do wwan (QMI)

```
config interface 'wan'
    option proto 'qmi'
    option device '/dev/cdc-wdm0'
    option auth 'none'
    option ipv6 '1'
    option pdptype 'ipv4v6'
    option profile '3'      # perfil APN do SIM
    option v6profile '3'
    option apn 'internet'   # opcional, se o perfil do SIM não bastar
```

## Bandas: WW vs NA é a pergunta crítica

Duas variantes, confirmadas no datasheet oficial (`downloads.netgear.com/files/GDC/datasheet/en/LBR20.pdf`):

| Variante | LTE-FDD | LTE-TDD | 3G |
|---|---|---|---|
| **NA** | B2,4,5,7,12,13,14,17,25,26,29,30,66,71 | B41 | B1,4,5 |
| **EU & AU** | B1,3,5,7,8,20,28 | B38,40,41 | B1,3,5,8 |

Esta unidade reporta `RegionTag=LBR20_WW` / `Region=ww` -> deve ser **EG18-EA** (bandas
EU). **Falta confirmar no modem** com `AT+CGMM`/`ATI` em `/dev/ttyUSB2`: o stock não tem
shell (nem SSH nem `/debug.htm` exposto) e o telnet, se existir, só se liga pelo UI de
admin. Só depois de OpenWrt há shell.

## Artefactos descarregados (2026-10-25, `~/lbr20/`)

```
openwrt/openwrt-25.12.6-ipq40xx-generic-netgear_lbr20-squashfs-factory.img
  13 500 545 B  sha256 4e1ee8ecb765d0a0b30adb7302e26ff856d1a1ab066dbb9cfae47a727c6c657e  (verificado)
openwrt/openwrt-25.12.6-ipq40xx-generic-netgear_lbr20-squashfs-sysupgrade.bin
   8 591 906 B  sha256 9b9c6f079075d13e184436eebe319ab371921372e88b389bdf76ea9d6eeff1da  (verificado)
netgear-stock/LBR20_V2.7.7.10.zip
  42 414 876 B  sha256 87556837f49897255b97da9b4d7e33561a1f782326ce5f5ae6ba0c9db38d102a
  -> LBR20-V2.7.7.10.img (42 862 721 B), release 2026-09-09, "security fixes"
```

Stock instalado de fábrica: `V2.6.5.2WW`. O zip V2.7.7.10 serve de upgrade e de
rollback (o stock da Netgear não é assinado como o da Cudy - o UI aceita qualquer um
destes dois).

## Portátil: cabo separado do Wi-Fi (evitar derrubar a sessão)

O perfil do cabo está com `ipv4.never-default=sim` e `ipv4.route-metric=700`: o cabo
nunca ganha default route, por isso a internet (e a sessão do agente) fica sempre no
Wi-Fi de casa. Acesso ao router **obriga a fixar a interface**, porque `192.168.1.1`
existe nos dois caminhos:

```sh
curl --interface enp2s0 http://192.168.1.1/currentsetting.htm   # SO_BINDTODEVICE
ssh -B enp2s0 root@192.168.1.1                                  # depois de OpenWrt
```

Isto chega para CLI, mas **não para o browser**: o browser não escolhe interface, segue a
default route, e `http://192.168.1.1` cai no TP-Link da DIGI. **Solução: rota /32
pelo cabo**, que ganha por longest-prefix-match sem tocar na default route:

```sh
nmcli con modify "Ligação com fios 1" +ipv4.routes "192.168.1.1/32"
nmcli con up "Ligação com fios 1"
ip route get 192.168.1.1   # -> dev enp2s0   (LBR20)
ip route get 1.1.1.1       # -> via 192.168.1.1 dev wlp3s0   (internet intacta)
```

A rota vive no perfil do cabo, logo só existe com o cabo ligado. **Efeito colateral:
com o cabo ligado, o UI do TP-Link em `192.168.1.1` fica inacessível** - desligar o cabo
para lá chegar. Remover quando o LBR20 passar a `192.168.2.1`:
`nmcli con modify "Ligação com fios 1" -ipv4.routes "192.168.1.1/32"`.

Quando a LAN do LBR20 passar a `192.168.2.1` a ambiguidade desaparece sozinha.

## Acesso ao stock (2026-10-25)

- Login de admin: **`admin` / `password`** (default de fábrica, coerente com `isBlankState=1`).
  A chave do Wi-Fi `ORBI45` é outra coisa e **não serve** para login `admin`.
- SOAP funciona em `POST /soap/server_sa/`, com `SOAPAction:
  "urn:NETGEAR-ROUTER:service:<Svc>:1#<Method>"` e um header `SessionID=AUTH`.
  `DeviceConfig:1#SOAPLogin` devolve `<ResponseCode>000</ResponseCode>` = ok; `401` = credencial má.
- Serviços que existem: `DeviceConfig:1`, `DeviceInfo:1`, `WLANConfiguration:1`, `Time:1`,
  `WANIPConnection:1`, `ParentalControl:1`. **Não existe** nenhum serviço de LTE
  (`Cellular`, `CellularInterface`, `WWAN`, `LTE`, `Mobile`, `Sim` -> todos `404`).
  Logo, o estado do modem **não sai por API** no stock; só pelo UI ou por shell.
- Sem shell no stock: sem SSH, `/debug.htm` devolve a splash genérica (telnet não acessível).
- Leitura útil: `GET /currentsetting.htm` (sem auth) -> modelo, firmware, região,
  `InternetConnectionStatus`, `uptime`.

```
serial   <REDACTED>           firmware V2.6.5.2 (WW)
LAN      192.168.1.1
WAN eth  proto DHCP, ExternalIP 0.0.0.0  (nada ligado em WAN/LAN1)
TZ stock "Sunday, 30 Sep 2007" (relógio errado, sem NTP)
```

**Nota desta máquina:** o agente não tem `sudo` aqui (não pode `ip addr add` nem
`nmcli con modify`... este último até passa por polkit). Consequência prática: o recovery
TFTP (que exige IP fixo `192.168.1.10` no cabo) **tem de ser feito pelo utilizador**.
Isso torna o flash por API não documentada uma má ideia - usar o UI do Netgear.
O `ufw` está **ativo** nesta máquina (o mesmo bloqueio de UDP 69 que atrasou o recovery do
LT300) - o script de recovery desliga-o e repõe-no no fim.

## Scripts (2026-10-25, em `~/lbr20/`)

- `preflight.sh` (sem sudo): valida hashes, link, resposta do LBR20, e se o cabo está
  sem default route. Imprime o checklist. Corrido: tudo OK.
- `recover-tftp.sh` (**sudo**): tira o `enp2s0` do NetworkManager, põe
  `192.168.1.10/24`, desliga o ufw, arranca `dnsmasq` como servidor TFTP na pasta do
  stock, mostra os pedidos do bootloader e no fim repõe tudo (trap em EXIT/INT/TERM).
  Uso: `sudo ./recover-tftp.sh [imagem]`, `IFACE=`/`WAIT_SECS=` por ambiente.
  Não filtra por IP de origem (o bootloader pede de um IP próprio, já visto `192.168.1.119`
  no caso do LT300).
- Os dois passam `bash -n`; o preflight foi executado com o LBR20 ligado.

## Pendente / próximo passo

- [x] Descarregar stock firmware da Netgear para rollback (V2.7.7.10)
- [x] Descarregar `factory.img` + `sysupgrade.bin` 25.12.6 (shas verificados)
- [x] Scripts `preflight.sh` e `recover-tftp.sh`
- [x] SIM inserida (confirmado pelo utilizador)
- [ ] **Mover o cabo de `WAN/LAN1` para `LAN2`** antes de flashar (no stock o `WAN/LAN1`
      funciona como LAN e dá DHCP; no OpenWrt o mapeamento pode ser outro)
- [ ] Flash `factory.img` pelo UI do Netgear (aviso de versão antiga -> aceitar)
- [ ] No OpenWrt: LAN para `192.168.2.1`, root password -> SSH, `AT+CGMM` (EG18-EA?), QMI
      com `pdptype ipv4v6` e **sem MTU**
- [ ] Mudar LAN stock para `192.168.2.1` (colisão com o TP-Link)
- [ ] Flash `factory.img` pelo UI do Netgear (aviso de versão antiga -> aceitar)
- [ ] No OpenWrt: LAN para `192.168.2.1`, root password -> SSH, `AT+CGMM` (EG18-EA?), QMI
      com `pdptype ipv4v6` e **sem MTU**

## Modo loja (2026-10-25, decisao final)

Requisito do utilizador: **uma só Wi-Fi** (`dinaferreira.pt`, chave partilhada por QR para
os clientes) e o **POS numa rede separada por cabo**. Sem SSID de POS, sem rede de
convidados: ambas foram criadas e removidas a pedido.

```
dinaferreira.pt   192.168.2.0/24    clientes + telemoveis da loja   lan1 + radios
lan2              192.168.10.0/24   PC do POS (DHCP .100-.149)     zona 'pos'
```

Zona `pos`: input REJECT, forward REJECT, masq 1, forwarding `pos -> wan`, regra
`pos-dhcp-dns` (53/67). Verificado: da LAN, `ping 192.168.10.1` = 100% loss.
O POS e um PC a parte (browser HTTPS para a app da empresa); como e outro equipamento,
a decisao de o ligar por cabo nao depende do portatil de configuracao.

### Porque o firewall nao e "para o cabo"

A porta e so L2; o que existe atras e uma rede, e no OpenWrt toda a rede pertence a uma
zona. A zona e que da NAT (`masq`), impede `pos -> lan`, impede o POS de falar com o
SSH/LuCI do router (`input REJECT`) e abre apenas DHCP/DNS. A alternativa - deixar a
`lan2` dentro da `br-lan` - mete o POS no mesmo segmento dos clientes Wi-Fi.

### Artefactos

```
config/uci-export.txt        export de network/wireless/firewall/dhcp/system/dropbear
                             (chaves e passwords substituidas por <REDACTED>)
config/rc.local-e-cron.txt   arranque + watchdog
scripts/watch-router.sh      vigia do uplink (escada de recuperacao + reboot com travao)
scripts/ap-isolate.sh        isolamento cliente/cliente
scripts/30-wwan-ifup         hotplug que entrega ao watch-router.sh
scripts/40-ap-isolate        hotplug que aplica o ap-isolate
scripts/install-router.sh    empurra os scripts + uci/firewall/cron, verifica sha256
TUTORIAL-pt.md               passo a passo completo (flash -> LTE -> wifi -> zonas -> backup)
```
