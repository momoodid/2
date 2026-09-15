#!/usr/bin/env lua
--fusion mt7615 detect init script
--calculate wifi base mac
--init default ssid
--set vap bssid

local sksapwifi = {}

local function read_pipe(pipe)
	local fp = io.popen(pipe)
	local txt = fp:read()
	fp:close()
	return txt
end

local function file_exist(path)
	local file = io.open(path, "r")
	if file == nil then
		return false
	end
	file:close()
	return true
end

local function esc(x)
	return (x:gsub('%%', '%%%%')
		:gsub('^%^', '%%^')
		:gsub('%$$', '%%$')
		:gsub('%(', '%%(')
		:gsub('%)', '%%)')
		:gsub('%.', '%%.')
		:gsub('%[', '%%[')
		:gsub('%]', '%%]')
		:gsub('%*', '%%*')
		:gsub('%+', '%%+')
		:gsub('%-', '%%-')
		:gsub('%?', '%%?'))
end

function add_vif_into_bridge(vif, br_name)
	local mtkwifi = require("mtkwifi")
	local brvifs = mtkwifi.__trim( mtkwifi.read_pipe("uci get network."..br_name..".ifname"))
	if not string.match(brvifs, esc(vif)) then
		nixio.syslog("debug", "add "..vif.." into "..br_name)
		brvifs = brvifs.." "..vif
		os.execute("uci set network."..br_name..".ifname=\""..brvifs.."\"")
		os.execute("ubus call network.interface."..br_name.." add_device \"{\\\"name\\\":\\\""..vif.."\\\"}\"")
		os.execute("brctl addif br-"..br_name.." "..vif) -- double insurance for rare failure
	else
		os.execute("brctl addif br-"..br_name.." "..vif) -- ap save configuration function
	end
end

function del_vif_from_bridge(vif, br_name)
	local mtkwifi = require("mtkwifi")
	local brvifs = mtkwifi.__trim(mtkwifi.read_pipe("uci get network."..br_name..".ifname"))
	if string.match(brvifs, esc(vif)) then
		brvifs = mtkwifi.__trim(string.gsub(brvifs, esc(vif), ""))
		nixio.syslog("debug", "del "..vif.." from "..br_name)
		os.execute("uci set network."..br_name..".ifname=\""..brvifs.."\"")
		os.execute("ubus call network.interface."..br_name.." remove_device \"{\\\"name\\\":\\\""..vif.."\\\"}\"")
	end
end

function runtime_uci_config()
	os.execute("rm -rf /tmp/wireless")
	os.execute("uci export wireless > /tmp/wireless")
	os.execute("sed -i \"s/package wireless//g\" /tmp/wireless")
end

function add_mac_address(mac_addr, step)
	local mtkwifi = require("mtkwifi")

	if mac_addr == nil or string.find(mac_addr, ':') == nil or #string.split(mac_addr, ':') ~=6 or tonumber(step) == nil then
		return nil
	end

	local mac_addr_tb = string.split(mac_addr, ':')
	local mac_addr_new_tb = {}

	local rand = 0
	local dec_num = tonumber('0x'..mac_addr_tb[6]) + tonumber(step)
	mac_addr_new_tb[6] = string.format("%02x", tostring(dec_num % 256))

	if dec_num >= 256 then rand = 1 end
	dec_num = tonumber('0x'..mac_addr_tb[5]) + rand
	mac_addr_new_tb[5] = string.format("%02x", tostring(dec_num % 256))
	rand = 0

	if dec_num >= 256 then rand = 1 end
	dec_num = tonumber('0x'..mac_addr_tb[4]) + rand
	mac_addr_new_tb[4] = string.format("%02x", tostring(dec_num))

	mac_addr_new_tb[3] = mac_addr_tb[3]
	mac_addr_new_tb[2] = mac_addr_tb[2]
	mac_addr_new_tb[1] = mac_addr_tb[1]

	return table.concat(mac_addr_new_tb, ':')
end

function bssid_mac_address(mac_addr, step)
	local mtkwifi = require("mtkwifi")

	if mac_addr == nil or string.find(mac_addr, ':') == nil or #string.split(mac_addr, ':') ~= 6 or tonumber(step) == nil then
		return nil
	end

	local mac_addr_tb = string.split(mac_addr, ':')

	offset = (step - 1) * 16 + 2

	dec_num = tonumber('0x'..mac_addr_tb[1]) + offset
	mac_addr_tb[1] = string.format("%02x", tostring(dec_num))

	return table.concat(mac_addr_tb, ':')
