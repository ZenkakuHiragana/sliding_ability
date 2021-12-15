-- Thanks to WholeCream, prediction issues are fixed.

sound.Add {
    name = "SlidingAbility.ImpactSoft",
    channel = CHAN_BODY,
    level = 75,
    volume = 0.6,
    sound = {
        "physics/body/body_medium_impact_soft1.wav",
        "physics/body/body_medium_impact_soft2.wav",
        "physics/body/body_medium_impact_soft5.wav",
        "physics/body/body_medium_impact_soft6.wav",
        "physics/body/body_medium_impact_soft7.wav",
    },
}
sound.Add {
    name = "SlidingAbility.ScrapeRough",
    channel = CHAN_STATIC,
    level = 70,
    volume = 0.25,
    sound = "physics/body/body_medium_scrape_rough_loop1.wav",
}

local cf = {FCVAR_REPLICATED, FCVAR_ARCHIVE}
local CVarAccel = CreateConVar("sliding_ability_acceleration", 250, cf,
"The acceleration/deceleration of the sliding.  Larger value makes shorter sliding.")
local CVarCooldown = CreateConVar("sliding_ability_cooldown", 0.3, cf,
"Cooldown time to be able to slide again in seconds.")
local CVarCooldownJump = CreateConVar("sliding_ability_cooldown_jump", 0.6, cf,
"Cooldown time to be able to slide again when you jump while sliding, in seconds.")
local SLIDING_ABILITY_BLACKLIST = {
    climb_swep2 = true,
    parkourmod = true,
}
local SLOPE_MAX = math.cos(math.rad(45))
local SLIDE_ANIM_TRANSITION_TIME = 0.2
local SLIDE_TILT_DEG = 42
local IN_MOVE = bit.bor(IN_FORWARD, IN_BACK, IN_MOVELEFT, IN_MOVERIGHT)
local ACT_HL2MP_SIT_CAMERA = "sit_camera"
local ACT_HL2MP_SIT_DUEL = "sit_duel"
local ACT_HL2MP_SIT_PASSIVE = "sit_passive"
local acts = {
    revolver = ACT_HL2MP_SIT_PISTOL,
    pistol = ACT_HL2MP_SIT_PISTOL,
    shotgun = ACT_HL2MP_SIT_SHOTGUN,
    smg = ACT_HL2MP_SIT_SMG1,
    ar2 = ACT_HL2MP_SIT_AR2,
    physgun = ACT_HL2MP_SIT_PHYSGUN,
    grenade = ACT_HL2MP_SIT_GRENADE,
    rpg = ACT_HL2MP_SIT_RPG,
    crossbow = ACT_HL2MP_SIT_CROSSBOW,
    melee = ACT_HL2MP_SIT_MELEE,
    melee2 = ACT_HL2MP_SIT_MELEE2,
    slam = ACT_HL2MP_SIT_SLAM,
    fist = ACT_HL2MP_SIT_FIST,
    normal = ACT_HL2MP_SIT_DUEL,
    camera = ACT_HL2MP_SIT_CAMERA,
    duel = ACT_HL2MP_SIT_DUEL,
    passive = ACT_HL2MP_SIT_PASSIVE,
    magic = ACT_HL2MP_SIT_DUEL,
    knife = ACT_HL2MP_SIT_KNIFE,
}
local function AngleEqualTol(a1, a2, tol)
    tol = tol or 1e-3
    if not (isangle(a1) and isangle(a2)) then return false end
    if math.abs(a1.pitch - a2.pitch) > tol then return false end
    if math.abs(a1.yaw - a2.yaw) > tol then return false end
    if math.abs(a1.roll - a2.roll) > tol then return false end
    return true
end

local function GetSlidingActivity(ply)
    local w, a = ply:GetActiveWeapon(), ACT_HL2MP_SIT_DUEL
    if IsValid(w) then a = acts[string.lower(w:GetHoldType())] or acts[string.lower(w.HoldType or "")] or ACT_HL2MP_SIT_DUEL end
    if isstring(a) then return ply:GetSequenceActivity(ply:LookupSequence(a)) end
    return a
end

local BoneAngleCache = SERVER and {} or nil
local function ManipulateBoneAnglesLessTraffic(ent, bone, ang, frac)
    local a = SERVER and ang or ang * frac
    if CLIENT or not (BoneAngleCache[ent] and AngleEqualTol(BoneAngleCache[ent][bone], a, 1)) then
        ent:ManipulateBoneAngles(bone, a)
        if CLIENT then return end
        if not BoneAngleCache[ent] then BoneAngleCache[ent] = {} end
        BoneAngleCache[ent][bone] = a
    end
