--[[ Copyright (c) 2009 Peter "Corsix" Cawley

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE. --]]

local TH = require"TH"
local ipairs, _G, table_remove
    = ipairs, _G, table.remove

dofile "entity"
dofile "room"
dofile "object"
dofile "humanoid"
dofile "patient"
dofile "staff_profile"

class "World"

function World:World(app)
  self.map = app.map
  self.wall_types = app.walls
  self.object_types = app.objects
  self.anims = app.anims
  self.anim_length_cache = {}
  self.pathfinder = TH.pathfinder()
  self.pathfinder:setMap(app.map.th)
  self.entities = {}
  self.objects = {}
  self.objects_notify_occupants = {}
  self.rooms = {}
  self.ticks_per_tick = 1
  self.tick_rate = 3
  self.tick_timer = 0
  self.month = 1 -- January
  self.day = 1
  self.hour = 0
  self.idle_cache = {}
  
  self.wall_id_by_block_id = {}
  for _, wall_type in ipairs(self.wall_types) do
    for _, set in ipairs{"inside_tiles", "outside_tiles", "window_tiles"} do
      for name, id in pairs(wall_type[set]) do
        self.wall_id_by_block_id[id] = wall_type.id
      end
    end
  end
  self.object_id_by_thob = {}
  for _, object_type in ipairs(self.object_types) do
    self.object_id_by_thob[object_type.thob] = object_type.id
  end
  self:makeAvailableStaff()
end

function World:makeAvailableStaff()
  self.available_staff = {}
  for _, class in ipairs{"Doctor", "Nurse", "Handyman", "Receptionist"} do
    local group = {}
    for i = 1, math.random(3, 12) do
      group[i] = StaffProfile(class)
      group[i]:randomise()
    end
    self.available_staff[class] = group
  end
end

function World:notifyObjectOfOccupants(x, y, object)
  local idx = (y - 1) * self.map.width + x
  self.objects_notify_occupants[idx] =  object or nil
end

function World:getObjectToNotifyOfOccupants(x, y)
  local idx = (y - 1) * self.map.width + x
  return self.objects_notify_occupants[idx]
end

function World:createMapObjects(objects)
  for _, object in ipairs(objects) do repeat
    local x, y, thob, flags = unpack(object)
    local object_id = self.object_id_by_thob[thob]
    if not object_id then
      print("Warning: Map contained object with unrecognised THOB (" .. thob .. ") at " .. x .. "," .. y)
      break -- continue
    end
    local object_type = self.object_types[object_id]
    if not object_type or not object_type.supports_creation_for_map then
      print("Warning: Unable to create map object " .. object_id .. " at " .. x .. "," .. y)
      break -- continue
    end
    self:newObject(object_id, x, y, flags, "map object")
  until true end
end

function World:getAnimLength(anim)
  if not self.anim_length_cache[anim] then
    local length = 0
    local seen = {}
    local frame = self.anims:getFirstFrame(anim)
    while not seen[frame] do
      seen[frame] = true
      length = length + 1
      frame = self.anims:getNextFrame(frame)
    end
    self.anim_length_cache[anim] = length
  end
  return self.anim_length_cache[anim]
end

function World:newRoom(x, y, w, h, room_info)
  local id = #self.rooms + 1
  -- Note: Room IDs will be unique, but they may not form continuous values
  -- from 1, as IDs of deleted rooms may not be re-issued for a while
  local class = room_info.class and _G[room_info.class] or Room
  local room = class(x, y, w, h, id, room_info, self)
  
  self.rooms[id] = room
  self:clearCaches()
  return room
end

function World:clearCaches()
  self.idle_cache = {}
end

function World:getWallIdFromBlockId(block_id)
  return self.wall_id_by_block_id[block_id]
end

