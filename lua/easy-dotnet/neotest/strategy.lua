local run_context = require("easy-dotnet.neotest.run-context")
local run_queue = require("easy-dotnet.neotest.run-queue")

local function normalize_path(path)
  if type(path) ~= "string" then return nil end
  -- URI-scheme buffer names (diffview://, vscode://, ...) are not filesystem
  -- paths and must never be resolved or sent to the server.
  if path:find("://", 1, true) then return nil end
  local normalized = vim.fn.resolve(path):gsub("\\", "/")
  if vim.fn.has("win32") == 1 then normalized = normalized:lower() end
  return normalized
end

local function sync_test_file(spec, client)
  local file_path = spec.context.file_path
  if type(file_path) ~= "string" or file_path:find("://", 1, true) or not file_path:lower():match("%.cs$") then return true end

  local content
  local normalized_file_path = normalize_path(file_path)
  local bufnr
  for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(candidate) and normalize_path(vim.api.nvim_buf_get_name(candidate)) == normalized_file_path then
      bufnr = candidate
      break
    end
  end

  if bufnr then
    content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  else
    local ok, lines = pcall(vim.fn.readfile, file_path)
    if not ok or not lines then return true end
    content = table.concat(lines, "\n")
  end

  local nio = require("nio")
  local done = nio.control.future()
  local sync_result, sync_error
  local finished = false
  local function finish(result, err)
    if finished then return end
    finished = true
    vim.schedule(function()
      sync_result = result
      sync_error = err
      done.set()
    end)
  end

  require("easy-dotnet.test-runner.buffer").sync_file(file_path, content, client, function(result) finish(result) end, function(err) finish(nil, err and err.message or "RPC error") end)
  done.wait()
  return sync_result ~= nil, sync_error
end

---@param spec neotest.RunSpec
---@param _context table
---@return neotest.Process
return function(spec, _context)
  local client = require("easy-dotnet.rpc.rpc").global_rpc_client
  local ctx = run_context.begin_run(spec.context.node_id, spec.context.result_ids)

  run_queue.add(function()
    local synced, sync_error = sync_test_file(spec, client)
    if not synced then
      local message = "easy-dotnet failed to sync the test file before running it: " .. tostring(sync_error or "unknown error")
      spec.context.run_error = message
      ctx:fail(message)
      return
    end

    local function on_result(result)
      if result then
        -- `success = false` means the test operation completed with failing
        -- tests/build results; it is not an RPC failure. Let results.lua fetch
        -- and map those per-test details instead of replacing them with a
        -- generic run-level error.
        vim.schedule(function() ctx:finish() end)
        return
      end

      local message = "easy-dotnet Neotest RPC returned no result"
      spec.context.run_error = message
      ctx:fail(message)
    end

    local function on_crash(err)
      local message = err and err.message or "unknown RPC error"
      local failure = "easy-dotnet Neotest RPC failed: " .. message
      spec.context.run_error = failure
      ctx:fail(failure)
    end

    if spec.context.debug then
      client.testrunner:debug(spec.context.node_id, on_result, "neotest", on_crash)
    else
      client.testrunner:run(spec.context.node_id, on_result, "neotest", on_crash)
    end

    ctx.completion.wait()
  end)

  return {
    result = function() return ctx.completion.wait() end,
    output_stream = function() return ctx.result_chan.get end,
    output = function() return ctx:flush_stdout_to_tempfile() end,
    stop = function() client.testrunner:cancel() end,
    is_complete = function() return ctx.completion.is_set() end,
    attach = function() end,
  }
end
