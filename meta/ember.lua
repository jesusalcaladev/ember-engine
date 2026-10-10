--- Ember engine Lua API — GENERATED from metadata.zig, do not edit by hand.
--- Regenerate with `zig build stubs` (CI fails if this drifts).

---@meta

-- ── actor ──
---World-space position of this actor as x, y.
---@param self Actor 
---@return number x in world units (pixels unless the game scales them)
---@return number y in world units
function Actor:get_position() end

---Sets the world-space position of this actor.
---@param self Actor 
---@param x number 
---@param y number 
function Actor:set_position(x, y) end

---Moves the actor by a delta, relative to its current position.
---@param self Actor 
---@param dx number 
---@param dy number 
function Actor:translate(dx, dy) end

---Read-modify-write move: adds a delta to the actor's position in ONE call.
---@param self Actor 
---@param dx number 
---@param dy number 
function Actor:move_by(dx, dy) end

---Rotation of this actor in radians (clockwise on screen).
---@param self Actor 
---@return number angle in radians
function Actor:get_rotation() end

---Sets the rotation of this actor, in radians.
---@param self Actor 
---@param radians number angle in radians (positive = clockwise on screen)
function Actor:set_rotation(radians) end

---The Name component of this actor, or an empty string when it has none.
---@param self Actor 
---@return string the actor's name, or empty string
function Actor:get_name() end

---Queues a signal on this actor; listeners run on the next drain, in stable spawn order.
---@param self Actor 
---@param event string signal name, matched by listeners on the same name
function Actor:emit(event) end

---Half the sprite's extent: the half-width and half-height of what is drawn.
---@param self Actor 
---@return number half width (0 if no Sprite component)
---@return number half height (0 if no Sprite component)
function Actor:get_half_size() end

---Distance between this actor and another, in world units (pixels by default).
---@param self Actor 
---@param other Actor any other behavior's self table
---@return number distance in world units
function Actor:distance_to(other) end

---Distance from this actor to a bare point (a click, a marker, a waypoint).
---@param self Actor 
---@param x number 
---@param y number 
---@return number distance in world units
function Actor:distance_to_point(x, y) end

---Squared distance: the comparison form, with no square root.
---@param self Actor 
---@param other Actor 
---@return number distance squared; compare against radius*radius
function Actor:distance_squared_to(other) end

---True when the other actor is within `radius` world units of this one.
---@param self Actor 
---@param other Actor 
---@param radius number 
---@return boolean true if within radius, false otherwise
function Actor:is_within_radius(other, radius) end

---True when a bare point is within `radius` of this actor.
---@param self Actor 
---@param x number 
---@param y number 
---@param radius number 
---@return boolean true if point is within radius
function Actor:is_within_radius_of_point(x, y, radius) end

---Unit vector pointing from this actor to the other.
---@param self Actor 
---@param other Actor 
---@return number dx in [-1, 1]; 0 when actors coincide
---@return number dy in [-1, 1]; 0 when actors coincide
function Actor:direction_to(other) end

---Angle from this actor to the other, relative to +X; positive is clockwise.
---@param self Actor 
---@param other Actor 
---@return number angle in radians
function Actor:angle_to(other) end

---Adds a component by name. False if it was already there or the name is unknown.
---@param self Actor 
---@param name string Sprite, CollisionLayers, Name, RigidBody2D, Collider2D
---@return boolean true when it was added
function Actor:add_component(name) end

---Whether an actor carries a component.
---@param self Actor 
---@param name string the component name
---@return boolean true when present
function Actor:has_component(name) end

---Removes a component. Refuses on Transform, which everything else assumes exists.
---@param self Actor 
---@param name string the component name
---@return boolean true when removed
function Actor:remove_component(name) end

---Sets the velocity outright. Leaves the angular velocity alone.
---@param self Actor 
---@param vx number velocity x in units/second
---@param vy number velocity y in units/second
function Actor:set_linear_velocity(vx, vy) end

---The velocity the solver has for this actor, as `vx, vy`.
---@param self Actor 
---@return number velocity x in units/second
---@return number velocity y in units/second
function Actor:get_linear_velocity() end

