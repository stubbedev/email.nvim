local M = {}

function M.start()
  local server = { messages = {} }
  local tcp = assert(vim.uv.new_tcp())
  assert(tcp:bind("127.0.0.1", 0))
  server.port = tcp:getsockname().port
  assert(tcp:listen(8, function(err)
    assert(not err, err)
    local client = assert(vim.uv.new_tcp())
    tcp:accept(client)
    local buffer, data = "", nil
    local function say(line)
      client:write(line .. "\r\n")
    end
    say("220 test ESMTP")
    client:read_start(function(read_err, chunk)
      if read_err or not chunk then
        client:close()
        return
      end
      buffer = buffer .. chunk
      while true do
        local line, rest = buffer:match("^(.-)\r\n(.*)$")
        if not line then
          return
        end
        buffer = rest
        if data then
          if line == "." then
            server.messages[#server.messages + 1] = table.concat(data, "\n") .. "\n"
            data = nil
            say("250 queued")
          else
            data[#data + 1] = line:sub(1, 1) == "." and line:sub(2) or line
          end
        else
          local verb = (line:match("^(%S+)") or ""):upper()
          if verb == "EHLO" or verb == "HELO" then
            say("250 test")
          elseif verb == "DATA" then
            data = {}
            say("354 go")
          elseif verb == "QUIT" then
            say("221 bye")
          else
            say("250 ok")
          end
        end
      end
    end)
  end))
  function server.last()
    return server.messages[#server.messages]
  end
  function server.stop()
    tcp:close()
  end
  return server
end

return M
