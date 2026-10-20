//! The GPU particle simulation: one compute pass that spawns, one that
//! integrates.
//!
//! ## Why two passes and not one
//!
//! The spawn pops a slot off the emitter's free list and WRITES the particle;
//! the integration advances the live ones. If both ran in the same pass, a
//! particle spawned by one thread could be integrated by another in the same
//! dispatch — a data race, and WGSL has no rule that would make it benign.
//! Two dispatches in the same compute pass are ordered, and WebGPU puts a
//! memory barrier between them, so the second pass sees the first one's
//! writes.
//!
//! ## The free list
//!
//! Each emitter owns a fixed SLICE of the global pool, and the dead slots
//! form an intrusive stack inside the particles themselves (`next`). The
//! stack is lock-free: the push writes the link and then swaps the head with
//! a compare-exchange, retrying if somebody else took the head meanwhile.
//! Writing the link BEFORE the exchange is what makes it correct — the
//! exchange only succeeds if the head is still what we saw, and the link is
//! rewritten before each retry.
//!
//! ## The semantics are the CPU's
//!
//! Every rule here is the CPU system's rule (see `render/particles.zig`): the
//! same drag (`v *= exp(-drag*dt)`), the same gravity, the same colour
//! interpolation, the same "the particle dies when its age reaches its life".
//! An emitter that moves from the CPU backend to the GPU one has to look the
//! same, and a rule that is written twice has to be written the same way
//! twice.

const SLICE: u32 = 256u;
const WORKGROUP: u32 = 64u;
const NO_SLOT: u32 = 0xffffffffu;

/// What the CPU knows about an emitter. Written every frame: the emitter can
/// move, and a particle born "at the emitter" has to be born where it is NOW.
struct Params {
    pos: vec2f,        // where the emitter is
    prev_pos: vec2f,   // where it was: the delta moves the local particles
    angle: vec2f,      // the emission angle's range, radians
    speed: vec2f,      // the speed's range
    life: vec2f,       // the lifetime's range, seconds
    size: vec2f,       // the size at birth and at death
    gravity: vec2f,    // the constant acceleration
    extent: vec2f,     // the box half extents, or the disc's radius
    drag: f32,         // the velocity damping per second
    spin: f32,         // the rotation velocity, rad/s
    rate: f32,         // the particles per second
    shape: u32,        // 0 point, 1 box, 2 disc
    seed: u32,         // the emitter's PRNG seed
    color0: u32,       // the colour at birth, packed RGBA
    color1: u32,       // the colour at death, packed RGBA
    capacity: u32,     // the hard cap on live particles
    flags: u32,        // bit 0: playing, bit 1: one shot, bit 2: local space
    _pad: u32,         // the struct ends at 104 bytes, and it says so
};

/// The GPU-owned state of an emitter. The CPU never writes it: the free list
/// and the spawn accumulator live here because the GPU is the only one that
/// can update them without a readback.
struct State {
    free_head: atomic<u32>,
    free_count: atomic<u32>,
    spawn_accum: atomic<u32>,  // the rate accumulator, in 1/256 of a particle
    fired: atomic<u32>,        // the one-shot has already fired
    _pad: u32,
};

/// One particle: 64 bytes. The layout is the CPU system's, field for field,
/// and the sizes are read in the DRAW pass, not the simulation.
struct Particle {
    pos: vec2f,
    vel: vec2f,
    age: f32,
    life: f32,
    size0: f32,
    size1: f32,
    rot: f32,
    rot_v: f32,
    color0: u32,
    color1: u32,
    alive: u32,
    next: u32,   // the free list's link
    atlas: u32,
    _pad: u32,
};

@group(0) @binding(0) var<storage, read_write> particles: array<Particle>;
@group(0) @binding(1) var<storage, read_write> states: array<State>;
@group(0) @binding(2) var<storage, read> params: array<Params>;
@group(0) @binding(3) var<uniform> sim: SimUniforms;

struct SimUniforms {
    dt: f32,
    time: f32,
    emitter_count: u32,
    _pad: u32,
};

/// A hash, for the randomness. Not the CPU's xorshift: the sequence is
/// different, and it does not have to be — what has to hold is that the SAME
/// scene on the SAME backend replays the same particles (spec §6).
fn hash(v: u32) -> u32 {
    var x = v;
    x ^= x >> 16u;
    x *= 0x7feb352du;
    x ^= x >> 15u;
    x *= 0x846ca68bu;
    x ^= x >> 16u;
    return x;
}

/// A number in [0, 1) from a seed and a salt.
fn rand01(seed: u32, salt: u32) -> f32 {
    return f32(hash(seed ^ (salt * 0x9e3779b9u)) >> 8u) / 16777216.0;
}

/// Pops a free slot off an emitter's stack. Returns NO_SLOT when the emitter
/// is out of room, which is an answer and not an error: the CPU system's pool
/// drops the spawn and counts it too.
///
/// The emitter is an INDEX and not a pointer: a WGSL pointer may not point at
/// a struct with an atomic in it, and the free list IS an atomic.
fn popFree(emitter: u32) -> u32 {
    var head = atomicLoad(&states[emitter].free_head);
    loop {
        if (head == NO_SLOT) {
            return NO_SLOT;
        }
        let next = particles[head].next;
        let result = atomicCompareExchangeWeak(&states[emitter].free_head, head, next);
        if (result.exchanged) {
            atomicSub(&states[emitter].free_count, 1u);
            return head;
        }
        head = result.old_value;
    }
}

