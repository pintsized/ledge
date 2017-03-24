local redis = require "resty.redis"
local redis_connector = require "resty.redis.connector"

local   tostring, ipairs, pairs, type, tonumber, next, unpack, setmetatable =
        tostring, ipairs, pairs, type, tonumber, next, unpack, setmetatable

local ngx_null = ngx.null
local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local ngx_NOTICE = ngx.NOTICE
local ngx_WARN = ngx.WARN
local tbl_insert = table.insert


local _M = {
    _VERSION = '1.28',
}

local mt = {
    __index = _M,
    __newindex = function() error("module fields are read only", 2) end,
    __metatable = false,
}


-- Redis key namespace
local KEY_PREFIX = "ledge:entity:"


--- Creates a new (disconnected) storage instance.
-- @param   ctx     Request context
-- @return  The module instance
function _M.new(ctx)
    return setmetatable({
        ctx = ctx,
        redis = {},
        reader_cursor = 0,
        body_max_memory = 1024, -- (KB) Max size for a cache body before
                                -- we bail on trying to save.

        _keys_created = false,
        _supports_transactions = true,
    }, mt)
end


--- Connects to the Redis storage backend
-- @param   params  Redis connection params as per lua-resty-redis-connector
-- @see     https://github.com/pintsized/lua-resty-redis-connector
-- @usage   The params table can also include
function _M.connect(self, params)
    local rc = redis_connector.new()

    -- Set timeout / connection options
    local connect_timeout, read_timeout, connection_options =
          params.connect_timeout, params.read_timeout, params.connection_options

    if connect_timeout then rc:set_connect_timeout(connect_timeout) end
    if read_timeout then rc:set_read_timeout(read_timeout) end
    if connection_options then rc:set_connection_options(connection_options) end

    if params.supports_transactions == false then
        self._supports_transactions = false
    end

    -- Connect
    local redis, err = rc:connect(params)
    if not redis then
        return nil, err
    else
        self.redis = redis
        return true, nil
    end
end


function _M.close(self)
    local redis = self.redis
    if redis then
        local ok, err = redis:discard()
        if ok then
            -- TODO: How are keepalives configured?
            return redis:set_keepalive()
        else
            return redis:close()
        end
    end
end


-- Return the Redis keys for the entity; entity_id
local function entity_keys(entity_id)
    if entity_id then
        return {
            -- Both keys are lists of chunks
            body        = KEY_PREFIX .. "{" .. entity_id .. "}" .. ":body",
            body_esi    = KEY_PREFIX .. "{" .. entity_id .. "}" .. ":body_esi",
        }
    end
end


-- Returns a boolean indicating if the entity exists, or nil, err
function _M.exists(self, entity_id)
    local keys = entity_keys(entity_id)
    if not keys then
        return nil, "no entity id"
    else
        local redis = self.redis

        local res, err = redis:exists(keys.body, keys.body_esi)
        if not res and err then
            return nil, err
        elseif res == ngx_null or res < 2 then
            return false
        else
            return true, nil
        end
    end
end


function _M.delete(self, entity_id)
    local key_chain = entity_keys(entity_id)
    if key_chain then
        local keys = {}
        for k, v in pairs(key_chain) do
            tbl_insert(keys, v)
        end
        return self.redis:del(unpack(keys))
    end
end


function _M.expire(self, entity_id, ttl)
    local key_chain = entity_keys(entity_id)
    if key_chain then
        for _,key in pairs(key_chain) do
            self.redis:expire(key, ttl)
        end
    end
end


