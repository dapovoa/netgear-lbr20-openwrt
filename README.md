# NETGEAR LBR20 (Orbi 4G LTE) on OpenWrt

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![OpenWrt](https://img.shields.io/badge/OpenWrt-25.12.6-00B5E2.svg)
![Target](https://img.shields.io/badge/target-ipq40xx%2Fgeneric-green.svg)
![Device](https://img.shields.io/badge/device-LBR20-orange.svg)
![Shell](https://img.shields.io/badge/shell-ash%20%7C%20bash-lightgrey.svg)

The Orbi 4G LTE router on mainline OpenWrt, and the things that bite.

## Overview

Flashing the Orbi 4G LTE router to mainline OpenWrt. Measured on hardware.

1. Finish the stock wizard, then upload the OpenWrt factory image
2. Recover over TFTP when it bricks (no UART needed)
3. Reach the box over IPv6 link-local when the LAN IPv4 vanishes
4. Configure QMI without the traps (no MTU, no LED on `wwan0`)

## Hardware

| Part | Detail |
|------|--------|
| SoC | Qualcomm IPQ4019 (4x Cortex-A7, 717 MHz) + QCA9888 |
| RAM | 512 MB class |
| Wi-Fi | AC2200 tri-band: 2.4 GHz 400 + 5 GHz 866 + 5 GHz 866 (third radio usable as backhaul) |
| Ethernet | 2x GbE: `WAN/LAN1` and `LAN2` |
| Modem | Internal **Quectel EG18** Cat 18 on **QMI** (`/dev/cdc-wdm0`, `wwan0`, AT on `/dev/ttyUSB2`) |
| SIM | Nano-SIM |
| Antennas | 2x SMA for external LTE antennas |

## OpenWrt Support

| Field | Value |
|-------|-------|
| Target | `ipq40xx/generic` |
| Profile | `netgear_lbr20` |
| Supported devices | `["netgear,lbr20"]` |
| Present in | 24.10.5 and 25.12.6 |

Release 25.12.6
([downloads](https://downloads.openwrt.org/releases/25.12.6/targets/ipq40xx/generic/)):

| Image | Bytes | sha256 |
|-------|-------|--------|
| `...-netgear_lbr20-squashfs-factory.img` | 13500545 | `4e1ee8ecb765d0a0b30adb7302e26ff856d1a1ab066dbb9cfae47a727c6c657e` |
| `...-netgear_lbr20-squashfs-sysupgrade.bin` | 8591906 | `9b9c6f079075d13e184436eebe319ab371921372e88b389bdf76ea9d6eeff1da` |
| `...-netgear_lbr20-initramfs-zImage.itb` | 7918052 | `e4bffb96323537d706b3ef67b52026fa26eb76e23b02a28bf3ca0513267e7b14` |

Device packages: `ipq-wifi-netgear_lbr20 ath10k-firmware-qca9888-ct kmod-usb-net-qmi-wwan
kmod-usb-serial-option uqmi`.

## Install

There is no signed-intermediate step: the stock Netgear web UI takes the OpenWrt factory
image directly.

1. **Swap the cable to `LAN2`**, not the `WAN/LAN1` port.
2. **Finish the OEM setup wizard.** While `isBlankState=1` the UI only offers the wizard and
   there is no *Advanced → Administration* menu yet. Check with
   `curl http://<router>/currentsetting.htm`.
3. **Upload the image** on *Advanced → Administration → Firmware Update*. It warns that the
   version is older; accept. About 5 minutes; do not power off.

The stock NVRAM is preserved, so flashing back to stock returns to the previous settings.

### Recovery / Debrick (TFTP, no UART)

1. Unplug power, hold RESET (SIM tool), plug back in, keep holding about 30 s.
2. Release when the tower LED blinks white and the power LED blinks red.
3. Laptop on `192.168.1.10`, `LAN2` port, TFTP UDP 69; send the stock `.img`
   (`scripts/recover-tftp.sh` does all of this).

The bootloader asks from its own address, not `.1` or `.10`, so do not filter by source IP.
Disable any host firewall first: it blocks UDP 69 and the failure looks like "no packets".

## Getting In When the LAN IPv4 Vanishes

Observed in the field: after power cycles, the LBR20 came back with **no IPv4 answering on
the LAN** (ARP `FAILED`, no DHCP offer) while the hardware was alive. Every IPv4 probe
returned nothing and the device looked bricked. It was not:

```
ping6 fe80::<eui64>%enp2s0                                -> 3/3, 0.46 ms
curl -g "http://[fe80::<eui64>%25enp2s0]/"                -> 200, Server: uhttpd/1.0.0
uptime advances (200 -> 220 in 20 s)                      -> stable, not a boot loop
```

The EUI-64 link-local is derived from the base MAC (flip bit 7 of the first byte, insert
`ff:fe` in the middle). Discover it and reach the stock UI over IPv6:

```sh
ping -6 -c2 ff02::1%enp2s0
ip -6 neigh show dev enp2s0
curl -g -H 'Host: orbilogin.com' "http://[fe80::...%25enp2s0]/currentsetting.htm"
```

The `Host: orbilogin.com` header matters: without it the UI redirects to
`http://orbilogin.com` and you get an empty page.

Firefox accepts `http://[fe80::...%25eth0]/`. Chrome does not support a scope id in the URL.
Use curl or Firefox.

When the same `192.168.1.1` also exists on the Wi-Fi path (ISP router), a browser picks the
default route and lands on the wrong device. A host route forces the cable without touching
the default route:

```sh
nmcli con modify "<wired>" +ipv4.routes "192.168.1.1/32" && nmcli con up "<wired>"
ip route get 192.168.1.1   # -> dev enp2s0
ip route get 1.1.1.1       # -> via 192.168.1.1 dev wlp3s0   (internet untouched)
```

## Stock Access

`isBlankState=1` means the factory wizard was never completed:

- Default admin login is **`admin` / `password`**.
- The UI only offers the wizard. There is **no *Advanced → Administration* menu**, so
  **Firmware Update is unreachable until the wizard is finished**. This is what blocks the
  flash, nothing else.
- The wizard asks for an APN: `internet`, auth none, empty user and password (DIGI PT).
  A failing LTE registration does not block the wizard or the flash.

Unauthenticated state probe:

```sh
curl -s -H 'Host: orbilogin.com' http://<router>/currentsetting.htm
# Model=LBR20 Firmware=V2.6.5.2WW RegionTag=LBR20_WW isBlankState=0 uptime=...
```

SOAP API: `POST /soap/server_sa/`, `SOAPAction: "urn:NETGEAR-ROUTER:service:<Svc>:1#<Method>"`,
header `SessionID=AUTH`. `DeviceConfig:1#SOAPLogin` returns `<ResponseCode>000</ResponseCode>`
on success and `401` on a bad credential.

| Present | Absent (404) |
|---------|--------------|
| `DeviceConfig:1`, `DeviceInfo:1`, `LAN:1`, `WLANConfiguration:1`, `WANIPConnection:1`, `Time:1`, `ParentalControl:1` | `Cellular`, `WWAN`, `LTE`, `Mobile`, `Sim` |

Modem state is not available over the API. There is no SSH on stock, and `/debug.htm` does
not exist.

## LED Truth Table

From the manual (chapter LEDs):

| Power LED | Meaning |
|-----------|---------|
| Solid amber | Booting |
| Blinking amber | Resetting to factory defaults |
| **Blinking red** | **Firmware is corrupted** |
| Off | No power |

| Ring / tower | Meaning |
|--------------|---------|
| Pulsing white | Booting (or Sync pressed) |
| Solid white | Resetting to defaults |
| Solid magenta | No Internet |
| Off | Booted and healthy |

A link LED is just PHY: it proves power and a negotiated link, nothing about the OS.

## QMI Config

```
config interface 'wan'
    option proto 'qmi'
    option device '/dev/cdc-wdm0'
    option auth 'none'
    option ipv6 '1'
    option pdptype 'ipv4v6'
    option profile '3'
    option v6profile '3'
    option apn 'internet'
```

OpenWrt defaults to IPv4-only on the cell interface, which breaks `apk update` against
IPv4-reachable mirrors. `pdptype ipv4v6` fixes it. Protocol switch, if ever needed:

```sh
echo -n -e 'AT+QCFG="usbnet",0\r\n' > /dev/ttyUSB2   # 0 = QMI, 2 = MBIM
```

### LTE Bands: Check the Variant

| Variant | LTE-FDD | LTE-TDD | 3G |
|---------|---------|---------|----|
| NA | B2,4,5,7,12,13,14,17,25,26,29,30,66,71 | B41 | B1,4,5 |
| EU & AU | B1,3,5,7,8,20,28 | B38,40,41 | B1,3,5,8 |

`RegionTag=LBR20_WW` means the EU/AU band set. Confirm on the modem with `AT+CGMM`.

## Pitfalls

1. **Never set the MTU** on the `wwan`/QMI interface. The modem runs about 2 minutes and then
   crashes hard, needing a reboot. MBIM does the same because it sets the MTU itself. This
   is the opposite of RNDIS sticks, where a wrong MTU is the usual bug.
2. **Never tie the tower LEDs to `wwan0` traffic.** It causes hardware interference that
   kills the cellular connection. Solid per-link-state is fine.
3. **`sysupgrade` between OpenWrt versions can reboot into TFTP recovery.** Back up first and
   keep TFTP ready.
4. **Cat 18 is marketing.** Only `ANTMAIN`/`ANTDIV` are connected to the modem; `ANTMIMO1/2`
   are not wired. `AT+QNWCFG="mimo_ctrl"` returns `0` and `AT+QRSRP` shows `-140,-140` for
   the last two, so it aggregates at most 2 bands, never 1.2 Gbps.
5. **Modem firmware variants:** NA = A05/A06 (A06 01.008 stable), EA = A08/A11/A13 (A13
   cannot be downgraded). Deltas exist only A08↔A11 (EA) and A05↔A06 (NA); anything else
   needs `qfirehose -f /tmp`.
6. **Stock A08 drops the connection** without `scripts/watch-router.sh` in cron.

## How to Use

```sh
git clone https://github.com/dapovoa/netgear-lbr20-openwrt.git
cd netgear-lbr20-openwrt
./scripts/preflight.sh                       # before flashing
sudo ./scripts/recover-tftp.sh               # debrick over TFTP
./scripts/install-router.sh                  # push scripts, rc.local, firewall, cron
./scripts/install-router.sh --verify         # compare sha256 only, no writes
```

| Variable | Default | Used by |
|----------|---------|---------|
| `ROUTER` | `root@192.168.2.1` | `install-router.sh` |
| `IFACE` | `enp2s0` | all three scripts |

## Repository Structure

```
netgear-lbr20-openwrt/
  config/
    uci-export.txt        uci export of the running box
    rc.local-e-cron.txt   rc.local and crontab
  scripts/
    install-router.sh     push everything over SSH + uci/firewall/cron, sha256 check
    watch-router.sh       uplink watchdog: recovery ladder, reboot brake, log
    ap-isolate.sh         client-to-client isolation (bridge ports)
    30-wwan-ifup          hotplug -> watch-router.sh (single owner of uqmi)
    40-ap-isolate         hotplug -> ap-isolate.sh
    preflight.sh          image hashes, link state, route checks before flashing
    recover-tftp.sh       TFTP recovery (root): takes the NIC from NetworkManager,
                          serves the stock image with dnsmasq, restores on exit
  NOTES-pt.md             full lab notes (Portuguese)
  TUTORIAL-pt.md          step-by-step tutorial (Portuguese)
```

## References

- [OpenWrt ToH: NETGEAR LBR20](https://openwrt.org/toh/netgear/lbr20)
- [OpenWrt 25.12.6 ipq40xx/generic](https://downloads.openwrt.org/releases/25.12.6/targets/ipq40xx/generic/)
- [NETGEAR LBR20 support](https://www.netgear.com/support/product/lbr20/)
- [LTE dongles](https://openwrt.org/docs/guide-user/network/wan/wwan/ltedongle)

## License

This project is under the MIT License. See the [LICENSE](LICENSE) file for details.
