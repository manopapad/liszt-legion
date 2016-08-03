-- The MIT License (MIT)
--
-- Copyright (c) 2015 Stanford University.
-- All rights reserved.
--
-- Permission is hereby granted, free of charge, to any person obtaining a
-- copy of this software and associated documentation files (the "Software"),
-- to deal in the Software without restriction, including without limitation
-- the rights to use, copy, modify, merge, publish, distribute, sublicense,
-- and/or sell copies of the Software, and to permit persons to whom the
-- Software is furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included
-- in all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
-- FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
-- DEALINGS IN THE SOFTWARE.

local A = {}
package.loaded["admiral"] = A

import 'ebb'
import 'regent'

local AST = require 'ebb.src.ast'
local C   = require 'ebb.src.c'
local F   = require 'ebb.src.functions'
local L   = require 'ebblib'
local M   = require 'ebb.src.main'
local P   = require 'ebb.src.phase'
local R   = require 'ebb.src.relations'
local RG  = regentlib
local S   = require 'ebb.src.semant'
local T   = require 'ebb.src.types'

local DEBUG = true

-------------------------------------------------------------------------------
-- Helper functions
-------------------------------------------------------------------------------

local function quit(obj)
  print('====================')
  print('Unsupported class:')
  if not obj then
    print('Nil')
  elseif obj.kind then
    print(obj.kind)
  else
    print('(no kind information)')
  end
  print('--------------------')
  while obj do
    for k,_ in pairs(obj) do
      print(k)
    end
    print('--------------------')
    obj = getmetatable(obj)
  end
  assert(false)
end

-- terralib.type -> number
local function minValue(typ)
  return
    (typ == int)    and -2147483648 or
    (typ == int8)   and -128 or
    (typ == int16)  and -32768 or
    (typ == int32)  and -2147483648 or
    (typ == int64)  and -9223372036854775808 or
    (typ == uint)   and 0 or
    (typ == uint8)  and 0 or
    (typ == uint16) and 0 or
    (typ == uint32) and 0 or
    (typ == uint64) and 0 or
    (typ == bool)   and 0 or
    (typ == float)  and -math.huge or
    (typ == double) and -math.huge or
    assert(false)
end

-- terralib.type -> number
local function maxValue(typ)
  return
    (typ == int)    and 2147483647 or
    (typ == int8)   and 127 or
    (typ == int16)  and 32767 or
    (typ == int32)  and 2147483647 or
    (typ == int64)  and 9223372036854775807 or
    (typ == uint)   and 4294967295 or
    (typ == uint8)  and 255 or
    (typ == uint16) and 65535 or
    (typ == uint32) and 4294967295 or
    (typ == uint64) and 18446744073709551615 or
    (typ == bool)   and 1 or
    (typ == float)  and math.huge or
    (typ == double) and math.huge or
    assert(false)
end

-- string, terralib.type -> number
local function opIdentity(op, typ)
  return
    (op == '+')   and 0 or
    (op == '-')   and 0 or
    (op == '*')   and 1 or
    (op == '/')   and 1 or
    (op == 'max') and minValue(typ) or
    (op == 'min') and minValue(typ) or
    assert(false)
end

-- T*, T -> T*, T*
local function split(list, at)
  local head = terralib.newlist()
  local tail = terralib.newlist()
  local found = false
  for _,x in ipairs(list) do
    if found then
      tail:insert(x)
    elseif x == at then
      found = true
    else
      head:insert(x)
    end
  end
  return head, tail
end

-- T:terralib.type, N:int -> (T[N], T[N] -> T)
local emitDotProduct = terralib.memoize(function(T, N)
  local terra dot(a:T[N], b:T[N])
    escape
      if N == 1 then
        emit quote return a[0] * b[0] end
      elseif N == 2 then
        emit quote return a[0] * b[0] + a[1] * b[1] end
      elseif N == 3 then
        emit quote return a[0] * b[0] + a[1] * b[1] + a[2] * b[2] end
      else assert(false) end
    end
  end
  return dot
end)

-- RG.rexpr* -> RG.rexpr
local function arrayRExpr(elems)
  if #elems == 1 then
    local a = elems[1]
    return rexpr array(a) end
  elseif #elems == 2 then
    local a = elems[1]
    local b = elems[2]
    return rexpr array(a, b) end
  elseif #elems == 3 then
    local a = elems[1]
    local b = elems[2]
    local c = elems[3]
    return rexpr array(a, b, c) end
  elseif #elems == 4 then
    local a = elems[1]
    local b = elems[2]
    local c = elems[3]
    local d = elems[4]
    return rexpr array(a, b, c, d) end
  elseif #elems == 5 then
    local a = elems[1]
    local b = elems[2]
    local c = elems[3]
    local d = elems[4]
    local e = elems[5]
    return rexpr array(a, b, c, d, e) end
  elseif #elems == 6 then
    local a = elems[1]
    local b = elems[2]
    local c = elems[3]
    local d = elems[4]
    local e = elems[5]
    local f = elems[6]
    return rexpr array(a, b, c, d, e, f) end
  else assert(false) end
end

-- () -> boolean
function F.Function:isKernel()
  return (#self._decl_ast.params == 1 and
          self._decl_ast.ptypes[1]:iskey() and
          not self._decl_ast.exp)
end

