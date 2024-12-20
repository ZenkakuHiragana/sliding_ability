require("greatzenkakuman/predicted")
local predicted = greatzenkakuman.predicted

local IsValid = IsValid
local CurTime = CurTime
local Vector = Vector
local Angle = Angle
local isSingleplayer = game.SinglePlayer()

local vecBase = Vector(0, 0, 0)
local vecMWOffset = Vector(-3, 0, -55)
local vecOffset = Vector(12, 0, -46)

local angBase = Angle(0, 0, 0)
local angThigh = Angle(20, 35, 85)
local angCalf = Angle(0, 45, 0)
local angViewpunch = Angle(-0.5, 0, -0.5)

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

local cf = { FCVAR_REPLICATED, FCVAR_ARCHIVE } -- CVarFlags
local CVarAccel = CreateConVar("sliding_ability_acceleration", 250, cf,
"The acceleration/deceleration of the sliding. Larger value makes shorter sliding.", 0)
local CVarCooldown = CreateConVar("sliding_ability_cooldown", 0.3, cf,
"Cooldown time to be able to slide again in seconds.", 0)
local CVarCooldownJump = CreateConVar("sliding_ability_cooldown_jump", 0.6, cf,
"Cooldown time to be able to slide again when you jump while sliding, in seconds.", 0)
local CVarMaxSpeed = CreateConVar("sliding_ability_max_speed", 2500, cf,
"The maximum speed that you can move at while sliding.", 0)
local CVarSpeedThreshold = CreateConVar("sliding_ability_threshold", -1, cf,
"Required speed to be able to slide, set to -1 for automatic", -1)
local SLIDING_ABILITY_BLACKLIST = {
    climb_swep2 = true,
    parkourmod = true,
}
local SLIDE_ANIM_TRANSITION_TIME = 0.2
local SLIDE_TILT_DEG = 42
local IN_MOVE = bit.bor(IN_FORWARD, IN_BACK, IN_MOVELEFT, IN_MOVERIGHT)
local ACT_HL2MP_SIT_CAMERA  = "sit_camera"
local ACT_HL2MP_SIT_DUEL    = "sit_duel"
local ACT_HL2MP_SIT_PASSIVE = "sit_passive"
local acts = {
    revolver = ACT_HL2MP_SIT_PISTOL,
    pistol   = ACT_HL2MP_SIT_PISTOL,
    shotgun  = ACT_HL2MP_SIT_SHOTGUN,
    smg      = ACT_HL2MP_SIT_SMG1,
    ar2      = ACT_HL2MP_SIT_AR2,
    physgun  = ACT_HL2MP_SIT_PHYSGUN,
    grenade  = ACT_HL2MP_SIT_GRENADE,
    rpg      = ACT_HL2MP_SIT_RPG,
    crossbow = ACT_HL2MP_SIT_CROSSBOW,
    melee    = ACT_HL2MP_SIT_MELEE,
    melee2   = ACT_HL2MP_SIT_MELEE2,
    slam     = ACT_HL2MP_SIT_SLAM,
    fist     = ACT_HL2MP_SIT_FIST,
    normal   = ACT_HL2MP_SIT,
    camera   = ACT_HL2MP_SIT_CAMERA,
    duel     = ACT_HL2MP_SIT_DUEL,
    passive  = ACT_HL2MP_SIT_PASSIVE,
    magic    = ACT_HL2MP_SIT_DUEL,
    knife    = ACT_HL2MP_SIT_KNIFE,
}

local function AngleEqualTol(a1, a2, tol)
    tol = tol or 1e-3
    if not (isangle(a1) and isangle(a2)) then return false end
    if math.abs(a1.pitch - a2.pitch) > tol then return false end
    if math.abs(a1.yaw   - a2.yaw)   > tol then return false end
    if math.abs(a1.roll  - a2.roll)  > tol then return false end
    return true
end

local function GetSlidingActivity(ply)
    local w, a = ply:GetActiveWeapon(), ACT_HL2MP_SIT_DUEL
    if IsValid(w) then
        a = acts[string.lower(w:GetHoldType())]
         or acts[string.lower(w.HoldType or "")]
         or ACT_HL2MP_SIT_DUEL
    end
    if isstring(a) then
        return ply:GetSequenceActivity(ply:LookupSequence(a))
    end
    return a
end

