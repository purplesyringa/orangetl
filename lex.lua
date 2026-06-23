-- Simple lexing: extract identifiers/numbers, comments, and strings, and treat the remaining
-- non-whitespace characters as punctuation per character.
local function lex(code)
    local patterns = {
        alnum = "[%a%d_]+",
        comment = "%-%-",
        short_string = "[\"']",
        long_string = "%[(=*)%[.-%]%1%]",
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

        local first = cur_pos

        -- See if any pattern matches this position.
        for key, pattern in pairs(patterns) do
            local _, last = code:find("^" .. pattern, cur_pos)
            if last then
                -- Find the end of this token.
                if key == "alnum" or key == "long_string" then
                    -- Already parsed in full by the pattern.
                elseif key == "comment" then
                    if code:sub(last + 1, last + 1) == "[" then
                        -- Long comment like `--[[...]]`, reuse the long string pattern.
                        local _
                        _, last = code:find(patterns.long_string, last + 1)
                    else
                        -- Short comment, skip until EOL.
                        last = code:find("\n", last + 1)
                    end
                elseif key == "short_string" then
                    -- Skip until matching punctuation that is not preceded by an odd number of
                    -- backslashes. This pattern is likely worst-case quadratic, but this shouldn't
                    -- trigger on realistic strings.
                    local punct = code:sub(cur_pos, cur_pos)
                    local _
                    _, last = code:find("[^\\](\\*)%1" .. punct, cur_pos)
                end

                cur_pos = last + 1
                return code:sub(first, last), key, first, last
            end
        end

        -- Not a known token, assume punctuation.
        local value = code:sub(cur_pos, cur_pos)
        cur_pos = cur_pos + 1
        if value == "\n" then
            return "", "newline", first, first
        else
            return value, "punct", first, first
        end
    end
end

return {
    lex = lex,
}
