require('luacov')
local chdir = require('chdir')
local CWD = (function()
    local p = assert(io.popen('pwd'))
    local cwd = p:read('*l')
    p:close()
    return cwd
end)()
assert(chdir(arg[0]:match('^(.*)/[^/]+$') or '.'))

local assert = require('assert')
local dlopen = require('dlopen')
local strie2c = require('strie2c')
local testfn = {}
local testcase = setmetatable({}, {
    __newindex = function(_, k, v)
        assert(type(k) == 'string', 'testcase key must be a string')
        assert(type(v) == 'function', 'testcase value must be a function')
        if testfn[k] then
            error(string.format('testcase.%s already exists', k))
        end
        testfn[#testfn + 1] = {
            name = k,
            fn = v,
        }
        testfn[k] = #testfn
    end,
})

local function writefile(pathname, content)
    local f = assert(io.open(pathname, 'w'))
    f:write(content)
    f:close()
end

local function readfile(pathname)
    local f = assert(io.open(pathname, 'r'))
    local content = f:read('*a')
    f:close()
    return content
end

local function exec(cmd)
    local r1, r2, r3 = os.execute(cmd)
    -- Lua 5.1
    if type(r1) == "number" then
        return r1 == 0, "exit", r1
    end
    -- Lua 5.2+
    return r1, r2, r3
end

local DSO
function testcase.after_each()
    -- unload module after each test
    if DSO then
        DSO:dlclose()
        DSO = nil
    end
end

local function build_module(source, ret_type, funcname, arg_type, ...)
    -- derive output filenames
    assert(funcname:find('^[%w_]+$'), 'funcname must be /^[a-zA-Z0-9_]+$/')
    local dirname = './lib/'
    -- ensure output directory exists
    os.execute('mkdir -p ' .. dirname)

    local c_filename = dirname .. funcname .. '.c'
    local so_filename = dirname .. funcname .. '.so'
    local o_filename = dirname .. funcname .. '.o'

    -- write source file
    writefile(c_filename, source)

    -- remove old .so and .o files to force rebuild
    os.remove(so_filename)
    os.remove(o_filename)

    -- compile to shared object with gcc
    local ok, reason, rc = exec(table.concat({
        'gcc -shared -fPIC',
        '-o ' .. so_filename,
        '-I.',
        '-O2',
        '-Wall -Wextra',
        c_filename,
        '> build.log 2>&1',
    }, ' '))
    if not ok then
        local log = readfile('./build.log')
        print('==== build.log ====')
        print(log)
        print('===================')
        error(string.format('failed to build module: %s (%s)', reason, rc))
    end

    -- load built module
    local dso = assert(dlopen(so_filename))
    -- load symbol
    assert(dso:dlsym(ret_type, funcname, arg_type, ...))
    DSO = dso

    -- remove generated files
    os.remove(o_filename)
    os.remove(so_filename)
    os.remove('./build.log')

    return dso
end

function testcase.string_array()
    -- test that generate code with string array input
    local values = {
        'foo',
        'bar',
        'baz',
    }
    local result = strie2c(values, {
        func_name = 'int strie_test',
    })
    assert.is_string(result)
    local dso = build_module(result, 'int', 'strie_test', 'char*', 'size_t')

    -- test that generated function works correctly
    assert.equal(dso:strie_test('foo', 3), 1)
    assert.equal(dso:strie_test('bar', 3), 2)
    assert.equal(dso:strie_test('baz', 3), 3)
end

function testcase.kvpairs()
    -- test that gencode() returns generated code strings
    local values = {
        foo = 1,
        bar = 2,
        baz = 3,
    }
    local result = strie2c(values, {
        func_name = 'int test_kvpairs',
    })
    assert.is_string(result)
    local dso = build_module(result, 'int', 'test_kvpairs', 'char*', 'size_t')

    -- test that generated function works correctly
    assert.equal(dso:test_kvpairs('foo', 3), 1)
    assert.equal(dso:test_kvpairs('bar', 3), 2)
    assert.equal(dso:test_kvpairs('baz', 3), 3)
end

function testcase.case_insensitive()
    -- test case_insensitive option
    local values = {
        Foo = 1,
        BAR = 2,
        BaZ = 3,
    }
    local result = strie2c(values, {
        func_name = 'int test_case_insensitive',
        case_insensitive = true,
    })
    assert.is_string(result)
    local dso = build_module(result, 'int', 'test_case_insensitive', 'char*',
                             'size_t')

    -- test that case-insensitive matching works
    assert.equal(dso:test_case_insensitive('foo', 3), 1)
    assert.equal(dso:test_case_insensitive('FOO', 3), 1)
    assert.equal(dso:test_case_insensitive('Foo', 3), 1)
    assert.equal(dso:test_case_insensitive('bar', 3), 2)
    assert.equal(dso:test_case_insensitive('BAR', 3), 2)
    assert.equal(dso:test_case_insensitive('baz', 3), 3)
    assert.equal(dso:test_case_insensitive('Baz', 3), 3)
