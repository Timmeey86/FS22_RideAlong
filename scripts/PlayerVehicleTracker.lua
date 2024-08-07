---@class PlayerVehicleTracker
---This class keeps track of which player is above which vehicle

PlayerVehicleTracker = {}
local PlayerVehicleTracker_mt = Class(PlayerVehicleTracker)

---Creates a new object which keeps track of which player is above which vehicle
---@param mainStateMachine table @The main state machine of the mod
---@param debugVehicleDetection boolean @True if additional logging shall be turned on in case of vehicle detection
---@return table @The new instance
function PlayerVehicleTracker.new(mainStateMachine, debugVehicleDetection)
    local self = setmetatable({}, PlayerVehicleTracker_mt)
    self.mainStateMachine = mainStateMachine
    self.debugVehicleDetection = debugVehicleDetection
    -- The current vehicle which was found by the algorithm. This is only valid temporarily
    self.lastVehicleMatch = nil
    return self
end

---Finds the first vehicle below the given location
---@param x number @the X coordinate
---@param y number @the Y coordinate
---@param z number @the Z coordinate
function PlayerVehicleTracker:updateTrackedVehicleAt(x,y,z)
    -- Find the first vehicle below the player (that actually includes pallets)
    self.lastVehicleMatch = nil
    self.lastObjectMatch = nil
    local collisionMask = CollisionFlag.STATIC_OBJECT + CollisionFlag.DYNAMIC_OBJECT + CollisionFlag.VEHICLE + CollisionFlag.PLAYER
    dbgPrint(("Looking for vehicle at %.3f/%.3f/%.3f"):format(x,y,z))
    -- Look 4 meters above and 10 below the player to account for jumping and being stuck inside a vehicle
    local maxDistance = 14
    raycastAll(x, y + 4, z, 0,-1,0, "vehicleRaycastCallback", maxDistance, self, collisionMask)

    -- Update the state machine
    local trackedVehicle = nil
    if self.lastVehicleMatch ~= nil then
        trackedVehicle = self.lastVehicleMatch.object
    end
    self.mainStateMachine:onVehicleBelowPlayerUpdated(trackedVehicle)
end

---Updates the local coordinates of the vehicle which shall be tracked based on the previous vehicle match
---@param player table @The player
function PlayerVehicleTracker:updateTrackedLocation(player)
    dbgPrint("Updating tracked vehicle coordinates")
    local xVehicle, yVehicle, zVehicle = worldToLocal(self.lastVehicleMatch.object.rootNode, self.lastVehicleMatch.x, self.lastVehicleMatch.y, self.lastVehicleMatch.z)
    if self.lastObjectMatch ~= nil then
        -- An object is between the player and the trailer. Use the top Y coordinate of that object instead of the trailer
        local _, yObject, _ = worldToLocal(self.lastVehicleMatch.object.rootNode, self.lastObjectMatch.x, self.lastObjectMatch.y, self.lastObjectMatch.z)
        if yObject > yVehicle then
            -- Object is above the vehicle. Use the Y coordinate of the object
            yVehicle = yObject
        end
    end
    player.trackedVehicleCoords = { x = xVehicle, y = yVehicle, z = zVehicle }
    dbgPrint(("Tracked vehicle local coordinates are %.3f/%.3f/%.3f"):format(xVehicle, yVehicle, zVehicle))
    dbgPrint(("Tracked vehicle global coordinates are %.3f/%.3f/%.3f"):format(self.lastVehicleMatch.x, self.lastVehicleMatch.y, self.lastVehicleMatch.z))
end

---Force moves the player to the given location. This also stores network synchronisation values.
---@param player table @The player to be moved
---@param x number @The X coordinate of the target graphics root node position
---@param y number @The Y coordinate of the target graphics root node position
---@param z number @The Z coordinate of the target graphics root node position
function PlayerVehicleTracker:forceMovePlayer(player, x, y, z)
    dbgPrint("Force moving player")
    if self.debugVehicleDetection then
        local vehicleId = nil
        if self.mainStateMachine.trackedVehicle ~= nil then
            vehicleId = self.mainStateMachine.trackedVehicle.id
        end
        print(("%s: Moving player to %.3f/%.3f/%.3f. Tracked vehicle: %s"):format(MOD_NAME, x, y, z, tostring(vehicleId)))
    end
    player:moveToAbsoluteInternal(x, y + player.model.capsuleTotalHeight * 0.5, z)
    setTranslation(player.graphicsRootNode, x, y, z)
    if self.mainStateMachine.trackedVehicle then
        local xl, yl, zl = worldToLocal(self.mainStateMachine.trackedVehicle.rootNode, x, y, z)
        -- Synchronize the local coordinates to other network participants since by the time they receive the update, the global coordinates will be wrong already
        player.forceMoveVehicle = self.mainStateMachine.trackedVehicle
        player.forceMoveLocalCoords = {x = xl, y = yl, z = zl}
    -- else: Force moving without a tracked vehicle can happen when the player is leaving a vehicle
    --       We don't need to send network data in that case since base game will handle that
    end