end

function get_device_basemac()
	local fp = io.popen("boardinfo mac r")
	local txt = fp:read()
	local basemac = string.sub(txt, string.find(txt, "%w%w:%w%w:%w%w:%w%w:%w%w:%w%w"))
	fp:close()

	return basemac
end

function sksapwifi.config_wifi_basemac()
	local basemac = get_device_basemac()
	local wifibasemac = add_mac_address(basemac, 3)
	local wifi5gbasemac = add_mac_address(basemac, 4)

	os.execute("uci set wireless.MT761511.MacAddress="..wifibasemac)
	os.execute("uci set wireless.MT761512.MacAddress="..wifi5gbasemac)
	os.execute("uci commit2 wireless")
end

function sksapwifi.config_default_ssid()
	local basemac = get_device_basemac()
	local wifi24gbasemac = add_mac_address(basemac, 3)
	local wifi5gbasemac = add_mac_address(basemac, 4)
	local mac_tab = string.split(string.upper(basemac),":")
	local branch = read_pipe("uci -q get board.boardinfo.branch")
	local vendor = read_pipe("boardinfo vendor read | awk '{print $NF}'")
	local tr_prefix = "SKS-"
	local re_prefix = "skspruce-"
	local troubleshooting_ssid = ""
	local reserved_ssid = ""

	if tostring(vendor) == "41724" then
		if branch == "telecom" then
			tr_prefix = "ChinaNet-"
			re_prefix = "ChinaNet-"
		else
			tr_prefix = "SKS-"
			re_prefix = "skspruce-"
		end
	else
		local cmd = "uci get oem." .. tostring(vendor) .. ".ssid_prefix"
		re_prefix = tostring(read_pipe(cmd)) .. "-"
		tr_prefix = re_prefix
	end

	reserved_ssid = re_prefix..mac_tab[5]..mac_tab[6]
	troubleshooting_ssid = tr_prefix..mac_tab[4]..mac_tab[5]..mac_tab[6]

	-- 2.4G default sssid
	os.execute("uci set wireless.@wifi-iface[5].ssid="..troubleshooting_ssid)
	os.execute("uci set wireless.@wifi-iface[6].ssid="..reserved_ssid)

	-- set vap bssid
	for i = 1, 7, 1 do
		local bssid = bssid_mac_address(wifi24gbasemac, i)
		os.execute("uci set wireless.MT761511.MacAddress"..i.."="..bssid)
	end

	-- 5G default sssid
	os.execute("uci set wireless.@wifi-iface[13].ssid="..troubleshooting_ssid)
	os.execute("uci set wireless.@wifi-iface[14].ssid="..reserved_ssid)

	-- set vap bssid
	for i = 1, 7, 1 do
		bssid = bssid_mac_address(wifi5gbasemac, i)
		os.execute("uci set wireless.MT761512.MacAddress"..i.."="..bssid)
	end
end

function load_radio_config(devname, phy)
	local nixio = require("nixio")
	local uci = require("shuci")

	local ucicfg = uci.decode("/tmp/wireless")
	if not ucicfg then nixio.syslog("err", "uci decode /tmp/wireless fail") return end

	local vdev = ucicfg["wifi-device"][devname]
	if not vdev then nixio.syslog("err", "unknown device "..devname) return end

	if vdev.broadcast_probe_suppression then
		os.execute("iwpriv "..phy.." prb_suppression "..vdev.broadcast_probe_suppression)
	end
end

function sksapwifi.load_uci_config()
	runtime_uci_config()
	os.execute("uci2dat -d MT761511 -u /tmp/wireless -f /etc/wireless/mt7615/mt7615.1.2G.dat")
	os.execute("uci2dat -d MT761512 -u /tmp/wireless -f /etc/wireless/mt7615/mt7615.1.5G.dat")

	load_radio_config("MT761511", "wifi0")
	load_radio_config("MT761512", "wifi1")
end


function lighting_wireless_LED(is_2g, is_5g)
	if is_2g == '1' then
		os.execute(". /lib/functions/leds.sh; status_wlan2_on")
	end
	if is_5g == '1' then
		os.execute(". /lib/functions/leds.sh; status_wlan5_on")
	end
end


