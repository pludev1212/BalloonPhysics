local ServerScriptService = game:GetService("ServerScriptService")

local services = {}
for _, module in ServerScriptService.Server.Services:GetChildren() do
	if module:IsA("ModuleScript") then
		services[module.Name] = require(module)
	end
end

for name, service in services do
	if service.Start then
		-- one broken service shouldnt take the rest down with it
		local ok, err = xpcall(service.Start, debug.traceback)
		if not ok then
			warn(`{name} failed to start: {err}`)
		end
	end
end
