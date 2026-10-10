local M = {}

M.name = "easy-dotnet"

-- Neotest and the test runner can represent the same Windows path with
-- different slash styles (and casing). Keep path comparisons independent of
-- those representation differences.
local function normalize_path(path)
  if type(path) ~= "string" then return nil end
  local normalized = vim.fn.resolve(path):gsub("\\", "/")
  if vim.fn.has("win32") == 1 then normalized = normalized:lower() end
  return normalized
end

local function path_is_within(path, root)
  local normalized_path = normalize_path(path)
  local normalized_root = normalize_path(root)
  if not normalized_path or not normalized_root then return false end
  return normalized_path == normalized_root or vim.startswith(normalized_path, normalized_root .. "/")
end

local function get_client() return require("easy-dotnet.rpc.rpc").global_rpc_client end

local function get_neotest_subprocess()
  local ok, subprocess = pcall(require, "neotest.lib.subprocess")
  if not ok or not subprocess.enabled() then return nil end
  return subprocess
end

-- Neotest only needs the RPC connection here. Full test-runner initialization
-- builds/restores every project and must not gate per-file source sync.
local _client_future = nil
local _client_future_success = false
local _indexed_nodes = nil
local _indexed_nodes_version = nil
local _test_file_index = nil
local _synced_buffer_ticks = {}
local _synced_disk_contents = {}
local _discovered_contents = {}

local function sync_loaded_buffer(file_path)
  local normalized_path = normalize_path(file_path)
  if not normalized_path then return false end

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and normalize_path(vim.api.nvim_buf_get_name(bufnr)) == normalized_path then
      local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
      if _synced_buffer_ticks[normalized_path] == changedtick then return true end

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local content = table.concat(lines, "\n")
      local done = require("nio").control.future()
      local succeeded = false
      local finished = false
      local function finish(success)
        if finished then return end
        finished = true
        vim.schedule(function()
          succeeded = success
          if succeeded then _synced_buffer_ticks[normalized_path] = changedtick end
          done.set()
        end)
      end

      require("easy-dotnet.test-runner.buffer").sync_file(vim.api.nvim_buf_get_name(bufnr), content, get_client(), function(result) finish(result ~= nil) end, function() finish(false) end)
      done.wait()
      return true
    end
  end

  return false
end

local TEST_ATTRIBUTE_NAMES = { "fact", "theory", "testcase", "testcasesource", "testmethod", "test", "inlinedata", "datarow", "arguments" }

