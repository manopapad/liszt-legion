import "compiler.liszt"
require "tests.test"

local LMesh = terralib.require "compiler.lmesh"
mesh = LMesh.Load("examples/mesh.lmesh")

local vk = liszt_kernel(v : mesh.vertices)
    var x = {1, 2, 3} ^ 4
end
test.fail_kernel(vk, mesh.vertices, "invalid types")

local vk2 = liszt_kernel(v : mesh.vertices)
    var x = {1, 2, 3} ^ {4, 5, 6}
end
test.fail_kernel(vk2, mesh.vertices, "invalid types")

local vk3 = liszt_kernel(v : mesh.vertices)
    var x = 5 < true
end
test.fail_kernel(vk3, mesh.vertices, "invalid types")

local t = {}
local r = {}
local vk4 = liszt_kernel(v : mesh.vertices)
    var x = r < t
end
test.fail_kernel(vk4, mesh.vertices, "invalid types")