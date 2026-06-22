-- Simple lexing: extract identifiers/numbers, comments, and strings, and treat the remaining
-- non-whitespace characters as punctuation per character.
local function lex(code)
    -- Since Lua patterns don't support `|`, the easiest way to implement this is with multiple
    -- `find` calls stepping in parallel.
    local scans = {
        alnum = { pattern = "[%a%d_]+" },
        comment = { pattern = "%-%-" },
        short_string = { pattern = "[\"']" },
        long_string = { pattern = "%[(=*)%[.-%]%1%]" },
    }

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

        -- Find the nearest token.
        local token_key, token_entry = nil, { first = 1 / 0 }
        for key, entry in pairs(scans) do
            if not entry.first or entry.first < cur_pos then
                -- Key not initialized yet, or we've jumped over the previous occurrence because it
                -- was inside of a string or a comment.
                local first, last = code:find(entry.pattern, cur_pos)
                entry.first = first or 1 / 0
                entry.last = last
            end
            if entry.first < token_entry.first then
                token_key, token_entry = key, entry
            end
        end

        if not token_key then
            return nil
        end

        if token_entry.first > cur_pos then
            -- Not a known token, assume punctuation.
            local pos = cur_pos
            local value = code:sub(pos, pos)
            cur_pos = cur_pos + 1
            if value == "\n" then
                return "", "newline", pos, pos
            else
                return code:sub(pos, pos), "punct", pos, pos
            end
        end

        -- Find the end of this token.
        local last = token_entry.last
        if token_key == "alnum" or token_key == "long_string" then
            -- Already parsed in full by the pattern.
        elseif token_key == "comment" then
            if code:sub(token_entry.last + 1, token_entry.last + 1) == "[" then
                -- Long comment like `--[[...]]`, reuse the long string pattern.
                local _
                _, last = code:find(scans.long_string.pattern, token_entry.last + 1)
            else
                -- Short comment, skip until EOL.
                last = code:find("\n", token_entry.last + 1)
            end
        elseif token_key == "short_string" then
            -- Skip until matching punctuation that is not preceded by an odd number of backslashes.
            -- This pattern is likely worst-case quadratic, but this shouldn't trigger on realistic
            -- strings.
            local punct = code:sub(token_entry.first, token_entry.first)
            local _
            _, last = code:find("[^\\](\\*)%1" .. punct, token_entry.first)
        end

        cur_pos = last + 1
        return code:sub(token_entry.first, last), token_key, token_entry.first, last
    end
end

return {
    lex = lex,
}
