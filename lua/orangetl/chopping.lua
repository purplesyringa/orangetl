local function makeChopper(code)
    local parts = {}
    local last_added = 0
    local acc_newlines_to_add = 0

    local chopper = {}

    function chopper.cut(first, last, replacement, disable_newlines)
        last = math.max(last, first - 1)
        replacement = replacement or ""

        assert(first > last_added, "cutting an already cut part")
        table.insert(parts, code:sub(last_added + 1, first - 1))

        local newlines_to_add = 0
        for _ in code:sub(first, last):gmatch("\n") do
            newlines_to_add = newlines_to_add + 1
        end
        for _ in replacement:gmatch("\n") do
            newlines_to_add = newlines_to_add - 1
        end
        assert(newlines_to_add >= 0, "more newlines removed than added")
        acc_newlines_to_add = acc_newlines_to_add + newlines_to_add
        if not disable_newlines then
            replacement = replacement .. ("\n"):rep(acc_newlines_to_add)
            acc_newlines_to_add = 0
        end
        if replacement ~= "" then
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