---An instantaneous push at the centre of mass. Wakes a sleeping actor.
---@param self Actor 
---@param ix number impulse x (mass * units/second)
---@param iy number impulse y (mass * units/second)
function Actor:apply_impulse(ix, iy) end

---False once the body has stopped moving and the solver may put it to sleep.
---@param self Actor 
---@return boolean true while the body is still moving
function Actor:is_awake() end


-- ── physics ──
---Engine counters: broadphase health, what the solver is thinking about, what the activity system decided.
---@return table with pairs, pairs_per_body, tree_height, static_tree_height, solver_bytes, bodies, shapes, contacts, islands, sleeping, simulated, active_fraction, transitions
function physics.stats() end

---Tells the engine what the camera can see. Enabling this turns on physics view culling.
---@param cx number view centre x in world units
---@param cy number view centre y in world units
---@param half_w number half the view width, plus a margin
---@param half_h number half the view height, plus a margin
---@param enabled boolean false to fall back to distance tiers alone
function physics.set_view(cx, cy, half_w, half_h, enabled) end

---Where the player is. Bodies are tiered by their distance to this point.
---@param x number player x in world units
---@param y number player y in world units
function physics.set_focus(x, y) end

---Gives an actor a solid shape, creating the solver body if it has none.
---@param self Actor 
---@param kind integer 0 box, 1 circle, 2 capsule, 3 cylinder, 4 polygon
---@param half_w number half width in world units
---@param half_h number half height in world units
function Actor:create_shape(kind, half_w, half_h) end

---Replaces an actor's shape in place. Safe to call every frame while dragging a handle.
---@param self Actor 
---@param kind integer 0 box, 1 circle, 2 capsule, 3 cylinder, 4 polygon
---@param half_w number half width in world units
---@param half_h number half height in world units
function Actor:reshape(kind, half_w, half_h) end

---Sets an actor's surface material.
---@param self Actor 
---@param friction number 0 slippery to 1 grippy
---@param restitution number 0 no bounce to 1 full bounce
---@param density number mass per area
function Actor:set_material(friction, restitution, density) end

---Turns a shape into a trigger volume: reports overlaps, generates no contact response.
---@param self Actor 
---@param is_sensor boolean true for a trigger
function Actor:set_sensor(is_sensor) end

---Assigns collision layers as bitmasks. Two shapes interact only if each is on a layer the other's mask has.
---@param self Actor 
---@param layer_mask integer which layers this actor is on
---@param collide_mask integer which layers it is willing to interact with
function Actor:set_layers(layer_mask, collide_mask) end

---Changes how an actor is simulated: 0 fixed, 1 kinematic, 2 dynamic.
---@param self Actor 
---@param kind integer 0 fixed, 1 kinematic, 2 dynamic
function Actor:set_body_type(kind) end

---Turns collision on or off without destroying the shape. The editor's eye toggle.
---@param self Actor 
---@param enabled boolean false to make it intangible
function Actor:set_body_enabled(enabled) end

---Every actor overlapping a box. The selection query. Approximate: a shape is found when a ray crosses it.
---@param cx number box centre x
---@param cy number box centre y
---@param half_w number half the box width
---@param half_h number half the box height
---@return integer how many actors were found
---@return Actor each one, as varargs
function physics.overlap_rect(cx, cy, half_w, half_h) end

---The actor under a point, for click-to-select.
---@param x number point x in world units
---@param y number point y in world units
---@return Actor the actor found, or nil
function physics.contains_point(x, y) end

---Casts a segment and reports what it hit: `hit, t, px, py, nx, ny`.
---@param x1 number segment start x
---@param y1 number segment start y
---@param x2 number segment end x
---@param y2 number segment end y
---@return boolean false when nothing blocks the segment
---@return number how far along the segment the hit is, 0 at the start and 1 at the end
---@return number hit point x
---@return number hit point y
---@return number surface normal x (points away from the surface)
---@return number surface normal y
function physics.cast_ray(x1, y1, x2, y2) end

