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

---Batch set: position, rotation and scale in one call.
---@param self Actor 
---@param x number 
---@param y number 
---@param rot number 
---@param scale number 
function Actor:set_transform(x, y, rot, scale) end

---Batch get: all actor components as one table (replaces N bindings).
---@param self Actor 
---@return table table of component values
function Actor:get_all() end

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

---Starts `fn` as a coroutine on this actor. The function is called with the actor's `self` and may call `self:wait(seconds)` to pause; the engine resumes it on the fixed step, so a wait is a measure of GAME time. The engine injects this method into every behavior's `self` table — it is not a module function, and the name `async` is reserved.
---@param self Actor 
---@param fn any the function to run as a coroutine
---@return boolean true when the coroutine started
function Actor:async(fn) end

---Pauses the current coroutine for `seconds` of game time. The wait is measured in the fixed step, so it slows down with the global time scale and replays identically. Only valid inside a coroutine; the global `wait(seconds)` is the same function.
---@param self Actor 
---@param seconds number how long to pause, in game seconds
function Actor:wait(seconds) end

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
function physics.create_shape(self, kind, half_w, half_h) end

---Replaces an actor's shape in place. Safe to call every frame while dragging a handle.
---@param self Actor 
---@param kind integer 0 box, 1 circle, 2 capsule, 3 cylinder, 4 polygon
---@param half_w number half width in world units
---@param half_h number half height in world units
function physics.reshape(self, kind, half_w, half_h) end

---Sets an actor's surface material.
---@param self Actor 
---@param friction number 0 slippery to 1 grippy
---@param restitution number 0 no bounce to 1 full bounce
---@param density number mass per area
function physics.set_material(self, friction, restitution, density) end

---Turns a shape into a trigger volume: reports overlaps, generates no contact response.
---@param self Actor 
---@param is_sensor boolean true for a trigger
function physics.set_sensor(self, is_sensor) end

---Assigns collision layers as bitmasks. Two shapes interact only if each is on a layer the other's mask has.
---@param self Actor 
---@param layer_mask integer which layers this actor is on
---@param collide_mask integer which layers it is willing to interact with
function physics.set_layers(self, layer_mask, collide_mask) end

---Changes how an actor is simulated: 0 fixed, 1 kinematic, 2 dynamic.
---@param self Actor 
---@param kind integer 0 fixed, 1 kinematic, 2 dynamic
function physics.set_body_type(self, kind) end

---Turns collision on or off without destroying the shape. The editor's eye toggle.
---@param self Actor 
---@param enabled boolean false to make it intangible
function physics.set_body_enabled(self, enabled) end

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


-- ── audio ──
---Plays a sound file and returns a handle. Load-time/preview: it may decode, so keep gameplay on a resident slot.
---@param path string path to the sound file, relative to the project root
---@param opts table { bus, bus_name, volume, pitch, max_distance, spread, loop, priority }
---@return any a voice handle, or nil when it could not load
function audio.play_file(path, opts) end

---Plays a sound STREAMED from disk: only a small window is resident and the frame loop keeps it fed. Use it for long music.
---@param path string path to the sound file, relative to the project root
---@param opts table { bus, bus_name, volume, pitch, max_distance, spread, loop, priority }
---@return any a voice handle, or nil when it could not open
function audio.play_stream(path, opts) end

---Stops one playing sound. A stale handle is a no-op.
---@param voice any 
function audio.stop(voice) end

---Stops every playing sound. The Play/Stop hook: leaves the mixer silent and exact.
function audio.stop_all() end

---Changes a playing sound's own volume (before bus gain).
---@param voice any 
---@param volume number 1 is full; >1 is allowed and soft-clipped
function audio.set_volume(voice, volume) end

---Changes a playing sound's pitch (the resample ratio): 2 is an octave up.
---@param voice any 
---@param pitch number 1 is original
function audio.set_pitch(voice, pitch) end

---Whether a voice is still playing. False for a stale handle.
---@param voice any 
---@return boolean true while the sound is audible
function audio.is_playing(voice) end

---Sets the master volume (bus 0). Applies to everything.
---@param gain number 1 is full
function audio.set_master_volume(gain) end

---Where the ears are and which way they face. The rotation turns the stereo field: a sound to the world-east pans right when the ears face +x.
---@param x number 
---@param y number 
---@param rotation number radians; 0 (default) faces +x
function audio.set_listener(x, y, rotation) end

---Solos or unsolos a bus. While any bus is soloed, every other bus except master is silent.
---@param bus any bus name or id
---@param solo boolean 
function audio.solo_bus(bus, solo) end

---Routes part of a bus into another bus's gain path (an aux/reverb send). A nil target clears it.
---@param bus any source bus name or id
---@param target any destination bus name or id, or nil to clear
---@param amount number fraction of the source signal, 0..4
function audio.set_bus_send(bus, target, amount) end

---A bus's current gain, by name or id. A missing name reads as 1.
---@param bus any bus name ('music') or id (number)
---@return number 0 when muted, otherwise the gain
function audio.bus_gain(bus) end

---Sets a bus gain by name or id. What a mixer slider writes.
---@param bus any bus name or id
---@param gain number 1 is full
function audio.set_bus_volume(bus, gain) end

---Mutes or unmutes a bus. Muted voices keep playing but are silent.
---@param bus any bus name or id
---@param muted boolean 
function audio.mute_bus(bus, muted) end

---Every named bus as { name, id, gain, muted, solo, send_to, send_amount }, in bus order. What the mixer panel iterates.
---@return table an array of bus records
function audio.buses() end

---Engine counters: voices active/peak, xruns, latency, the negotiated rate, and the bank's bytes.
---@return table voices_active, voices_peak, xruns, commands_dropped, latency_ms, period_frames, sample_rate, channels, bank_bytes, bank_budget
function audio.stats() end


