-- GTL2750 4x4 Matrix Amplifier — Control4 Driver
-- Protocol: GTL2750 Central Control RS232/TCP
-- Frame: A5 C3 3C 5A [ID] [RW] [Func] [Len] [Data...] EE

------------------------------------------------------------
-- Constants
------------------------------------------------------------
FRAME_HEAD   = string.char(0xA5, 0xC3, 0x3C, 0x5A)
FRAME_TAIL   = string.char(0xEE)
RW_WRITE     = 0x36
RW_READ      = 0x63
DEFAULT_ID   = 0xFF

FUNC = {
    SCENE        = 0x02,
    MUTE         = 0x03,
    VOLUME       = 0x04,
    VOLUME_STEP  = 0x05,
    LINE_MIC     = 0x06,
    MATRIX       = 0x09,
    WORK_MODE    = 0x16,
    STANDBY      = 0x17,
    DEVICE_IP    = 0x18,
    PAGE         = 0x1A,
}

BINDING_NET    = 1000
BINDING_SERIAL = 2000
PROXY_BINDING  = 5001

CMD_GAP_MS     = 220   -- minimum gap between normal commands (>200ms per spec)
SCENE_GAP_MS   = 3100  -- minimum gap after scene call (>=3s per spec)

------------------------------------------------------------
-- State
------------------------------------------------------------
EC  = {}        -- ExecuteCommand handlers
PRP = {}        -- Property handlers
RFP = {}        -- ReceivedFromProxy handlers
LUA_ACTION = {} -- Programming action handlers

g_DeviceID     = DEFAULT_ID
g_Connection   = "Network"
g_IP           = "192.168.1.100"
g_Port         = 8234
g_Baud         = 115200
g_Debug        = 0           -- 0=Off 1=Print 2=Log 3=Both
g_RxBuffer     = ""
g_CmdQueue     = {}          -- list of { data=str, scene=bool, expectRead=bool, func=int }
g_Pending      = nil         -- currently sent (awaiting response)
g_LastSendMs   = 0
g_LastSceneMs  = 0
g_DrainTimer   = nil
g_RetryTimer   = nil
g_Connected    = false
g_TickTimer    = nil

------------------------------------------------------------
-- Logging
------------------------------------------------------------
function dbg(msg)
    if g_Debug == 0 then return end
    if g_Debug == 1 or g_Debug == 3 then print(msg) end
    if g_Debug == 2 or g_Debug == 3 then C4:ErrorLog(msg) end
end

function hex(s)
    local r = {}
    for i = 1, #s do r[#r+1] = string.format("%02X", string.byte(s, i)) end
    return table.concat(r, " ")
end

------------------------------------------------------------
-- Time helper (milliseconds)
------------------------------------------------------------
function nowMs()
    return math.floor((os.time() * 1000) + ((os.clock() * 1000) % 1000))
end

------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------
function ON_DRIVER_LATE_INIT()
    dbg("GTL2750 driver: late init")
    LoadAllProperties()
    OpenConnection()
    StartTickTimer()
end

function ON_DRIVER_DESTROYED()
    CloseConnection()
    StopTickTimer()
end

function LoadAllProperties()
    for _, k in ipairs({
        "Debug Mode", "Connection Type", "IP Address", "TCP Port",
        "Baud Rate", "Device ID"
    }) do
        local v = Properties[k]
        if v then OnPropertyChanged(k) end
    end
end

function OnPropertyChanged(strProperty)
    local val = Properties[strProperty]
    dbg(string.format("PropChanged: %s = %s", strProperty, tostring(val)))
    local handler = PRP[strProperty]
    if handler then handler(val) end
end

PRP["Debug Mode"] = function(v)
    local map = { ["Off"]=0, ["Print"]=1, ["Log"]=2, ["Print and Log"]=3 }
    g_Debug = map[v] or 0
end

PRP["Connection Type"] = function(v)
    if v ~= g_Connection then
        g_Connection = v or "Network"
        CloseConnection()
        OpenConnection()
    end
end

PRP["IP Address"] = function(v)
    g_IP = v or g_IP
    if g_Connection == "Network" then
        CloseConnection(); OpenConnection()
    end
end

PRP["TCP Port"] = function(v)
    local p = tonumber(v)
    if p then
        g_Port = p
        if g_Connection == "Network" then
            CloseConnection(); OpenConnection()
        end
    end
