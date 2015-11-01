local   setmetatable, tostring, ipairs, pairs, type, tonumber, next, unpack =
        setmetatable, tostring, ipairs, pairs, type, tonumber, next, unpack
        
local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG
local ngx_ERR = ngx.ERR
local ngx_WARN = ngx.WARN
local ngx_NOTICE = ngx.NOTICE
local ngx_INFO = ngx.INFO
local ngx_null = ngx.null
local ngx_print = ngx.print
local ngx_var = ngx.var
local ngx_get_phase = ngx.get_phase
local ngx_req_get_headers = ngx.req.get_headers
local ngx_req_set_header = ngx.req.set_header
local ngx_req_get_method = ngx.req.get_method
local ngx_req_raw_header = ngx.req.raw_header
local ngx_req_get_uri_args = ngx.req.get_uri_args
local ngx_parse_http_time = ngx.parse_http_time
local ngx_http_time = ngx.http_time
local ngx_time = ngx.time
local ngx_re_gsub = ngx.re.gsub
local ngx_re_sub = ngx.re.sub
local ngx_re_match = ngx.re.match
local ngx_re_gmatch = ngx.re.gmatch
local ngx_re_find = ngx.re.find

local tbl_insert = table.insert
local tbl_concat = table.concat
local str_rep = string.rep
local str_lower = string.lower
local h_util = require "ledge.header_util"
local response = require "ledge.response"
local config = require "ledge.config"
local http = require "resty.http"
local http_headers = require "resty.http_headers"

local _M = {
    _VERSION = '0.1 dev',

    ORIGIN_MODE_BYPASS = 1, -- Never go to the origin, serve from cache or 503.
    ORIGIN_MODE_AVOID  = 2, -- Avoid the origin, serve from cache where possible.
    ORIGIN_MODE_NORMAL = 4, -- Assume the origin is happy, use at will.
}

local mt = { __index = _M }

