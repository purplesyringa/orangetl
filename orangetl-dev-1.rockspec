rockspec_format = "3.0"
package = "orangetl"
version = "dev-1"
source = {
    url = "git://github.com/purplesyringa/orangetl",
    tag = nil,
}
description = {
    summary = "A just-in-time Teal-to-Lua transpiler.",
    detailed = [[
        A fast Teal transpiler without type checking or validation,
        suitable for runtime use.
    ]],
    license = "MIT",
    homepage = "https://github.com/purplesyringa/orangetl",
    issues_url = "https://github.com/purplesyringa/orangetl/issues",
    maintainer = "Alisa Sireneva <me@purplesyringa.moe>",
    labels = {},
}
dependencies = {
    "lua >= 5.1, < 5.6",
    "argparse >= 0.6",
}
build = {
    type = "builtin",
    modules = {},
    install = {
        bin = {
            orangetl = "bin/orangetl.lua",
        },
    },
}