-- ── sound ──
---Plays this actor's emitter at its transform. Omitting `path` plays the slot the scene already resolved (the frame-safe form).
---@param self Actor 
---@param path string sound file to load, relative to the project root; omit to use the emitter's own bank slot
---@param opts table { bus, bus_name, volume, pitch, loop, max_distance, spread, priority }; absent fields keep the component's values
---@return any a voice handle, or nil when there was nothing to play
function sound.play(self, path, opts) end

---Stops the voice this emitter started. A no-op when it already ended.
---@param self Actor 
function sound.stop(self) end

---Sets the emitter's gain and applies it to the voice already playing.
---@param self Actor 
---@param volume number 1 is full; >1 is allowed and soft-clipped
function sound.set_volume(self, volume) end

---Sets the emitter's resample ratio and applies it to the voice already playing.
---@param self Actor 
---@param pitch number 1 is original; 2 is an octave up
function sound.set_pitch(self, pitch) end

---Makes the emitter loop. Takes effect on the next play: a running voice keeps the flag it started with.
---@param self Actor 
---@param on boolean 
function sound.set_loop(self, on) end

---How far this sound carries. 0 means global: never attenuated, never panned (music, UI). Next play, not the running one.
---@param self Actor 
---@param max_distance number world units; 0 = global
function sound.set_radius(self, max_distance) end

---How far off-centre the sound reaches hard left/right. Next play, not the running one.
---@param self Actor 
---@param units number world units to full pan
function sound.set_spread(self, units) end

---Whether this emitter's voice is still audible. Asks the system, and clears a stale handle.
---@param self Actor 
---@return boolean true while the sound is playing
function sound.is_playing(self) end

---Every readable field of this emitter: bank slot, its path, bus, volume, pitch, loop, radius, spread, autoplay, playing, tick.
---@param self Actor 
---@return table an empty table when the actor has no emitter
function sound.describe(self) end


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
function sprite.rect(self, w, h, r, g, b, a) end

---A circle, no texture needed. One quad and one comparison in the shader.
---@param self Actor 
---@param diameter number width and height
---@param r number red 0..1
---@param g number green 0..1
---@param b number blue 0..1
---@param a number alpha 0..1
function sprite.circle(self, diameter, r, g, b, a) end

---The same shape, sampling a real atlas region. The 'now give it art' call.
---@param self Actor 
---@param w number width
---@param h number height
---@param atlas_slot integer index into the texture table
---@param u0 number atlas u0
---@param v0 number atlas v0
---@param u1 number atlas u1
---@param v1 number atlas v1
function sprite.texture(self, w, h, atlas_slot, u0, v0, u1, v1) end

---Draw order. Lower draws first; equal layers batch into one draw call.
---@param self Actor 
---@param layer integer 0 draws first
function sprite.set_layer(self, layer) end

---Draw nothing without despawning. The editor's eye toggle.
---@param self Actor 
---@param visible boolean false to stop drawing it
function sprite.set_visible(self, visible) end

---The sprite's size in world units.
---@param self Actor 
---@param w number width
---@param h number height
function sprite.set_size(self, w, h) end

---Colour, multiplied with the texel.
---@param self Actor 
---@param r number red 0..1
---@param g number green 0..1
---@param b number blue 0..1
---@param a number alpha 0..1
function sprite.set_tint(self, r, g, b, a) end

---The atlas region to sample.
---@param self Actor 
---@param u0 number left
---@param v0 number top
---@param u1 number right
---@param v1 number bottom
function sprite.set_uv(self, u0, v0, u1, v1) end

---Which texture in the table.
---@param self Actor 
---@param slot integer index into the texture table; 0 is the white texture
function sprite.set_atlas(self, slot) end

---How the quad is masked: 0 quad, 1 circle.
---@param self Actor 
---@param kind integer 0 quad, 1 circle
function sprite.set_shape(self, kind) end

---Blending mode: 0 solid, 1 alpha, 2 additive.
---@param self Actor 
---@param kind integer 0 solid, 1 alpha, 2 additive
function sprite.set_blend(self, kind) end

---The sprite's size. The inspector reads as well as writes.
---@param self Actor 
---@return number width
---@return number height
function sprite.get_size(self) end

---The sprite's tint.
---@param self Actor 
---@return number red
---@return number green
---@return number blue
---@return number alpha
function sprite.get_tint(self) end

---Loads an image, packs it into the shared atlas, and sets the sprite's texture slot and UV. The path is relative to the project root. It is a LOAD-TIME call: it reads a file and packs pixels, so it does not belong in a frame loop.
---@param self Actor 
---@param path string the image path, relative to the project root
function sprite.set_image(self, path) end


-- ── point ──
---Adds a PointLight2D: a lamp, torch or candle. Falls off in every direction.
---@param self Actor 
---@param radius number reach in world units
function point.new(self, radius) end

---How far the light reaches. Clamped to at least 1: a zero radius is a divide-by-zero in every falloff, not a hard edge.
---@param self Actor 
---@param radius number reach
function point.set_radius(self, radius) end


-- ── spot ──
---Adds a SpotLight2D: a cone with a soft edge.
---@param self Actor 
---@param radius number beam reach
function spot.new(self, radius) end

---How far the beam reaches.
---@param self Actor 
---@param radius number reach
function spot.set_radius(self, radius) end

---The cone's opening and its soft edge. Two numbers in one call because nothing ever sets one without the other, and a spotlight whose opening moved but whose soft edge did not is a mis-configured light nobody can explain.
---@param self Actor 
---@param degrees number full opening
---@param penumbra number 0..1 soft-edge fraction
function spot.set_cone(self, degrees, penumbra) end

---The direction the cone points.
---@param self Actor 
---@param radians number angle
function spot.set_angle(self, radians) end


-- ── directional ──
---Adds a DirectionalLight2D: the sun. No falloff at all, which is why it exists -- a point light at 4000 units is dark at the far end of the screen because its falloff is measured from where it IS, and a sun is not anywhere.
---@param self Actor 
function directional.new(self) end

---The direction the light TRAVELS, not the direction it points. A sun at 0 shines to the right, which makes shadows run to the left of every object.
---@param self Actor 
---@param radians number angle
function directional.set_angle(self, radians) end

