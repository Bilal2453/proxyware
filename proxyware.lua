#!/usr/bin/luvit

---@diagnostic disable-next-line: undefined-global
local stdout = process.stdout or io.stdout
local uv = require 'uv'
local c = require 'pretty-print'.colorize

local PORT          = 80          -- which port to listen on?
local DOMAIN        = '0.0.0.0'   -- which domain/loopback to listen on?
local LOCAL_HOST    = '127.0.0.1' -- the machine's address on which to route to
local PUBLIC_DOMAIN = 'nas.local' -- the public address of the server (mainly used for logging and reporting purposes)

-- list the available subdomains with their ports
local subdomains_map = {
  cockpit  = 9090,
  jellyfin = 8096,
  stash    = 8069,
}

-- an upvalue holding the TCP socket for our proxy server
local server

local function wrap(func)
  return function (...)
    coroutine.wrap(func)(...)
  end
end

local function resume(thread, ...)
  local success, err = coroutine.resume(thread, ...)
  if not success then
    error(debug.traceback(thread, err), 0)
  end
end

-- awaits a luv's async method
-- e.x: await(socket, 'write', 'data')
local function await(obj, method, ...)
  local thread = coroutine.running()
  local params = {...}
  params[#params + 1] = function (err, data)
    if err then
      return resume(thread, false, err)
    end
    return resume(thread, data or true)
  end
  obj[method](obj, unpack(params))
  return coroutine.yield()
end

-- properly closes multiple handles
local function close(...)
  local handles = {...}
  for i = 1, #handles do
    local handle = handles[i]
    if not handle:is_closing() then
      handle:close()
    end
  end
end

-- reads a single chunk off of a stream asynchronously
-- while yielding current coroutine until operation is done
local function read(socket)
  local is_readable = socket:is_readable()
  if not is_readable then
    return false, 'provided stream is not readable'
  end
  local data, err = await(socket, 'read_start')
  if not data then
    return false, err
  end
  assert(socket:read_stop()) -- should never fail
  return data
end

-- writes a chunk of data to some stream asynchronously
-- while yielding current coroutine until operation is done
local function write(socket, do_close, chunk)
  local is_writable = socket:is_writable()
  if not is_writable then
    return false, 'provided stream is not writable'
  end
  local data, err = await(socket, 'write', chunk or '')
  if not data then
    return nil, err
  end
  if do_close and not socket:is_closing() then
    socket:shutdown()
    socket:close()
  end
  return data -- probably nothing?
end

-- only used to respond to invalid initial requests
-- could be done better if used a table gsub, but this will do
local function httpRes(code, reason, payload)
  return ('HTTP/1.1 {code} {reason}\r\nServer: {domain}\r\nContent-Length: {length}\r\n\r\n{payload}')
    :gsub('%{code%}', code)
    :gsub('%{reason%}', reason)
    :gsub('%{domain%}', PUBLIC_DOMAIN)
    :gsub('%{length%}', payload and #payload or #reason)
    :gsub('%{payload%}', payload and payload or reason)
end

-- the main server handle, where the "magic" happen
local function handler(initial_err)
  -- raise any initial errors
  assert(not initial_err, initial_err)

  -- create a socket to bind the client to
  local client_socket = uv.new_tcp()
  -- accept the client connection
  assert(server:accept(client_socket))

  -- read the sent request (read a single chunk of it)
  local chunk, err_msg = read(client_socket)
  -- failed to read, or client sent an empty request
  if not chunk or chunk == true then
    if err_msg then
      stdout:write(c('failure', 'Error while reading request from host: ' .. err_msg) .. '\n')
    end
    return write(client_socket, true)
  end

  -- retrieve the Host header
  local host = chunk:match('[Hh]ost: (.-)\r?\n')
  -- no host was specified, we won't be able to tell what is the subdomain without it
  -- it should never happen, since a Host header is absolutely required
  if not host then
    return write(client_socket, true, httpRes(400, 'No specified host header'))
  end

  -- is there such subdomain in our map? if one was specified at all
  local subdomain = host:match('([^%.]+)%.'):lower()
  if not subdomain then
    return write(client_socket, true, httpRes(400, 'No specified subdomain'))
  elseif not subdomains_map[subdomain] then
    return write(client_socket, true, httpRes(404, 'Subdomain not found'))
  end

  -- retrieve the subdomain port from the map
  local subdomain_port = subdomains_map[subdomain]
  local subdomain_uri = PUBLIC_DOMAIN .. ':' .. subdomain_port

  -- replace the host header with the uri we are supposedly using
  -- (we are actually using LOCAL_HOST to connect, but we want it to look similar to original header)
  chunk = chunk:gsub('[Hh]ost: .-\r?\n', 'Host: ' .. subdomain_uri .. '\r\n')

  -- establish a TCP connection to the subdomain server we're proxying to
  local subdomain_socket = uv.new_tcp()
  local success, fail_msg = await(subdomain_socket, 'connect', LOCAL_HOST, subdomain_port)
  if not success then
    stdout:write(c('failure', 'Error while trying to establish a connection to ' .. subdomain_uri .. ': ' .. fail_msg) .. '\n')
    return write(client_socket, true, httpRes(500, fail_msg))
  end

  -- start mirroring the tcp packets;
  -- that is: send the request to the subdomain server
  -- then receive the server response
  -- then send the response back.
  -- and keep looping this until one of the connections is closed.

  -- log the client's request
  local req = chunk:match('^(.-)\r?\n') or 'unknown request'
  stdout:write(c('highlight', 'Proxying ' .. req .. ' from ' .. host .. '\n\n'))

  -- listen for packets sent by the subdomain peer, and mirror them to client
  subdomain_socket:read_start(function(err, data)
    assert(not err, err) -- waiting for this to fail, and see in which scenario would that be
    if not data then
      -- DEBUGGING: print('Closing stream ' .. req .. '\n\n')
      return close(client_socket, subdomain_socket)
    end
    assert(client_socket:write(data)) -- should never fail
  end)

  -- listen for packets sent by the client, and mirror them to server
  -- (except for the initial request packet, we've handled that earlier for the headers)
  client_socket:read_start(function(err, data)
    if err or not data then
      return close(client_socket, subdomain_socket)
    end
    assert(subdomain_socket:write(data)) -- should never fail too
  end)

  -- send the initial client's request to the subdomain server
  -- this will start the above attached callbacks
  write(subdomain_socket, false, chunk)
end


stdout:write(c('success', 'Proxying ' .. PUBLIC_DOMAIN .. ':' .. PORT) .. '\n\n')

local success, err = pcall(function()
  -- create the server TCP socket and bind it to the domain:port
  server = uv.new_tcp()
  assert(server:bind(DOMAIN, PORT))

  -- start listening for TCP packets
  -- I am using this backlog value based on nothing other than Linux 5.4 using it too by default
  -- *and on some really rare errors I've been getting*
  assert(server:listen(4096, wrap(handler)))
end)

-- failed to init server? or some other unexpected error?
if not success then
  stdout:write(c('failure', 'An error has occurred: ' .. err) .. '\n')
end