-- http://www.w3.org/Protocols/rfc2616/rfc2616-sec13.html#sec13.5.1
local HOP_BY_HOP_HEADERS = {
    ["connection"]          = true,
    ["keep-alive"]          = true,
    ["proxy-authenticate"]  = true,
    ["proxy-authorization"] = true,
    ["te"]                  = true,
    ["trailers"]            = true,
    ["transfer-encoding"]   = true,
    ["upgrade"]             = true,
    ["content-length"]      = true, -- Not strictly hop-by-hop, but we set dynamically downstream.
}
---------------------------------------------------------------------------------------------------
-- Event transition table.
---------------------------------------------------------------------------------------------------
-- Use "begin" to transition based on an event. Filter transitions by current state "when", and/or
-- any previous state "after", and/or a previously fired event "in_case", and run actions using
-- "but_first". Transitions are processed in the order found, so place more specific entries for a
-- given event before more generic ones.
---------------------------------------------------------------------------------------------------
_M.events = {
    init = {
        { begin = "checking_method" },
    },

    -- Entry point for worker scripts, which need to connect to Redis but
    -- will stop when this is done.
    init_worker = {
        { begin = "connecting_to_redis" },
    },

    -- Background worker who slept due to redis connection failure, has awoken
    -- to try again.
    woken = {
        { begin = "connecting_to_redis" }
    },

    worker_finished = {
        { begin = "exiting_worker" }
    },

    -- We failed to connect to redis. Bail.
    redis_connection_failed = {
        { in_case = "init_worker", begin = "sleeping" },
        { begin = "exiting", but_first = "set_http_service_unavailable" },
    },

    -- We're connected! Let's get on with it then... First step, analyse the request.
    -- If we're a worker then we just start running tasks.
    redis_connected = {
        { in_case = "init_worker", begin = "running_worker" },
        { begin = "checking_method" },
    },

    cacheable_method = {
        { when = "checking_origin_mode", begin = "checking_request" },
        { begin = "checking_origin_mode" },
    },

    -- PURGE method detected.
    purge_requested = {
        { begin = "purging" },
    },

    -- Succesfully purged (expired) a cache entry. Exit 200 OK.
    purged = {
        { begin = "exiting", but_first = "set_http_ok" },
    },

    -- URI to purge was not found. Exit 404 Not Found.
    nothing_to_purge = {
        { begin = "exiting", but_first = "set_http_not_found" },
    },

    -- The request accepts cache. If we've already validated locally, we can think about serving.
    -- Otherwise we need to check the cache situtation.
    cache_accepted = {
        { when = "revalidating_locally", begin = "considering_esi_process" },
        { begin = "checking_cache" },
    },

    forced_cache = {
        { begin = "accept_cache" },
    },

    -- This request doesn't accept cache, so we need to see about fetching directly.
    cache_not_accepted = {
        { begin = "checking_can_fetch" },
    },

    -- We don't know anything about this URI, so we've got to see about fetching.
    cache_missing = {
        { begin = "checking_can_fetch" },
    },

    -- This URI was cacheable last time, but has expired. So see about serving stale, but failing
    -- that, see about fetching.
    cache_expired = {
        { when = "checking_cache", begin = "checking_can_serve_stale" },
        { when = "checking_can_serve_stale", begin = "checking_can_fetch" },
    },

    -- We have a (not expired) cache entry. Lets try and validate in case we can exit 304.
    cache_valid = {
        { in_case = "collapsed_response_ready", begin = "considering_local_revalidation" },
        { when = "checking_cache", begin = "considering_revalidation" },
    },

    -- We need to fetch, and there are no settings telling us we shouldn't, but collapsed forwarding
    -- is on, so if cache is accepted and in an "expired" state (i.e. not missing), lets try
    -- to collapse. Otherwise we just start fetching.
    can_fetch_but_try_collapse = {
        { in_case = "cache_missing", begin = "fetching" },
        { in_case = "cache_accepted", begin = "requesting_collapse_lock" },
        { begin = "fetching" },
    },

    -- We have the lock on this "fetch". We might be the only one. We'll never know. But we fetch
    -- as "surrogate" in case others are listening.
    obtained_collapsed_forwarding_lock = {
        { begin = "fetching_as_surrogate" },
    },

    -- Another request is currently fetching, so we've subscribed to updates on this URI. We need
    -- to block until we hear something (or timeout).
    subscribed_to_collapsed_forwarding_channel = {
        { begin = "waiting_on_collapsed_forwarding_channel" },
    },

    -- Another request was fetching when we asked, but by the time we subscribed the channel was
    -- closed (small window, but potentially possible). Chances are the item is now in cache,
    -- so start there.
    collapsed_forwarding_channel_closed = {
        { begin = "checking_cache" },
    },

    -- We were waiting on a collapse channel, and got a message saying the response is now ready.
    -- The item will now be fresh in cache.
    collapsed_response_ready = {
        { begin = "checking_cache" },
    },

    -- We were waiting on another request (collapsed), but it came back as a non-cacheable response
    -- (i.e. the previously cached item is no longer cacheable). So go fetch for ourselves.
    collapsed_forwarding_failed = {
        { begin = "fetching" },
    },

    -- We were waiting on another request, but it received an upstream_error (e.g. 500)
    -- Check if we can serve stale content instead
    collapsed_forwarding_upstream_error = {
        { begin = "considering_stale_error" },
    },

    -- We need to fetch and nothing is telling us we shouldn't. Collapsed forwarding is not enabled.
    can_fetch = {
        { begin = "fetching" },
    },

    -- We've fetched and got a response status and headers. We should consider potential for ESI
    -- before doing anything else.
    response_fetched = {
        { begin = "considering_esi_scan" },
    },

    partial_response_fetched = {
        { begin = "considering_esi_scan", but_first = "revalidate_in_background" },
    },

    -- If we went upstream and errored, check if we can serve a cached copy (stale-if-error),
    -- Publish the error first if we were the surrogate request
    upstream_error = {
        { after = "fetching_as_surrogate", begin = "publishing_collapse_upstream_error" },
        { begin = "considering_stale_error" }
    },

    -- We had an error from upstream and could not serve stale content, so serve the error
    -- Or we were collapsed and the surrogate received an error but we could not serve stale
    -- in that case, try and fetch ourselves
    can_serve_upstream_error = {
        { after = "fetching", begin = "serving_upstream_error" },
        { in_case = "collapsed_forwarding_upstream_error", begin = "fetching" },
        { begin = "serving_upstream_error" },
    },

    -- We've determined we need to scan the body for ESI.
    esi_scan_enabled = {
        { begin = "considering_gzip_inflate", but_first = "set_esi_scan_enabled" },
    },

    gzip_inflate_enabled = {
        { after = "updating_cache", begin = "preparing_response", but_first = "install_gzip_decoder" },
        { in_case = "esi_scan_enabled", begin = "updating_cache",
            but_first = { "install_gzip_decoder", "install_esi_scan_filter" } },
        { begin = "preparing_response", but_first = "install_gzip_decoder" },
    },

    gzip_inflate_disabled = {
        { after = "updating_cache", begin = "preparing_response" },
        { after = "considering_esi_scan", in_case = "esi_scan_enabled", begin = "updating_cache",
            but_first = { "install_esi_scan_filter" } },
        { in_case = "esi_process_disabled", begin = "checking_range_request" },
        { begin = "preparing_response" },
    },

    range_accepted = {
        { begin = "preparing_response", but_first = "install_range_filter" },
    },

    range_not_accepted = {
        { begin = "preparing_response" },
    },

    range_not_requested = {
        { begin = "preparing_response" },
    },

    -- We've determined no need to scan the body for ESI.
    esi_scan_disabled = {
        { begin = "updating_cache", but_first = "set_esi_scan_disabled" },
    },

    -- We deduced that the new response can cached. We always "save_to_cache". If we were fetching
    -- as a surrogate (collapsing) make sure we tell any others concerned. If we were performing
    -- a background revalidate (having served stale), we can just exit. Otherwise go back through
    -- validationg in case we can 304 to the client.
    response_cacheable = {
        { after = "fetching_as_surrogate", begin = "publishing_collapse_success",
            but_first = "save_to_cache" },
        { after = "revalidating_in_background", begin = "exiting",
            but_first = "save_to_cache" },
        { begin = "considering_local_revalidation",
            but_first = "save_to_cache" },
    },

    -- We've deduced that the new response cannot be cached. Essentially this is as per
    -- "response_cacheable", except we "delete" rather than "save", and we don't try to revalidate.
    response_not_cacheable = {
        { after = "fetching_as_surrogate", begin = "publishing_collapse_failure",
            but_first = "delete_from_cache" },
        { after = "revalidating_in_background", begin = "exiting",
            but_first = "delete_from_cache" },
        { begin = "considering_esi_process", but_first = "delete_from_cache" },
    },

    -- A missing response body means a HEAD request or a 304 Not Modified upstream response, for
    -- example. If we were revalidating upstream, we can now re-revalidate against local cache.
    -- If we're collapsing or background revalidating, ensure we either clean up the collapsees
    -- or exit respectively.
    response_body_missing = {
        { in_case = "must_revalidate", begin = "considering_local_revalidation" } ,
        { after = "fetching_as_surrogate", begin = "publishing_collapse_failure",
            but_first = "delete_from_cache" },
        { after = "revalidating_in_background", begin = "exiting" },
        { begin = "serving",
            but_first = {
                "install_no_body_reader", "set_http_status_from_response"
            },
        },
    },

    -- We were the collapser, so digressed into being a surrogate. We're done now and have published
    -- this fact, so we pick up where it would have left off - attempting to 304 to the client.
    -- Unless we received an error, in which case check if we can serve stale instead
    published = {
        { in_case = "upstream_error", begin = "considering_stale_error" },
        { begin = "considering_local_revalidation" },
    },

    -- Client requests a max-age of 0 or stored response requires revalidation.
    must_revalidate = {
        --{ begin = "revalidating_upstream" },
        { begin = "checking_can_fetch" },
    },

    -- We can validate locally, so do it. This doesn't imply it's valid, merely that we have
    -- the correct parameters to attempt validation.
    can_revalidate_locally = {
        { begin = "revalidating_locally" },
    },

    -- Standard non-conditional request.
    no_validator_present = {
        { begin = "considering_esi_process" },
    },

    -- The response has not been modified against the validators given. We'll exit 304 if we can
    -- but go via considering_esi_process in case of ESI work to be done.
    not_modified = {
        { when = "revalidating_locally", begin = "considering_esi_process" },
    },

    -- Our cache has been modified as compared to the validators. But cache is valid, so just
    -- serve it. If we've been upstream, re-compare against client validators.
    modified = {
        { in_case = "init_worker", begin = "considering_local_revalidation" },
        { when = "revalidating_locally", begin = "considering_esi_process" },
        { when = "revalidating_upstream", begin = "considering_local_revalidation" },
    },

    esi_process_enabled = {
        { begin = "preparing_response",
            but_first = {
                "install_esi_process_filter",
                "set_esi_process_enabled",
                "zero_downstream_lifetime",
                "remove_surrogate_control_header"
            }
        },
    },

    esi_process_disabled = {
        { begin = "considering_gzip_inflate", but_first = "set_esi_process_disabled" },
    },

    esi_process_not_required = {
        { begin = "considering_gzip_inflate",
            but_first = { "set_esi_process_disabled", "remove_surrogate_control_header" },
        },
    },

    -- We have a response we can use. If we've already served (we are doing background work) then
    -- just exit. If it has been prepared and we were not_modified, then set 304 and serve.
    -- If it has been prepared, set status accordingly and serve. If not, prepare it.
    response_ready = {
        { in_case = "served", begin = "exiting" },
        { in_case = "forced_cache", begin = "serving", but_first = "add_disconnected_warning"},
        -- If we might ESI, then don't 304 downstream.
        { when = "preparing_response", in_case = "esi_process_enabled",
            begin = "serving", but_first = "set_http_status_from_response" },
        { when = "preparing_response", in_case = "not_modified",
            begin = "serving", but_first = "set_http_not_modified" },
        { when = "preparing_response", begin = "serving",
            but_first = "set_http_status_from_response" },
        { begin = "preparing_response" },
    },

    -- We've deduced we can serve a stale version of this URI. Ensure we add a warning to the
    -- response headers.
    -- TODO: "serve_stale" isn't really an event?
    serve_stale = {
        { after = "considering_stale_error", begin = "serving_stale", but_first = "add_stale_warning" },
        { begin = "serving_stale", but_first = { "add_stale_warning", "revalidate_in_background" } },
    },

    -- We have sent the response. If it was stale, we go back around the fetching path
    -- so that a background revalidation can occur unless the upstream errored. Otherwise exit.
    served = {
        { in_case = "upstream_error", begin = "exiting" },
        { in_case = "collapsed_forwarding_upstream_error", begin = "exiting" },
        { begin = "exiting" },
    },

    -- When the client request is aborted clean up redis / http connections. If we're saving
    -- or have the collapse lock, then don't abort as we want to finish regardless.
    -- Note: this is a special entry point, triggered by ngx_lua client abort notification.
    aborted = {
        { in_case = "response_cacheable", begin = "cancelling_abort_request" },
        { in_case = "obtained_collapsed_forwarding_lock", begin = "cancelling_abort_request" },
        { begin = "exiting"},
    },

    -- The cache body reader was reading from the list, but the entity was collected by a worker
    -- thread because it had been replaced, and the client was too slow.
    entity_removed_during_read = {
        { begin = "exiting", but_first = "set_http_connection_timed_out" },
    },

    -- Useful events for exiting with a common status. If we've already served (perhaps we're doing
    -- background work, we just exit without re-setting the status (as this errors).

    http_ok = {
        { in_case = "served", begin = "exiting" },
        { begin = "exiting", but_first = "set_http_ok" },
    },

    http_not_found = {
        { in_case = "served", begin = "exiting" },
        { begin = "exiting", but_first = "set_http_not_found" },
    },

    http_gateway_timeout = {
        { in_case = "served", begin = "exiting" },
        { begin = "exiting", but_first = "set_http_gateway_timeout" },
    },

    http_service_unavailable = {
        { in_case = "served", begin = "exiting" },
        { begin = "exiting", but_first = "set_http_service_unavailable" },
    },

}

