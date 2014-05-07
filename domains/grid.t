import "compiler.liszt"

local Grid = {}
package.loaded["domains.grid"] = Grid

local L = terralib.require "compiler.lisztlib"



local Grid2d = {}
local Grid3d = {}
Grid2d.__index = Grid2d
Grid3d.__index = Grid3d

local max = L.NewMacro(function(a,b)
    return liszt quote
        var ret = a
        if b > a then ret = b end
    in
        ret
    end
end)

-- There are N x M cells for an NxM grid
local function setupCells(grid)
    local xsize, ysize      = grid:xSize(), grid:ySize()
    local cell_width        = grid:cellWidth()
    local cell_height       = grid:cellHeight()
    local xorigin           = grid:xOrigin()
    local yorigin           = grid:yOrigin()
    local n_bd              = grid:boundaryDepth()

    -- relative offset
    grid.cells:NewFieldMacro('__apply_macro',
        L.NewMacro(function(c,xoff,yoff)
            return liszt `
                L.UNSAFE_ROW( L.id(c) + yoff * xsize + xoff,  grid.cells )
        end))

    -- Boundary/Interior subsets
    local function is_boundary(i)
        return
            math.floor(i/xsize) <  n_bd or
            math.floor(i/xsize) >= ysize-n_bd or
                        i%xsize <  n_bd or
                        i%xsize >= xsize-n_bd
    end
    grid.cells:NewSubsetFromFunction('boundary', is_boundary)
    grid.cells:NewSubsetFromFunction('interior', function(i)
        return not is_boundary(i)
    end)
    
    -- Should these be hidden?
    grid.cells:NewFieldMacro('xid', L.NewMacro(function(c)
        return liszt ` L.id(c) % L.addr(xsize)
    end))
    grid.cells:NewFieldMacro('yid', L.NewMacro(function(c)
        return liszt ` L.id(c) / L.addr(xsize)
    end))

    grid.cells:NewFieldMacro('center', L.NewMacro(function(c)
        return liszt ` L.vec2f({
            xorigin + cell_width  * (L.double(c.xid) + 0.5),
            yorigin + cell_height * (L.double(c.yid) + 0.5) })
    end))

    -- boundary depths
    grid.cells:NewFieldMacro('xneg_depth', L.NewMacro(function(c)
        return liszt `max(L.int(n_bd - c.xid), 0)
    end))
    grid.cells:NewFieldMacro('xpos_depth', L.NewMacro(function(c)
        return liszt `max(L.int(c.xid - (xsize-1 - n_bd)), 0)
    end))
    grid.cells:NewFieldMacro('yneg_depth', L.NewMacro(function(c)
        return liszt `max(L.int(n_bd - c.yid), 0)
    end))
    grid.cells:NewFieldMacro('ypos_depth', L.NewMacro(function(c)
        return liszt `max(L.int(c.yid - (ysize-1 - n_bd)), 0)
    end))

    grid.cells:NewFieldMacro('in_boundary', L.NewMacro(function(c)
        return liszt ` c.xneg_depth > 0 or c.xpos_depth > 0 or
                       c.yneg_depth > 0 or c.ypos_depth > 0
    end))
    grid.cells:NewFieldMacro('in_interior', L.NewMacro(function(c)
        return liszt ` not c.in_boundary
    end))
end

-- There are N x M cells for an NxM grid
local function setupDualCells(grid)
    local xsize, ysize      = grid:xSize()+1, grid:ySize()+1
    local cell_width        = grid:cellWidth()
    local cell_height       = grid:cellHeight()
    local xorigin           = grid:xOrigin()
    local yorigin           = grid:yOrigin()
    local n_bd              = grid:boundaryDepth()

    -- relative offset
    grid.dual_cells:NewFieldMacro('__apply_macro',
        L.NewMacro(function(dc,xoff,yoff)
            return liszt `
                L.UNSAFE_ROW( L.id(dc) + yoff * xsize + xoff,
                              grid.dual_cells )
        end))

    -- Should these be hidden?
    grid.dual_cells:NewFieldMacro('xid', L.NewMacro(function(dc)
        return liszt ` L.id(dc) % L.addr(xsize)
    end))
    grid.dual_cells:NewFieldMacro('yid', L.NewMacro(function(dc)
        return liszt ` L.id(dc) / L.addr(xsize)
    end))
    grid.dual_cells:NewFieldMacro('center', L.NewMacro(function(dc)
        return liszt `L.vec2f({
            xorigin +  cell_width * (L.double(dc.xid)),
            yorigin + cell_height * (L.double(dc.yid))
        })
    end))

    grid.dual_locate = L.NewMacro(function(xy_vec)
        return liszt quote
            var xy = xy_vec -- prevent duplication
            var xidx = L.addr((xy[0] - xorigin)/cell_width + 0.5)
            var yidx = L.addr((xy[1] - yorigin)/cell_height + 0.5)
        in
            L.UNSAFE_ROW(xidx + yidx * xsize, grid.dual_cells)
        end
    end)
