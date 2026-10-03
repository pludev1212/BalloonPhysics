-- discord: oldwatchnewtime (pluto) | roblox: yourplut_o | github: pludev1212
-- balloon service, the core of balloon range (a small physics sandbox based on my game shoot a balloon)
-- Bootstrap requires every module in Server/Services and calls Start on it. tuning comes from
-- Shared/Config/RangeConfig, points go through ScoreService, and every part cloned here is a template in
-- ServerStorage.Assets. balloons float on a vectorforce and get pushed around by a noise wind field,
-- clicking one makes the server throw a dart at where that balloon is going to be. the dart runs its own
-- ballistic sim with spherecasts and pops whatever it hits first, bombs pop the balloons close to them and
-- shove the rest

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Config = require(ReplicatedStorage.Shared.Config.RangeConfig)
local ScoreService = require(script.Parent.ScoreService)

local assets = ServerStorage.Assets
local range = workspace.Map.Range
local balloonFolder = workspace.Runtime.Balloons
local dartFolder = workspace.Runtime.Darts
local debrisFolder = workspace.Runtime.Debris

local wind = Config.Wind
local dartSettings = Config.Dart
local bomb = Config.Bomb
local shards = Config.Shards

local shardFade = TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

-- the top face of the range part is the spawn floor, so moving or turning the part in studio moves everything
local rangeCFrame = range.CFrame * CFrame.new(0, range.Size.Y / 2, 0)
local rangeSize = range.Size
-- base wind follows the range x axis so it blows across the field instead of into the player
local windBase = rangeCFrame:VectorToWorldSpace(Vector3.new(wind.Base, 0, 0))

type Kind = {
	template: Model,
	color: Color3,
	points: number,
	gust: number,
	weight: number,
	bomb: boolean,
	lift: number,
	drag: number,
	height: number,
}

local Balloon = {}
Balloon.__index = Balloon

type Balloon = typeof(setmetatable({} :: {
	kind: Kind,
	model: Model,
	body: BasePart,
	tail: BasePart,
	force: VectorForce,
	gone: boolean,
}, Balloon))

type Dart = {
	part: BasePart,
	position: Vector3,
	velocity: Vector3,
	shooter: Player,
	params: RaycastParams,
	expires: number,
}

local BalloonService = {}

local rng = Random.new()
local kinds: {Kind} = {}
local totalWeight = 0
local balloons: {[BasePart]: Balloon} = {} -- keyed by body so a raycast hit turns back into its balloon in one lookup
local darts: {Dart} = {}
local nextShot: {[Player]: number} = {}
local activeCount = 0

-- each template keeps its own tuning in attributes so balloons get balanced in studio without touching
-- code. anything that only depends on the template is worked out once here instead of every spawn
for _, template in assets.Balloons:GetChildren() do
	local body = template.Body
	local lift = template:GetAttribute("Lift") -- gas push as a multiple of its own weight, over 1 floats
	-- the tail hangs off the rope so the gas has to hold it up too
	local mass = body.Mass + template.Tail.Mass
	local kind = {
		template = template,
		color = body.Color,
		points = template:GetAttribute("Points"),
		gust = template:GetAttribute("Gust"),
		weight = template:GetAttribute("Weight"),
		bomb = template:GetAttribute("Bomb"),
		-- lift and drag are kept in units of g, step multiplies them by the live gravity so the climb speed
		-- stays right even if something changes workspace.Gravity mid game
		lift = mass * lift,
		-- at top speed the spare lift equals the drag: mass * (lift - 1) = drag * rise, solved for drag
		drag = mass * (lift - 1) / template:GetAttribute("Rise"),
		-- spawn high enough that the tail starts just under a stud above the floor
		height = body.Size.Y / 2 + body.String.Length + 1,
	}
	table.insert(kinds, kind)
	totalWeight += kind.weight
end

-- the blast only cares about balloons, include mode skips the floor, players and debris completely
local blastQuery = OverlapParams.new()
blastQuery.FilterType = Enum.RaycastFilterType.Include
blastQuery.FilterDescendantsInstances = {balloonFolder}

local function windAt(position: Vector3, now: number): Vector3
	-- two noise samples with the axes swapped and offset so x and z gusts dont move together.
	-- position is in there too so balloons next to each other still drift a little differently
	local t = now * wind.Speed
	local gustX = math.noise(position.X * wind.Scale, position.Z * wind.Scale, t)
	local gustZ = math.noise(position.Z * wind.Scale, t, position.X * wind.Scale + 50)
	return windBase + Vector3.new(gustX, 0, gustZ) * wind.Gust
end

local function dartGravity(): Vector3
	return Vector3.yAxis * (-workspace.Gravity * dartSettings.Drop)
end