---True when nothing solid blocks the segment between the two points.
---@param x1 number segment start x
---@param y1 number segment start y
---@param x2 number segment end x
---@param y2 number segment end y
---@return boolean true when the target is visible
function physics.line_of_sight(x1, y1, x2, y2) end


-- ── render ──
---What the camera can see. Turning this on makes the renderer cull.
---@param x number camera centre x
---@param x number camera centre y
---@param half_w number half the view width
---@param half_h number half the view height
function render.set_view(x, x, half_w, half_h) end

---Last frame's counters: entities, instances, culled, hidden.
---@return integer entities visited
---@return integer instances drawn
---@return integer culled by the frustum
---@return integer hidden by the designer
function render.stats() end

---Marks an atlas page as present or evicted. Evicted pages are skipped at collection time.
---@param slot integer index into the texture table
---@param loaded boolean true when the page is resident
function render.set_resident(slot, loaded) end

---Marks every page resident. The default, and what a machine with no streaming wants.
function render.all_resident() end


-- ── sprite ──
---A filled rectangle, no texture needed. The first thing a prototype draws.
---@param self Actor 
---@param w number width
---@param h number height
---@param r number red 0..1
---@param g number green 0..1
---@param b number blue 0..1
---@param a number alpha 0..1
function Actor:rect(w, h, r, g, b, a) end

---A circle, no texture needed. One quad and one comparison in the shader.
---@param self Actor 
---@param diameter number width and height
---@param r number red 0..1
---@param g number green 0..1
---@param b number blue 0..1
---@param a number alpha 0..1
function Actor:circle(diameter, r, g, b, a) end

---The same shape, sampling a real atlas region. The 'now give it art' call.
---@param self Actor 
---@param w number width
---@param h number height
---@param atlas_slot integer index into the texture table
---@param u0 number atlas u0
---@param v0 number atlas v0
---@param u1 number atlas u1
---@param v1 number atlas v1
function Actor:texture(w, h, atlas_slot, u0, v0, u1, v1) end

---Draw order. Lower draws first; equal layers batch into one draw call.
---@param self Actor 
---@param layer integer 0 draws first
function Actor:set_layer(layer) end

---Draw nothing without despawning. The editor's eye toggle.
---@param self Actor 
---@param visible boolean false to stop drawing it
function Actor:set_visible(visible) end

---The sprite's size in world units.
---@param self Actor 
---@param w number width
---@param h number height
function Actor:set_size(w, h) end

---Colour, multiplied with the texel.
---@param self Actor 
---@param r number red 0..1
---@param g number green 0..1
---@param b number blue 0..1
---@param a number alpha 0..1
function Actor:set_tint(r, g, b, a) end

---The atlas region to sample.
---@param self Actor 
---@param u0 number left
---@param v0 number top
---@param u1 number right
---@param v1 number bottom
function Actor:set_uv(u0, v0, u1, v1) end

---Which texture in the table.
---@param self Actor 
---@param slot integer index into the texture table; 0 is the white texture
function Actor:set_atlas(slot) end

---How the quad is masked: 0 quad, 1 circle.
---@param self Actor 
---@param kind integer 0 quad, 1 circle
function Actor:set_shape(kind) end

---Blending mode: 0 solid, 1 alpha, 2 additive.
---@param self Actor 
---@param kind integer 0 solid, 1 alpha, 2 additive
function Actor:set_blend(kind) end

---The sprite's size. The inspector reads as well as writes.
---@param self Actor 
---@return number width
---@return number height
function Actor:get_size() end

---The sprite's tint.
---@param self Actor 
---@return number red
---@return number green
---@return number blue
---@return number alpha
function Actor:get_tint() end


-- ── material ──
---Attaches a shader material to an actor. Shader 0 is the stock sprite shader.
---@param self Actor 
---@param shader integer index into the shader table
function Actor:new(shader) end

---The material's four floats. Enough for a colour, a threshold, a time.
---@param self Actor 
---@param p0 number param 0
---@param p1 number param 1
---@param p2 number param 2
---@param p3 number param 3
function Actor:set_params(p0, p1, p2, p3) end

