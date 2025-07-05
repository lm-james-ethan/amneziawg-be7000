# AmneziaWG for Xiaomi Router BE7000

This script route all from the LAN network to the AmneziaWG server.\
Tested with firmware Version: 1.1.16

1. Install [AmneziaWG](https://amnezia.org/ru/self-hosted) onto your VPS.
2. Connect to your brand new AmneziaWG server using the Amnezia client.
3. In the client create a new connection for your router, and save the config in _AmneziaWG native format_. It is supposed that the name of the file will be `amnezia_for_awg.conf`.
4. [Enable SSH](https://github.com/openwrt-xiaomi/xmir-patcher) on your router.
5. SSH to your router and create a `/data/usr/app/awg` directory.
6. Put `amnezia_for_awg.conf` into this same directory /data/usr/app/awg
7. cd /data/usr/app/awg and tar -xzvf /data/usr/app/awg/awg.tar.gz
8. Make the downloaded script executable: `chmod +x /data/usr/app/awg/amneziawg-go` and `chmod +x /data/usr/app/awg/awg ` and `chmod +x /data/usr/app/awg/clear_firewall_settings.sh` and `chmod +x /data/usr/app/awg/awg_route_switch.sh` and `chmod +x /data/usr/app/awg/awg_watchdog.sh`
9. Run the script: `./awg_route_switch.sh up`
10. Now, the LAN network should be connected to your AmneziaWG server before the router reboots.
11. for auto reconnect awg0 `crontab -e` and add `* * * * * /bin/sh /data/usr/app/awg/awg_watchdog.sh >> /tmp/awg_watchdog.log 2>&1` save and exit and `/etc/init.d/cron restart`
12. Thanks for https://github.com/alexandershalin/


Binaries built from official sources: https://github.com/amnezia-vpn/

Useful links:
https://github.com/itdoginfo/domain-routing-openwrt