local function burst(body: BasePart, inherited: Vector3)
	local center = body.Position
	local radius = body.Size.X / 2
	for _ = 1, shards.Count do
		local direction = rng:NextUnitVector()
		-- the shard template sits in the PopDebris collision group which cant hit itself, they spawn
		-- overlapped and would shove each other apart at crazy speeds otherwise
		local shard = assets.Effects.Shard:Clone()
		shard.Size = Vector3.new(radius * 0.7, radius * 0.7, shard.Size.Z)
		-- looking outward from the middle lays the flat face on the skin, like a torn bit of rubber
		shard.CFrame = CFrame.lookAt(center + direction * radius, center + direction * (radius + 1))
		shard.Color = body.Color
		shard.Material = body.Material
		shard.Parent = debrisFolder
		-- impulse is mass times change in velocity, scaling by mass gives every shard the same launch speed.
		-- adding the balloons own velocity keeps the pieces moving with it instead of stopping dead
		shard:ApplyImpulse((direction * shards.Speed + inherited) * shard.AssemblyMass)
		-- spin is set straight, an angular impulse would need the inertia of a shape thats about to shrink anyway
		shard.AssemblyAngularVelocity = rng:NextUnitVector() * shards.Spin
		TweenService:Create(shard, shardFade, {Transparency = 1, Size = shard.Size * 0.3}):Play()
		Debris:AddItem(shard, shardFade.Time)
	end
end

-- finds the launch velocity that gets the dart and the balloon to the same spot at the same time.
-- flight time depends on the aim point and the aim point depends on flight time, so each pass feeds one
-- into the other. darts are way faster than balloons so it settles in a couple passes
local function solveLaunch(origin: Vector3, target: Vector3, targetVelocity: Vector3): Vector3
	local fall = dartGravity()
	local t = (target - origin).Magnitude / dartSettings.Speed
	local aim = target
	for _ = 1, 4 do
		-- where the balloon will be after t, raised by however far the dart drops in that time
		aim = target + targetVelocity * t - fall * (0.5 * t * t)
		t = (aim - origin).Magnitude / dartSettings.Speed
	end
	return (aim - origin).Unit * dartSettings.Speed
end