local BoneAngleCache = SERVER and {} or nil
local function ManipulateBoneAnglesLessTraffic(ent, bone, ang, frac)
    local a = (not isSingleplayer and SERVER) and ang or ang * frac
    if (isSingleplayer or CLIENT) or not (BoneAngleCache[ent] and AngleEqualTol(BoneAngleCache[ent][bone], a, 1)) then
        ent:ManipulateBoneAngles(bone, a, isSingleplayer)
        if CLIENT then return end
        BoneAngleCache[ent] = BoneAngleCache[ent] or {}
        BoneAngleCache[ent][bone] = a
        if isSingleplayer then return end
        net.Start("SlidingAbility_BroadcastBoneManipulation")
        net.WriteEntity(ent)
        net.WriteUInt(bone, 8)
        net.WriteAngle(a)
        if ent:IsPlayer() then
            net.SendOmit(ent)
        else
            net.Broadcast()
        end
    end
end

local function ManipulateBones(ply, ent, base, thigh, calf)
    if not IsValid(ent) then return end
    local bthigh = ent:LookupBone("ValveBiped.Bip01_R_Thigh")
    local bcalf = ent:LookupBone("ValveBiped.Bip01_R_Calf")
    local t0 = predicted.Get(ply, "SlidingAbility", "SlidingStartTime", 0)
    local ping = (isSingleplayer or SERVER) and 0 or LocalPlayer():Ping() / 1000
    local timefrac = math.TimeFraction(t0 - ping, t0 - ping + SLIDE_ANIM_TRANSITION_TIME, CurTime())
    timefrac = (not isSingleplayer and SERVER) and 1 or math.Clamp(timefrac, 0, 1)
    if bthigh or bcalf then ManipulateBoneAnglesLessTraffic(ent, 0, base, timefrac) end
    if bthigh then ManipulateBoneAnglesLessTraffic(ent, bthigh, thigh, timefrac) end
    if bcalf then ManipulateBoneAnglesLessTraffic(ent, bcalf, calf, timefrac) end

    if not (EnhancedCamera and ent == EnhancedCamera.entity) then return end
    local dp = vecBase
    local w = ply:GetActiveWeapon()
    if not thigh:IsZero() then
        if IsValid(w) and string.find(w.Base or "", "mg_base") and string.lower(w.HoldType or "") ~= "pistol" then
            dp = ply:GetCurrentViewOffset() + vecMWOffset
        else
            dp = ply:GetCurrentViewOffset() + vecOffset
        end
    end

    local seqname = LocalPlayer():GetSequenceName(EnhancedCamera:GetSequence())
    local pose = IsValid(w) and string.lower(w.HoldType or "") or ""
    if pose == "" then pose = seqname:sub((seqname:find "_" or 0) + 1) end
    if pose:find("all") then pose = "normal" end
    if pose == "smg1" then pose = "smg" end
    if pose and pose ~= "" and pose ~= EnhancedCamera.pose then
        EnhancedCamera.pose = pose
        EnhancedCamera:OnPoseChange()
    end

    ent:ManipulateBonePosition(0, dp * timefrac)
end

local function SetSlidingPose(ply, ent, body_tilt)
    ManipulateBones(ply, ent, -Angle(0, 0, body_tilt), angThigh, angCalf)
end

local function IsSliding(ply)
    if predicted.Get(ply, "SlidingAbility", "IsSliding") then return true end
    if CLIENT and LocalPlayer() == ply then return false end
    return ply:GetNWBool("SlidingAbilityIsSliding", false)
end

local kaitCvar = false

local function CheckCrouching(ply)
    -- Compatibility issue with Movement - Reworked partially fixes by disabling crouch check
    if kaitCvar then return true end

    -- GetConVar returns nil on failure so this won't run twice
    if kaitCvar == false then kaitCvar = GetConVar("kait_movement_enabled") end
    return ply:Crouching()
end

local savavCvar = GetConVar("savav_parkour_Enable")
local exosuitCvar = GetConVar("sv_sliding_enabled")

