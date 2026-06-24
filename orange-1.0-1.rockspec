package = "orange"
version = "1.0-1"
source = {
    url = "git://github.com/purplesyringa/orange",
    tag = "v1.0",
}
description = {
    summary = "A just-in-time Teal-to-Lua transpiler.",
    detailed = [[
        A fast Teal transpiler without type checking or validation,
        suitable for runtime use.
    ]],
    homepage = "https://github.com/purplesyringa/orange",
    license = "MIT",
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
            orange = "bin/orange.lua",
        },
    },
}