end

function testcase.string_values()
    -- test string values (C constant names)
    -- create test_constants.h
    writefile('./test_constants.h', [[
#define HTTP_ACCEPT 100
#define HTTP_CONTENT_TYPE 200
#define HTTP_HOST 300
]])

    local values = {
        accept = 'HTTP_ACCEPT',
        ['content-type'] = 'HTTP_CONTENT_TYPE',
        host = 'HTTP_HOST',
    }
    local result = strie2c(values, {
        func_name = 'int test_string_values',
        includes = {
            '<stddef.h>',
            '"test_constants.h"',
        },
    })
    assert.is_string(result)
    local dso = build_module(result, 'int', 'test_string_values', 'char*',
                             'size_t')

    assert.equal(dso:test_string_values('accept', 6), 100)
    assert.equal(dso:test_string_values('content-type', 12), 200)
    assert.equal(dso:test_string_values('host', 4), 300)

    -- cleanup
    os.remove('./test_constants.h')
end

function testcase.various_lengths()
    -- test labels with various lengths
    local values = {
        a = 1,
        ab = 2,
        abc = 3,
        abcd = 4,
        abcde = 5,
        abcdef = 6,
        abcdefg = 7,
        abcdefgh = 8,
        abcdefghi = 9,
        ['content-encoding'] = 10,
    }
    local result = strie2c(values, {
        func_name = 'int test_various_lengths',
    })
    assert.is_string(result)
    local dso = build_module(result, 'int', 'test_various_lengths', 'char*',
                             'size_t')

    assert.equal(dso:test_various_lengths('a', 1), 1)
    assert.equal(dso:test_various_lengths('ab', 2), 2)
    assert.equal(dso:test_various_lengths('abc', 3), 3)
    assert.equal(dso:test_various_lengths('abcd', 4), 4)
    assert.equal(dso:test_various_lengths('abcde', 5), 5)
    assert.equal(dso:test_various_lengths('abcdef', 6), 6)
    assert.equal(dso:test_various_lengths('abcdefg', 7), 7)
    assert.equal(dso:test_various_lengths('abcdefgh', 8), 8)
    assert.equal(dso:test_various_lengths('abcdefghi', 9), 9)
    assert.equal(dso:test_various_lengths('content-encoding', 16), 10)
end

function testcase.http_headers()
    -- test with realistic HTTP header names
    local values = {
        accept = 1,
        ['accept-charset'] = 2,
        ['accept-encoding'] = 3,
        ['accept-language'] = 4,
        authorization = 5,
        ['cache-control'] = 6,
        connection = 7,
        ['content-encoding'] = 8,
        ['content-language'] = 9,
        ['content-length'] = 10,
        ['content-location'] = 11,
        ['content-type'] = 12,
        date = 13,
        etag = 14,
        expect = 15,
        from = 16,
        host = 17,
        ['if-match'] = 18,
        ['if-modified-since'] = 19,
        ['if-none-match'] = 20,
        ['if-range'] = 21,
        ['if-unmodified-since'] = 22,
        ['last-modified'] = 23,
        location = 24,
        range = 25,
        referer = 26,
        server = 27,
        te = 28,
        trailer = 29,
        ['transfer-encoding'] = 30,
        upgrade = 31,
        ['user-agent'] = 32,
        via = 33,
        warning = 34,
    }
    local result = strie2c(values, {
        func_name = 'int test_http_headers',
    })
    assert.is_string(result)
    local dso = build_module(result, 'int', 'test_http_headers', 'char*',
                             'size_t')

    -- test some headers
    assert.equal(dso:test_http_headers('accept', 6), 1)
    assert.equal(dso:test_http_headers('content-type', 12), 12)
    assert.equal(dso:test_http_headers('host', 4), 17)
    assert.equal(dso:test_http_headers('user-agent', 10), 32)
    assert.equal(dso:test_http_headers('transfer-encoding', 17), 30)
    assert.equal(dso:test_http_headers('if-modified-since', 17), 19)
end

function testcase.invalid_input_types()
    -- test that invalid input types raise errors
    local err = assert.throws(strie2c, nil)
    assert.match(err, 'values must be a table')

    err = assert.throws(strie2c, 123)
    assert.match(err, 'values must be a table')

    err = assert.throws(strie2c, true)
    assert.match(err, 'values must be a table')

    err = assert.throws(strie2c, 'string')
    assert.match(err, 'values must be a table')

    err = assert.throws(strie2c, function()
    end)
    assert.match(err, 'values must be a table')