local month_length = {
  31, -- Jan
  28, -- Feb (29 in leap years, but TH doesn't have leap years)
  31, -- Mar
  30, -- Apr
  31, -- May
  30, -- Jun
  31, -- Jul
  31, -- Aug
  30, -- Sep
  31, -- Oct
  30, -- Nov
  31, -- Dec
}

function World:getDate()
  return self.month, self.day
end

function World:setTickRate(numerator, denominator)
  self.ticks_per_tick = numerator
  self.tick_rate = denominator
end

function World:onTick()
  if self.tick_timer == 0 then
    self.tick_timer = self.tick_rate
    self.hour = self.hour + self.ticks_per_tick
    -- There doesn't need to be 24 hours in a day. Whatever value gives the
    -- best ingame speed can be used, but 24 works OK and is a good starting
    -- point. Vanilla TH appears to take ~3 seconds per day at normal speed.
    -- With ~33 ticks/sec, reduced to 11 /sec at normal speed, 3 seconds -> 33
    -- ticks, which is 1 day and 9 hours.
    if self.hour >= 24 then
      self.hour = self.hour - 24
      self.day = self.day + 1
      if self.day > month_length[self.month] then
        self:onEndMonth()
        self.day = 1
        self.month = self.month + 1
        if self.month > 12 then
          self:onEndYear()
          self.month = 1
        end
      end
    end
    for i = 1, self.ticks_per_tick do
      for _, entity in ipairs(self.entities) do
        if entity.ticks then
          entity:tick()
        end
      end
      self.map:onTick()
      if self.ui then
        self.ui:onWorldTick()
      end
    end
  end
  self.tick_timer = self.tick_timer - 1
end

function World:onEndMonth()
  self:makeAvailableStaff()
end

function World:onEndYear()
end

function World:getPathDistance(x1, y1, x2, y2)
  return self.pathfinder:findDistance(x1, y1, x2, y2)
end

function World:getPath(x, y, dest_x, dest_y)
  return self.pathfinder:findPath(x, y, dest_x, dest_y)
end

function World:getIdleTile(x, y, idx)
  local cache_idx = (y - 1) * self.map.width + x
  local cache = self.idle_cache[cache_idx]
  if not cache then
    cache = {
      x = {},
      y = {},
    }
    self.idle_cache[cache_idx] = cache
  end
  if not cache.x[idx] then
    local ix, iy = self.pathfinder:findIdleTile(x, y, idx)
    if not ix then
      return ix, iy
    end
    cache.x[idx] = ix
    cache.y[idx] = iy
  end
  return cache.x[idx], cache.y[idx]
end

local face_dir = {
  [0] = "south",
  [1] = "west",
  [2] = "north",
  [3] = "east",
}

function World:getFreeBench(x, y, distance)
  local bench, rx, ry
  local object_type = self.object_types.bench
  self.pathfinder:findObject(x, y, object_type.thob, distance, function(x, y, d)
    local b = self:getObject(x, y, "bench")
    if b and not b.user and not b.reserved_for then
      local orientation = object_type.orientations[b.direction]
      if orientation.pathfind_allowed_dirs[d] then
        rx = x + orientation.use_position[1]
        ry = y + orientation.use_position[2]
        bench = b
        return true
      end
    end
  end)
  return bench, rx, ry
end

function World:findObjectNear(humanoid, object_type_name, distance, callback)
  if not distance then
    -- Note that regardless of distance, only the room which the humanoid is in
    -- is searched (or the corridor if the humanoid is not in a room).
    distance = 2^30
  end
  local obj, ox, oy
  if not callback then
    -- The default callback returns the first object found, along with its
    -- usage tile position. Note that this may return an object already being
    -- used - if you want to find an object not in use (in order to use it),
    -- then call findFreeObjectNearToUse instead.
    callback = function(x, y, d)
      obj = self:getObject(x, y, object_type_name)
      local orientation = obj.object_type.orientations
      if orientation then
        orientation = orientation[obj.direction]
        if not orientation.pathfind_allowed_dirs[d] then
          return
        end
        x = x + orientation.use_position[1]
        y = y + orientation.use_position[2]
      end
      ox = x
      oy = y
      return true
    end
  end
  self.pathfinder:findObject(humanoid.tile_x, humanoid.tile_y,
    self.object_types[object_type_name].thob, distance, callback)
  -- These return values are only relevent for the default callback - are nil
  -- for custom callbacks
  return obj, ox, oy
end

function World:findFreeObjectNearToUse(humanoid, object_type_name, distance, which, current_object)
  -- If which == nil or false, then the nearest object is taken.
  -- If which == "far", then the furthest object is taken.
  -- If which == "near", then the nearest object is taken with 50% probabilty, the second nearest with 25%, and so on
  -- Other values for which may be added in the future.
  -- Specify current_object if you want to exclude the currently used object from the search
  local object, ox, oy
  self:findObjectNear(humanoid, object_type_name, nil, function(x, y, d)
    local obj = self:getObject(x, y, object_type_name)
    if obj.user or (obj.reserved_for and obj.reserved_for ~= humanoid) or (current_object and obj == current_object) then
      return
    end
    local orientation = obj.object_type.orientations
    if orientation then
      orientation = orientation[obj.direction]
      if not orientation.pathfind_allowed_dirs[d] then
        return
      end
      x = x + orientation.use_position[1]
      y = y + orientation.use_position[2]
    end
    object = obj
    ox = x
    oy = y
    if which == "far" then
      -- just take the last found object, so don't ever abort
    elseif which == "near" then
      -- abort at each item with 50% probability
      local chance = math.random(1, 2)
      if chance == 1 then
        return true
      end
    else
      -- default: return at the first found item
      return true
    end
  end)
  return object, ox, oy
end

function World:findRoomNear(humanoid, roomclass, distance)
  local room
  if not distance then
    distance = 2^30
  end
  for _, r in ipairs(self.rooms) do
    if not roomclass or class.is(r, roomclass) then
      local x, y = r:getEntranceXY(false)
      local d = self:getPathDistance(humanoid.tile_x, humanoid.tile_y, x, y)
      if d and d < distance then
        distance = d
        room = r
      end
    end
  end
  return room
end

function World:newEntity(class, animation)
  local th = TH.animation()
  th:setAnimation(self.anims, animation)
  local entity = _G[class](th)
  self.entities[#self.entities + 1] = entity
  entity.world = self
  return entity
end

function World:newObject(id, ...)
  local object_type = self.object_types[id]
  local entity
  if object_type.class then
    entity = _G[object_type.class](self, object_type, ...)
  else
    entity = Object(self, object_type, ...)
  end
  self.entities[#self.entities + 1] = entity
  return entity
end

function World:removeObjectFromTile(object, x, y)
  local index = (y - 1) * self.map.width + x
  local objects = self.objects[index]
  if objects then
    for k, v in ipairs(objects) do
      if v == object then
        table_remove(objects, k)
        if k == 1 then
          if objects[1] then
            self.map.th:setCellFlags(x, y, {thob = objects[1].object_type.thob})
          else
            self.map.th:setCellFlags(x, y, {thob = 0})
          end
        end
        return true
      end
    end
  end
  return false
end

function World:addObjectToTile(object, x, y)
  local index = (y - 1) * self.map.width + x
  local objects = self.objects[index]
  if objects then
    if #objects >= 1 then
      -- Until it is clear how multiple objects will work, this warning should
      -- be in place. In most cases, having multiple objects on a tile should
      -- be impossible, but there are some edge cases like having two radiators
      -- or bins on a tile which need thinking about.
      print("Warning: Multiple objects on tile " .. x .. "," .. y .. " - only one will be encoded")
    else
      self.map.th:setCellFlags(x, y, {thob = object.object_type.thob})
    end
    objects[#objects + 1] = object
  else
    objects = {object}
    self.objects[index] = objects
    self.map.th:setCellFlags(x, y, {thob = object.object_type.thob})
  end
  return true
end

function World:getObject(x, y, id)
  local index = (y - 1) * self.map.width + x
  local objects = self.objects[index]
  if objects then
    if not id then
      return objects[1]
    else
      for _, obj in ipairs(objects) do
        if obj.object_type.id == id then
          return obj
        end
      end
    end
  end
  return -- nil
end

function World:getRoom(x, y)
  return self.rooms[self.map:getRoomId(x, y)]
end
