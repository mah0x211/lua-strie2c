local chdir = require('chdir')
local CWD = (function()
    local p = assert(io.popen('pwd'))
    local cwd = p:read('*l')
    p:close()
    return cwd
end)()
assert(chdir(arg[0]:match('^(.*)/[^/]+$') or '.'))

local assert = require('assert')
-- require local binding
local hash = require('strie2c.hash')

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

function testcase.rapidhash_basic()
    local s = "example"
    local h = hash(s)
    local h_str = h:get()

    assert.match(h_str, "^0x%x+$", false)
    -- Check length (0x + 16 chars)
    assert.equal(#h_str, 18, "should be 18 chars (0x + 16 hex digits)")
end

function testcase.rapidhash_consistency()
    local s = "example"
    local h1 = hash(s, 0, 0)
    local h2 = hash(s, 0, 0)
    assert.equal(h1:get(), h2:get(),
                 "same input and seed should produce same hash")

    local h3 = hash(s) -- default seed 0
    assert.equal(h1:get(), h3:get(), "default seed should match explicit 0 seed")
end

function testcase.rapidhash_seed_variance()
    local s = "example"
    local h_ref = hash(s, 0, 0)
    local h_var = hash(s, 0, 12345)
    assert.not_equal(h_ref:get(), h_var:get(),
                     "different seeds should produce different hashes")
end

function testcase.bucket_logic()
    -- We test bucket logic by calculating hash and manually verifying
    -- index = (hash >> shift) & mask
    local s = "consistency_check"
    local h = hash(s)
    local h_str = h:get()

    -- Extract last hex char manually to simulate (h >> 0) & 0xF
    local last_char = string.sub(h_str, -1)
    local expected_idx = tonumber(last_char, 16)

    local idx = h:bucket(0, 0xF)
    assert.equal(idx, expected_idx, "bucket(0, 0xF) should match last hex digit")

    -- Test bad arguments
    local err = assert.throws(function()
        h:bucket(-1, 0xF)
    end)
    assert.match(tostring(err), "shift must be >= 0", false)

    err = assert.throws(function()
        h:bucket(0, 0)
    end)
    assert.match(tostring(err), "mask must be > 0", false)
end

-- Run tests
local after_each = testfn[testcase.after_each] or function()
end
table.remove(testfn, testfn.after_each)

print(string.format('Running %d tests...', #testfn))
print(string.rep('=', 20))
for _, t in ipairs(testfn) do
    io.write(string.format('TEST %-40s ...', t.name))
    local ok, err = pcall(t.fn)
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
