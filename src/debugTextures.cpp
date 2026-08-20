#include "debugTextures.h"

#ifdef DEBUG
#include <graphics/opengl.h>
#include <graphics/texture.h>

#include <array>
#include <memory>

namespace {

constexpr uint32_t base_size = 512;
constexpr uint32_t checker_cell = 4;

std::vector<uint8_t> makeChecker(uint32_t size, uint32_t cell)
{
    std::vector<uint8_t> pixels(static_cast<size_t>(size) * size * 4);
    for(uint32_t y=0; y<size; y++)
    {
        for(uint32_t x=0; x<size; x++)
        {
            const uint8_t value = (((x / cell) + (y / cell)) & 1u) ? 255 : 24;
            auto* pixel = &pixels[(static_cast<size_t>(y) * size + x) * 4];
            pixel[0] = pixel[1] = pixel[2] = value;
            pixel[3] = 255;
        }
    }
    return pixels;
}

std::vector<uint8_t> makeSolid(uint32_t size, const std::array<uint8_t, 3>& color)
{
    std::vector<uint8_t> pixels(static_cast<size_t>(size) * size * 4);
    for(size_t index=0; index<pixels.size(); index += 4)
    {
        pixels[index + 0] = color[0];
        pixels[index + 1] = color[1];
        pixels[index + 2] = color[2];
        pixels[index + 3] = 255;
    }
    return pixels;
}

}

sp::Texture* getDebugCheckerTexture()
{
    static std::unique_ptr<sp::BasicTexture> texture;
    if (!texture)
    {
        texture = std::make_unique<sp::BasicTexture>(glm::uvec2{base_size, base_size}, makeChecker(base_size, checker_cell), GL_RGBA);
        texture->generateMipmaps();
        texture->setRepeated(true);
        texture->setSmooth(true);
    }
    return texture.get();
}

sp::Texture* getDebugMipChartTexture()
{
    static std::unique_ptr<sp::BasicTexture> texture;
    if (!texture)
    {
        // Level 0 keeps the checkerboard so the texture is recognisable up
        // close; the levels below it are flat colours, coarse to fine.
        static constexpr std::array<std::array<uint8_t, 3>, 9> level_colors{{
            {{255, 32, 32}},    // 256
            {{32, 255, 32}},    // 128
            {{64, 96, 255}},    // 64
            {{255, 255, 32}},   // 32
            {{255, 32, 255}},   // 16
            {{32, 255, 255}},   // 8
            {{255, 128, 0}},    // 4
            {{255, 255, 255}},  // 2
            {{96, 96, 96}},     // 1
        }};

        std::vector<sp::TextureMipLevel> levels;
        levels.push_back({{base_size, base_size}, makeChecker(base_size, checker_cell)});
        uint32_t size = base_size;
        for(const auto& color : level_colors)
        {
            size /= 2;
            levels.push_back({{size, size}, makeSolid(size, color)});
        }

        texture = std::make_unique<sp::BasicTexture>(levels, GL_RGBA);
        texture->setRepeated(true);
        texture->setSmooth(true);
    }
    return texture.get();
}
#endif
