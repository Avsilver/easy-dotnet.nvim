local M = {}

local function do_initialize(client, solution_path)
  local state = require("easy-dotnet.test-runner.state")
  client:initialize(function()
    state.active_handle = client.testrunner:initialize(solution_path, function(result)
      if result and result.success then
        state.initialized = true
      else
        require("easy-dotnet.logger").error("Test runner initialization failed")
      end
    end)
  end)
end

local function attach_source_sync()
  local client = require("easy-dotnet.rpc.rpc").global_rpc_client
  local buffer = require("easy-dotnet.test-runner.buffer")
  local function attach(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then return end
    local path = vim.api.nvim_buf_get_name(bufnr)
    if not path:lower():match("%.cs$") then return end
    client:initialize(function() buffer.attach(path, client) end)
  end

  local group = vim.api.nvim_create_augroup("EasyDotnetTestSourceSync", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufWritePost" }, {
    group = group,
    pattern = "*.cs",
    callback = function(ev) attach(ev.buf) end,
  })
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    attach(bufnr)
  end
end

function M.auto_start()
  -- Source sync is independent of the optional full test-runner auto-discovery.
  -- Attach before the first server discovery so newly created files can register
  -- probable tests as soon as they are opened/saved.
  attach_source_sync()
end

function M.open()
  local options = require("easy-dotnet.options").get_option("test_runner")
  local render = require("easy-dotnet.test-runner.render")
  local state = require("easy-dotnet.test-runner.state")
  local current_solution = require("easy-dotnet.current_solution")
  local client = require("easy-dotnet.rpc.rpc").global_rpc_client

  if render.win and vim.api.nvim_win_is_valid(render.win) then
    render.hide()
    return
  end

  render.open(options.viewmode, options)
  require("easy-dotnet.test-runner.keymaps").register(render.buf, client, options)

  -- Source sync may already have created the solution/project/test nodes. Do not
  -- start a solution-wide initialize in that case: it would hold the run lock and
  -- make the just-synced current test wait for every project to discover.
  if state.root_id then
    -- Expand the current test file's project (no restore/build) so parameterised
    -- tests show their row subcases without having to run a test first.
    local path = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
    if path:lower():match("%.cs$") then client:initialize(function()
      client.testrunner:discover_file(path, function() end)
    end) end
    return
  end

  current_solution.get_or_pick_solution(function(solution_path)
    if not solution_path then return end
    do_initialize(client, solution_path)
  end)
end

return M
