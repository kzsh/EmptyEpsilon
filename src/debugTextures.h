#pragma once

#include "featureDefs.h"

#ifdef DEBUG
namespace sp { class Texture; }

// Procedurally generated textures for the debug model viewer.

// Fine checkerboard with a generated mip chain. Minified without mipmaps it
// shimmers; with mipmaps it fades to flat grey.
sp::Texture* getDebugCheckerTexture();

// Checkerboard at level 0, every level below it a flat, distinct colour. The
// colour on screen tells you which mip level the GPU picked, so an unmipped
// texture stays a checkerboard no matter how far away it is.
sp::Texture* getDebugMipChartTexture();
#endif
