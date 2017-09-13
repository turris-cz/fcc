#!/bin/sh

SSH="ssh root@192.168.2.1"

reload_hostapd() {
    if [ -n "`$SSH cat /var/run/wifi-$PHY.pid`" ]; then
        $SSH kill `$SSH cat /var/run/wifi-$PHY.pid`
        $SSH /usr/sbin/hostapd -P /var/run/wifi-$PHY.pid -B /var/run/hostapd-$PHY.conf \& > /dev/null 2> /dev/null 
    fi
}

get_channels() {
    $SSH iw $PHY info | sed -n 's|.*\* \([0-9]*\) MHz \[\([0-9]*\)\] (\([0-9.]*\) dBm.*|channel \2 (\1 MHz) - maximum power \3 dBm|p'
}

usb_test() {
    ans=""
    while [ "$ans" \!= F ] && [ "$ans" \!= B ]; do
        echo
        echo "Do you want to read from front usb or back usb? [F/B] "
        read ans
    done
    if [ $ans = B ]; then
        DEV=$(basename $($SSH ls -1d /sys/bus/usb/devices/5-1/5-1:1.0/host*/target*/*/block/sd[a-z]))
    else
        DEV=$(basename $($SSH ls -1d /sys/bus/usb/devices/3-1/3-1:1.0/host*/target*/*/block/sd[a-z]))
    fi
    echo
    echo "Press Ctrl+C to stop transmitting data"
    while $SSH cat /dev/$DEV | pv > /dev/null; do
        true
    done
}

set_frag() {
    choose_card
    echo
    echo "What should be the new fragmentation threshold (empty = off)?"
    read ans
    if [ -n "$ans" ]; then
        $SSH iw phy $PHY set frag $ans
    else
        $SSH iw phy $PHY set frag off
    fi
}

set_tx_power() {
    choose_card
    echo
    echo "What should be the new txpower in dBm?"
    read ans
    VALUE="`expr $ans \* 100`"
    $SSH iw phy $PHY set txpower fixed $VALUE
}

generate_hostpad() {
    chnum="$1"
    chw="$2"
    SIGN="$3"
    HT_CAP_ADD=""
    [ $WLAN = wlan1 ] || HT_CAP_ADD="[LDPC][MAX-AMSDU-7935]"
    if [ $chw = legacy ]; then
        WIDTH=""
    else
        VTH_W="0"
        if [ $chw -gt 40 ]; then
            VTH_W="1"
        fi
        WIDTH="
ieee80211n=1
ht_coex=0
ht_capab=`[ $chw -lt 30 ] || echo "[HT40$SIGN]"`${HT_CAP_ADD}[SHORT-GI-20][SHORT-GI-40][TX-STBC][RX-STBC1][DSSS_CCK-40]
"
        if [ $chw -gt 20 ] && [ $chnum -gt 13 ]; then
            WIDTH="$WIDTH
vht_oper_chwidth=$VTH_W
vht_oper_centr_freq_seg0_idx=`expr $chnum $SIGN 2 $SIGN $VTH_W \* 4`
ieee80211ac=1
vht_capab=[RXLDPC][SHORT-GI-80][TX-STBC-2BY1][RX-ANTENNA-PATTERN][TX-ANTENNA-PATTERN][RX-STBC-1][MAX-MPDU-11454][MAX-A-MPDU-LEN-EXP7]
"
        fi
    fi
    echo "
driver=nl80211
logger_syslog=127
logger_syslog_level=2
logger_stdout=127
logger_stdout_level=2
country_code=US
ieee80211d=1
ieee80211h=1
`if [ $chnum -gt 13 ]; then echo hw_mode=a; else echo hw_mode=g; fi`
channel=$chnum
`[ $chnum -lt 14 ] || echo ieee80211h=1`

$WIDTH

interface=$WLAN
ctrl_interface=/var/run/hostapd
ap_isolate=1
disassoc_low_ack=1
preamble=1
wmm_enabled=1
ignore_broadcast_ssid=0
uapsd_advertisement_enabled=1
auth_algs=1
wpa=0
ssid=Turris-Omnia-Test
bridge=br-lan
beacon_int=15
bssid=`$SSH ip a s dev wlan0 | sed -n 's|.*link/ether\ \([^[:blank:]]*\)\ .*|\1|p'`
" | $SSH cat \> /var/run/hostapd-$PHY.conf

}

set_channel() {
    choose_card
    echo
    echo "WARNING: Changing channel will clear MCS settings"
    echo
    echo -n "Enter channel number: "
    read chnum
    echo -n "Enter channel width (legacy, 20, 40 80): "
    read chw
    if [ $chw = legacy ]; then
        WIDTH=""
    else
        if [ $chw -gt 20 ]; then
            echo -n "HT40+ or HT40-? "
            read direct
            if [ $direct = "HT40+" ]; then
                SIGN="+"
            else
                SIGN="-"
            fi
        fi
    fi
    generate_hostpad "$chnum" "$chw" "$SIGN"
    reload_hostapd
}

set_beacon() {
    choose_card
    echo
    echo "WARNING: Changing beacon interval will clear MCS settings"
    echo
    echo -n "Enter prefered beacon interval (15..65536): "
    read num
    if [ "`$SSH grep beacon_int /var/run/hostapd-$PHY.conf`" ]; then
        $SSH sed -i "s|beacon_int=.*|beacon_int=$num|" /var/run/hostapd-$PHY.conf
    else
        $SSH echo "beacon_int=$num" \>\> /var/run/hostapd-$PHY.conf
    fi
    reload_hostapd
}

choose_card() {
    echo
    echo "Choose card:"
    echo " 0) wlan0 - ath10k (abcgn)"
    echo " 1) wlan1 - ath9k (bgn)"
    echo
    echo -n "Your choice? "
    read ans
    PHY=phy$ans
    WLAN=wlan$ans
}

toogle_card() {
    choose_card
    if [ "`$SSH ps w | grep hostapd | grep $PHY`" ]; then
        $SSH kill \`cat /var/run/wifi-$PHY.pid\`
        $SSH ip l s down dev $WLAN
    else
        $SSH ip l s up dev $WLAN
        if [ -z "`$SSH ls /var/run/hostapd-$PHY.conf`" ]; then
            if [ $WLAN = wlan0 ]; then
                generate_hostpad "36" "80" "+"
            else
                generate_hostpad "6" "legacy" ""
            fi
        fi
        $SSH /usr/sbin/hostapd -P /var/run/wifi-$PHY.pid -B /var/run/hostapd-$PHY.conf \& > /dev/null 2>&1
    fi
}

set_mcs() {
    choose_card
    CHANNEL="`$SSH iw dev $WLAN info | sed -n 's|.*channel \([0-9]\+\) .*|\1|p'`"
    DONE=""
    while [ -z "$DONE" ]; do
        clear
        echo "MCS menu for $WLAN"
        echo
        echo " 0) back to main menu"
        echo " 1) set legacy bitrate"
        echo " 2) set HT MCS"
        echo " 3) set VHT MCS"
        echo " 4) set SGI"
        echo " 5) set LGI"
        echo " 6) clear settings"
        echo
        if [ $CHANNEL -gt 13 ]; then
            BAND="5"
        else
            BAND="2.4"
        fi
        echo -n "Enter your command: "
        read ans
        case $ans in
            0) DONE="yes";;
            1) echo -n "Enter legacy bitrate: "; read bitrate; LEGACY="legacy-$BAND $bitrate" ;;
            2) echo -n "Enter HT MCS: "; read mcs; HT="ht-mcs-$BAND $mcs" ;;
            3) echo -n "Enter VHT NSS: "; read nss; echo -n "Enter VHT MCS: "; read mcs; VHT="vht-mcs-$BAND $nss:$mcs" ;;
            4) GI="sgi-$BAND" ;;
            5) GI="lgi-$BAND" ;;
            6) GI=""; LEGACY=""; HT=""; VHT="" ;;
            *) echo "Invalid option!";;
        esac
        $SSH iw dev $WLAN set bitrates $LEGACY $HT $VHT $GI
        sleep 2
    done
}

get_wifi_info() {
    for WLAN in wlan0 wlan1; do
    CHANNEL="`$SSH iw dev $WLAN info | sed -n 's|.*\(channel\)|\1|p'`"
    if [ -n "$CHANNEL" ]; then
        echo "$WLAN - on"
        echo " * $CHANNEL"
        echo " *" `$SSH iwconfig $WLAN | sed -n -e 's|.*Tx-Power=\(.*\)|TX power: \1|p' `
    else
        echo "$WLAN - off"
    fi
    done
}

main_menu() {
    while true; do
        clear
        echo "Testing framework for Turris Omnia"
        echo
        get_wifi_info
        echo
        echo "What would you like to do?"
        echo
        echo " 0) exit"
        echo " 1) stream data from USB over LAN"
        echo
        echo "WiFi:"
        echo " 2) set card on/off"
        echo " 3) set tx power"
        echo " 4) set MCS"
        echo " 5) set channel"
        echo " 6) set beacon interval"
#        echo " 5) set fragmentation threshold"
        echo
        echo -n "Enter your command: "
        read ans
        case $ans in
            0) exit 0;;
            1) usb_test ;;
            2) toogle_card ;;
            3) set_tx_power ;;
            4) set_mcs ;;
            5) set_channel ;;
            6) set_beacon ;;
#            5) set_frag ;;
            *) echo "Invalid option!";;
        esac
        sleep 2
    done
}

while [ -z "`$SSH echo ok`" ]; do
    echo "Please connect Omnia to control"
    sleep 1
done

$SSH wifi down
for i in 0 1; do
    $SSH iw phy$i interface add wlan$i type managed > /dev/null 2>&1
    $SSH iw phy$i power_safe off > /dev/null 2>&1
    $SSH kill \`cat /var/run/wifi-phy$i.pid\` > /dev/null 2>&1
    $SSH ip l s down dev wlan$i > /dev/null 2>&1
done

main_menu
