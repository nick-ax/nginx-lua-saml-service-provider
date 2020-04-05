-- Copyright (C) by Hiroaki Nakamura (hnakamur)

local session_cookie = require "session.cookie"
local saml_sp_request = require "saml.service_provider.request"
local saml_sp_response = require "saml.service_provider.response"
local random = require "saml.service_provider.random"
local jwt_store = require "saml.service_provider.jwt_store"
local shdict_store = require "saml.service_provider.shdict_store"
local api_error = require "saml.service_provider.api_error"

local setmetatable = setmetatable

local _M = { _VERSION = '0.9.0' }

local mt = { __index = _M }

function _M.new(self, config)
    return setmetatable({
        config = config
    }, mt)
end

function _M.access(self)
    local session_cookie = self:session_cookie()
    local session_id_or_jwt, err = session_cookie:get()
    if err ~= nil then
        return api_error.new{
            err_code = 'err_session_cookie_get',
            log_detail = string.format('access, err=%s', err)
        }
    end

    local key_attr_name = self.config.key_attribute_name
    local key_attr = nil
    if session_id_or_jwt ~= nil then
        local ts = self:token_store()
        key_attr, err = ts:retrieve(session_id_or_jwt)
        if err ~= nil then
            return api_error.new{
                err_code = 'err_token_store_retrieve',
                log_detail = string.format('access, err=%s', err)
            }
        end
    end

    if session_id_or_jwt == nil or key_attr == nil then
        local sp_req = self:request()
        return sp_req:redirect_to_idp_to_login()
    end

    ngx.req.set_header(key_attr_name, key_attr)
    return nil
end

local function has_prefix(s, prefix)
    return #s >= #prefix and string.sub(s, 1, #prefix) == prefix
end

local function parse_iso8601_utc_time(str)
    local year, month, day, hour, min, sec = str:match('(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)')
    return os.time{year=year, month=month, day=day, hour=hour, min=min, sec=sec}
end

function _M.finish_login(self)
    local sp_resp = self:response()

    local response_xml, redirect_uri, err = sp_resp:read_and_base64decode_response()
    if err ~= nil then
        return api_error.new{
            err_code = 'err_decode_saml_response',
            status_code = ngx.HTTP_BAD_REQUEST,
            log_detail = string.format('finish_login, err=%s', err)
        }
    end

    if self.config.response.idp_certificate ~= nil then
        local ok, err = sp_resp:verify_response_memory(response_xml)
        if err ~= nil then
            return api_error.new{
                err_code = 'err_verify_resp_mem',
                log_detail = string.format('finish_login, err=%s', err)
            }
        end
        if not ok then
            return api_error.new{
                err_code = 'err_verify_failed',
                status_code = ngx.HTTP_FORBIDDEN,
                log_detail = 'finish_login'
            }
        end
    else
        local ok, err = sp_resp:verify_response(response_xml)
        if err ~= nil then
            return api_error.new{
                err_code = 'err_verify_resp_cmd',
                log_detail = string.format('finish_login, err=%s', err)
            }
        end
    end

    local attrs, err = sp_resp:take_attributes_from_response(response_xml)
    if err ~= nil then
        return api_error.new{
            err_code = 'err_take_attrs_from_resp',
            log_detail = 'finish_login'
        }
    end

    local key_attr_name = self.config.key_attribute_name
    local key_attr = attrs[key_attr_name]
    if key_attr == nil then
        return api_error.new{
            err_code = 'err_attr_not_found',
            log_detail = 'finish_login'
        }
    end

    local exptime_str = sp_resp:take_session_expiration_time_from_response(response_xml)
    local exptime = parse_iso8601_utc_time(exptime_str)

    local ts = self:token_store()
    local session_id_or_jwt, err = ts:store(key_attr, exptime)
    if err ~= nil then
        return api_error.new{
            err_code = 'err_token_store_store',
            log_detail = string.format('finish_login, err=%s', err)
        }
    end

    local sc = self:session_cookie()
    local ok, err = sc:set(session_id_or_jwt)
    if err ~= nil then
        return api_error.new{
            err_code = 'err_session_cookie_set_empty',
            log_detail = string.format('finish_login, err=%s', err)
        }
    end

    if not has_prefix(redirect_uri, '/') then
        redirect_uri = '/'
    end
    return ngx.redirect(redirect_uri)
end

function _M.logout(self)
    local sc = self:session_cookie()
    local session_id_or_jwt, err = sc:get()
    if err ~= nil then
        return api_error.new{
            err_code = 'err_session_cookie_get',
            log_detail = string.format('logout, err=%s', err)
        }
    end

    if session_id_or_jwt ~= nil then
        local ts = self:token_store()
        ts:delete(session_id_or_jwt)

        -- In ideal, we would delete the cookie by setting expiration to the Unix epoch date.
        -- In reality, curl still sends the cookie after receiving the Unix epoch date
        -- with set-cookie, so we have to change the cookie value instead of deleting it.
        local ok, err = sc:set("")
        if err ~= nil then
            return api_error.new{
                err_code = 'err_session_cookie_set_empty',
                log_detail = string.format('logout, err=%s', err)
            }
        end
    end

    return ngx.redirect(self.config.redirect.url_after_logout)
end


function _M.request(self)
    local request = self._request
    if request ~= nil then
        return request
    end

    local config = self.config.request
    request = saml_sp_request:new{
        idp_dest_url = config.idp_dest_url,
        sp_entity_id = config.sp_entity_id,
        sp_saml_finish_url = config.sp_saml_finish_url,
        request_id_generator = function()
            return "_" .. random.hex(config.request_id_byte_length or 16)
        end
    }
    self._request = request
    return request
end

function _M.response(self)
    local response = self._response
    if response ~= nil then
        return response
    end

    response = saml_sp_response:new(self.config.response)
    self._response = response
    return response
end

function _M.session_cookie(self)
    local cookie = self._session_cookie
    if cookie ~= nil then
        return cookie
    end

    local config = self.config.session.cookie
    cookie = session_cookie:new{
        name = config.name,
        path = config.path,
        secure = config.secure
    }
    self._session_cookie = cookie
    return cookie
end

function _M.token_store(self)
    local store = self._token_store
    if store ~= nil then
        return store
    end

    local store_type = self:token_store_type()
    if store_type == "jwt" then
        local jwt_config = self.config.session.store.jwt
        store = jwt_store:new{
            key_attr_name = self.config.key_attribute_name,
            symmetric_key = jwt_config.symmetric_key,
            algorithm = jwt_config.algorithm
        }
    else
        store = shdict_store:new(self.config.session.store)
    end
    self._token_store = store
    return store
end

function _M.token_store_type(self)
    if self.config.session.store.jwt ~= nil then
        return "jwt"
    end
    return "shared_dict"
end

return _M