end

local function ManipulateBones(ply, ent, base, thigh, calf)
    if not IsValid(ent) then return end
    local bthigh = ent:LookupBone "ValveBiped.Bip01_R_Thigh"
    local bcalf = ent:LookupBone "ValveBiped.Bip01_R_Calf"
    local t0 = ply:GetNWFloat "SlidingAbility_SlidingStartTime"
    local timefrac = math.TimeFraction(t0, t0 + SLIDE_ANIM_TRANSITION_TIME, CurTime())
    timefrac = SERVER and 1 or math.Clamp(timefrac, 0, 1)
    if bthigh or bcalf then ManipulateBoneAnglesLessTraffic(ent, 0, base, timefrac) end
    if bthigh then ManipulateBoneAnglesLessTraffic(ent, bthigh, thigh, timefrac) end
    if bcalf then ManipulateBoneAnglesLessTraffic(ent, bcalf, calf, timefrac) end
    local dp = thigh:IsZero() and Vector() or Vector(12, 0, -18)
    for _, ec in pairs {EnhancedCamera, EnhancedCameraTwo} do
        if ent == ec.entity then
            local w = ply:GetActiveWeapon()
            local seqname = LocalPlayer():GetSequenceName(ec:GetSequence())
            local pose = IsValid(w) and string.lower(w.HoldType or "") or ""
            if pose == "" then pose = seqname:sub((seqname:find "_" or 0) + 1) end
            if pose:find "all" then pose = "normal" end
            if pose == "smg1" then pose = "smg" end
            if pose and pose ~= "" and pose ~= ec.pose then
                ec.pose = pose
                ec:OnPoseChange()
            end

            ent:ManipulateBonePosition(0, dp * timefrac)
        end
    end
end

local function EndSliding(ply)
    if SERVER then ManipulateBones(ply, ply, Angle(), Angle(), Angle()) end
    ply.SlidingAbility_IsSliding = false
    ply.SlidingAbility_SlidingStartTime = CurTime()
    ply:SetNWBool("SlidingAbility_IsSliding", false)
    ply:SetNWFloat("SlidingAbility_SlidingStartTime", CurTime())
    if SERVER then ply:StopSound "SlidingAbility.ScrapeRough" end
end

local function SetSlidingPose(ply, ent, body_tilt)
    ManipulateBones(ply, ent, -Angle(0, 0, body_tilt), Angle(20, 35, 85), Angle(0, 45, 0))
end

-- Backtack our data by WholeCream
local SlidingBacktrack = {}
local PredictedVars = {
    ["SlidingAbility_SlidingCurrentVelocity"] = Vector(),
}

local function GetPredictedVar(ply, name)
    return SERVER and ply[name] or PredictedVars[name]
end

local function SetPredictedVar(ply, name, value)
    if CLIENT then
        PredictedVars[name] = value
    else
        ply[name] = value
    end
end