---0..1. How high above the scene the light sits, which scales shadow LENGTH. A 2D scene needs a z coordinate for exactly this.
---@param self Actor 
---@param h number 0..1
function directional.set_height(self, h) end


-- ── ambient ──
---Adds an AmbientLight2D. Its own type rather than one number on the Environment, because a scene often wants TWO ambients -- a sky colour and a ground bounce.
---@param self Actor 
function ambient.new(self) end

---A local ambient. 0 restores the scene-wide kind. A lantern's pool of warm air differs from the night around it, and one number cannot hold both.
---@param self Actor 
---@param distance number reach; 0 for scene-wide
function ambient.set_local(self, distance) end


-- ── light ──
---Which light component this actor carries: point, spot, directional, ambient or legacy. nil when it carries none.
---@param self Actor 
---@return any the kind's name as a string, or nil for no light
function light.kind_of(self) end

---Every readable field of whichever light component is present, as one flat string-keyed table. An empty table when there is no light.
---@param self Actor 
---@return table field name to value
function light.describe(self) end

---Colour. Alpha is the light's opacity, so a light fades out by its alpha and not a separate field.
---@param self Actor 
---@param r number red
---@param g number green
---@param b number blue
---@param a number alpha
function light.set_color(self, r, g, b, a) end

---Brightness multiplier.
---@param self Actor 
---@param e number multiplier
function light.set_energy(self, e) end

---A spot's opening and its soft edge. The penumbra is the fraction of the cone given over to a fade: 0.2 means full strength to 80% and a fade over the last 20%.
---@param self Actor 
---@param degrees number full opening
---@param penumbra number 0..1 soft-edge fraction
function light.set_cone(self, degrees, penumbra) end

---0 add, 1 subtract, 2 mix. `mix` is the energy-conserving one: a white surface under it stays white.
---@param self Actor 
---@param kind integer 0 add, 1 subtract, 2 mix
function light.set_blend(self, kind) end

---Whether this light casts shadows, how the edge is filtered, and how wide the filter's taps are. Only four lights in a scene can get shadow channels, ranked by area.
---@param self Actor 
---@param enabled boolean cast shadows
---@param filter integer 0 off, 1 one tap, 2 three, 3 five
---@param smoothness number tap radius in mask texels
function light.set_shadow(self, enabled, filter, smoothness) end

---Which sprite layers this light affects, as a bitmask of `Sprite.layer`. A light on layer 2 lights only layer 2, which is how a scene gets a lamp that does not brighten its own interface.
---@param self Actor 
---@param bitmask integer mask of layer bits
function light.set_mask(self, bitmask) end

---The inspector reads as well as writes, and its field list is generated from this same registry.
---@param self Actor 
---@return number brightness multiplier
function light.get_energy(self) end

---Adds a light of `kind` (0 point, 1 spot, 2 directional, 3 ambient) with its colour, radius and energy in one call.
---@param self Actor 
---@param kind number 0 point, 1 spot, 2 directional, 3 ambient
---@param radius number reach; ignored by directional and ambient
---@param r number red
---@param g number green
---@param b number blue
---@param energy number brightness multiplier
function light.new(self, kind, radius, r, g, b, energy) end

---A spotlight's opening and soft edge. Degrees in, because that is how a cone is authored; the penumbra is 0..1.
---@param self Actor 
---@param degrees number full opening angle
---@param penumbra number 0..1; 0.2 is a typical flashlight
function light.set_cone(self, degrees, penumbra) end

---How far the light reaches. 0 for a directional or ambient light, which reach everywhere.
---@param self Actor 
---@return number radius in world units
function light.get_radius(self) end

---A spotlight's opening in degrees and its penumbra, for the inspector.
---@param self Actor 
---@return number opening in degrees
---@return number penumbra 0..1
function light.get_cone(self) end

---Whether this light casts shadows, the filter step and its smoothness — in the order `light.set_shadow` takes them.
---@param self Actor 
---@return boolean casts shadows
---@return number filter: 0 off, 1 pcf3, 2 pcf5, 3 soft
---@return number smoothness in texels
function light.get_shadow(self) end


-- ── lighting ──
---The lighting quality tier: 0 off, 1 low, 2 medium, 3 high. -1 when no lighting system is wired.
---@return number the tier, or -1
function lighting.quality() end

---Changes the lighting quality tier. False when it could not be taken, which is one case: a GI-on tier on a driver created with GI off declines, because the pyramid is a startup budget decision.
---@param tier number 0 off, 1 low, 2 medium, 3 high
---@return boolean whether the tier was taken
function lighting.set_quality(tier) end

---What the lighting system cost this frame: light counts, shadow channels, sweep steps, occluder counts and the per-pass timings in nanoseconds. Empty when no system is wired.
---@return table stat name to value
function lighting.stats() end


-- ── environment ──
---Adds an Environment to this actor. Without it the other environment.* functions are unreachable in a scene that has no actor carrying one.
---@param self Actor 
function environment.new(self) end

---How much bloom is added, and the luminance above which a pixel contributes to it. Zero intensity skips the four-pass chain entirely rather than running it with a zero multiplier.
---@param self Actor 
---@param intensity number 0..1; 0 disables the chain
---@param threshold number 0..1 luminance
function environment.set_bloom(self, intensity, threshold) end

---The radiance a ray that escapes the occluder mask carries. This is the base case of every GI merge, so it decides whether light bouncing around a corner is warm at sunset or white at noon.
---@param self Actor 
---@param r number red
---@param g number green
---@param b number blue
function environment.set_sky(self, r, g, b) end

---What 'dark' means in this world. One per world, not per actor: a dungeon and a meadow differ in what their shadows are made of.
---@param self Actor 
---@param r number red 0..1
---@param g number green 0..1
---@param b number blue 0..1
---@param energy number multiplier, 0 removes global light
function environment.set_ambient(self, r, g, b, energy) end

---What nothing lights at all resolves to. Separate from the ambient colour: one is what the world does to what it touches, the other is the empty case.
---@param self Actor 
---@param r number red
---@param g number green
---@param b number blue
function environment.set_clear(self, r, g, b) end

