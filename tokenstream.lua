local lex = require "lex"

local function makeTokenStream(code)
    local e = { value = "", type = "sof", first = 1, last = 1, line = 1 }
    local stream = {
        code = code,
        prev3 = e,
        prev2 = e,
        prev = e,
        cur = e,
        next = e,
        next2 = e,
    }
    local lexer = lex.lex(code)
    local line = 1

    function stream.nextToken()
        local value, type, first, last
        repeat
            value, type, first, last = lexer()
            if type == "newline" then
                line = line + 1
            end
        until type ~= "comment" and type ~= "newline"
        if type == "short_string" or type == "long_string" then
            type = "string"
        end
        local token
        if value then
            token = {
                value = value,
                type = type,
                first = first,
                last = last,
                line = line,
            }
        else
            token = {
                value = "",
                type = "eof",
                first = #code + 1,
                last = #code + 1,
                line = line,
            }
        end

        stream.prev3 = stream.prev2
        stream.prev2 = stream.prev
        stream.prev = stream.cur
        stream.cur = stream.next
        stream.next = stream.next2
        stream.next2 = token
    end

    function stream.tryConsume(value)
        if stream.cur.value == value then
            stream.nextToken()
            return true
        else
            return false
        end
    end

    -- Populate up to `cur`.
    stream.nextToken()
    stream.nextToken()
    stream.nextToken()

    return stream
end

return {
    makeTokenStream = makeTokenStream,
}