--- Returns an iterator for reading the body chunks.
-- @param   entity_id   The entity ID
-- @return  chunk       The chunk data, or nil indicating error or end of stream
-- @return  err         Error message
-- @return  has_esi     Boolean to indicate presence of ESI instructions
function _M.get_reader(self, res)
    local redis = self.redis
    local entity_id = res.entity_id
    local entity_keys = entity_keys(entity_id)
    local num_chunks = redis:llen(entity_keys.body) or 0

    return function()
        local cursor = self.reader_cursor
        self.reader_cursor = cursor + 1

        local has_esi = false

        if cursor < num_chunks then
            local chunk, err = redis:lindex(entity_keys.body, cursor)
            if not chunk then return nil, err, nil end

            -- Only bother with the body_esi list if we know there are some
            -- chunks marked as true. The body server is responsible for
            -- deciding whether to actually call process_esi() or not.
            local process_esi = self.ctx.esi_process_enabled
            if process_esi then
                has_esi, err = redis:lindex(entity_keys.body_esi, cursor)
                if not has_esi then return nil, err, nil end
            end

            if chunk == ngx_null or (process_esi and has_esi == ngx_null) then
                ngx_log(ngx_WARN,
                    "entity removed during read, ",
                    entity_keys.body
                )
            end

            return chunk, nil, has_esi == "true"
        end
    end
end


local function write_chunk(self, entity_keys, chunk, has_esi, ttl)
    local redis = self.redis

    -- Write chunks / has_esi onto lists
    local ok, e = redis:rpush(entity_keys.body, chunk)
    if not ok then return nil, e end

    ok, e = redis:rpush(entity_keys.body_esi, tostring(has_esi))
    if not ok then return nil, e end

    -- If this is the first write, set expiration too
    if not self._keys_created then
        self._keys_created = true

        ok, e = redis:expire(entity_keys.body, ttl)
        if not ok then return nil, e end

        ok, e = redis:expire(entity_keys.body_esi, ttl)
        if not ok then return nil, e end
    end

    return true, nil
end


-- Returns a wrapped coroutine for writing chunks to cache, where reader is a
-- coroutine to be resumed which reads from the upstream socket.
-- If we cross the body_max_memory boundary, or error for any reason, we just
-- keep yielding chunks to be served, after having removed the cache entry.
--
-- on_abort is a callback to notify that the writing has failed, and cleanup
-- attempted
function _M.get_writer(self, res, ttl, onsuccess, onfailure)
    -- TODO: How to safely do this?
    assert(type(res) == "table")
    assert(type(ttl) == "number")
    assert(type(onsuccess) == "function")
    assert(type(onfailure) == "function")

    local redis = self.redis
    local max_memory = (self.body_max_memory or 0) * 1024

    local entity_id = res.entity_id
    local entity_keys = entity_keys(entity_id)

    local failed = false
    local failed_reason = ""
    local transaction_open = false

    local size = 0
    local reader = res.body_reader

    return function(buffer_size)
        if not transaction_open and self._supports_transactions then
            redis:multi()
            transaction_open = true
        end

        local chunk, err, has_esi = reader(buffer_size)

        if chunk and not failed then  -- We have something to write
            size = size + #chunk

            if size > max_memory then
                failed = true
                failed_reason = "body is larger than " .. max_memory .. " bytes"
            else
                local ok, e = write_chunk(self, entity_keys, chunk, has_esi, ttl)
                if not ok then
                    failed = true
                    failed_reason = "error writing: " .. tostring(e)
                end
            end

        elseif not chunk and not failed then  -- We're finished
            local ok, e = redis:exec() -- Commit

            if not ok or ok == ngx_null then
                -- Transaction failed
                ok, e = pcall(onfailure, e)
                if not ok then ngx_log(ngx_ERR, e) end
            else
                -- All good, report success
                ok, e = pcall(onsuccess, size)
                if not ok then ngx_log(ngx_ERR, e) end
            end

        elseif not chunk and failed then  -- We're finished, but failed
            if self._supports_transactions then
                redis:discard() -- Rollback
            else
                -- Attempt to clean up manually (connection could be dead)
                local ok, e = redis:del(
                    entity_keys.body,
                    entity_keys.body_esi
                )
                if not ok or ok == ngx_null then ngx_log(ngx_ERR, e) end
            end

            local ok, e = pcall(onfailure, failed_reason)
            if not ok then ngx_log(ngx_ERR, e) end
        end

        -- Always bubble up
        return chunk, err, has_esi
    end
end


return _M
