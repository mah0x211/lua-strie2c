--
-- Copyright (C) 2026 Masatoshi Fukunaga
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
-- THE SOFTWARE.
--
local next = next
local type = type
local format = string.format
local sub = string.sub
local gsub = string.gsub
local lower = string.lower
local rep = string.rep
local concat = table.concat
local sort = table.sort

local DEFINE_PKNAMES = {}

--- generate indentation
--- @param depth number indentation depth
--- @return string indentation string
local function indent(depth)
    return rep(' ', depth * 4)
end

local function strsplit(s)
    -- split s by char and escape for C character literal
    local arr = {}
    for i = 1, #s do
        local c = sub(s, i, i)
        -- escape special characters for C
        if c == '\'' then
            c = "\\'"
        elseif c == '\\' then
            c = "\\\\"
        end
        arr[i] = c
    end
    return arr
end

--- create label to packname define
--- @param label string label
--- @param opts table options
--- @return string pkname generated packname define
local function label2pkname(label, opts)
    assert(#label <= 8, 'label length must be <= 8')
    local pksize = #label > 4 and 8 or #label
    local pkname = format('PK%d_%s', pksize,
                          lower(gsub(label, '[^%a%d_]', function(c)
        -- escape non-alphanumeric characters to hex code
        return format('_%02X_', c:byte())
    end)))
    local arr = strsplit(label)

    -- create DEFINE_PKNAMES if not exists
    if not DEFINE_PKNAMES[pkname] then
        -- add 0 padding
        for i = #arr + 1, pksize do
            arr[i] = '\\0'
        end

        local def = format('#define %s PACK%d%s(\'%s\')', pkname, #arr,
                           opts.strcase, concat(arr, "', '"))
        DEFINE_PKNAMES[pkname] = def
        DEFINE_PKNAMES[#DEFINE_PKNAMES + 1] = def
    end
    return pkname
end

--- generate if condition
--- @param label string laabel to compare
--- @param offset number offset in the string
--- @param retval string return value
--- @return string cond generated if condition
local function gen_if(label, offset, retval)
    return format('return (memcmp(str + %d, %q, %d) != 0) ? -1 : %s;', offset,
                  label, #label, retval)
end

--- generate under 8byte switch-cases
--- @param group table group info
--- @param offset number offset in the string
--- @param opts table options
local function gen_switch(group, offset, opts)
    -- generate if condition for only one label
    if #group.labels == 1 then
        group.ifcond = gen_if(group.labels[1], offset, group.retvals[1])
        return
    end

    -- generate switch cases
    local retvals = group.retvals
    local cases = {}
    for i, label in ipairs(group.labels) do
        cases[i] = format('case %s: return %s;', label2pkname(label, opts),
                          retvals[i])
    end

    -- set switch statement and cases
    group.switch = format('switch (PACK%d_FROM_STR%s(str, %d))', group.len,
                          opts.strcase, offset)
    group.switch_cases = cases
end

--- generate 8byte+ switch-cases
--- @param group table group info
--- @param offset number offset in the string
--- @param opts table options
local function gen_switch8over(group, offset, opts)
    -- generate if condition for only one label
    if #group.labels == 1 then
        group.ifcond = gen_if(group.labels[1], offset, group.retvals[1])
        return
    end

    local retvals = group.retvals
    local len = group.len
    local cases = {}
    local pregroup = {}
    -- grouping by 8byte prefix
    for i, label in ipairs(group.labels) do
        -- get subgroup by 8byte prefix
        local prefix = sub(label, 1, 8)
        local subgroup = pregroup[prefix]

        -- create subgroup if not exists
        if not subgroup then
            subgroup = {
                len = len - 8,
                labels = {},
                case = format('case %s:', label2pkname(prefix, opts)),
                retvals = {},
            }
            cases[#cases + 1] = format('case %s:', label2pkname(prefix, opts))
            pregroup[prefix] = subgroup
        end

        -- add remaining label to subgroup
        subgroup.labels[#subgroup.labels + 1] = sub(label, 9)
        -- add key to subgroup
        subgroup.retvals[#subgroup.retvals + 1] = retvals[i]
    end

    -- process each subgroup
    local kvpairs = group.kvpairs
    for _, subgroup in pairs(pregroup) do
        subgroup.kvpairs = kvpairs
        if subgroup.len <= 8 then
            gen_switch(subgroup, offset + 8, opts)
        else
            gen_switch8over(subgroup, offset + 8, opts)
        end
        subgroup.kvpairs = nil
        subgroup.retvals = nil
    end

    group.switch_cases = pregroup
    group.switch = format('switch (PACK%d_FROM_STR%s(str, %d))',
                          len > 8 and 8 or len, opts.strcase, offset)
end

--- make groups by label length
--- @param kvpairs strie2c.kvpair[] key-value pairs
--- @param opts table options (case_insensitive: boolean)
--- @return table[] groups generated groups
local function make_groups(kvpairs, opts)
    assert(type(kvpairs) == 'table', 'kvpairs must be a table')
    assert(type(opts) == 'table', 'opts must be a table')

    -- sort by key-length
    sort(kvpairs, function(a, b)
        return #a.key < #b.key
    end)

    -- create groups by length
    local groups = {}
    local lengroups = {}
    for _, kvp in ipairs(kvpairs) do
        local label = kvp.key
        local len = #label
        local group = lengroups[len]
        if not group then
            group = {
                len = len,
                case = format('case %d:', len),
                labels = {},
                retvals = {},
            }
            lengroups[len] = group
            groups[#groups + 1] = group
        end
        group.labels[#group.labels + 1] = label
        group.retvals[#group.retvals + 1] = kvp.val
    end

    -- process each label group
    DEFINE_PKNAMES = {}
    for _, group in ipairs(groups) do
        group.kvpairs = kvpairs
        if group.len <= 8 then
            -- generate under 8byte switch
            gen_switch(group, 0, opts)
        else
            -- generate over 8byte switch
            gen_switch8over(group, 0, opts)
        end
        group.kvpairs = nil
        group.retvals = nil
    end

    return groups
end

--- generate packname defines
--- @param opts table options
local function gen_define_packnames(opts)
    local macros = {}

    -- base macros
    macros[#macros + 1] = [[
/* pack 1-byte string to uint32_t */
#define PACK1(a) ((uint32_t)(a))

/* pack 2-byte string to uint32_t */
#define PACK2(a, b) ((uint32_t)(a) << 8 | (uint32_t)(b))

/* pack 3-byte string to uint32_t */
#define PACK3(a, b, c) ((uint32_t)(a) << 16 | (uint32_t)(b) << 8 | (uint32_t)(c))

/* pack 4-byte string to uint32_t */
#define PACK4(a, b, c, d) ((uint32_t)(a) << 24 | (uint32_t)(b) << 16 | (uint32_t)(c) << 8 | (uint32_t)(d))

/* pack 8-byte string to uint64_t */
#define PACK8(a, b, c, d, e, f, g, h) ((uint64_t)(a) << 56 | (uint64_t)(b) << 48 | (uint64_t)(c) << 40 | (uint64_t)(d) << 32 | (uint64_t)(e) << 24 | (uint64_t)(f) << 16 | (uint64_t)(g) << 8 | (uint64_t)(h))

#define PACK1_FROM_STR(str, offset) PACK1(str[offset])

#define PACK2_FROM_STR(str, offset) PACK2(str[offset], str[offset + 1])

#define PACK3_FROM_STR(str, offset) PACK3(str[offset], str[offset + 1], str[offset + 2])

#define PACK4_FROM_STR(str, offset) PACK4(str[offset], str[offset + 1], str[offset + 2], str[offset + 3])

#define PACK5_FROM_STR(str, offset) PACK8(str[offset], str[offset + 1], str[offset + 2], str[offset + 3], str[offset + 4], '\0', '\0', '\0')

#define PACK6_FROM_STR(str, offset) PACK8(str[offset], str[offset + 1], str[offset + 2], str[offset + 3], str[offset + 4], str[offset + 5], '\0', '\0')

#define PACK7_FROM_STR(str, offset) PACK8(str[offset], str[offset + 1], str[offset + 2], str[offset + 3], str[offset + 4], str[offset + 5], str[offset + 6], '\0')
#define PACK8_FROM_STR(str, offset) PACK8(str[offset], str[offset + 1], str[offset + 2], str[offset + 3], str[offset + 4], str[offset + 5], str[offset + 6], str[offset + 7])

]]

    -- case_insensitive mode: add LC macros
    if opts.case_insensitive then
        macros[#macros + 1] = [[
#define PACK1_TOLOWER_SWAR_SAFE(x)                                             \
    ((x) | ((((x) + 0x3F) & ~((x) + 0x25) & 0x80) >> 2))


#define PACK2_TOLOWER_SWAR_SAFE(x)                                             \
    ((x) | (((((x) & 0x7F7FUL) + 0x3F3FUL) &                                   \
             ~(((x) & 0x7F7FUL) + 0x2525UL) & 0x8080UL) >> 2))


#define PACK3_TOLOWER_SWAR_SAFE(x)                                             \
    ((x) | (((((x) & 0x7F7F7FUL) + 0x3F3F3FUL) &                               \
             ~(((x) & 0x7F7F7FUL) + 0x252525UL) & 0x808080UL) >> 2))


/* pack 4-byte string to uint32_t SWAR lower-case conversion */
#define PACK4_TOLOWER_SWAR_SAFE(x)                                             \
    ((x) | (((((x) & 0x7F7F7F7FUL) + 0x3F3F3F3FUL) &                           \
             ~(((x) & 0x7F7F7F7FUL) + 0x25252525UL) & 0x80808080UL) >>         \
            2))


/* pack 8-byte string to uint64_t SWAR lower-case conversion */
#define PACK8_TOLOWER_SWAR_SAFE(x)                                             \
    ((x) | ((((((x) & 0x7F7F7F7F7F7F7F7FULL) + 0x3F3F3F3F3F3F3F3FULL) &      \
                ~(((x) & 0x7F7F7F7F7F7F7F7FULL) + 0x2525252525252525ULL) &     \
                0x8080808080808080ULL) &                                       \
               ~(x)) >>                                                        \
              2))

#define PACK1_LC(a) PACK1_TOLOWER_SWAR_SAFE(PACK1(a))

#define PACK2_LC(a, b) PACK2_TOLOWER_SWAR_SAFE(PACK2(a, b))

#define PACK3_LC(a, b, c) PACK3_TOLOWER_SWAR_SAFE(PACK3(a, b, c))

#define PACK4_LC(a, b, c, d) PACK4_TOLOWER_SWAR_SAFE(PACK4(a, b, c, d))

#define PACK8_LC(a, b, c, d, e, f, g, h)                                       \
    PACK8_TOLOWER_SWAR_SAFE(PACK8(a, b, c, d, e, f, g, h))

/* pack 1-byte string to uint32_t (case-insensitive) */
#define PACK1_FROM_STR_LC(str, offset) PACK1_TOLOWER_SWAR_SAFE(PACK1(str[offset]))

/* pack 2-byte string to uint32_t (case-insensitive) */
#define PACK2_FROM_STR_LC(str, offset) PACK2_TOLOWER_SWAR_SAFE(PACK2(str[offset], str[offset + 1]))

/* pack 3-byte string to uint32_t (case-insensitive) */
#define PACK3_FROM_STR_LC(str, offset) PACK3_TOLOWER_SWAR_SAFE(PACK3(str[offset], str[offset + 1], str[offset + 2]))

/* pack 4-byte string to uint32_t (case-insensitive) */
#define PACK4_FROM_STR_LC(str, offset) PACK4_TOLOWER_SWAR_SAFE(PACK4(str[offset], str[offset + 1], str[offset + 2], str[offset + 3]))

/* pack 5-byte string to uint64_t (case-insensitive) */
#define PACK5_FROM_STR_LC(str, offset) PACK8_TOLOWER_SWAR_SAFE(PACK8(str[offset], str[offset + 1], str[offset + 2], str[offset + 3], str[offset + 4], '\0', '\0', '\0'))

/* pack 6-byte string to uint64_t (case-insensitive) */
#define PACK6_FROM_STR_LC(str, offset) PACK8_TOLOWER_SWAR_SAFE(PACK8(str[offset], str[offset + 1], str[offset + 2], str[offset + 3], str[offset + 4], str[offset + 5], '\0', '\0'))

/* pack 7-byte string to uint64_t (case-insensitive) */
#define PACK7_FROM_STR_LC(str, offset) PACK8_TOLOWER_SWAR_SAFE(PACK8(str[offset], str[offset + 1], str[offset + 2], str[offset + 3], str[offset + 4], str[offset + 5], str[offset + 6], '\0'))

/* pack 8-byte string to uint64_t (case-insensitive) */
#define PACK8_FROM_STR_LC(str, offset) PACK8_TOLOWER_SWAR_SAFE(PACK8(str[offset], str[offset + 1], str[offset + 2], str[offset + 3], str[offset + 4], str[offset + 5], str[offset + 6], str[offset + 7]))
]]
    end

    -- packname defines
    macros[#macros + 1] = format([[
/* Packname defines */
%s
]], concat(DEFINE_PKNAMES, '\n'))

    return concat(macros, '\n')
end

local function gen_switch_lines(group, depth)
    local lines = {}

    -- if condition
    if group.ifcond then
        lines[#lines + 1] = format('%s%s', indent(depth), group.ifcond)
        return concat(lines, '\n')
    end

    -- switch statement
    lines[#lines + 1] = format('%s%s {', indent(depth), group.switch)
    lines[#lines + 1] = format('%sdefault: return -1;', indent(depth))
    -- switch cases
    for k, case in pairs(group.switch_cases) do
        if type(k) == 'number' then
            lines[#lines + 1] = format('%s%s', indent(depth), case)
        else
            lines[#lines + 1] = format('%s%s', indent(depth), case.case)
            lines[#lines + 1] = gen_switch_lines(case, depth + 1)
        end
    end

    lines[#lines + 1] = format('%s}', indent(depth))

    return concat(lines, '\n')
end

--- check if number is integer
--- @param n any
--- @return boolean ok
local function is_int(n)
    return type(n) == 'number' and n % 1 == 0
end

--- check non-empty string
--- @param s any
--- @return boolean ok
local function is_string(s)
    return type(s) == 'string' and s:find('%S') ~= nil
end

--- check optional string
--- @param s any
--- @return boolean ok
local function is_opt_string(s)
    return s == nil or is_string(s)
end

--- check optional boolean
--- @param b any
--- @return boolean ok
local function is_opt_boolean(b)
    return b == nil or type(b) == 'boolean'
end

--- @class strie2c.options
--- @field case_insensitive boolean?
--- @field func_name string?
--- @field return_type string?
--- @field includes string[]?

--- check options
--- @param options strie2c.options
local function checkopts(options)
    -- validate options
    assert(is_opt_boolean(options.case_insensitive),
           'options.case_insensitive must be boolean or nil')
    assert(is_opt_string(options.func_name),
           'options.func_name must be non-empty string or nil')
    assert(is_opt_string(options.return_type),
           'options.return_type must be non-empty string or nil')
    if options.includes == nil then
        return
    end
    assert(type(options.includes) == 'table' and #options.includes > 0,
           'options.includes must be a nil or a non-empty string[]')

    -- check each include string
    for i, inc in ipairs(options.includes) do
        assert(is_string(inc),
               format('options.includes#%d must be non-empty string', i))
    end
end

--- @class strie2c.kvpair
--- @field key string
--- @field val string

--- convert values to key-value pair array
--- @param values string[]|table<string, string|number> values list
--- @param opts strie2c.options
--- @return strie2c.kvpair[] kvpairs converted key-value pairs
local function values2kvpairs(values, opts)
    local kvpairs = {}
    local duplicates = {}
    local has_skey = false
    local has_ikey = false

    -- process values
    for k, v in pairs(values) do
        if is_string(k) then
            if type(v) ~= 'number' and not is_string(v) then
                -- in map style, value must be non-empty string or number
                error(format(
                          'values[%q] value must be non-empty string or number',
                          k))
            end
            has_skey = true
        elseif is_int(k) then
            if not is_string(v) then
                -- in array style, value must be non-empty string
                error(format('values#%d must be non-empty strings', k))
            elseif duplicates[v] then
                error(format('values#%d duplicate label found: %s', k, v))
            end
            duplicates[v] = true
            has_ikey = true

            -- swap k and v (use v as string key, k as integer value)
            k, v = v, tostring(k)
        else
            error(format(
                      'values keys must be non-empty strings or integers, got %q (%q)',
                      type(k), tostring(k)))
        end

        if has_ikey and has_skey then
            error('values must not contain both string and integer keys')
        end

        -- add to kvpairs
        kvpairs[#kvpairs + 1] = {
            key = opts.case_insensitive and lower(k) or k,
            val = tostring(v),
        }
    end

    return kvpairs
end

--- build switch cases for labels
--- @param values string[]|table<string, string|number> values list
--- @param options table options (case_insensitive: boolean, func_name: string, includes: string[])
--- @return string source generated C source code
--- @return table[] groups generated groups
local function gencode(values, options)
    -- generate timestamp-based default names
    local timestamp = os.date('%Y%m%dT%H%M%S')

    -- validate arguments
    assert(type(values) == 'table', 'values must be a table')
    assert(next(values) ~= nil, 'values must not be empty')
    if options ~= nil then
        assert(type(options) == 'table', 'options must be a table or nil')
        checkopts(options)
    end
    -- shallow copy options and add strcase suffix
    local opts = {}
    for k, v in pairs(options or {}) do
        opts[k] = v
    end
    -- set strcase suffix
    opts.strcase = opts.case_insensitive and '_LC' or ''

    -- convert values to kvpairs
    local kvpairs = values2kvpairs(values, opts)
    -- set function, header and include-guard names
    local return_type = opts.return_type or 'int'
    local func_name = opts.func_name or format('strie2c_find_%s', timestamp)
    local includes = opts.includes or {}

    -- grouping by length
    local groups = make_groups(kvpairs, opts)
    local depth = 1

    -- generate source file content
    local slines = {}
    -- source comment with algorithm description
    slines[#slines + 1] = format([[
/*
 * Generated by strie2c (Static Trie to C code generator)
 * https://github.com/mah0x211/lua-strie2c
 * Generated at: %s
 * DO NOT EDIT - This file is auto-generated
 *
 * Algorithm:
 *   Static trie compiled into hierarchical switch-case statements:
 *   - Stage 1: Length partitioning (switch on string length)
 *   - Stage 2+: Prefix matching using packed integers (PACK8/PACK4)
 *     * 8-byte chunks loaded with SIMD, packed into 64-bit/32-bit integers
 *     * Single integer comparison for entire chunk (O(1) per stage)
 *     * Recursive descent for remaining bytes
 *   - Leaf: memcmp for final confirmation when single item remains
 *
 * Performance characteristics:
 *   - Best case (unique prefix): ~3-5 CPU cycles (length + one PACK8 compare + branch)
 *   - Worst case (deep collision): O(L/8) stages where L = string length
 *   - Memory: No hash table lookups, all constants are compile-time embedded
 *   - Branch prediction friendly: Each stage has predictable jump targets
 */
#include <stddef.h>
#include <stdint.h>
#include <string.h>
]], timestamp)

    -- includes
    if #includes > 0 then
        slines[#slines + 1] = format([[#include %s]],
                                     concat(includes, '\n#include '))
        slines[#slines + 1] = ''
    end

    -- packname defines
    slines[#slines + 1] = gen_define_packnames(opts)
    slines[#slines + 1] = ''

    -- function implementation
    slines[#slines + 1] = format([[
%s %s(const char *str, size_t len) {
    switch (len) {]], return_type, func_name)

    slines[#slines + 1] = format('%sdefault: return -1;', indent(depth))

    for _, group in ipairs(groups) do
        slines[#slines + 1] = format('%s%s', indent(depth), group.case)
        slines[#slines + 1] = gen_switch_lines(group, depth + 1)
    end

    slines[#slines + 1] = format('%s}', indent(depth))
    slines[#slines + 1] = '}'
    slines[#slines + 1] = ''

    return concat(slines, '\n'), groups
end

return gencode
