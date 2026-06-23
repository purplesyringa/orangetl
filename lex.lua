-- Simple lexing: extract identifiers/numbers, comments, and strings, and treat the remaining
-- non-whitespace characters as punctuation per character.
local function lex(code)
    local cur_pos = 1
    local handlers = {}

    local function handleDefault(first)
        return "punct", first
    end
    for byte = 0, 0xff do
        handlers[byte] = handleDefault
    end

    local function handleAlnum(first)
        local _, last = code:find("[%a%d_]+", first)
        return "alnum", last
    end
    for byte = 0x30, 0x39 do
        handlers[byte] = handleAlnum
    end
    for byte = 0x41, 0x5a do
        handlers[byte] = handleAlnum
    end
    for byte = 0x61, 0x7a do
        handlers[byte] = handleAlnum
    end
    handlers[0x5f] = handleAlnum

    handlers[0x0a] = function(first)
        return "newline", first
    end

    local function handleString(first)
        -- Skip until matching punctuation that is not preceded by an odd number of backslashes.
        -- This pattern is likely worst-case quadratic, but this shouldn't trigger on realistic
        -- strings.
        local punct = code:sub(first, first)
        local _, last = code:find("[^\\](\\*)%1" .. punct, first)
        return "string", last
    end
    handlers[0x22] = handleString
    handlers[0x27] = handleString

    handlers[0x2d] = function(first)
        if code:byte(first + 1) ~= 0x2d then
            return "punct", first
        end
        local _, last
        if code:sub(first + 2, first + 2) == "[" then
            -- Long comment like `--[[...]]`, reuse the long string pattern.
            _, last = code:find("%[(=*)%[.-%]%1%]", first + 2)
        else
            -- Short comment, skip until EOL.
            last = code:find("\n", first + 2) or #code
        end
        return "comment", last
    end

    handlers[0x5b] = function(first)
        if code:byte(first + 1) ~= 0x5b and code:byte(first + 1) ~= 0x3d then
            return "punct", first
        end
        local _, last = code:find("%[(=*)%[.-%]%1%]", first)
        return "string", last
    end

    return function()
        local first = code:find("[^ \r\t\v\f]", cur_pos)
        if not first then
            return nil
        end
        local key, last = handlers[code:byte(first)](first)
        cur_pos = last + 1
        return code:sub(first, last), key, first, last
    end
end

return {
    lex = lex,
}