function shutdown_wireless_LED(is_2g, is_5g, ifname)
	local mtkwifi = require("mtkwifi")
	local prefix_name
	local vif
	local file
	local output_string
	local iter = string.gmatch(ifname, "%a+")
	if iter ~= nil then
		prefix_name = iter()
	end

	for _,vif in ipairs(string.split(mtkwifi.read_pipe("ls /sys/class/net"), "\n"))
	do
		if string.match(vif, prefix_name.."[0-9]+") then
			file = io.popen("ifconfig "..vif.." | grep UP")
			output_string = file:read("*a")
			if string.find(output_string, "[%a]+") ~= nil then
				-- still same type of dev is up, return
				return
			end
		end
	end

	if is_2g == '1' then
		os.execute(". /lib/functions/leds.sh; status_wlan2_off")
	end
	if is_5g == '1' then
		os.execute(". /lib/functions/leds.sh; status_wlan5_off")
	end
end


function trigger_wireless_LED(ifname, dev_status)
	local is_2g = '0'
	local is_5g = '0'

	local uci = require "luci.model.uci".cursor()
	uci.foreach("wireless", "wifi-iface",
	function(s)
		if s.ifname == ifname then
			if s.radio_id == '0' then
				is_2g = '1'
			end
			if s.radio_id == '1' then
				is_5g = '1'
			end
		end
	end)

	if file_exist("/lib/functions/leds.sh") == false then
		return
	end
	if dev_status == "up" then
		lighting_wireless_LED(is_2g, is_5g)
	end
	if dev_status == "down" then
		shutdown_wireless_LED(is_2g, is_5g, ifname)
	end
end

function config_vap_bandsteering_parameters(ifname, enable, mode, count)
	os.execute("iwpriv "..ifname.." bdst_enable "..enable)
	os.execute("iwpriv "..ifname.." bdst_mode "..mode)
	os.execute("iwpriv "..ifname.." bdst_count "..count)
end

function config_vap_mac_acl_parameters(ifname, filter, list)
	local policy = 0

	-- flush MAC list
	os.execute("iwpriv "..ifname.." acl_policy 3")

	-- convert filter string to index
	if filter == "allow" then
		policy = 1
	elseif filter == "deny" then
		policy = 2
	end

	os.execute("iwpriv "..ifname.." acl_policy "..policy)

	if not list then return end

	local fd = io.open(list, "r")
	if not fd then return end

	-- driver supports max 256 MAC lists
	local max_num = 18 * 256
	local mac_str = fd:read(max_num)

	if mac_str and string.len(mac_str) % 18 == 0 then
		mac_str = (string.gsub(mac_str, ";", " "))
		os.execute("iwpriv "..ifname.." acl_add "..mac_str)
	end

	fd:close()
end

function config_vap_rssi_optimization(ifname, ucicfg)
	if ucicfg.assoc_min_rssi_access_ctl then
		os.execute("iwpriv "..ifname.." ass_ctrl "..ucicfg.assoc_min_rssi_access_ctl)
	end

	if ucicfg.disassoc_min_rssi_access_ctl then
		os.execute("iwpriv "..ifname.." ass_kick "..ucicfg.disassoc_min_rssi_access_ctl)
	end

	if ucicfg.assoc_min_rssi then
		local ass_ctrl_rssi = 95 - ucicfg.assoc_min_rssi
		os.execute("iwpriv "..ifname.." ass_ctrl_rssi "..ass_ctrl_rssi)
	end

	if ucicfg.disassoc_min_rssi then
		local ass_kick_rssi = 95 - ucicfg.disassoc_min_rssi;
		os.execute("iwpriv "..ifname.." ass_kick_rssi "..ass_kick_rssi)
	end

	if ucicfg.min_rssi_freq then
		os.execute("iwpriv "..ifname.." rssi_check_p "..ucicfg.min_rssi_freq)
	end

	if ucicfg.min_rssi_times then
		os.execute("iwpriv "..ifname.." rssi_fail_cnt "..ucicfg.min_rssi_times)
	end

	if ucicfg.probe_rssi_rej then
		os.execute("iwpriv "..ifname.." probe_rssi_rej "..ucicfg.probe_rssi_rej)
	end
end