end

function testcase.invalid_value_types()
    -- test that invalid value types raise errors (map style)
    local err = assert.throws(strie2c, {
        foo = {},
    })
    assert.match(err, 'value must be non-empty string or number')

    err = assert.throws(strie2c, {
        foo = function()
        end,
    })
    assert.match(err, 'value must be non-empty string or number')

    err = assert.throws(strie2c, {
        foo = true,
    })
    assert.match(err, 'value must be non-empty string or number')

    -- test that invalid value types raise errors (array style)
    err = assert.throws(strie2c, {
        123,
        456,
    })
    assert.match(err, 'must be non-empty strings')

    err = assert.throws(strie2c, {
        foo = 'bar',
        123,
    })
    assert.match(err, 'must be non-empty strings')
end

function testcase.empty_table()
    -- test that empty table raises an error
    local err = assert.throws(strie2c, {})
    assert.match(err, 'values must not be empty')
end

function testcase.empty_string_key()
    -- test that empty string key raises an error (map style)
    local err = assert.throws(strie2c, {
        [''] = 1,
    })
    assert.match(err, 'keys must be non-empty strings or integers')

    -- test that empty string key raises an error (array style)
    err = assert.throws(strie2c, {
        '',
        'foo',
    })
    assert.match(err, 'must be non-empty strings')
end

function testcase.not_found()
    -- test that searching for non-existent strings returns -1
    local values = {
        foo = 1,
        bar = 2,
        baz = 3,
    }
    local result = strie2c(values, {
        func_name = 'int test_not_found',
    })
    assert.is_string(result)
    local dso = build_module(result, 'int', 'test_not_found', 'char*', 'size_t')

    -- test that non-existent strings return -1
    assert.equal(dso:test_not_found('qux', 3), -1)
    assert.equal(dso:test_not_found('hello', 5), -1)
    assert.equal(dso:test_not_found('world', 5), -1)
    assert.equal(dso:test_not_found('', 0), -1)

    -- test that valid strings still return correct values
    assert.equal(dso:test_not_found('foo', 3), 1)
    assert.equal(dso:test_not_found('bar', 3), 2)
    assert.equal(dso:test_not_found('baz', 3), 3)
end

function testcase.invalid_options()
    local values = {
        foo = 1,
        bar = 2,
    }

    -- test invalid case_insensitive values
    local err = assert.throws(strie2c, values, {
        case_insensitive = 'true',
    })
    assert.match(err, 'case_insensitive must be boolean or nil')

    err = assert.throws(strie2c, values, {
        case_insensitive = 1,
    })
    assert.match(err, 'case_insensitive must be boolean or nil')

    -- test invalid func_name values
    err = assert.throws(strie2c, values, {
        func_name = '',
    })
    assert.match(err, 'func_name must be non-empty string or nil')

    err = assert.throws(strie2c, values, {
        func_name = 123,
    })
    assert.match(err, 'func_name must be non-empty string or nil')

    -- test invalid includes values
    err = assert.throws(strie2c, values, {
        includes = {},
    })
    assert.match(err, 'includes must be a nil or a non-empty string[]')

    err = assert.throws(strie2c, values, {
        includes = 'string',
    })
    assert.match(err, 'includes must be a nil or a non-empty string[]')

    err = assert.throws(strie2c, values, {
        includes = {
            '',
        },
    })
    assert.match(err, 'includes#1 must be non-empty string')
end