---A wash over the whole scene, which is how a bright room stops looking like a dark room with five torches in it. 0 disables it.
---@param self Actor 
---@param threshold number 0..0.2
function environment.set_bloom(self, threshold) end

---For HDR scenes, where a light at energy 3 otherwise clips to white and a colour ramp nobody chose.
---@param self Actor 
---@param enabled boolean 
function environment.set_tonemap(self, enabled) end

---The cheapest depth cue a 2D game has. `far <= near` disables it, and that is the documented way to remove it rather than a special zero case.
---@param self Actor 
---@param near number start distance
---@param far number end distance; 0 disables
---@param r number red
---@param g number green
---@param b number blue
function environment.set_fog(self, near, far, r, g, b) end

---The ambient colour with the energy applied, for the inspector.
---@param self Actor 
---@return number red
---@return number green
---@return number blue
---@return number alpha
function environment.get_ambient(self) end

---The clear colour.
---@param self Actor 
---@return number red
---@return number green
---@return number blue
---@return number alpha
function environment.get_clear(self) end

---Fog's near and far.
---@param self Actor 
---@return number near
---@return number far
function environment.get_fog(self) end


-- ── scene ──
---Covers the screen with the given colour over `duration` real seconds. Zero duration is an instant cover. Restarting an existing fade replaces it.
---@param duration number seconds; 0 = instant
---@param r number red 0..1
---@param g number green 0..1
---@param b number blue 0..1
function scene.fade_out(duration, r, g, b) end

---Uncovers from wherever the curtain currently is. Zero duration is an instant clear.
---@param duration number seconds; 0 = instant
function scene.fade_in(duration) end

---Jumps straight to a fully covered screen (a loading screen's first frame).
---@param r number red 0..1
---@param g number green 0..1
---@param b number blue 0..1
function scene.fade_covered(r, g, b) end

---Jumps straight back to a clear screen.
function scene.fade_clear() end

---Current curtain coverage.
---@return number coverage 0..1
function scene.fade_amount() end

---True while a transition is running.
---@return boolean true = fading
function scene.fading() end

---Lays a colour over the whole canvas (world and game UI). Multiply by default; `a` is the strength 0..1, and 0 is a no-op.
---@param r number red 0..1
---@param g number green 0..1
---@param b number blue 0..1
---@param a number strength 0..1; 0 turns the tint off
function scene.tint(r, g, b, a) end

---Sets how the tint mixes: "multiply" (default), "add" (a flash), "alpha" (a flat veil) or "off". Unknown names are ignored.
---@param name string "multiply", "add", "alpha" or "off"
function scene.tint_mode(name) end

---Disables the tint and forgets its colour.
function scene.tint_clear() end

---The tint's current strength. The value a script animates a flash back down to zero against.
---@return number strength 0..1
function scene.tint_amount() end


-- ── particles ──
---Emits `count` particles NOW from this actor's ParticleEmitter2D. Returns how many were actually emitted (may be less if the emitter's slab is full).
---@param self Actor 
---@param count integer how many to emit
---@return integer how many were emitted
function particles.burst(self, count) end

---Per-frame particle counters. `dropped_spawn` or `slab_denied` > 0 means the pool was too small at load time.
---@return table counters
function particles.stats() end


-- ── material ──
---Attaches a shader material to an actor. Shader 0 is the stock sprite shader.
---@param self Actor 
---@param shader integer index into the shader table
function material.new(self, shader) end

---The material's four floats. Enough for a colour, a threshold, a time.
---@param self Actor 
---@param p0 number param 0
---@param p1 number param 1
---@param p2 number param 2
---@param p3 number param 3
function material.set_params(self, p0, p1, p2, p3) end

---The material's four floats. The inspector reads as well as writes.
---@param self Actor 
---@return number param 0
---@return number param 1
---@return number param 2
---@return number param 3
function material.get_params(self) end

---Which shader this material uses.
---@param self Actor 
---@return number shader index
function material.get_shader(self) end


-- ── occluder ──
---Adds a light occluder to an actor.
---@param self Actor 
---@param mode integer 0 auto from the sprite's alpha, 1 manual polygon, 2 none
function occluder.new(self, mode) end

---0 derives the shape from the sprite's alpha at `set_threshold`, 1 uses the polygon, 2 blocks nothing. Mode 2 is how a sprite that looks like it occludes says it must not.
---@param self Actor 
---@param mode integer 0 auto, 1 manual, 2 none
function occluder.set_mode(self, mode) end

---The alpha at which the automatic shape decides a texel is solid. Raising it is the fix for most 'my sprite has a fringe of shadow' reports.
---@param self Actor 
---@param alpha number 0..1
function occluder.set_threshold(self, alpha) end

---Which lights this occluder blocks. 0 blocks everything, which is what a wall wants; a pane that blocks the sun but not the lamps sets it.
---@param self Actor 
---@param bitmask integer 0 for all lights
function occluder.set_mask(self, bitmask) end

---The manual shape, as a flat list of coordinates. Read from a table because eight positional arguments are unreadable and an editor dragging vertices produces a list anyway.
---@param self Actor 
---@param points table flat x/y pairs
function occluder.set_polygon(self, points) end

---The inspector reads as well as writes.
---@param self Actor 
---@return integer 0 auto, 1 manual, 2 none
function occluder.get_mode(self) end

---The automatic shape's alpha threshold.
---@param self Actor 
---@return number alpha 0..1
function occluder.get_threshold(self) end

---Which lights this occluder blocks.
---@param self Actor 
---@return integer the mask
function occluder.get_mask(self) end

---The manual shape as a flat list of coordinates. An editor that lets a user drag vertices reads this back to draw them.
---@param self Actor 
---@return table flat x/y pairs
function occluder.get_polygon(self) end


-- ── camera ──
---Adds a Camera2D to this actor. The FIRST enabled camera in the world is the one that renders, so a second one is a cut waiting to happen.
---@param self Actor 
function camera.new(self) end

