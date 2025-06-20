--[[
	AlexChassis.lua
	Client-side vehicle physics and controller.
	Handles player input, vehicle movement, suspension, sound, and camera.

	Original Author: @badccvoid
	Improvements and Comments by: @shzexi9e3ca (Readability) and Gemini AI (Further Comments)

	This script is responsible for the client-side simulation and visual representation
	of vehicle dynamics, including:
	- Processing player input for driving, steering, and vehicle actions.
	- Calculating and applying forces for suspension, traction, drag, and engine thrust.
	- Managing visual aspects like wheel rotation, steering wheel animation, and lighting.
	- Controlling sound effects for engine, tires, and environmental acoustics.
]]

--// SERVICES & MODULES //--
-- Get necessary Roblox services. These services provide access to various game functionalities.
local CollectionService = game:GetService("CollectionService") -- Used for tagging and retrieving game objects.
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- A storage area for assets that need to be accessible by both client and server.
local UserInputService = game:GetService("UserInputService") -- Manages user input (keyboard, mouse, gamepad, touch).
local SoundService = game:GetService("SoundService") -- Manages sound properties and sound effects.
local RunService = game:GetService("RunService") -- Provides events that fire every frame, useful for game loops and updates.
local Players = game:GetService("Players") -- Manages players in the game.

-- Load custom modules from ReplicatedStorage. These are external scripts providing specific functionalities.
local Audio = require(ReplicatedStorage.Module.Audio) -- Module for playing audio effects.
local AlexInput = require(ReplicatedStorage.Module.AlexInput) -- Custom input handling module.
local UI = require(ReplicatedStorage.Module.UI) -- User Interface related functions.
local R15IKv2 = require(ReplicatedStorage.Module.R15IKv2) -- Inverse Kinematics module for R15 character rigs, used for arm movement.
local Region = require(ReplicatedStorage.Module.Region) -- Module for checking if a point is within a defined region.
local Settings = require(ReplicatedStorage.Resource.Settings) -- Game settings.
local ChassisShared = require(ReplicatedStorage.Module.ChassisShared) -- Shared data accessible by both client and server (e.g., handbrake state).
local VehicleUtil = require(ReplicatedStorage.Game.Vehicle) -- Utility functions related to vehicles.
local Time = require(ReplicatedStorage.Module.Time) -- Time utility module.
local EnumMake = require(ReplicatedStorage.Game.Garage.EnumMake) -- Enumeration for vehicle makes/brands (e.g., "Lamborghini", "Volt").

--// LOCAL VARIABLES //--
local LocalPlayer = Players.LocalPlayer -- The player currently running this script.
local IsStudio = RunService:IsStudio() -- Boolean flag: true if the game is running in Roblox Studio, false otherwise.
local CurrentCamera = workspace.CurrentCamera -- Reference to the game's current camera.

--// FUNCTION DECLARATIONS & SHORTCUTS //--
local GetMoveVector -- Forward declare function to get player movement vector, primarily for mobile support.
function GetMoveVector()
	-- Default empty move vector. This will be overwritten if ControlModule is found.
	return Vector3.new()
end
-- Overwrite GetMoveVector with the one from the player's ControlModule for mobile support.
-- This block ensures that mobile input (like joysticks) is correctly captured.
do
	local ControlModule = LocalPlayer.PlayerScripts:WaitForChild("PlayerModule", 5).ControlModule -- Attempts to find the ControlModule from PlayerScripts.
	if ControlModule then
		ControlModule = require(ControlModule) -- Loads the ControlModule.
		function GetMoveVector()
			return ControlModule:GetMoveVector() -- Overwrites the function to get the actual movement vector from the ControlModule.
		end
	end
end

-- Shortcuts for frequently used constructors and functions to improve performance and readability.
local cf, v3, cfa = CFrame.new, Vector3.new, CFrame.Angles -- Aliases for CFrame and Vector3 constructors.
local cfb, v3b, v3d = cf(0, 0, 0), v3(0, 0, 0), v3(0, -1, 0) -- Pre-created common CFrames and Vectors (e.g., zero vector, down vector).
local RayNew = Ray.new -- Alias for Ray.new constructor.
local fpor = workspace.FindPartOnRay -- Alias for FindPartOnRay method.
local fporwil = workspace.FindPartOnRayWithIgnoreList -- Alias for FindPartOnRayWithIgnoreList method.
local min, max, abs, tanh = math.min, math.max, math.abs, math.tanh -- Aliases for common math functions.
local exp = math.exp -- Alias for math.exp (e^x).
local tos, vtos, vtws = cfb.toObjectSpace, cfb.vectorToObjectSpace, cfb.vectorToWorldSpace -- CFrame method shortcuts (e.g., for converting coordinates).

local Event -- Will be set later by the main script to communicate with the server. This is a RemoteEvent.

--// RAYCASTING UTILITIES //--
--[[
	A raycast function that repeatedly casts until it hits a collidable part,
	ignoring any non-collidable parts it hits along the way.
	This is useful for ensuring the ray hits a solid surface and doesn't get stuck on decorative or invisible parts.
]]
local function RayCast(Origin, Direction, IgnoreList)
	local Length = Direction.magnitude -- Total length of the ray.
	Direction = Direction.unit -- Normalize the direction vector to a unit vector.
	local Position = Origin -- Current starting position for the ray segment.
	local Traveled = 0 -- Distance already traveled by the ray.
	local Ignored = {IgnoreList} -- Table of parts to ignore, initialized with the provided IgnoreList.
	local Hit, Pos, Normal = nil, v3b, v3b -- Variables to store raycast results.
	local Attempts = 0 -- Counter to prevent infinite loops.
	local CanCollide -- Flag to check if the hit part is collidable.
	repeat
		Attempts = Attempts + 1
		local r = RayNew(Position, Direction * (Length - Traveled)) -- Create a new ray for the remaining length.
		Hit, Pos, Normal = fporwil(workspace, r, Ignored, false, true) -- Perform the raycast, ignoring specified parts.
		CanCollide = Hit and Hit.CanCollide -- Check if the hit part has CanCollide set to true.
		if not CanCollide then
			table.insert(Ignored, Hit) -- If the hit part is not collidable, add it to the ignore list for the next attempt.
		end
		Traveled = (Origin - Pos).magnitude -- Update the total distance traveled from the original origin.
		Position = Pos -- Set the new origin for the next ray segment to the current hit position.
	until CanCollide or Length - Traveled <= 0.001 or Attempts > 4 -- Stop if a collidable part is hit, ray length is exhausted, or too many attempts.
	if not Hit then
		Pos, Normal = Origin + Direction * Length, v3d -- If nothing was hit, set Pos to the end of the original ray and Normal to down.
	end
	return Hit, Pos, Normal -- Return the hit part, hit position, and hit normal.
end

--[[
	A more optimized raycast function that attempts up to 3 casts to find a collidable part.
	It's "smarter" because it tries to avoid the performance overhead of the repeated casting in the `RayCast` function above,
	by making a few pre-calculated attempts rather than a generic loop.
]]
local function SmartCast(Origin, Direction, IgnoreList)
	local Length = Direction.magnitude -- Total length of the ray.
	Direction = Direction.unit -- Normalize the direction vector.
	local IgnoreListIsTable = type(IgnoreList) == "table" -- Check if the ignore list is already a table.
	local Ignored = IgnoreListIsTable and {
		IgnoreList, -- If it's a table, use it as the first element.
		nil, -- Placeholder for subsequent ignored parts.
		nil
	} or IgnoreList -- If not a table, use it directly (e.g., a single part to ignore).
	local IgnoreIndex = IgnoreListIsTable and 1 or 0 -- Index for adding to the 'Ignored' table.
	local Position = Origin -- Current ray origin.
	local Traveled = 0 -- Distance traveled.
	local Hit, Pos, Normal, Mat -- Variables for raycast results, including material.
	
	-- Attempt 1
	local r = RayNew(Position, Direction * Length) -- Create the initial ray.
	if IgnoreListIsTable then
		Hit, Pos, Normal, Mat = fporwil(workspace, r, Ignored, false, true) -- Use FindPartOnRayWithIgnoreList if IgnoreList is a table.
	else
		Hit, Pos, Normal, Mat = fpor(workspace, r, Ignored, false, true) -- Use FindPartOnRay otherwise.
	end
	if Hit and Hit.CanCollide then
		return Hit, Pos, Normal, Mat -- If a collidable part is hit, return immediately.
	end
	
	-- If first hit was non-collidable, add it to the ignore list and try again from the hit position.
	Traveled = (Origin - Pos).magnitude -- Calculate distance traveled.
	if not IgnoreListIsTable then
		Ignored = {
			IgnoreList, -- Original ignore part.
			Hit, -- The newly ignored non-collidable part.
			nil
		}
		IgnoreListIsTable = true -- Now 'Ignored' is a table.
	else
		IgnoreIndex = IgnoreIndex + 1
		Ignored[IgnoreIndex] = Hit -- Add the non-collidable part to the existing ignore table.
	end
	Position = Pos -- Update ray origin to the previous hit position.

	-- Attempt 2
	r = RayNew(Position, Direction * (Length - Traveled)) -- Create ray for remaining length.
	if IgnoreListIsTable then
		Hit, Pos, Normal, Mat = fporwil(workspace, r, Ignored, false, true)
	else
		Hit, Pos, Normal, Mat = fpor(workspace, r, Ignored, false, true)
	end
	if Hit and Hit.CanCollide then
		return Hit, Pos, Normal, Mat
	end

	-- Attempt 3
	Traveled = (Origin - Pos).magnitude -- Update distance traveled.
	IgnoreIndex = IgnoreIndex + 1
	Ignored[IgnoreIndex] = Hit -- Add the non-collidable part to the ignore table.
	Position = Pos -- Update ray origin.
	r = RayNew(Position, Direction * (Length - Traveled)) -- Create ray for remaining length.
	if IgnoreListIsTable then
		Hit, Pos, Normal, Mat = fporwil(workspace, r, Ignored, false, true)
	else
		Hit, Pos, Normal, Mat = fpor(workspace, r, Ignored, false, true)
	end
	if Hit and Hit.CanCollide then
		return Hit, Pos, Normal, Mat
	end
	
	-- If still no hit after 3 attempts, return the end of the original ray.
	return nil, Origin + Direction * Length, Normal, Mat
