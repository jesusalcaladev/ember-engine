/* The one translation unit that compiles stb_image's implementation.
 *
 * Why a C shim and not `@cImport`: Zig 0.16's translate-c cannot lower the
 * whole of stb_image (unions of arrays, bit-cast pointer arithmetic) — it
 * emits a cimport.zig that does not compile. Declaring the handful of externs
 * we use by hand (the same approach `platform/glfw_bindings.zig` takes for
 * GLFW) keeps the dependency compiled as C, one TU, and the Zig side tiny.
 */
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