---Makes this camera follow another actor. Passing an actor rather than a position means it stays correct without being told again every frame.
---@param self Actor 
---@param other Actor the actor to follow
function camera.follow(self, other) end

---The zoom the camera eases toward. 2 shows half the world at twice the detail; it is reached through a spring, not snapped.
---@param self Actor 
---@param zoom number target zoom, > 0
function camera.zoom_to(self, zoom) end

---Adds screen shake. Trauma accumulates and then decays, so repeated hits build on each other instead of restarting.
---@param self Actor 
---@param trauma number 0..1; 1 is a hard hit
function camera.shake(self, trauma) end

---The rectangle the camera may not leave — how a level stops you from seeing past its own edges. A zero width or height disables the limits.
---@param self Actor 
---@param x number left edge
---@param y number top edge
---@param w number width; 0 disables
---@param h number height; 0 disables
function camera.set_limits(self, x, y, w, h) end

---How lazily the camera chases its target. 0 welds it (a fixed-view platformer); higher trails behind.
---@param self Actor 
---@param damping number 0 = instant, ~8 = smooth
function camera.set_damping(self, damping) end

---Where the camera is, in world units — the same number the renderer uses.
---@param self Actor 
---@return number centre x
---@return number centre y
function camera.get_centre(self) end


-- ── timer ──
---A timer as a COMPONENT: kind 0 once, 1 loop, 2 during. It declares signal names instead of a closure, so it survives save/load and hot-reload.
---@param self Actor 
---@param seconds number cycle length
---@param kind number 0 once, 1 loop, 2 during
function timer.new(self, seconds, kind) end

---The signals this timer fires. `on_done` runs at the end of each cycle; `on_tick` runs every tick and only matters for kind 2 (during).
---@param self Actor 
---@param on_tick string empty fires nothing
---@param on_done string empty fires nothing
function timer.set_signals(self, on_tick, on_done) end

---Starts the timer from zero. 0 loops means forever.
---@param self Actor 
---@param loops number 0 = infinite
function timer.start(self, loops) end

---Pauses the timer WITHOUT losing its progress, so starting again resumes where it was. `timer.kill` ends it for good.
---@param self Actor 
function timer.stop(self) end

---Finishes the timer: no more signals, ever.
---@param self Actor 
function timer.kill(self) end

---How far through the current cycle, 0..1 — what a cooldown bar draws.
---@param self Actor 
---@return number 0 at the start, 1 at the end of the cycle
function timer.progress(self) end

---Puts the timer back to zero and runs it again. The configuration survives — the duration, the kind, the loop count and the signals are all still there; only the progress is reset.
---@param self Actor 
function timer.restart(self) end

---How long one cycle takes.
---@param self Actor 
---@param seconds number the cycle length
function timer.set_duration(self, seconds) end

---How long one cycle takes, in seconds.
---@param self Actor 
---@return number the cycle length in seconds
function timer.get_duration(self) end

---How far into the current cycle the timer is, in seconds.
---@param self Actor 
---@return number seconds into the current cycle
function timer.get_elapsed(self) end

---How many cycles the timer will run, and how many it has run. A count of 0 means it runs forever.
---@param self Actor 
---@return number the total cycle count (0 = forever)
---@return number the cycles completed so far
function timer.get_loops(self) end

---The kind of timer: 0 once, 1 loop, 2 during. Changing the kind does not restart the timer — the elapsed time and the cycle counter stay where they were.
---@param self Actor 
---@param kind number 0 once, 1 loop, 2 during
function timer.set_kind(self, kind) end

---This timer's own speed. 1 is normal, 0.5 is half as fast, 0 stops the timer where it is. It multiplies with the GLOBAL scale (`time.scale`): a slow-motion game slows every timer, and a timer slower than the game is slower still.
---@param self Actor 
---@param scale number 0 stops the timer, 0.5 halves it, 2 doubles it
function timer.set_time_scale(self, scale) end

---True once the timer has done its job: a `once` that fired, or a `loop` that exhausted its cycle count.
---@param self Actor 
---@return boolean true when the timer is done
function timer.is_finished(self) end

---True while the timer is stopped. A stopped timer keeps its elapsed time, so starting it again resumes where it was.
---@param self Actor 
---@return boolean true while the timer is stopped
function timer.is_paused(self) end

---The cycles this timer could not run, because one tick asked for more than the engine runs at once. Zero in a healthy game; a number that grows says the timer is running late.
---@param self Actor 
---@return number the dropped cycle count
function timer.get_dropped(self) end


-- ── time ──
---The last frame's delta in seconds, scaled by the global time scale. It is the same number the simulation advanced by, so a script can never move at a different speed than the world it is in.
---@return number seconds; 0 while the game is paused
function time.delta() end

---The last frame's REAL delta in seconds, unaffected by the time scale. A UI that has to keep moving while the game is paused reads this one.
---@return number seconds of wall clock
function time.unscaled_delta() end

---Scaled game time since boot. It slows down with the game, so it counts PLAY time, not wall-clock time.
---@return number seconds of game time
function time.elapsed() end

---Real time since boot, unaffected by the time scale.
---@return number seconds of wall clock
function time.unscaled_elapsed() end

---The frame counter, incremented once per frame since boot.
---@return number frames since boot
function time.frame() end

---The fixed simulation step (1/60 s) — the step the solver uses. Integrate against this when the answer must not depend on the frame rate.
---@return number the fixed step in seconds
function time.physics_delta() end

---The global time scale. 1 is normal, 0.5 is slow motion, 0 is paused.
---@return number the global scale
function time.scale() end

---Sets the global time scale. It slows the simulation — physics, timers, animation, particles — and the delta the scripts are handed. Clamped to [0, 100]: a negative scale would run the world backwards.
---@param s number 0 pauses, 0.5 is slow motion, 2 is double speed
function time.set_scale(s) end

---Pauses the simulation. The scale goes to 0 and the scale in force is remembered, so `resume` restores it. The frame loop keeps running: the UI and the input keep working.
function time.pause() end

