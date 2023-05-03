AddCSLuaFile()
module("greatzenkakuman.predicted", package.seeall)

local IsValid = IsValid
local CurTime = CurTime
local isentity = isentity
local istable = istable
local isvector = isvector
local isangle = isangle
local ismatrix = ismatrix
local pairs = pairs
local Vector = Vector
local Angle = Angle
local isSingleplayer = game.SinglePlayer()

--==== Predicted EmitSound ====--

local NET_LEVEL_BITS = 9
local NET_PITCH_BITS = 8
local NET_CHAN_BITS  = 9
local NET_FLAGS_BITS = 10
local NET_DSP_BITS   = 8
local netNameEnt  = "greatzenkakuman.predicted.EmitSound"
local netNamePos  = "greatzenkakuman.predicted.EmitSound.NoEntity"
local netNameStop = "greatzenkakuman.predicted.StopSound"
local netSendSP   = "greatzenkakuman.predicted.SendToClientSP"
local function GetDefaultChannel(ent)
    if isentity(ent) and IsValid(ent) and ent:IsWeapon() then
        return CHAN_WEAPON
    else
        return CHAN_AUTO
    end
end

local function Play(ent, pos, soundName, ...)
    if pos then
        sound.Play(soundName, pos, ...)
    else
        ent:EmitSound(soundName, ...)
    end
end

if SERVER then
    util.AddNetworkString(netNameEnt)
    util.AddNetworkString(netNamePos)
    util.AddNetworkString(netNameStop)
else
    local function EmitSoundClient(ent)
        local pos
        local name = net.ReadString()
        local extra = net.ReadBool()
        local level = 75
        local pitch = 100
        local volume = 1
        local channel = GetDefaultChannel(ent)
        local flags = SND_NOFLAGS
        local dsp = 0
        if extra then
            level = net.ReadUInt(NET_LEVEL_BITS)
            pitch = net.ReadUInt(NET_PITCH_BITS)
            volume = net.ReadFloat()
            channel = net.ReadInt(NET_CHAN_BITS)
            flags = net.ReadUInt(NET_FLAGS_BITS)
            dsp = net.ReadUInt(NET_DSP_BITS)
        end
        if isvector(ent) then pos, ent = ent, nil end
        if isentity(ent) then
            ent:EmitSound(name, level, pitch, volume, channel, flags, dsp)
        else
            sound.Play(name, pos, level, pitch, volume)
        end
    end

    net.Receive(netNameEnt, function() EmitSoundClient(net.ReadEntity()) end)
    net.Receive(netNamePos, function() EmitSoundClient(net.ReadVector()) end)
    net.Receive(netNameStop, function()
        local ent = net.ReadEntity()
        if not IsValid(ent) then return end
        local soundName = net.ReadString()
        ent:StopSound(soundName)
    end)
end

function EmitSound(ent, soundName,
    soundLevel, pitchPercent, volume, channel, soundFlags, dsp)
    local pos
    local defaultChannel = GetDefaultChannel(ent)
    local predicted = GetPredictionPlayer()
    local predictedWeapon = IsValid(predicted) and predicted:GetActiveWeapon()
    local extra = soundLevel and pitchPercent and volume and
                  channel    and soundFlags   and dsp
    if isvector(ent) then pos, ent = ent, nil end
    soundLevel   = soundLevel   or 75
    pitchPercent = pitchPercent or 100
    volume       = volume       or 1
    channel      = channel      or defaultChannel
    soundFlags   = soundFlags   or SND_NOFLAGS
    dsp          = dsp          or 0

    if isSingleplayer or ent == predictedWeapon
    or CLIENT and IsFirstTimePredicted() then
        Play(ent, pos, soundName,
            soundLevel, pitchPercent, volume, channel, soundFlags, dsp)
        return
    end

    if CLIENT then return end
    net.Start(pos and netNamePos or netNameEnt)
    if pos then
        net.WriteVector(pos)
    else
        net.WriteEntity(ent)
    end
    net.WriteString(soundName)
    net.WriteBool(extra)
    if extra then
        net.WriteUInt(soundLevel, NET_LEVEL_BITS)
        net.WriteUInt(pitchPercent, NET_PITCH_BITS)
        net.WriteFloat(volume)
        net.WriteInt(channel, NET_CHAN_BITS)
        net.WriteUInt(soundFlags, NET_FLAGS_BITS)
        net.WriteUInt(dsp, NET_DSP_BITS)
    end

    if IsValid(predicted) then
        net.SendOmit(predicted)
    else
        net.Broadcast()
    end
end

function StopSound(ent, soundName)
    if not IsValid(ent) then return end
    local predicted = GetPredictionPlayer()
    local predictedWeapon = IsValid(predicted) and predicted:GetActiveWeapon()
    if isSingleplayer or ent == predictedWeapon
    or CLIENT and IsFirstTimePredicted() then
        ent:StopSound(soundName)
        return
    end

    if CLIENT then return end
    net.Start(netNameStop)
    net.WriteEntity(ent)
    net.WriteString(soundName)
    if IsValid(predicted) then
        net.SendOmit(predicted)
    else
        net.Broadcast()
    end