-------------------------------------------------------------------------------
-- Basic Regent mappings
-------------------------------------------------------------------------------

-- map(B.Builtin, (double -> double))
local unaryArithFuns = {
  [L.acos]  = C.acos,
  [L.asin]  = C.asin,
  [L.atan]  = C.atan,
  [L.cbrt]  = C.cbrt,
  [L.ceil]  = C.ceil,
  [L.cos]   = C.cos,
  [L.fabs]  = C.fabs,
  [L.floor] = C.floor,
  [L.fmod]  = C.fmod,
  [L.log]   = C.log,
  [L.sin]   = C.sin,
  [L.sqrt]  = C.sqrt,
  [L.tan]   = C.tan,
}

-- map(B.Builtin, (double, double -> double))
local binaryArithFuns = {
  [L.pow]   = C.pow,
}

-- T.Type -> terralib.type
local function toRType(ltype)
  if ltype:isprimitive() then
    return ltype:terratype()
  elseif ltype:isvector() then
    return toRType(ltype.type)[ltype.N]
  elseif ltype:ismatrix() then
    return toRType(ltype.type)[ltype.Nrow][ltype.Ncol]
  elseif ltype:iskey() then
    return ltype.relation:indexType()
  else assert(false) end
end

-- M.ExprConst, terralib.type? -> RG.rexpr
local function toRConst(lit, typ)
  if type(lit) == 'boolean' then
    assert(not typ or typ == bool)
    return rexpr lit end
  elseif type(lit) == 'number' then
    if typ then
      return rexpr [typ](lit) end
    else
      return rexpr lit end
    end
  elseif type(lit) == 'table' then
    assert(terralib.israwlist(lit))
    local elemT
    if typ then
      assert(#lit == typ.N)
      elemT = typ.type
    end
    return arrayRExpr(terralib.newlist(lit):map(function(e)
      return toRConst(e, elemT)
    end))
  else assert(false) end
end

-------------------------------------------------------------------------------
-- Relation-to-region translation
-------------------------------------------------------------------------------

-- () -> RG.index_type
function R.Relation:indexType()
  local dims = self:Dims()
  return
    (#dims == 1) and int1d or
    (#dims == 2) and int2d or
    (#dims == 3) and int3d or
    assert(false)
end

-- () -> RG.ispace_type
function R.Relation:indexSpaceType()
  return ispace(self:indexType())
end

-- () -> terralib.struct
R.Relation.fieldSpace = terralib.memoize(function(self)
  local fs = terralib.types.newstruct(self:Name() .. '_columns')
  for _,fld in ipairs(self._fields) do
    fs.entries:insert({fld:Name(), toRType(fld:Type())})
  end
  if DEBUG then fs:printpretty() end
  return fs
end)

-- () -> RG.region_type
function R.Relation:regionType()
  -- Region types in signatures must be distinct, so we're not caching here.
  return region(self:indexSpaceType(), self:fieldSpace())
end

-- () -> RG.rexpr
function R.Relation:mkISpaceInit()
  local dims = self:Dims()
  return
    (#dims == 1) and rexpr
      ispace(int1d, [dims[1]])
    end or
    (#dims == 2) and rexpr
      ispace(int2d, { x = [dims[1]], y = [dims[2]] })
    end or
    (#dims == 3) and rexpr
      ispace(int3d, { x = [dims[1]], y = [dims[2]], z = [dims[3]] })
    end or
    assert(false)
end

-- () -> RG.rexpr
function R.Relation:mkRegionInit()
  local ispaceExpr = self:mkISpaceInit()
  local fspaceExpr = self:fieldSpace()
  return rexpr region(ispaceExpr, fspaceExpr) end
end

-------------------------------------------------------------------------------
-- Function translation
-------------------------------------------------------------------------------

-- FunInfo = {
--   name           : string
--   domainRel      : R.Relation
--   field_use      : map(R.Field, P.PhaseType)
--   global_use     : map(L.Global, P.PhaseType)
-- }

local FunContext = {}
FunContext.__index = FunContext

-- FunInfo, AST.Symbol*, T.Type* -> FunContext
function FunContext.New(info, argNames, argTypes)
  local self = setmetatable({
    -- Symbol mappings
    localMap        = {},                 -- map(AST.Symbol, RG.rexpr)
    globalMap       = {},                 -- map(L.Global, RG.symbol)
    relMap          = {},                 -- map(R.Relation, RG.symbol)
    -- Signature information
    domainSym       = nil,                -- RG.Symbol?
    domainRel       = nil,                -- R.Relation?
    args            = terralib.newlist(), -- RG.Symbol*
    accessedRels    = terralib.newlist(), -- R.Relation*
    readGlobals     = terralib.newlist(), -- L.Global*
    -- Field use information
    -- TODO: implicitly over accessedRels[1]
    readCols        = terralib.newlist(), -- string*
    writeCols       = terralib.newlist(), -- string*
    plusRdCols      = terralib.newlist(), -- string*
    minusRdCols     = terralib.newlist(), -- string*
    multRdCols      = terralib.newlist(), -- string*
    divRdCols       = terralib.newlist(), -- string*
    maxRdCols       = terralib.newlist(), -- string*
    minRdCols       = terralib.newlist(), -- string*
    -- Global reduction information
    reducedGlobal   = nil,                -- L.Global?
    globalReduceAcc = nil,                -- RG.symbol?
    globalReduceOp  = nil,                -- string?
  }, FunContext)
  -- Process mapped relation
  if info.domainRel then
    local rel = info.domainRel
    self.domainSym = RG.newsymbol(rel:regionType(), 'dom')
    self.domainRel = rel
    -- Mapped relation always set as first accessed relation.
    self.accessedRels:insert(rel)
    self.relMap[rel] = RG.newsymbol(rel:regionType(), rel:Name())
  end
  -- Process arguments
  for i,lsym in ipairs(argNames) do
    local rsym = RG.newsymbol(tostring(lsym), toRType(argTypes[i]))
    self.args:insert(rsym)
    self.localMap[lsym] = rexpr rsym end
  end
  -- Process field access modes
  for fld,pt in pairs(info.field_use) do
    if #self.accessedRels > 0 then
      assert(fld:Relation() == self.accessedRels[1])
    else
      local rel = fld:Relation()
      self.accessedRels:insert(rel)
      self.relMap[rel] = RG.newsymbol(rel:regionType(), rel:Name())
    end
    -- Assuming phase checking has checked for errors
    if pt.read or pt.write then self.readCols:insert(fld:Name()) end
    if pt.write then self.writeCols:insert(fld:Name()) end
    if pt.reduceop then
      local rdCols =
        (pt.reduceop == '+')   and self.plusRdCols or
        (pt.reduceop == '-')   and self.minusRdCols or
        (pt.reduceop == '*')   and self.multRdCols or
        (pt.reduceop == '/')   and self.divRdCols or
        (pt.reduceop == 'max') and self.maxRdCols or
        (pt.reduceop == 'min') and self.minRdCols or
        assert(false)
      rdCols:insert(fld:Name())
    end
  end
  -- Process global access modes
  for g,pt in pairs(info.global_use) do
    if pt.read and not pt.reduceop then
      assert(not self.globalMap[g])
      self.globalMap[g] = RG.newsymbol(toRType(g:Type()))
      self.readGlobals:insert(g)
    elseif pt.reduceop and not pt.read then
      assert(not self.reducedGlobal)
      self.reducedGlobal = g
      self.globalReduceAcc = RG.newsymbol(toRType(g:Type()), 'acc')
      self.globalReduceOp = op
    else assert(false) end
  end
  return self
end

-- AST.Symbol -> RG.symbol
function FunContext:addLocal(lsym)
  assert(not self.localMap[lsym])
  local rsym = RG.newsymbol(tostring(lsym))
  self.localMap[lsym] = rexpr rsym end
  return rsym
end

-- AST.Symbol, RG.rexpr -> ()
function FunContext:addAlias(lsym, expr)
  assert(not self.localMap[lsym])
  self.localMap[lsym] = expr
end

-- () -> RG.symbol*
function FunContext:signature()
  local fullArgs = terralib.newlist()
  if self.domainRel then
    fullArgs:insert(self.domainSym)
  end
  for i,arg in ipairs(self.args) do
    if i > 1 or not self.domainRel then
      fullArgs:insert(self.args[i])
    end
  end
  for _,rel in ipairs(self.accessedRels) do
    fullArgs:insert(self.relMap[rel])
  end
  for _,g in ipairs(self.readGlobals) do
    fullArgs:insert(self.globalMap[g])
  end
  return fullArgs
end

-- FunInfo -> RG.task, FunContext
function AST.UserFunction:toTask(info)
  -- self.params : AST.Symbol*
  -- self.ptypes : T.Type*
  -- self.body   : AST.Block
  -- self.exp    : AST.Expression?
  local ctxt = FunContext.New(info, self.params, self.ptypes)
  assert(not ctxt.reducedGlobal or not self.exp)
  -- Synthesize body
  local body = terralib.newlist() -- RG.quote*
  if ctxt.reducedGlobal then
    local accInitVal =
      opIdentity(ctxt.globalReduceOp, ctxt.globalReduceAcc:gettype())
    body:insert(rquote var [ctxt.globalReduceAcc] = [accInitVal] end)
  end
  local block = self.body:toRQuote(ctxt)
  if info.domainRel then
    local loopVar = ctxt.args[1]
    block = rquote for [loopVar] in [ctxt.domainSym] do [block] end end
  end
  body:insert(block)
  if ctxt.reducedGlobal then
    body:insert(rquote return [ctxt.globalReduceAcc] end)
  end
  if self.exp then
    body:insert(rquote return [self.exp:toRExpr(ctxt)] end)
  end
  -- Synthesize task
  -- TODO: Remove hacks from this part, once Regent bugs are fixed.
  local tsk
  local args = ctxt:signature()
  if info.domainRel then
    local dom = ctxt.domainSym
    local univ = ctxt.relMap[ctxt.domainRel]
    assert(dom == args[1] and univ == args[2])
    local _, rest = split(args, univ)
    local task st([dom], [univ], [rest]) where
      dom <= univ,
      reads      (univ.[ctxt.readCols]),
      writes     (univ.[ctxt.writeCols]),
      reduces +  (univ.[ctxt.plusRdCols]),
      reduces -  (univ.[ctxt.minusRdCols]),
      reduces *  (univ.[ctxt.multRdCols]),
      reduces /  (univ.[ctxt.divRdCols]),
      reduces max(univ.[ctxt.maxRdCols]),
      reduces min(univ.[ctxt.minRdCols])
    do [body] end
    tsk = st
  elseif #ctxt.accessedRels > 0 then
    local univ = ctxt.relMap[ctxt.accessedRels[1]]
    local _, rest = split(args, univ)
    local task st([univ], [rest]) where
      reads      (univ.[ctxt.readCols]),
      writes     (univ.[ctxt.writeCols]),
      reduces +  (univ.[ctxt.plusRdCols]),
      reduces -  (univ.[ctxt.minusRdCols]),
      reduces *  (univ.[ctxt.multRdCols]),
      reduces /  (univ.[ctxt.divRdCols]),
      reduces max(univ.[ctxt.maxRdCols]),
      reduces min(univ.[ctxt.minRdCols])
    do [body] end
    tsk = st
  else
    local task st([args]) [body] end
    tsk = st
  end
  -- Finalize task
  tsk:setname(info.name)
  tsk.ast.name[1] = info.name -- TODO: Dangerous
  if DEBUG then tsk:printpretty() end
  return tsk, ctxt
end

local toKernelTask_cache = {} -- map(F.Function, {RG.task,FunContext})

-- () -> RG.task, FunContext
function F.Function:toKernelTask()
  if toKernelTask_cache[self] then
    return unpack(toKernelTask_cache[self])
  end
  assert(self:isKernel())
  local argRel = self._decl_ast.ptypes[1].relation
  local info = self:_get_typechecked(42, argRel, {})
  local typedAST = info.typed_ast
  -- info : {
  --   ...
  --   typed_ast      : AST.UserFunction
  --   field_use      : map(R.Field, P.PhaseType)
  --   global_use     : map(L.Global, P.PhaseType)
  -- }
  info.name = self._name
  info.domainRel = argRel
  if DEBUG then
    print(self._name)
    typedAST:pretty_print()
  end
  local tsk, ctxt = typedAST:toTask(info)
  toKernelTask_cache[self] = {tsk, ctxt}
  return tsk, ctxt
end

local toHelperTask_cache = {} -- map(F.Function, {RG.task,FunContext})

-- T.Type*, R.Relation? -> RG.task, FunContext
function F.Function:toHelperTask(argTypes, callerDom)
  -- TODO: Only caching on the function object; we assume the helper functions
  -- have a single specialization.
  if toHelperTask_cache[self] then
    return unpack(toHelperTask_cache[self])
  end
  -- If the caller has centered access to a relation, the helper can use it.
  -- TODO: This is not necessarily true for all the calls to this helper,
  -- i.e. this information should be included in the caching scheme.
  local typedAST = S.check_helper_func(self, argTypes, callerDom)
  local info = P.phasePass(typedAST)
  -- info : {
  --   ...
  --   field_use      : map(R.Field, P.PhaseType)
  --   global_use     : map(L.Global, P.PhaseType)
  -- }
  info.name = self._name
  info.domainRel = nil
  typedAST.ptypes = argTypes
  if DEBUG then
    print(self._name)
    typedAST:pretty_print()
  end
  local tsk, ctxt = typedAST:toTask(info)
  toHelperTask_cache[self] = {tsk, ctxt}
  return tsk, ctxt
end

-------------------------------------------------------------------------------
-- AST translation
-------------------------------------------------------------------------------

-- AST.Expression, FunContext -> RG.rexpr
local function recoverHelperCall(expr, ctxt)
  -- expr.orig_func   : F.Function
  -- expr.orig_params : AST.Expression*
  local argTypes = terralib.newlist(expr.orig_params):map(function(p)
    return p.node_type
  end)
  local hTask, hCtxt = expr.orig_func:toHelperTask(argTypes, ctxt.domainRel)
  local actualArgs = terralib.newlist()
  for _,p in ipairs(expr.orig_params) do
    actualArgs:insert(p:toRExpr(ctxt))
  end
  for _,rel in ipairs(hCtxt.accessedRels) do
    actualArgs:insert(assert(ctxt.relMap[rel]))
  end
  for _,g in ipairs(hCtxt.readGlobals) do
    actualArgs:insert(assert(ctxt.globalMap[g]))
  end
  return rexpr [hTask]([actualArgs]) end
end

-- FunContext -> RG.rexpr
function AST.Expression:toRExpr(ctxt)
  error('Abstract Method')
end
function AST.BinaryOp:toRExpr(ctxt)
  -- self.lhs : AST.Expression
  -- self.rhs : AST.Expression
  -- self.op  : string
  local a = self.lhs:toRExpr(ctxt)
  local b = self.rhs:toRExpr(ctxt)
  return
    (self.op == '==')  and rexpr a == b  end or
    (self.op == '~=')  and rexpr a ~= b  end or
    (self.op == '<')   and rexpr a < b   end or
    (self.op == '>')   and rexpr a > b   end or
    (self.op == '<=')  and rexpr a <= b  end or
    (self.op == '>=')  and rexpr a >= b  end or
    (self.op == 'or')  and rexpr a or b  end or
    (self.op == 'and') and rexpr a and b end or
    (self.op == '+')   and rexpr a + b   end or
    (self.op == '-')   and rexpr a - b   end or
    (self.op == '*')   and rexpr a * b   end or
    (self.op == '/')   and rexpr a / b   end or
    (self.op == '%')   and rexpr a % b   end or
    assert(false)
end
function AST.Bool:toRExpr(ctxt)
  quit(self)
end
function AST.Call:toRExpr(ctxt)
  -- self.func   : B.Builtin
  -- self.params : table*
  assert(L.is_builtin(self.func))
  -- Affine expression
  -- self.params[1] : AST.LuaObject
  --   .node_type.value : R.Relation
  -- self.params[2] : AST.MatrixLiteral
  --   .n       : int
  --   .m       : int
  --   .matvals : int[.n][.m]
  -- self.params[3] : AST.Expression
  if self.func == L.Affine then
    local rel = self.params[1].node_type.value
    -- TODO: The translated expression for self.params[3] is duplicated.
    assert(self.params[2].m == self.params[2].n + 1)
    local N = self.params[2].n
    local mat = self.params[2].matvals
    -- Only allowing diagonal translation matrices.
    for i=1,N do for j=1,N do
      assert(i == j and mat[i][j] == 1 or
             i ~= j and mat[i][j] == 0)
    end end
    local base = self.params[3]:toRExpr(ctxt)
    if N == 2 then
      local x = mat[1][3]
      local y = mat[2][3]
      return rexpr (base + {x,y}) % [ctxt.relMap[rel]].bounds end
    elseif N == 3 then
      local x = mat[1][4]
      local y = mat[2][4]
      local z = mat[3][4]
      return rexpr (base + {x,y,z}) % [ctxt.relMap[rel]].bounds end
    else assert(false) end
  end
  -- Assertion
  -- self.params[1] : AST.Expression
  if self.func == L.assert then
    return rexpr
      RG.assert([self.params[1]:toRExpr(ctxt)], '(Liszt assertion)')
    end
  end
  -- Key unboxing
  -- self.params[1] : AST.Expression
  if self.func == L.id then
    -- TODO: Need to do something extra here?
    return self.params[1]:toRExpr(ctxt)
  elseif self.func == L.xid then
    return rexpr [self.params[1]:toRExpr(ctxt)].x end
  elseif self.func == L.yid then
    return rexpr [self.params[1]:toRExpr(ctxt)].y end
  elseif self.func == L.zid then
    return rexpr [self.params[1]:toRExpr(ctxt)].z end
  end
  -- Unary arithmetic function
  -- self.params[1] : AST.Expression
  if unaryArithFuns[self.func] then
    local arg = self.params[1]:toRExpr(ctxt)
    return rexpr [unaryArithFuns[self.func]](arg) end
  end
  -- Binary arithmetic function
  -- self.params[1] : AST.Expression
  -- self.params[2] : AST.Expression
  if binaryArithFuns[self.func] then
    local arg1 = self.params[1]:toRExpr(ctxt)
    local arg2 = self.params[2]:toRExpr(ctxt)
    return rexpr [binaryArithFuns[self.func]](arg1, arg2) end
  end
  -- Min/max call
  -- self.params[1] : AST.Expression
  -- self.params[2] : AST.Expression
  if self.func == L.fmax or self.func == L.imax then
    local arg1 = self.params[1]:toRExpr(ctxt)
    local arg2 = self.params[2]:toRExpr(ctxt)
    return rexpr max(arg1, arg2) end
  end
  if self.func == L.fmin or self.func == L.imin then
    local arg1 = self.params[1]:toRExpr(ctxt)
    local arg2 = self.params[2]:toRExpr(ctxt)
    return rexpr min(arg1, arg2) end
  end
  -- Random number generator
  if self.func == L.rand then
    return rexpr [double](C.rand()) / C.RAND_MAX end
  end
  -- Dot product
  -- self.params[1] : AST.Expression
  -- self.params[2] : AST.Expression
  if self.func == L.dot then
    local t1 = self.params[1].node_type
    local t2 = self.params[2].node_type
    assert(t1:isvector() and t2:isvector() and t1.N == t2.N)
    local fun = emitDotProduct(toRType(t1.type), t1.N)
    if DEBUG then fun:printpretty() end
    local arg1 = self.params[1]:toRExpr(ctxt)
    local arg2 = self.params[2]:toRExpr(ctxt)
    return rexpr fun([arg1], [arg2]) end
  end
  -- TODO: Not covered: L.print, L.cross, L.length, L.UNSAFE_ROW
  assert(false)
end
function AST.Cast:toRExpr(ctxt)
  -- self.node_type : T.Type
  -- self.value     : AST.Expression
  local rtype = toRType(self.node_type)
  return rexpr [rtype]([self.value:toRExpr(ctxt)]) end
end
function AST.FieldAccess:toRExpr(ctxt)
  -- self.field : R.Field
  -- self.key   : AST.Expression
  local rel = self.key.node_type.relation
  -- TODO: Assuming that off-center accesses are only made using Affine
  -- expressions, therefore we don't need to bounds-check here.
  return rexpr
    [ctxt.relMap[rel]][ [self.key:toRExpr(ctxt)] ].[self.field:Name()]
  end
end
function AST.FieldAccessIndex:toRExpr(ctxt)
  -- self.base  : AST.FieldAccess
  -- self.field : R.Field
  -- self.key   : AST.Expression
  -- self.index : AST.Expression
  return rexpr
    [self.base:toRExpr(ctxt)][ [self.index:toRExpr(ctxt) ] ]
  end
end
function AST.Global:toRExpr(ctxt)
  -- self.global : L.Global
  return rexpr
    [ctxt.globalMap[self.global]]
  end
end
function AST.GlobalIndex:toRExpr(ctxt)
  -- self.index  : AST.Expression
  -- self.global : L.Global
  return rexpr
    [ctxt.globalMap[self.global]][ [self.index:toRExpr(ctxt)] ]
  end
end
function AST.LetExpr:toRExpr(ctxt)
  -- self.block       : AST.Block
  -- self.exp         : AST.Expression
  -- self.orig_func   : F.Function?
  -- self.orig_params : (AST.Expression*)?
  assert(self.block:is(AST.Block))
  -- Call to user-defined helper function: emit as separate task
  if self.orig_func then
    return recoverHelperCall(self, ctxt)
  end
  -- Call to macro: handle common case of simple alias expression
  assert(#self.block.statements == 1)
  local decl = self.block.statements[1]
  assert(decl:is(AST.DeclStatement))
  ctxt:addAlias(decl.name, decl.initializer:toRExpr(ctxt))
  return self.exp:toRExpr(ctxt)
end
function AST.LuaObject:toRExpr(ctxt)
  quit(self)
end
function AST.MatrixLiteral:toRExpr(ctxt)
  quit(self)
end
function AST.Name:toRExpr(ctxt)
  -- self.name : AST.Symbol
  return assert(ctxt.localMap[self.name])
end
function AST.Number:toRExpr(ctxt)
  -- self.node_type : T.Type
  -- self.value     : number
  return rexpr [toRType(self.node_type)]([self.value]) end
end
function AST.Quote:toRExpr(ctxt)
  -- self.code : AST.Expression
  return self.code:toRExpr(ctxt)
end
function AST.RecordLiteral:toRExpr(ctxt)
  quit(self)
end
function AST.Reduce:toRExpr(ctxt)
  quit(self)
end
function AST.SquareIndex:toRExpr(ctxt)
  -- self.node_type : T.Type
  -- self.base      : AST.Expression
  -- self.index     : AST.Expression
  return rexpr
    [self.base:toRExpr(ctxt)][ [self.index:toRExpr(ctxt)] ]
  end
end
function AST.String:toRExpr(ctxt)
  quit(self)
end
function AST.TableLookup:toRExpr(ctxt)
  quit(self)
end
function AST.UnaryOp:toRExpr(ctxt)
  -- self.exp : AST.Expression
  -- self.op  : string
  local arg = self.exp:toRExpr(ctxt)
  return
    (self.op == '-')   and rexpr -arg    end or
    (self.op == 'not') and rexpr not arg end or
    assert(false)
end
function AST.VectorLiteral:toRExpr(ctxt)
  -- self.node_type : T.Type
  -- self.elems     : AST.Expression*
  return arrayRExpr(terralib.newlist(self.elems):map(function(e)
    return e:toRExpr(ctxt)
  end))
end
function AST.Where:toRExpr(ctxt)
  quit(self)
end

-- FunContext -> RG.rquote
function AST.Statement:toRQuote(ctxt)
  error('Abstract Method')
end
function AST.Assignment:toRQuote(ctxt)
  -- self.lvalue : AST.Expression
  -- self.exp    : AST.Expression
  return rquote
    [self.lvalue:toRExpr(ctxt)] = [self.exp:toRExpr(ctxt)]
  end
end
function AST.Break:toRQuote(ctxt)
  quit(self)
end
function AST.DeclStatement:toRQuote(ctxt)
  -- self.name        : AST.Symbol
  -- self.node_type   : T.Type
  -- self.initializer : AST.Expression
  local rsym = ctxt:addLocal(self.name)
  return rquote
    var [rsym] = [self.initializer:toRExpr(ctxt)]
  end
end
function AST.DeleteStatement:toRQuote(ctxt)
  quit(self)
end
function AST.DoStatement:toRQuote(ctxt)
  -- self.body        : AST.Block
  -- self.orig_func   : F.Function?
  -- self.orig_params : (AST.Expression*)?
  return self.body:toRQuote(ctxt)
end
function AST.ExprStatement:toRQuote(ctxt)
  -- self.exp : AST.Expression | AST.DoStatement
  if self.exp:is(AST.DoStatement) then
    return self.exp:toRQuote(ctxt)
  end
  return rquote [self.exp:toRExpr(ctxt)] end
end
function AST.FieldWrite:toRQuote(ctxt)
  -- self.fieldaccess : AST.FieldAccess
  -- self.exp         : AST.Expression
  return rquote
    [self.fieldaccess:toRExpr(ctxt)] = [self.exp:toRExpr(ctxt)]
  end
end
function AST.GenericFor:toRQuote(ctxt)
  quit(self)
end
function AST.GlobalReduce:toRQuote(ctxt)
  -- self.global   : AST.Global
  -- self.reduceop : string
  -- self.exp      : AST.Expression
  assert(self.global.global == ctxt.reducedGlobal)
  local acc = ctxt.globalReduceAcc
  local val = self.exp:toRExpr(ctxt)
  return
    (self.reduceop == '+')   and rquote acc += val   end or
    (self.reduceop == '-')   and rquote acc -= val   end or
    (self.reduceop == '*')   and rquote acc *= val   end or
    (self.reduceop == '/')   and rquote acc /= val   end or
    (self.reduceop == 'max') and rquote acc max= val end or
    (self.reduceop == 'min') and rquote acc min= val end or
    assert(false)
end
function AST.IfStatement:toRQuote(ctxt)
  -- self.if_blocks  : AST.CondBlock*
  -- self.else_block : AST.Block
  local quot
  for i=#self.if_blocks,1,-1 do
    local cond = self.if_blocks[i].cond:toRExpr(ctxt)
    local body = self.if_blocks[i].body:toRQuote(ctxt)
    if quot then
      quot = rquote if [cond] then [body] else [quot] end end
    elseif self.else_block then
      local innerElse = self.else_block:toRQuote(ctxt)
      quot = rquote if [cond] then [body] else [innerElse] end end
    else
      quot = rquote if [cond] then [body] end end
    end
  end
  return quot
end
function AST.InsertStatement:toRQuote(ctxt)
  quit(self)
end
function AST.NumericFor:toRQuote(ctxt)
  -- self.name  : AST.Symbol
  -- self.lower : AST.Expression
  -- self.upper : AST.Expression
  -- self.body  : AST.Block
  local i = ctxt:addLocal(self.name)
  return rquote
    for [i] = [self.lower:toRExpr(ctxt)], [self.lower:toRExpr(ctxt)] do
      [self.body:toRQuote(ctxt)]
    end
  end
end
function AST.RepeatStatement:toRQuote(ctxt)
  quit(self)
end
function AST.WhileStatement:toRQuote(ctxt)
  quit(self)
end

-- FunContext -> RG.rquote
function AST.Block:toRQuote(ctxt)
  local stmtQuotes =
    terralib.newlist(self.statements):map(function(stmt)
      return stmt:toRQuote(ctxt)
    end)
  return rquote
    [stmtQuotes]
  end
end

-------------------------------------------------------------------------------
-- Control program translation
-------------------------------------------------------------------------------

-- ProgramContext -> RG.rquote
function M.AST.Stmt:toRQuote(ctxt)
  error('Abstract method')
end
function M.AST.Block:toRQuote(ctxt)
  return rquote
    [self.stmts:map(function(s) return s:toRQuote(ctxt) end)]
  end
end
function M.AST.ForEach:toRQuote(ctxt)
  local tsk, fCtxt = self.fun:toKernelTask()
  local actualArgs = terralib.newlist()
  local domArg = self.subset
    and ctxt.subsetMap[self.subset]
    or ctxt.relMap[self.rel]
  actualArgs:insert(domArg)
  for _,rel in ipairs(fCtxt.accessedRels) do
    actualArgs:insert(assert(ctxt.relMap[rel]))
  end
  for _,g in ipairs(fCtxt.readGlobals) do
    actualArgs:insert(assert(ctxt.globalMap[g]))
  end
  local callExpr = rexpr [tsk]([actualArgs]) end
  local callQuote = rquote [callExpr] end
  if fCtxt.reducedGlobal then
    local retSym = ctxt.globalMap[fCtxt.reducedGlobal]
    local op = fCtxt.globalReduceOp
    callQuote =
      (op == '+')   and rquote [retSym] +=   [callExpr] end or
      (op == '-')   and rquote [retSym] -=   [callExpr] end or
      (op == '*')   and rquote [retSym] *=   [callExpr] end or
      (op == '/')   and rquote [retSym] /=   [callExpr] end or
      (op == 'max') and rquote [retSym] max= [callExpr] end or
      (op == 'min') and rquote [retSym] min= [callExpr] end or
      assert(false)
  end
  return callQuote
end
function M.AST.If:toRQuote(ctxt)
  if self.elseBlock then
    return rquote
      if [self.cond:toRExpr(ctxt)] then
        [self.thenBlock:toRQuote(ctxt)]
      else
        [self.elseBlock:toRQuote(ctxt)]
      end
    end
  else
    return rquote
      if [self.cond:toRExpr(ctxt)] then
        [self.thenBlock:toRQuote(ctxt)]
      end
    end
  end
end
function M.AST.LoadField:toRQuote(ctxt)
  local relSym = ctxt.relMap[self.fld:Relation()]
  local valTyp = toRType(self.fld:Type())
  return rquote
    fill(relSym.[self.fld:Name()], [toRConst(self.val, valTyp)])
  end
end
function M.AST.SetGlobal:toRQuote(ctxt)
  return rquote
    [ctxt.globalMap[self.global]] = [self.expr:toRExpr(ctxt)]
  end
end
function M.AST.While:toRQuote(ctxt)
  return rquote
    __demand(__spmd)
    while [self.cond:toRExpr(ctxt)] do
      [self.body:toRQuote(ctxt)]
    end
  end
end

-- ProgramContext -> RG.rexpr
function M.AST.Cond:toRExpr(ctxt)
  error('Abstract method')
end
function M.AST.Literal:toRExpr(ctxt)
  return rexpr [self.val] end
end
function M.AST.And:toRExpr(ctxt)
  return rexpr [self.lhs:toRExpr(ctxt)] and [self.rhs:toRExpr(ctxt)] end
end
function M.AST.Or:toRExpr(ctxt)
  return rexpr [self.lhs:toRExpr(ctxt)] or [self.rhs:toRExpr(ctxt)] end
end
function M.AST.Not:toRExpr(ctxt)
  return rexpr not [self.cond:toRExpr(ctxt)] end
end
function M.AST.Compare:toRExpr(ctxt)
  local a = self.lhs:toRExpr(ctxt)
  local b = self.rhs:toRExpr(ctxt)
  return
    (self.op == '==') and rexpr a == b end or
    (self.op == '~=') and rexpr a ~= b end or
    (self.op == '>')  and rexpr a > b  end or
    (self.op == '<')  and rexpr a < b  end or
    (self.op == '>=') and rexpr a >= b end or
    (self.op == '<=') and rexpr a <= b end or
    assert(false)
end

-- ProgramContext -> RG.rexpr
function M.AST.Expr:toRExpr(ctxt)
  error('Abstract method')
end
function M.AST.Const:toRExpr(ctxt)
  return rexpr [toRConst(self.val)] end
end
function M.AST.GetGlobal:toRExpr(ctxt)
  return rexpr [assert(ctxt.globalMap[self.global])] end
end
function M.AST.BinaryOp:toRExpr(ctxt)
  local a = self.lhs:toRExpr(ctxt)
  local b = self.rhs:toRExpr(ctxt)
  return
    (self.op == '+') and rexpr a + b end or
    (self.op == '-') and rexpr a - b end or
    (self.op == '*') and rexpr a * b end or
    (self.op == '/') and rexpr a / b end or
    (self.op == '%') and rexpr a % b end or
    assert(false)
end
function M.AST.UnaryOp:toRExpr(ctxt)
  local a = self.arg:toRExpr(ctxt)
  return
    (self.op == '-') and rexpr -a end or
    assert(false)
end

function A.translateAndRun()
  local stmts = terralib.newlist()
  local ctxt = { -- ProgramContext
    globalMap  = {}, -- map(L.Global, RG.symbol)
    relMap     = {}, -- map(R.Relation, RG.symbol)
    subsetMap  = {}, -- map(R.Subset, RG.symbol)
  }
  -- Collect declarations
  local globalInits = {} -- map(L.Global, M.ExprConst)
  local rels = terralib.newlist() -- R.Relation*
  local subsetDefs = {} -- map(R.Subset, (int[1-3][2])*)
  for _,decl in ipairs(M.decls()) do
    if M.AST.NewField.check(decl) then
      -- Do nothing
    elseif M.AST.NewFunction.check(decl) then
      -- Do nothing
    elseif M.AST.NewGlobal.check(decl) then
      globalInits[decl.global] = decl.init
    elseif M.AST.NewRelation.check(decl) then
      rels:insert(decl.rel)
    elseif M.AST.NewSubset.check(decl) then
      subsetDefs[decl.subset] = decl.rectangles
    else assert(false) end
  end
  -- Emit global declarations
  for g,val in pairs(globalInits) do
    local typ = toRType(g:Type())
    local x = RG.newsymbol(typ)
    ctxt.globalMap[g] = x
    stmts:insert(rquote var [x] = [toRConst(val, typ)] end)
  end
  -- Emit region declarations
  for _,rel in ipairs(rels) do
    local rg = RG.newsymbol(rel:Name())
    ctxt.relMap[rel] = rg
    stmts:insert(rquote
      var [rg] = [rel:mkRegionInit()]
    end)
  end
  -- Emit subset declarations
  for subset,rects in pairs(subsetDefs) do
    local rel = subset:Relation()
    if #rects > 1 then
      print('WARNING: Skipping multi-rect subset '..subset:FullName())
    else
      local rg = ctxt.relMap[rel]
      local subrg = RG.newsymbol(rel:Name()..'_'..subset:Name())
      ctxt.subsetMap[subset] = subrg
      local rect = rects[1]
      local rectExpr =
        (#rect == 1) and rexpr
          rect1d{ lo = [rect[1][1]], hi = [rect[1][2]] }
        end or
        (#rect == 2) and rexpr
          rect2d{
            lo = int2d{ x = [rect[1][1]], y = [rect[2][1]] },
            hi = int2d{ x = [rect[1][2]], y = [rect[2][2]] }}
        end or
        (#rect == 3) and rexpr
          rect3d{
            lo = int3d{ x = [rect[1][1]], y = [rect[2][1]], z = [rect[3][1]] },
            hi = int3d{ x = [rect[1][2]], y = [rect[2][2]], z = [rect[3][2]] }}
        end or
        assert(false)
      stmts:insert(rquote
        var colors = ispace(int1d, 1)
        var coloring = RG.c.legion_domain_point_coloring_create()
        var rect = [rectExpr]
        RG.c.legion_domain_point_coloring_color_domain(coloring, int1d(0), rect)
        var [subrg] = partition(disjoint, rg, coloring, colors)
        RG.c.legion_domain_point_coloring_destroy(coloring)
      end)
    end
  end
  -- Process statements
  for _,s in ipairs(M.stmts()) do
    stmts:insert(s:toRQuote(ctxt))
  end
  -- Synthesize main task
  local task main()
    [stmts]
  end
  if DEBUG then main:printpretty() end
  RG.start(main)
end