---Unpauses the simulation, restoring the scale that was in force before the pause. A no-op when the game is not paused: a scale set by hand while paused is not stomped by a resume the game did not need.
function time.resume() end

---True while the game is paused.
---@return boolean true while the scale is 0
function time.is_paused() end


-- ── math ──
---An easing curve: the SHAPE of a movement over time. `t` goes from 0 to 1 and the result is how far along the movement is. The same curves the tween uses, so a value eased by hand and a value eased by a tween look the same.
---@param name string "linear", "in_quad", "out_cubic", "in_out_back", "out_elastic", "out_bounce"…
---@param t number 0 at the start, 1 at the end
---@return number the eased value; nil for an unknown curve
function math.ease(name, t) end

---Every easing name, so a script can discover what exists without the documentation being the only source.
---@return table the list of easing names
function math.easings() end

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


-- ── flow ──
---Declares a state of the game's flow. The first call creates the flow and binds it to this global. The hooks are the same `{ enter, update, exit }` the per-entity state machine takes, and they receive this global's `self`.
---@param self Actor the global that owns the flow
---@param name string the state's name
---@param hooks table optional: enter, update, exit
---@return boolean true when the state was declared
function flow.add_state(self, name, hooks) end

---A transition between the flow's states. It REPLACES the whole stack: the game's phase changed, not the layer on top of it.
---@param self Actor the global that owns the flow
---@param from string the state the transition leaves
---@param event string the event that triggers it
---@param to string the state the transition enters
---@return boolean true when the transition was declared
function flow.add_transition(self, from, event, to) end

---The state the flow enters when it starts.
---@param self Actor the global that owns the flow
---@param name string the starting state
---@return boolean true when the initial state was set
function flow.set_initial(self, name) end

---Requests a transition. It is applied at the TOP of the next tick, like `sm.fire`: a callback that fires cannot re-enter the flow.
---@param self Actor the global that owns the flow
---@param event string the event to fire
function flow.fire(self, event) end

---Jumps to a state NOW, replacing the whole stack. For a layered change use `flow.push`.
---@param self Actor the global that owns the flow
---@param name string the state to enter
---@return boolean true when the state was entered
function flow.set_state(self, name) end

---Pushes a state on the flow's stack. The state below stays: `flow.pop` returns to it. This is how "paused" sits on top of "playing".
---@param self Actor the global that owns the flow
---@param name string the state to push
---@return boolean true when the state was pushed
function flow.push(self, name) end

---Leaves the top of the flow's stack, returning to the one below. False when the stack has only the bottom state: the flow always has a phase.
---@param self Actor the global that owns the flow
---@return boolean true when a state was left
function flow.pop(self) end

---The state on the top of the flow's stack.
---@param self Actor the global that owns the flow
---@return string the current state's name
function flow.state(self) end

---Whether the top of the flow's stack is `name`.
---@param self Actor the global that owns the flow
---@param name string the state's name
---@return boolean true when the flow is in that state
function flow.is_in(self, name) end

---The states on the flow's stack, bottom to top. The last one is the current state.
---@param self Actor the global that owns the flow
---@return table the stack, as an array of names
function flow.stack(self) end


-- ── tween ──
---Animates a component property of this actor towards a value. Returns a handle: a number that identifies the tween until it finishes. The property is a component field, optionally with a sub-field: "position", "position.x", "rotation", "scale", "tint", "tint.a", "color", "energy", "radius", "value", "duration".
---@param self Actor 
---@param property string the property to drive, e.g. "position.x"
---@param value any the target: a number, or a table for a vector or a colour
---@param duration number seconds
---@param opts table optional: easing, delay, repeat, yoyo, hold, on_complete
---@return number the tween handle; 0 when it could not be created
function tween.to(self, property, value, duration, opts) end

---The child tween starts when the parent finishes. The child is parked and reset to its start value, so chain it before it runs (or create it with `hold = true`) to avoid a visible jump.
---@param parent number the tween handle that runs first
---@param child number the tween handle that waits
---@return boolean true when the chain was made
function tween.chain(parent, child) end

---Releases a parked tween: it starts now. A tween created with `hold = true` waits until it is released or chained.
---@param handle number the tween handle
---@return boolean true when the tween was released
function tween.start(handle) end

---Stops a tween where it is. The property keeps the value it had, and the completion callback does NOT run: a killed tween was cancelled, not finished.
---@param handle number the tween handle
---@return boolean true when a tween was stopped
function tween.kill(handle) end

---Stops every tween driving this actor. The count of stopped tweens comes back.
---@param self Actor 
---@return number how many tweens were stopped
function tween.kill_entity(self) end

---Stops every tween in the game. The count of tweens still running comes back.
---@return number how many tweens are still running
function tween.kill_all() end

---True while the tween is running. False once it finished, was killed, or never existed.
---@param handle number the tween handle
---@return boolean true while the tween runs
function tween.is_alive(handle) end

---How many tweens are running right now.
---@return number the number of live tweens
function tween.count() end

---The global tween speed. 1 is normal, 0 freezes every tween. It moves the ANIMATIONS, not the world: the world's speed is `time.scale`.
---@return number the global tween scale
function tween.time_scale() end

---Sets the global tween speed. Clamped to [0, 100]; a negative speed would run the animations backwards.
---@param s number 0 freezes the tweens, 0.5 halves them, 2 doubles them
function tween.set_time_scale(s) end

---Every property a tween can drive, as an array of names. The list is here so a script can discover what is tweenable without the documentation being the only source.
---@return table the list of tweenable property names
function tween.properties() end


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
function sm.add_state(self, name, hooks) end

---Moves from one state to another when an event is fired.
---@param self Actor 
---@param from string state the transition starts in
---@param event string event name that triggers it
---@param to string state to enter
function sm.add_transition(self, from, event, to) end

---Sets the state entered when the machine starts.
---@param self Actor 
---@param name string state to start in
function sm.set_initial(self, name) end