---------------------------------------------------------------------------------------------------
-- Pre-transitions. Actions to always perform before transitioning.
---------------------------------------------------------------------------------------------------
_M.pre_transitions = {
    exiting = { "redis_close", "httpc_close" },
    exiting_worker = { "redis_close", "httpc_close" },
    checking_cache = { "read_cache" },
    -- Never fetch with client validators, but put them back afterwards.
    fetching = {
        "remove_client_validators", "fetch", "restore_client_validators"
    },
    -- Use validators from cache when revalidating upstream, and restore client validators
    -- afterwards.
    revalidating_upstream = {
        "remove_client_validators",
        "add_validators_from_cache",
        "fetch",
        "restore_client_validators"
    },
    -- Need to save the error response before reading from cache in case we need to serve it later
    considering_stale_error = {
        "stash_error_response",
        "read_cache"
    },
    -- Restore the saved response and set the status when serving an error page
    serving_upstream_error = {
        "restore_error_response",
        "set_http_status_from_response"
    },
}

---------------------------------------------------------------------------------------------------
-- Actions. Functions which can be called on transition.
---------------------------------------------------------------------------------------------------
_M.actions = {
    redis_connect = function(self)
        return self:redis_connect()
    end,

    redis_close = function(self)
        return self:redis_close()
    end,

    httpc_close = function(self)
        local res = self:get_response()
        if res then
            local httpc = res.conn
            if httpc then
                return httpc:set_keepalive()
            end
        end
    end,

    stash_error_response = function(self)
        local error_res = self:get_response()
        self:set_response(error_res, "error")
    end,

    restore_error_response = function(self)
        local error_res = self:get_response('error')
        self:set_response(error_res)
    end,

    read_cache = function(self)
        local res = self:read_from_cache()
        self:set_response(res)
    end,

    install_no_body_reader = function(self)
        local res = self:get_response()
        res.body_reader = _no_body_reader
    end,

    install_gzip_decoder = function(self)
        local res = self:get_response()
        res.header["Content-Encoding"] = nil
        res.body_reader = self:filter_body_reader(
            "gzip_decoder",
            get_gzip_decoder(res.body_reader)
        )
    end,

    install_range_filter = function(self)
        local res = self:get_response()
        res.body_reader = self:filter_body_reader(
            "range_request_filter",
            self:get_range_request_filter(res.body_reader)
        )
    end,

    set_esi_scan_enabled = function(self)
        local res = self:get_response()
        local ctx = self:ctx()
        ctx.esi_scan_enabled = true
        res.esi_scanned = true
    end,

    install_esi_scan_filter = function(self)
        local res = self:get_response()
        local ctx = self:ctx()
        local esi_parser = ctx.esi_parser
        if esi_parser and esi_parser.parser then
            res.body_reader = self:filter_body_reader(
                "esi_scan_filter",
                esi_parser.parser.get_scan_filter(res.body_reader)
            )
        end
    end,

    set_esi_scan_disabled = function(self)
        local res = self:get_response()
        self:ctx().esi_scan_disabled = true
        res.esi_scanned = false
    end,

    install_esi_process_filter = function(self)
        local res = self:get_response()
        local esi_parser = self:ctx().esi_parser
        if esi_parser and esi_parser.parser then
            res.body_reader = self:filter_body_reader(
                "esi_process_filter",
                esi_parser.parser.get_process_filter(
                    res.body_reader,
                    self:config_get("esi_pre_include_callback"),
                    self:config_get("esi_recursion_limit")
                )
            )
        end
    end,

    set_esi_process_enabled = function(self)
        self:ctx().esi_process_enabled = true
    end,

    set_esi_process_disabled = function(self)
        self:ctx().esi_process_enabled = false
    end,

    zero_downstream_lifetime = function(self)
        local res = self:get_response()
        if res.header then
            res.header["Cache-Control"] = "private, must-revalidate"
        end
    end,

    remove_surrogate_control_header = function(self)
        local res = self:get_response()
        if res.header then
            res.header["Surrogate-Control"] = nil
        end
    end,

    fetch = function(self)
        local res = self:fetch_from_origin()
        if res.status ~= ngx.HTTP_NOT_MODIFIED then
            self:set_response(res)
        end
    end,

    remove_client_validators = function(self)
        -- Keep these in case we need to restore them (after revalidating upstream)
        local client_validators = self:ctx().client_validators
        client_validators["If-Modified-Since"] = ngx_var.http_if_modified_since
        client_validators["If-None-Match"] = ngx_var.http_if_none_match

        ngx_req_set_header("If-Modified-Since", nil)
        ngx_req_set_header("If-None-Match", nil)
    end,

    restore_client_validators = function(self)
        local client_validators = self:ctx().client_validators
        ngx_req_set_header("If-Modified-Since", client_validators["If-Modified-Since"])
        ngx_req_set_header("If-None-Match", client_validators["If-None-Match"])
    end,

    add_validators_from_cache = function(self)
        local cached_res = self:get_response()

        -- TODO: Patch OpenResty to accept additional headers for subrequests.
        ngx_req_set_header("If-Modified-Since", cached_res.header["Last-Modified"])
        ngx_req_set_header("If-None-Match", cached_res.header["Etag"])
    end,

    add_stale_warning = function(self)
        return self:add_warning("110")
    end,

    add_transformation_warning = function(self)
        ngx_log(ngx_INFO, "adding warning")
        return self:add_warning("214")
    end,

    add_disconnected_warning = function(self)
        return self:add_warning("112")
    end,

    serve = function(self)
        return self:serve()
    end,

    revalidate_in_background = function(self)
        self:put_background_job("ledge", "ledge.jobs.revalidate", {
            raw_header = ngx_req_raw_header(),
            host = ngx_var.host,
            server_addr = ngx_var.server_addr,
            server_port = ngx_var.server_port,
        })
    end,

    save_to_cache = function(self)
        local res = self:get_response()
        return self:save_to_cache(res)
    end,

    delete_from_cache = function(self)
        return self:delete_from_cache()
    end,

    release_collapse_lock = function(self)
        self:ctx().redis:del(self:cache_key_chain().fetching_lock)
    end,

    set_http_ok = function(self)
        ngx.status = ngx.HTTP_OK
    end,

    set_http_not_found = function(self)
        ngx.status = ngx.HTTP_NOT_FOUND
    end,

    set_http_not_modified = function(self)
        ngx.status = ngx.HTTP_NOT_MODIFIED
    end,

    set_http_service_unavailable = function(self)
        ngx.status = ngx.HTTP_SERVICE_UNAVAILABLE
    end,

    set_http_gateway_timeout = function(self)
        ngx.status = ngx.HTTP_GATEWAY_TIMEOUT
    end,

    set_http_connection_timed_out = function(self)
        ngx.status = 524
    end,

    set_http_status_from_response = function(self)
        local res = self:get_response()
        if res.status then
            ngx.status = res.status
        else
            res.status = ngx.HTTP_INTERNAL_SERVER_ERROR
        end
    end,
}

