# sks write for config vap infomation

export LOG_INFO="logger -p local5.info -t unknown "
export LOG_ERR="logger -p local5.error -t unknown "

# bit0~7 is ltf, bit8 is 400ns, bit9 is 800ns, bit10 is 1600ns, bit11 is 3200ns,
# override he auto shortgi function, first override shortgi config
override_he_auto_giltf() {
	local ifname=$1
	local heshortgi=$2
	local radiomode=$3

	if [ "$3" == "11axa" -o "$3" == "11axg" ]; then

		ori_giltf=$(cfg80211tool $ifname get_he_ar_gi_ltf | awk -F ':' '{print $2}')
		[ -z "$ori_giltf" ] && ori_giltf=255
		ltf=`expr $ori_giltf % 256`

		case $heshortgi in
		800)
			argi=2
			;;
		400)
			argi=1
			;;
		1600)
			argi=4
			;;
		3200)
			argi=8
			;;
		*)
			argi=2
			;;
		esac

		giltf=`expr $argi \* 256 + $ltf`
		cfg80211tool "$ifname" he_ar_gi_ltf "$giltf"
	fi
}

calculate_hemcsmapmask() {
	local mask=$1
	local val=$1
	local h_mask=$1

	nss=$(iwpriv $2 get_nss | awk -F ':' '{print $2}')

	nss=`expr $nss - 1`

	for i in `seq $nss`
	do
		mask=`expr $mask \* 4 + $val`
	done

	# Handle 160Mhz, for QCA solution, when operating at 160Mhz,
	# nss will be nss/2
	if [ "$3" = "HT160" ]; then
		nss=`expr $nss / 2`

		for i in `seq $nss`
		do
			h_mask=`expr $h_mask \* 4 + $val`
		done

		mask=`expr $mask + $h_mask \* 65536`
	fi

	echo $mask
}

ifconfig() {
	CMD="ifconfig $@"
	$LOG_INFO "$CMD"
	/sbin/ifconfig "$@"
	#result=$?
	#[ $result -ne 0 ] && $LOG_ERR " $CMD fail: $result"
}

iwconfig() {
	CMD="iwconfig $@"
	$LOG_INFO "$CMD"
	/usr/sbin/iwconfig "$@"
	#result=$?
	#[ $result -ne 0 ] && $LOG_ERR " $CMD fail: $result"
}

iwpriv() {
	CMD="iwpriv $@"
	$LOG_INFO "$CMD"
	/usr/sbin/iwpriv "$@"
	#result=$?
	#[ $result -ne 0 ] && $LOG_ERR " $CMD fail: $result"
}

wpa_cli() {
	CMD="wpa_cli $@"
	$LOG_INFO "$CMD"
	/usr/sbin/wpa_cli "$@"
	#result=$?
	#[ $result -ne 0 ] && $LOG_ERR " $CMD fail: $result"
}

. /lib/wifi/hostapd.sh

scan_wifi() {
	local cfgfile="$1"
	DEVICES=
	config_cb() {
		local type="$1"
		local section="$2"

		# section start
		case "$type" in
			wifi-device)
				append DEVICES "$section"
				config_set "$section" vifs ""
				config_set "$section" ht_capab ""
			;;
		esac

		# section end
		config_get TYPE "$CONFIG_SECTION" TYPE
		case "$TYPE" in
			wifi-iface)
				config_get device "$CONFIG_SECTION" device
				config_get vifs "$device" vifs
				append vifs "$CONFIG_SECTION"
				config_set "$device" vifs "$vifs"
			;;
		esac
	}
	config_load "${cfgfile:-wireless}"
}

set_wifi_up() {
	local cfg="$1"
	local ifname="$2"
	uci_set_state wireless "$cfg" up 1
	uci_set_state wireless "$cfg" ifname "$ifname"
}

set_wifi_down() {
	local cfg="$1"
	uci_revert_state wireless "$cfg"
}