---Requests a transition; applied before the next update.
---@param self Actor 
---@param event string event name
function sm.fire(self, event) end

---Jumps to a state immediately, running exit then enter.
---@param self Actor 
---@param name string state to enter now
function sm.set_state(self, name) end

---The active state's name; empty before the first update.
---@param self Actor 
---@return string the current state name
function sm.state(self) end

---True when the machine is currently in that state.
---@param self Actor 
---@param name string state name to test
---@return boolean true when the active state is `name`
function sm.is_in(self, name) end


-- ── world ──
---Calls `fn(other_self)` for every actor within `radius`, excluding the caller.
---@param self Actor 
---@param x number centre x in world units
---@param y number centre y in world units
---@param radius number search radius in world units
---@param fn any visitor called as fn(other_self)
function world.nearby(self, x, y, radius, fn) end


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

---True while the pointer is over an interactive game-UI widget, so a click on a button is not also a world action.
---@return boolean true when an interactive UI widget captures the pointer this frame
function input.pointer_over_ui() end


-- ── log ──
---Logs an informational line. Strings are concatenated with `..`.
---@param message string message to log
function log.info(message) end

---Logs a warning line.
---@param message string warning message
function log.warn(message) end


-- ── globals ──
---The mounted global script's `self` table, or nil.
---@param name string the global script's cache name (e.g. "game")
---@return Actor the global's `self` table — call its methods (game:pause()) or read/write its fields; nil when no global by that name is mounted
function globals.get(name) end

---True when a global script with this name is mounted.
---@param name string the global script's cache name (e.g. "flow")
---@return boolean true while the global is mounted (a detached global returns false the moment it is gone)
function globals.exists(name) end


-- ── tilemap ──
---Sets the TileSet (tile palette) this layer draws from. The GUID is in 'asset_XXXXXXXXXXXXXXXX' format.
---@param self Actor 
---@param tileset_guid string TileSet asset GUID from the asset registry
function tilemap.set_tileset(self, tileset_guid) end

---Sets a single tile at the given tile coordinates. Flip flags are optional.
---@param self Actor 
---@param tile_x integer tile coordinate X (not pixels)
---@param tile_y integer tile coordinate Y (not pixels)
---@param atlas_index integer index into the TileSet atlas (0 = empty)
---@param flip_x boolean? #false# mirror horizontally
---@param flip_y boolean? #false# mirror vertically
function tilemap.set_tile(self, tile_x, tile_y, atlas_index, flip_x, flip_y) end

---Returns the tile at the given coordinates, or 0/false/false if empty.
---@param self Actor 
---@param tile_x integer tile coordinate X
---@param tile_y integer tile coordinate Y
---@return integer atlas index (0 = empty)
---@return boolean flip_x flag
---@return boolean flip_y flag
function tilemap.get_tile(self, tile_x, tile_y) end

---Fills a rectangle (inclusive) with the same tile. Order of corners does not matter.
---@param self Actor 
---@param x1 integer first corner tile X
---@param y1 integer first corner tile Y
---@param x2 integer opposite corner tile X
---@param y2 integer opposite corner tile Y
---@param atlas_index integer tile atlas index to fill with
function tilemap.fill_rect(self, x1, y1, x2, y2, atlas_index) end

---Sets the render layer (draw order). Lower layers draw first.
---@param self Actor 
---@param layer integer render layer (0 = default, negative = behind, positive = front)
function tilemap.set_layer(self, layer) end

---Enables or disables physics collision for this tile layer.
---@param self Actor 
---@param enabled boolean true = collidable, false = no collision
function tilemap.set_physics_enabled(self, enabled) end

---Returns the world-space bounds of a chunk. Useful for spawning or querying.
---@param self Actor 
---@param cx integer chunk X coordinate
---@param cy integer chunk Y coordinate
---@return number minimum world X
---@return number minimum world Y
---@return number maximum world X
---@return number maximum world Y
function tilemap.get_chunk_bounds(self, cx, cy) end

---Erases a rectangle (sets tiles to empty). Order of corners does not matter.
---@param self Actor 
---@param x1 integer first corner tile X
---@param y1 integer first corner tile Y
---@param x2 integer opposite corner tile X
---@param y2 integer opposite corner tile Y
function tilemap.erase_rect(self, x1, y1, x2, y2) end

---Overrides the tile size for this layer. 0 = use TileSet default.
---@param self Actor 
---@param size number tile size in world units (0 = default)
function tilemap.set_tile_size(self, size) end

---Sets default flip flags for newly placed tiles via set_tile/fill_rect.
---@param self Actor 
---@param flip_x boolean mirror horizontally by default
---@param flip_y boolean mirror vertically by default
function tilemap.set_default_flip(self, flip_x, flip_y) end

---Returns a table with debug info about this tilemap layer.
---@param self Actor 
---@return table fields: tileset_guid, layer, z_offset, physics_enabled, tile_size_override, default_flip_x, default_flip_y
function tilemap.describe(self) end


-- ── anim ──
---Adds an AnimationPlayer to this actor when it does not already have one.
---@param self Actor 
function anim.new(self) end

---Decodes a .anim clip file and registers it, returning the clip id for anim.play. Calling it again for the same path hot-reloads the clip under the same id, so playback position is kept.
---@param path string path to a .anim clip file
---@return integer clip id, or nil on failure
function anim.load(path) end

---Plays a clip. A positive blend crossfades over that many seconds instead of cutting.
---@param self Actor 
---@param clip_id integer? #current# clip handle to play (0 = nothing)
---@param blend number? #0# crossfade seconds; 0 cuts
function anim.play(self, clip_id, blend) end

---Stops playback and clears the current clip.
---@param self Actor 
function anim.stop(self) end

---Pauses playback by setting speed to 0; the clip and time are kept.
---@param self Actor 
function anim.pause(self) end

---Resumes a paused player by restoring speed 1; a no-op otherwise.
---@param self Actor 
function anim.resume(self) end

---Jumps to a time in seconds inside the current clip.
---@param self Actor 
---@param time number seconds from the clip start
function anim.seek(self, time) end