local function contains_test_attribute(content)
  local lower_content = content:lower()
  for _, name in ipairs(TEST_ATTRIBUTE_NAMES) do
    local from = 1
    while true do
      local start = lower_content:find(name, from, true)
      if not start then break end

      local preceding = lower_content:sub(1, start - 1):reverse()
      local open = preceding:find("%[")
      local close = preceding:find("%]")
      local next_char = lower_content:sub(start + #name, start + #name)
      if open and open <= 256 and (not close or open < close) and (next_char == "" or next_char:match("[%s%],%(]")) then return true end
      from = start + #name
    end
  end
  return false
end

local function sync_unloaded_test_file(file_path)
  local normalized_path = normalize_path(file_path)
  if not normalized_path then return end

  local ok, lines = pcall(vim.fn.readfile, file_path)
  if not ok or not lines then return end
  local content = table.concat(lines, "\n")
  if not contains_test_attribute(content) or _synced_disk_contents[normalized_path] == content then return end

  local done = require("nio").control.future()
  local succeeded = false
  local finished = false
  local function finish(success)
    if finished then return end
    finished = true
    vim.schedule(function()
      succeeded = success
      if succeeded then _synced_disk_contents[normalized_path] = content end
      done.set()
    end)
  end

  require("easy-dotnet.test-runner.buffer").sync_file(file_path, content, get_client(), function(result) finish(result ~= nil) end, function() finish(false) end)
  done.wait()
end

local function rebuild_test_file_index(state)
  _indexed_nodes = state.nodes
  _indexed_nodes_version = state.nodes_version
  _test_file_index = {}
  for _, node in pairs(state.nodes) do
    local path = normalize_path(node.filePath)
    if path then _test_file_index[path] = true end
  end
end

local function await_client()
  require("nio").scheduler()
  local client = get_client()
  if client._initialized then return true end

  if not _client_future then
    local future = require("nio").control.future()
    _client_future = future
    _client_future_success = false
    local settled = false
    local function finish(success)
      if settled then return end
      settled = true
      vim.schedule(function()
        _client_future_success = success
        future.set()
      end)
    end
    client:initialize(function() finish(true) end)
    vim.defer_fn(function() finish(false) end, 15000)
  end

  local future = _client_future
  future.wait()
  if _client_future == future then _client_future = nil end
  return _client_future_success
end

---@param _dir string
---@return string|nil
function M.root(_dir)
  local sln = require("easy-dotnet.current_solution").try_get_selected_solution()
  if not sln then return nil end
  local root = vim.fn.fnamemodify(sln, ":p:h")
  if vim.fn.has("win32") == 1 then root = root:gsub("/", "\\") end
  return root
end

---@param name string
---@return boolean
function M.filter_dir(name, _rel_path, _root) return not vim.tbl_contains({ "bin", "obj", ".git", ".vs", ".idea", "node_modules", "packages" }, name) end

---@param file_path string
---@return boolean
function M.is_test_file(file_path)
  if not file_path:lower():match("%.cs$") then return false end
  local subprocess = get_neotest_subprocess()
  if subprocess and subprocess.is_child() then return subprocess.call("require('easy-dotnet.neotest').is_test_file", { file_path }) end
  if not await_client() then return false end
  local state = require("easy-dotnet.test-runner.state")
  if not sync_loaded_buffer(file_path) then sync_unloaded_test_file(file_path) end
  if _indexed_nodes ~= state.nodes or _indexed_nodes_version ~= state.nodes_version then rebuild_test_file_index(state) end

  local normalized_file_path = normalize_path(file_path)
  if _indexed_nodes ~= state.nodes or _indexed_nodes_version ~= state.nodes_version then rebuild_test_file_index(state) end
  return _test_file_index[normalized_file_path] == true
end

--- Return the current buffer (or on-disk) content for a file, or nil if unavailable.
local function file_content(file_path)
  local normalized_path = normalize_path(file_path)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and normalize_path(vim.api.nvim_buf_get_name(bufnr)) == normalized_path then return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n") end
  end

  local ok, lines = pcall(vim.fn.readfile, file_path)
  if ok and lines then return table.concat(lines, "\n") end
  return nil
end

-- Source sync only registers provisional nodes; a parameterised test ([Theory]) needs a
-- real discovery pass against the built assembly to expand into its row subcases. Ask the
-- server to discover this file's project (no restore/build) before reading positions.
-- Memoised by content so an unbuilt project is retried and edits trigger rediscovery.
local function ensure_discovered(file_path)
  local normalized_path = normalize_path(file_path)
  if not normalized_path then return end

  local content = file_content(file_path)
  if content and _discovered_contents[normalized_path] == content then return end

  local done = require("nio").control.future()
  get_client().testrunner:discover_file(file_path, function(result)
    if result and result.success then
      if content then _discovered_contents[normalized_path] = content end
    else
      require("easy-dotnet.logger").warn(string.format("discoverFile failed for %s; parameterised rows may be missing", file_path))
    end
    done.set()
  end)
  done.wait()
end

---@param file_path string
---@return neotest.Tree|nil
local function get_neotest_positions(file_path)
  if not await_client() then return nil end
  if not sync_loaded_buffer(file_path) then sync_unloaded_test_file(file_path) end
  ensure_discovered(file_path)

  local nio = require("nio")
  local positions = nil
  local done = nio.control.future()

  get_client().testrunner:neotest_positions(file_path, function(result)
    positions = result
    done.set()
  end)
  done.wait()

  return positions
end

-- Called by neotest's embedded Neovim worker through subprocess.call so all
-- easy-dotnet RPC traffic uses the parent editor's single server connection.
M._get_positions_for_subprocess = get_neotest_positions

---@param file_path string
---@return neotest.Tree|nil
function M.discover_positions(file_path)
  local subprocess = get_neotest_subprocess()
  local positions
  if subprocess and subprocess.is_child() then
    positions = subprocess.call("require('easy-dotnet.neotest')._get_positions_for_subprocess", { file_path })
  else
    positions = get_neotest_positions(file_path)
  end

  if not positions or #positions == 0 then return nil end

  local node_map = {}
  for _, pos in ipairs(positions) do
    node_map[pos.id] = pos
  end

  local function build_list(node_id)
    local node = node_map[node_id]
    if not node then return nil end
    local list = {
      {
        id = node.id,
        name = node.name,
        type = node.type,
        path = file_path,
        range = { node.startLine or 0, 0, node.endLine or (node.startLine or 0), 0 },
      },
    }
    for _, child in ipairs(positions) do
      if child.parentId == node_id then
        local child_list = build_list(child.id)
        if child_list then table.insert(list, child_list) end
      end
    end
    return list
  end

  local file_root = {
    {
      id = file_path,
      name = vim.fn.fnamemodify(file_path, ":t"),
      type = "file",
      path = file_path,
      range = { 0, 0, 0, 0 },
    },
  }
  local normalized_file_path = normalize_path(file_path)
  for _, pos in ipairs(positions) do
    if normalize_path(pos.parentId) == normalized_file_path then
      local child_list = build_list(pos.id)
      if child_list then table.insert(file_root, child_list) end
    end
  end

  local Tree = require("neotest.types").Tree
  return Tree.from_list(file_root, function(pos) return pos.id end)
end

---@param args neotest.RunArgs
---@return neotest.RunSpec|nil
function M.build_spec(args)
  local root = args.tree:data()

  local result_ids = {}
  for _, pos in args.tree:iter() do
    if pos.type == "test" then table.insert(result_ids, pos.id) end
  end

  if #result_ids == 0 then result_ids = { root.id } end

  local node_id = root.id
  local first_child = args.tree:children()[1]

  if root.type == "file" then
    node_id = first_child and first_child:data().id or root.id
  elseif root.type == "dir" then
    local state = require("easy-dotnet.test-runner.state")
    local dir = normalize_path(root.id)

    for _, node in pairs(state.nodes) do
      if node.type and node.type.type == "Project" and node.filePath then
        if normalize_path(vim.fn.fnamemodify(node.filePath, ":h")) == dir then
          node_id = node.id
          break
        end
      end

      -- for typical folders neotest just assigns folder path so we need to determine
      -- proper node id that does exist on server side  based on it
      if node.type and node.type.type == "Namespace" and node.displayName == root.name and first_child then
        local doesChildBelongToFolder = path_is_within(first_child:data().path, root.path)
        if doesChildBelongToFolder then node_id = node.id end
      end
    end
  end

  return {
    command = {},
    context = {
      node_id = node_id,
      result_ids = result_ids,
      file_path = root.path,
      debug = args.strategy == "dap",
    },
    strategy = require("easy-dotnet.neotest.strategy"),
    stream = require("easy-dotnet.neotest.stream"),
  }
end

---@type fun(spec: neotest.RunSpec, result: neotest.StrategyResult, tree: neotest.Tree): table<string, neotest.Result>
M.results = require("easy-dotnet.neotest.results")

return M
