#include "textureFiltering.h"

#include "logging.h"
#include "preferenceManager.h"
#include "textureManager.h"

namespace {

constexpr size_t bilinear_index = 1;

}

const std::vector<TextureFilteringMode>& textureFilteringModes()
{
    static const std::vector<TextureFilteringMode> modes{
        {"off", sp::MipmapFilter::None, 1.0f},
        {"bilinear", sp::MipmapFilter::Nearest, 1.0f},
        {"trilinear", sp::MipmapFilter::Linear, 1.0f},
        {"anisotropic_2x", sp::MipmapFilter::Linear, 2.0f},
        {"anisotropic_4x", sp::MipmapFilter::Linear, 4.0f},
        {"anisotropic_8x", sp::MipmapFilter::Linear, 8.0f},
        {"anisotropic_16x", sp::MipmapFilter::Linear, 16.0f},
    };
    return modes;
}

size_t savedTextureFilteringIndex()
{
    const auto key = PreferencesManager::get("texture_filtering", "bilinear");
    const auto& modes = textureFilteringModes();
    for (size_t index = 0; index < modes.size(); index++)
        if (modes[index].key == key)
            return index;
    return bilinear_index;
}

void applyTextureFilteringPreference()
{
    const auto& mode = textureFilteringModes()[savedTextureFilteringIndex()];
    textureManager.setDefaultMipmapFilter(mode.mipmaps);
    textureManager.setDefaultAnisotropy(mode.anisotropy);
    LOG(INFO) << "Texture filtering: " << mode.key;
}
