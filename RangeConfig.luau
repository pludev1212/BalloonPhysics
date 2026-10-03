-- tuning for the balloon range. sits in Shared so client code could read the same numbers later on
-- per balloon numbers (points, lift, rise, gust, spawn weight) are attributes on the templates instead

return {
	MaxBalloons = 24,
	SpawnDelay = NumberRange.new(0.5, 1.2),
	Ceiling = 90, -- studs above the range floor before a balloon counts as escaped

	Wind = {
		Base = 3, -- steady breeze along the range x axis
		Gust = 8,
		Scale = 0.025, -- smaller = bigger gust patches
		Speed = 0.25, -- how fast the gust pattern changes over time
	},

	Dart = {
		Speed = 150,
		Drop = 0.12, -- share of workspace gravity the dart feels, full gravity drops it way too hard at this speed
		Radius = 0.3,
		Lifetime = 3,
		Cooldown = 0.2,
	},

	Bomb = {
		Radius = 16,
		Push = 120,
	},

	Shards = {
		Count = 8,
		Speed = 28,
		Spin = 12,
	},

	Combo = {
		Window = 1.5,
		Step = 0.25,
		Max = 3,
	},
}