end


---Updates internal states based on whether or not a vehicle is below that player.
---@param player table @The player to be inspected
---@param dt number @The time delta since the previous call
function PlayerVehicleTracker:checkForVehicleBelow(player, dt)

    -- Other players: Just move them along with the vehicle as long as that's possible
    if player.syncedLockVehicle ~= nil then
        local x,y,z = localToWorld(player.syncedLockVehicle.rootNode, player.syncedLockCoords.x, player.syncedLockCoords.y, player.syncedLockCoords.z)
        player:moveToAbsoluteInternal(x, y + player.model.capsuleTotalHeight * 0.5, z)
        setTranslation(player.graphicsRootNode, x, y, z)
    end
    -- Otherwise only handle the local client player
    if not player.isClient or player ~= g_currentMission.player then return end

    -- Check if the player is active in the game or sitting in a vehicle (or other reasons not to be "entered")
    self.mainStateMachine:onPlayerIsEnteredStateUpdated(player.isEntered)
    -- If the player is not enterd, they can by definition not be on a vehicle, so we can skip the remaining function
    if not player.isEntered then return end

    -- Find the first vehicle below the player
    local previousVehicle = self.mainStateMachine.trackedVehicle
    local playerWorldX, playerWorldY, playerWorldZ = player:getPositionData()
    dbgPrint(("Updating tracked vehicle in :checkForVehicleBelow (default case) based on player pos %.3f/%.3f/%.3f"):format(playerWorldX, playerWorldY, playerWorldZ))
    self:updateTrackedVehicleAt(playerWorldX, playerWorldY, playerWorldZ)

    -- Depending on the state, do different things:
    -- If there is no vehicle below the player, or neither player nor vehicle are moving, nothing has to be done
    -- If there is a vehicle, and only the player is moving: Update the tracked vehicle coordinates
    -- If there is a vehicle, and only the vehicle is moving: Drag the player along with the vehicle so that they stick to the tracked location on the vehicle
    -- If both are moving, add the player movement vector to the vehicle vector and move the player to that calculated location
    local state = self.mainStateMachine.state

    if self.mainStateMachine.trackedVehicle == nil then
        player.trackedVehicleCoords = nil
        if previousVehicle ~= nil then
            -- Reset rotation so it doesn't get used when the player hops on the same vehicle again
            previousVehicle.previousRotation = nil
        end
    elseif state == StickyFeetStateMachine.STATES.PLAYER_MOVING
        or state == StickyFeetStateMachine.STATES.JUMPING_ONTO_VEHICLE
        or (previousVehicle ~= nil and self.mainStateMachine.trackedVehicle ~= previousVehicle)
        or (state == StickyFeetStateMachine.STATES.IDLE_ON_VEHICLE and self.mainStateMachine.previousState == StickyFeetStateMachine.STATES.PLAYER_MOVING)
        then

        dbgPrint("Updating tracked vehicle coordinates since player is moving above a vehicle in some way (or because the vehicle changed)")

        -- Always update the tracked location if the player is moving in any way (and for one update after stopping, so we get the position they are stopped at)
        self:updateTrackedLocation(player)
    end

    if player.trackedVehicleCoords ~= nil
        and state ~= StickyFeetStateMachine.STATES.JUMPING_FROM_MOVING_VEHICLE
        and state ~= StickyFeetStateMachine.STATES.JUMPING_ONTO_VEHICLE then

        local vehicle = self.mainStateMachine.trackedVehicle
        local targetX,targetY,targetZ = localToWorld(vehicle.rootNode, player.trackedVehicleCoords.x, player.trackedVehicleCoords.y, player.trackedVehicleCoords.z)
        dbgPrint(("Current target coordinates are %.3f/%.3f/%.3f based on vehicle ID %d"):format(targetX, targetY, targetZ, vehicle.id))

        if (state == StickyFeetStateMachine.STATES.VEHICLE_MOVING and player.trackedVehicleCoords ~= nil) then
            dbgPrint("Moving player to target location")
            self:forceMovePlayer(player, targetX, targetY, targetZ)
            -- Rotate the player around the Y axis by the same amount the vehicle has rotated
            local dirX, _, dirZ = localDirectionToWorld(vehicle.rootNode, 0, 0, 1)
            local newRotation = MathUtil.getYRotationFromDirection(dirX, dirZ)
            if vehicle.previousRotation ~= nil then
                local rotationDiff = newRotation - vehicle.previousRotation
                player:setRotation(player.rotX, player.rotY + rotationDiff)
            end
            vehicle.previousRotation = newRotation
        end

        -- If the vehicle is moving and the player is either moving, jumping up or falling down
        if self.mainStateMachine:playerIsMovingAboveMovingVehicle() then
            dbgPrint("Player is moving above vehicle - adding player vector to target coordinates")
            -- Calculate the desired player movement
            local desiredSpeed = player:getDesiredSpeed()
            local dtInSeconds = dt * 0.001
            local desiredSpeedX = player.motionInformation.currentWorldDirX * desiredSpeed * dtInSeconds
            local desiredSpeedZ = player.motionInformation.currentWorldDirZ * desiredSpeed * dtInSeconds
            dbgPrint(("Desired speed is %.3f, dt is %.3fs, X/Y speed is %.3f/%.3f"):format(desiredSpeed, dtInSeconds, desiredSpeedX, desiredSpeedZ))
            -- Calculate the target world coordinates
            targetX = targetX + desiredSpeedX
            targetZ = targetZ + desiredSpeedZ
            dbgPrint(("New target coordinates are %.3f/%.3f/%.3f based on vehicle ID %d"):format(targetX, targetY, targetZ, vehicle.id))
            -- Find the vehicle at those coordinates to check wether or not the location is still on the vehicle
            dbgPrint("Updating tracked vehicle in :checkForVehicleBelow ('player is moving' case)")
            self:updateTrackedVehicleAt(targetX, targetY, targetZ)
            state = self.mainStateMachine.state
            vehicle = self.mainStateMachine.trackedVehicle
            -- Note: if that location is no longer above a vehicle, the state machine will be in a NO_VEHICLE state now
            if self.mainStateMachine:playerIsMovingAboveMovingVehicle() then
                dbgPrint("Target location is still above vehicle. Updating tracked vehicle coordinates")
                -- Remember the new tracked location
                self:updateTrackedLocation(player)
                -- Retrieve target world coordinates
                targetX,targetY,targetZ = localToWorld(vehicle.rootNode, player.trackedVehicleCoords.x, player.trackedVehicleCoords.y, player.trackedVehicleCoords.z)
                dbgPrint(("Final target coordinates are %.3f/%.3f/%.3f based on vehicle ID %d"):format(targetX, targetY, targetZ, vehicle.id))
                -- Adjust for jumping or falling
                if state == StickyFeetStateMachine.STATES.JUMPING_ABOVE_VEHICLE or state == StickyFeetStateMachine.STATES.FALLING_ABOVE_VEHICLE then
                    local _, graphicsY, _ = localToWorld(player.graphicsRootNode, 0, 0, 0)
                    local adjustedYCoordinate = graphicsY + player.motionInformation.currentSpeedY * dtInSeconds
                    if adjustedYCoordinate > targetY then
                        targetY = adjustedYCoordinate
                    elseif state == StickyFeetStateMachine.STATES.FALLING_ABOVE_VEHICLE then
                        -- the player is still considered falling, but they landed on the trailer or something else 
                        -- => we need to convince the game engine that the player is in fact no longer falling
                        player.motionInformation.currentSpeedY = 0
                        player.baseInformation.isOnGround = true
                        player.playerStateMachine.playerStateFall:deactivate()
                        player.networkInformation.interpolatorOnGround:setValue(1.0)
                    end
                end
            else
                dbgPrint("Target location is no longer above vehicle")
                -- Keep Y coordinate so the next force move does not force the player down on the trailer again
                -- This is required only once since the state machine will prevent further position manipulations from happening
                local _, graphicsY, _ = localToWorld(player.graphicsRootNode, 0, 0, 0)
                targetY = graphicsY
            end
            dbgPrint("Moving player to target location")
            self:forceMovePlayer(player, targetX, targetY, targetZ)
        end
    end

    -- Nothing to do in other states
