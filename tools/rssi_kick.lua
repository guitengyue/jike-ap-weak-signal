-- Local station control for Jike QSDK APs. Requires Lua 5.1/LuaJIT, UCI,
-- iwinfo.qcawifi, nixio, iw and cfg80211tool. No network credentials required.
local usage = [[
Usage: lua rssi_kick.lua --iface IFACE [--iface IFACE ...] [--threshold DBM]
                         [--protect MAC ...] [--once | --loop] [--apply]
Repeat --protect for each station to exclude. Default: observe three samples
five seconds apart. Default threshold: -82 dBm. --apply enables disconnection.
Only visible AP VAPs on the LAN bridge are eligible. Ctrl+C stops the loop.
]]
local selected, protected = {}, {}
local threshold, apply, loop = -82, false, false
local interval, required, max_gap, cooldown = 5, 3, 12, 180

local function station_mac(value)
    if type(value) ~= "string" then return nil end
    value = value:lower():gsub("-", ":")
    if not value:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then return nil end
    if not value:find("[1-9a-f]") or tonumber(value:sub(1, 2), 16) % 2 ~= 0 then return nil end
    return value
end

local i = 1
while i <= #arg do
    local flag = arg[i]
    if flag == "--help" or flag == "-h" then print(usage); return
    elseif flag == "--apply" then apply = true
    elseif flag == "--dry-run" then apply = false
    elseif flag == "--loop" then loop = true
    elseif flag == "--once" then loop = false
    elseif flag == "--iface" then
        i = i + 1
        local iface = arg[i]
        assert(iface and iface:match("^ath%d%d?%d?$"), "--iface requires a QSDK ath VAP")
        selected[iface] = true
    elseif flag == "--protect" then
        i = i + 1
        protected[assert(station_mac(arg[i]), "--protect requires a unicast MAC")] = true
    elseif flag == "--threshold" then
        i = i + 1
        local raw = arg[i] or ""
        threshold = raw:match("^%-%d+$") and tonumber(raw)
        assert(threshold and threshold >= -110 and threshold <= -40, "expected an integer threshold from -110 to -40 dBm")
    else error(usage)
    end
    i = i + 1
end
assert(next(selected), "provide at least one --iface")

local uci = require("uci")
local iwinfo = require("iwinfo")
local nixio = require("nixio")
assert(iwinfo.qcawifi and type(iwinfo.qcawifi.assoclist) == "function", "QSDK iwinfo association list unavailable")

