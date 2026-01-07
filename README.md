Update:  

I ultimately resolved this by replacing the WiFi card in my Omnibook. I forgot to have my uninstall script reset the wifi.powersave line. If you decide to do the same and want to change it back to normal type the following into your terminal:

sudo nano /etc/NetworkManager/conf.d/wifi-powersave.conf

Arrow down to "wifi.powersave=2", and change it to a 3.

Ctrl + o then press enter to save, ctrl + x to exit.

If you have an AMD laptop, I would highly recommend this card as a replacement. It still disconnects randomly on rare occasion (~once a day, if using basically constantly all day), but the WiFi never fully breaks (connection restores pretty quickly), and it supports WiFi 7: https://www.amazon.com/EDUP-Wireless-Bluetooth-Tri-Band-Compatible/dp/B0FZJQF4DW

Please do research and acquire the right tools (an iFixit set for example) before attempting the same. However, with the proper research and tools, this only took about 15 minutes, upgraded my WiFi, and ended the issues.

Original readme:

Fixes issues where WiFi network discovery fails after the system was suspended. Creates a system service to run at boot and reset the WiFi with each wake. Also restricts some WiFi power saving options to prevent WiFi drops when in use. It may take a bit longer reconnecting, but that is far better than wifi breaking altogether.

This fix has been generalized towards any WiFi card drivers, including auto-detection for the drivers in use. However, this was created originally to resolve issues with the MediaTek MT7922 WiFi card.

This requires an OS that uses systemd and NetworkManager, which is the vast majority of major Linux distributions. Although it was created primarily for Zorin OS, distros such as Ubuntu and Mint should also be supported. To test if this fix would work for you, run the following command:

systemctl is-active NetworkManager  
command -v nmcli journalctl systemctl ip modprobe

You should recieve an output like this if your distro is supported:

active  
/usr/bin/nmcli  
/usr/bin/journalctl  
/usr/bin/systemctl  
/usr/sbin/ip  
/usr/sbin/modprobe

To use, make sure all scripts are in the same folder, then run install.sh. This can be done by right clicking the install script, and running it as a program under the drop down. If this option doesn't appear, go to properties in the same drop down and select "Executable as program". Alternatively, you could right click the empty space in the directory that contains the scripts, select "Open in terminal", and run the following commands:

chmod +x install.sh  
./install.sh



This fix was originally for the Omnibook Flip, but should apply for all laptops facing similar issues.
