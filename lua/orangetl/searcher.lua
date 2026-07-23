local transpiler = require("orangetl.transpiler")

local function loadTealFile(file, ...)
    local f, err = io.open(file, "rb")
    if not f then
        error(err, 0)
    end
    local teal_code = f:read("*all")
    assert(teal_code, "cannot read " .. file)
    f:close()

    local lua_code = transpiler.transpile(teal_code, {
        -- Avoid using logic like `_VERSION <= "Lua 5.3"` in case Lua 5.10 releases.
        strip_attributes = _VERSION == "Lua 5.1" or _VERSION == "Lua 5.2" or _VERSION == "Lua 5.3",
        replace_named_varargs = _VERSION == "Lua 5.1"
            or _VERSION == "Lua 5.2"
            or _VERSION == "Lua 5.3"
            or _VERSION == "Lua 5.4",
        rewrite_for_reassignments = not (
                _VERSION == "Lua 5.1"
                or _VERSION == "Lua 5.2"
                or _VERSION == "Lua 5.3"
            ),
        rewrite_string_escapes = _VERSION == "Lua 5.1" or _VERSION == "Lua 5.2",
    })

    local closure, err = (loadstring or load)(lua_code, "@" .. file, "t") -- luacheck: ignore
    if not closure then
        error("in transpiled code: " .. err, 0)
    end

    return closure(...)
end

local function searcher(name)
    -- Reimplement `package.searchpath` for compatibility with Lua 5.1. Roughly follows
    -- https://github.com/keplerproject/lua-compat-5.2.
    local file_name = name:gsub("%.", package.config:sub(1, 1))
    local err = ""
    for pattern in package.path:gmatch("[^;]+") do
        local tl_pattern = pattern:gsub("%.lua$", ".tl")
        if tl_pattern ~= pattern then
            local file = tl_pattern:gsub("%?", file_name)
            local f = io.open(file, "r")
            if f then
                f:close()
                -- Construct a closure for `file` instead of returning a user value because Lua 5.1
                -- doesn't support that.
                return function(name)
                    local ok, value = pcall(loadTealFile, file)
                    if ok then
                        return value
                    end
                    error(
                        ("error loading module '%s' from file '%s':\n\t%s"):format(
                            name,
                            file,
                            value
                        ),
                        0
                    )
                end
            end
            err = err .. "\n\tno file '" .. file .. "'"
        end
    end
    return err
end

return {
    loadTealFile = loadTealFile,
    searcher = searcher,
}
