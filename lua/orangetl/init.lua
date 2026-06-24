local transpiler = require("orangetl.transpiler")
local searcher = require("orangetl.searcher")

return {
    transpile = transpiler.transpile,
    searcher = searcher.searcher,
}