function testcase.very_long_strings()
    -- test that very long strings work correctly
    local values = {
        a = 1,
        -- 64 character string
        ['aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'] = 2,
        -- mixed length strings
        x = 3,
        yy = 4,
        zzz = 5,
        -- long string with special chars
        ['xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'] = 6,
    }
    local result = strie2c(values, {
        func_name = 'int test_very_long_strings',
    })
    assert.is_string(result)
    local dso = build_module(result, 'int', 'test_very_long_strings', 'char*',
                             'size_t')

    -- test that all strings are found correctly
    assert.equal(dso:test_very_long_strings('a', 1), 1)
    assert.equal(dso:test_very_long_strings(
                     'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                     64), 2)
    assert.equal(dso:test_very_long_strings('x', 1), 3)
    assert.equal(dso:test_very_long_strings('yy', 2), 4)
    assert.equal(dso:test_very_long_strings('zzz', 3), 5)
    assert.equal(dso:test_very_long_strings(
                     'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
                     64), 6)
end

function testcase.special_chars()
    -- test that keys with special characters work correctly
    local values = {
        ['foo-bar'] = 1,
        ['foo_bar'] = 2,
        ['foo.bar'] = 3,
        ['foo:bar'] = 4,
        ['foo/bar'] = 5,
        ['foo\\bar'] = 6,
        ['foo@bar'] = 7,
        ['foo+bar'] = 8,
        ['foo=bar'] = 9,
        ['foo$bar'] = 10,
    }
    local result = strie2c(values, {
        func_name = 'int test_special_chars',
    })
    assert.is_string(result)
    local dso = build_module(result, 'int', 'test_special_chars', 'char*',
                             'size_t')

    -- test that all special character keys are found correctly
    assert.equal(dso:test_special_chars('foo-bar', 7), 1)
    assert.equal(dso:test_special_chars('foo_bar', 7), 2)
    assert.equal(dso:test_special_chars('foo.bar', 7), 3)
    assert.equal(dso:test_special_chars('foo:bar', 7), 4)
    assert.equal(dso:test_special_chars('foo/bar', 7), 5)
    assert.equal(dso:test_special_chars('foo\\bar', 7), 6)
    assert.equal(dso:test_special_chars('foo@bar', 7), 7)
    assert.equal(dso:test_special_chars('foo+bar', 7), 8)
    assert.equal(dso:test_special_chars('foo=bar', 7), 9)
    assert.equal(dso:test_special_chars('foo$bar', 7), 10)
end

function testcase.single_quote_in_label()
    -- test that single quote in label is properly escaped
    local values = {
        ["foo'bar"] = 1,
        baz = 2,
    }
    local result = strie2c(values, {
        func_name = 'int test_single_quote',
    })
    assert.is_string(result)
    local dso = build_module(result, 'int', 'test_single_quote', 'char*',
                             'size_t')

    assert.equal(dso:test_single_quote("foo'bar", 7), 1)
    assert.equal(dso:test_single_quote('baz', 3), 2)
end

function testcase.nine_to_sixteen_chars_same_prefix()
    -- test labels with 9-16 chars sharing same 8-char prefix
    -- this covers gen_switch8(subgroup, offset + 8, opts) path
    local values = {
        ['abcdefghi'] = 1, -- 9 chars
        ['abcdefgh123'] = 2, -- 11 chars, same prefix
        ['abcdefghxyz'] = 3, -- 11 chars, same prefix
    }
    local result = strie2c(values, {
        func_name = 'int test_same_prefix',
    })
    assert.is_string(result)

    local dso = build_module(result, 'int', 'test_same_prefix', 'char*',
                             'size_t')

    assert.equal(dso:test_same_prefix('abcdefghi', 9), 1)
    assert.equal(dso:test_same_prefix('abcdefgh123', 11), 2)
    assert.equal(dso:test_same_prefix('abcdefghxyz', 11), 3)
end

function testcase.long_common_prefix_recursion()
    -- test labels with very long common prefix (> 8 bytes) to verify recursive processing
    -- specifically checks if remaining length is calculated correctly in gen_switch8over
    local values = {
        ["access-control-allow-headers"] = 51,
        ["access-control-allow-methods"] = 52,
    }
    local result = strie2c(values, {
        func_name = 'int test_long_prefix',
    })
    assert.is_string(result)

    local dso = build_module(result, 'int', 'test_long_prefix', 'char*',
                             'size_t')

    assert.equal(dso:test_long_prefix('access-control-allow-headers', 28), 51)
    assert.equal(dso:test_long_prefix('access-control-allow-methods', 28), 52)
end

function testcase.duplicate_labels()
    -- test that duplicate labels in array style raise an error
    local err = assert.throws(strie2c, {
        'foo',
        'bar',
        'foo',
    })
    assert.match(err, 'duplicate label found')
end

function testcase.mixed_string_and_integer_keys()
    -- test that mixing string and integer keys raises an error
    local err = assert.throws(strie2c, {
        foo = 1,
        [2] = 'bar',
    })
    assert.match(err, 'must not contain both string and integer keys')
end

-- run all tests
local after_each = testfn[testcase.after_each] or function()
end
table.remove(testfn, testfn.after_each)

print(string.format('Running %d tests...', #testfn))
print(string.rep('=', 20))
for _, test in ipairs(testfn) do
    collectgarbage('collect')
    io.write(string.format('Running test: %s... ', test.name))
    io.flush()
    local ok, err = pcall(test.fn)
    if ok then
        io.write('OK\n')
    else
        io.write('FAILED\n')
        io.write('Error: ' .. tostring(err) .. '\n')
    end

    after_each()
end
print(string.rep('=', 20))
print('All tests completed.')
assert(chdir(CWD))
