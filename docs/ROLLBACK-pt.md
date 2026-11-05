# Reverter o LBR20 para o firmware original (NETGEAR V2.7.7.10)

**Verificado a 27/10/2026, num LBR20 com OpenWrt 25.12.6.** Resultado: stock `V2.7.7.10WW`
a correr, `isBlankState=0`. Processo completo em ~6 min.

> Aviso importante: a receita do ToH («use your laptop to TFTP an image **into** the device»)
> é fácil de ler ao contrário. **O bootloader não pede a imagem: é ele que serve TFTP e nós
> é que fazemos PUT.** Com um servidor TFTP do lado do PC (à espera de pedidos) não acontece
> nada — foi o que se passou na primeira tentativa.

## 1. Material

```
firmware/LBR20-V2.7.7.10.img    42 862 721 B   (é um .chk: começa com "device:LBR20\nversion:...")
sha256 6b4614724a272447f5703a6dc9c3d84d5c854377a11b5d74e395c739a19bedf8
```

## 2. Preparação

1. Router **desligado da corrente**.
2. Cabo Ethernet do PC para a porta **LAN2** (a da direita).
3. No PC (precisa de `sudo`): tirar a interface do NetworkManager e pôr o IP fixo. O
   NetworkManager volta a agarrar o dispositivo e **limpa os IPs** se não for marcado como
   não-gerido:
   ```sh
   sudo nmcli con down "Wired connection 1"
   sudo nmcli device set eno1 managed no
   sudo ip addr flush dev eno1
   sudo ip addr add 192.168.1.10/24 dev eno1
   sudo ip link set eno1 up
   ```
4. Confirmar que não há firewall a bloquear: `sudo ufw status` (se activo, `sudo ufw disable`).

## 3. Entrar no recovery

Com o router **desligado**: premir e **manter o RESET** (orifício do clip do SIM) → ligar a
ficha → **manter ~30 s** → largar.

Sinal: a torre pisca a branco e o LED de power (junto à ficha) pisca a vermelho. Nesse modo o
router fica em **192.168.1.1**, responde a `ping`, **não tem portas TCP** e **não pede TFTP**
(é servidor).

Verificação rápida: `ping -c2 -I 192.168.1.10 192.168.1.1` (0,1 ms) e
`curl -s tftp://192.168.1.1/x` (não responde a leituras — é normal).

## 4. Enviar a imagem (PUT)

```sh
cd /run/media/vmef/NVME/github/netgear-lbr20-openwrt
curl -# --interface 192.168.1.10 -T firmware/LBR20-V2.7.7.10.img \
     tftp://192.168.1.1/LBR20-V2.7.7.10.img
```

- A barra de progresso chega a **100,0%** em ~25 s (o bootloader negocía blocos grandes, não
  512 B).
- A seguir o router **deixa de responder ao ping** — está a gravar e a reiniciar. **Não tocar**
  durante ~2 min.

## 5. Confirmar

```sh
curl -s -I --interface 192.168.1.10 http://192.168.1.1/currentsetting.htm   # ou GET
```
Deve devolver:
```
Model=LBR20  Firmware=V2.7.7.10WW  RegionTag=LBR20_WW  Region=ww  ...  isBlankState=0
```
`isBlankState=0` = a NVRAM antiga foi preservada (era o esperado). `InternetConnectionStatus=Down`
com o SIM fora é normal.

## 6. Deixar de fábrica (para devolver)

1. Com o stock a correr, **premir RESET ~10 s** → reset de fábrica da NETGEAR (volta a
   `isBlankState=1` e ao assistente; apaga SSID/chave antigos).
2. **Retirar o nano-SIM** (tem o perfil APN do operador).
3. Confirmar que o Wi-Fi antigo desapareceu.

## 7. Repor o PC

```sh
sudo nmcli device set eno1 managed yes
sudo nmcli con up "Wired connection 1"
sudo ufw enable          # se estava activo no início
```

Cuidado: o stock usa **192.168.1.1**, igual ao router da fibra. Com o cabo ligado e a
Wi-Fi ligada há colisão de rotas/ARP. Para configurar o stock, desligar a Wi-Fi
(`nmcli radio wifi off`), terminar, e voltar a ligar (`nmcli radio wifi on`).

## 8. Voltar ao OpenWrt mais tarde

Flashar `firmware/openwrt-25.12.6-ipq40xx-generic-netgear_lbr20-squashfs-factory.img` pelo UI
do stock (Firmware Update). O stock da NETGEAR não é assinado: não precisa de imagem
intermédia. A NVRAM é preservada (voltar ao stock recupera as definições anteriores).

## 9. O que se perde

Watchdog do LTE, MSS fixo 1360, topologia POS/clientes (`br-pos`/`br-lan`), guarda de boot,
`/etc/firewall.user`. O stock **não tem watchdog**: as quedas de LTE descritas em
`docs/DIAGNOSTICO-2026-10-26-27.md` voltam a acontecer. O firmware do **modem** não é tocado
por este processo (ficou em `EG18EAPAR01A11M4G`).