---The material's four floats. The inspector reads as well as writes.
---@param self Actor 
---@return number param 0
---@return number param 1
---@return number param 2
---@return number param 3
function Actor:get_params() end

---Which shader this material uses.
---@param self Actor 
---@return number shader index
function Actor:get_shader() end


-- ── light ──
---Adds a light to an actor. Position and direction come from its Transform.
---@param self Actor 
---@param kind integer 0 point, 1 spot, 2 directional
---@param radius number reach in world units
---@param r number red 0..1
---@param g number green 0..1
---@param b number blue 0..1
---@param energy number brightness multiplier
function Actor:new(kind, radius, r, g, b, energy) end

---0 point, 1 spot, 2 directional.
---@param self Actor 
---@param kind integer 0 point, 1 spot, 2 directional
function Actor:set_kind(kind) end

---The light's reach in world units. Clamped to at least 1: a zero radius is a divide-by-zero in every falloff.
---@param self Actor 
---@param radius number reach
function Actor:set_radius(radius) end

---Colour. Alpha is the light's opacity, so a light fades out by its alpha and not a separate field.
---@param self Actor 
---@param r number red
---@param g number green
---@param b number blue
---@param a number alpha
function Actor:set_color(r, g, b, a) end

---Brightness multiplier.
---@param self Actor 
---@param e number multiplier
function Actor:set_energy(e) end

---Direction for a spot, or the direction it travels for a directional light. Unused by a point light.
---@param self Actor 
---@param radians number angle
function Actor:set_angle(radians) end

---A spot's opening and its soft edge. The penumbra is the fraction of the cone given over to a fade: 0.2 means full strength to 80% and a fade over the last 20%.
---@param self Actor 
---@param degrees number full opening
---@param penumbra number 0..1 soft-edge fraction
function Actor:set_cone(degrees, penumbra) end

---0 add, 1 subtract, 2 mix. `mix` is the energy-conserving one: a white surface under it stays white.
---@param self Actor 
---@param kind integer 0 add, 1 subtract, 2 mix
function Actor:set_blend(kind) end

---Whether this light casts shadows, how the edge is filtered, and how wide the filter's taps are. Only four lights in a scene can get shadow channels, ranked by area.
---@param self Actor 
---@param enabled boolean cast shadows
---@param filter integer 0 off, 1 one tap, 2 three, 3 five
---@param smoothness number tap radius in mask texels
function Actor:set_shadow(enabled, filter, smoothness) end

---How much of the global-illumination enclosure term this light applies. Zero by default: a scene that did not ask for bounce should not have it.
---@param self Actor 
---@param contribution number 0..1
function Actor:set_gi(contribution) end

---Which sprite layers this light affects, as a bitmask of `Sprite.layer`. A light on layer 2 lights only layer 2, which is how a scene gets a lamp that does not brighten its own interface.
---@param self Actor 
---@param bitmask integer mask of layer bits
function Actor:set_mask(bitmask) end

---The inspector reads as well as writes, and its field list is generated from this same registry.
---@param self Actor 
---@return integer 0 point, 1 spot, 2 directional
function Actor:get_kind() end

---The inspector reads as well as writes, and its field list is generated from this same registry.
---@param self Actor 
---@return number reach
function Actor:get_radius() end

---The inspector reads as well as writes, and its field list is generated from this same registry.
---@param self Actor 
---@return number red
---@return number green
---@return number blue
---@return number alpha
function Actor:get_color() end

---The inspector reads as well as writes, and its field list is generated from this same registry.
---@param self Actor 
---@return number brightness multiplier
function Actor:get_energy() end

---The inspector reads as well as writes, and its field list is generated from this same registry.
---@param self Actor 
---@return number opening in degrees
---@return number penumbra 0..1
function Actor:get_cone() end

---The inspector reads as well as writes, and its field list is generated from this same registry.
---@param self Actor 
---@return boolean casts shadows
---@return integer filter
---@return number smoothness
function Actor:get_shadow() end