function _M.new(self)
    local config = {
        origin_mode     = _M.ORIGIN_MODE_NORMAL,
        host			= {
       		-- { name = "www.visionad.com.cn", port = 80, ip = "121.43.108.134" },
    	},
    }

    return setmetatable({ config = config }, mt)
end


-- A safe place in ngx.ctx for the current module instance (self).
function _M.ctx(self)
    local id = tostring(self)
    local ctx = ngx.ctx[id]
    if not ctx then
        ctx = {
            events = {},
            config = {},
            state_history = {},
            event_history = {},
            current_state = "",
            client_validators = {},
        }
        ngx.ctx[id] = ctx
    end
    return ctx
end


-- Set a config parameter
function _M.config_set(self, param, value)
    if ngx_get_phase() == "init" then
        self.config[param] = value
    else
        self:ctx().config[param] = value
    end
end


-- Gets a config parameter.
function _M.config_get(self, param)
    local p = self:ctx().config[param]
    if p == nil then
        return self.config[param]
    else
        return p
    end
end

function _M.set_response(self, res, name)
    local name = name or "response"
    self:ctx()[name] = res
end

function _M.get_response(self, name)
    local name = name or "response"
    return self:ctx()[name]
end


function _M.handle_abort(self)
    -- Use a closure to pass through the ledge instance
    return function()
        self:e "aborted"
    end
