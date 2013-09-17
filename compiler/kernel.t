module(... or 'kernel', package.seeall)

local semant = require "semant"
terralib.require "include/liszt"
terralib.require "compiler/codegen"
terralib.require "runtime/liszt"

Kernel = { }
Kernel.__index = Kernel

function Kernel.isKernel (obj)
	return getmetatable(obj) == Kernel
end

function Kernel.new (kernel_ast, env)
	return setmetatable({ast=kernel_ast,env=env}, Kernel)
end

function Kernel:acceptsType (param_type)
	return true
end

function Kernel:generate (param_type)
	semant.check(self.env, self.ast)
	if not self.__kernel then
		self.__kernel = codegen.codegen(self.env, self.ast)
	end
	return self.__kernel
end