end

---This is called by the game engine when an object which matches the VEHICLE collision mask was found below the player
---@param potentialVehicleId number @The ID of the object which was found
---@param x number @The world X coordinate of the match location
---@param y number @The world Y coordinate of the match location
---@param z number @The world Z coordinate of the match location
---@param distance number @The distance between the player and the match location
---@return boolean @False if the search should be stopped, true if it should be continued
function PlayerVehicleTracker:vehicleRaycastCallback(potentialVehicleId, x, y, z, distance)
    if potentialVehicleId ~= nil and potentialVehicleId ~= 0 then
        local object = g_currentMission:getNodeObject(potentialVehicleId)
        if object ~= nil and (object:isa(Vehicle)) then
            self.lastVehicleMatch = { object = object, x = x, y = y, z = z, distance = distance }
            if self.debugVehicleDetection then
                print(("%s: Found vehicle with ID %d at %.3f/%.3f/%.3f, %.3fm below player location"):format(MOD_NAME, object.id, x, y, z, distance - g_currentMission.player.model.capsuleTotalHeight ))
            end
            -- Stop searching
            return false
        elseif object ~= nil and self.lastObjectMatch == nil and (object:isa(Bale) or object:isa(Player)) then
            self.lastObjectMatch = { object = object, x = x, y = y, z = z, distance = distance }
            -- Continue searching anyway
        end
    end

    -- Any other case: continue searching
    return true
