Fixes issues where WiFi netowrk discovery fails after the system was suspended. Creates a system service to run at boot to reset the WiFi with each wake. Also restricts some WiFi power saving options to prevent WiFi drops when in use. It will cause a short delay in connection after the system wakes from suspending, but that is far better than the WiFi dying altogether.

This fix has been generalized towards any WiFi card drivers, including auto-detection for the drivers in use. However, this was created originally to resolve issues with the MediaTek MT7922 WiFi card.

This requires an OS that uses systemd and NetworkManager, which is the vast majority of major Linux distributions. Although it was created primarily for Zorin OS, distros such as Ubuntu and Mint should also be supported. To test if this fix would work for you, run the following command:

systemctl is-active NetworkManager

command -v nmcli journalctl systemctl ip modprobe

You should recieve an output like this is your distro is supported:

active

/usr/bin/nmcli

/usr/bin/journalctl

/usr/bin/systemctl

/usr/sbin/ip

/usr/sbin/modprobe
