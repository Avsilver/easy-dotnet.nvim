local nio = require("nio")

local OUTCOME_MAP = {
  passed = "passed",
  failed = "failed",
  faulted = "failed",
  skipped = "skipped",
  none = "skipped",
  inconclusive = "skipped",
  cancelled = "skipped",
  buildfailed = "failed",
}

---@param detail easy-dotnet.TestRunner.NeotestBatchResult
---@return neotest.Result
local function to_neotest_result(detail)
  local errors = nil
  local stack_trace = {}

  if detail.errorMessage and #detail.errorMessage > 0 then
    local failing_frame = detail.failingFrame
    local diagnostic_line = failing_frame and failing_frame.isFromTest and failing_frame.line and failing_frame.line - 1 or nil

    for _, item in ipairs(detail.frames or {}) do
      table.insert(stack_trace, item.originalText)
    end

    errors = {
      {
        message = table.concat(detail.errorMessage, "\n"),
        line = diagnostic_line,
      },
    }
  end

  local output_path = vim.fn.tempname()
  local f = io.open(output_path, "w")
  if f then
    if detail.stdout and #detail.stdout > 0 then f:write(table.concat(detail.stdout, "\n")) end
    if errors then
      f:write("\n" .. (errors[1].message or ""))
      f:write("\n\n" .. (detail.failingFrame and detail.failingFrame.originalText or ""))
      f:write("\n\n" .. (table.concat(stack_trace, "\n") .. "\n\n"))
    end
    f:close()
  end

  return {
    status = OUTCOME_MAP[(detail.outcome or ""):lower()] or "failed",
    short = detail.errorMessage and detail.errorMessage[1] or nil,
    errors = errors,
    output = output_path,
  }
end

---@param spec neotest.RunSpec
---@param _strategy_result neotest.StrategyResult
---@param _tree neotest.Tree
---@return table<string, neotest.Result>
return function(spec, _strategy_result, _tree)
  local client = require("easy-dotnet.rpc.rpc").global_rpc_client
  local ids = spec.context and spec.context.result_ids
  if not ids or #ids == 0 then return {} end

  local batch = nil
  local done = nio.control.future()

  client.testrunner:neotest_batch_results(ids, function(res)
    batch = res
    done.set()
  end)
  done.wait()

  batch = batch or {}

  local out = {}
  for id, detail in pairs(batch) do
    out[id] = to_neotest_result(detail)
  end
  if spec.context.run_error then
    for _, id in ipairs(ids) do
      if not out[id] then out[id] = {
        status = "failed",
        short = spec.context.run_error,
        errors = { { message = spec.context.run_error } },
      } end
    end
  end
  return out
end
