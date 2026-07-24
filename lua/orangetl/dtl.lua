local transpiler = require("orangetl.transpiler")

local TEMPLATE = ([[
    return (function(lua, dtl)
        local function merge(dst, src)
            for k, v in pairs(src) do
                if dst[k] == nil then
                    dst[k] = v
                else
                    merge(dst[k], v)
                end
            end
        end
        if lua == true then
            lua = {}
        end
        merge(lua, dtl)
        return lua
    end)((function(...) %s end)(...), (function() %s end)())
]]):gsub("%s+", " "):gsub("^%s|%s$", "")

local function transpileDef(dtl_code, lua_code)
    dtl_code = transpiler.transpile(dtl_code)
    -- Give the Lua code the right line numbers, since it's more likely to contain errors.
    lua_code = lua_code:gsub("^#[^\n]*", "")
    return TEMPLATE:format(lua_code, dtl_code)
end

return {
    transpileDef = transpileDef,
}