end

-- There are N x M cells for an NxM grid
local function setupVertices(grid)
    local xsize, ysize      = grid:xSize()+1, grid:ySize()+1
    local cell_width        = grid:cellWidth()
    local cell_height       = grid:cellHeight()
    local xorigin           = grid:xOrigin()
    local yorigin           = grid:yOrigin()
    local n_bd              = grid:boundaryDepth()

    -- relative offset
    grid.vertices:NewFieldMacro('__apply_macro',
        L.NewMacro(function(v,xoff,yoff)
            return liszt `
                L.UNSAFE_ROW( L.id(v) + yoff * xsize + xoff,  grid.vertices )
        end))

    -- Should these be hidden?
    grid.vertices:NewFieldMacro('xid', L.NewMacro(function(v)
        return liszt ` L.id(v) % L.addr(xsize)
    end))
    grid.vertices:NewFieldMacro('yid', L.NewMacro(function(v)
        return liszt ` L.id(v) / L.addr(xsize)
    end))
end

local function setupInterconnects(grid)
    local cxsize, cysize    = grid:xSize(), grid:ySize()
    local vxsize, vysize    = cxsize + 1, cysize + 1

    grid.dual_cells:NewFieldMacro('vertex', L.NewMacro(function(dc)
        return liszt ` L.UNSAFE_ROW( L.id(dc), grid.vertices )
    end))
    grid.vertices:NewFieldMacro('dual_cell', L.NewMacro(function(v)
        return liszt ` L.UNSAFE_ROW( L.id(v), grid.dual_cells )
    end))

    grid.cells:NewFieldMacro('vertex', L.NewMacro(function(c)
        return liszt `
            L.UNSAFE_ROW( c.xid + c.yid * vxsize, grid.vertices )
    end))
    grid.vertices:NewFieldMacro('cell', L.NewMacro(function(v)
        return liszt `
            L.UNSAFE_ROW( v.xid + v.yid * cxsize, grid.cells )
    end))
end

function Grid.NewGrid2d(params)
    local calling_convention = [[

New2dUniformGrid should be called with named parameters:
Grid.New2dUniformGrid{
  size          = {#,#},    -- number of cells in x and y
  origin        = {#,#},    -- x,y coordinates of grid origin
  width         = #,        -- width of grid coordinate system
  height        = #,        -- height of grid coordinate system
  (optional)
  boundary_depth = #,       -- depth of boundary region (default value: 1)
}]]
    local function is_num(obj) return type(obj) == 'number' end
    local function check_params(params)
        local check =
            type(params) == 'table' and
            type(params.size) == 'table' and
            type(params.origin) == 'table' and
            is_num(params.size[1]) and is_num(params.size[2]) and
            is_num(params.origin[1]) and is_num(params.origin[2]) and
            is_num(params.width) and is_num(params.height)
        if check and params.boundary_depth then
            check = check and is_num(params.boundary_depth)
        end
        return check
    end
    if not check_params(params) then error(calling_convention, 2) end

    -- default
    params.boundary_depth = params.boundary_depth or 1

    local nCells        = params.size[1] * params.size[2]
    local nDualCells    = (params.size[1]+1) * (params.size[2]+1)
    local nVerts        = nDualCells

    local grid = setmetatable({
        _n_xy       = params.size,
        _origin     = params.origin,
        _dims       = {params.width, params.height},
        _bd_depth   = params.boundary_depth,
        -- relations
        cells       = L.NewRelation(nCells, 'cells'),
        dual_cells  = L.NewRelation(nDualCells, 'dual_cells'),
        vertices    = L.NewRelation(nVerts, 'vertices'),
    }, Grid2d)

    setupCells(grid)
    setupDualCells(grid)
    setupVertices(grid)
    setupInterconnects(grid)

    return grid
end


function Grid2d:xSize()
    return self._n_xy[1]
end

function Grid2d:ySize()
    return self._n_xy[2]
end

function Grid2d:xOrigin()
    return self._origin[1]
end

function Grid2d:yOrigin()
    return self._origin[2]
end

function Grid2d:width()
    return self._dims[1]
end

function Grid2d:height()
    return self._dims[2]
end

function Grid2d:cellWidth()
    return self:width() / (1.0 * self:xSize())
end

function Grid2d:cellHeight()
    return self:height() / (1.0 * self:ySize())
end

function Grid2d:boundaryDepth()
    return self._bd_depth
end





