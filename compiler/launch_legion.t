-- Launch liszt program as a top level legion task.

-- set up a global structure to stash legion variables into
rawset(_G, '_legion_env', {})
local LE = rawget(_G, '_legion_env')

local C = require "compiler.c"

-- Legion library
local LW = require "compiler.legionwrap"

local terra dereference_legion_context(ctx : &LW.legion_context_t)
  return @ctx
end

local terra dereference_legion_runtime(runtime : &LW.legion_runtime_t)
  return @runtime
end

-- Top level task
TID_TOP_LEVEL = 100

-- Error handler to display stack trace
local function top_level_err_handler(errobj)
  local err = tostring(errobj)
  if not string.match(err, 'stack traceback:') then
    err = err .. '\n' .. debug.traceback()
  end
  print(err)
  os.exit(1)
end

-- Launch Liszt application
function load_liszt()
  local script_filename = arg[1]
  local success = xpcall( function ()
    assert(terralib.loadfile(script_filename))()
    LW.legion_runtime_issue_execution_fence(LE.legion_env:get().runtime,
                                            LE.legion_env:get().ctx)
  end, top_level_err_handler)
end

-- Run Liszt compiler/ Lua-Terra interpreter as a top level task
local terra top_level_task(
  task_args   : LW.legion_task_t,
  regions     : &LW.legion_physical_region_t,
  num_regions : uint32,
  ctx         : LW.legion_context_t,
  runtime     : LW.legion_runtime_t
)
  LE.legion_env.ctx = ctx
  LE.legion_env.runtime = runtime
  load_liszt()
end

-- Note 4 types of processors

--      TOC_PROC = ::TOC_PROC, // Throughput core
--      LOC_PROC = ::LOC_PROC, // Latency core
--      UTIL_PROC = ::UTIL_PROC, // Utility core
--      PROC_GROUP = ::PROC_GROUP, // Processor group


-- Main function that launches Legion runtime
local terra main()
  LW.legion_runtime_register_task_void(
    TID_TOP_LEVEL, LW.LOC_PROC, true, false, 1,
    LW.legion_task_config_options_t {
      leaf = false,
      inner = false,
      idempotent = false },
    'top_level_task', top_level_task)

  LW.legion_runtime_register_task_void(
    LW.TID_SIMPLE_CPU, LW.LOC_PROC, true, false, 1,
    LW.legion_task_config_options_t {
      leaf = false,
      inner = false,
      idempotent = false },
    'simple_task_cpu', LW.simple_task)
  LW.legion_runtime_register_task_void(
    LW.TID_SIMPLE_GPU, LW.LOC_PROC, true, false, 1,
    LW.legion_task_config_options_t {
      leaf = false,
      inner = false,
      idempotent = false },
    'simple_task_gpu', LW.simple_task)

  LW.legion_runtime_register_task(
    LW.TID_FUTURE_CPU, LW.LOC_PROC, true, false, 1,
    LW.legion_task_config_options_t {
      leaf = false,
      inner = false,
      idempotent = false },
    'future_task_cpu', LW.future_task)
  LW.legion_runtime_register_task(
    LW.TID_FUTURE_GPU, LW.LOC_PROC, true, false, 1,
    LW.legion_task_config_options_t {
      leaf = false,
      inner = false,
      idempotent = false },
    'future_task_gpu', LW.future_task)

  LW.legion_runtime_set_top_level_task_id(TID_TOP_LEVEL)

  -- arguments
  var n_args  = 3
  var args    = arrayof(rawstring,
    [arg[0]..' '..arg[1]], -- include the Liszt invocation here;
                           -- doesn't matter though
    "-level",
    "5"
  )

  LW.legion_runtime_start(n_args, args, false)
end

main()
