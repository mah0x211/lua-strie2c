rockspec_format = "3.0"
package = "strie2c"
version = "dev-1"
source = {
    url = "git+https://github.com/mah0x211/lua-strie2c.git",
}
description = {
    summary = "Static Trie to C code generator",
    detailed = [[`strie2c` generates optimized C code for string matching using a static trie (prefix tree) compiled into hierarchical switch-case statements. Achieves 1.6-1.9x faster performance than gperf for typical use cases.]],
    homepage = "https://github.com/mah0x211/lua-strie2c",
    maintainer = "Masatoshi Fukunaga",
    license = "MIT",
}
dependencies = {
    "lua >= 5.1",
}
build_dependencies = {
    "luarocks-build-hooks >= 0.1.0",
}
build = {
    type = "hooks",
    before_build = {
        "$(extra-vars)",
    },
    extra_variables = {
        CFLAGS = "-Wall -Wno-trigraphs -Wmissing-field-initializers -Wreturn-type -Wmissing-braces -Wparentheses -Wno-switch -Wunused-function -Wunused-label -Wunused-parameter -Wunused-variable -Wunused-value -Wuninitialized -Wunknown-pragmas -Wshadow -Wsign-compare",
    },
    modules = {
        strie2c = "lib/strie2c.lua",
        ["strie2c.hash"] = "src/hash.c",
    },
}
