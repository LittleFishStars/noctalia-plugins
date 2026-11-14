--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- lib/jwt.luau —— 和风天气的 JWT（Ed25519 / EdDSA）认证
--
-- Luau 里没有 Ed25519 实现，所以签名交给 bin/qweather-jwt.py 完成
-- （优先用 cryptography 库，没有则回退到本机 openssl 命令行）。
-- Token 在内存里缓存，过期前 5 分钟自动换新，不会每次请求都起进程。
--
-- 需要的四项参数来自和风控制台：
--   jwt_private_key  本地 Ed25519 私钥（openssl genpkey -algorithm ED25519）
--   jwt_kid          「凭据 ID」
--   jwt_sub          「项目 ID」
--   jwt_iss          「开发者 ID」（Q 开头的 10 位）
-- ══════════════════════════════════════════════════════════════════════════

local q = require("./qweather.luau")

local M = {}

local TTL = 1800         -- 申请的有效期（和风允许 60 ~ 86400 秒）
local RENEW_BEFORE = 300 -- 提前 5 分钟换新
local TIMEOUT_MS = 15000

local token = nil
local expiresAt = 0

local function s(value)
    return q.trim(tostring(value or ""))
end

function M.scriptPath()
    local ok, dir = pcall(noctalia.pluginDir)
    if ok and type(dir) == "string" and dir ~= "" then
        return dir .. "/bin/qweather-jwt.py"
    end
    return "bin/qweather-jwt.py"
end

function M.python()
    local ok, value = pcall(noctalia.getenv, "QWEATHER_PYTHON")
    if ok and type(value) == "string" and value ~= "" then
        return value
    end
    return "python3"
end

--- 丢弃缓存（401 时调用，下一次会重新签一个）
function M.invalidate()
    token = nil
    expiresAt = 0
end

function M.cached()
    if token and os.time() < expiresAt - RENEW_BEFORE then
        return token
    end
    return nil
end

--- 拿一个可用 Token；cb(token, err)
function M.get(cfg, cb)
    local hit = M.cached()
    if hit then
        cb(hit, nil)
        return
    end

    local keyPath = noctalia.expandPath(s(cfg.jwt_private_key))
    local argv = {
        M.python(),
        M.scriptPath(),
        keyPath,
        s(cfg.jwt_kid),
        s(cfg.jwt_sub),
        "--iss", s(cfg.jwt_iss),
        "--ttl", tostring(TTL),
    }

    local delivered = false
    local function deliver(value, err)
        if delivered then
            return
        end
        delivered = true
        cb(value, err)
    end

    local started = noctalia.runAsync(argv, function(res)
        if type(res) ~= "table" then
            deliver(nil, "JWT 生成器没有返回结果")
            return
        end

        local out = tostring(res.stdout or "")
        if res.exitCode ~= 0 or q.trim(out) == "" then
            local detail = q.trim(tostring(res.stderr or ""))
            deliver(nil, detail ~= "" and detail or ("JWT 生成器退出码 " .. tostring(res.exitCode)))
            return
        end

        -- 只认最后一个非空行，防止脚本额外打印了提示信息
        local line
        for chunk in out:gmatch("[^\r\n]+") do
            if q.trim(chunk) ~= "" then
                line = q.trim(chunk)
            end
        end

        if not line or not line:find("%.") then
            deliver(nil, "JWT 生成器输出看起来不像 Token")
            return
        end

        token = line
        expiresAt = os.time() + TTL
        deliver(token, nil)
    end, TIMEOUT_MS)

    if started == false then
        deliver(nil, "无法启动 JWT 生成器（runAsync 不可用或命令被拒绝）")
    end
end

return M