end

function _M.run(self)
    local set, msg = ngx.on_abort(self:handle_abort())
    if set == nil then
       ngx_log(ngx_WARN, "on_abort handler not set: "..msg)
    end
    self:e "init"
end

---------------------------------------------------------------------------------------------------
-- Decision states.
---------------------------------------------------------------------------------------------------
-- Represented as functions which should simply make a decision, and return calling self:e(ev) with
-- the event that has occurred. Place any further logic in actions triggered by the transition
-- table.
---------------------------------------------------------------------------------------------------
_M.states = {

    checking_method = function(self)
        local method = ngx_req_get_method()
        if method == "PURGE" then
            return self:e "purge_requested"
        elseif method ~= "GET" and method ~= "HEAD" then
            -- Only GET/HEAD are cacheable
            return self:e "cache_not_accepted"
        else
            return self:e "cacheable_method"
        end
    end,
    
    exiting = function(self)
        ngx.exit(ngx.status)
    end,

    running_worker = function(self)
        return true
    end,

    exiting_worker = function(self)
        return true
    end,

    checking_can_fetch = function(self)
        return self:e "can_fetch"
    end,
    
    fetching = function(self)
        local res = self:get_response()

        if res.status >= 500 then
            return self:e "upstream_error"
        elseif res.status == ngx.HTTP_NOT_MODIFIED then
            return self:e "response_ready"
        elseif res.status == ngx_PARTIAL_CONTENT then
            return self:e "partial_response_fetched"
        else
            return self:e "response_fetched"
        end
    end,
        
    checking_origin_mode = function(self)
    	return self:e "cacheable_method"
    end,
    
    checking_request = function(self)
        if self:request_accepts_cache() then
            return self:e "cache_accepted"
        else
            return self:e "cache_not_accepted"
        end
    end,
    
	checking_cache = function(self)
        local res = self:get_response()

        if not res then
            return self:e "cache_missing"
        elseif res:has_expired() then
            return self:e "cache_expired"
        else
            return self:e "cache_valid"
        end
    end,
        
    cancelling_abort_request = function(self)
        return true
    end,
    considering_esi_scan = function(self)

        return self:e "esi_scan_disabled"
    end,    

    updating_cache = function(self)
        local res = self:get_response()
        if res.has_body then
            if res:is_cacheable() then
                return self:e "response_cacheable"
            else
                return self:e "response_not_cacheable"
            end
        else
            return self:e "response_body_missing"
        end
    end,    
}