local function shoot(player: Player, balloon: Balloon)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	-- r15 rigs have RightHand and r6 rigs have Right Arm, the dart just leaves from whichever one exists
	local hand = character and (character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm"))
	local now = os.clock()
	if balloon.gone or not hand or not humanoid or humanoid.Health <= 0 or now < (nextShot[player] or 0) then
		return
	end
	-- clicks come from the client and exploiters can fire clickdetectors directly, so the rate limit lives here
	nextShot[player] = now + dartSettings.Cooldown

	local origin = hand.Position
	local velocity = solveLaunch(origin, balloon.body.Position, balloon.body.AssemblyLinearVelocity)
	-- the dart leaves from inside the shooters own body and flies through falling scraps, neither should stop it
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {character, dartFolder, debrisFolder}

	local part = assets.Effects.Dart:Clone()
	-- lookAt turns the parts front (-z) down the velocity so the long side lines up with the flight
	part.CFrame = CFrame.lookAt(origin, origin + velocity)
	part.Parent = dartFolder
	table.insert(darts, {
		part = part,
		position = origin,
		velocity = velocity,
		shooter = player,
		params = params,
		expires = now + dartSettings.Lifetime,
	})
end

local function blast(center: Vector3, popper: Player?)
	-- the explosion is only the visual. the template has zero pressure and zero joint radius so it cant
	-- fling or kill anyone, the actual blast is the overlap query below
	local explosion = assets.Effects.Explosion:Clone()
	explosion.Position = center
	explosion.Parent = workspace
	Debris:AddItem(explosion, 2)

	for _, part in workspace:GetPartBoundsInRadius(center, bomb.Radius, blastQuery) do
		local other = balloons[part]
		if other then
			local offset = part.Position - center
			-- bounds checks catch box corners, so closeness can go below 0 for parts just outside the radius
			local closeness = 1 - offset.Magnitude / bomb.Radius
			if closeness > 0.5 then
				-- delay grows with distance so the chain ripples outward instead of everything popping on one frame
				task.delay(0.05 + (1 - closeness) * 0.3, other.pop, other, popper)
			elseif closeness > 0 then
				part:ApplyImpulse(offset.Unit * (bomb.Push * closeness * part.AssemblyMass))
			end
		end
	end
end

function Balloon.new(kind: Kind, position: Vector3): Balloon
	local model = kind.template:Clone()
	-- the body is the primary part so pivoting puts the middle of the balloon on the spawn point
	model:PivotTo(CFrame.new(position))
	local body = model.Body
	local self = setmetatable({
		kind = kind,
		model = model,
		body = body,
		tail = model.Tail,
		force = body.Lift,
		gone = false,
	}, Balloon)

	-- no need to disconnect this later, destroying the model takes the detector and its connection with it
	body.ClickDetector.MouseClick:Connect(function(player)
		shoot(player, self)
	end)
	model.Parent = balloonFolder
	-- server keeps ownership, otherwise physics hands them to the closest client and the forces set here
	-- would arrive late on their end (and an exploiter could just fly them away)
	body:SetNetworkOwner(nil)
	self.tail:SetNetworkOwner(nil)
	balloons[body] = self
	activeCount += 1
	return self
end

function Balloon:step(gravity: number, now: number)
	local body = self.body
	-- bounds are checked in range space so they still line up if the range part is rotated
	local spot = rangeCFrame:PointToObjectSpace(body.Position)
	if spot.Y > Config.Ceiling or math.abs(spot.X) > rangeSize.X or math.abs(spot.Z) > rangeSize.Z then
		self:remove()
		return
	end
	-- drag works off the velocity relative to the air, thats the part that makes wind carry it along.
	-- its linear instead of v squared because the force only updates once a frame and v squared overshot
	-- after bomb pushes
	local relative = body.AssemblyLinearVelocity - windAt(body.Position, now) * self.kind.gust
	self.force.Force = (Vector3.yAxis * self.kind.lift - relative * self.kind.drag) * gravity
end

function Balloon:remove()
	if self.gone then
		return
	end
	self.gone = true
	balloons[self.body] = nil
	activeCount -= 1
	self.model:Destroy()
end

function Balloon:pop(popper: Player?)
	if self.gone then
		return -- a dart and a bomb chain can both reach the same balloon
	end
	local body = self.body
	local center = body.Position
	-- tail gets pulled out first, the rope lives in the body so the string end just drops to the floor
	self.tail.Parent = debrisFolder
	Debris:AddItem(self.tail, 4)
	burst(body, body.AssemblyLinearVelocity)
	self:remove()

	if popper then
		ScoreService.Award(popper, self.kind.points, center, self.kind.color)
	end
	if self.kind.bomb then
		blast(center, popper)
	end
end

local function land(dart: Dart, hit: RaycastResult?)
	local balloon = hit and balloons[hit.Instance]
	if balloon then
		balloon:pop(dart.shooter)
	elseif hit and hit.Instance.Anchored then
		-- stick it in walls and the floor for a bit, tip pushed 0.3 in so it doesnt float on the surface
		local forward = dart.velocity.Unit
		local middle = hit.Position - forward * (dart.part.Size.Z / 2 - 0.3)
		dart.part.CFrame = CFrame.lookAt(middle, middle + forward)
		dart.part.Trail.Enabled = false
		Debris:AddItem(dart.part, 4)
		return
	end
	dart.part:Destroy()
end

-- reused every frame so moving the darts doesnt make two new tables per frame
local movedParts: {BasePart} = {}
local movedFrames: {CFrame} = {}

local function stepDarts(dt: number, now: number)
	local fall = dartGravity()
	table.clear(movedParts)
	table.clear(movedFrames)
	-- backwards so the swap remove below never skips a dart
	for i = #darts, 1, -1 do
		local dart = darts[i]
		-- exact step for constant acceleration (v*t + a*t^2/2), same math solveLaunch assumed so the aim holds up
		local step = dart.velocity * dt + fall * (0.5 * dt * dt)
		-- a spherecast instead of a ray gives the dart some thickness so grazing a balloon still counts
		local hit = workspace:Spherecast(dart.position, dartSettings.Radius, step, dart.params)
		if hit or now > dart.expires then
			-- swap remove, order doesnt matter here and it skips shifting the whole array down
			darts[i] = darts[#darts]
			darts[#darts] = nil
			land(dart, hit)
		else
			dart.position += step
			dart.velocity += fall * dt
			table.insert(movedParts, dart.part)
			table.insert(movedFrames, CFrame.lookAt(dart.position, dart.position + dart.velocity))
		end
	end
	if #movedParts > 0 then
		-- one engine call for all darts instead of a cframe write per part
		workspace:BulkMoveTo(movedParts, movedFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

local function pickKind(): Kind
	-- roll somewhere in the total and walk the list subtracting weights, the kind the roll lands in wins
	local roll = rng:NextNumber(0, totalWeight)
	for _, kind in kinds do
		roll -= kind.weight
		if roll <= 0 then
			return kind
		end
	end
	return kinds[#kinds] -- float rounding can leave a tiny bit over
end

local function spawnLoop()
	while true do
		if activeCount < Config.MaxBalloons then
			local kind = pickKind()
			-- random spot on the range floor, offset is in range space so it follows the part around
			local offset = Vector3.new(
				rng:NextNumber(-0.5, 0.5) * rangeSize.X,
				kind.height,
				rng:NextNumber(-0.5, 0.5) * rangeSize.Z
			)
			Balloon.new(kind, rangeCFrame:PointToWorldSpace(offset))
		end
		task.wait(rng:NextNumber(Config.SpawnDelay.Min, Config.SpawnDelay.Max))
	end
end

function BalloonService.Start()
	Players.PlayerRemoving:Connect(function(player)
		nextShot[player] = nil
	end)
	task.spawn(spawnLoop)
	-- presimulation runs right before physics every frame, so forces set here get used on this same step
	RunService.PreSimulation:Connect(function(dt)
		local now = os.clock()
		local gravity = workspace.Gravity
		-- step can remove the balloon its on, clearing the current key mid loop is allowed in luau
		for _, balloon in balloons do
			balloon:step(gravity, now)
		end
		stepDarts(dt, now)
	end)
end

return BalloonService
