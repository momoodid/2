. /lib/wifi/hostapd.sh
. /lib/functions.sh
. /usr/share/libubox/jshn.sh

LOG_ERR="logger -p local5.err -t unknown "
enable_fu_mt7615() {
  local device="$1"
  local vapname="$2"
  local start_hostapd=
  config_get vifs "$device" vifs
  config_get type "$device" type
  config_get hwmode "$device" hwmode

  #ref to WirelessMode in mtk guide
  case "$hwmode" in
    0|1|4|6|7|9) hwmode=g;;
    2|8|11|14) hwmode=a;;
  esac
  config_set "$device" hwmode "$hwmode"

  for vif in $vifs; do
    config_get ifname "$vif" ifname
    config_get ssid "$vif" ssid
    config_get mode "$vif" mode
    config_get enc "$vif" encryption
    config_get disabled "$vif" disabled 0
    if [ $disabled -eq 0 -a "$ifname" == "$vapname" ]; then

      case "$enc" in
        WEP*|wep*)
          start_hostapd=1
        ;;
        mixed*|psk*|wpa*|8021x)
          start_hostapd=1
          config_get key "$vif" key
        ;;
        none)
        #add non encryption vap to hostapd
          start_hostapd=1
        ;;
        *)
          $LOG_ERR "encryption config error!"
          exit 1
        ;;
      esac
      # local net_cfg bridge
      # net_cfg="$(find_net_config "$vif")"
      # [ -z "$net_cfg" ] || {
      #   bridge="$(bridge_interface "$net_cfg")"
      #   config_set "$vif" bridge "$bridge"
      #   start_net "$ifname" "$net_cfg"
      # }
      # set_wifi_up "$vif" "$ifname"

      case "$mode" in
        ap)
          if [ -n "$start_hostapd" ] &&\
             eval "type hostapd_setup_vif" 2>/dev/null >/dev/null; then
            hostapd_setup_vif "$vif" nl80211 || {
              echo "Failed to set up hostapd for interface $ifname" >&2
              ifconfig "$ifname" down
              continue
            }
          fi
        ;;
        wds|sta)
        ;;
      esac
    fi
  done

}

scan_fu_mt7615() {
  local cfgfile="$1"
  DEVICES=
  config_load "${cfgfile:-wireless}"

  create_vifs_list() {
    local section="$1"
    append DEVICES "$section"
    config_set "$section" vifs ""
  }
  config_foreach create_vifs_list wifi-device

  append_vif() {
    local section="$1"
    config_get device "$section" device
    config_get vifs "$device" vifs
    append vifs "$section"
    config_set "$device" vifs "$vifs"
  }
  config_foreach append_vif wifi-iface
}

#test & verify only
# scan_fu_mt7615
# enable_fu_mt7615 MT761511
# enable_fu_mt7615 MT761512

usage(){
  cat <<EOF
Usage: $0 [ifname] [device] [ADD/REMOVE]
add vap interface to hostapd or remove vap interface from hostapd
EOF
  exit 1
}

remove_vap_from_hostapd(){
  local ifname=$1
  local lockname=/var/run/hostapd-$ifname.lock
  local confname=/var/run/hostapd-$ifname.conf
  local maclistname=/var/run/hostapd-$ifname.maclist

  if [ -f "$lockname" ]; then
    hostapd_cli -p /var/run/hostapd raw REMOVE "$ifname"
    rm -f "$lockname"
    rm -f "$confname"
    rm -f "$maclistname"
  fi
}

vap_ifname=$1
vap_device=$2
action=$3

if [ $# -lt 3 ]; then
  usage
fi

if [ "$action" == "ADD" ]; then
  scan_fu_mt7615
  enable_fu_mt7615 $vap_device $vap_ifname
else
  if [ "$action" == "REMOVE" ]; then
    remove_vap_from_hostapd $vap_ifname
  fi
fi