hook.Add("SetupMove", "SlidingAbility_CheckSliding", function(ply, mv)
    if not CheckCrouching(ply) then return end
    local w = ply:GetActiveWeapon()
    if IsValid(w) and SLIDING_ABILITY_BLACKLIST[w:GetClass()] then return end
    if savavCvar and savavCvar:GetBool() then return end
    if exosuitCvar and exosuitCvar:GetBool() and ply.HasExosuit ~= false then return end

    predicted.Process("SlidingAbility", function(pr)
        -- Actual calculation of movement
        if pr.Get("IsSliding") then
            -- Calculate movement
            local velocity = pr.Get("SlidingCurrentVelocity", vecBase)
            local speed = velocity:Length()
            local speedref_crouch = ply:GetWalkSpeed() * ply:GetCrouchedWalkSpeed()

            local vdir = velocity:GetNormalized()
            local forward = mv:GetMoveAngles():Forward()
            local speedref_slide = pr.Get("SlidingMaxSpeed")
            local speedref_min = math.min(speedref_crouch, speedref_slide)
            local speedref_max = math.max(speedref_crouch, speedref_slide)
            local dp = mv:GetOrigin() - pr.Get("SlidingPreviousPosition", mv:GetOrigin())
            local dp2d = Vector(dp.x, dp.y)
            dp:Normalize()
            dp2d:Normalize()
            local dot = forward:Dot(dp2d)
            local speedref = Lerp(math.max(-dp.z, 0), speedref_min, speedref_max)
            local accel_cvar = CVarAccel:GetFloat()
            local accel = accel_cvar * engine.TickInterval()
            if speed > speedref then accel = -accel end
            local maxspeed_cvar = CVarMaxSpeed:GetInt()
            velocity = LerpVector(0.005, vdir, forward) * math.Clamp(speed + accel, -maxspeed_cvar, maxspeed_cvar)

            SetSlidingPose(ply, ply, math.deg(math.asin(dp.z)) * dot + SLIDE_TILT_DEG)
            pr.Set("SlidingCurrentVelocity", velocity)
            pr.Set("SlidingPreviousPosition", mv:GetOrigin())

            local cooldown = CVarCooldown:GetFloat()
            if mv:KeyPressed(IN_JUMP) or not ply:OnGround() then
                cooldown = CVarCooldownJump:GetFloat()
                velocity.z = ply:GetJumpPower()
            end

            mv:SetVelocity(velocity)
            if mv:KeyReleased(IN_DUCK) or not ply:OnGround() or math.abs(speed - speedref_crouch) < 10 then
                if SERVER then ply:SetNWBool("SlidingAbilityIsSliding", false) end
                pr.Set("IsSliding", false)
                pr.Set("SlidingCooldown", cooldown)
                pr.Set("SlidingEndTime", CurTime())
                pr.StopSound(ply, "SlidingAbility.ScrapeRough")
                ManipulateBones(ply, ply, angBase, angBase, angBase)
            end

            local e = EffectData()
            e:SetOrigin(mv:GetOrigin())
            e:SetScale(1.6)
            pr.Effect("WheelDust", e)

            return
        end

        -- Initial check to see if we can do it
        if not ply:OnGround() then return end
        if not mv:KeyDown(IN_DUCK) then return end
        -- if not mv:KeyDown(IN_SPEED) then return end -- This disables sliding for some people for some reason
        if not mv:KeyDown(IN_MOVE) then return end
        if CurTime() < pr.Get("SlidingEndTime", CurTime()) + pr.Get("SlidingCooldown", 0) then return end
        if math.abs(ply:GetWalkSpeed() - ply:GetRunSpeed()) < 25 then return end

        local mvvelocity = mv:GetVelocity()
        local mvlength = mvvelocity:Length()
        local run = ply:GetRunSpeed()
        local crouched = ply:GetWalkSpeed() * ply:GetCrouchedWalkSpeed()
        local threshold = CVarSpeedThreshold:GetInt()
        if threshold < 0 then
            threshold = (run + crouched) / 2
        end
        if run > crouched and mvlength < threshold then return end
        if run < crouched and (mvlength < run - 1 or mvlength > threshold) then return end
        local runspeed = math.max(ply:GetVelocity():Length(), mvlength, run) * 1.5
        local dir = mvvelocity:GetNormalized()
        if SERVER then ply:SetNWBool("SlidingAbilityIsSliding", true) end
        pr.Set("IsSliding", true)
        pr.Set("SlidingStartTime", CurTime())
        pr.Set("SlidingCurrentVelocity", dir * runspeed)
        pr.Set("SlidingMaxSpeed", runspeed * 5)
        pr.EmitSound(ply:GetPos(), "SlidingAbility.ImpactSoft")
        pr.EmitSound(ply, "SlidingAbility.ScrapeRough")

        if tobool(ply:GetInfoNum("sliding_ability_viewpunch", 0)) then
            ply:ViewPunch(angViewpunch)
        end
    end)
end)