hook.Add("SetupMove", "Check sliding", function(ply, mv, cmd)
    local w = ply:GetActiveWeapon()
    if IsValid(w) and SLIDING_ABILITY_BLACKLIST[w:GetClass()] then return end
    if ConVarExists "savav_parkour_Enable" and GetConVar "savav_parkour_Enable":GetBool() then return end
    if ConVarExists "sv_sliding_enabled" and GetConVar "sv_sliding_enabled":GetBool() and ply.HasExosuit ~= false then return end
    if ply:GetNWFloat "SlidingPreserveWalkSpeed" > 0 then
        local v = GetPredictedVar(ply, "SlidingAbility_SlidingCurrentVelocity") or Vector()
        v.z = mv:GetVelocity().z
        mv:SetVelocity(v)
    end

    if not ply.SlidingAbility_SlidingPreviousPosition then
        ply.SlidingAbility_SlidingPreviousPosition = Vector()
        ply.SlidingAbility_SlidingStartTime = 0
        ply.SlidingAbility_IsSliding = false
    end
    
    ply:SetNWFloat("SlidingPreserveWalkSpeed", -1)
    if IsFirstTimePredicted() and not ply:Crouching() and ply.SlidingAbility_IsSliding then
        EndSliding(ply)
    end
    
    -- Actual calculation of movement
    local CT = CurTime()
    if (ply:Crouching() and ply.SlidingAbility_IsSliding) or (CLIENT and SlidingBacktrack[CT]) then
        local restorevars = {}
        local vpbacktrack
        if CLIENT and not ply:KeyDown(IN_JUMP) then
            if SlidingBacktrack[CT] then
                local data = SlidingBacktrack[CT]
                for k, v in pairs(PredictedVars) do
                    restorevars[k] = v
                    PredictedVars[k] = data[k]
                end
                vpbacktrack = true
            elseif not IsFirstTimePredicted() then
                return
            end
        end

        -- Calculate movement
        local v = GetPredictedVar(ply, "SlidingAbility_SlidingCurrentVelocity") or Vector()
        local speed = v:Length()
        local speedref_crouch = ply:GetWalkSpeed() * ply:GetCrouchedWalkSpeed()
        if not vpbacktrack then
            local vdir = v:GetNormalized()
            local forward = mv:GetMoveAngles():Forward()
            local speedref_slide = ply.SlidingAbility_SlidingMaxSpeed
            local speedref_min = math.min(speedref_crouch, speedref_slide)
            local speedref_max = math.max(speedref_crouch, speedref_slide)
            local dp = mv:GetOrigin() - ply.SlidingAbility_SlidingPreviousPosition
            local dp2d = Vector(dp.x, dp.y)
            dp:Normalize()
            dp2d:Normalize()
            local dot = forward:Dot(dp2d)
            local speedref = Lerp(math.max(-dp.z, 0), speedref_min, speedref_max)
            local accel_cvar = CVarAccel:GetFloat()
            local accel = accel_cvar * engine.TickInterval()
            if speed > speedref then accel = -accel end
            v = LerpVector(0.005, vdir, forward) * (speed + accel)

            SetSlidingPose(ply, ply, math.deg(math.asin(dp.z)) * dot + SLIDE_TILT_DEG)
            SetPredictedVar(ply, "SlidingAbility_SlidingCurrentVelocity", v)
            ply.SlidingAbility_SlidingCurrentVelocity = v
            ply.SlidingAbility_SlidingPreviousPosition = mv:GetOrigin()
        end

        -- Set push velocity
        mv:SetVelocity(GetPredictedVar(ply, "SlidingAbility_SlidingCurrentVelocity"))

        -- Effects & ending
        if not vpbacktrack then
            if not ply:OnGround() or mv:KeyPressed(IN_JUMP) or mv:KeyReleased(IN_DUCK) or math.abs(speed - speedref_crouch) < 10 then
                EndSliding(ply)
                if mv:KeyPressed(IN_JUMP) then
                    local t = CurTime() + CVarCooldownJump:GetFloat()
                    ply.SlidingAbility_SlidingStartTime = t
                    ply:SetNWFloat("SlidingAbility_SlidingStartTime", t)
                    ply:SetNWFloat("SlidingPreserveWalkSpeed", ply:GetWalkSpeed())
                end
            end

            local e = EffectData()
            e:SetOrigin(mv:GetOrigin())
            e:SetScale(1.6)
            util.Effect("WheelDust", e)
        end

        -- Restore backtrack or record data
        if CLIENT then
            if vpbacktrack then
                for k, v in pairs(restorevars) do
                    PredictedVars[k] = v
                end
                vpbacktrack = nil
            elseif not SlidingBacktrack[CT] then
                if SERVER then
                    SlidingBacktrack[CT] = {}
                    for k, v in pairs(PredictedVars) do
                        SlidingBacktrack[CT][k] = v
                    end
                    local keys = table.GetKeys(SlidingBacktrack)
                    table.sort(keys, function(a, b) return a > b end)
                    for i = 1, #keys do
                        local v = keys[i]
                        if i > 2 then
                            SlidingBacktrack[v] = nil
                        end
                    end
                else
                    SlidingBacktrack[CT] = {}
                    for k, v in pairs(PredictedVars) do
                        SlidingBacktrack[CT][k] = v
                    end
                    local tickint = engine.TickInterval()
                    local ping = LocalPlayer():Ping() / 1000
                    for k, v in pairs(SlidingBacktrack) do
                        if CT - (ping + tickint * 2) > k then
                            SlidingBacktrack[k] = nil
                        end
                    end
                end
            end
        end

        return
    end
    
    -- Initial check to see if we can do it
    if ply.SlidingAbility_IsSliding then return end
    if not ply:OnGround() then return end
    if not ply:Crouching() then return end
    if not IsFirstTimePredicted() then return end
    if not mv:KeyDown(IN_DUCK) then return end
    -- if not mv:KeyDown(IN_SPEED) then return end -- This disables sliding for some people for some reason
    if not mv:KeyDown(bit.bor(IN_FORWARD, IN_BACK, IN_MOVELEFT, IN_MOVERIGHT)) then return end
    if CurTime() < ply.SlidingAbility_SlidingStartTime + CVarCooldown:GetFloat() then return end
    if math.abs(ply:GetWalkSpeed() - ply:GetRunSpeed()) < 25 then return end

    local v = mv:GetVelocity()
    local speed = v:Length()
    local run = ply:GetRunSpeed()
    local crouched = ply:GetWalkSpeed() * ply:GetCrouchedWalkSpeed()
    local threshold = (run + crouched) / 2
    if run > crouched and speed < threshold then return end
    if run < crouched and (speed < run - 1 or speed > threshold) then return end
    local runspeed = math.max(ply:GetVelocity():Length(), speed, run) * 1.5
    local dir = v:GetNormalized()
    local ping = SERVER and 0 or (ply == LocalPlayer() and ply:Ping() / 1000 or 0)
    ply.SlidingAbility_IsSliding = true
    ply.SlidingAbility_SlidingStartTime = CurTime() - ping
    ply.SlidingAbility_SlidingCurrentVelocity = dir * runspeed
    ply.SlidingAbility_SlidingMaxSpeed = runspeed * 5
    ply:SetNWBool("SlidingAbility_IsSliding", true)
    ply:SetNWFloat("SlidingAbility_SlidingStartTime", ply.SlidingAbility_SlidingStartTime)
    ply:SetNWVector("SlidingAbility_SlidingMaxSpeed", ply.SlidingAbility_SlidingMaxSpeed)
    SetPredictedVar(ply, "SlidingAbility_SlidingCurrentVelocity", ply.SlidingAbility_SlidingCurrentVelocity)
    ply:EmitSound "SlidingAbility.ImpactSoft"
    if SERVER then ply:EmitSound "SlidingAbility.ScrapeRough" end
end)

