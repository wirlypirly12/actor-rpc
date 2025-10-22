local Class = loadstring(game:HttpGet("https://raw.githubusercontent.com/wirlypirly12/luau-utility/refs/heads/main/class.luau"))()
local Promise = loadstring(game:HttpGet("https://raw.githubusercontent.com/wirlypirly12/luau-utility/refs/heads/main/promise.luau"))()

local ActorRPC = Class.new{
    name = "ActorRPC",
    dependencies = {
        "getcommchannel",
        "createcommchannel",
        "runonactor"
    }
}

function ActorRPC:create_channels()
    local channels = {}
    for i, channelname in next, self.all_channels do
        local channel_id, channel = createcommchannel(channelname)
        channels[channelname] = {
            id = channel_id,
            name = channelname,
            channel = channel
        }
    end
    return channels
end

function ActorRPC:connect(actor)

    self.all_channels.Gate.channel.Event:Connect(function(...)
        return self:OnActorMessage(...)
    end)

    runonactor(actor, [[
        -- get channel ids
        local tick_begin = tick()
        local Signal = getcommchannel(...)
        local Channels;

        Signal.Event:Connect(function(payload)
            Channels = {}
            for channelname, channeldata in next, payload do
                Channels[channelname] = channeldata.id
            end
        end)
        
        repeat task.wait() until Channels

        local Gate = getcommchannel(Channels.Gate)
        local RunFunction = getcommchannel(Channels.RunFunction)
        local MakeFunction = getcommchannel(Channels.MakeFunction)

        getgenv().ResolvePath = function(path)
            local env = getrenv()
            for segment in string.gmatch(path, "[^.]+") do
                env = env[segment]
                if env == nil then break end
            end
            if env ~= nil then return env end

            env = getgenv()
            for segment in string.gmatch(path, "[^.]+") do
                env = env[segment]
                if env == nil then return nil end
            end
            return env
        end
        getgenv().GetPath = function(base, path)
            local env = base
            local segments = {}
            for segment in string.gmatch(path, "[^.]+") do
                table.insert(segments, segment)
            end
            for i, seg in next, segments do
                if i == #segments then
                    if type(env[seg]) ~= "table" then
                        env[seg] = {}
                    end
                    return env, seg
                end

                if env[seg] == nil then
                    env[seg] = {}
                end
                env = env[seg]
            end
            return env
        end

        RunFunction.Event:Connect(function(payload)
            local func = ResolvePath(payload.path)
            if not func or typeof(func) ~= "function" then
                warn(payload.path,"doesn't exist")
            end
            
            local ok, message = pcall(func, table.unpack(payload.args))
            local message_back = {
                id = payload.id,
                success = ok,
                result = message
            }

            Gate:Fire(message_back)
        end)

        MakeFunction.Event:Connect(function(payload)
            payload.params = payload.params or {}
            
            local chunk = string.format(
                "return function(%s)\n%s\nend",
                table.concat(payload.params, ", "),
                payload.code
            )
            local ok, func = pcall(function()
                return loadstring(chunk)()
            end)

            if not ok or type(func) ~= "function" then
                warn("failed to compile function")
                return
            end

            getgenv()[payload.name] = func
        end)

        warn(("[ACTOR] initlized in %.2f seconds"):format(tick()-tick_begin)) -- woooooooooo
    ]], self.id)
    
    
    self.channel:Fire(self.all_channels)
end

function ActorRPC:OnActorMessage(message)
    if not message.id then
        print("no id")
        return
    end

    local req = self._pending[message.id]
    if not req then
        print("no pending request found for id")
        return
    end

    if message.success then
        req.resolve(message.result)
    else
        req.reject(message.result)
    end
end

function ActorRPC.new(actor)
    local self = ActorRPC:create(actor and actor.Name or "unknown ActorRPC")
    self._pending = {}
    
    local channel_id, channel = createcommchannel("payload")

    self.id = channel_id
    self.channel = channel
    self.all_channels = {
        "Gate",
        "RunFunction",
        "MakeFunction"
    }
    self.all_channels = self:create_channels()
    self:connect(actor)

    task.wait(1)
    return self
end

function ActorRPC:make_request()
    return {
        id = math.random(1,99999999),
        timeout = 3
    }
end

function ActorRPC:run(path, ...)
    local varargs = table.pack(...)
    local promise; promise = Promise.new(function(resolve, reject)
        local template = self:make_request()
        self._pending[template.id] = {
            resolve = resolve,
            reject = reject
        }

        self.all_channels.RunFunction.channel:Fire{
            id = template.id,
            path = path,
            args = varargs
        }

        task.delay(template.timeout, function()
            if promise._state ~= "pending" then return end
            reject("timeout")
        end)
    end)

    return promise
end

function ActorRPC:make(name, code, params)
    self.all_channels.MakeFunction.channel:Fire{
        name = name,
        code = code,
        params = params
    }
end


-- example:
-- local best = getactors()[1]
-- local rpc = ActorRPC.new(best)
-- rpc:make("hi", [[
--     print("hi!")
-- ]])
-- rpc:run("hi")

return ActorRPC