end

PRP["Baud Rate"] = function(v)
    g_Baud = tonumber(v) or 115200
    if g_Connection == "Serial" then ApplySerialParams() end
end

PRP["Device ID"] = function(v)
    local n = tonumber(v, 16)
    if n and n >= 0 and n <= 0xFF then g_DeviceID = n end
end

------------------------------------------------------------
-- Connection management
------------------------------------------------------------
function OpenConnection()
    if g_Connection == "Network" then
        if g_IP == nil or g_IP == "" then
            SetStatus("No IP configured"); return
        end
        dbg(string.format("Connecting TCP %s:%d", g_IP, g_Port))
        SetStatus("Connecting...")
        C4:CreateNetworkConnection(BINDING_NET, g_IP, "GTL2750")
        C4:NetConnect(BINDING_NET, g_Port, "TCP")
    else
        ApplySerialParams()
        SetStatus("Serial Ready")
        g_Connected = true
        C4:FireEvent("Connected")
    end
end

function CloseConnection()
    if g_Connection == "Network" then
        pcall(function() C4:NetDisconnect(BINDING_NET, g_Port) end)
    end
    g_Connected = false
end

function ApplySerialParams()
    pcall(function()
        C4:SetSerialPortParams(BINDING_SERIAL, g_Baud, "NONE", 8, 1)
    end)
end

function SetStatus(s)
    C4:UpdateProperty("Status", s)
    dbg("Status: " .. s)
end

------------------------------------------------------------
-- Inbound network/serial data
------------------------------------------------------------
function OnConnectionStatusChanged(idBinding, nPort, strStatus)
    dbg(string.format("Conn status: bind=%d port=%d status=%s",
        idBinding, nPort, tostring(strStatus)))
    if idBinding == BINDING_NET then
        if strStatus == "ONLINE" then
            g_Connected = true
            SetStatus("Connected")
            C4:FireEvent("Connected")
        elseif strStatus == "OFFLINE" then
            g_Connected = false
            SetStatus("Disconnected")
            C4:FireEvent("Disconnected")
            ScheduleReconnect()
        end
    end
end

function ReceivedFromNetwork(idBinding, nPort, strData)
    if idBinding == BINDING_NET then HandleRx(strData) end
end

function ReceivedFromSerial(idBinding, strData)
    if idBinding == BINDING_SERIAL then HandleRx(strData) end
end

function ScheduleReconnect()
    if g_RetryTimer then C4:KillTimer(g_RetryTimer); g_RetryTimer = nil end
    g_RetryTimer = C4:SetTimer(10000, function()
        g_RetryTimer = nil
        if not g_Connected and g_Connection == "Network" then OpenConnection() end
    end)
end

