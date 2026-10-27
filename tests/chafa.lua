local test = require "core.test"
local core = require "core"
local process = require "process"
local Chafa = require "plugins.tui.chafa"

test.describe("Chafa image backend", function()
  local backend, start, clock, threads, redraw
  test.before_each(function()
    start, clock = process.start, system.get_time
    threads, core.threads = core.threads, {}
    redraw = core.redraw
    backend = Chafa.new()
  end)
  test.after_each(function()
    backend:close()
    process.start, system.get_time = start, clock
    core.threads, core.redraw = threads, redraw
  end)

  ---Drive only the converter's coroutine without advancing unrelated UI work.
  local function finish()
    for _ = 1, 100 do
      if not backend.worker then return end
      local ok, err = coroutine.resume(core.threads[backend.worker].cr)
      test.ok(ok, err)
    end
    test.fail("Chafa worker failed to finish")
  end

  ---A nonblocking process fixture with controlled output and failure state.
  ---@param output string
  ---@param code? integer
  ---@return table
  local function converter(output, code)
    local remaining = output
    return {
      read_stdout = function() local chunk = remaining; remaining = nil; return chunk end,
      running = function() return remaining ~= nil end,
      returncode = function() return code or 0 end,
      close_stream = function() end,
      kill = function() remaining = nil end
    }
  end

  test.test("decodes colors, inverse spaces, transparent cells and CRLF", function()
    local grid, err = Chafa.decode("\27[38;2;255;0;0;48;2;0;0;255m▀"
      .. "\27[0m \r\n\27[7;38;2;0;255;0m \27[0m\n", 2, 2)
    test.not_nil(grid, err)
    test.equal(grid:cell(0, 0)[1], "▀")
    test.equal(grid:cell(0, 0)[2], 0xff0000)
    test.equal(grid:cell(0, 0)[3], 0x0000ff)
    test.not_ok(grid:cell(1, 0)[6])
    test.equal(grid:cell(0, 1)[3], 0x00ff00)
    test.is_nil(grid:cell(0, 1)[2])
  end)

  test.test("rejects cursor controls and malformed colors instead of emitting them", function()
    for _, output in ipairs({"\27[2J", "\27]0;title\7", "\27[38;2;256;0;0mX", "\tX"}) do
      local grid, err = Chafa.decode(output, 2, 2)
      test.is_nil(grid)
      test.type(err, "string")
    end
  end)

  test.test("starts lazily, caches previews and uses shell-free portable arguments", function()
    local calls = 0
    local source = {path = "/image folder/a; $(test).png"}
    process.start = function(args, options)
      calls = calls + 1
      test.equal(args[#args], source.path)
      test.equal(args[#args - 1], "--")
      test.equal(args[1], PLATFORM == "Windows" and "chafa.exe" or "chafa")
      test.contains(table.concat(args, " "), "--probe=off")
      test.contains(table.concat(args, " "), "--format=symbols")
      test.equal(options.stdin, process.REDIRECT_DISCARD)
      return converter("\27[48;2;255;0;0m  \n  \n")
    end
    local grid, message = backend:get(source, 16, 32)
    test.is_nil(grid)
    test.equal(message, "Loading image preview...")
    test.equal(calls, 0)
    backend:get(source, 16, 32)
    finish()
    grid = backend:get(source, 16, 32)
    test.equal(grid:cell(0, 0)[3], 0xff0000)
    test.equal(calls, 1)
    for _ = 1, 100 do backend:get(source, 16, 32) end
    test.equal(calls, 1)
    test.is_nil(backend.worker)
    test.ok(core.redraw)
  end)

  test.test("missing Chafa produces an installation hint and is not retried each frame", function()
    local calls = 0
    process.start = function() calls = calls + 1; return nil, "not found" end
    backend:get({path = "missing.png"}, 16, 32)
    finish()
    for _ = 1, 10 do
      local grid, message = backend:get({path = "another.png"}, 16, 32)
      test.is_nil(grid)
      test.contains(message, "Install chafa")
    end
    test.equal(calls, 1)
  end)

  test.test("failed decoding is cached without disabling other images", function()
    local calls = 0
    process.start = function()
      calls = calls + 1
      return converter("", 1)
    end
    local source = {path = "unsupported.png"}
    backend:get(source, 16, 32)
    finish()
    local _, message = backend:get(source, 16, 32)
    test.contains(message, "could not decode")
    test.not_ok(backend.missing)
    test.equal(calls, 1)
    backend:get({path = "next.png"}, 16, 32)
    finish()
    test.equal(calls, 2)
  end)

  test.test("rapid zoom retains only two conversions and limits oversized previews", function()
    local calls = 0
    process.start = function()
      calls = calls + 1
      return converter("\27[48;2;255;0;0m \n")
    end
    local source = {path = "large.png"}
    for width = 8, 80, 8 do backend:get(source, width, 32) end
    test.equal(#source.previews, 2)
    finish()
    test.equal(calls, 2)
    backend:get(source, 1000000, 1000000)
    local entry = source.previews[1]
    test.ok(entry.columns * entry.rows <= 65536)
  end)

  test.test("a stalled converter times out and closing cancels active work", function()
    local killed, now = 0, 0
    process.start = function()
      return {read_stdout = function() end, running = function() return true end,
        kill = function() killed = killed + 1 end, close_stream = function() end}
    end
    system.get_time = function() now = now + 5; return now end
    backend:get({path = "slow.png"}, 16, 32)
    finish()
    test.equal(killed, 1)
    backend:get({path = "next.png"}, 16, 32)
    test.ok(coroutine.resume(core.threads[backend.worker].cr))
    backend:close()
    test.equal(killed, 2)
    test.is_nil(backend.worker)
    test.is_nil(backend.process)
  end)
end)
