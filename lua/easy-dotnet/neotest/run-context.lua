local nio = require("nio")
local events = require("easy-dotnet.neotest.events")

local M = {}

local TERMINAL_TYPES = {
  Passed = true,
  Failed = true,
  Faulted = true,
  Skipped = true,
  Inconclusive = true,
  Cancelled = true,
  BuildFailed = true,
}

---@class easy-dotnet.neotest.RunContext
---@field root_node_id string
---@field leaf_ids table<string, boolean>
---@field completion nio.control.Future
---@field result_chan nio.control.Queue

---@param root_id string  The node ID that was passed to testrunner/run
---@param leaf_ids string[] All leaf position IDs (type == "test") in the subtree
---@return easy-dotnet.neotest.RunContext
function M.begin_run(root_id, leaf_ids)
  local leaf_set = {}
  local pending_leaf_ids = {}
  for _, id in ipairs(leaf_ids) do
    leaf_set[id] = true
    pending_leaf_ids[id] = true
  end

  ---@class easy-dotnet.neotest.RunContext
  local ctx = {
    root_node_id = root_id,
    leaf_ids = leaf_set,
    pending_leaf_ids = pending_leaf_ids,
    completion = nio.control.future(),
    result_chan = nio.control.queue(),
    _stdout = {},
  }

  local unsubscribe = events.subscribe("updateStatus", function(id, status) ctx:on_update(id, status) end)

  function ctx:finish()
    if self.completion.is_set() then return end
    self.result_chan.put_nowait(nil)
    self.completion.set(0)
    unsubscribe()
  end

  function ctx:fail(message)
    if self.completion.is_set() then return end
    self.failure_message = message
    table.insert(self._stdout, message)
    self.result_chan.put_nowait(nil)
    self.completion.set(1)
    unsubscribe()
    require("easy-dotnet.logger").error(message)
  end

  function ctx:on_update(id, status)
    local status_type = status and status.type or ""
    if not TERMINAL_TYPES[status_type] then return end

    if self.leaf_ids[id] then
      self.result_chan.put_nowait(vim.json.encode({ id = id, status = status }) .. "\n")
      self.pending_leaf_ids[id] = nil
    end

    local has_build_failed = status_type == "BuildFailed"
    if has_build_failed then
      self:fail("Build failed while running Neotest tests")
      local client = require("easy-dotnet.rpc.rpc").global_rpc_client
      client.testrunner:get_build_errors(id)
    elseif id == self.root_node_id or next(self.pending_leaf_ids) == nil then
      self:finish()
    end
  end

  function ctx:flush_stdout_to_tempfile()
    local path = vim.fn.tempname()
    local f = io.open(path, "w")
    if f then
      f:write(table.concat(self._stdout, "\n"))
      f:close()
    end
    return path
  end

  return ctx
end

return M