------------------------------------------------------------
-- Protocol frame builder
------------------------------------------------------------
function BuildFrame(rw, func, data)
    data = data or ""
    local body = string.char(g_DeviceID, rw, func, #data) .. data
    return FRAME_HEAD .. body .. FRAME_TAIL
end

function Enqueue(rw, func, data, opts)
    opts = opts or {}
    local frame = BuildFrame(rw, func, data)
    table.insert(g_CmdQueue, {
        data = frame,
        scene = opts.scene == true,
        expectRead = rw == RW_READ,
        func = func,
    })
    Drain()
end

function SendNow(item)
    if not item then return end
    if g_Connection == "Network" then
        if not g_Connected then
            dbg("Not connected, dropping send")
            return
        end
        C4:SendToNetwork(BINDING_NET, g_Port, item.data)
    else
        C4:SendToSerial(BINDING_SERIAL, item.data)
    end
    g_LastSendMs = nowMs()
    if item.scene then g_LastSceneMs = g_LastSendMs end
    g_Pending = item
    dbg("TX: " .. hex(item.data))
end

function Drain()
    if #g_CmdQueue == 0 then return end
    if g_Pending then return end  -- wait for response or timeout

    local now = nowMs()
    local wait = 0
    if (now - g_LastSendMs) < CMD_GAP_MS then
        wait = math.max(wait, CMD_GAP_MS - (now - g_LastSendMs))
    end
    if (now - g_LastSceneMs) < SCENE_GAP_MS then
        wait = math.max(wait, SCENE_GAP_MS - (now - g_LastSceneMs))
    end

    if wait > 0 then
        if g_DrainTimer then C4:KillTimer(g_DrainTimer) end
        g_DrainTimer = C4:SetTimer(wait, function()
            g_DrainTimer = nil
            Drain()
        end)
        return
    end

    local item = table.remove(g_CmdQueue, 1)
    SendNow(item)
    -- response timeout to clear pending
    if g_DrainTimer then C4:KillTimer(g_DrainTimer) end
    g_DrainTimer = C4:SetTimer(1500, function()
        g_DrainTimer = nil
        if g_Pending then
            dbg("Response timeout for func=0x" .. string.format("%02X", g_Pending.func))
            g_Pending = nil
            Drain()
        end
    end)
end

------------------------------------------------------------
-- Response parser
------------------------------------------------------------
function HandleRx(strData)
    g_RxBuffer = g_RxBuffer .. strData
    dbg("RX raw: " .. hex(strData))
    while #g_RxBuffer > 0 do
        local consumed = ParseOne()
        if consumed == 0 then break end
        g_RxBuffer = g_RxBuffer:sub(consumed + 1)
    end
end

function ParseOne()
    local b1 = string.byte(g_RxBuffer, 1)
    if b1 == nil then return 0 end

    -- Full read-response frame begins with header
    if b1 == 0xA5 and #g_RxBuffer >= 4
       and g_RxBuffer:sub(1,4) == FRAME_HEAD then
        if #g_RxBuffer < 9 then return 0 end  -- need head(4)+id+rw+func+len + tail
        local len  = string.byte(g_RxBuffer, 8)
        local need = 4 + 4 + len + 1
        if #g_RxBuffer < need then return 0 end
        if string.byte(g_RxBuffer, need) ~= 0xEE then
            -- malformed; resync by dropping first byte
            return 1
        end
        local frame = g_RxBuffer:sub(1, need)
        OnFrame(frame)
        return need
    end

    -- Single-byte write ack (0x00 success, 0x01 failure)
    if b1 == 0x00 or b1 == 0x01 then
        OnWriteAck(b1)
        return 1
    end

    -- Unknown byte, drop it to resync
    dbg("Drop unknown byte: " .. string.format("%02X", b1))
    return 1
end

function OnWriteAck(code)
    if g_Pending then
        local f = g_Pending.func
        g_Pending = nil
        if code == 0x00 then
            dbg(string.format("ACK ok (func 0x%02X)", f))
        else
            dbg(string.format("ACK fail (func 0x%02X)", f))
            C4:FireEvent("Command Failed")
        end
        if g_DrainTimer then C4:KillTimer(g_DrainTimer); g_DrainTimer = nil end
        Drain()
    end
end

function OnFrame(frame)
    dbg("Frame: " .. hex(frame))
    local rw   = string.byte(frame, 6)
    local func = string.byte(frame, 7)
    local len  = string.byte(frame, 8)
    local data = frame:sub(9, 8 + len)

    if rw == RW_READ then
        if func == FUNC.SCENE and len >= 1 then
            local scene = string.byte(data, 1)
            C4:UpdateProperty("Current Scene", tostring(scene))
            C4:FireEvent("Scene Changed")
        elseif func == FUNC.DEVICE_IP and len >= 4 then
            local ip = string.format("%d.%d.%d.%d",
                string.byte(data, 1), string.byte(data, 2),
                string.byte(data, 3), string.byte(data, 4))
            dbg("Device IP: " .. ip)
            -- only update IP property if currently empty/default
        end
    end

    if g_Pending then
        g_Pending = nil
        if g_DrainTimer then C4:KillTimer(g_DrainTimer); g_DrainTimer = nil end
        Drain()
    end
end

------------------------------------------------------------
-- Protocol helpers
------------------------------------------------------------
function ChanByte(ch)
    -- 0=all (sent as 0x00), 1..4
    ch = tonumber(ch) or 0
    if ch < 0 or ch > 4 then ch = 0 end
    return ch
end

function IOByte(io)
    -- "Output"->0x02, "Input"->0x01
    if tostring(io):lower():find("input") then return 0x01 end
    return 0x02
end

function SignedVolBytes(v01dB)
    local v = tonumber(v01dB) or 0
    if v < -600 then v = -600 end
    if v > 150 then v = 150 end
    if v < 0 then v = v + 0x10000 end  -- two's complement, 16-bit
    local lo = v % 256
    local hi = math.floor(v / 256) % 256
    return string.char(lo, hi)
end

function ClampStep(s)
    s = tonumber(s) or 10
    if s < 1 then s = 1 end
    if s > 255 then s = 255 end
    return s
end

------------------------------------------------------------
-- ExecuteCommand router
------------------------------------------------------------
function ExecuteCommand(strCommand, tParams)
    dbg("EC: " .. tostring(strCommand))
    local f = EC[strCommand]
    if f then return f(tParams or {}) end
    -- fall through to LUA_ACTION when programming sends actions
    if strCommand == "LUA_ACTION" then
        local act = (tParams or {})["ACTION"]
        local fn = LUA_ACTION[act]
        if fn then return fn(tParams) end
    end
end

EC["Standby On"] = function()
    Enqueue(RW_WRITE, FUNC.STANDBY, string.char(0x00))
    C4:UpdateProperty("Power", "Standby")
end
EC["Standby Off"] = function()
    Enqueue(RW_WRITE, FUNC.STANDBY, string.char(0x01))
    C4:UpdateProperty("Power", "On")
end

EC["Recall Scene"] = function(p)
    local n = tonumber(p["Scene"]) or 1
    if n < 1 then n = 1 end
    if n > 31 then n = 31 end
    Enqueue(RW_WRITE, FUNC.SCENE, string.char(n), { scene = true })
    C4:UpdateProperty("Current Scene", tostring(n))
end

EC["Set Output Volume"] = function(p)
    local ch = ChanByte(p["Channel"])
    local vol = SignedVolBytes(p["Volume_0_1dB"])
    Enqueue(RW_WRITE, FUNC.VOLUME,
        string.char(0x02, ch) .. vol)
end
EC["Set Input Volume"] = function(p)
    local ch = ChanByte(p["Channel"])
    local vol = SignedVolBytes(p["Volume_0_1dB"])
    Enqueue(RW_WRITE, FUNC.VOLUME,
        string.char(0x01, ch) .. vol)
end

EC["Volume Up"] = function(p)
    Enqueue(RW_WRITE, FUNC.VOLUME_STEP,
        string.char(IOByte(p["IO"]), ChanByte(p["Channel"]),
                    0x00, ClampStep(p["Step_0_1dB"])))
end
EC["Volume Down"] = function(p)
    Enqueue(RW_WRITE, FUNC.VOLUME_STEP,
        string.char(IOByte(p["IO"]), ChanByte(p["Channel"]),
                    0x01, ClampStep(p["Step_0_1dB"])))
end

EC["Set Mute"] = function(p)
    local state = (tostring(p["State"]):lower() == "on") and 0x01 or 0x00
    Enqueue(RW_WRITE, FUNC.MUTE,
        string.char(IOByte(p["IO"]), ChanByte(p["Channel"]), state))
end

EC["Matrix Connect"] = function(p)
    local i = tonumber(p["Input"]) or 1
    local o = tonumber(p["Output"]) or 1
    local c = (tostring(p["Connect"]):lower():find("dis")) and 0x00 or 0x01
    Enqueue(RW_WRITE, FUNC.MATRIX, string.char(i, o, c))
end

EC["Set Working Mode"] = function(p)
    local g = tostring(p["Group"])
    local grp = g:find("3 and 4") and 0x01 or 0x00
    local modeMap = { ["Stereo"]=0x00, ["Mono"]=0x01,
                      ["Bridge"]=0x02, ["Matrix"]=0x03 }
    local m = modeMap[tostring(p["Mode"])] or 0x00
    Enqueue(RW_WRITE, FUNC.WORK_MODE, string.char(grp, m))
end

EC["Set Line Mic"] = function(p)
    local ch  = tonumber(p["Channel"]) or 1
    local sen = tostring(p["Sensitivity"]):find("6") and 0x01 or 0x00
    Enqueue(RW_WRITE, FUNC.LINE_MIC,
        string.char(ch, 0x00, sen))
end

EC["Query Current Scene"] = function()
    Enqueue(RW_READ, FUNC.SCENE, "")
end
EC["Query Device IP"] = function()
    Enqueue(RW_READ, FUNC.DEVICE_IP, "")
end
EC["Page Device"] = function()
    Enqueue(RW_WRITE, FUNC.PAGE, "")
end

EC["Send Raw Hex"] = function(p)
    local s = tostring(p["Hex"] or ""):gsub("[^%x]", "")
    if #s % 2 ~= 0 then dbg("Raw hex bad length"); return end
    local bytes = {}
    for i = 1, #s, 2 do
        bytes[#bytes+1] = string.char(tonumber(s:sub(i, i+1), 16))
    end
    local frame = table.concat(bytes)
    if g_Connection == "Network" then
        C4:SendToNetwork(BINDING_NET, g_Port, frame)
    else
        C4:SendToSerial(BINDING_SERIAL, frame)
    end
    dbg("Raw TX: " .. hex(frame))
end

------------------------------------------------------------
-- ReceivedFromProxy (audio_matrix_switch standard commands)
------------------------------------------------------------
function ReceivedFromProxy(idBinding, strCommand, tParams)
    dbg(string.format("RFP: bind=%d cmd=%s", idBinding, tostring(strCommand)))
    local f = RFP[strCommand]
    if f then return f(idBinding, tParams or {}) end
end

RFP["ON"]  = function() EC["Standby Off"]({}) end
RFP["OFF"] = function() EC["Standby On"]({})  end

-- audio_matrix_switch crosspoint set: input N to output M
RFP["SET_INPUT"] = function(idBinding, p)
    -- typical params: INPUT, OUTPUT; idBinding == output binding
    local out = tonumber(p["OUTPUT"]) or (idBinding - 200)
    local inp = tonumber(p["INPUT"]) or 0
    if inp <= 0 then
        Enqueue(RW_WRITE, FUNC.MATRIX, string.char(0x01, out, 0x00))
        return
    end
    -- disconnect other inputs from this output, then connect requested input
    for i = 1, 4 do
        if i ~= inp then
            Enqueue(RW_WRITE, FUNC.MATRIX, string.char(i, out, 0x00))
        end
    end
    Enqueue(RW_WRITE, FUNC.MATRIX, string.char(inp, out, 0x01))
end

-- Volume from proxy (level 0..100)  → map to dB
RFP["SET_LEVEL"] = function(idBinding, p)
    local out = (idBinding >= 200 and idBinding < 300) and (idBinding - 200) or 0
    local lvl = tonumber(p["LEVEL"]) or 50
    if lvl < 0 then lvl = 0 end
    if lvl > 100 then lvl = 100 end
    -- map 0..100 → -60..0 dB → -600..0 (0.1 dB)
    local v01 = math.floor(((lvl - 100) * 6) + 0.5)  -- 100->0, 0->-600
    Enqueue(RW_WRITE, FUNC.VOLUME,
        string.char(0x02, out) .. SignedVolBytes(v01))
end

RFP["MUTE_ON"]  = function(idBinding) ProxyMute(idBinding, 0x01) end
RFP["MUTE_OFF"] = function(idBinding) ProxyMute(idBinding, 0x00) end
RFP["TOGGLE_MUTE"] = function(idBinding) ProxyMute(idBinding, 0x01) end

function ProxyMute(idBinding, state)
    local out = (idBinding >= 200 and idBinding < 300) and (idBinding - 200) or 0
    Enqueue(RW_WRITE, FUNC.MUTE, string.char(0x02, out, state))
end

------------------------------------------------------------
-- Programming actions
------------------------------------------------------------
LUA_ACTION["Reconnect"] = function()
    CloseConnection(); OpenConnection()
end

LUA_ACTION["QueryState"] = function()
    EC["Query Current Scene"]()
    EC["Query Device IP"]()
end

------------------------------------------------------------
-- Periodic heartbeat / state polling
------------------------------------------------------------
function StartTickTimer()
    if g_TickTimer then C4:KillTimer(g_TickTimer) end
    g_TickTimer = C4:SetTimer(60000, function()
        if g_Connected or g_Connection == "Serial" then
            EC["Query Current Scene"]()
        end
        StartTickTimer()
    end)
end

function StopTickTimer()
    if g_TickTimer then C4:KillTimer(g_TickTimer); g_TickTimer = nil end
end