config_vap_down(){
	local phy=$1
	local ifname=$2
	local vif=$3
	local start_hostapd= 
    local brnetwork=`brctl show | grep "${ifname}\$" -B 32 | cut -f 1 | grep -v '^\$' | tail -n 1`
	config_set "$phy" phy "$phy"
	config_set "$vif" ifname "$ifname"
	
	config_get network "$vif" network


	iwconfig "$ifname" essid off

#	[ -n $network ] && brctl delif "$brnetwork" "$ifname"
	[ -n $network ] && ubus call network.interface.$network remove_device {\"name\":\"$ifname\"}

	ifconfig "$ifname" down
	set_wifi_down "$vif"

	lockname=/var/run/hostapd-$ifname.lock
	confname=/var/run/hostapd-$ifname.conf

	if [ -f "$lockname" ];then
		wpa_cli -g /var/run/hostapd/global raw REMOVE "$ifname"
		rm -f "$lockname"
		rm -f "$confname"
	fi
}

config_vap_up(){
	local phy=$1
	local ifname=$2
	local vif=$3
	local start_hostapd= 
	config_set "$phy" phy "$phy"
	config_set "$vif" ifname "$ifname"

	config_get disabled "$vif" disabled

	if [ $disabled == 1 ];then
		return 0
	else
		config_get_bool disabled "$phy" disabled 0
		[ $disabled == 1 ] && return 0
	fi
    			
	config_get network "$vif" network
#	[ -n $network ] && brctl addif "br-$network" "$ifname"
	[ -n $network ] && ubus call network.interface.$network add_device {\"name\":\"$ifname\"}
	config_get frag "$vif" frag
	[ -n "$frag" ] && iwconfig "$ifname" frag "${frag%%.*}"

	config_get rts "$vif" rts
	if [ -n "$rts" ];then
		if [ $rts -eq 0 ];then
			iwconfig "$ifname" rts off
		else
			iwconfig "$ifname" rts "${rts%%.*}"
		fi
	else
		iwconfig "$ifname" rts off
	fi

	config_get pureg "$vif" pureg 1
	[ -n "$pureg" ] && iwpriv "$ifname" pureg "$pureg"

	config_get puren "$vif" puren
	[ -n "$puren" ] && iwpriv "$ifname" puren "$puren"

	config_get channel "$phy" channel
	[ auto = "$channel" ] && channel=0
	iwconfig "$ifname" channel "$channel" >/dev/null 2>/dev/null

	config_get dtim_period "$vif" dtim_period
	[ -n "$dtim_period" ] && iwpriv "$ifname" dtim_period "$dtim_period"

	config_get mcast_rate "$vif" mcast_rate
	[ -n "$mcast_rate" ] && iwpriv "$ifname" mcast_rate "$mcast_rate"

	config_get hwmode "$phy" hwmode
	[ -n "$hwmode" ] && [ -n "$mcast_rate" ] && {
		dis_legacy=0
		case "$hwmode" in
		*b)
		#mode is 11b
			dis_legacy="0xff0"
			;;
		*g|*n|*ng|*bg|*axg)
		#mode is 11g,11ng,11axg
			dis_legacy="0x4"
			;;
		*)
		#mode is 11a,11na,11ac,11axa,auto
			dis_legacy="0xf"
			;;
		esac
		echo "dis_legacy: $dis_legacy" > /dev/console
		iwpriv "$ifname" dis_legacy "$dis_legacy"
	}

	config_get inact "$vif" inact
	[ -n "$inact" ] && iwpriv "$ifname" inact "$inact"

	config_get maxsta "$vif" maxsta
	[ -n "$maxsta" ] && iwpriv "$ifname" maxsta "$maxsta"


	config_get enc "$vif" encryption "none"
	config_get eap_type "$vif" eap_type
	
	case "$enc" in
		wep*|mixed*|psk*|wpa*|8021x)
		config_get key "$vif" key
		;;
	esac
	start_hostapd=1

	config_get maclist "$vif" maclist
	[ -n "$maclist" ] && {
		# flush MAC list
		iwpriv "$ifname" maccmd 3
		maclist=$(echo ${maclist// /})
		echo "$maclist" > /sys/devices/virtual/net/"$ifname"/macacl
	}

	config_get macfilter "$vif" macfilter
	case "$macfilter" in
		allow)
			iwpriv "$ifname" maccmd 1
		;;
		deny)
			iwpriv "$ifname" maccmd 2
		;;
		disable)
			iwpriv "$ifname" maccmd 0
		;;
		*)
			# default disable policy if mac list exists
			[ -n "$maclist" ] && iwpriv "$ifname" maccmd 0
		;;
	esac

	# flush MAC list
	iwpriv "$ifname" acl_policy 3

	config_get acl_list "$vif" mac_acl_list
	[ -n "$acl_list" ] && {
		acllist=$(cat "$acl_list")
		acllist=$(echo $acllist | sed 's/;/ /g')
		for mac in $acllist; do
			iwpriv "$ifname" acl_add "$mac"
		done
	}

	config_get acl_policy "$vif" mac_acl_filter
	case "$acl_policy" in
		allow)
			iwpriv "$ifname" acl_policy 1
		;;
		deny)
			iwpriv "$ifname" acl_policy 2
		;;
		*)
			iwpriv "$ifname" acl_policy 0
		;;
	esac

	config_get ssid "$vif" ssid
	[ -n "$ssid" ] && {
		iwconfig "$ifname" essid on
		iwconfig "$ifname" essid ${ssid:+-- }"$ssid"
	}

	config_get_bool hidden "$vif" hidden 0
	iwpriv "$ifname" hide_ssid "$hidden"

	config_get_bool fullhidden "$vif" fullhidden 0
	iwpriv "$ifname" full_hide_ssid "$fullhidden"

	#skip this first #llai: no need reload
	config_load wireless
	handle_add_ch_a_list() {
		local value="$1"
		[ -n "$value" ] && iwpriv "$ifname" chan_a_add $value
	}
	iwpriv "$ifname" chan_a_flush
	config_list_foreach "$vif" dot11k_ch_a_list handle_add_ch_a_list

	handle_add_ch_g_list() {
		local value="$1"
		[ -n "$value" ] && iwpriv "$ifname" chan_bg_add $value
	}
	iwpriv "$ifname" chan_bg_flush
	config_list_foreach "$vif" dot11k_ch_g_list handle_add_ch_g_list

	if [ -n "$start_hostapd" ] && eval "type hostapd_setup_vif" 2>/dev/null >/dev/null; then
		hostapd_setup_vif "$vif" nl80211 no_nconfig || {
			echo "enable_qcawifi($device): Failed to set up hostapd for interface $ifname" >&2
			# make sure this wifi interface won't accidentally stay open without encryption
			ifconfig "$ifname" down
			return 1
		}
	fi

	config_get_bool bdst_en "$vif" band_steering 0
	iwpriv "$ifname" bdst_enable "$bdst_en"

	config_get bdst_mode "$vif" band_steering_mode
	[ -n "$bdst_mode" ] && iwpriv "$ifname" bdst_mode "$bdst_mode"

	config_get bdst_count "$vif" band_steering_count
	[ -n "$bdst_count" ] && iwpriv "$ifname" bdst_count "$bdst_count"

	bdst_fail_lim=$(uci_get system redis cantsteer_number 10)
	iwpriv "$ifname" bdst_fail_lim "$bdst_fail_lim"

	config_get_bool specialssid "$vif" specialssid 1
	if [ "$specialssid" = "0" ]; then
		iwpriv "$ifname" dis_spec_ssid 1
	else
		iwpriv "$ifname" dis_spec_ssid 0
	fi

	config_get tunnelmode "$vif" tunnelmode
	if [ -n "$tunnelmode" ]; then
		iwpriv "$ifname" tunnel "$tunnelmode"
	else
		iwpriv "$ifname" tunnel 0
	fi

	config_get_bool webauth "$vif" webauth 0
	iwpriv "$ifname" web_auth "$webauth"

	config_get_bool localdhcp "$vif" localdhcp 0
	iwpriv "$ifname" local_dhcp "$localdhcp"

	config_get_bool localassoc "$vif" localassoc 0
	iwpriv "$ifname" local_assoc "$localassoc"

	config_get_bool isolate "$vif" isolate 0
	if [ -n "$isolate" ]; then
		if [ "$isolate" == "0" ]; then
			ebtables -D FORWARD -i $ifname -o ath+ -j DROP 2>/dev/null
			ebtables -D FORWARD -i ath+ -o $ifname -j DROP 2>/dev/null
			iwpriv "$ifname" l2tif "$isolate"
		else
			ebtables -D FORWARD -i $ifname -o ath+ -j DROP 2>/dev/null
			ebtables -D FORWARD -i ath+ -o $ifname -j DROP 2>/dev/null

			ebtables -I FORWARD -i $ifname -o ath+ -j DROP 2>/dev/null
			ebtables -I FORWARD -i ath+ -o $ifname -j DROP 2>/dev/null
			iwpriv "$ifname" l2tif "$isolate"
		fi
	fi

	config_get beacon_rate "$vif" beacon_rate
	if [ -n "$beacon_rate" ]; then
		iwpriv "$ifname" set_bcn_rate "$beacon_rate"
	fi

	config_get_bool vhtintop "$vif" vhtintop 1
	iwpriv "$ifname" 11ngvhtintop $vhtintop

	config_get shortgi  "$phy" shortgi 1
	iwpriv "$ifname" shortgi "$shortgi"

	#override he auto shortgi config
	config_get heshortgi "$phy" heshortgi
	[ -n "$heshortgi" ] && override_he_auto_giltf "$ifname" "$heshortgi" "$hwmode"

	config_get tx_rate "$vif" tx_rate
	if [ -n "$tx_rate" ]; then
		echo $tx_rate   > /proc/"$ifname"/tx_rate
	fi

	config_get vapvlan "$vif" vapvlan
        if [ -n "$vapvlan" ]; then
		iwpriv "$ifname" vlan "$vapvlan"
	else
		iwpriv "$ifname" vlan 1
        fi

	config_get bintval "$phy" bintval
	[ -n "$bintval" ] && iwpriv "$ifname" bintval "$bintval"

	config_get ampdu "$phy" ampdu
	[ -n "$ampdu" ] && iwpriv "$ifname" ampdu "$ampdu"

	config_get amsdu "$phy" amsdu
	[ -n "$amsdu" ] && iwpriv "$ifname" amsdu "$amsdu"

	config_get maxampdu "$phy" maxampdu
	[ -n "$maxampdu" ] && iwpriv "$ifname" maxampdu "$maxampdu"

	config_get vhtmaxampdu "$phy" vhtmaxampdu
	[ -n "$vhtmaxampdu" ] && iwpriv "$ifname" vhtmaxampdu "$vhtmaxampdu"

	config_get_bool qbssload "$vif" qbssload
	[ -n "$qbssload" ] && iwpriv "$ifname" qbssload "$qbssload"

	config_get_bool proxyarp "$vif" proxyarp
	[ -n "$proxyarp" ] && iwpriv "$ifname" proxyarp "$proxyarp"

	config_get dot11k_base_snr "$vif" dot11k_base_snr
	if [ -n "$dot11k_base_snr" ]; then
		iwpriv "$ifname" base_snr "$dot11k_base_snr"
	fi

	config_get_bool dot11v_trans_enable "$vif" dot11v_trans_enable 0
	iwpriv "$ifname" trans_en "$dot11v_trans_enable"

	config_get_bool dot11r_roam_assist "$vif" dot11r_roam_assist 0
	iwpriv "$ifname" roam_assist "$dot11r_roam_assist"

	config_get dot11k_rpt_interval "$vif" dot11k_rpt_interval 0
	iwpriv "$ifname" rpt_intval "$dot11k_rpt_interval"

	config_get_bool dot11k_enable "$vif" dot11k_enable 0
	iwpriv "$ifname" dot11k_en "$dot11k_enable"

	config_get_bool rrmenable "$vif" rrmenable 0
	iwpriv "$ifname" rrm "$rrmenable"
	# iwpriv "$ifname" quiet "$dot11k_enable"

	config_get mcastenhance "$vif" mcastenhance
	[ -n "$mcastenhance" ] && iwpriv "$ifname" mcastenhance "$mcastenhance"

	config_get metimer "$vif" metimer
	[ -n "$metimer" ] && iwpriv "$ifname" metimer "$metimer"

	config_get me_length "$vif" me_length
	[ -n "$me_length" ] && iwpriv "$ifname" me_length "$me_length"

	config_get htmode "$phy" htmode

	#config_get he_txmcsmap "$phy" he_txmcsmap
	#[ -n "$he_txmcsmap" ] && {
	#	txmcsmap=$(calculate_hemcsmapmask "$he_txmcsmap" "$ifname" "$htmode")
	#	iwpriv "$ifname" he_txmcsmap "${txmcsmap}"
	#}

	#config_get he_rxmcsmap "$phy" he_rxmcsmap
	#[ -n "$he_rxmcsmap" ] && {
	#	rxmcsmap=$(calculate_hemcsmapmask "$he_rxmcsmap" "$ifname" "$htmode")
	#	iwpriv "$ifname" he_rxmcsmap "${rxmcsmap}"
	#}

	config_get he_dlofdma "$phy" he_dlofdma
	[ -n "$he_dlofdma" ] && iwpriv "$ifname" he_dlofdma "${he_dlofdma}"

	config_get he_ulofdma "$phy" he_ulofdma
	[ -n "$he_ulofdma" ] && iwpriv "$ifname" he_ulofdma "${he_ulofdma}"

	config_get he_ulmumimo "$phy" he_ulmumimo
	[ -n "$he_ulmumimo" ] && iwpriv "$ifname" he_ulmumimo "${he_ulmumimo}"

	config_get twt_responder "$phy" twt_responder 0
	[ -n "$twt_responder" ] && cfg80211tool "$ifname" twt_responder "${twt_responder}"

	ifconfig "$ifname" up
	set_wifi_up "$vif" "$ifname"

	# associate rssi control and low rssi kick sta function config
	config_get_bool handoff_assist "$phy" assoc_min_rssi_access_ctl 0
	[ -n "$handoff_assist" ] && iwpriv "$ifname" ass_ctrl "${handoff_assist}"

	config_get assoc_min_rssi "$phy" assoc_min_rssi
	[ -n "$assoc_min_rssi" ] && {
		assoc_min_rssi=`expr 95 - $assoc_min_rssi`
		iwpriv "$ifname" ass_ctrl_rssi "${assoc_min_rssi}"
	}

	config_get disassoc_min_rssi "$phy" disassoc_min_rssi
	[ -n "$assoc_min_rssi" ] && {
		disassoc_min_rssi=`expr 95 - $disassoc_min_rssi`
		iwpriv "$ifname" ass_kick_rssi "${disassoc_min_rssi}"
	}

	config_get min_rssi_freq "$phy" min_rssi_freq
	[ -n "$min_rssi_freq" ] && iwpriv "$ifname" rssi_check_p "${min_rssi_freq}"

	config_get min_rssi_times "$phy" min_rssi_times
	[ -n "$min_rssi_times" ] && iwpriv "$ifname" rssi_fail_cnt "${min_rssi_times}"

	config_get_bool rssi_check "$phy" disassoc_min_rssi_access_ctl 0
	[ -n "$rssi_check" ] && iwpriv "$ifname" ass_kick "${rssi_check}"

	config_get probe_rssi_rej "$phy" probe_rssi_rej
	[ -n "$probe_rssi_rej" ] && iwpriv "$ifname" probe_rssi_rej "${probe_rssi_rej}"

	# netifd -> system_if_apply_rps_xps() will set 0
	echo 5 > /sys/class/net/"$ifname"/queues/rx-0/rps_cpus

	iwpriv "$ifname" update_vap
}
