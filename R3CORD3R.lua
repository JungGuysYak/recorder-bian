--[[
    RECORDER BIANN v12.0
    MOD: Hasil kompres disimpan ke folder "Compressed" di dalam folder records.
]]

repeat task.wait() until game:IsLoaded()

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local LP = Players.LocalPlayer

local VERSION = "12.0"
local DATA_FOLDER = "RecorderBiannRecords"
local RECORDS_FOLDER = DATA_FOLDER .. "/records"
local COMPRESSED_FOLDER = RECORDS_FOLDER .. "/Compressed"  -- folder untuk hasil kompres
local MIN_FRAMES = 5
local WALK_VEL_THRESHOLD = 0.2

local MAX_VELOCITY_CLAMP = 50
local SMOOTHING_FACTOR = 0.85

if not isfolder(DATA_FOLDER) then makefolder(DATA_FOLDER) end
if not isfolder(RECORDS_FOLDER) then makefolder(RECORDS_FOLDER) end
if not isfolder(COMPRESSED_FOLDER) then makefolder(COMPRESSED_FOLDER) end

-- ==================== STATE ====================
local isRecording = false
local recordedFrames = {}
local recordStartTime = 0
local recordHB = nil
local pendingFrames = nil
local isSaving = false

local isWalking = false
local walkPaused = false
local walkLoop = false
local walkSpeed = 1.0
local walkIndex = 1
local walkHB = nil

local playbackTime = 0
local lastHeartbeatTick = 0

local currentWalk = nil
local savedRecords = {}
local selectedRecord = nil
local notifLabel = nil

local originalWalkSpeed = 16

local updatePlaybackUI = function() end
local renderList = function() end

local lastStopCFrame = nil
local lastStopWalkName = nil

-- ==================== GROUND DETECTION ====================
local function getGroundLevel(pos)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Blacklist
    params.FilterDescendantsInstances = {LP.Character}
    local origin = Vector3.new(pos.X, pos.Y + 5, pos.Z)
    local direction = Vector3.new(0, -15, 0)
    local result = Workspace:Raycast(origin, direction, params)
    if result then return result.Position.Y end
    return pos.Y - 3
end

-- ==================== SAFE YAW ====================
local function getYaw(cf)
    local success, yaw = pcall(function() return cf:Yaw() end)
    if success then return yaw end
    return math.atan2(cf.LookVector.X, cf.LookVector.Z)
end

-- ==================== HELPERS ====================
local function getHRP()
    local c = LP.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function getHum()
    local c = LP.Character
    return c and c:FindFirstChild("Humanoid")
end

LP.CharacterAdded:Connect(function(char)
    task.wait(0.5)
    local hum = char:FindFirstChild("Humanoid")
    if hum then
        hum.AutoRotate = true
        hum.JumpPower = 50
        hum.WalkSpeed = 16
    end
    if isWalking then
        isWalking = false
        walkPaused = false
        if walkHB then walkHB:Disconnect(); walkHB = nil end
        updatePlaybackUI(false)
    end
end)

-- ==================== NOTIF ====================
local function notif(msg, color, duration)
    print("[Recorder]", msg)
    if not notifLabel then return end
    notifLabel.Text = msg
    notifLabel.TextColor3 = color or Color3.fromRGB(255, 255, 255)
    notifLabel.TextTransparency = 0
    notifLabel.BackgroundTransparency = 0
    notifLabel.Visible = true
    task.delay(duration or 3.5, function()
        if not notifLabel then return end
        TweenService:Create(notifLabel, TweenInfo.new(0.4), {
            BackgroundTransparency = 1,
            TextTransparency = 1,
        }):Play()
        task.wait(0.45)
        notifLabel.Visible = false
        notifLabel.BackgroundTransparency = 0
        notifLabel.TextTransparency = 0
    end)
end

-- ==================== REKAM ====================
local function getNextCheckpointNum()
    local max = 0
    if isfolder(RECORDS_FOLDER) then
        for _, file in ipairs(listfiles(RECORDS_FOLDER)) do
            local n = file:match("Checkpoint_(%d+)%.json$")
            if n then
                local num = tonumber(n)
                if num and num > max then max = num end
            end
        end
    end
    return max + 1
end

local function startRecording()
    if isWalking then
        notif("❌ Hentikan playback dulu", Color3.fromRGB(255,100,100))
        return
    end
    if isRecording then
        if recordHB then recordHB:Disconnect(); recordHB = nil end
        isRecording = false
    end
    pendingFrames = nil
    recordedFrames = {}
    recordStartTime = tick()
    isRecording = true

    local lastRecTick = tick()
    notif("🔴 Merekam...", Color3.fromRGB(255,80,80))
    print("[Recorder] Recording started")

    if recordHB then recordHB:Disconnect() end
    recordHB = RunService.Heartbeat:Connect(function()
        if not isRecording then
            recordHB:Disconnect()
            recordHB = nil
            return
        end
        local now = tick()
        if now - lastRecTick < 1/60 then return end
        lastRecTick = now

        local hrp = getHRP()
        local hum = getHum()
        if not hrp then return end

        local pos = hrp.Position
        local cf = hrp.CFrame
        local vel = hrp.AssemblyLinearVelocity
        local groundY = getGroundLevel(pos)

        local rotY = getYaw(cf)
        local moveDir = Vector3.new(vel.X, 0, vel.Z).Unit
        if moveDir.Magnitude < 0.01 then moveDir = Vector3.new(0,0,0) end

        local state = hum and hum:GetState() or Enum.HumanoidStateType.Running
        local stateStr = tostring(state):gsub("Enum.HumanoidStateType.", "")
        local isJumping = (state == Enum.HumanoidStateType.Jumping or state == Enum.HumanoidStateType.Freefall)

        table.insert(recordedFrames, {
            position = { x = pos.X, y = pos.Y, z = pos.Z },
            velocity = { x = vel.X, y = vel.Y, z = vel.Z },
            rotation = rotY,
            moveDirection = { x = moveDir.X, y = 0, z = moveDir.Z },
            state = stateStr,
            walkSpeed = hum and hum.WalkSpeed or 16,
            hipHeight = hum and hum.HipHeight or 0,
            jumping = isJumping,
            time = now - recordStartTime,
            groundLevel = groundY,
            cf_right = { x = cf.RightVector.X, y = cf.RightVector.Y, z = cf.RightVector.Z },
            cf_up = { x = cf.UpVector.X, y = cf.UpVector.Y, z = cf.UpVector.Z },
        })
    end)
