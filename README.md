# Slightly customized OpenWrt fork based on official OpenWrt 19.07 release

[![Build Status](https://travis-ci.com/DarkCaster/OpenWrt-1907-Custom.svg?branch=custom)](https://travis-ci.com/DarkCaster/OpenWrt-1907-Custom)

Customizations and patches applied to original OpenWrt 19.07 source code:

## NETGEAR WNR2200 board support

* Added build profile for 16MiB-flash board version, suitable for Russian and (maybe) Chinese router revisions.

### _WARNING!_

_Do not try to flash 16MiB firmware to 8MiB board version - it may damage WiFi calibration data stored in ART system partition, and will cause permanent malfunction in WiFi._
_See more info [here](https://wiki.openwrt.org/doc/howto/generic.backup)._

## Xunlong Orange Pi Zero changes (only for original 256/512M versions, not for PLUS or LTS models)

* Enabled 2 external USB ports (using pins 1-6 at 13-pin expansion connector).
See [this](https://github.com/openwrt/openwrt/pull/1702) pull request for more info.

## Procd changes

* Changes to "tmpfs on zram" feature - altered options for mkfs.ext4, added some mount options in order to improve performance a bit

## Other kernel patches and config changes

* Some minor changes. TODO: verbose description.