end


--// SOUND CONFIGURATION //--
-- References to sound effects in the SoundService. These are Roblox SoundEffect instances.
local SoundEffects = {
	Echo = SoundService.Chassis.EchoSoundEffect,
	Equalizer = SoundService.Chassis.EqualizerSoundEffect,
	Reverb = SoundService.Chassis.ReverbSoundEffect
}
-- A map of sound effects to their configurable properties. This defines which properties can be adjusted.
local SoundOptions = {
	Echo = {"Delay", "DryLevel", "Feedback", "WetLevel"},
	Equalizer = {"HighGain", "LowGain", "MidGain"},
	Reverb = {"DecayTime", "Density", "Diffusion", "DryLevel", "WetLevel"}
}
-- Predefined sound presets for different environments. These are collections of property values for the SoundEffects.
local SoundValues = {
	Tunnel = {
		Echo = {Delay = 0.35, DryLevel = 0, Feedback = 0, WetLevel = -27},
		Equalizer = {HighGain = 0, LowGain = -2.5, MidGain = -2.5},
		Reverb = {DecayTime = 3.5, Density = 1, Diffusion = 0.6, DryLevel = 4, WetLevel = 0}
	},
	Outside = {
		Echo = {Delay = 1.5, DryLevel = 0, Feedback = 0, WetLevel = -42.2},
		Equalizer = {HighGain = 0, LowGain = 0, MidGain = 0},
		Reverb = {DecayTime = 10, Density = 1, Diffusion = 1, DryLevel = 0, WetLevel = -35}
	},
	City = {
		Echo = {Delay = 0.198, DryLevel = 0, Feedback = 0, WetLevel = -9.8},
		Equalizer = {HighGain = 0, LowGain = -8, MidGain = 0},
		Reverb = {DecayTime = 4.6, Density = 1, Diffusion = 0.6, DryLevel = 0, WetLevel = -28}
	}
}

local Transition = 0 -- Variable for controlling the transition progress between sound environments (0 to 1).
local SetRPMRaw -- Forward declare the raw RPM sound function, which will be defined in the following 'do' block.

-- This block encapsulates the engine sound logic.
do
	-- Gaussian function to create a smooth curve for sound volume based on RPM.
	-- This function outputs a value between 0 and 1, peaking at 'Mean' and spreading based on 'StdDev'.
	local function f(Mean, Ratio, StdDev)
		return math.exp(-(Mean - Ratio) ^ 2 / (2 * StdDev * StdDev))
	end
	
	-- Complex engine sound logic for combustion engines (most cars).
	-- It blends between Idle, Low, Mid, and High RPM sounds based on current RPM and throttle input.
	local function SetRPM3(Sounds, RPM, Throttle, Make)
		local Mult = 0.8 -- General volume multiplier.
		local IdleSpeed, OnLowSpeed, OnMidSpeed, OnHighSpeed, OffLowSpeed -- Playback speed variables for different sound layers.
		local IdleMult = 1 -- Multiplier for idle sound.
		-- Different cars have different engine characteristics, affecting how sounds are blended.
		if Make == EnumMake.Lamborghini or Make == EnumMake.Bugatti or Make == EnumMake.Chiron or Make == EnumMake.Surus or Make == EnumMake.Challenger or Make == EnumMake.Revuelto then
			Mult = 0.6 -- Specific multiplier for these high-performance cars.
			if RPM < 6000 then
				IdleSpeed = (RPM + 2000) / 5500 + 0.8
				OnLowSpeed = RPM / 12000 + 0.5 + 0.07 - 0.1
				IdleMult = 0.5
			end
			OnMidSpeed = 1 + RPM / 12000 - 0.5 + 0.07 - 0.1
			OnHighSpeed = 1 + RPM / 12000 - 0.3 + 0.25 - 0.1
			OffLowSpeed = RPM / 12000 + 0.6 + 0.1 - 0.1
		else -- Default engine sound characteristics for other cars.
			if RPM < 6000 then
				IdleSpeed = (RPM + 1000) / 6000
				OnLowSpeed = RPM / 10000 + 0.2
			end
			OnMidSpeed = 1 + RPM / 10000 - 0.7
			OnHighSpeed = 1 + RPM / 10000 - 1
			OffLowSpeed = RPM / 10000 + 0.2
		end

		-- Set playback speeds for different sound layers.
		if IdleSpeed then Sounds.Idle.PlaybackSpeed = IdleSpeed end
		if OnLowSpeed then Sounds.OnLow.PlaybackSpeed = OnLowSpeed end
		Sounds.OnMid.PlaybackSpeed = OnMidSpeed
		Sounds.OnHigh.PlaybackSpeed = OnHighSpeed
		Sounds.OffLow.PlaybackSpeed = OffLowSpeed
		
		-- Calculate volumes for each sound layer using the Gaussian function.
		local Ratio = RPM / 8000 -- Normalize RPM to a ratio for the Gaussian function.
		local IdleVolume = f(-0.1, Ratio, 0.2) * Mult * IdleMult
		local OnLowVolume = f(0.3, Ratio, 0.1) * Mult
		local OnMidVolume = f(0.6, Ratio, 0.2) * Mult
		local OnHighVolume = f(0.9, Ratio, 0.15) * Mult
		
		Sounds.Idle.Volume = IdleVolume
		-- Adjust volumes based on whether the player is accelerating (Throttle > 0) or decelerating.
		if Throttle > 0 then -- Accelerating
			Sounds.OnLow.Volume = OnLowVolume
			Sounds.OnMid.Volume = OnMidVolume
			Sounds.OnHigh.Volume = OnHighVolume
			Sounds.OffLow.Volume = 0 -- Off-throttle sound is silent when accelerating.
		else -- Decelerating (or idle)
			Sounds.OnLow.Volume = OnLowVolume * 0.5
			Sounds.OnMid.Volume = OnMidVolume * 1
			Sounds.OnHigh.Volume = OnHighVolume * 1
			Sounds.OffLow.Volume = OnLowVolume * 0.5 -- Off-throttle sound becomes active.
		end
	end
	
	-- Simpler engine sound logic for electric vehicles.
	-- These typically have a more linear and less varied sound profile.
	local function SetRPM1(Sounds, RPM, Throttle, Make)
		local Mult = 0.5 -- General volume multiplier for electric cars.
		-- Different electric cars have different max RPMs for sound scaling.
		local Ratio = RPM / ((Make == EnumMake.Volt and 10000) or (Make == EnumMake.Roadster and 12000) or 6000)
		Sounds.Idle.PlaybackSpeed = (RPM + 3000) / 8000 -- Adjust playback speed based on RPM.
		local IdleVolume = f(1.1, Ratio, 0.5) * Mult -- Use Gaussian function for a smooth volume curve.
		Sounds.Idle.Volume = IdleVolume
	end
	
	-- Main function to set RPM sounds. It decides which logic to use based on the car's make.
	function SetRPMRaw(Make, Sounds, RPM, Throttle)
		if Make == EnumMake.Model3 or Make == EnumMake.Volt or Make == EnumMake.Roadster or Make == EnumMake.Cybertruck then
			SetRPM1(Sounds, RPM, Throttle, Make) -- Use electric vehicle sound logic.
		else
			SetRPM3(Sounds, RPM, Throttle, Make) -- Use combustion engine sound logic.
		end
	end
end

--// GEAR & RPM LOGIC //--
--[[
	Updates the vehicle's current gear and calculates the engine RPM.
	This simulates an automatic transmission, handling gear shifts and RPM calculation.
]]
local function UpdateGearsAndRPM(p, Gears, Speed, Throttle, dt)
	local Gear, LastGear, t3, LastRPM = p.Gear, p.LastGear, p.t3, p.LastRPM -- Retrieve current gear state from the vehicle packet 'p'.
	-- Calculate engine speed based on wheel speed and wheel radius.
	-- The constants convert speed from studs/s to an engine speed equivalent.
	local EngineSpeed = Speed / (p.Model.WheelBackRight.Wheel.Size.y / 2.9) * 1000 / 3600 / 0.34
	local GearRatio = LastGear * (1 - t3) + Gear * t3 -- Interpolate gear ratio for smooth transitions.

	-- Smoothly transition between gear ratios when shifting.
	if LastGear ~= Gear then -- If a gear shift is in progress.
		GearRatio = Gears[2 + LastGear] * (1 - t3 * t3) + Gears[2 + Gear] * t3 * t3 -- Use a squared interpolation for a snappier shift.
		t3 = t3 + dt * 1 / 0.26 -- Increment the transition timer 't3'. 0.26 is the target transition duration in seconds.
		p.t3 = t3
		if t3 >= 1 then -- Transition complete.
			p.LastGear = Gear -- Update LastGear to the new current gear.
			p.t3 = 0 -- Reset transition timer.
		end
	else -- No shift in progress.
		GearRatio = Gears[2 + Gear] -- Use the direct gear ratio. Gears[2] is reverse, Gears[3] is 1st, etc.
	end

	-- Calculate the final RPM.
	-- Gears[1] is typically the final drive ratio.
	local RPM = EngineSpeed * Gears[1] * GearRatio * 60 / (2 * math.pi)
	-- Calculate the "Full RPM" which is the RPM if the shift was instantaneous (used for shift point detection).
	local FullRPM = EngineSpeed * Gears[1] * Gears[2 + Gear] * 60 / (2 * math.pi)
	local ChangeIn = FullRPM - LastRPM -- Change in RPM, used to detect acceleration/deceleration for shifting.

	-- Automatic gear shifting logic.
	if not p.NoGears then -- If the vehicle has an automatic transmission.
		if Throttle > 0 and ChangeIn > 0 and FullRPM > 6000 and Gear < 6 then
			p.Gear = Gear + 1 -- Shift up if accelerating, RPM is high, and not in top gear.
		elseif ChangeIn < 0 and FullRPM < 3400 and Gear > 1 then
			p.Gear = Gear - 1 -- Shift down if decelerating, RPM is low, and not in first gear.
		end
	end

	-- Update the engine sound based on the new RPM.
	SetRPMRaw(p.EnumMakeId, p.Sounds, RPM, Throttle)
	p.LastRPM = FullRPM -- Store FullRPM for the next frame's ChangeIn calculation.
	return Gear, GearRatio -- Return the current gear and its ratio.
