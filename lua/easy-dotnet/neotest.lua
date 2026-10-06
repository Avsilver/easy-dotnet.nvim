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

local function is_initialized()
  local ok, state = pcall(require, "easy-dotnet.test-runner.state")
  return ok and state.initialized == true
end

-- Shared future: first caller triggers init, all concurrent callers suspend on the
-- same future and resume together once the server finishes initialization.
-- neotest always calls is_test_file / discover_positions inside nio coroutines,
-- so .wait() correctly yields without blocking the Neovim event loop.
local _init_future = nil
local _indexed_nodes = nil
local _indexed_nodes_version = nil
local _test_file_index = nil

local function await_initialization()
  -- Switch to main loop
  require("nio").scheduler()

  if is_initialized() then return true end

  if not _init_future then
    local future = require("nio").control.future()
    _init_future = future
    local sln = require("easy-dotnet.current_solution").try_get_selected_solution()
    if not sln then
      future.set()
    else
      local client = get_client()
      client:initialize(function()
        client.testrunner:initialize(sln, function(result)
          if result and result.success then
            local ok, state = pcall(require, "easy-dotnet.test-runner.state")
            if ok then state.initialized = true end
          end
          future.set()
        end)
      end)
    end
  end

  local future = _init_future
  future.wait()
  if _init_future == future then _init_future = nil end
  return is_initialized()
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
  if not await_initialization() then return false end
  local state = require("easy-dotnet.test-runner.state")
  if _indexed_nodes ~= state.nodes or _indexed_nodes_version ~= state.nodes_version then
    _indexed_nodes = state.nodes
    _indexed_nodes_version = state.nodes_version
    _test_file_index = {}
    for _, node in pairs(state.nodes) do
      local path = normalize_path(node.filePath)
      if path then _test_file_index[path] = true end
    end
  end
  return _test_file_index[normalize_path(file_path)] == true
end

---@param file_path string
---@return neotest.Tree|nil
function M.discover_positions(file_path)
  if not await_initialization() then return nil end

  local nio = require("nio")
  local positions = nil
  local done = nio.control.future()

  get_client().testrunner:neotest_positions(file_path, function(result)
    positions = result
    done.set()
  end)
  done.wait()

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
      debug = args.strategy == "dap",
    },
    strategy = require("easy-dotnet.neotest.strategy"),
    stream = require("easy-dotnet.neotest.stream"),
  }
end

---@type fun(spec: neotest.RunSpec, result: neotest.StrategyResult, tree: neotest.Tree): table<string, neotest.Result>
M.results = require("easy-dotnet.neotest.results")

return M
