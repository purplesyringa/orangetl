local function makeChopper(code)
    local parts = {}
    local last_added = 0

    return {
        cut = function(first, last, replacement)
            assert(first > last_added, "cutting an already cut part")
            table.insert(parts, code:sub(last_added + 1, first - 1))
            if replacement then
                table.insert(parts, replacement)
            end
            last_added = last
        end,
        finish = function()
            table.insert(parts, code:sub(last_added + 1))
            return table.concat(parts)
        end,
    }
end

return {
    makeChopper = makeChopper,
}
