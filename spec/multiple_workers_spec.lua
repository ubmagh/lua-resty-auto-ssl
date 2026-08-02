local http = require "resty.http"
local server = require "spec.support.server"

-- This test has occasionally dropped a small fraction of its 1000 requests
-- under the free Cloudflare Tunnel (which is explicitly best-effort, no
-- uptime guarantee) rather than every run. The ngx.log calls below are kept
-- intentionally so a recurrence surfaces the actual failing step and error
-- in the CI log artifact, instead of just the generic count mismatch.
local function make_http_requests()
  local httpc = http.new()

  local _, connect_err = httpc:connect("127.0.0.1", 9443)
  if connect_err then
    ngx.log(ngx.ERR, "auto-ssl test debug: connect failed: ", connect_err)
  end
  assert.equal(nil, connect_err)

  local _, ssl_err = httpc:ssl_handshake(nil, server.tunnel_hostname, true)
  if ssl_err then
    ngx.log(ngx.ERR, "auto-ssl test debug: ssl_handshake failed: ", ssl_err)
  end
  assert.equal(nil, ssl_err)

  -- Make pipelined requests on this connection to test behavior across
  -- the same connection.
  local requests = {}
  for _ = 1, 10 do
    table.insert(requests, {
      path = "/foo",
    })
  end

  local responses, request_err = httpc:request_pipeline(requests)
  if request_err then
    ngx.log(ngx.ERR, "auto-ssl test debug: request_pipeline failed: ", request_err)
  end
  assert.equal(nil, request_err)

  for _, res in ipairs(responses) do
    if res.status ~= 200 then
      ngx.log(ngx.ERR, "auto-ssl test debug: unexpected status: ", res.status)
    end
    assert.equal(200, res.status)

    local body, body_err = res:read_body()
    if body_err then
      ngx.log(ngx.ERR, "auto-ssl test debug: read_body failed: ", body_err)
    end
    assert.equal(nil, body_err)
    if body ~= "foo" then
      ngx.log(ngx.ERR, "auto-ssl test debug: unexpected body: ", tostring(body))
    end
    assert.equal("foo", body)

    -- Keep track of the total number of successful requests across all
    -- the parallel requests.
    if res.status == 200 and body == "foo" then
      local _, incr_err = ngx.shared.test_counts:incr("successes", 1)
      assert.equal(nil, incr_err)
    end
  end

  local _, close_err = httpc:close()
  assert.equal(nil, close_err)
end

describe("multiple workers", function()
  before_each(server.stop)
  after_each(server.stop)

  it("issues a new SSL certificate when multiple nginx workers are running and concurrent requests are made", function()
    server.start({
      master_process = "on",
      worker_processes = 5,
    })

    local _, err = ngx.shared.test_counts:set("successes", 0)
    assert.equal(nil, err)

    -- Make 50 concurrent requests to see how separate connections are
    -- handled during initial registration.
    local threads = {}
    for _ = 1, 50 do
      table.insert(threads, ngx.thread.spawn(make_http_requests))
    end
    for _, thread in ipairs(threads) do
      ngx.thread.wait(thread)
    end

    local error_log = server.nginx_error_log_tail:read()
    assert.matches("issuing new certificate for", error_log, nil, true)

    -- Make some more concurrent requests after waiting for the first batch
    -- to succeed. All of these should then be dealing with the cached certs.
    threads = {}
    for _ = 1, 50 do
      table.insert(threads, ngx.thread.spawn(make_http_requests))
    end
    for _, thread in ipairs(threads) do
      ngx.thread.wait(thread)
    end

    -- Report the total number of successful requests across all the parallel
    -- requests to make sure it matches what's expected.
    assert.equal(1000, ngx.shared.test_counts:get("successes"))

    error_log = server.nginx_error_log_tail:read()
    assert.Not.matches("issuing new certificate for", error_log, nil, true)

    error_log = server.read_error_log()
    assert.Not.matches("[warn]", error_log, nil, true)
    assert.Not.matches("[error]", error_log, nil, true)
    assert.Not.matches("[alert]", error_log, nil, true)
    assert.Not.matches("[emerg]", error_log, nil, true)
  end)
end)