---Sets the playback rate: 1 is normal, negative plays in reverse.
---@param self Actor 
---@param speed number time multiplier
function anim.set_speed(self, speed) end

---Queues a clip to start when the current one finishes (up to four).
---@param self Actor 
---@param clip_id integer clip handle to queue
function anim.queue(self, clip_id) end

---Sets one playback parameter by name: speed, time, clip, blend or state. Unknown names are ignored.
---@param self Actor 
---@param name string 'speed' | 'time' | 'clip' | 'blend' | 'state'
---@param value number new value for the parameter
function anim.set_param(self, name, value) end

---Current playback state (0 idle, 1 playing, 2 paused, 3 finished).
---@param self Actor 
---@return integer playback state
function anim.state(self) end

---Current time in seconds inside the playing clip.
---@param self Actor 
---@return number seconds from the clip start
function anim.time(self) end

---Duration in seconds of the current clip; 0 when the clip is unknown.
---@param self Actor 
---@return number clip duration in seconds
function anim.length(self) end

---True while the player is in the playing state.
---@param self Actor 
---@return boolean true when playing
function anim.is_playing(self) end


-- ── ui ──
---Places the widget at an anchor preset: top_left … bottom_right, stretch_h, stretch_v or full_rect.
---@param self Actor 
---@param anchor string "top_left" | "top_center" | "top_right" | "middle_left" | "center" | "middle_right" | "bottom_left" | "bottom_center" | "bottom_right" | "stretch_h" | "stretch_v" | "full_rect"
function ui.set_anchor(self, anchor) end

---Displacement from the resolved anchor point, in canvas pixels.
---@param self Actor 
---@param x number horizontal offset
---@param y number vertical offset, positive down
function ui.set_offset(self, x, y) end

---Widget size in canvas pixels (ignored by `full_rect` and by the axis a stretch preset fills).
---@param self Actor 
---@param w number width in canvas pixels
---@param h number height in canvas pixels
function ui.set_size(self, w, h) end

---Where the anchor point sits on the widget: 0,0 is its top-left, 0.5,0.5 centres it.
---@param self Actor 
---@param x number 0..1 across the width
---@param y number 0..1 down the height
function ui.set_pivot(self, x, y) end

---The insets the stretch presets use. Ignored by the nine point anchors.
---@param self Actor 
---@param top number 
---@param right number 
---@param bottom number 
---@param left number 
function ui.set_margin(self, top, right, bottom, left) end

---Paint and hit-test tie-break: a higher order draws later and wins a click. Equal orders fall back to spawn order.
---@param self Actor 
---@param order integer any integer; additive across widgets
function ui.set_order(self, order) end

---Whether the widget is drawn this frame.
---@param self Actor 
---@param visible boolean 
function ui.set_visible(self, visible) end

---Whether the widget blocks world input and can be hovered/clicked. Labels and bars never capture regardless.
---@param self Actor 
---@param interactive boolean 
function ui.set_interactive(self, interactive) end

---The widget's string: a label's body, a button's caption or a bar's text. Truncated at 128 bytes.
---@param self Actor 
---@param text string the text to draw (max 128 bytes, silently truncated)
function ui.set_text(self, text) end

---Which font the text uses: 0 is the engine default, any other id comes from `ui.font_load`.
---@param self Actor 
---@param id integer font id from ui.font_load, or 0 for the default
function ui.set_font(self, id) end

---The widget's primary colour: a label's text, a panel's fill, a button's caption or a bar's fill.
---@param self Actor 
---@param r number red 0..1
---@param g number green 0..1
---@param b number blue 0..1
---@param a number alpha 0..1
function ui.set_color(self, r, g, b, a) end

---A button's four colours, each a `{ r, g, b, a }` array (alpha optional). A nil table leaves that colour unchanged.
---@param self Actor 
---@param normal table { r, g, b, a } when idle
---@param hover table { r, g, b, a } under the pointer
---@param pressed table { r, g, b, a } while held
---@param text table { r, g, b, a } for the caption
function ui.set_colors(self, normal, hover, pressed, text) end

---A panel's outline. Zero width or zero alpha draws none.
---@param self Actor 
---@param r number red 0..1
---@param g number green 0..1
---@param b number blue 0..1
---@param a number alpha 0..1
---@param width number border thickness in pixels
function ui.set_border(self, r, g, b, a, width) end

---Whether a progress bar draws its text (e.g. "7 / 10") over the fill.
---@param self Actor 
---@param show boolean 
function ui.set_show_text(self, show) end

---A progress bar's fill, clamped to 0..1.
---@param self Actor 
---@param value number 0..1 fraction filled
function ui.set_value(self, value) end

---A label's horizontal alignment inside its rect: "left", "center" or "right".
---@param self Actor 
---@param align string "left" | "center" | "right"
function ui.set_align(self, align) end

---A button's enabled flag. A disabled button is inert: no hover, no click, no pointer capture.
---@param self Actor 
---@param enabled boolean 
function ui.set_enabled(self, enabled) end

---The pixel size `text` would occupy in this widget's font. Nil when no UI system is wired.
---@param self Actor 
---@param text string the string to measure
---@return number width in pixels
---@return number height in pixels (the line box)
function ui.measure(self, text) end

---The screen-pixel rect the UI system resolved this frame: x, y, width, height.
---@param self Actor 
---@return number x of the top-left corner
---@return number y of the top-left corner
---@return number width in pixels
---@return number height in pixels
function ui.rect(self) end

---True while the pointer is over this widget.
---@param self Actor 
---@return boolean true when the pointer is over the widget
function ui.hovered(self) end

---True while this button is being held down.
---@param self Actor 
---@return boolean true while held
function ui.pressed(self) end

---Loads (or returns a cached) TTF at `px` pixels and returns its id for `ui.set_font`. 0 when unreadable.
---@param path string TTF path, relative to the project root
---@param px number pixel height to rasterize at
---@return integer font id for ui.set_font; 0 when the file could not be read
function ui.font_load(path, px) end