-- Transition to a new state.
function _M.t(self, state)
    local ctx = self:ctx()

    -- Check for any transition pre-tasks
    local pre_t = self.pre_transitions[state]

    if pre_t then
        for _,action in ipairs(pre_t) do
            ngx_log(ngx_DEBUG, "#a: ", action)
            self.actions[action](self)
        end
    end

    ngx_log(ngx_DEBUG, "#t: ", state)

    ctx.state_history[state] = true
    ctx.current_state = state
    return self.states[state](self)
end


-- Process state transitions and actions based on the event fired.
function _M.e(self, event)
    ngx_log(ngx_DEBUG, "#e: ", event)

    local ctx = self:ctx()
    ctx.event_history[event] = true

    -- It's possible for states to call undefined events at run time. Try to handle this nicely.
    if not self.events[event] then
        ngx_log(ngx.CRIT, event, " is not defined.")
        ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
        self:t("exiting")
    end

    for _, trans in ipairs(self.events[event]) do
        local t_when = trans["when"]
        if t_when == nil or t_when == ctx.current_state then
            local t_after = trans["after"]
            if not t_after or ctx.state_history[t_after] then
                local t_in_case = trans["in_case"]
                if not t_in_case or ctx.event_history[t_in_case] then
                    local t_but_first = trans["but_first"]
                    if t_but_first then
                        if type(t_but_first) == "table" then
                            for _,action in ipairs(t_but_first) do
                                ngx_log(ngx_DEBUG, "#a: ", action)
                                self.actions[action](self)
                            end
                        else
                            ngx_log(ngx_DEBUG, "#a: ", t_but_first)
                            self.actions[t_but_first](self)
                        end
                    end

                    return self:t(trans["begin"])
                end
            end
        end
    end
