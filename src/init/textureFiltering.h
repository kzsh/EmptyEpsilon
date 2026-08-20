#pragma once

#include <graphics/texture.h>
#include <stringImproved.h>

#include <vector>

struct TextureFilteringMode
{
    string key; // Value of the texture_filtering preference.
    sp::MipmapFilter mipmaps;
    float anisotropy;
};

// Cheapest first. Anisotropic modes ascend and come last, so the modes a
// driver supports are always a prefix.
const std::vector<TextureFilteringMode>& textureFilteringModes();

// Index of the saved texture_filtering preference; bilinear when unset or unknown.
size_t savedTextureFilteringIndex();

// Applies to textures loaded afterwards, so call before any are loaded.
void applyTextureFilteringPreference();
