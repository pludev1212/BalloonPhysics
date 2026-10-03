-- score side of the balloon range: leaderstats, combos and the floating +points text
-- BalloonService calls Award whenever a player pops something

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Config = require(ReplicatedStorage.Shared.Config.RangeConfig)

local assets = ServerStorage.Assets
local combo = Config.Combo
local popupRise = TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

type Shooter = {
	combo: number,
	lastPop: number,
	points: IntValue,
	pops: IntValue,
}

local ScoreService = {}
local shooters: {[Player]: Shooter} = {}

local function popup(position: Vector3, text: string, color: Color3)
	local anchor = assets.Effects.Popup:Clone()
	local gui = anchor.BillboardGui
	-- terrain sits at the origin with no rotation so a local position on it is already a world position
	anchor.Position = position
	gui.Amount.Text = text
	gui.Amount.TextStrokeColor3 = color -- white text with a colored outline stays readable even on the black bomb
	anchor.Parent = workspace.Terrain
	TweenService:Create(gui, popupRise, {StudsOffsetWorldSpace = Vector3.new(0, 5, 0)}):Play()
	TweenService:Create(gui.Amount, popupRise, {TextTransparency = 1, TextStrokeTransparency = 1}):Play()
	Debris:AddItem(anchor, popupRise.Time)
end

local function track(player: Player)
	local stats = assets.leaderstats:Clone()
	stats.Parent = player
	-- keep the values themselves so scoring never has to search the player for them
	shooters[player] = {
		combo = 0,
		lastPop = 0,
		points = stats.Points,
		pops = stats.Pops,
	}
end

function ScoreService.Award(player: Player, points: number, position: Vector3, color: Color3)
	local shooter = shooters[player]
	if not shooter then
		return -- they left while a bomb chain was still going
	end
	local now = os.clock()
	-- a pop inside the window keeps the combo going, a late one starts it over
	shooter.combo = if now - shooter.lastPop <= combo.Window then shooter.combo + 1 else 1
	shooter.lastPop = now
	-- every combo step adds a bit more, capped so a huge bomb chain doesnt blow up the scoreboard
	local multiplier = math.min(1 + (shooter.combo - 1) * combo.Step, combo.Max)
	local gained = math.round(points * multiplier)
	shooter.points.Value += gained
	shooter.pops.Value += 1
	popup(position, if shooter.combo > 1 then `+{gained}  x{multiplier}` else `+{gained}`, color)
end

function ScoreService.Start()
	Players.PlayerAdded:Connect(track)
	Players.PlayerRemoving:Connect(function(player)
		shooters[player] = nil
	end)
	-- in studio the first player can join before Start runs
	for _, player in Players:GetPlayers() do
		track(player)
	end
end

return ScoreService
