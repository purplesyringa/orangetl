-- Simple lexing: extract identifiers/numbers, comments, and strings, and treat the remaining
-- non-whitespace characters as punctuation per character.
local function lex(code)
    local cur_pos = 1

    return function()
        if not cur_pos then
            return nil
        end

        -- Skip whitespace, except for `\n`, which is used to track line numbers.
        cur_pos = code:find("[^ \r\t\v\f]", cur_pos)
        if not cur_pos then
            return nil
        end

        local first = cur_pos
        local key
        local _, last

        local byte = code:byte(cur_pos)
        local next_byte = code:byte(cur_pos + 1)
        if (
            (0x30 <= byte and byte <= 0x39)
            or (0x41 <= byte and byte <= 0x5a)
            or (0x61 <= byte and byte <= 0x7a)
            or byte == 0x5f
        ) then
            key = "alnum"
            _, last = code:find("[%a%d_]+", cur_pos)
        elseif byte == 0x0a then
            key = "newline"
            last = cur_pos
        elseif byte == 0x22 or byte == 0x27 then
            key = "string"
            -- Skip until matching punctuation that is not preceded by an odd number of backslashes.
            -- This pattern is likely worst-case quadratic, but this shouldn't trigger on realistic
            -- strings.
            local punct = code:sub(cur_pos, cur_pos)
            _, last = code:find("[^\\](\\*)%1" .. punct, cur_pos)
        elseif byte == 0x2d and next_byte == 0x2d then
            key = "comment"
            if code:sub(cur_pos + 2, cur_pos + 2) == "[" then
                -- Long comment like `--[[...]]`, reuse the long string pattern.
                _, last = code:find("%[(=*)%[.-%]%1%]", cur_pos + 2)
            else
                -- Short comment, skip until EOL.
                last = code:find("\n", cur_pos + 2) or #code
            end
        elseif byte == 0x5b and (next_byte == 0x5b or next_byte == 0x3d) then
            key = "string"
            _, last = code:find("%[(=*)%[.-%]%1%]", cur_pos)
        else
            key = "punct"
            last = cur_pos
        end

        cur_pos = last + 1
        return code:sub(first, last), key, first, last
    end
end

return {
    lex = lex,
}