end

--// MAIN CHASSIS MODULE TABLE & STATE VARIABLES //--
local m = {} -- The main module table that will be returned.
local WASDQE = {0, 0, 0, 0, 0, 0} -- Input state for [W, A, S, D, Q, E]. 0 for released, 1 for pressed (or analog value).
local ShouldDrift, Lights, ShouldBrake, Autopilot = false, false, false, false -- Boolean flags for various vehicle states.
local Sirens = false -- Boolean flag for police sirens.

--// UTILITY FUNCTIONS //--
-- Recursively calculates the total mass of a model.
-- This is important for physics calculations (e.g., suspension force, anti-gravity).
local function GetMass(Model)
	local Mass = 0
	for _, v in next, Model:GetChildren() do -- Iterate through all children of the model.
		if v:IsA("BasePart") then -- If the child is a physical part.
			local m = v:GetMass() -- Get the default Roblox mass.
			if v.CustomPhysicalProperties then -- If custom physics properties are defined.
				local Density = v.CustomPhysicalProperties.Density
				if Density ~= Density then Density = 0 end -- NaN check for Density.
				m = m * Density -- Adjust mass based on custom density.
			end
			Mass = Mass + m -- Add part mass to total.
		end
		Mass = Mass + GetMass(v) -- Recurse for children models (e.g., complex assemblies).
	end
	return Mass
end

-- Enables or disables the player's humanoid states to prevent walking while seated.
-- This ensures the player character stays put and doesn't try to move on its own.
local SetHumanoidEnabled = function(Character, Enabled)
	for _, State in next, Enum.HumanoidStateType:GetEnumItems() do -- Iterate through all HumanoidStateType enums.
		-- Exclude Dead, None, and Jumping states as they should always be managed by the engine or other scripts.
		if State ~= Enum.HumanoidStateType.Dead and State ~= Enum.HumanoidStateType.None and State ~= Enum.HumanoidStateType.Jumping then
			Character.Humanoid:SetStateEnabled(State, Enabled) -- Enable or disable the state.
		end
	end
end

--// ACTION HANDLER //--
-- Handles inputs bound to specific vehicle actions (lights, drift, etc.).
-- This function is likely connected to a custom input binding system.
local function OnAction(b, State, i) -- 'b' is the action binding, 'State' is true for began/pressed, false for ended/released, 'i' is UserInputObject.
	local Name = b.Name -- Get the name of the action (e.g., "Drift", "Lights").
	if State then -- Action began (key pressed, button down).
		if Name == "Drift" then
			ShouldDrift = true -- Activate drift mode.
			ChassisShared.HandBrake = true -- Inform server about handbrake activation.
		elseif Name == "Lights" then
			Lights = not Lights -- Toggle lights.
			Event:FireServer("VehicleEvent", "Lights", Lights) -- Notify server to update lights.
		elseif Name == "Sirens" then
			Sirens = not Sirens -- Toggle sirens.
			Event:FireServer("VehicleEvent", "PoliceLights", Sirens) -- Notify server about police lights.
		elseif Name == "Brake" then
			ShouldBrake = not ShouldBrake -- Toggle continuous braking.
		elseif Name == "Forward" then
			WASDQE[1] = 1 -- Set forward input.
		elseif Name == "Backward" then
			WASDQE[3] = 1 -- Set backward input.
		elseif Name == "Autopilot" then
			Autopilot = not Autopilot -- Toggle autopilot.
		elseif Name == "Action" then
			if ChassisShared.VehicleMake == "Firetruck" then
				Event:FireServer("VehicleEvent", "FiretruckWater", true) -- Activate firetruck water.
			else
				Event:FireServer("VehicleEvent", "Action") -- Generic action for other vehicles.
			end
		elseif Name == "CamToggle" then
			local p = VehicleUtil.GetLocalVehiclePacket() -- Get the local vehicle packet.
			if not p.Passenger then -- Only allow driver to toggle camera.
				if p.IsCameraLocked then
					m.UnlockCamera(p) -- Unlock camera if locked.
				else
					m.LockCamera(p) -- Lock camera if unlocked.
				end
			end
		end
	elseif Name == "Drift" then -- Action ended (key released, button up).
		ShouldDrift = false -- Deactivate drift mode.
		ChassisShared.HandBrake = false -- Release handbrake.
	elseif Name == "Forward" then
		WASDQE[1] = 0 -- Release forward input.
	elseif Name == "Backward" then
		WASDQE[3] = 0 -- Release backward input.
	elseif Name == "Action" and ChassisShared.VehicleMake == "Firetruck" then
		Event:FireServer("VehicleEvent", "FiretruckWater", false) -- Deactivate firetruck water.
	end
end
m.OnAction = OnAction -- Expose OnAction function through the module table.

--// VEHICLE SETUP & STATE MANAGEMENT //--

-- Sets the anti-gravity force to counteract a portion of Roblox's gravity.
-- This helps the car stay on the ground and provides better handling.
function m.SetGravity(p, Gravity)
	local Mass = p.Mass -- Get the calculated mass of the vehicle.
	local Force = 1 - Gravity / 196.2 -- The force needed to counteract gravity. 196.2 is Roblox's default gravity (9.81 * 20).
	if Mass ~= Mass then Mass = 0 end -- NaN check for Mass.
	if Force ~= Force then Force = 0 end -- NaN check for Force.
	p.Lift.Force = v3(0, Mass * Force, 0) -- Apply an upward force proportional to mass and anti-gravity factor.
end

-- Calculates and updates vehicle physics properties like total mass, suspension force, and damping.
function m.UpdateStats(p)
	local Character = LocalPlayer.Character -- Get the player's character.
	local Model = p.Model -- Get the vehicle model.
	local Suspension = p.Suspension -- Suspension stiffness parameter from vehicle configuration.
	if Suspension ~= Suspension then Suspension = 4 end -- NaN check, default to 4.
	local Bounce = p.Bounce -- Suspension damping parameter.
	if Bounce ~= Bounce then Bounce = 100 end -- NaN check, default to 100.

	local Mass = (GetMass(Model) + GetMass(Character)) * 9.81 * 20 -- Calculate total mass including character, multiplied by Roblox's gravity constant (9.81 * 20).
	if Mass ~= Mass then Mass = 1 end -- NaN check, default to 1.

	local Force = Mass * Suspension -- Calculate the spring force for suspension.
	if Force ~= Force then Force = 0 end -- NaN check.
	local Damping = Force / Bounce -- Calculate damping force.
	if Damping ~= Damping then Damping = 0 end -- NaN check.

	p.Mass, p.Force, p.Damping = Mass, Force, Damping -- Store calculated values in the vehicle packet.
	m.SetGravity(p, 100) -- Apply a default anti-gravity force (100 is just a value, not real gravity).
end