end

---This is called on both client and server when players shall be synchronized. However, data will only be sent from clients since the server will never
---have data related to force moving
---@param player table @The player to synchronize
---@param streamId number @The ID of the network stream
---@param connection table @Unused
---@param dirtyMask table @Unused
function PlayerVehicleTracker:after_player_writeUpdateStream(player, streamId, connection, dirtyMask)
    -- Send vehicle tracking data only for the own player on each client
    local forceMoveIsValid = player.forceMoveVehicle ~= nil
    if streamWriteBool(streamId, forceMoveIsValid) then
        dbgPrint("Sending target player position for player ID " .. tostring(player.id) .. " to the server")
        -- Transmit the reference of the tracked vehicle to other network participants (the ID is different on every client, but NetworkUtil seems to map that for us)
        NetworkUtil.writeNodeObject(streamId, player.forceMoveVehicle)
        -- distribute the player position in relation to the vehicle
        streamWriteFloat32(streamId, player.forceMoveLocalCoords.x)
        streamWriteFloat32(streamId, player.forceMoveLocalCoords.y)
        streamWriteFloat32(streamId, player.forceMoveLocalCoords.z)
        -- Reset values so they don't get sent again
        player.forceMoveVehicle = nil
        player.forceMoveLocalCoords = nil
    end
end

---This is called on both client and server when other clients sent synchronisation data.
---It will be processed on both server and clients in order to move non-local players to the appropriate positions.
---@param player table @The player to synchronize
---@param streamId number @The ID of the network stream
---@param timestamp unknown @The timestamp of the update
---@param connection table @Unused
function PlayerVehicleTracker:after_player_readUpdateStream(player, streamId, timestamp, connection)
    if streamReadBool(streamId) then
        dbgPrint("Receiving player position for player ID " .. tostring(player.id))
        local vehicle = NetworkUtil.readNodeObject(streamId)
        local xl = streamReadFloat32(streamId)
        local yl = streamReadFloat32(streamId)
        local zl = streamReadFloat32(streamId)

        if vehicle ~= nil and xl ~= nil and yl ~= nil and zl ~= nil then
            player.syncedLockVehicle = vehicle
            player.syncedLockCoords = { x = xl, y = yl, z = zl }
        else
            if vehicle == nil then
                Logging.warning(MOD_NAME .. ": [network] Vehicle could not be resolved. Ignoring player update")
            else
                Logging.warning((MOD_NAME .. ": [network] At least one of X/Y/Z was nil: %s/%s/%s. Ignoring player update"):format(tostring(xl), tostring(yl), tostring(zl)))
            end
        end
    else
        player.syncedLockVehicle = nil
        player.syncedLockCoords = nil
    end
end