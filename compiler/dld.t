

local dld = {}
package.loaded["compiler.dld"] = dld
dld.__index = dld


-- DATA LAYOUT DESCRIPTION

--[[

  {
    type: {
      vector_size: (number, 1 usually could be a tuple of 2,3,4 elements)
      base_type_str: (string expression of type)
      base_bytes: (number, # of bytes used for base type)
    }
    logical_size: (number, the count of the items in the array)
    address: (pointer, where to find the data)
    stride:  (number, how much space to expect between entries)
    offset:  (number, how many bytes to skip after address)
  }

]]--

function dld.new(params)
  local desc = setmetatable({}, dld)
  if params then desc:init(params) end
  return desc
end

function dld.is_dld(o)
  return getmetatable(o) == dld
end

function dld:init(params)
  params = params or {}

  if params.type then
    if terralib.types.istype(params.type) then
      self:setTerraType(params.type)
    end
  end

  if params.logical_size then
    self:setLogicalSize(params.logical_size)
  end

  if params.data then
    self:setData(params.data)
  end

  if params.stride then
    self:setStride(params.stride)
  end

  if params.offset then
    self:setOffset(params.offset)
  end

  if params.compact then
    self:setCompactStrideOffset()
  end
end

function dld:setTerraType(typ)
  if not terralib.types.istype(typ) then
    error('setTerraType() only accepts Terra types as arguments')
  end
  self.type = {}

  if typ:isvector() then
    self.type.vector_size = typ.N
    typ = typ.type
  else
    self.type.vector_size = 1
  end

  if not typ:isprimitive() then
    error('Cannot handle non-vector, non-primitive types in DLD')
  else
    self.type.base_type_str = tostring(typ)
    self.type.base_bytes    = terralib.sizeof(typ)
  end
end

function dld:setLogicalSize(n)
  self.logical_size = n
end

function dld:setData(ptr)
  self.address = ptr
end

function dld:setStride(stride)
  self.stride = stride
end

function dld:setOffset(offset)
  self.offset = offset
end

function dld:setCompactStrideOffset()
  self.stride = self.type.vector_size * self.type.base_bytes
  self.offset = 0
end

function dld:getPhysicalSize()
  return self.logical_size * self.stride
end


