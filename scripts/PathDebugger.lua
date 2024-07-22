PathDebugger = {}
local PathDebugger_mt = Class(PathDebugger)
function PathDebugger.new(debugSwitch)
    local self = setmetatable({}, PathDebugger_mt)
    self.index = 1
    self.playerPositions = {}
    self.vehiclePositions = {}
    self.movementStarts = {}
    self.movementStops = {}
    self.playerUpdateCalls = {}
    self.vehicleUpdateCalls = {}
    self.playerMovePlayerCalls = {}
    self.debugSwitch = debugSwitch
    return self
end

function PathDebugger:trace(text)
    if self.debugSwitch then
        print(("%s [%d]: %s"):format(MOD_NAME, self.index, text))
    end
end

function PathDebugger:recordPlayerUpdateCall()
    if self.debugSwitch then
        self:trace("Before player:update")
        self.playerUpdateCalls[self.index] = true
    end
end
function PathDebugger:recordPlayerUpdateTickCall()
    if self.debugSwitch then
        self:trace("Before player:updateTick")
        self.playerUpdateCalls[self.index] = true
    end
end

function PathDebugger:recordVehicleUpdateCall()
    if self.debugSwitch then
        self:trace("After Vehicle:update")
        self.vehicleUpdateCalls[self.index] = true
    end
end

function PathDebugger:recordPlayerMovePlayerCall()
    if self.debugSwitch then
        self:trace("During Player:movePlayer")
        self.playerMovePlayerCalls[self.index] = true
    end
end

function PathDebugger:addPlayerPos(player)
    if self.debugSwitch then
        if g_currentMission.player ~= nil and player.id == g_currentMission.player.id then
            local x,y,z = getTranslation(player.rootNode)
            self.playerPositions[self.index] = { x = x, y = y, z = z }
            self:trace(("Adding player position: %.3f, %.3f, %.3f"):format(x,y,z))
            self:trace("Updates since movement start: " .. tostring(player.updatesSinceMovementStart))
        end
    end
end

function PathDebugger:startMovement()
    if self.debugSwitch then
        self:trace("Player is now moving")
        self.movementStarts[self.index] = true
    end
end

function PathDebugger:stopMovement()
    if self.debugSwitch then
        self:trace("Player is no longer moving")
        self.movementStops[self.index] = true
    end
end

function PathDebugger:addVehiclePos(vehicle)
    if self.debugSwitch and g_currentMission.player ~= nil and g_currentMission.player.trackedVehicle ~= nil and g_currentMission.player.trackedVehicle.id == vehicle.id then
        self:trace("Vehicle position updated")
        local x,y,z = getTranslation(vehicle.rootNode)
        self.vehiclePositions[self.index] = { x = x, y = y, z = z }
    end
end

function PathDebugger:draw()
    local textSize = getCorrectTextSize(0.012)
    local pathColor = { r = 1, g = 0, b = 0 }
    local offset = 0
    if self.debugSwitch then
        for i = 1, self.index - 1 do
            local pos = self.playerPositions[i]
            if pos ~= nil then
                local mvStart = self.movementStarts[i]
                local mvEnd = self.movementStops[i]
                if mvStart then
                    Utils.renderTextAtWorldPosition(pos.x, pos.y + 0.1, pos.z, "Start", textSize, 0, {1,1,1})
                    pathColor = { r = 0, g = 0, b = 1 }
                    offset = 0.1
                elseif mvEnd then
                    Utils.renderTextAtWorldPosition(pos.x, pos.y + 0.1, pos.z, "End", textSize, 0, {1,1,1})
                    pathColor = { r = 1, g = 0, b = 0 }
                    offset = 0
                end
                local vehiclePos = self.vehiclePositions[i]
                if vehiclePos ~= nil then
                    DebugUtil.drawDebugLine(pos.x, pos.y + offset, pos.z, vehiclePos.x, vehiclePos.y, vehiclePos.z, 1, 1, 1, 0, false)
                end
                if self.playerUpdateCalls[i] then
                    Utils.renderTextAtWorldPosition(pos.x, pos.y + 0.15, pos.z, "P:u", textSize, 0, {1,1,1})
                end
                if self.vehicleUpdateCalls[i] then
                    Utils.renderTextAtWorldPosition(pos.x, pos.y + 0.2, pos.z, "V:u", textSize, 0, {1,1,1})
                end
                if self.playerMovePlayerCalls[i] then
                    Utils.renderTextAtWorldPosition(pos.x, pos.y + 0.25, pos.z, "P:umP", textSize, 0, {1,1,1})
                end
                Utils.renderTextAtWorldPosition(pos.x, pos.y + 0.05, pos.z, tostring(i), textSize, 0, {1,1,1})
                for j = i + 1, self.index - 1 do
                    local nextPos = self.playerPositions[j]
                    if nextPos ~= nil then
                        DebugUtil.drawDebugLine(pos.x, pos.y + offset, pos.z, nextPos.x, nextPos.y + offset, nextPos.z, pathColor.r, pathColor.g, pathColor.b, .01, false)
                        i = j
                        break -- continue with the "i" loop
                    end
                end
            end
        end
        for i = 1, self.index - 1 do
            local pos = self.vehiclePositions[i]
            if pos ~= nil then
                Utils.renderTextAtWorldPosition(pos.x, pos.y, pos.z, tostring(i), textSize, 0, {0,1,0})
                for j = i + 1, self.index - 1 do
                    local nextPos = self.vehiclePositions[j]
                    if nextPos ~= nil then
                        DebugUtil.drawDebugLine(pos.x, pos.y, pos.z, nextPos.x, nextPos.y, nextPos.z, 0, 1, 0, .01, false)
                        i = j
                        break -- continue with the "i" loop
                    end
                end
            end
        end
    end
end

function PathDebugger:update()
    if self.debugSwitch then
        self.index = self.index + 1
        dbgPrint("Increasing index to " .. tostring(self.index))
    end
end