end

function Effect(name, effectdata)
    if isSingleplayer or IsFirstTimePredicted() then
        util.Effect(name, effectdata)
    end
end

--==== Predicted Variable using Backtrack Elimination ====--

local __pool  = {} -- [CurTime()][key] = value
local __stash = {} -- table.Copy(PredictedVars)
local __vars  = {} -- [key] = value
local function __deepcopy(t, lookup)
    if t == nil then return nil end

    local copy = {}
    for k, v in pairs(t) do
        if istable(v) then
            lookup = lookup or {}
            lookup[t] = copy
            if lookup[v] then
                copy[k] = lookup[v]
            else
                copy[k] = __deepcopy(v, lookup)
            end
        elseif isvector(v) then
            copy[k] = Vector(v)
        elseif isangle(v) then
            copy[k] = Angle(v)
        elseif ismatrix(v) then
            copy[k] = Matrix(v)
        else
            copy[k] = v
        end
    end

    return copy
end

if isSingleplayer then
    if SERVER then
        util.AddNetworkString(netSendSP)
    else
        net.Receive(netSendSP, function()
            __vars.key = net.ReadString()
            local key = net.ReadString()
            local ent = net.ReadEntity()
            local value = net.ReadType()
            __vars[__vars.key]           = __vars[__vars.key]      or {}
            __vars[__vars.key][ent]      = __vars[__vars.key][ent] or {}
            __vars[__vars.key][ent][key] = value
        end)
    end
end

local function __tohash(t)
    return math.Round(t / engine.TickInterval())
end

local function __totime(h)
    return h * engine.TickInterval()
end

local function __clean()
    if not __pool[__vars.key] then return end
    local ent = GetPredictionPlayer()
    local tick = engine.TickInterval()
    local ping = SERVER and 0 or LocalPlayer():Ping() / 1000
    for hash in pairs(__pool[__vars.key][ent] or {}) do
        local trackedTime = __totime(hash)
        if CurTime() > trackedTime + ping + tick * 2 then
            __pool[__vars.key][ent][hash] = nil
        end
    end
end

local function __getpast(id, ent, includeCurrent)
    if not (__pool[id] and __pool[id][ent]) then return end
    local hash = __tohash(CurTime())
    local tick = engine.TickInterval()
    local ping = SERVER and 0 or LocalPlayer():Ping() / 1000
    local trackLength = __tohash(ping + tick * 2)
    for i = includeCurrent and 0 or 1, trackLength do
        if __pool[id][ent][hash - i] then
            return __pool[id][ent][hash - i]
        end
    end
end

local function __begin(id)
    __vars.key = id
    __vars[__vars.key] = __vars[__vars.key] or {}
    local ent = GetPredictionPlayer()
    if __pool[__vars.key] and __pool[__vars.key][ent] then
        local target = __getpast(__vars.key, ent)
        if target then
            __stash[ent] = __deepcopy(__vars[__vars.key][ent] or {})
            __vars[__vars.key][ent] = __deepcopy(target)
        end
    end
end

local function __terminate()
    local ent = GetPredictionPlayer()
    local hash = __tohash(CurTime())
    __clean(ent)

    __pool[__vars.key]      = __pool[__vars.key]      or {}
    __pool[__vars.key][ent] = __pool[__vars.key][ent] or {}
    if __pool[__vars.key][ent][hash] then
        __vars[__vars.key][ent] = __deepcopy(__stash[ent] or {})
    else
        __pool[__vars.key][ent][hash] = __deepcopy(__vars[__vars.key][ent])
    end
end

-- key, default = nil | ply, id, key, default = nil
function Get(...)
    local args = {...}
    if isentity(args[1]) then
        local ent, id      = args[1], args[2]
        local key, default = args[3], args[4]
        if __vars[id] and __vars[id][ent] and __vars[id][ent][key] ~= nil then
            return __vars[id][ent][key]
        end

        local pool = __getpast(id, ent, true)
        if IsValid(ent) and pool and pool[key] ~= nil then
            return pool[key]
        end
        return default
    else
        local ent = GetPredictionPlayer()
        local key, default = args[1], args[2]
        if IsValid(ent)
        and __vars.key ~= nil
        and __vars[__vars.key]
        and __vars[__vars.key][ent]
        and __vars[__vars.key][ent][key] ~= nil then
            return __vars[__vars.key][ent][key]
        end
        return default
    end
end

function Set(key, value)
    if __vars.key == nil then return end
    local ent = GetPredictionPlayer()
    if not IsValid(ent) then return end
    __vars[__vars.key]           = __vars[__vars.key]      or {}
    __vars[__vars.key][ent]      = __vars[__vars.key][ent] or {}
    __vars[__vars.key][ent][key] = value

    if not (isSingleplayer and SERVER) then return end
    net.Start(netSendSP)
    net.WriteString(__vars.key)
    net.WriteString(key)
    net.WriteEntity(ent)
    net.WriteType(value)
    net.Broadcast()
end

function Process(id, func)
    __begin(id)
    local a = { func(greatzenkakuman.predicted) }
    __terminate()
    return unpack(a)
end