/// Pushes a dead slot back onto an emitter's stack.
fn pushFree(emitter: u32, idx: u32) {
    var head = atomicLoad(&states[emitter].free_head);
    loop {
        // The link is written BEFORE the exchange, and rewritten on every
        // retry: the exchange only succeeds if the head is still what we saw.
        particles[idx].next = head;
        let result = atomicCompareExchangeWeak(&states[emitter].free_head, head, idx);
        if (result.exchanged) {
            atomicAdd(&states[emitter].free_count, 1u);
            return;
        }
        head = result.old_value;
    }
}

/// The spawn pass: one thread per emitter.
///
/// The thread that owns slot 0 of the emitter's slice does the spawning, so
/// the emitter's spawn loop is serial — which is what the CPU does too, and
/// an emitter emits tens of particles a second, not thousands.
@compute @workgroup_size(WORKGROUP)
fn spawn_pass(@builtin(global_invocation_id) gid: vec3u) {
    let emitter = gid.x;
    if (emitter >= sim.emitter_count) {
        return;
    }
    let prm = params[emitter];

    // The playing flag.
    if ((prm.flags & 1u) == 0u) {
        return;
    }

    // How many to spawn.
    //
    // The rate accumulator holds 1/256ths of a particle, so a rate of 2.5
    // emits one every other frame at 60 Hz and the fraction is CARRIED: a
    // dropped fraction drifts the rate low, and a rate that drifts is a bug
    // nobody reports.
    var to_spawn: u32 = 0u;
    if ((prm.flags & 2u) != 0u) {
        // A ONE SHOT: the whole capacity, once, and then never again. The
        // flag in the state is what makes it fire once — a script that clears
        // the particles and plays again gets a continuing emitter, not a
        // second detonation.
        if (atomicExchange(&states[emitter].fired, 1u) == 0u) {
            to_spawn = prm.capacity;
        }
    } else {
        if (prm.rate <= 0.0) {
            return;
        }
        let scaled = u32(prm.rate * 256.0 * sim.dt);
        if (scaled == 0u) {
            return;
        }
        let old = atomicAdd(&states[emitter].spawn_accum, scaled);
        let total = old + scaled;
        to_spawn = total / 256u;
        // The remainder stays in the accumulator.
        atomicStore(&states[emitter].spawn_accum, total % 256u);
    }

    for (var k: u32 = 0u; k < to_spawn; k = k + 1u) {
        // The emitter's own cap, and the slice's room. A spawn that does not
        // fit is DROPPED, like the CPU system's: the count is the answer.
        if (atomicLoad(&states[emitter].free_count) == 0u) {
            return;
        }
        if (SLICE - atomicLoad(&states[emitter].free_count) >= prm.capacity) {
            return;
        }
        let idx = popFree(emitter);
        if (idx == NO_SLOT) {
            return;
        }
        // The randomness: the emitter's seed and the particle's index, so a
        // particle's numbers do not depend on the order the threads ran in.
        let salt = hash(idx * 2654435761u + emitter);
        var ex: f32 = 0.0;
        var ey: f32 = 0.0;
        if (prm.shape == 1u) {
            ex = (rand01(prm.seed, salt) * 2.0 - 1.0) * prm.extent.x;
            ey = (rand01(prm.seed, salt + 1u) * 2.0 - 1.0) * prm.extent.y;
        } else if (prm.shape == 2u) {
            let r = prm.extent.x * sqrt(rand01(prm.seed, salt));
            let a = rand01(prm.seed, salt + 1u) * 6.28318530718;
            ex = cos(a) * r;
            ey = sin(a) * r;
        }
        let ang = prm.angle.x + rand01(prm.seed, salt + 2u) * (prm.angle.y - prm.angle.x);
        let spd = prm.speed.x + rand01(prm.seed, salt + 3u) * (prm.speed.y - prm.speed.x);

        // A `let`, not a `var`: WGSL only allows a function-scope variable to
        // hold a constructible type, and a pointer into a storage buffer is
        // not one. The pointer itself is immutable; what it points at is not.
        let p = &particles[idx];
        p.pos = prm.pos + vec2f(ex, ey);
        p.vel = vec2f(cos(ang) * spd, sin(ang) * spd);
        p.age = 0.0;
        p.life = prm.life.x + rand01(prm.seed, salt + 4u) * (prm.life.y - prm.life.x);
        p.size0 = prm.size.x;
        p.size1 = prm.size.y;
        p.rot = 0.0;
        p.rot_v = prm.spin;
        p.color0 = prm.color0;
        p.color1 = prm.color1;
        p.atlas = 0u;
        p.alive = 1u;
    }
}

/// The integration pass: one thread per particle.
@compute @workgroup_size(WORKGROUP)
fn sim_pass(@builtin(global_invocation_id) gid: vec3u) {
    let idx = gid.x;
    if (idx >= arrayLength(&particles)) {
        return;
    }
    let emitter = idx / SLICE;
    if (emitter >= sim.emitter_count) {
        return;
    }
    let prm = params[emitter];
    // A `let`, not a `var`: WGSL only allows a function-scope variable to hold
    // a constructible type, and a pointer into a storage buffer is not one.
    let p = &particles[idx];
    if (p.alive == 0u) {
        return;
    }

    // The LOCAL space: the particle follows the emitter, which moved since
    // the last tick. The CPU applies the same delta to the whole slab.
    if ((prm.flags & 4u) != 0u) {
        p.pos += prm.pos - prm.prev_pos;
    }

    // The drag, the gravity, the position: the CPU's order, bit for bit.
    if (prm.drag != 0.0) {
        let decay = exp(-prm.drag * sim.dt);
        p.vel *= decay;
    }
    p.vel += prm.gravity * sim.dt;
    p.pos += p.vel * sim.dt;
    p.age += sim.dt;
    p.rot += p.rot_v * sim.dt;
    if (p.age >= p.life) {
        p.alive = 0u;
        pushFree(emitter, idx);
    }
}
