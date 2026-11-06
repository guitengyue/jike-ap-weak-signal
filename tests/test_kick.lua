-- From the repository root: lua tests/test_kick.lua  (or luajit tests/test_kick.lua).
-- Optional first argument: path to the tool under test. Requires only Lua 5.1 or LuaJIT.
-- All device data is synthetic. No actual processes, sockets, clocks or APs are used.
local source = arg[1] or "tools/rssi_kick.lua"
local station = "02:00:00:00:00:01" -- synthetic, locally administered unicast
local once = {"--iface", "ath0", "--once", "--apply"}
local continuous = {"--iface", "ath0", "--loop", "--apply"}

local function simulate(options, args)
    local clock, reads, kicks = 100, 0, 0
    local messages = {}
    local function file(value)
        return {read=function() return value end, close=function() end}
    end
    local fake_io = {
        stdout={setvbuf=function() end}, stderr={write=function() end},
        open=function(path)
            if path == "/proc/uptime" then return file(clock .. ".0 250") end
            if path == "/sys/class/net/br-lan/brif/ath0/port_no" then
                if not options.no_bridge then return file("0x7") end
                return nil
            end
            if path == "/sys/class/net/ath0/ifindex" then
                return file(options.replace_vap and clock >= 105 and "14" or "13")
            end
            error("unexpected file read: " .. path)
        end,
        popen=function(command)
            assert(command == "/usr/sbin/iw dev ath0 info 2>/dev/null", "unexpected live-interface command")
            local mode = options.bad_mode and "managed" or "AP"
            local name = options.runtime_ssid or options.configured_ssid or "test-service"
            local lines = {" type " .. mode, " ssid " .. name}
            return {
                lines=function()
                    local i = 0
                    return function() i = i + 1; return lines[i] end
                end,
                close=function() end
            }
        end
    }

    local cursor = {
        get=function(_, package, section, option)
            assert(package == "wireless" and section == "wifi0")
            if not option then return "wifi-device" end
            if option == "disabled" then return options.radio_off and "1" or "0" end
        end,
        foreach=function(_, package, kind, visit)
            assert(package == "wireless" and kind == "wifi-iface")
            local s = {
                ifname="ath0", athname="ath0", ssid=options.configured_ssid or "test-service",
                mode=options.uci_mode or "ap", network=options.network or "lan", hidden=options.hidden or "0",
                device="wifi0", meshiface=options.meshiface, backhaul=options.backhaul,
                wds=options.wds, sos=options.sos
            }
            visit(s)
            if options.duplicate then visit(s) end
        end,
        close=function() end
    }
    local function assoclist(iface)
        assert(iface == "ath0")
        reads = reads + 1
        if options.assoc_error or (options.fail_round and reads == 2) then error("simulated read failure") end
        if kicks > 0 and not options.still_present then return {} end
        local age = clock
        if options.reassoc and clock >= 105 then age = clock - 100 end
        if options.reconfirm_reset and reads == 4 then age = 0 end
        local signal = options.signal or -83
        if options.reconfirm_strong and reads == 4 then signal = -65 end
        if options.invalid_data then signal = "NaN" end
        local idle_ms = options.inactive or 0
        if options.idle then idle_ms = (clock - 100) * 1000 end
        return {[station]={signal=signal, inactive=idle_ms, assoctime=age}}
    end
    local modules = {
        uci={cursor=function() return cursor end}, iwinfo={qcawifi={assoclist=assoclist}},
        nixio={
            getuid=function() return options.not_root and 1000 or 0 end,
            socket=function() return {bind=function() return not options.lock_taken end} end,
            nanosleep=function(seconds)
                clock = clock + seconds
                if options.stop_at and clock >= options.stop_at then error("simulation-stop") end
            end
        }
    }
    local fake_os = {
        execute=function(command)
            assert(command == "/usr/sbin/cfg80211tool ath0 kickmac " .. station .. " >/dev/null 2>&1",
                   "unexpected device command")
            kicks = kicks + 1
            return 0
        end,
        exit=function(code) error("exit:" .. code) end
    }
    -- Grant the script its ordinary Lua primitives and only the mocked OS/AP interfaces.
    local env = {
        arg=args or once, io=fake_io, os=fake_os, math=math, string=string, table=table,
        assert=assert, error=error, next=next, pairs=pairs, ipairs=ipairs, pcall=pcall,
        tonumber=tonumber, tostring=tostring, type=type,
        print=function(message) messages[#messages + 1] = message end,
        require=function(key) return assert(modules[key], "unexpected module: " .. key) end
    }
    local program = assert(loadfile(source))
    setfenv(program, env)
    local ok, err = pcall(program)
    return {kicks=kicks, reads=reads, output=table.concat(messages, "\n"), error=not ok and tostring(err) or ""}
end

local passed = 0
local function test(label, options, expected, args)
    local actual = simulate(options, args)
    local function check(condition, why)
        assert(condition, string.format("%s: %s (kicks=%d reads=%d error=%s)",
            label, why, actual.kicks, actual.reads, actual.error))
    end
    check(actual.kicks == (expected.kicks or 0), "wrong number of kick calls")
    if expected.reads ~= nil then check(actual.reads == expected.reads, "wrong number of association reads") end
    if expected.error then check(actual.error:find(expected.error, 1, true), "unexpected error")
    else check(actual.error == "", "unexpected failure") end
    if expected.output then check(actual.output:find(expected.output, 1, true), "missing status output") end
    passed = passed + 1
end

test("three distinct weak samples", {}, {kicks=1, reads=5, output="association-absent"})
test("equal to threshold", {signal=-82}, {reads=3})
test("above threshold", {signal=-75}, {reads=3})
test("sleeping station, repeated reading", {idle=true}, {reads=3})
test("expired sample", {inactive=30001}, {reads=3})
test("malformed signal", {invalid_data=true}, {reads=3})
test("new association invalidates history", {reassoc=true}, {reads=3})
test("VAP recreated with same name", {replace_vap=true}, {reads=3})
test("missing middle sample breaks run", {fail_round=true}, {reads=3})
test("strong signal at final check", {reconfirm_strong=true}, {reads=4})
test("new association at final check", {reconfirm_reset=true}, {reads=4})
test("protected station", {}, {reads=3},
    {"--iface", "ath0", "--apply", "--protect", "02-00-00-00-00-01"})
test("default observe mode", {}, {reads=3, output="mode=observe readable_vaps=1 fresh=1 weak=1 eligible=1"},
    {"--iface", "ath0"})
test("device reports success but station remains", {still_present=true}, {kicks=1, reads=5, output="still-associated"})

local skip = {error="exit:1", reads=0}
test("disabled radio", {radio_off=true}, skip)
test("duplicate UCI assignment", {duplicate=true}, skip)
test("hidden BSS", {hidden="1"}, skip)
test("WDS link", {wds="1"}, skip)
test("backhaul", {backhaul="1"}, skip)
test("mesh AP", {meshiface="ap"}, skip)
test("reserved SOS name", {configured_ssid="SOS_SYNTHETIC"}, skip)
test("explicit SOS flag", {sos="1"}, skip)
test("not on LAN bridge", {no_bridge=true}, skip)
test("live SSID differs", {runtime_ssid="replacement-test-service"}, skip)
test("live interface is not in AP mode", {bad_mode=true}, skip)
test("UCI network is not LAN", {network="wan"}, skip)
test("no readable association table", {assoc_error=true}, {error="exit:1", reads=3})
test("apply needs root", {not_root=true}, {error="root", reads=0})
test("another apply worker", {lock_taken=true}, {error="lock", reads=0})
test("missing interface", {}, {error="at least one", reads=0}, {})
test("invalid interface", {}, {error="QSDK", reads=0}, {"--iface", "ath0;true", "--apply"})
test("invalid threshold", {}, {error="threshold", reads=0}, {"--iface", "ath0", "--threshold", "-1", "--apply"})
test("reject multicast protection address", {}, {error="unicast", reads=0},
    {"--iface", "ath0", "--protect", "01:00:00:00:00:01"})
test("help exits without AP reads", {}, {reads=0, output="Usage:"}, {"--help"})
test("cooldown suppresses repeated commands", {still_present=true, stop_at=150},
    {kicks=1, error="simulation-stop"}, continuous)
test("eligible again after cooldown", {still_present=true, stop_at=294},
    {kicks=2, error="simulation-stop"}, continuous)
print(string.format("%d simulated weak-signal cases passed.", passed))