hook.Add("PlayerFootstep", "Sliding sound", function(ply, pos, foot, sound, volume, filter)
    return ply:GetNWBool "SlidingAbility_IsSliding" or nil
end)

hook.Add("CalcMainActivity", "Sliding animation", function(ply, velocity)
    if not ply:GetNWBool "SlidingAbility_IsSliding" then return end
    if GetSlidingActivity(ply) == -1 then return end
    return GetSlidingActivity(ply), -1
end)

hook.Add("UpdateAnimation", "Sliding aim pose parameters", function(ply, velocity, maxSeqGroundSpeed)
    -- Workaround!!!  Revive Mod disables the sliding animation so we disable it
    local ReviveModUpdateAnimation = hook.GetTable().UpdateAnimation.BleedOutAnims
    if ReviveModUpdateAnimation then hook.Remove("UpdateAnimation", "BleedOutAnims") end
    if ReviveModUpdateAnimation and ply:IsBleedOut() then
        ReviveModUpdateAnimation(ply, velocity, maxSeqGroundSpeed)
        return
    end

    if not ply:GetNWBool "SlidingAbility_IsSliding" then
        if ply.SlidingAbility_SlidingReset then
            local l = ply
            if ply == LocalPlayer() then
                if g_LegsVer then l = GetPlayerLegs() end
                if EnhancedCamera then l = EnhancedCamera.entity end
                if EnhancedCameraTwo then l = EnhancedCameraTwo.entity end
            end

            if IsValid(l) then SetSlidingPose(ply, l, 0) end
            if g_LegsVer then ManipulateBones(ply, GetPlayerLegs(), Angle(), Angle(), Angle()) end
            if EnhancedCamera then ManipulateBones(ply, EnhancedCamera.entity, Angle(), Angle(), Angle()) end
            if EnhancedCameraTwo then ManipulateBones(ply, EnhancedCameraTwo.entity, Angle(), Angle(), Angle()) end
            ManipulateBones(ply, ply, Angle(), Angle(), Angle())
            ply.SlidingAbility_SlidingReset = nil
        end

        return
    end

    local pppitch = ply:LookupPoseParameter "aim_pitch"
    local ppyaw = ply:LookupPoseParameter "aim_yaw"
    if pppitch >= 0 and ppyaw >= 0 then
        local b = ply:GetManipulateBoneAngles(0).roll
        local p = ply:GetPoseParameter "aim_pitch" -- degrees in server, 0-1 in client
        local y = ply:GetPoseParameter "aim_yaw"
        if CLIENT then
            p = Lerp(p, ply:GetPoseParameterRange(pppitch))
            y = Lerp(y, ply:GetPoseParameterRange(ppyaw))
        end

        p = p - b

        local a = ply:GetSequenceActivity(ply:GetSequence())
        local la = ply:GetSequenceActivity(ply:GetLayerSequence(0))
        if a == ply:GetSequenceActivity(ply:LookupSequence(ACT_HL2MP_SIT_DUEL)) and la ~= ACT_HL2MP_GESTURE_RELOAD_DUEL then
            p = p - 45
            ply:SetPoseParameter("aim_yaw", ply:GetPoseParameterRange(ppyaw))
        elseif a == ply:GetSequenceActivity(ply:LookupSequence(ACT_HL2MP_SIT_CAMERA)) then
            y = y + 20
            ply:SetPoseParameter("aim_yaw", y)
        end

        ply:SetPoseParameter("aim_pitch", p)
    end

    if SERVER then return end

    local l = ply
    if ply == LocalPlayer() then
        if g_LegsVer then l = GetPlayerLegs() end
        if EnhancedCamera then l = EnhancedCamera.entity end
        if EnhancedCameraTwo then l = EnhancedCameraTwo.entity end
        if not IsValid(l) then return end
    end
    
    local dp = ply:GetPos() - (l.SlidingAbility_SlidingPreviousPosition or ply:GetPos())
    local dp2d = Vector(dp.x, dp.y)
    dp:Normalize()
    dp2d:Normalize()
    local dot = ply:GetForward():Dot(dp2d)
    SetSlidingPose(ply, l, math.deg(math.asin(dp.z)) * dot + SLIDE_TILT_DEG)
    l.SlidingAbility_SlidingPreviousPosition = ply:GetPos()
    ply.SlidingAbility_SlidingReset = true
end)