local function SlidingFootstep(ply)
    return IsSliding(ply) or nil
end

if DSteps then
    local fsname = "zzzzzz_dstep_main"
    local esname = "zzzzz_dsteps_maskfootstep"
    local hooks = hook.GetTable()
    local DStepsHook = hooks.PlayerFootstep[fsname]
    local EmitSoundHook = hooks.EntityEmitSound[esname]
    if DStepsHook then
        hook.Add("PlayerFootstep", fsname, function(...)
            if SlidingFootstep(...) then return true end
            return DStepsHook(...)
        end)
    end
    if EmitSoundHook then
        hook.Add("EntityEmitSound", esname, function(data, ...)
            local ply = data.Entity
            if not (IsValid(ply) and ply:IsPlayer()) then
                return EmitSoundHook(data, ...)
            end

            if IsSliding(ply) then
                return
            end

            return EmitSoundHook(data, ...)
        end)
    end
else
    hook.Add("PlayerFootstep", "SlidingAbility_SlidingSound", SlidingFootstep)
end

local function AddonCompat()
    local hooks = hook.GetTable()
    if not hooks or not istable(hooks) then return end

    -- Alternate Running Animation (Workshop ID: 1104562150)
    local calcMainActivity = hooks.CalcMainActivity
    if calcMainActivity and istable(calcMainActivity) and calcMainActivity.BaseAnimations and isfunction(calcMainActivity.BaseAnimations) then
        local orig = calcMainActivity.BaseAnimations

        hook.Add("CalcMainActivity", "BaseAnimations", function(ply, ...)
            if not IsValid(ply) then return end
            if IsSliding(ply) then return end
            return orig(ply, ...)
        end)
    end

    -- IK Foot (Workshop ID: 1605334558)
    local postPlayerDraw = hooks.PostPlayerDraw
    if postPlayerDraw and istable(postPlayerDraw) and postPlayerDraw.IKFoot_PostPlayerDraw and isfunction(postPlayerDraw.IKFoot_PostPlayerDraw) then
        local orig = postPlayerDraw.IKFoot_PostPlayerDraw

        hook.Add("PostPlayerDraw", "IKFoot_PostPlayerDraw", function(ply, ...)
            if not IsValid(ply) then return end
            if IsSliding(ply) then return end
            return orig(ply, ...)
        end)
    end
end
hook.Add("Initialize", "SlidingAbility_Compatibility", AddonCompat)

hook.Add("CalcMainActivity", "SlidingAbility_SlidingAnimation", function(ply)
    if not IsSliding(ply) then return end
    if GetSlidingActivity(ply) == -1 then return end
    return GetSlidingActivity(ply), -1
end)

local function DoSomethingWithLegs(ply, doSomething, ...)
    for _, addon in ipairs { "g_LegsVer", "EnhancedCamera", "EnhancedCameraTwo", "CLegs" } do
        local leg = nil
        if not _G[addon] then continue end
        if addon == "g_LegsVer" or addon == "CLegs" then
            leg = GetPlayerLegs()
        else
            leg = _G[addon].entity
        end
        if not IsValid(leg) then continue end
        doSomething(ply, leg, ...)
    end
end

-- Workaround!!!  Revive Mod disables the sliding animation so we disable it
local ReviveModUpdateAnimation
hook.Add("InitPostEntity", "SlidingAbility_ReviveModCompatibility", function()
    ReviveModUpdateAnimation = hook.GetTable().UpdateAnimation.BleedOutAnims
    if ReviveModUpdateAnimation then hook.Remove("UpdateAnimation", "BleedOutAnims") end
end)