-- Called when the local player enters a vehicle. Sets up controls, sounds, and physics objects.
function m.VehicleEnter(p)
	local IsPassenger = p.Passenger -- Check if the player is a passenger or the driver.
	local Character = LocalPlayer.Character
	SetHumanoidEnabled(Character, false) -- Disable player movement while seated.
	p.EnumMakeId = EnumMake[p.Make] -- Get the enumerated ID for the vehicle make (e.g., from string "Lamborghini" to EnumMake.Lamborghini).

	-- Handle different seating animations/states based on vehicle type.
	if p.EnumMakeId == "ATV" or p.EnumMakeId == "Volt" then
		p.NoLook = true -- Disable camera look for these vehicles.
		Character.Humanoid:ChangeState(Enum.HumanoidStateType.Seated) -- Force Humanoid to Seated state.
	elseif p.Seat:FindFirstChild("Turret") then -- For vehicles with a turret.
		Character.Humanoid.Sit = true -- Set Sit property.
		Character.Humanoid:ChangeState(Enum.HumanoidStateType.Seated)
		delay(0.1, function() -- Small delay to ensure animations are loaded.
			for _, Track in next, Character.Humanoid:GetPlayingAnimationTracks() do
				Track:Stop() -- Stop any default sitting animations.
			end
		end)
	else -- Default seating for most cars.
		Character.Humanoid:ChangeState(Enum.HumanoidStateType.Seated)
	end
	
	-- Play custom sitting animation if available.
	if p.CarSitTrack ~= nil then p.CarSitTrack:Stop(); p.CarSitTrack:Destroy(); p.CarSitTrack = nil end -- Stop and clean up previous animation.
	if p.Seat:FindFirstChild("SitAnim") then -- If a "SitAnim" object is present in the seat.
		local CarSitTrack = Character.Humanoid:LoadAnimation(ReplicatedStorage.Resource.CarSitAnimation) -- Load custom animation.
		CarSitTrack:AdjustSpeed(0) -- Pause the animation at the first frame.
		CarSitTrack:Play() -- Play (and pause) the animation.
		p.CarSitTrack = CarSitTrack -- Store reference to the animation track.
	end

	local Model = p.Model
	CurrentCamera.CameraSubject = Model.Camera -- Set the camera to follow the car's Camera part.
	if not p.Seat:FindFirstChild("Visible") then -- Make player's face invisible for first-person view (if 'Visible' part is not in seat).
		local Head = Character:FindFirstChild("Head")
		if Head and Head:FindFirstChild("face") then Head.face.Transparency = 1 end
	end
	ChassisShared.VehicleMake = p.Make -- Update the shared vehicle make information.

	if IsPassenger then return end -- Passengers don't need driving controls or physics setup.

	-- Reset driving state variables for the driver.
	WASDQE = {0, 0, 0, 0, 0, 0}
	ShouldDrift, ShouldBrake = false, false
	ChassisShared.HandBrake = false
	Autopilot = false
	Sirens = p.PoliceLights -- Initialize sirens based on vehicle's PoliceLights property.
	
	m.UpdateStats(p) -- Calculate mass and forces for the vehicle.

	-- Create physics objects.
	local Rotate = Instance.new("BodyAngularVelocity") -- Used for steering.
	Rotate.AngularVelocity = v3b -- Initialize with no angular velocity.
	Rotate.MaxTorque = v3(p.Mass, math.huge, p.Mass) -- Max torque for rotation around Y-axis (steering).
	Rotate.Parent = Model.Engine -- Parent to the engine part.
	p.Rotate = Rotate -- Store reference.

	-- Initialize vehicle specific state properties.
	p.Traction = 1 -- Initial traction value.
	p.LastForward = 0 -- Last forward direction (1 for forward, -1 for backward).
	p.RotY = 0 -- Current Y-rotation for steering visuals.
	p.WheelRotation = 0 -- Current visual rotation of the wheels.
	p.LastDrift = 0 -- Tick count of the last time a drift occurred.
	p.vHeading = 0 -- Smoothed steering input.
	p.vGrass = 0 -- Smoothed volume for grass sound.
	p.vAsphalt = 0 -- Smoothed volume for asphalt sound.
	p.vSandstone = 0 -- Smoothed volume for sandstone sound.
	p.Gear = 1 -- Current gear (starts in first).
	p.LastGear = 1 -- Last gear.
	p.LastRPM = 0 -- Last calculated RPM.
	p.t3 = 0 -- Transition timer for gear shifts.

	-- Set up inverse kinematics for the player's arms on the steering wheel.
	if p.Make ~= "Volt" then -- Volt might have different controls or no visible steering wheel.
		local IKR = R15IKv2.BuildPacketArms(Character) -- Build an IK packet for the character's arms.
		p.IK = IKR -- Store the IK packet.
	end
	
	-- Start all vehicle sounds.
	p.Sounds.DriftSqueal.Volume = 0 -- Initialize drift squeal volume to 0.
	for _, Sound in next, p.Sounds, nil do -- Iterate through all sound objects in the 'Sounds' folder.
		if not Sound.IsPlaying then
			Sound:Play() -- Play sounds that aren't already playing.
		end
	end
end

-- Called when the local player leaves a vehicle. Cleans up and resets state.
function m.VehicleLeave(p)
	local IsPassenger = p.Passenger
	local Character = LocalPlayer.Character
	if Character then
		CurrentCamera.CameraSubject = Character:FindFirstChild("Humanoid") -- Reset camera subject to the player's Humanoid.
		local Head = Character:FindFirstChild("Head")
		if Head and Head:FindFirstChild("face") then Head.face.Transparency = 0 end -- Make player's face visible again.
	end
	
	-- Stop sitting animation.
	if p.CarSitTrack ~= nil then
		p.CarSitTrack:Stop()
		p.CarSitTrack:Destroy()
		p.CarSitTrack = nil
	end
	
	CurrentCamera.FieldOfView = 70 -- Reset camera FOV to default.
	
	-- Reset and stop all vehicle sounds and environmental sound effects.
	if p.Sounds then
		local Outside = SoundValues.Outside -- Get default "Outside" sound values.
		for Effect, Options in next, SoundOptions, nil do -- Iterate through each sound effect (Echo, Equalizer, Reverb).
			for _, Option in next, Options, nil do -- Iterate through each option for that effect.
				local Value = Outside[Effect][Option] -- Get the default value from the "Outside" preset.
				SoundEffects[Effect][Option] = Value -- Apply the default value to the actual SoundEffect.
			end
		end
		for _, Sound in next, p.Sounds, nil do
			Sound.Volume = 0 -- Set all vehicle specific sounds to 0 volume.
		end
		p.Sounds.DriftSqueal:Stop() -- Stop the drift squeal sound explicitly.
	end
	
	-- Re-enable player controls and place character outside the car.
	if Character then
		SetHumanoidEnabled(Character, true) -- Re-enable all Humanoid states.
		Character.Humanoid:ChangeState(Enum.HumanoidStateType.GettingUp) -- Set Humanoid state to GettingUp for animation.
		local RootPart = Character:FindFirstChild("HumanoidRootPart")
		if RootPart then
			local BoundingBox = p.Model and p.Model:FindFirstChild("BoundingBox") -- Attempt to find a bounding box part.
			if BoundingBox then
				-- Position the character slightly above and outside the bounding box of the car.
				RootPart.CFrame = cf(BoundingBox.Position) + v3(0, BoundingBox.Size.y * 0.5 + 5, 0)
			end
		end
	end
	
	-- Unlock camera if it was locked.
	if p.IsCameraLocked then
		m.UnlockCamera(p)
	end

	if IsPassenger then return end -- Nothing more to do for passengers (e.g., physics objects cleanup).

	-- Clean up physics objects for the driver.
	p.Rotate:Destroy() -- Destroy the BodyAngularVelocity used for steering.
	p.DriveThruster.Force = v3b -- Reset the main driving thruster force.
	for _, Wheel in next, p.Wheels, nil do
		Wheel.Thruster.Force = v3b -- Reset individual wheel thruster forces.
	end
end

--// LOW QUALITY MODE FUNCTIONS //--
-- A simplified wheel update for lower performance settings.
-- This likely sacrifices some visual fidelity or precision for better framerates on less powerful devices.
function m.UpdateWheelLowQuality(Model, Height, Thruster, WheelRotation)
	local Engine = Model.Engine
	local EngineCFrame = Engine.CFrame
	local ThrusterCFrame = Thruster.CFrame
	local ThrusterPosition = ThrusterCFrame.p
	local ThrusterVelocity = Thruster.Velocity
	local Motor = Thruster.Motor
	-- Uses SmartCast (optimized raycast) to find the ground.
	local _, Pos = SmartCast(ThrusterPosition, vtws(ThrusterCFrame, v3d) * Height, workspace.Vehicles, "lq") -- "lq" is an extra argument not typically used in SmartCast, might be a tag.
	local CurrentHeight = (Pos - ThrusterPosition).magnitude -- Distance from thruster to ground.
	-- Calculate wheel offset based on suspension compression.
	local WheelOffset = cf(0, -min(CurrentHeight, Height) + Motor.Part0.Size.y * 0.5, 0)
	local RelativePos = tos(ThrusterCFrame, EngineCFrame)
	if 0 < RelativePos.z then -- Front wheels (check Z-coordinate relative to engine).
		WheelOffset = WheelOffset * cfa(0, Engine.RotVelocity.y * 0.5, 0) -- Apply some rotation based on engine's angular velocity.
	end
	WheelOffset = WheelOffset * cfa(WheelRotation, 0, 0) -- Apply rolling rotation.
	Motor.C1 = WheelOffset -- Update the CFrame of the Motor6D to visually move the wheel.
end

-- A simplified sound update for lower performance settings.
function m.UpdateSoundLowQuality(p, Gears, Velocity)
	if p.EnumMakeId == nil then
		p.EnumMakeId = EnumMake[p.Make] -- Ensure EnumMakeId is set.
	end
	-- Calls UpdateGearsAndRPM with a fixed delta time (0.01666... is roughly 1/60th of a second).
	-- This skips using the actual variable 'dt' for sound updates, potentially simplifying calculations.
	UpdateGearsAndRPM(p, Gears, Velocity.magnitude, -Velocity.z, 0.016666666666666666)
end

--// PHYSICS UPDATE FUNCTIONS //--
local IsNaN = function(n) return n ~= n end -- Helper function to check if a number is NaN (Not-a-Number).

