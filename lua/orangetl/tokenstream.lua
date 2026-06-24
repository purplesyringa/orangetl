local lex = require("orangetl.lex")

local function makeTokenStream(code)
    local lexer = lex.lex(code)

    local sof = { value = "", type = "sof", first = 1, last = 1 }
    local eof = { value = "", type = "eof", first = #code + 1, last = #code + 1 }

    local stream = {
        prev3 = sof,
        prev2 = sof,
        prev = sof,
        cur = sof,
        next = sof,
        next2 = sof,
    }

    function stream.nextToken()
        local value, type, first, last
        repeat
            value, type, first, last = lexer()
        until type ~= "comment"
        local token
        if value then
            token = {
                value = value,
                type = type,
                first = first,
                last = last,
            }
        else
            token = eof
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

    function stream.isCurPreceededByNewline()
        return code:sub(stream.prev.last + 1, stream.cur.first - 1):find("\n") ~= nil
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
