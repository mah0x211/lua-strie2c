#include "rapidhash.h"
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
// lua headers
#include <lauxlib.h>
#include <lua.h>

#define MODULE_MT "strie2c.hash"

// default 64bit seed (hi/lo)
#define DEFAULT_SEED_HI 0x0
#define DEFAULT_SEED_LO 0x0

typedef struct {
    uint64_t seed;
    uint64_t hash;
} strie2c_hash_t;

// Lua: index = h:bucket(shift, mask)
// Returns: integer index
static int bucket_lua(lua_State *L)
{
    strie2c_hash_t *h = luaL_checkudata(L, 1, MODULE_MT);
    lua_Integer shift = luaL_checkinteger(L, 2);
    lua_Integer mask  = luaL_checkinteger(L, 3);

    luaL_argcheck(L, shift >= 0, 2, "shift must be >= 0");
    luaL_argcheck(L, mask > 0, 3, "mask must be > 0");

    // Calculation: (hash >> shift) & mask
    lua_pushinteger(L, (lua_Integer)((h->hash >> shift) & mask));

    return 1;
}

// Lua: str = h:get()
// Returns: hex string of hash value
static int get_lua(lua_State *L)
{
    strie2c_hash_t *h = luaL_checkudata(L, 1, MODULE_MT);
    char buf[32];
    sprintf(buf, "0x%" PRIx64, h->hash);
    lua_pushstring(L, buf);
    return 1;
}

static int tostring_lua(lua_State *L)
{
    strie2c_hash_t *h = luaL_checkudata(L, 1, MODULE_MT);
    char buf[128]     = {0};
    // format: strie2c.hash: <hash> (seed: <seed>)
    int len           = snprintf(buf, sizeof(buf) - 1,
                                 MODULE_MT ": 0x%" PRIx64 " (seed: 0x%" PRIx64 ")",
                                 h->hash, h->seed);
    lua_pushlstring(L, buf, len);
    return 1;
}

// Lua: h = new(str, [seed_hi, seed_lo])
// Returns: hash userdata
static int new_lua(lua_State *L)
{
    size_t len        = 0;
    const char *str   = luaL_checklstring(L, 1, &len);
    // NOTE: seed can be passed as two 32-bit integers to support full 64-bit
    // range in Lua 5.1
    lua_Integer seedh = luaL_optinteger(L, 2, DEFAULT_SEED_HI);
    lua_Integer seedl = luaL_optinteger(L, 3, DEFAULT_SEED_LO);
    strie2c_hash_t *h = lua_newuserdata(L, sizeof(strie2c_hash_t));

    h->seed = (uint64_t)seedh << 32 | (uint64_t)seedl;
    h->hash = rapidhash_withSeed(str, len, h->seed);

    luaL_getmetatable(L, MODULE_MT);
    lua_setmetatable(L, -2);
    return 1;
}

// Export the function using luaopen_...
// Lua 5.1/5.2 compatibility
LUALIB_API int luaopen_strie2c_hash(lua_State *L)
{
    // Create metatable
    if (luaL_newmetatable(L, MODULE_MT)) {
        struct luaL_Reg method[] = {
            {"get",    get_lua   },
            {"bucket", bucket_lua},
            {NULL,     NULL      }
        };

        // metamethods
        lua_pushcfunction(L, tostring_lua);
        lua_setfield(L, -2, "__tostring");
        // methods
        lua_createtable(L, 0, 1);
        for (struct luaL_Reg *ptr = method; ptr->name; ptr++) {
            lua_pushcfunction(L, ptr->func);
            lua_setfield(L, -2, ptr->name);
        }
        lua_setfield(L, -2, "__index");
    }

    // Return constructor function
    lua_pushcfunction(L, new_lua);
    return 1;
}