function sksapwifi.vap_up(ifname)
	runtime_uci_config()

	local nixio = require("nixio")
	local uci = require("shuci")

	local ucicfg = uci.decode("/tmp/wireless")
	if not ucicfg then error("unable to decode "..ucifile) return end

	local bdst_fail_lim = read_pipe("uci -q get system.redis.cantsteer_number")

	for vifname, vif in pairs(ucicfg["wifi-iface"]) do
		if vif.ifname == ifname then
		local vap_disabled = vif.disabled
		local device = vif.device
		local vde = ucicfg["wifi-device"][device]
		local radio_disabled = vde.disabled

		if (vap_disabled == '0' and radio_disabled == '0') then
			--add vap interface to hostapd
			os.execute("hostapd_loader.sh "..ifname.." "..device.." ADD")
			nixio.syslog("debug", "mt7615_up: ifconfig "..ifname.." up")
			os.execute("ifconfig "..ifname.." up")

			if vif.network then
				add_vif_into_bridge(ifname, vif.network)
			end

			if vif.band_steering and vif.band_steering_mode and vif.band_steering_count then
				config_vap_bandsteering_parameters(ifname, vif.band_steering, vif.band_steering_mode, vif.band_steering_count)
			end

			if bdst_fail_lim then
				os.execute("iwpriv "..ifname.." bdst_fail_lim "..bdst_fail_lim)
			end

			if vif.isolate then
				os.execute("iwpriv "..ifname.." set NoForwarding="..vif.isolate)
				os.execute("iwpriv "..ifname.." set NoForwardingMBCast="..vif.isolate)
			end

			if vif.mcastenhance then
				if (vif.mcastenhance == '2') then
					os.execute("iwpriv "..ifname.." set IgmpSnEnable=1")
				else
					os.execute("iwpriv "..ifname.." set IgmpSnEnable=0")
				end
			end

			if vif.mac_acl_filter then
				config_vap_mac_acl_parameters(ifname, vif.mac_acl_filter, vif.mac_acl_list)
			end

			if vde then
				config_vap_rssi_optimization(ifname, vde)
			end

			trigger_wireless_LED(ifname, "up")
		-- handle main interface, when call mt7615_up, main interface is auto up, so need to shutdown
		else
			os.execute("ifconfig "..ifname.." down")
		end
		break
		end
	end
end

function sksapwifi.vap_down(ifname)
	local nixio = require("nixio")
	local uci = require("shuci")

	local ucicfg = uci.decode("/tmp/wireless")
	if not ucicfg then error("unable to decode "..ucifile) return end

	for vifname, vif in pairs(ucicfg["wifi-iface"]) do
		if vif.ifname == ifname then
			-- remove vap interface from hostapd
			os.execute("hostapd_loader.sh "..ifname.." "..vif.device.." REMOVE")
			os.execute("ifconfig "..ifname.." down")

			if vif.network then
				del_vif_from_bridge(ifname, vif.network)
			end
			trigger_wireless_LED(ifname, "down")
			break
		end
	end
end

function get_maxtxpower(devname)
	local an_gain
	local maxpower
	local maxtxpower = 20 --default value
	local oem_file = io.open("/etc/oem_info.json", "r")

	if oem_file then
		local radio_num = read_pipe("jsonfilter -i /etc/oem_info.json -e \"@.ap_if_info.radio_count\"")

		for i = 1, radio_num, 1 do
			local j = i - 1
			dev = read_pipe("jsonfilter -i /etc/oem_info.json -e \"@.ap_if_info.radio_info["..j.."].device\"")

			if(dev == devname) then
				an_gain = read_pipe("jsonfilter -i /etc/oem_info.json -e \"@.ap_if_info.radio_info["..j.."].gain\"")

				maxpower = read_pipe("jsonfilter -i /etc/oem_info.json -e \"@.ap_if_info.radio_info["..j.."].max_txpower\"")

				maxtxpower = maxpower - an_gain
				break
			end
		end
		oem_file:close()
	end

	return maxtxpower
end

function sksapwifi.dbm_to_percentage(devname, txpower)
	local val
	local power
	local max_tx_power = get_maxtxpower(devname)

	if (tonumber(txpower) >= max_tx_power) then
		val = 100
	else
		local max_tx_power = math.ceil(10 ^ (max_tx_power / 10))
		local power = math.ceil(10 ^ (txpower / 10))
		val = math.ceil(power * 100 / max_tx_power)
	end

	return val
end

function sksapwifi.update_uci_config()
	runtime_uci_config()
end

return sksapwifi