end

local function stopRecording()
    if not isRecording then
        notif("❌ Tidak sedang merekam", Color3.fromRGB(255,100,100))
        return
    end
    isRecording = false
    if recordHB then recordHB:Disconnect(); recordHB = nil end
    local hum = getHum()
    if hum then hum.AutoRotate = true end

    print("[Recorder] Recording stopped. Total frames:", #recordedFrames)

    if #recordedFrames < MIN_FRAMES then
        notif(string.format("❌ Rekaman terlalu pendek (%d frame)", #recordedFrames), Color3.fromRGB(255,100,100))
        recordedFrames = {}
        pendingFrames = nil
        return
    end

    local startIdx = 1
    for i = 1, #recordedFrames do
        local f = recordedFrames[i]
        local speed = math.sqrt(f.velocity.x^2 + f.velocity.z^2)
        if speed >= WALK_VEL_THRESHOLD then
            startIdx = i
            break
        end
    end

    local trimmed = {}
    if startIdx > 1 and startIdx <= #recordedFrames then
        local timeOffset = recordedFrames[startIdx].time
        for i = startIdx, #recordedFrames do
            local f = recordedFrames[i]
            local newFrame = {}
            for k,v in pairs(f) do newFrame[k] = v end
            newFrame.time = f.time - timeOffset
            table.insert(trimmed, newFrame)
        end
    else
        trimmed = recordedFrames
    end

    if #trimmed < MIN_FRAMES then
        notif("❌ Rekaman terlalu pendek setelah trim", Color3.fromRGB(255,100,100))
        recordedFrames = {}
        pendingFrames = nil
        return
    end

    pendingFrames = trimmed
    recordedFrames = {}
    notif(string.format("⏹ %d frame (%.1fs) — siap save", #pendingFrames, pendingFrames[#pendingFrames].time),
          Color3.fromRGB(255,200,50))
    print("[Recorder] Ready to save, frames:", #pendingFrames)
end

local function saveRecording()
    if isSaving then
        notif("⚠️ Sedang menyimpan...", Color3.fromRGB(255,200,50))
        return nil
    end
    if not pendingFrames or #pendingFrames == 0 then
        notif("❌ Tidak ada rekaman", Color3.fromRGB(255,100,100))
        return nil
    end
    isSaving = true
    local num = getNextCheckpointNum()
    local name = "Checkpoint_" .. num
    local fileName = RECORDS_FOLDER .. "/" .. name .. ".json"
    local data = {
        name = name,
        date = os.time(),
        version = VERSION,
        frames = pendingFrames,
        totalFrames = #pendingFrames,
        duration = pendingFrames[#pendingFrames].time,
    }
    local ok, err = pcall(function()
        writefile(fileName, HttpService:JSONEncode(data))
    end)
    if ok then
        notif(string.format("💾 %s (%d frame)", name, #pendingFrames), Color3.fromRGB(100,255,150))
        pendingFrames = nil
        isSaving = false
        return name
    else
        notif("❌ Gagal: "..tostring(err), Color3.fromRGB(255,100,100))
        isSaving = false
        return nil
    end
end

-- ==================== LOAD & DELETE ====================
local function getRecordFilePath(name)
    -- Cari di folder utama dulu, jika tidak ada cari di compressed
    local mainFile = RECORDS_FOLDER .. "/" .. name .. ".json"
    if isfile(mainFile) then return mainFile end
    local compFile = COMPRESSED_FOLDER .. "/" .. name .. ".json"
    if isfile(compFile) then return compFile end
    return nil
end

local function loadRecord(name)
    local filePath = getRecordFilePath(name)
    if not filePath then return false end
    local ok, data = pcall(function() return HttpService:JSONDecode(readfile(filePath)) end)
    if not ok then return false end
    currentWalk = data
    notif(string.format("📂 %s (%d frame)", name, data.totalFrames or 0), Color3.fromRGB(100,180,255))
    return true
end

local function deleteRecord(name)
    local filePath = getRecordFilePath(name)
    if not filePath then return false end
    delfile(filePath)
    if currentWalk and currentWalk.name == name then currentWalk = nil end
    notif("🗑️ Dihapus: "..name, Color3.fromRGB(255,160,60))
    return true
end

local function sortRecords(list)
    table.sort(list, function(a,b)
        local na = tonumber(a:match("Checkpoint_(%d+)$"))
        local nb = tonumber(b:match("Checkpoint_(%d+)$"))
        if na and nb then return na < nb end
        if na then return true end
        if nb then return false end
        return a < b
    end)
end

local function refreshRecords()
    savedRecords = {}
    -- baca dari folder utama
    if isfolder(RECORDS_FOLDER) then
        for _, file in ipairs(listfiles(RECORDS_FOLDER)) do
            if file:find("%.json$") then
                local name = file:match("([^/\\]+)%.json$")
                if name then table.insert(savedRecords, name) end
            end
        end
    end
    -- baca dari folder compressed
    if isfolder(COMPRESSED_FOLDER) then
        for _, file in ipairs(listfiles(COMPRESSED_FOLDER)) do
            if file:find("%.json$") then
                local name = file:match("([^/\\]+)%.json$")
                if name then table.insert(savedRecords, name) end
            end
        end
    end
    sortRecords(savedRecords)
    print("[Recorder] Records refreshed, count:", #savedRecords)
end

-- ==================== MERGE ====================
local function mergeAllCheckpoints()
    local toMerge = {}
    for _, name in ipairs(savedRecords) do
        if name:match("^Checkpoint_%d+$") then
            -- pastikan file ada di folder utama (bukan compressed) karena merge hanya menggunakan checkpoint asli
            local filePath = RECORDS_FOLDER .. "/" .. name .. ".json"
            if isfile(filePath) then
                table.insert(toMerge, name)
            end
        end
    end
    if #toMerge < 2 then
        notif("❌ Minimal 2 Checkpoint", Color3.fromRGB(255,100,100))
        return
    end

    local cpDataList = {}
    for _, name in ipairs(toMerge) do
        local fileName = RECORDS_FOLDER .. "/" .. name .. ".json"
        if not isfile(fileName) then continue end
        local raw = readfile(fileName)
        if raw == "" then continue end
        local ok, data = pcall(function() return HttpService:JSONDecode(raw) end)
        if not ok or not data or not data.frames or #data.frames < 2 then continue end
        table.insert(cpDataList, { name = name, frames = data.frames })
    end

    if #cpDataList < 2 then
        notif("❌ Minimal 2 CP valid", Color3.fromRGB(255,100,100))
        return
    end

    local allFrames = {}
    local currentTime = 0

    for cpIdx, cpData in ipairs(cpDataList) do
        local frames = cpData.frames
        local nFrames = #frames

        local startIdx = 1
        local endIdx = nFrames
        for i = 1, nFrames do
            local speed = math.sqrt(frames[i].velocity.x^2 + frames[i].velocity.z^2)
            if speed >= WALK_VEL_THRESHOLD then
                startIdx = i
                break
            end
        end
        for i = nFrames, 1, -1 do
            local speed = math.sqrt(frames[i].velocity.x^2 + frames[i].velocity.z^2)
            if speed >= WALK_VEL_THRESHOLD then
                endIdx = i
                break
            end
        end
        if startIdx > endIdx then
            startIdx = 1
            endIdx = nFrames
        end

        local movingFrames = {}
        for i = startIdx, endIdx do
            table.insert(movingFrames, frames[i])
        end

        if cpIdx == 1 then
            local firstTime = movingFrames[1].time
            for _, f in ipairs(movingFrames) do
                local newFrame = {}
                for k,v in pairs(f) do newFrame[k] = v end
                newFrame.time = f.time - firstTime
                table.insert(allFrames, newFrame)
            end
            currentTime = allFrames[#allFrames].time
        else
            local firstTime = movingFrames[1].time
            for _, f in ipairs(movingFrames) do
                local newFrame = {}
                for k,v in pairs(f) do newFrame[k] = v end
                newFrame.time = currentTime + (f.time - firstTime)
                table.insert(allFrames, newFrame)
            end
            currentTime = allFrames[#allFrames].time
        end
    end

    if #allFrames == 0 then
        notif("❌ Tidak ada frame", Color3.fromRGB(255,100,100))
        return
    end

    for i = 2, #allFrames do
        if allFrames[i].time <= allFrames[i-1].time then
            allFrames[i].time = allFrames[i-1].time + 0.001
        end
    end

    local outName = "MergeAll_" .. os.date("%d%m%y_%H%M%S")
    local outFile = RECORDS_FOLDER .. "/" .. outName .. ".json"
    local outData = {
        name = outName,
        date = os.time(),
        version = VERSION,
        frames = allFrames,
        totalFrames = #allFrames,
        duration = allFrames[#allFrames].time,
    }
    local ok, err = pcall(function()
        writefile(outFile, HttpService:JSONEncode(outData))
    end)
    if ok then
        notif(string.format("🔗 Merge: %d CP, %d frame", #cpDataList, #allFrames), Color3.fromRGB(100,255,150))
        refreshRecords()
        renderList()
    else
        notif("❌ Gagal merge: "..tostring(err), Color3.fromRGB(255,100,100))
    end
end

-- ==================== COMPRESS (HARD LEVEL, ke folder Compressed) ====================
local function compressRecord(name, aggressiveness)
    -- Hanya hard level
    aggressiveness = 3
    local sourcePath = getRecordFilePath(name)
    if not sourcePath then
        notif("❌ File tidak ada: "..name, Color3.fromRGB(255,100,100))
        return false
    end
    local ok, data = pcall(function() return HttpService:JSONDecode(readfile(sourcePath)) end)
    if not ok or not data then
        notif("❌ Gagal baca: "..name, Color3.fromRGB(255,100,100))
        return false
    end
    local frames = data.frames
    local orig = #frames
    if orig < 3 then
        notif("❌ Frame terlalu sedikit", Color3.fromRGB(255,100,100))
        return false
    end

    local totalSpeed = 0
    for i = 1, orig do
        local f = frames[i]
        totalSpeed = totalSpeed + math.sqrt(f.velocity.x^2 + f.velocity.z^2)
    end
    local avgSpeed = totalSpeed / orig

    local baseThresh = 1.2
    local speedFactor = math.clamp(avgSpeed / 10, 0.3, 2.0)
    local posThreshold = baseThresh / speedFactor
    local rotThreshold = 0.2
    local velThreshold = posThreshold * 1.5

    local kept = { frames[1] }
    local last = frames[1]

    for i = 2, orig - 1 do
        local f = frames[i]
        local keep = false

        local dx = f.position.x - last.position.x
        local dy = f.position.y - last.position.y
        local dz = f.position.z - last.position.z
        local posDist = math.sqrt(dx*dx + dy*dy + dz*dz)
        if posDist >= posThreshold then keep = true end

        if not keep then
            local dRot = math.abs(f.rotation - last.rotation)
            if dRot > math.pi then dRot = 2*math.pi - dRot end
            if dRot >= rotThreshold then keep = true end
        end

        if not keep then
            local dvx = f.velocity.x - last.velocity.x
            local dvy = f.velocity.y - last.velocity.y
            local dvz = f.velocity.z - last.velocity.z
            local velDist = math.sqrt(dvx*dvx + dvy*dvy + dvz*dvz)
            if velDist >= velThreshold then keep = true end
        end

        if f.jumping ~= last.jumping then keep = true end

        if keep then
            table.insert(kept, f)
            last = f
        end
    end
    table.insert(kept, frames[orig])

    local outName = name
    if not name:match("_c%d$") then
        outName = name .. "_c3"
    else
        outName = name:gsub("_c%d$", "_c3")
    end
    local outFile = COMPRESSED_FOLDER .. "/" .. outName .. ".json"
    local outData = {
        name = outName,
        date = os.time(),
        version = VERSION,
        frames = kept,
        totalFrames = #kept,
        duration = kept[#kept].time,
        compressed = true,
        originalFrames = orig,
    }
    local ok2, err = pcall(function()
        writefile(outFile, HttpService:JSONEncode(outData))
    end)
    if ok2 then
        local reducePct = math.floor((1 - #kept/orig) * 100)
        notif(string.format("🗜️ -%d%%  %d→%d frame → %s", reducePct, orig, #kept, outName), Color3.fromRGB(100,255,150))
        refreshRecords()
        renderList()
        return true
    else
        notif("❌ Gagal: "..tostring(err), Color3.fromRGB(255,100,100))
        return false
    end
end

local function compressAllMerged()
    local done = 0
    -- Hanya kompres file MergeAll yang ada di folder utama (bukan di compressed)
    for _, name in ipairs(savedRecords) do
        if name:find("^MergeAll") and not name:find("_c%d$") then
            local filePath = RECORDS_FOLDER .. "/" .. name .. ".json"
            if isfile(filePath) then
                if compressRecord(name, 3) then done = done + 1 end
            end
        end
    end
    if done == 0 then
        notif("❌ Tidak ada MergeAll yang belum dikompres", Color3.fromRGB(255,100,100))
    else
        notif(string.format("🗜️ Compress: %d file", done), Color3.fromRGB(100,255,150))
    end
end

-- ==================== TELEPORT ====================
local function teleportToLastStop()
    if not currentWalk then
        notif("❌ Pilih rekaman dulu", Color3.fromRGB(255,100,100))
        return
    end
    local hrp = getHRP()
    local hum = getHum()
    if not hrp or not hum then
        notif("❌ Character tidak siap", Color3.fromRGB(255,100,100))
        return
    end
    if lastStopCFrame and lastStopWalkName == currentWalk.name then
        hrp.CFrame = lastStopCFrame
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
        hum.AutoRotate = true
        hum:ChangeState(Enum.HumanoidStateType.Running)
        notif("📡 Teleport ke posisi terakhir", Color3.fromRGB(100,200,255))
        return
    end
    local frames = currentWalk.frames
    if #frames < 1 then
        notif("❌ Rekaman kosong", Color3.fromRGB(255,100,100))
        return
    end
    local firstFrame = frames[1]
    local recordedGround = firstFrame.groundLevel or (firstFrame.position.y - (firstFrame.hipHeight or 5.33))
    local groundAtTarget = getGroundLevel(Vector3.new(firstFrame.position.x, firstFrame.position.y, firstFrame.position.z))
    local yOffset = groundAtTarget - recordedGround
    hrp.CFrame = CFrame.new(firstFrame.position.x, firstFrame.position.y + yOffset, firstFrame.position.z)
    hrp.AssemblyLinearVelocity = Vector3.zero
    hrp.AssemblyAngularVelocity = Vector3.zero
    hum.AutoRotate = true
    hum:ChangeState(Enum.HumanoidStateType.Running)
    notif("📡 Teleport ke awal rekaman", Color3.fromRGB(100,200,255))
end

-- ==================== PLAYBACK ====================
-- (fungsi playback tidak berubah, hanya perlu menggunakan currentWalk yang sudah di-load)
local function binarySearch(frames, time, lo, hi)
    lo = math.max(1, lo)
    hi = math.min(#frames, hi)
    for i = lo, math.min(lo+5, hi) do
        if frames[i].time <= time and (i == hi or frames[i+1].time > time) then
            return i
        end
    end
    while lo < hi do
        local mid = math.floor((lo+hi+1)/2)
        if frames[mid].time <= time then lo = mid else hi = mid-1 end
    end
    return lo
end

local function smoothstep(t)
    t = math.clamp(t,0,1)
    return t*t*(3-2*t)
end

local function stopWalking()
    isWalking = false
    walkPaused = false
    walkIndex = 1

    if walkHB then walkHB:Disconnect(); walkHB = nil end

    local hrp = getHRP()
    local hum = getHum()

    if hrp then
        lastStopCFrame = hrp.CFrame
        lastStopWalkName = currentWalk and currentWalk.name or nil
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
    end
    if hum then
        hum.AutoRotate = true
        hum.WalkSpeed = originalWalkSpeed
        hum.JumpPower = 50
        hum:ChangeState(Enum.HumanoidStateType.Running)
    end

    playbackTime = 0
    lastHeartbeatTick = 0

    notif("⏹️ Stop", Color3.fromRGB(220,220,220))
    updatePlaybackUI(false)
end

local function pauseWalking()
    if not isWalking then return end
    walkPaused = not walkPaused
    if not walkPaused then
        lastHeartbeatTick = tick()
    end
    notif(walkPaused and "⏸️ Pause" or "▶️ Resume", Color3.fromRGB(255,180,60))
end

local function startWalking()
    if not currentWalk then
        notif("❌ Pilih rekaman dulu", Color3.fromRGB(255,100,100))
        return
    end
    if isWalking then
        notif("⚠️ Sudah berjalan", Color3.fromRGB(255,180,60))
        return
    end
    if isRecording then
        notif("❌ Hentikan rekaman", Color3.fromRGB(255,100,100))
        return
    end

    local frames = currentWalk.frames
    if #frames < 2 then
        notif("❌ Rekaman terlalu pendek", Color3.fromRGB(255,100,100))
        return
    end

    local hrp = getHRP()
    local hum = getHum()
    if not hrp or not hum then
        notif("❌ Character tidak siap", Color3.fromRGB(255,100,100))
        return
    end

    originalWalkSpeed = hum.WalkSpeed

    local firstFrame = frames[1]
    local recordedGround = firstFrame.groundLevel or (firstFrame.position.y - (firstFrame.hipHeight or 5.33))
    local groundAtTarget = getGroundLevel(Vector3.new(firstFrame.position.x, firstFrame.position.y, firstFrame.position.z))
    local yOffset = groundAtTarget - recordedGround

    hrp.CFrame = CFrame.new(firstFrame.position.x, firstFrame.position.y + yOffset, firstFrame.position.z)
    hrp.AssemblyLinearVelocity = Vector3.zero
    hrp.AssemblyAngularVelocity = Vector3.zero

    hum.AutoRotate = false
    hum.WalkSpeed = originalWalkSpeed
    hum.JumpPower = 50
    hum:ChangeState(Enum.HumanoidStateType.Running)

    task.wait(0.1)

    isWalking = true
    walkPaused = false
    walkIndex = 1

    playbackTime = 0
    lastHeartbeatTick = tick()

    notif("▶️ "..currentWalk.name, Color3.fromRGB(100,255,150))
    updatePlaybackUI(true)

    local lastIdx = 1
    local lastVelocity = Vector3.zero
    local wasJumping = false
    local isJumping = false

    local function doJump()
        if not hum then return end
        hum:ChangeState(Enum.HumanoidStateType.Jumping)
        isJumping = true
        task.delay(0.5, function() isJumping = false end)
    end

    local function doLand()
        if not hum then return end
        hum:ChangeState(Enum.HumanoidStateType.Running)
        isJumping = false
    end

    if walkHB then walkHB:Disconnect() end
    walkHB = RunService.Heartbeat:Connect(function()
        if not isWalking then
            if walkHB then walkHB:Disconnect() end
            walkHB = nil
            return
        end

        local now = tick()

        if walkPaused then
            lastHeartbeatTick = now
            return
        end

        local dt = now - lastHeartbeatTick
        lastHeartbeatTick = now
        dt = math.clamp(dt, 0, 0.1)
        playbackTime = playbackTime + dt * walkSpeed

        local success, err = pcall(function()
            local currentTime = playbackTime
            local totalDur = frames[#frames].time

            if currentTime >= totalDur then
                if walkLoop then
                    playbackTime = 0
                    lastIdx = 1
                    walkIndex = 1
                    local firstF = frames[1]
                    hrp.CFrame = CFrame.new(firstF.position.x, firstF.position.y + yOffset, firstF.position.z)
                    hrp.AssemblyLinearVelocity = Vector3.zero
                    notif("🔁 Loop", Color3.fromRGB(150,220,255), 1)
                else
                    stopWalking()
                    notif("✅ Selesai", Color3.fromRGB(100,255,150))
                end
                return
            end

            local frameIdx = binarySearch(frames, currentTime, lastIdx, #frames-1)
            local nextIdx = math.min(frameIdx+1, #frames)
            lastIdx = frameIdx
            walkIndex = frameIdx

            local f1 = frames[frameIdx]
            local f2 = frames[nextIdx]

            local deltaTime = f2.time - f1.time
            local t = (currentTime - f1.time) / (deltaTime > 0 and deltaTime or 0.001)
            t = math.clamp(t, 0, 1)
            local smoothT = smoothstep(t)

            local posX = f1.position.x + (f2.position.x - f1.position.x) * smoothT
            local posZ = f1.position.z + (f2.position.z - f1.position.z) * smoothT
            local posY = f1.position.y + (f2.position.y - f1.position.y) * smoothT + yOffset

            local rot1 = f1.rotation or 0
            local rot2 = f2.rotation or 0
            local rot = rot1 + (rot2 - rot1) * smoothT
            local newCF = CFrame.new(posX, posY, posZ) * CFrame.Angles(0, rot, 0)

            if f1.cf_right and f2.cf_right then
                local function lerpVector(v1, v2, a)
                    return Vector3.new(v1.x + (v2.x - v1.x)*a,
                                       v1.y + (v2.y - v1.y)*a,
                                       v1.z + (v2.z - v1.z)*a)
                end
                local right = lerpVector(f1.cf_right, f2.cf_right, smoothT)
                local up = lerpVector(f1.cf_up, f2.cf_up, smoothT)
                newCF = CFrame.fromMatrix(Vector3.new(posX, posY, posZ), right, up)
            end

            hrp.CFrame = newCF

            local vel1 = Vector3.new(f1.velocity.x, f1.velocity.y, f1.velocity.z)
            local vel2 = Vector3.new(f2.velocity.x, f2.velocity.y, f2.velocity.z)
            local targetVel = vel1:Lerp(vel2, smoothT)
            local newVel = lastVelocity * SMOOTHING_FACTOR + targetVel * (1 - SMOOTHING_FACTOR)
            if newVel.Magnitude > MAX_VELOCITY_CLAMP then
                newVel = newVel.Unit * MAX_VELOCITY_CLAMP
            end
            hrp.AssemblyLinearVelocity = newVel
            hrp.AssemblyAngularVelocity = Vector3.zero

            local moveDir = Vector3.new(f1.moveDirection.x, 0, f1.moveDirection.z)
            if moveDir.Magnitude > 0.01 then
                hum:Move(moveDir, true)
            else
                hum:Move(Vector3.zero, true)
            end

            local isJumpingNow = f1.jumping
            if isJumpingNow and not wasJumping then
                doJump()
            elseif not isJumpingNow and wasJumping then
                doLand()
            end
            wasJumping = isJumpingNow

            lastVelocity = newVel
        end)
        if not success then
            print("[Recorder] Playback error:", err)
        end
    end)
end

-- ==================== GUI ====================
local function createGUI()
    local old = LP.PlayerGui:FindFirstChild("RecorderBiann")
    if old then old:Destroy() end

    local gui = Instance.new("ScreenGui")
    gui.Name = "RecorderBiann"
    gui.ResetOnSpawn = false
    gui.Parent = LP:WaitForChild("PlayerGui")

    local W, H = 300, 540
    local frame = Instance.new("Frame", gui)
    frame.BackgroundColor3 = Color3.fromRGB(10,10,14)
    frame.BorderSizePixel = 0
    frame.Position = UDim2.new(0.5,-W/2,0.5,-H/2)
    frame.Size = UDim2.new(0,W,0,H)
    frame.Active = true
    frame.Draggable = true
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0,12)

    local fs = Instance.new("UIStroke", frame)
    fs.Color = Color3.fromRGB(0,180,255)
    fs.Thickness = 1.5

    local titleBar = Instance.new("Frame", frame)
    titleBar.BackgroundColor3 = Color3.fromRGB(0,120,180)
    titleBar.BorderSizePixel = 0
    titleBar.Size = UDim2.new(1,0,0,36)
    Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0,12)

    local titleLbl = Instance.new("TextLabel", titleBar)
    titleLbl.BackgroundTransparency = 1
    titleLbl.Position = UDim2.new(0,12,0,0)
    titleLbl.Size = UDim2.new(1,-40,1,0)
    titleLbl.Font = Enum.Font.GothamBold
    titleLbl.Text = "📼 RECORDER BIANN v"..VERSION
    titleLbl.TextColor3 = Color3.fromRGB(255,255,255)
    titleLbl.TextSize = 14
    titleLbl.TextXAlignment = Enum.TextXAlignment.Left

    local closeBtn = Instance.new("TextButton", titleBar)
    closeBtn.BackgroundColor3 = Color3.fromRGB(200,50,50)
    closeBtn.BorderSizePixel = 0
    closeBtn.Position = UDim2.new(1,-32,0,6)
    closeBtn.Size = UDim2.new(0,24,0,24)
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.Text = "✕"
    closeBtn.TextColor3 = Color3.fromRGB(255,255,255)
    closeBtn.TextSize = 12
    Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0,6)
    closeBtn.MouseButton1Click:Connect(function() frame.Visible = false end)

    local function mkBtn(x,y,w,h,text,r,g,b)
        local btn = Instance.new("TextButton", frame)
        btn.BackgroundColor3 = Color3.fromRGB(r,g,b)
        btn.BorderSizePixel = 0
        btn.Position = UDim2.new(0,x,0,y)
        btn.Size = UDim2.new(0,w,0,h)
        btn.Font = Enum.Font.GothamBold
        btn.Text = text
        btn.TextColor3 = Color3.fromRGB(255,255,255)
        btn.TextSize = 12
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0,6)
        return btn
    end

    local function mkDiv(y)
        local d = Instance.new("Frame", frame)
        d.BackgroundColor3 = Color3.fromRGB(25,35,50)
        d.BorderSizePixel = 0
        d.Position = UDim2.new(0,12,0,y)
        d.Size = UDim2.new(1,-24,0,1.5)
    end

    local function mkLbl(y,text)
        local lbl = Instance.new("TextLabel", frame)
        lbl.BackgroundTransparency = 1
        lbl.Position = UDim2.new(0,12,0,y)
        lbl.Size = UDim2.new(1,-24,0,16)
        lbl.Font = Enum.Font.GothamBold
        lbl.Text = text
        lbl.TextColor3 = Color3.fromRGB(0,180,255)
        lbl.TextSize = 10
        lbl.TextXAlignment = Enum.TextXAlignment.Left
    end

    mkLbl(42, "REKAM")
    local recBtn = mkBtn(12,60,132,32,"🔴 REC",170,35,35)
    local stpBtn = mkBtn(152,60,136,32,"⏹ STOP & SAVE",25,130,70)

    local recStatus = Instance.new("TextLabel", frame)
    recStatus.BackgroundTransparency = 1
    recStatus.Position = UDim2.new(0,12,0,96)
    recStatus.Size = UDim2.new(1,-24,0,14)
    recStatus.Font = Enum.Font.Gotham
    recStatus.Text = "Siap"
    recStatus.TextColor3 = Color3.fromRGB(100,120,140)
    recStatus.TextSize = 10
    recStatus.TextXAlignment = Enum.TextXAlignment.Left

    mkDiv(112)

    mkLbl(118, "PLAYBACK")
    local playBtn = mkBtn(12,134,86,30,"▶ PLAY",25,155,85)
    local pauseBtn = mkBtn(104,134,86,30,"⏸ PAUSE",180,120,20)
    local stopBtn2 = mkBtn(196,134,92,30,"⏹ STOP",160,40,40)

    local teleportBtn = mkBtn(12,170,86,26,"📡 TP LAST",90,70,140)
    teleportBtn.TextSize = 11

    local loopBtn = mkBtn(104,170,86,26,"🔁 Loop: OFF",35,35,55)
    loopBtn.TextSize = 11

    local speedMinus = mkBtn(196,170,28,26,"−",35,55,90)
    local speedLbl = Instance.new("TextLabel", frame)
    speedLbl.BackgroundTransparency = 1
    speedLbl.Position = UDim2.new(0,228,0,170)
    speedLbl.Size = UDim2.new(0,48,0,26)
    speedLbl.Font = Enum.Font.GothamBold
    speedLbl.Text = "1.00x"
    speedLbl.TextColor3 = Color3.fromRGB(255,210,40)
    speedLbl.TextSize = 12
    local speedPlus = mkBtn(280,170,28,26,"+",35,55,90)

    mkDiv(202)
    mkLbl(208, "REKAMAN")
    local refreshBtn = mkBtn(208,206,80,20,"🔄",25,50,90)
    refreshBtn.TextSize = 10

    local listFrame = Instance.new("ScrollingFrame", frame)
    listFrame.BackgroundColor3 = Color3.fromRGB(14,14,20)
    listFrame.BorderSizePixel = 0
    listFrame.Position = UDim2.new(0,12,0,228)
    listFrame.Size = UDim2.new(1,-24,0,180)
    listFrame.ScrollBarThickness = 4
    listFrame.ScrollBarImageColor3 = Color3.fromRGB(0,160,230)
    listFrame.CanvasSize = UDim2.new(0,0,0,0)
    listFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
    Instance.new("UICorner", listFrame).CornerRadius = UDim.new(0,6)

    local ll = Instance.new("UIListLayout", listFrame)
    ll.Padding = UDim.new(0,3)
    ll.SortOrder = Enum.SortOrder.LayoutOrder
    local lp2 = Instance.new("UIPadding", listFrame)
    lp2.PaddingTop = UDim.new(0,6)
    lp2.PaddingLeft = UDim.new(0,6)
    lp2.PaddingRight = UDim.new(0,6)

    mkDiv(412)

    local mergeBtn = mkBtn(12,418,100,32,"🔗 Merge",0,100,160)
    local compressBtn = mkBtn(118,418,170,32,"🗜️ Compress (Hard)",140,30,30)

    notifLabel = Instance.new("TextLabel", frame)
    notifLabel.BackgroundColor3 = Color3.fromRGB(0,80,150)
    notifLabel.BorderSizePixel = 0
    notifLabel.Position = UDim2.new(0,12,0,468)
    notifLabel.Size = UDim2.new(1,-24,0,56)
    notifLabel.Font = Enum.Font.Gotham
    notifLabel.Text = ""
    notifLabel.TextColor3 = Color3.fromRGB(255,255,255)
    notifLabel.TextSize = 10
    notifLabel.TextWrapped = true
    notifLabel.Visible = false
    Instance.new("UICorner", notifLabel).CornerRadius = UDim.new(0,6)

    local rowCache = {}

    local function getLayoutOrder(recName)
        for i,n in ipairs(savedRecords) do
            if n == recName then return i end
        end
        return 9999
    end

    local function addEmptyLabel()
        local e = Instance.new("TextLabel", listFrame)
        e.Name = "__empty"
        e.BackgroundTransparency = 1
        e.Size = UDim2.new(1,-12,0,32)
        e.Font = Enum.Font.Gotham
        e.Text = "Belum ada rekaman"
        e.TextColor3 = Color3.fromRGB(70,80,100)
        e.TextSize = 11
    end

    local function addRowToList(recName)
        local isSel = (selectedRecord == recName)
        local row = Instance.new("Frame", listFrame)
        row.Name = "row_"..recName
        row.LayoutOrder = getLayoutOrder(recName)
        row.BackgroundColor3 = isSel and Color3.fromRGB(0,70,120) or Color3.fromRGB(20,20,30)
        row.BorderSizePixel = 0
        row.Size = UDim2.new(1,-12,0,32)
        Instance.new("UICorner", row).CornerRadius = UDim.new(0,6)
        rowCache[recName] = row

        local nb = Instance.new("TextButton", row)
        nb.BackgroundTransparency = 1
        nb.Position = UDim2.new(0,8,0,0)
        nb.Size = UDim2.new(1,-44,1,0)
        nb.Font = isSel and Enum.Font.GothamBold or Enum.Font.Gotham
        nb.Text = (isSel and "▶ " or "  ")..recName
        nb.TextColor3 = isSel and Color3.fromRGB(0,210,255) or Color3.fromRGB(160,175,200)
        nb.TextSize = 11
        nb.TextXAlignment = Enum.TextXAlignment.Left
        nb.TextTruncate = Enum.TextTruncate.AtEnd
        nb.MouseButton1Click:Connect(function()
            if selectedRecord and rowCache[selectedRecord] then
                local oldRow = rowCache[selectedRecord]
                if oldRow and oldRow.Parent then
                    oldRow.BackgroundColor3 = Color3.fromRGB(20,20,30)
                    local oldNb = oldRow:FindFirstChildOfClass("TextButton")
                    if oldNb then
                        oldNb.Font = Enum.Font.Gotham
                        oldNb.Text = "  "..selectedRecord
                        oldNb.TextColor3 = Color3.fromRGB(160,175,200)
                    end
                end
            end
            selectedRecord = recName
            row.BackgroundColor3 = Color3.fromRGB(0,70,120)
            nb.Font = Enum.Font.GothamBold
            nb.Text = "▶ "..recName
            nb.TextColor3 = Color3.fromRGB(0,210,255)
            loadRecord(recName)
        end)

        local db = Instance.new("TextButton", row)
        db.BackgroundColor3 = Color3.fromRGB(120,25,25)
        db.BorderSizePixel = 0
        db.Position = UDim2.new(1,-28,0,4)
        db.Size = UDim2.new(0,22,0,24)
        db.Font = Enum.Font.GothamBold
        db.Text = "🗑"
        db.TextSize = 11
        db.TextColor3 = Color3.fromRGB(255,255,255)
        Instance.new("UICorner", db).CornerRadius = UDim.new(0,4)
        db.MouseButton1Click:Connect(function()
            row:Destroy()
            rowCache[recName] = nil
            if selectedRecord == recName then selectedRecord = nil end

            local hasRows = false
            for _,c in pairs(listFrame:GetChildren()) do
                if c:IsA("Frame") then hasRows = true; break end
            end
            if not hasRows then addEmptyLabel() end

            task.spawn(function()
                deleteRecord(recName)
                for i,n in ipairs(savedRecords) do
                    if n == recName then table.remove(savedRecords,i); break end
                end
            end)
        end)
    end

    renderList = function()
        for _,c in pairs(listFrame:GetChildren()) do
            if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
        end
        rowCache = {}
        if #savedRecords == 0 then addEmptyLabel(); return end
        for _,recName in ipairs(savedRecords) do addRowToList(recName) end
    end

    updatePlaybackUI = function(playing)
        playBtn.BackgroundColor3 = playing and Color3.fromRGB(15,100,55) or Color3.fromRGB(25,155,85)
    end

    task.spawn(function()
        while gui.Parent do
            if isRecording then
                recStatus.Text = string.format("🔴 %d frame  |  %.1fs", #recordedFrames, tick()-recordStartTime)
                recStatus.TextColor3 = Color3.fromRGB(255,90,90)
            elseif isWalking and currentWalk then
                local pct = math.floor(playbackTime / (currentWalk.duration or 1) * 100)
                recStatus.Text = string.format("▶ %.1fs / %.1fs  (%d%%)", playbackTime, currentWalk.duration or 0, pct)
                recStatus.TextColor3 = Color3.fromRGB(80,220,130)
            else
                recStatus.Text = "✅ Siap | F = Toggle GUI"
                recStatus.TextColor3 = Color3.fromRGB(100,120,140)
            end
            task.wait(0.2)
        end
    end)

    recBtn.MouseButton1Click:Connect(function()
        startRecording()
        recBtn.BackgroundColor3 = Color3.fromRGB(220,40,40)
    end)

    stpBtn.MouseButton1Click:Connect(function()
        if not isRecording then return end
        stopRecording()
        recBtn.BackgroundColor3 = Color3.fromRGB(170,35,35)
        task.defer(function()
            local saved = saveRecording()
            if saved then
                refreshRecords()
                renderList()
                print("[Recorder] Record saved and list refreshed:", saved)
            else
                print("[Recorder] Save failed")
            end
        end)
    end)

    playBtn.MouseButton1Click:Connect(startWalking)

    pauseBtn.MouseButton1Click:Connect(function()
        pauseWalking()
        if walkPaused then
            pauseBtn.Text = "▶ RESUME"
            pauseBtn.BackgroundColor3 = Color3.fromRGB(80,150,40)
        else
            pauseBtn.Text = "⏸ PAUSE"
            pauseBtn.BackgroundColor3 = Color3.fromRGB(180,120,20)
        end
    end)

    stopBtn2.MouseButton1Click:Connect(function()
        stopWalking()
        pauseBtn.Text = "⏸ PAUSE"
        pauseBtn.BackgroundColor3 = Color3.fromRGB(180,120,20)
    end)

    teleportBtn.MouseButton1Click:Connect(teleportToLastStop)

    loopBtn.MouseButton1Click:Connect(function()
        walkLoop = not walkLoop
        loopBtn.Text = walkLoop and "🔁 Loop: ON" or "🔁 Loop: OFF"
        loopBtn.BackgroundColor3 = walkLoop and Color3.fromRGB(0,120,65) or Color3.fromRGB(35,35,55)
    end)

    speedMinus.MouseButton1Click:Connect(function()
        walkSpeed = math.max(walkSpeed-0.25, 0.25)
        speedLbl.Text = string.format("%.2fx", walkSpeed)
    end)

    speedPlus.MouseButton1Click:Connect(function()
        walkSpeed = math.min(walkSpeed+0.25, 4.0)
        speedLbl.Text = string.format("%.2fx", walkSpeed)
    end)

    refreshBtn.MouseButton1Click:Connect(function()
        refreshRecords()
        renderList()
        notif("🔄 Direfresh", Color3.fromRGB(130,190,255),1.5)
    end)

    mergeBtn.MouseButton1Click:Connect(mergeAllCheckpoints)

    compressBtn.MouseButton1Click:Connect(function()
        if selectedRecord then
            compressRecord(selectedRecord, 3)
        else
            compressAllMerged()
        end
    end)

    refreshRecords()
    renderList()
end

-- ==================== KEYBIND ====================
UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.F then
        local g = LP.PlayerGui:FindFirstChild("RecorderBiann")
        if g then
            local f = g:FindFirstChildOfClass("Frame")
            if f then f.Visible = not f.Visible end
        end
    end
end)

-- ==================== START ====================
createGUI()
refreshRecords()

print("====================================")
print("📼 RECORDER BIANN v"..VERSION)
print("✅ Hasil kompres disimpan di folder 'Compressed'")
print("✅ Compress hard level untuk semua rekaman")
print("====================================")