if SERVER then
    hook.Add("PlayerInitialSpawn", "Prevent breaking TPS model on changelevel", function(ply, transition)
        if not transition then return end
        timer.Simple(1, function()
            for i = 0, ply:GetBoneCount() - 1 do
                ply:ManipulateBoneScale(i, Vector(1, 1, 1))
                ply:ManipulateBoneAngles(i, Angle())
                ply:ManipulateBonePosition(i, Vector())
            end
        end)
    end)

    return
end

CreateClientConVar("sliding_ability_tilt_viewmodel", 1, true, true, "Enable viewmodel tilt like Apex Legends when sliding.")
hook.Add("CalcViewModelView", "Sliding view model tilt", function(w, vm, op, oa, p, a)
    if w.SuppressSlidingViewModelTilt then return end -- For the future addons which are compatible with this addon
    if w.ArcCW and w:GetState() == ArcCW.STATE_SIGHTS then return end
    if not (IsValid(w.Owner) and w.Owner:IsPlayer()) then return end
    if not GetConVar "sliding_ability_tilt_viewmodel":GetBool() then return end
    if w.IsTFAWeapon and w:GetIronSights() then return end
    local wp, wa = p, a
    if isfunction(w.CalcViewModelView) then wp, wa = w:CalcViewModelView(vm, op, oa, p, a) end
    if not (wp and wa) then wp, wa = p, a end

    local ply = w.Owner
    local t0 = ply:GetNWFloat "SlidingAbility_SlidingStartTime"
    local timefrac = math.TimeFraction(t0, t0 + SLIDE_ANIM_TRANSITION_TIME, CurTime())
    timefrac = math.Clamp(timefrac, 0, 1)
    if not ply:GetNWBool "SlidingAbility_IsSliding" then timefrac = 1 - timefrac end
    if timefrac == 0 then return end
    wp:Add(LerpVector(timefrac, Vector(), LocalToWorld(Vector(0, 2, -6), Angle(), Vector(), wa)))
    wa:RotateAroundAxis(wa:Forward(), Lerp(timefrac, 0, -45))
end)
