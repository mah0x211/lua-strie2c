local dofile = dofile
for _, pathname in ipairs({
    'test/hash_test.lua',
    'test/strie2c_test.lua',
}) do
    dofile(pathname)
end