-- This function updates the physics for a single wheel, handling suspension and visual rotation.
local function UpdateThruster(ChassisPacket, WheelData, DeltaTime)
	-- Get all necessary parts and data from the vehicle packet and wheel data.
	local WheelPart = WheelData.Part -- The visual wheel part.
	local VehicleModel = ChassisPacket.Model
	local Engine = VehicleModel.Engine
	local EngineCFrame = Engine.CFrame
	local WheelCFrame = WheelPart.CFrame
	local WheelPosition = WheelCFrame.p
	local WheelVelocity = WheelPart.Velocity -- Velocity of the wheel part.
	local WheelMotor = WheelPart.Motor -- The Motor6D connecting the visual wheel.
	local SuspensionThruster = WheelData.Thruster -- The BodyThruster used for suspension force.
	local VehicleMass = ChassisPacket.Mass
	local SuspensionForce = ChassisPacket.Force
	local WheelPosRelativeToEngine = tos(WheelCFrame, EngineCFrame) -- Wheel position relative to engine (for front/back check).
	local LocalWheelVelocity = vtos(WheelCFrame, WheelVelocity) -- Wheel velocity in its own local space.
	local SuspensionHeight = ChassisPacket.Height + ChassisPacket.GarageSuspensionHeight -- Total suspension travel height.

	-- Raycast down to find the ground.
	local HitPart, HitPosition = SmartCast(WheelPosition, vtws(WheelCFrame, v3d) * SuspensionHeight, workspace.Vehicles) -- Raycast downwards from the wheel.
	local CompressionDistance = (HitPosition - WheelPosition).Magnitude -- Distance from wheel to ground hit.
	
	-- Calculate the vertical offset for the wheel model to simulate suspension compression.
	local WheelYOffset = -min(CompressionDistance, SuspensionHeight) + WheelMotor.Part0.Size.y * 0.5 -- How much the wheel should be compressed visually.
	local LastWheelYOffset = WheelMotor.C1.y -- Get the previous Y offset.
	-- Smoothly interpolate the wheel's visual Y offset to prevent jerky movement.
	local NewWheelCFrame = cf(0, LastWheelYOffset + (WheelYOffset - LastWheelYOffset) * 0.5, 0)

	-- Apply steering rotation to front wheels.
	if 0 < WheelPosRelativeToEngine.z then -- Check if it's a front wheel (positive Z relative to engine).
		-- Apply steering angle and a small rotation based on engine's angular velocity (for a more dynamic look).
		NewWheelCFrame = NewWheelCFrame * cfa(0, ChassisPacket.RotY * 0.4 + Engine.RotVelocity.y * 0.2, 0)
	elseif HitPart and (ShouldDrift or ChassisPacket.Drift) then -- Emit drift particles from back wheels if on ground and drifting.
		local DriftPart = WheelPart.Drift -- Reference to the part where particles are emitted.
		local DriftEmitter = DriftPart.Part0.ParticleEmitter -- The particle emitter.
		DriftEmitter:Emit(2) -- Emit 2 particles.
	end
	
	-- Apply rolling rotation to the wheel.
	NewWheelCFrame = NewWheelCFrame * cfa(ChassisPacket.WheelRotation, 0, 0)

	-- Sanity check to prevent visual glitches from invalid CFrame values (NaNs or excessively large values).
	if NewWheelCFrame.x ~= NewWheelCFrame.x or NewWheelCFrame.y ~= NewWheelCFrame.y or NewWheelCFrame.z ~= NewWheelCFrame.z or abs(NewWheelCFrame.x + NewWheelCFrame.y + NewWheelCFrame.z) > 100 then
		NewWheelCFrame = cfb -- Reset to identity CFrame if invalid.
	end
	WheelMotor.C1 = NewWheelCFrame -- Update the visual wheel's CFrame relative to its attachment.

	-- If the wheel is on the ground, calculate and apply suspension force.
	if HitPart then
		local DampingForce = LocalWheelVelocity * ChassisPacket.Damping -- Damping force opposes vertical velocity.
		local MaxForce, MinForce = VehicleMass * 0.5, -VehicleMass * 0.5 -- Clamp suspension force to a reasonable range.
		-- Calculate spring force based on compression. The force increases with squared compression.
		local UpwardForce = (SuspensionHeight - min(CompressionDistance, SuspensionHeight)) ^ 2 * (SuspensionForce / SuspensionHeight ^ 2)
		if LocalWheelVelocity.magnitude > 0.01 then
			UpwardForce = UpwardForce - DampingForce.y -- Apply damping to reduce bounciness.
		end
		if UpwardForce ~= UpwardForce then UpwardForce = 0 end -- NaN check.

		UpwardForce = max(MinForce, min(MaxForce, UpwardForce)) -- Clamp the force to min/max.
		
		-- Scale force based on physics step time to ensure consistency across different framerates.
		local TimeScale = 1
		if DeltaTime <= 0.025 then TimeScale = 0.016666666666666666 / DeltaTime end -- Adjust for smaller delta times.
		if TimeScale ~= TimeScale then TimeScale = 0 end -- NaN check.
		TimeScale = math.clamp(TimeScale, 0, 1) -- Clamp time scale between 0 and 1.

		SuspensionThruster.Force = v3(0, UpwardForce * TimeScale, 0) -- Apply the calculated upward force.
	else
		-- No force if the wheel is in the air.
		SuspensionThruster.Force = v3b -- Set thruster force to zero.
	end
end

-- A specialized raycast that only hits 'Concrete' material, used for autopilot lane detection.
local function BetterCast(Origin, Direction, IgnoreList)
	local Length = Direction.magnitude
	Direction = Direction.unit
	local Position = Origin
	local Traveled = 0
	local Ignored = {IgnoreList}
	local Hit, Pos, Normal = nil, v3b, v3b
	local Attempts = 0
	local CanCollide
	repeat
		Attempts = Attempts + 1
		local r = RayNew(Position, Direction * (Length - Traveled))
		Hit, Pos, Normal = fporwil(workspace, r, Ignored, false, true)
		-- The key difference: checks for a specific material (Concrete).
		CanCollide = Hit and Hit.CanCollide and Hit.Material == Enum.Material.Concrete
		if not CanCollide then
			table.insert(Ignored, Hit)
		end
		Traveled = (Origin - Pos).magnitude
		Position = Pos
	until CanCollide or Length - Traveled <= 0.001 or Attempts > 4
	if not Hit then
		Pos, Normal = Origin + Direction * Length, v3d
	end
	return Hit, Pos, Normal
end

-- Sound IDs for tire events.
local TireSounds = {
	tire_pop = 4534995816, -- Roblox asset ID for tire pop sound.
	tire_leak = 4534995685 -- Roblox asset ID for tire leak sound.
}
local UpVector = Vector3.new(0, 1, 0) -- Convenient reference for the up direction.