-- ── occluder ──
---Adds a light occluder to an actor.
---@param self Actor 
---@param mode integer 0 auto from the sprite's alpha, 1 manual polygon, 2 none
function Actor:new(mode) end

---0 derives the shape from the sprite's alpha at `set_threshold`, 1 uses the polygon, 2 blocks nothing. Mode 2 is how a sprite that looks like it occludes says it must not.
---@param self Actor 
---@param mode integer 0 auto, 1 manual, 2 none
function Actor:set_mode(mode) end

---The alpha at which the automatic shape decides a texel is solid. Raising it is the fix for most 'my sprite has a fringe of shadow' reports.
---@param self Actor 
---@param alpha number 0..1
function Actor:set_threshold(alpha) end

---Which lights this occluder blocks. 0 blocks everything, which is what a wall wants; a pane that blocks the sun but not the lamps sets it.
---@param self Actor 
---@param bitmask integer 0 for all lights
function Actor:set_mask(bitmask) end

---The manual shape, as a flat list of coordinates. Read from a table because eight positional arguments are unreadable and an editor dragging vertices produces a list anyway.
---@param self Actor 
---@param points table flat x/y pairs
function Actor:set_polygon(points) end

---The inspector reads as well as writes.
---@param self Actor 
---@return integer 0 auto, 1 manual, 2 none
function Actor:get_mode() end

---The automatic shape's alpha threshold.
---@param self Actor 
---@return number alpha 0..1
function Actor:get_threshold() end

---Which lights this occluder blocks.
---@param self Actor 
---@return integer the mask
function Actor:get_mask() end

---The manual shape as a flat list of coordinates. An editor that lets a user drag vertices reads this back to draw them.
---@param self Actor 
---@return table flat x/y pairs
function Actor:get_polygon() end


-- ── math ──
---Clamps `v` into the range `[lo, hi]`.
---@param v number value to clamp
---@param lo number minimum allowed value
---@param hi number maximum allowed value
---@return number `v` constrained to [lo, hi]
function math.clamp(v, lo, hi) end

---The smaller of two numbers.
---@param a number 
---@param b number 
---@return number the lesser of `a` and `b`
function math.min(a, b) end

---The larger of two numbers.
---@param a number 
---@param b number 
---@return number the greater of `a` and `b`
function math.max(a, b) end

---Absolute value: the distance from zero, always >= 0.
---@param v number any number; the sign is discarded
---@return number `v` without its sign
function math.abs(v) end

---The sign of `v`: -1, 0 or +1 (zero maps to 0, not +1).
---@param v number 
---@return number -1, 0 or +1
function math.sign(v) end

---Largest integer not greater than `v`.
---@param v number 
---@return integer the integral float floor of `v`
function math.floor(v) end

---Smallest integer not less than `v`.
---@param v number 
---@return integer the integral float ceil of `v`
function math.ceil(v) end

