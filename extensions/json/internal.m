@import Cocoa ;
@import LuaSkin ;

#define get_objectFromUserdata(objType, L, idx, tag) (objType*)*((void**)luaL_checkudata(L, idx, tag))

@interface HSjsonProxy : NSObject
- (id)initWithFileAtPath:(NSString *)filePath;
- (id)initWithDictionary:(NSDictionary *)dict;
- (id)objectForKey:(id)key;
- (NSUInteger)getLength;
@property NSDictionary *jsonObject;
@property (readonly, getter=getLength) NSUInteger *length;
@end

@implementation HSjsonProxy

- (id)initWithFileAtPath:(NSString *)filePath {
    self = [super init];
    if (self) {
        LuaSkin *skin = [LuaSkin shared];
        NSError *error;

        NSData *fileData = [NSData dataWithContentsOfFile:filePath options:NSDataReadingMapped error:&error];
        if (!fileData) {
            [skin logError:[NSString stringWithFormat:@"hs.json.proxyDecodeAtPath failed to read %@: %@", filePath, error.localizedDescription]];
            return nil;
        }

        id jsonObject = [NSJSONSerialization JSONObjectWithData:fileData options:NSJSONReadingAllowFragments error:&error];

        if (!jsonObject) {
            [skin logError:[NSString stringWithFormat:@"hs.json proxyDecodeAtPath failed to decode %@:%@", filePath, error.localizedDescription]];
            return nil;
        }

        if ([jsonObject isKindOfClass:[NSArray class]]) {
            // We'll rarely hit a JSON document whose top level is an Array, but we can just convert that to an NSDictionary anyway
            self.jsonObject = [self indexKeyedDictionaryFromArray:(NSArray *)jsonObject];
        } else {
            self.jsonObject = jsonObject;
        }
    }
    return self;
}

- (id)initWithDictionary:(NSDictionary *)dict {
    self = [super self];
    if (self) {
        self.jsonObject = dict;
    }
    return self;
}

- (NSDictionary *) indexKeyedDictionaryFromArray:(NSArray *)array
{
    id objectInstance;
    NSUInteger indexKey = 0U;

    NSMutableDictionary *mutableDictionary = [[NSMutableDictionary alloc] init];
    for (objectInstance in array)
        [mutableDictionary setObject:objectInstance forKey:[NSNumber numberWithUnsignedInteger:indexKey++]];

    return (NSDictionary *)mutableDictionary;
}

- (id)objectForKey:(id)key {
    return [self.jsonObject objectForKey:key];
}

- (NSUInteger)getLength {
    return self.jsonObject.count;
}
@end

/// hs.json.encode(val[, prettyprint]) -> string
/// Function
/// Encodes a table as JSON
///
/// Parameters:
///  * val - A table containing data to be encoded as JSON
///  * prettyprint - An optional boolean, true to format the JSON for human readability, false to format the JSON for size efficiency. Defaults to false
///
/// Returns:
///  * A string containing a JSON representation of the supplied table
///
/// Notes:
///  * This is useful for storing some of the more complex lua table structures as a persistent setting (see `hs.settings`)
static int json_encode(lua_State* L) {
    if lua_istable(L, 1) {
        id obj = [[LuaSkin shared] toNSObjectAtIndex:1] ;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wassign-enum"
        NSJSONWritingOptions opts = 0;
#pragma clang diagnostic pop

        if (lua_toboolean(L, 2))
            opts = NSJSONWritingPrettyPrinted;

        if ([NSJSONSerialization isValidJSONObject:obj]) {
            NSError* error;
            NSData* data = [NSJSONSerialization dataWithJSONObject:obj options:opts error:&error];

			if (error) {
				return luaL_error(L, "%s", [[error localizedDescription] UTF8String]);
			} else if (data) {
				NSString* str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                lua_pushstring(L, [str UTF8String]);
                return 1;
			} else {
				return luaL_error(L, "json output returned nil") ;
			}

        } else {
            luaL_error(L, "object cannot be encoded as a json string") ;
            return 0;
        }
    } else {
        lua_pop(L, 1) ;
        luaL_error(L, "non-table object given to json encoder");
        return 0;
    }
}

/// hs.json.decode(jsonString) -> table
/// Function
/// Decodes JSON into a table
///
/// Parameters:
///  * jsonString - A string containing some JSON data
///
/// Returns:
///  * A table representing the supplied JSON data
///
/// Notes:
///  * This is useful for retrieving some of the more complex lua table structures as a persistent setting (see `hs.settings`)
static int json_decode(lua_State* L) {
    LuaSkin *skin = [LuaSkin shared] ;
    [skin checkArgs:LS_TSTRING, LS_TBREAK] ;
    NSData* data = [skin toNSObjectAtIndex:1 withOptions:LS_NSLuaStringAsDataOnly] ;
    if (data) {
        NSError* error;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:&error];

		if (error) {
			return luaL_error(L, "%s", [[error localizedDescription] UTF8String]);
		} else if (obj) {
			[[LuaSkin shared] pushNSObject:obj] ;
			return 1;
		} else {
			return luaL_error(L, "json input returned nil") ;
		}

    } else {
        return luaL_error(L, "Unable to convert json input into data structure.") ;
    }
}