end

function _M.relative_uri(self)
    return ngx_re_gsub(ngx_var.uri, "\\s", "%20", "jo") .. ngx_var.is_args .. (ngx_var.query_string or "")
end

-- Fetches a resource from the origin server.
function _M.fetch_from_origin(self)
    local res = response.new()
    self:emit("origin_required")

    local ups = config:get_ups()
    ngx_log(ngx_DEBUG, "host=", ups.host, "port=", ups.port)

    local method = ngx['HTTP_' .. ngx_req_get_method()]
    if not method then
        res.status = ngx.HTTP_METHOD_NOT_IMPLEMENTED
        return res
    end

    local httpc

    httpc = http.new()
    --httpc:set_timeout(ups.connect_timeout)

    --local ok, err = httpc:connect(ups.host, ups.port)
    local ok, err = httpc:connect("121.43.108.134", 80)    

    if not ok then
        if err == "timeout" then
            res.status = 524 -- upstream server timeout
        else
            res.status = 503
        end
        return res
    end

    --httpc:set_timeout(ups.read_timeout)

    -- Case insensitve headers so that we can safely manipulate them
    local headers = http_headers.new()
    for k,v in pairs(ngx_req_get_headers()) do
        headers[k] = v
    end

    local client_body_reader, err = httpc:get_client_body_reader()
    if err then
        ngx_log(ngx_ERR, "error getting client body reader: ", err)
    end

    local req_params = {
        method = ngx_req_get_method(),
        path = self:relative_uri(),
        body = client_body_reader,
        headers = headers,
    }

    -- allow request params to be customised
    self:emit("before_request", req_params)

    local origin, err = httpc:request(req_params)

    if not origin then
        ngx_log(ngx_ERR, err)
        res.status = 524
        return res
    end

    res.conn = httpc
    res.status = origin.status

    -- Merge end-to-end headers
    for k,v in pairs(origin.headers) do
        if not HOP_BY_HOP_HEADERS[str_lower(k)] then
            res.header[k] = v
        end
    end

    -- May well be nil, but if present we bail on saving large bodies to memory nice
    -- and early.
    res.length = tonumber(origin.headers["Content-Length"])

    res.has_body = origin.has_body
    res.body_reader = self:filter_body_reader("upstream_body_reader", origin.body_reader)

    if res.status < 500 then
        -- http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.18
        -- A received message that does not have a Date header field MUST be assigned
        -- one by the recipient if the message will be cached by that recipient
        if not res.header["Date"] or not ngx_parse_http_time(res.header["Date"]) then
            ngx_log(ngx_WARN, "no Date header from upstream, generating locally")
            res.header["Date"] = ngx_http_time(ngx_time())
        end
    end

    -- A nice opportunity for post-fetch / pre-save work.
    self:emit("origin_fetched", res)

    return res
end

function _M.request_accepts_cache(self)
    -- Check for no-cache
    local h = ngx_req_get_headers()
    if h_util.header_has_directive(h["Pragma"], "no-cache")
       or h_util.header_has_directive(h["Cache-Control"], "no-cache")
       or h_util.header_has_directive(h["Cache-Control"], "no-store") then
        return false
    end

    return true
end

function _M.read_from_cache(self)
	return nil
end

function _M.filter_body_reader(self, filter_name, filter)
    -- Keep track of the filters by name, just for debugging
    local filters = self:ctx().body_filters
    if not filters then filters = {} end

    ngx_log(ngx_DEBUG, filter_name, "(", tbl_concat(filters, "("), "" , str_rep(")", #filters - 1), ")")

    tbl_insert(filters, 1, filter_name)
    self:ctx().body_filters = filters

    return filter
end

function _M.delete_from_cache(self)

end

function _M.emit(self, event, res)
    local events = self:ctx().events
    for _, handler in ipairs(events[event] or {}) do
        if type(handler) == "function" then
            local ok, err = pcall(handler, res)
            if not ok then
                ngx_log(ngx_ERR, "Error in user callback for '", event, "': ", err)
            end
        end
    end
end


return _M
