local function makeChopper(code)
    local parts = {}
    local last_added = 0

    local chopper = {}
    function chopper.cut(first, last, replacement)
        assert(first > last_added, "cutting an already cut part")
        table.insert(parts, code:sub(last_added + 1, first - 1))
        if replacement then
            table.insert(parts, replacement)
        end
        last_added = last
    end
    function chopper.insert(pos, value)
        chopper.cut(pos, pos - 1, value)
    end
    function chopper.finish()
        table.insert(parts, code:sub(last_added + 1))
        return table.concat(parts)
    end

    return chopper
end

return {
    makeChopper = makeChopper,
}
