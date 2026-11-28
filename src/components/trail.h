#pragma once

#include <glm/vec2.hpp>
#include <glm/vec3.hpp>
#include <vector>


// One or more ribbons tracking an entity over time. Each ribbon records its
// own world-space history, so a multi-engine ship renders one ribbon per
// engine while a missile uses a single ribbon at its center.
class Trail
{
public:
    struct Point {
        glm::vec2 position;
        float age = 0.0f; // seconds since this point was recorded
    };

    struct Ribbon {
        // Emitter position relative to the entity center, in the entity's frame.
        glm::vec2 offset{};

        // Half-width of the ribbon at its head, in world units; tapers to 0 at the tail.
        float head_width = 8.0f;

        // Color of the ribbon at its head (youngest end).
        glm::vec3 color = {1.0f, 0.8f, 0.8f};

        // World-space positions recorded over time, oldest first.
        std::vector<Point> points;
    };

    // Maximum number of points kept per ribbon.
    static constexpr size_t max_points = 64;

    // How often (in seconds) a new point is appended to each ribbon.
    float sample_interval = 0.05f;

    // Total time (seconds) a point lives before being discarded.
    float max_age = 3.0f;

    // While false, points are only aged, never appended (engines offline).
    bool sampling = true;

    // When the owner entity is destroyed, move the ribbons to an orphan
    // entity so the trail fades out instead of vanishing with it.
    bool detach_on_destroy = false;

    // Draw a bright billboard at the entity's position — the marker for a
    // projectile that has no rendered model.
    bool head_glow = false;

    std::vector<Ribbon> ribbons;
    float time_since_last_sample = 0.0f;
};