-- Main physics update function, called every frame before the physics step (Heartbeat).
-- This is where most of the vehicle's driving logic resides.
function m.UpdatePrePhysics(p, dt)
	local Model = p.Model
	local Engine = Model:FindFirstChild("Engine") -- The main part representing the car's body/center of mass.
	if not Engine then return end -- Exit if the engine part is not found (car might be unloaded or error).
	
	-- Get current vehicle state.
	local EngineCFrame = Engine.CFrame
	local EngineHalfSize = Engine.Size * 0.5
	local Rotate = p.Rotate -- BodyAngularVelocity for steering.
	local Height = p.Height -- Suspension height.
	local Mass = p.Mass -- Total vehicle mass.
	local TurnSpeed = p.TurnSpeed -- How quickly the car turns.
	local Make = p.EnumMakeId -- Vehicle make/brand.
	local LocalVelocity = vtos(EngineCFrame, Engine.Velocity) -- Velocity relative to the car's own orientation (forward/sideways).
	local Speed = LocalVelocity.Magnitude -- Absolute speed of the car.

	-- Get player input.
	local Forward, Heading = WASDQE[1] - WASDQE[3], WASDQE[2] - WASDQE[4] -- Calculate combined forward/backward and left/right input.
	if UserInputService.TouchEnabled then -- Handle mobile input (touch screen).
		local Character = LocalPlayer.Character
		if Character then
			local Humanoid = Character:FindFirstChild("Humanoid")
			if Humanoid then
				local MoveVector = GetMoveVector() -- Get movement vector from mobile joystick.
				local MoveX, MoveZ = math.clamp(MoveVector.x, -1, 1), math.clamp(MoveVector.z, -1, 1) -- Clamp values.
				Forward = -MoveZ * abs(MoveZ) -- Use squared input for more sensitivity at higher inputs.
				Heading = -MoveX * abs(MoveX)
			end
		end
	end
	
	if p.LockMovement then Forward, Heading = 0, 0 end -- Lock controls if the vehicle state dictates it.

	-- Autopilot logic.
	if Autopilot then
		local RightVector = EngineCFrame.lookVector:Cross(v3(0, 1, 0)) -- Calculate the vehicle's right vector.
		-- Cast down ahead of the car to find the road (Concrete material).
		local RoadPart, RoadPosition = BetterCast(EngineCFrame * v3(0, 0, -EngineHalfSize.z - abs(LocalVelocity.z) * 16 * dt), v3(0, -1, 0) * 10, Model)
		if RoadPart then
			-- Calculate the target position in the center of the current lane.
			local EnginePosInRoadSpace = tos(RoadPart.CFrame, EngineCFrame) -- Car's position relative to the road part.
			local LaneIndex = math.floor((EnginePosInRoadSpace.x + RoadPart.Size.x * 0.5) / 12) -- Determine which lane the car is in (assuming 12-stud wide lanes).
			local LaneCenterX = -RoadPart.Size.x * 0.5 + LaneIndex * 12 + 6 -- Calculate the center X position of that lane.
			local RoadDirection = 0 < EngineCFrame.lookVector:Dot(RoadPart.CFrame.lookVector) and 1 or -1 -- Determine if car is facing same direction as road.
			local TargetPosition = RoadPart.CFrame * v3(LaneCenterX, 0, -RoadPart.Size.z * 0.5 * RoadDirection) -- Target position in world space.
			
			-- Calculate steering and throttle corrections to stay in the lane.
			local CorrectionVector = (TargetPosition - EngineCFrame.p).unit:Dot(RightVector) -- How far off center the car is laterally.
			local SteeringCorrection = math.clamp(CorrectionVector * 4, -1, 1) -- Steering input to correct lateral position.
			Heading = Heading - SteeringCorrection -- Apply steering correction.
			local ForwardCorrection = 1 - abs(CorrectionVector) ^ (1 / 6) -- Forward thrust correction (reduces if off-center).
			Forward = Forward + ForwardCorrection - abs(CorrectionVector) ^ 4 * 0.3 -- Apply forward thrust and add a penalty for being too off-center.
			Heading = math.clamp(Heading, -1, 1) -- Clamp final heading and forward inputs.
			Forward = math.clamp(Forward, -1, 1)
		end
	end

	-- Smooth the steering input.
	local RHeading = 0.16 -- Smoothing factor.
	local VHeading = p.vHeading -- Current smoothed heading.
	VHeading = VHeading + Heading - VHeading * (Heading == 0 and 0.3 or RHeading) -- Exponential smoothing.
	p.vHeading = VHeading
	VHeading = VHeading * RHeading -- Apply smoothing.

	-- Tire popping logic.
	local CoefDrag, CoefRolling, CoefBrake = p.Cd, p.Crr, p.Cb -- Drag, rolling resistance, and braking coefficients.
	local PopForce -- Force applied when tires are popped.
	local TirePopDuration, TirePopProportion = p.TirePopDuration, p.TirePopProportion -- Configurable parameters for tire pop.
	local TiresLastPop = p.TiresLastPop -- Table storing when each tire last popped.
	local CurrentTime = Time.GetNowSync() -- Current synced game time.
	-- Calculate health of each tire (0 to 1), where 1 means healthy.
	local TireBackLeft = min((CurrentTime - TiresLastPop[1]) / TirePopDuration, 1)
	local TireBackRight = min((CurrentTime - TiresLastPop[2]) / TirePopDuration, 1)
	local TireFrontLeft = min((CurrentTime - TiresLastPop[3]) / TirePopDuration, 1)
	local TireFrontRight = min((CurrentTime - TiresLastPop[4]) / TirePopDuration, 1)
	local AvgTireHealth = (TireBackLeft + TireBackRight + TireFrontLeft + TireFrontRight) / 4 -- Average tire health.
	local AreTiresPopped = AvgTireHealth < 0.999 -- True if average health is very low (tires are considered popped).
	
	if AreTiresPopped then
		-- Apply a braking/drag force if tires are popped.
		local PopEffectiveness = (AvgTireHealth < TirePopProportion) and 0 or (AvgTireHealth - TirePopProportion) / (1 - TirePopProportion) -- Effectiveness of the pop effect.
		PopForce = Mass * ((v3b - LocalVelocity) / ((1 - PopEffectiveness) * 200 + PopEffectiveness * 500)) -- Drag force proportional to mass and velocity.
		Forward = 0 -- No forward input when tires are popped.
		if Speed > 30 then p.LastDrift = tick() end -- Force a drift state if speed is high.
	end
	
	-- Handle sound and visuals for popped tires.
	if p.AreTiresPopped ~= AreTiresPopped then -- If tire pop state changed.
		if AreTiresPopped then
			Audio.ObjectLocal(Engine, TireSounds.tire_pop, {Volume = 1}) -- Play pop sound.
			Audio.ObjectLocal(Engine, TireSounds.tire_leak, {Volume = 1}) -- Play leak sound.
		end
		m.SetWheelsVisible(p, not AreTiresPopped) -- Hide wheels if popped.
		p.AreTiresPopped = AreTiresPopped -- Update the stored state.
	end

	-- Drifting logic.
	if Heading ~= 0 then -- If steering input is given.
		local TurnDirection = Heading / abs(Heading) -- Direction of turn (-1 or 1).
		local LateralVelDirection = LocalVelocity.x / abs(LocalVelocity.x) -- Direction of lateral velocity.
		-- Start drift if turning sharply against lateral velocity and lateral speed is high.
		if TurnDirection ~= LateralVelDirection and abs(LocalVelocity.x) > 8 then
			p.LastDrift = tick() -- Record time of drift.
		end
	end
	local IsDrifting = 0.3 > tick() - p.LastDrift -- A drift is active for 0.3 seconds after LastDrift.
	if Make == EnumMake.Volt then IsDrifting, ShouldDrift = false, false end -- Volts (electric cars) can't drift.
	p.Drift = IsDrifting -- Store drift state.
	
	-- Update drift sound volume.
	local TargetDriftVolume = 0
	local CurrentDriftVolume = p.Sounds.DriftSqueal.Volume
	if Speed > 30 and (IsDrifting or ShouldDrift and Heading ~= 0) then -- Only play drift sound if speed is high and drifting or forcing drift.
		TargetDriftVolume = 0.3
		CurrentDriftVolume = CurrentDriftVolume + (TargetDriftVolume - CurrentDriftVolume) * 0.06 -- Smoothly increase volume.
	else
		CurrentDriftVolume = CurrentDriftVolume + (TargetDriftVolume - CurrentDriftVolume) * 0.1 -- Smoothly decrease volume.
	end
	p.Sounds.DriftSqueal.Volume = CurrentDriftVolume

	m.UpdateForces(p, dt) -- Update wheel suspension forces (calls UpdateThruster for each wheel).

	-- Update visual wheel rotation.
	local WheelRotationDelta = LocalVelocity.z * dt -- Distance traveled along the forward axis.
	if WheelRotationDelta ~= WheelRotationDelta then WheelRotationDelta = 0 end -- NaN check.
	local MWheelRotation = p.WheelRotation
	MWheelRotation = (MWheelRotation + WheelRotationDelta / (Model.WheelFrontRight.Wheel.Size.y * 0.5)) % (2 * math.pi) -- Add to current rotation, normalizing by wheel radius.
	p.WheelRotation = MWheelRotation

	-- Update traction based on drift state and speed.
	local TractionSpeedFactor = tanh(abs(LocalVelocity.magnitude) * 0.03) -- Traction decreases with speed.
	local mTraction = p.Traction
	local vTraction = (ShouldDrift or IsDrifting) and (1 - TractionSpeedFactor) ^ 2 or 1 -- Reduce traction significantly when drifting.
	if game:GetService("Lighting"):FindFirstChild("IsRaining") then vTraction = vTraction * 0.4 end -- Less traction in rain.
	vTraction = max(vTraction, 0.07) -- Minimum traction value.
	local rTraction = mTraction > vTraction and 0.2 or 0.01 -- Smoothing rate for traction.
	mTraction = mTraction + (vTraction - mTraction) * rTraction -- Smoothly transition traction.
	p.Traction = mTraction

	-- Update gears and RPM.
	local CurrentGear, CurrentGearRatio = UpdateGearsAndRPM(p, p.Gears, Speed, Forward, dt)
	
	-- Update camera Field of View (FOV) for a sense of speed.
	do
		local EffectiveGearRatio = p.NoGears and 1 or CurrentGearRatio
		local FOVSpeedEffect = EffectiveGearRatio ^ 0.5 * (Speed / 120) -- Calculate FOV effect based on gear ratio and speed.
		if IsNaN(FOVSpeedEffect) then FOVSpeedEffect = 0 end
		FOVSpeedEffect = math.clamp(FOVSpeedEffect, 0, 3)
		local FieldOfView = FOVSpeedEffect < 0.825155 and FOVSpeedEffect ^ 3 or 1 - exp(-FOVSpeedEffect) -- Non-linear curve for FOV.
		FieldOfView = FieldOfView * 30 + 70 -- Scale to a range (70-100).
		local MFieldOfView = CurrentCamera.FieldOfView
		FieldOfView = MFieldOfView + (FieldOfView - MFieldOfView) * 0.7 -- Smooth transition for FOV.
		CurrentCamera.FieldOfView = FieldOfView
	end

	-- Check what surface the car is on.
	local OnTerrain, _, _, Mat = SmartCast(EngineCFrame * v3(0, 0, EngineHalfSize.z - 1), vtws(EngineCFrame, v3(0, -1, 0)) * Height * 2, Model)
	
	-- Calculate driving forces.
	local Power = (Make == EnumMake.Bugatti or Make == EnumMake.Torpedo or Make == EnumMake.Firetruck) and 650 or (Make == EnumMake.Lamborghini or Make == EnumMake.MoltenM12 or Make == EnumMake.Revuelto) and 400 or 120 -- Base power based on car make.
	local DragForce = -CoefDrag * LocalVelocity * Speed * v3(Power * mTraction, 0, Forward < 0 and 80 or 1) -- Air resistance/drag.
	local RollingResistance = -CoefRolling * LocalVelocity * v3(Power * mTraction, 0, 1) -- Rolling friction.
	if Make == EnumMake.ATV and abs(RollingResistance.x) > Mass * 0.05 then
		-- Special case for ATVs to limit lateral rolling resistance.
		RollingResistance = Vector3.new(math.clamp(RollingResistance.x, -Mass * 0.05, Mass * 0.05), 0, RollingResistance.z)
	end
	local BrakingPower = -(CoefBrake * (1 + p.GarageBrakes)) * LocalVelocity.z / abs(LocalVelocity.z) -- Braking power.
	if BrakingPower ~= BrakingPower then BrakingPower = 0 end -- NaN check.
	local ForwardForce = BrakingPower * v3(0, 0, 1) -- Braking force applied in the forward/backward direction.
	local BrakingForce = -CoefBrake * 0.3 * LocalVelocity * v3(1, 0, 0) -- Lateral braking force (for skidding).

	-- Nitro (NOS) logic.
	local IsNitroActive = p.Nitro -- Check if nitro is active.
	local NitroForce = (IsNitroActive and 0.17 * Mass or 0) * v3(0, -0.1, -1) -- Downward and backward force for nitro.
	if IsNitroActive and not p.Nitrof1 then
		p.Nitrof1 = true
		m.SetGravity(p, 20) -- Apply more downforce during nitro for better grip.
	elseif not IsNitroActive and p.Nitrof1 then
		p.Nitrof1 = false
		m.SetGravity(p, 100) -- Reset gravity when nitro is off.
	end

	-- Calculate engine thrust.
	local EngineThrust
	local EngineForce = Forward * v3(0, 0, -1) * p.Gears[1] * 1 / 0.34 * 750 -- Base engine force.
	local EffectiveGearRatio
	if p.NoGears then -- For vehicles without traditional gears (e.g., electric).
		EffectiveGearRatio = Forward > 0 and p.Gears[1] or p.Gears[2] -- Use forward or reverse ratios.
	else
		EffectiveGearRatio = Forward > 0 and p.Gears[2 + CurrentGear] or p.Gears[2] -- Use current gear ratio or reverse ratio.
	end
	-- Different power multipliers for different cars and upgrades.
	local EnginePowerMultiplier = 4.4
	if Make == EnumMake.Lamborghini or Make == EnumMake.Ferrari then EnginePowerMultiplier = 6.5
	elseif Make == EnumMake.MoltenM12 then EnginePowerMultiplier = 8.2
	elseif Make == EnumMake.Bugatti then EnginePowerMultiplier = 8
	elseif Make == EnumMake.Model3 then EnginePowerMultiplier = 4.2
	elseif Make == EnumMake.Monster then EnginePowerMultiplier = 5
	elseif Make == EnumMake.Roadster then EnginePowerMultiplier = 9
	elseif Make == EnumMake.Firetruck then EnginePowerMultiplier = 10
	elseif Make == EnumMake.ATV then EnginePowerMultiplier = 1.5 end
	EnginePowerMultiplier = EnginePowerMultiplier + p.GarageEngineSpeed -- Add engine upgrade bonus.
	if p.GarageSpoilerSpeed then EnginePowerMultiplier = EnginePowerMultiplier + 0.5 end -- Add spoiler upgrade bonus.
	EngineThrust = EngineForce * EffectiveGearRatio * EnginePowerMultiplier -- Final engine thrust.
	
	-- Reduce thrust in water.
	do
		local _, _, _, WaterMaterial = workspace:FindPartOnRay(Ray.new(EngineCFrame.p + UpVector * 10, UpVector * -20), Model)
		if WaterMaterial and WaterMaterial == Enum.Material.Water then
			EngineThrust = EngineThrust * 0.625 -- Significantly reduce thrust in water.
		end
	end

	-- Sum up all forces.
	local ThrustForce = DragForce + RollingResistance -- Combine drag and rolling resistance.
	if Forward ~= 0 and Forward == Forward then -- If there's active forward/backward input.
		ThrustForce = ThrustForce + EngineThrust -- Add engine thrust.
		p.LastForward = Forward / abs(Forward) -- Store last forward direction.
	end
	if Forward == 0 then -- If no forward/backward input.
		if Speed <= 1 then
			Engine.Velocity = v3b -- Full stop at very low speeds.
		else
			ThrustForce = ThrustForce + ForwardForce -- Apply brakes.
		end
	end
	if ShouldDrift and Heading == 0 and Forward == 0 then -- Handbrake turn without other inputs.
		ThrustForce = ThrustForce + ForwardForce * 3 -- Stronger forward braking.
		ThrustForce = ThrustForce + BrakingForce -- Add lateral braking.
	end

	-- Update terrain sounds based on surface material.
	local GrassRatio, AsphaltRatio, SandstoneRatio = 0, 0, 0
	local RotY = p.RotY
	RotY = RotY + (Heading - RotY) * 0.1 -- Smooth steering visual rotation.
	p.RotY = RotY
	
	if OnTerrain then -- If the car is on a surface.
		p.LastMaterial = Mat -- Store the material.
		if Mat == Enum.Material.Grass then GrassRatio = 0.4
		elseif Mat == Enum.Material.Concrete or Mat == Enum.Material.Basalt or Mat == Enum.Material.Asphalt then AsphaltRatio = 0.94
		elseif Mat == Enum.Material.Sandstone or Mat == Enum.Material.Sand then SandstoneRatio = 0.5 end
		
		-- Calculate steering force.
		local SteeringFactor = exp(-max(LocalVelocity.magnitude, 120) / 400) * (ShouldDrift and 1.5 or 1.2) -- Steering effectiveness decreases with speed, increased by drift.
		local ForwardDirection = -LocalVelocity.z / abs(LocalVelocity.z) -- Current forward direction based on velocity.
		if ForwardDirection ~= ForwardDirection then ForwardDirection = 0 end -- NaN check.
		if p.LastForward ~= ForwardDirection and 2 < abs(LocalVelocity.z) and not ShouldDrift then
			p.LastForward = ForwardDirection -- Update last forward direction.
		end
		if Heading ~= 0 then
			Rotate.MaxTorque = v3(0, p.Mass * 30, 0) -- High torque for active steering.
		elseif LocalVelocity.z < 0 and not ShouldDrift then -- When reversing and not drifting.
			Rotate.MaxTorque = v3(0, p.Mass * 2, 0) -- Reduced steering torque.
		end
		-- Apply angular velocity for steering.
		Rotate.AngularVelocity = v3(0, VHeading * TurnSpeed * p.LastForward * SteeringFactor * TractionSpeedFactor, 0)
	else
		-- If in the air, disable driving forces and reduce rotation torque.
		ThrustForce = v3b
		Rotate.MaxTorque = v3(p.Mass * 0.5, p.Mass, p.Mass * 0.5) -- Allow some limited rotation in air.
	end
	
	ThrustForce = ThrustForce + NitroForce -- Add nitro force.
	if PopForce ~= nil then
		ThrustForce = ThrustForce + PopForce -- Add tire pop force.
	end

	-- Update terrain sound volumes and pitches.
	do
		local Grass, Asphalt, Sandstone = p.Sounds.Grass, p.Sounds.Asphalt, p.Sounds.Sandstone
		p.vGrass = p.vGrass + (GrassRatio - p.vGrass) * 0.03 -- Smoothly interpolate grass volume.
		p.vAsphalt = p.vAsphalt + (AsphaltRatio - p.vAsphalt) * 0.03 -- Smoothly interpolate asphalt volume.
		p.vSandstone = p.vSandstone + (SandstoneRatio - p.vSandstone) * 0.03 -- Smoothly interpolate sandstone volume.
		local Volume = min(Speed / 60, 1) * 0.7 -- Volume scales with speed.
		Grass.Volume = p.vGrass * Volume
		Asphalt.Volume = p.vAsphalt * Volume
		Sandstone.Volume = p.vSandstone * Volume
		local Pitch = Speed > 0 and (Speed / 120) ^ 0.5 or 0 -- Pitch scales with speed.
		Grass.PlaybackSpeed = Pitch
		Asphalt.PlaybackSpeed = Pitch
		Sandstone.PlaybackSpeed = Pitch
	end

	-- Update headlights.
	for _, v in next, p.Model.Model:GetChildren() do
		if v.Name == "Headlights" then
			local Enabled = Lights -- Controlled by the 'Lights' toggle.
			v.Material = Enabled and Enum.Material.Neon or Enum.Material.Plastic -- Change material for glowing effect.
			v.SpotLight.Enabled = Enabled -- Enable/disable the spotlight.
		end
	end
	-- Update brakelights.
	local Brakelights = Model.Model:FindFirstChild("Brakelights")
	if Brakelights then
		local Enabled = ShouldDrift or Forward < 1.0E-6 -- Enabled when drifting or braking (forward input is near zero or negative).
		Brakelights.Material = Enabled and Enum.Material.Neon or Enum.Material.Plastic
		Brakelights.SpotLight.Enabled = Enabled
	end

	p.DriveThruster.Force = ThrustForce -- Apply the final calculated driving force to the main thruster.

	-- Update IK for steering wheel (player's arms).
	if p.IK then
		local SteeringRotation = 0.6 * p.RotY -- Calculate steering wheel rotation based on car's Y rotation.
		p.WeldSteer.C0 = cfa(0, SteeringRotation, 0) -- Apply rotation to the steering wheel's weld.
		local SteerCFrame = Model.Steer.CFrame
		local SteerHalfWidth = Model.Steer.Size.x * 0.5 - 0.2
		local IKPacket = p.IK -- Get the IK packet.
		-- Set target positions for the left and right arms based on the steering wheel's position and size.
		IKPacket.RightArm = SteerCFrame * v3(SteerHalfWidth, 0.1, 0)
		IKPacket.LeftArm = SteerCFrame * v3(-SteerHalfWidth, 0.1, 0)
		-- Set target angles for the arms to simulate gripping and turning the wheel.
		IKPacket.RightAngle = -SteeringRotation - 0.6
		IKPacket.LeftAngle = -SteeringRotation + 0.6
		R15IKv2.Arms(IKPacket) -- Apply IK to move the character's arms.
	end
	
	-- Vehicle flip detection.
	local _, _, _, _, _, _, _, VehicleYRotation = EngineCFrame:components() -- Get rotation components from engine CFrame.
	if VehicleYRotation < -0.25 then -- Is the car significantly upside down (Y rotation indicates upside down)?
		if not p.UpsideDownTime then
			p.UpsideDownTime = tick() -- Start timer when first detected as upside down.
		elseif 2 < tick() - p.UpsideDownTime then -- If upside down for more than 2 seconds, flip it.
			p.UpsideDownTime = nil
			Event:FireServer("VehicleFlip", Model) -- Request server to flip the vehicle.
		end
	else
		p.UpsideDownTime = nil -- Reset timer if not upside down.
	end
	
	-- Environmental sound logic (City, Tunnel, Outside).
	local CityEnv
	if not IsStudio or IsStudio and Settings.Test.RegionSounds then -- Only check region sounds if not in Studio (or if specifically enabled for testing).
		local Prism = Settings.Prism.City -- Get the definition of the city region.
		if Region.CastPoint(Prism, Engine.Position) then -- Check if the car is within the city region.
			CityEnv = "City"
		end
	end
	-- Check if inside a tunnel by casting upwards.
	local Hit, Pos = SmartCast(EngineCFrame * v3(0, 0, EngineHalfSize.z - 1), vtws(EngineCFrame, v3(0, 1, 0)) * 20, Model) -- Cast ray upwards.
	local LastEnvironment = Hit and "Tunnel" or CityEnv or "Outside" -- Determine current environment.

	-- If the environment changed, start a transition.
	if p.LastEnvironment ~= LastEnvironment then
		local TransitionTime = (LastEnvironment == "Tunnel" or p.LastEnvironment == "Tunnel") and 0.5 or 4 -- Faster transition for tunnels.
		p.TransitionSpeed = 1 / TransitionTime -- Speed of the transition.
		p.EnvironmentTransition = true -- Flag to indicate transition is active.
		p.LastEnvironment = LastEnvironment -- Update last environment.
		Transition = 0 -- Reset transition progress.
		-- Store the starting values for the transition for each sound effect.
		for EffectName, EffectOptions in next, SoundOptions, nil do
			p[EffectName] = {}
			for _, OptionName in next, EffectOptions, nil do
				p[EffectName][OptionName] = SoundEffects[EffectName][OptionName]
			end
		end
	end
	
	-- Linearly interpolate sound properties during the transition.
	if p.EnvironmentTransition then
		local Values = SoundValues[LastEnvironment] -- Get target sound values for the new environment.
		Transition = Transition + dt * p.TransitionSpeed -- Increment transition progress.
		for Effect, Options in next, SoundOptions, nil do
			for _, Option in next, Options, nil do
				local Last = p[Effect][Option] -- Starting value.
				local Value = Values[Effect][Option] -- Target value.
				SoundEffects[Effect][Option] = Last * (1 - Transition) + Value * Transition -- Linear interpolation.
			end
		end
		if Transition >= 1 then
			p.EnvironmentTransition = false -- End transition when progress reaches 1.
		end
	end
end

-- Calls the individual wheel update function for all four wheels.
function m.UpdateForces(p, dt)
	local Wheels = p.Wheels -- Get the table of wheel data.
	UpdateThruster(p, Wheels.WheelFrontRight, dt) -- Update front right wheel.
	UpdateThruster(p, Wheels.WheelFrontLeft, dt) -- Update front left wheel.
	UpdateThruster(p, Wheels.WheelBackRight, dt) -- Update back right wheel.
	UpdateThruster(p, Wheels.WheelBackLeft, dt) -- Update back left wheel.
end

-- Called every frame after the physics step (RenderStepped).
-- Used for visual updates or resetting forces that should not persist.
function m.UpdatePostPhysics(p, dt)
	-- Reset thruster forces to prevent them from carrying over to the next frame.
	-- This is crucial because BodyThrust forces are persistent if not explicitly reset.
	local Wheels = p.Wheels
	for _, Wheel in next, p.Wheels, nil do
		Wheel.Thruster.Force = v3b -- Set each wheel's thruster force to zero.
	end
end

-- Halts all vehicle movement immediately.
function m.Halt(p)
	p.DriveThruster.Force = v3b -- Set main driving force to zero.
	p.Rotate.MaxTorque = v3b -- Set steering torque to zero.
end

--// VISUAL & STATE FUNCTIONS //--
-- Toggles the visibility of the wheel models. Used for popped tires.
function m.SetWheelsVisible(p, Visible)
	local Model = p.Model
	for _, Wheel in ipairs({ "WheelFrontRight", "WheelFrontLeft", "WheelBackRight", "WheelBackLeft" }) do
		assert(Model:FindFirstChild(Wheel)).Wheel.Transparency = Visible and 0 or 1 -- Set transparency: 0 for visible, 1 for invisible.
	end
end

-- Sets the pop time for all tires to a specific value.
-- This is used to simulate all tires popping simultaneously or being repaired.
function m.SetTiresPoppedAt(p, t)
	p.TiresLastPop[1] = t
	p.TiresLastPop[2] = t
	p.TiresLastPop[3] = t
	p.TiresLastPop[4] = t
end

--// CAMERA CONTROL //--
-- Locks the camera to a fixed first-person perspective inside the car.
function m.LockCamera(p)
	assert(not p.IsCameraLocked) -- Assert that camera is not already locked.
	local InsideCamera = p.Model:FindFirstChild("InsideCamera") -- Find the designated camera part inside the car.
	if InsideCamera == nil then return false end -- If not found, cannot lock camera.

	p.IsCameraLocked = true -- Set locked flag.
	CurrentCamera.CameraType = Enum.CameraType.Scriptable -- Change camera type to allow script control.
	-- On every frame, force the camera's CFrame to match the fixed camera part.
	p.CameraLockRenderStepped = RunService.RenderStepped:Connect(function()
		CurrentCamera.CFrame = InsideCamera.CFrame -- Constantly update camera CFrame.
	end)
end

-- Unlocks the camera, returning it to the default follow behavior.
function m.UnlockCamera(p)
	assert(p.IsCameraLocked) -- Assert that camera is currently locked.
	p.IsCameraLocked = false -- Unset locked flag.
	CurrentCamera.CameraType = Enum.CameraType.Custom -- Revert camera type to default.
	p.CameraLockRenderStepped:Disconnect() -- Disconnect the RenderStepped connection to stop forcing CFrame.
	p.CameraLockRenderStepped = nil -- Clear the connection.
end

--// INPUT HANDLING //--
-- Lookup table to map KeyCodes to indices in the WASDQE state table.
-- This allows mapping different keys/buttons to the same logical input.
local InputLookup = {
	[Enum.KeyCode.W] = 1, [Enum.KeyCode.A] = 2, [Enum.KeyCode.S] = 3, [Enum.KeyCode.D] = 4, [Enum.KeyCode.Q] = 5, [Enum.KeyCode.E] = 6,
	[Enum.KeyCode.ButtonR2] = 1, [Enum.KeyCode.ButtonL2] = 3, -- Gamepad triggers for forward/backward.
	[Enum.KeyCode.Up] = 1, [Enum.KeyCode.Left] = 2, [Enum.KeyCode.Down] = 3, [Enum.KeyCode.Right] = 4 -- Arrow keys.
}

-- Called when a keyboard key is pressed.
function m.InputBegan(i)
	if i.UserInputType == Enum.UserInputType.Keyboard then
		local k = i.KeyCode
		if InputLookup[k] then WASDQE[InputLookup[k]] = 1 end -- Set input state to 1 (pressed).
	end
end

-- Called when a keyboard key or gamepad trigger is released.
function m.InputEnded(i)
	if i.UserInputType == Enum.UserInputType.Keyboard then
		local k = i.KeyCode
		if InputLookup[k] then WASDQE[InputLookup[k]] = 0 end -- Set input state to 0 (released).
	elseif i.UserInputType == Enum.UserInputType.Gamepad1 then
		local k = i.KeyCode
		if k == Enum.KeyCode.ButtonR2 or k == Enum.KeyCode.ButtonL2 then
			WASDQE[InputLookup[k]] = 0 -- Release analog triggers.
		end
	end
end

-- Called when a gamepad thumbstick or trigger changes.
function m.InputChanged(i)
	if i.UserInputType == Enum.UserInputType.Gamepad1 then
		local k = i.KeyCode
		if k == Enum.KeyCode.Thumbstick1 then -- Steering (left thumbstick).
			local v = i.Position -- Get the X, Y, Z position of the thumbstick (X for horizontal, Y for vertical).
			local x, y = v.x, v.y
			local th = 0.24 -- Deadzone: ignore small movements near center.
			WASDQE[2] = x < -th and (-x) ^ 2 or 0 -- Apply squared input for left turn.
			WASDQE[4] = x > th and x ^ 2 or 0 -- Apply squared input for right turn.
		elseif k == Enum.KeyCode.ButtonR2 or k == Enum.KeyCode.ButtonL2 then -- Analog throttle/brake.
			local v = i.Position
			local z = v.z -- Get the Z position, which typically represents trigger pressure.
			local th = 0.05 -- Deadzone.
			WASDQE[InputLookup[k]] = z > th and z ^ 0.5 or 0 -- Use square root for a better, less sensitive curve at low pressures.
		end
	end
end

--// INITIALIZATION //--
-- Function to allow the main vehicle script to pass in the server communication event.
function m.SetEvent(n)
	Event = n -- Assign the RemoteEvent for server communication.
end

-- This block handles interactions with special vehicle parts, like firetruck ladders.
do
	local CircleAction = UI.CircleAction -- Reference to a UI module function for interactive prompts.
	-- Callback function for the interaction.
	local function Callback(Spec, Processed)
		if Processed then
			Event:FireServer("ToggleLadder", Spec.Part) -- Tell the server to toggle the ladder.
		end
		return true
	end
	-- Function to add the interaction prompt to a part.
	local function AddedFun(Part)
		local Spec = {
			Part = Part,
			Name = "Toggle Ladder",
			NoRay = true, -- Does not require raycasting to activate (always visible).
			Timed = true, -- Requires holding down for a duration.
			Duration = 0.5, -- Hold duration.
			Dist = 10, -- Max distance from player to activate.
			Callback = Callback -- Function to call when activated.
		}
		CircleAction.Add(Spec, Part) -- Add the interactive prompt to the part.
	end
	-- Function to remove the interaction prompt.
	local function RemovedFun(Part)
		CircleAction.Remove(Part)
	end
	
	-- Connect to CollectionService to detect all parts tagged as "Firetruck_Ladder".
	-- This ensures that ladders are automatically interactive when added to the game.
	for _, v in next, CollectionService:GetTagged("Firetruck_Ladder") do
		AddedFun(v) -- Add interaction to existing tagged ladders.
	end
	CollectionService:GetInstanceAddedSignal("Firetruck_Ladder"):Connect(AddedFun) -- Connect to add interaction for new ladders.
	CollectionService:GetInstanceRemovedSignal("Firetruck_Ladder"):Connect(RemovedFun) -- Connect to remove interaction for removed ladders.
end

return m -- Return the module table containing all chassis control functions