// Methods for hs.json proxy objects
static int json_proxyTableIndex(lua_State *L);
static int json_proxyTablePairs(lua_State *L);
static int json_proxyTableIPairs(lua_State *L);
static int json_proxyGC(lua_State *L);
static const luaL_Reg jsonProxyTableMetatable[] = {
    {"__index", json_proxyTableIndex},
    {"__newindex", json_proxyTableNewIndex},
    {"__pairs", json_proxyTablePairs},
    {"__ipairs", json_proxyTableIPairs},
    {"__len", json_proxyTableLen},
    {NULL,  NULL}
};
static const luaL_Reg jsonProxyUserdataMetatable[] = {
    {"__gc", json_proxyGC},
    {NULL,  NULL}
};
#define USERDATA_JSONPROXY_TAG "hs.jsonProxy"

static int json_proxyDecodeAtPath(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared];
    [skin checkArgs:LS_TSTRING, LS_TBREAK];

    HSjsonProxy *proxy = [[HSjsonProxy alloc] initWithFileAtPath:[skin toNSObjectAtIndex:1]];

    if (!proxy) {
        lua_pushnil(L);
        return 1;
    }

    lua_newtable(L); // Table is -1
    void **userData = lua_newuserdata(L, sizeof(HSjsonProxy*)); // Userdata is -1, table is -2
    *userData = (__bridge_retained void*)proxy;
    luaL_getmetatable(L, USERDATA_JSONPROXY_TAG); // Metatable is -1, userdata is -2, table is -3
    lua_setmetatable(L, -2); // Userdata is -1, table is -2
    lua_setfield(L, -2, "__HSjsonProxy"); // Table is -1

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wconstant-conversion"
#pragma GCC diagnostic ignored "-Wsizeof-pointer-div"
    luaL_newlib(L, jsonProxyTableMetatable); // newlib is -1, table is -2
#pragma GCC diagnostic pop
    lua_setmetatable(L, -2); // table is -1

    lua_pushvalue(L, -1);
    return 1;
}

static int json_proxyTableIndex(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared];
    [skin checkArgs:LS_TTABLE, LS_TSTRING | LS_TINTEGER | LS_TNUMBER, LS_TBREAK];

    lua_pushstring(L, "__HSjsonProxy");
    lua_rawget(L, 1);

    HSjsonProxy *jsonProxy = get_objectFromUserdata(__bridge HSjsonProxy, L, -1, USERDATA_JSONPROXY_TAG);
    if (!jsonProxy) {
        luaL_error(L, "hs.json proxy table malformed, __HSjsonProxy is not userdata");
        return 0;
    }

    id key = [skin toNSObjectAtIndex:2];
    id value = [jsonProxy objectForKey:key];

    if ([value isKindOfClass:[NSDictionary class]]) {
        // This needs to be handled as a proxy object too
        lua_newtable(L); // table is -1
        void **userData = lua_newuserdata(L, sizeof(HSjsonProxy*)); // userdata is -1, table is -2
        *userData = (__bridge_retained void*)[[HSjsonProxy alloc] initWithDictionary:value];
        luaL_getmetatable(L, USERDATA_JSONPROXY_TAG); // metatable is -1, userdata is -2, table is -3
        lua_setmetatable(L, -2); // userdata is -1, table is -2
        lua_setfield(L, -2, "__HSjsonProxy"); // table is -1

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wconstant-conversion"
#pragma GCC diagnostic ignored "-Wsizeof-pointer-div"
        luaL_newlib(L, jsonProxyTableMetatable); // newlib is -1, table is -2
#pragma GCC diagnostic pop
        lua_setmetatable(L, -2); // table is -1
    } else {
        [skin pushNSObject:value];
    }

    return 1;
}

static int json_proxyTableNewIndex(lua_State *L) {
    luaL_error(L, "hs.json proxy objects are currently read-only");
    return 0;
}

static int json_proxyTablePairs(lua_State *L) {
    luaL_error(L, "__pairs unimplemented");
    return 0;
}

static int json_proxyTableIPairs(lua_State *L) {
    luaL_error(L, "__ipairs unimplemented");
    return 0;
}

static int json_proxyTableLen(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared];
    HSjsonProxy *proxy = get_objectFromUserdata(__bridge HSjsonProxy, L, 1, USERDATA_JSONPROXY_TAG);
    lua_pushnumber(L, (lua_Number)proxy.length);
    return 1;
}

static int json_proxyGC(lua_State *L) {
    LuaSkin *skin = [LuaSkin shared];
    [skin checkArgs:LS_TUSERDATA, USERDATA_JSONPROXY_TAG];
    HSjsonProxy *jsonProxy = get_objectFromUserdata(__bridge HSjsonProxy, L, -1, USERDATA_JSONPROXY_TAG);
    jsonProxy.jsonObject = nil;
    jsonProxy = nil;
    return 0;
}

// Functions for returned object when module loads
static const luaL_Reg jsonLib[] = {
    {"encode",  json_encode},
    {"decode",  json_decode},
    {"decodeProxyAtPath", json_proxyDecodeAtPath},
    {NULL,      NULL}
};

int luaopen_hs_json_internal(lua_State* L __unused) {
    LuaSkin *skin = [LuaSkin shared];
    [skin registerLibrary:jsonLib metaFunctions:nil];
    [skin registerObject:USERDATA_JSONPROXY_TAG objectFunctions:jsonProxyUserdataMetatable];

    return 1;
}
