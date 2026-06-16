local function lexerToTokenStream(lexer)
    local e = { value = "", type = "sof" }
    local stream = { prev3 = e, prev2 = e, prev = e, cur = e, next = e, next2 = e }

    function stream.nextToken()
        local value, type, first, last
        repeat
            value, type, first, last = lexer()
        until type ~= "comment"
        if type == "short_string" or type == "long_string" then
            type = "string"
        end
        local token = { value = "", type = "eof" }
        if value then
            token = {
                value = value,
                type = type,
                first = first,
                last = last,
            }
        end

        stream.prev3 = stream.prev2
        stream.prev2 = stream.prev
        stream.prev = stream.cur
        stream.cur = stream.next
        stream.next = stream.next2
        stream.next2 = token
    end

    -- Populate up to `cur`.
    stream.nextToken()
    stream.nextToken()
    stream.nextToken()

    return stream
end

return {
    lexerToTokenStream = lexerToTokenStream,
}
