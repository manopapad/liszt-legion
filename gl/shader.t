


local Shader = {}
package.loaded["gl.shader"] = Shader
Shader.__index = Shader

local ffi   = require 'ffi'
local C     = terralib.require 'compiler.c'
local gl    = terralib.require 'gl.gl'
local mat4f = terralib.require 'gl.mat4f'


function Shader.new()
  return setmetatable({
    program_id = nil,
    vert_shader_id = nil,
    frag_shader_id = nil,
    vert_src = nil,
    frag_src = nil,
  }, Shader)
end


function Shader:release()
  if self.program_id then
    gl.glDeleteProgram(self.program_id)
    self.program_id = nil
  end

  if self.vert_shader_id then
    gl.glDeleteShader(self.vert_shader_id)
    self.vert_shader_id = nil
  end

  if self.frag_shader_id then
    gl.glDeleteShader(self.frag_shader_id)
    self.frag_shader_id = nil
  end
end

function Shader:use()
  gl.glUseProgram(self.program_id)
end



function Shader:load_vert_str(str_src)
  self.vert_src = str_src
end
function Shader:load_frag_str(str_src)
  self.frag_src = str_src
end

function Shader:compile()
  -- get the source
  if type(self.vert_src) ~= 'string' then
    error('cannot compile without vertex shader source loaded')
  end
  if type(self.frag_src) ~= 'string' then
    error('cannot compile without fragment shader source loaded')
  end

  local vert_str = terralib.global(&int8, self.vert_src)
  local frag_str = terralib.global(&int8, self.frag_src)

  -- Create and compile the shaders
  local prog = gl.glCreateProgram()
  local vert = gl.glCreateShader(gl.VERTEX_SHADER)
  local frag = gl.glCreateShader(gl.FRAGMENT_SHADER)
  self.program_id     = prog
  self.vert_shader_id = vert
  self.frag_shader_id = frag

  gl.glShaderSource(vert, 1, vert_str:getpointer(), nil)
  gl.glShaderSource(frag, 1, frag_str:getpointer(), nil)
  gl.glAttachShader(prog, vert)
  gl.glAttachShader(prog, frag)
  gl.glCompileShader(vert)
  gl.glCompileShader(frag)
end


function Shader:link()
  -- Link the program
  gl.glLinkProgram(self.program_id)
end


-- returns true when valid, false when not
function Shader:validate(vao)
  if not self.program_id then
    error('cannot validate an uncompiled/linked shader')
  end

  vao:bind()
  gl.glValidateProgram(self.program_id)
  vao:unbind()

  local is_valid = true
  local p_validate_program = ffi.new 'int[1]'
  gl.glGetProgramiv(self.program_id, gl.VALIDATE_STATUS, p_validate_program)
  if p_validate_program[0] == 0 then
      is_valid = false
  end

  return is_valid
end

local terra get_shader_info(shader : gl.GLuint) : &int8
  var buffer  : &int8 = nil
  var log_len : int
  gl.glGetShaderiv(shader, gl.INFO_LOG_LENGTH, &log_len)
  if log_len > 0 then
    buffer = [&int8](C.malloc(log_len))
    var chars_written : int
    gl.glGetShaderInfoLog(shader, log_len, &chars_written, buffer)
    -- ignore chars_written for now???
  end
  return buffer
end
local terra get_program_info(program : gl.GLuint) : &int8
  var buffer  : &int8 = nil
  var log_len : int
  gl.glGetProgramiv(program, gl.INFO_LOG_LENGTH, &log_len)
  if log_len > 0 then
    buffer = [&int8](C.malloc(log_len))
    var chars_written : int
    gl.glGetProgramInfoLog(program, log_len, &chars_written, buffer)
  end
  return buffer
end
local function get_info(is_shader, obj)
  local buffer
  if is_shader then
    buffer = get_shader_info(obj)
  else
    buffer = get_program_info(obj)
  end

  if buffer ~= nil then -- must check nil b/c buffer is cdata
    local result = ffi.string(buffer)
    C.free(buffer)
    return result
  else
    return nil
  end
end
local getShaderInfo  = function(shader)  return get_info(true,  shader)  end
local getProgramInfo = function(program) return get_info(false, program) end

-- returns a table with 'vert', 'frag', 'prog' entries 
function Shader:getLogs(options)
  options = options or {}

  local vertinfo = getShaderInfo(self.vert_shader_id) or options.null_val
  local fraginfo = getShaderInfo(self.frag_shader_id) or options.null_val
  local proginfo = getProgramInfo(self.program_id)    or options.null_val

  return {
    vert = vertinfo,
    frag = fraginfo,
    prog = proginfo,
  }
end


-- gets the program id
function Shader:id()
  return self.program_id
end


function Shader:setUniform(name, val)
  if not mat4f.is_mat4f(val) then
    error('only mat4f uniforms are currently supported.', 2)
  end

  local loc = gl.glGetUniformLocation(self.program_id, name)
  gl.glUniformMatrix4fv(loc,
                        1, false, -- expect column-major matrices
                        val.col)
end


-- How do we support this (if we do)
-- gl.glDeleteProgram(shader_program)
-- gl.glDeleteShader(vert_shader)
-- gl.glDeleteShader(frag_shader)



return Shader