hook.Add("UpdateAnimation", "SlidingAbility_SlidingAimPoseParameters", function(ply, velocity, maxSeqGroundSpeed)
    if ReviveModUpdateAnimation and ply:IsBleedOut() then
        ReviveModUpdateAnimation(ply, velocity, maxSeqGroundSpeed)

        return
    end

    if not IsSliding(ply) then
        if ply.SlidingAbility_SlidingReset then
            ply.SlidingAbility_SlidingReset = nil
            DoSomethingWithLegs(ply, ManipulateBones, angBase, angBase, angBase)
        end

        return
    end

    local pppitch = ply:LookupPoseParameter("aim_pitch")
    local ppyaw = ply:LookupPoseParameter("aim_yaw")
    if pppitch >= 0 and ppyaw >= 0 then
        local b = ply:GetManipulateBoneAngles(0).roll
        local p = ply:GetPoseParameter("aim_pitch") -- degrees in server, 0-1 in client
        local y = ply:GetPoseParameter("aim_yaw")
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

    if ply ~= LocalPlayer() then return end
    ply.SlidingAbility_SlidingReset = true
    DoSomethingWithLegs(ply, function(p, l, ...)
        local dp = ply:GetPos() - (l.SlidingAbility_SlidingPreviousPosition or ply:GetPos())
        local dp2d = Vector(dp.x, dp.y)
        dp:Normalize()
        dp2d:Normalize()
        local dot = ply:GetForward():Dot(dp2d)
        local angle = math.deg(math.asin(dp.z)) * dot + SLIDE_TILT_DEG
        l.SlidingAbility_SlidingPreviousPosition = ply:GetPos()
        SetSlidingPose(p, l, angle)
    end)
end)

if SERVER then
    util.AddNetworkString("SlidingAbility_BroadcastBoneManipulation")

    local vecInitSpawn = Vector(1, 1, 1)

    hook.Add("PlayerInitialSpawn", "SlidingAbility_PreventBreakingTPSModelOnChangelevel", function(ply, transition)
        if not transition then return end
        timer.Simple(1, function()
            for i = 0, ply:GetBoneCount() - 1 do
                ply:ManipulateBoneScale(i, vecInitSpawn)
                ply:ManipulateBoneAngles(i, angBase)
                ply:ManipulateBonePosition(i, vecBase)
            end
        end)
    end)

    return
end

net.Receive("SlidingAbility_BroadcastBoneManipulation", function()
    local ply = net.ReadEntity()
    if not IsValid(ply) or LocalPlayer() == ply then return end
    local bone = net.ReadUInt(8)
    local ang = net.ReadAngle()
    ply:ManipulateBoneAngles(bone, ang, false)
end)

CreateClientConVar("sliding_ability_viewpunch", 1, true, true, "Enables a slight viewpunch roll when entering a slide.", 0, 1)
local clTiltVM = CreateClientConVar("sliding_ability_tilt_viewmodel", 1, true, true, "Enable viewmodel tilt like Apex Legends when sliding.")
local vecViewModel = Vector(0, 2, -6)

hook.Add("CalcViewModelView", "SlidingAbility_SlidingViewModelTilt", function(w, vm, op, oa, p, a)
    local wTbl = w:GetTable()
    if wTbl.SuppressSlidingViewModelTilt then return end -- For the future addons which are compatible with this addon
    if string.find(wTbl.Base or "", "mg_base") and isfunction(wTbl.GetToggleAim) and w:GetToggleAim() then return end
    if wTbl.ArcCW and w:GetState() == ArcCW.STATE_SIGHTS then return end

    local ply = w:GetOwner()
    if not (IsValid(ply) and ply:IsPlayer()) then return end
    if not clTiltVM:GetBool() then return end
    if wTbl.IsTFAWeapon and w:GetIronSights() then return end

    local wp, wa = p, a
    if isfunction(wTbl.CalcViewModelView) then wp, wa = w:CalcViewModelView(vm, op, oa, p, a) end
    if not (wp and wa) then wp, wa = p, a end

    local isSliding = IsSliding(ply)
    local slidingStartTime = predicted.Get(ply, "SlidingAbility", "SlidingStartTime", 0)
    local slidingEndTime = predicted.Get(ply, "SlidingAbility", "SlidingEndTime", 0)
    local t0 = isSliding and slidingStartTime or slidingEndTime
    if not IsFirstTimePredicted() then t0 = t0 - ply:Ping() / 1000 end
    local timeFraction = math.Clamp(math.TimeFraction(t0, t0 + SLIDE_ANIM_TRANSITION_TIME, CurTime()), 0, 1)
    if not isSliding then
        local maxFraction = math.Clamp((slidingEndTime - slidingStartTime) / SLIDE_ANIM_TRANSITION_TIME, 0, 1)
        timeFraction = math.Clamp(maxFraction - timeFraction, 0, 1)
    end
    if timeFraction == 0 then return end
    wp:Add(LerpVector(timeFraction, vecBase, LocalToWorld(vecViewModel, angBase, vecBase, wa)))
    wa:RotateAroundAxis(wa:Forward(), Lerp(timeFraction, 0, -45))
end)