local function first_line(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local line = f:read("*l")
    f:close()
    return line
end

local function uptime()
    return assert(tonumber((first_line("/proc/uptime") or ""):match("^(%d+%.?%d*)")), "system uptime unavailable")
end

local function set_flag(value)
    return value ~= nil and value ~= "0" and value ~= "no" and value ~= "off" and value ~= "false"
end

local function service_identity(cursor, s)
    local iface = s.ifname
    if s.athname ~= iface or s.mode ~= "ap" or s.network ~= "lan" or s.hidden ~= "0" then return nil end
    if set_flag(s.disabled) or set_flag(s.meshiface) or set_flag(s.backhaul) or set_flag(s.wds)
            or set_flag(s.sos) then return nil end
    if type(s.ssid) ~= "string" or s.ssid == "" or s.ssid:lower():match("^sos[_%-]") or s.ssid:lower() == "sos" then return nil end
    if not s.device or cursor:get("wireless", s.device) ~= "wifi-device"
            or set_flag(cursor:get("wireless", s.device, "disabled")) then return nil end
    local port = first_line("/sys/class/net/br-lan/brif/" .. iface .. "/port_no")
    local index = first_line("/sys/class/net/" .. iface .. "/ifindex")
    if not port or not index or not index:match("^%d+$") then return nil end
    -- iface came from the explicit numeric ath allowlist. Check the live BSS
    -- as a wireless reload can assign the same name to a different interface.
    local cmd = io.popen("/usr/sbin/iw dev " .. iface .. " info 2>/dev/null", "r")
    if not cmd then return nil end
    local mode, name
    for line in cmd:lines() do
        mode = line:match("^%s*type%s+(%S+)%s*$") or mode
        name = line:match("^%s*ssid (.*)$") or name
    end
    cmd:close()
    if mode == "AP" and name == s.ssid then return index .. "/" .. name end
end

local function services()
    local valid, seen = {}, {}
    local cursor = uci.cursor()
    cursor:foreach("wireless", "wifi-iface", function(s)
        local iface = s.ifname
        if not iface or not selected[iface] then return end
        if seen[iface] then valid[iface] = nil; return end
        seen[iface] = true
        valid[iface] = service_identity(cursor, s)
    end)
    cursor:close()
    return valid
end

local function associations(iface)
    local ok, list = pcall(iwinfo.qcawifi.assoclist, iface)
    if ok and type(list) == "table" then return list end
end

local function reading(row, identity, now)
    if type(row) ~= "table" then return nil end
    local signal, inactive, age = tonumber(row.signal), tonumber(row.inactive), tonumber(row.assoctime)
    if not (signal and signal >= -120 and signal < 0 and signal % 1 == 0) then return nil end
    if not (inactive and inactive >= 0 and inactive <= 30000 and age and age >= 0 and age < 2^32) then return nil end
    return {signal=signal, age=age, at=now, identity=identity, activity=now-inactive/1000, count=1}
end

local function same_association(old, current)
    local elapsed = current.at - old.at
    local age_delta = current.age - old.age
    return old.identity == current.identity and elapsed >= 0 and elapsed <= max_gap and age_delta >= 0
        and math.abs(age_delta - elapsed) <= 2 and current.age >= math.floor(elapsed)
        and current.activity >= old.credit - 1.25
end

local function lookup(list, mac)
    for address, row in pairs(list or {}) do
        if station_mac(address) == mac then return row end
    end
end

local history, recent = {}, {}
local function disconnect(candidate)
    local iface, mac, old = candidate.iface, candidate.mac, candidate.item
    if services()[iface] ~= old.identity then return end
    local current = reading(lookup(associations(iface), mac), old.identity, uptime())
    if not current or current.signal >= threshold or not same_association(old, current) then return end
    recent[mac] = uptime() + cooldown
    history[iface .. "/" .. mac] = nil
    local status = os.execute("/usr/sbin/cfg80211tool " .. iface .. " kickmac " .. mac .. " >/dev/null 2>&1")
    nixio.nanosleep(1)
    local after = associations(iface)
    local result = "unverified"
    if status == 0 and after and services()[iface] == old.identity then
        result = lookup(after, mac) and "still-associated" or "association-absent"
    end
    print(string.format("kick iface=%s mac_suffix=%s dbm=%d result=%s", iface, mac:sub(-8), current.signal, result))
end

local function poll()
    local next_history, weakest = {}, nil
    local active, weak, eligible, vaps = 0, 0, 0, 0
    local now = uptime()
    for mac, expires in pairs(recent) do if now >= expires then recent[mac] = nil end end
    for iface, identity in pairs(services()) do
        local stations = associations(iface)
        if stations then vaps = vaps + 1 end
        for address, row in pairs(stations or {}) do
            local mac = station_mac(address)
            local item = reading(row, identity, now)
            if item and mac and not protected[mac] then
                active = active + 1
                if item.signal < threshold then
                    weak = weak + 1
                    local key = iface .. "/" .. mac
                    local prev = history[key]
                    item.credit = item.activity
                    if prev and same_association(prev, item) then
                        if item.activity > prev.credit + 1.25 then item.count = prev.count + 1
                        else item.count, item.credit = prev.count, prev.credit end
                    end
                    next_history[key] = item
                    if item.count >= required and not recent[mac] then
                        eligible = eligible + 1
                        if not weakest or item.signal < weakest.item.signal then
                            weakest = {iface=iface, mac=mac, item=item}
                        end
                    end
                end
            end
        end
    end
    history = next_history
    print(string.format("mode=%s readable_vaps=%d fresh=%d weak=%d eligible=%d threshold=%d",
        apply and "apply" or "observe", vaps, active, weak, eligible, threshold))
    if apply and weakest then disconnect(weakest) end
    return vaps
end

io.stdout:setvbuf("line")
local lock
if apply then
    assert(nixio.getuid() == 0, "--apply requires root")
    -- The tested nixio build lacks file locking. A bound, non-listening
    -- loopback socket provides a process lock released by the kernel on exit.
    lock = assert(nixio.socket("inet", "stream"))
    assert(lock:bind("127.0.0.1", 37877), "another apply process holds the lock or the lock port is unavailable")
end
local rounds, readable = 0, 0
repeat
    local ok, result = pcall(poll)
    if ok then
        readable = readable + result
    else
        history = {}
        io.stderr:write("sample skipped: ", tostring(result), "\n")
    end
    rounds = rounds + 1
    if loop or rounds < required then nixio.nanosleep(interval) end
until not loop and rounds >= required
if readable == 0 then
    io.stderr:write("No requested interface passed the UCI, live BSS, bridge and association-list checks.\n")
    os.exit(1)
end
