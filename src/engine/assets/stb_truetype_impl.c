/* The one translation unit that compiles stb_truetype's implementation (M14).
 *
 * Same shape and same reason as `stb_image_impl.c` beside it: Zig 0.16's
 * translate-c cannot lower the whole header, so the implementation is C and the
 * Zig side (`src/engine/render/font.zig`) declares the handful of externs it
 * calls. stb_truetype pulls `sqrt`/`floor`/`ceil`/`pow` from libm, which the
 * build links for every consumer of the `assets` module.
 *
 * `STBTT_malloc`/`STBTT_free` are left at their defaults (malloc/free): this is
 * called at load time and on an explicit `ui.font_load`, never inside the frame
 * loop, so it is outside the zero-allocation rule's jurisdiction (spec §3.1).
 */
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"