---Nearest integer, halves away from zero (not banker's rounding).
---@param v number any finite number
---@return integer nearest integral float; .5 rounds away from zero
function math.round(v) end

---Fractional part of `v`, always in [0, 1) regardless of sign.
---@param v number any number; the integer part is discarded
---@return number fractional part in [0, 1)
function math.fract(v) end

---Square root.
---@param v number non-negative value
---@return number the non-negative square root
function math.sqrt(v) end

---`base` raised to `exp`.
---@param base number the base
---@param exp number the exponent
---@return number base^exp
function math.pow(base, exp) end

---Sine of an angle in radians.
---@param radians number angle in radians
---@return number sine of the angle, in [-1, 1]
function math.sin(radians) end

---Cosine of an angle in radians.
---@param radians number angle in radians
---@return number cosine of the angle, in [-1, 1]
function math.cos(radians) end

---Two-argument arctangent: the angle of the point (x, y).
---@param y number y component
---@param x number x component
---@return number angle in radians, in (-pi, pi]
function math.atan2(y, x) end

---Linear blend: `a` at t=0, `b` at t=1.
---@param a number value at t=0
---@param b number value at t=1
---@param t number blend factor, usually 0..1
---@return number a*(1-t) + b*t
function math.lerp(a, b, t) end

---Where `v` falls between `a` and `b`, as 0..1 (can leave the range).
---@param a number start of the range
---@param b number end of the range
---@param v number value to locate within the range
---@return number 0 at a, 1 at b; may go outside 0..1
function math.inverse_lerp(a, b, v) end

---Maps `v` from one range to another.
---@param v number value to remap
---@param in_lo number input range minimum
---@param in_hi number input range maximum
---@param out_lo number output range minimum
---@param out_hi number output range maximum
---@return number `v` mapped to the output range
function math.remap(v, in_lo, in_hi, out_lo, out_hi) end

---Hermite ease: 0 below `edge0`, 1 above `edge1`, smooth between.
---@param edge0 number lower edge of the transition
---@param edge1 number upper edge of the transition
---@param v number value to evaluate
---@return number smooth 0..1 blend based on where `v` sits
function math.smoothstep(edge0, edge1, v) end

---Hard threshold: 0 below `edge`, 1 at or above it.
---@param edge number threshold value
---@param v number value to test
---@return number 0 if v < edge, 1 otherwise
function math.step(edge, v) end

---Moves `current` toward `target` by at most `max_delta` (never overshoots).
---@param current number starting value
---@param target number value to move toward
---@param max_delta number maximum step per frame
---@return number `current` moved toward `target`, clamped to max_delta
function math.move_toward(current, target, max_delta) end

---Frame-rate independent smoothing toward `b`; prefer it over a raw lerp.
---@param a number current value
---@param b number target value
---@param rate number time constant; larger is slower
---@param dt number delta time in seconds
---@return number smoothed value between `a` and `b`
function math.damp(a, b, rate, dt) end

---Wraps `v` into `[lo, hi)` (a modulo with a live floor).
---@param v number value to wrap
---@param lo number lower bound (inclusive)
---@param hi number upper bound (exclusive)
---@return number `v` wrapped into [lo, hi)
function math.wrap(v, lo, hi) end

---Triangle wave bouncing between 0 and `length` (period 2*length).
---@param v number time or phase value
---@param length number maximum value before bouncing back
---@return number triangle wave between 0 and length
function math.pingpong(v, length) end

---Degrees to radians.
---@param degrees number angle in degrees
---@return number the same angle in radians
function math.deg_to_rad(degrees) end

---Radians to degrees.
---@param radians number angle in radians
---@return number the same angle in degrees
function math.rad_to_deg(radians) end

---True when `a` and `b` differ by at most `tolerance`.
---@param a number first value
---@param b number second value
---@param tolerance number maximum acceptable difference
---@return boolean true when |a-b| <= tolerance
function math.is_close(a, b, tolerance) end


-- ── vec2 ──
---Builds a vector table. Allocates: use it for state, not inside a hot loop.
---@param x number? #0# 
---@param y number? #0# 
---@return Vec2 a table with `x` and `y` fields
function vec2.new(x, y) end

---The width-explicit constructor: identical to `vec2.new`, spelled for clarity.
---@param x number x component
---@param y number y component
---@return Vec2 a table with `x` and `y` fields
function vec2.to_vec(x, y) end

---Distance between two points. Accepts either four numbers or two Vec2 tables.
---@param ax number first point x (or a Vec2 table)
---@param ay number first point y (or a Vec2 table)
---@param bx number second point x (or a Vec2 table)
---@param by number second point y (or a Vec2 table)
---@return number distance
function vec2.dist(ax, ay, bx, by) end

---Squared distance: the comparison form, no square root.
---@param ax number first point x (or a Vec2 table)
---@param ay number first point y (or a Vec2 table)
---@param bx number second point x (or a Vec2 table)
---@param by number second point y (or a Vec2 table)
---@return number distance squared
function vec2.dist_sq(ax, ay, bx, by) end

---Length of a vector (also accepts `x, y` as two numbers).
---@param v Vec2 a Vec2 table or x, y as two numbers
---@return number length; 0 for the zero vector
function vec2.length(v) end

---Squared length: the comparison form, no square root.
---@param v Vec2 a Vec2 table
---@return number length squared
function vec2.length_sq(v) end

---The vector scaled to length 1; the zero vector maps to zero (never NaN).
---@param v Vec2 a Vec2 table
---@return Vec2 a unit vector (length 1); zero maps to zero
function vec2.normalized(v) end

---Unit vector pointing from one point to another.
---@param ax number origin point x
---@param ay number origin point y
---@param bx number target point x
---@param by number target point y
---@return Vec2 a unit vector; (0,0) when the points coincide
function vec2.direction(ax, ay, bx, by) end

---Blends two vectors: `a` at t=0, `b` at t=1.
---@param a Vec2 value at t=0
---@param b Vec2 value at t=1
---@param t number blend factor, usually 0..1
---@return Vec2 the blended vector
function vec2.lerp(a, b, t) end

---Dot product: how much two vectors point the same way.
---@param a Vec2 first vector
---@param b Vec2 second vector
---@return number the dot product
function vec2.dot(a, b) end

---2D cross product; the sign is the orientation test between the vectors.
---@param a Vec2 first vector
---@param b Vec2 second vector
---@return number the scalar cross (z of the 3D cross); positive when b is clockwise from a
function vec2.cross(a, b) end

---Angle of a vector in radians, relative to +X.
---@param v Vec2 a Vec2 table
---@return number angle in radians
function vec2.angle(v) end

---Signed angle from `a` to `b` in radians; positive is clockwise.
---@param a Vec2 first vector
---@param b Vec2 second vector
---@return number signed angle in (-pi, pi]
function vec2.angle_between(a, b) end

---Rotates a vector by an angle (positive is clockwise on screen).
---@param v Vec2 vector to rotate
---@param radians number rotation angle in radians (positive = clockwise)
---@return Vec2 the rotated vector
function vec2.rotate(v, radians) end

---The 90-degree rotation of a vector: a wall normal from a direction.
---@param v Vec2 a Vec2 table
---@return Vec2 the perpendicular vector (90° clockwise rotation)
function vec2.perpendicular(v) end

---Caps the LENGTH of a vector (direction preserved).
---@param v Vec2 vector to clamp
---@param max_len number maximum length
---@return Vec2 the capped vector
function vec2.clamp_length(v, max_len) end

---Godot's spelling of `clamp_length`; identical behaviour.
---@param v Vec2 vector to clamp
---@param max_len number maximum length
---@return Vec2 the capped vector
function vec2.clamped(v, max_len) end

---Bounce: mirrors an incoming direction around a unit normal.
---@param d Vec2 incoming direction
---@param n Vec2 unit normal of the surface
---@return Vec2 the reflected direction
function vec2.reflect(d, n) end

---Unit vector at an angle (Godot's `Vector2.from_angle`).
---@param radians number angle in radians
---@return Vec2 a unit vector pointing at the given angle
function vec2.from_angle(radians) end


-- ── rand ──
---Restarts the random sequence so the same seed replays the same draws.
---@param n integer seed value; any integer
function rand.seed(n) end

---A uniform float in `[lo, hi)`.
---@param lo number inclusive lower bound
---@param hi number exclusive upper bound
---@return number a random number in [lo, hi)
function rand.float(lo, hi) end

---The Godot/Unity spelling of `rand.float`; identical behaviour.
---@param lo number inclusive lower bound
---@param hi number exclusive upper bound
---@return number a random number in [lo, hi)
function rand.range(lo, hi) end

---A uniform integer in `[lo, hi]`, both ends inclusive.
---@param lo integer inclusive lower bound
---@param hi integer inclusive upper bound
---@return integer a random integer in [lo, hi]
function rand.int(lo, hi) end

---True with probability `p`. `p <= 0` never fires, `p >= 1` always does.
---@param p number probability, 0..1
---@return boolean true about p of the time
function rand.chance(p) end

---Returns -1 or +1 with equal probability.
---@return number -1 or +1
function rand.sign() end

---A normal-distributed sample; most values land near `mu`.
---@param mu number mean (centre of the bell)
---@param sigma number standard deviation (spread)
---@return number a sample from N(mu, sigma^2)
function rand.gauss(mu, sigma) end

---Picks one element of an array table at random; nil when it is empty.
---@param table any array-like Lua table
---@return any one element of the table, or nil if empty
function rand.choice(table) end

---Shuffles an array table in place (Fisher-Yates) and returns it.
---@param table any array-like Lua table
---@return any the same table, shuffled
function rand.shuffle(table) end


-- ── noise ──
---Sets the default seed every later `noise.*` call uses.
---@param n integer seed value
function noise.seed(n) end

---2D value noise in [-1, 1]. Cheap; shows a faint grid when sampled far apart.
---@param x number sample x
---@param y number sample y
---@return number noise sample in [-1, 1]
function noise.value(x, y) end

---2D Perlin gradient noise in [-1, 1]. The smooth default for terrain.
---@param x number sample x
---@param y number sample y
---@return number noise sample in [-1, 1]
function noise.perlin(x, y) end

---2D simplex noise in [-1, 1]. No axis bias, so it stays even along circles.
---@param x number sample x
---@param y number sample y
---@return number noise sample in [-1, 1]
function noise.simplex(x, y) end

---Fractal Brownian motion: several octaves of a base noise, each finer and weaker.
---@param x number sample x
---@param y number sample y
---@param octaves integer? #4# how many layers; clamped to 12
---@param basis string? #"perlin"# "value", "perlin" or "simplex"
---@return number combined noise in [-1, 1]
function noise.fbm(x, y, octaves, basis) end

---Ridged multifractal in [0, 1]: sharp crests where the noise crosses zero.
---@param x number sample x
---@param y number sample y
---@param octaves integer? #4# how many layers; clamped to 12
---@param basis string? #"perlin"# "value", "perlin" or "simplex"
---@return number ridge height in [0, 1]
function noise.ridged(x, y, octaves, basis) end


-- ── sm ──
---Declares a state with optional `enter`/`update`/`exit` callbacks.
---@param self Actor 
---@param name string state name, unique within the machine
---@param hooks any? #{}# table with optional enter/update/exit functions
---@return boolean true when the state was declared
function Actor:add_state(name, hooks) end

---Moves from one state to another when an event is fired.
---@param self Actor 
---@param from string state the transition starts in
---@param event string event name that triggers it
---@param to string state to enter
function Actor:add_transition(from, event, to) end

---Sets the state entered when the machine starts.
---@param self Actor 
---@param name string state to start in
function Actor:set_initial(name) end

---Requests a transition; applied before the next update.
---@param self Actor 
---@param event string event name
function Actor:fire(event) end

---Jumps to a state immediately, running exit then enter.
---@param self Actor 
---@param name string state to enter now
function Actor:set_state(name) end

---The active state's name; empty before the first update.
---@param self Actor 
---@return string the current state name
function Actor:state() end

---True when the machine is currently in that state.
---@param self Actor 
---@param name string state name to test
---@return boolean true when the active state is `name`
function Actor:is_in(name) end


-- ── world ──
---Calls `fn(other_self)` for every actor within `radius`, excluding the caller.
---@param self Actor 
---@param x number centre x in world units
---@param y number centre y in world units
---@param radius number search radius in world units
---@param fn any visitor called as fn(other_self)
function Actor:nearby(x, y, radius, fn) end


-- ── input ──
---True on the frame an action went down.
---@param name string input action name (e.g. "jump")
---@return boolean true on the frame the action was pressed
function input.is_action_pressed(name) end

---True while an action is held.
---@param name string input action name (e.g. "move_right")
---@return boolean true while the action is held
function input.is_action_down(name) end

---Axis value in [-1, 1] from two opposing actions.
---@param negative string action for the negative direction (e.g. "move_left")
---@param positive string action for the positive direction (e.g. "move_right")
---@return number -1, 0 or +1 (fractional once more devices are mapped)
function input.get_axis(negative, positive) end


-- ── log ──
---Logs an informational line. Strings are concatenated with `..`.
---@param message string message to log
function log.info(message) end

---Logs a warning line.
---@param message string warning message
function log.warn(message) end


