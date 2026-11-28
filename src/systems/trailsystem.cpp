#include "trailsystem.h"
#include "components/missile.h"
#include "components/radar.h"
#include "glObjects.h"
#include "shaderRegistry.h"
#include "textureManager.h"
#include "main.h"
#include <graphics/opengl.h>
#include <glm/gtc/matrix_transform.hpp>
#include <glm/gtc/type_ptr.hpp>
#include <glm/geometric.hpp>
#include "vectorUtils.h"
#include <algorithm>
#include <array>


// Number of line segments interpolated between each pair of recorded points.
static constexpr int catmull_steps = 6;

// A recorded point ages toward smoke: it shifts toward smoke_color and —
// the transparent pass being additive — fades as its color is scaled
// toward black. The width stays near the head width for most of the
// point's life and only plumes out over the last smoke_plume_start..1
// fraction of its age, as it turns brown.
static constexpr float smoke_expansion = 0.05f;
static constexpr float smoke_plume_start = 0.75f;
static constexpr glm::vec3 smoke_color{0.35f, 0.30f, 0.25f};

// Interpolated position and age fraction (0=fresh, 1=expired) along the spline.
struct SplinePoint { glm::vec3 pos; float age_frac; };

// Evaluate the smoke interpolation for a point of age fraction t.
static void smoke_params(float t, const Trail::Ribbon& ribbon, glm::vec3& color, float& half_width)
{
    t = std::clamp(t, 0.0f, 1.0f);
    color = glm::mix(ribbon.color, smoke_color, t) * (1.0f - t);
    const float plume = std::clamp((t - smoke_plume_start) / (1.0f - smoke_plume_start), 0.0f, 1.0f);
    half_width = ribbon.head_width * (1.0f + smoke_expansion * plume * plume);
}


// Evaluate a Catmull-Rom spline at parameter t in [0,1] between p1 and p2,
// with p0 and p3 as the surrounding control points.
static glm::vec2 catmullRom(const glm::vec2& p0, const glm::vec2& p1,
                             const glm::vec2& p2, const glm::vec2& p3,
                             float t)
{
    float t2 = t * t;
    float t3 = t2 * t;
    return 0.5f * (
        (2.0f * p1) +
        (-p0 + p2) * t +
        (2.0f * p0 - 5.0f * p1 + 4.0f * p2 - p3) * t2 +
        (-p0 + 3.0f * p1 - 3.0f * p2 + p3) * t3
    );
}


void TrailSystem::onEntityDestroyed(sp::ecs::Entity entity)
{
    auto trail = entity.getComponent<Trail>();
    if (!trail || !trail->detach_on_destroy || trail->ribbons.empty())
        return;

    auto e = sp::ecs::Entity::create();
    if (auto transform = entity.getComponent<sp::Transform>())
    {
        auto& t = e.addComponent<sp::Transform>();
        t.setPosition(transform->getPosition());
        t.setRotation(transform->getRotation());
    }
    auto& orphan = e.addComponent<Trail>();
    orphan.ribbons = std::move(trail->ribbons);
    orphan.sampling = false;
    // detach_on_destroy stays on: the orphan cleans itself up once the
    // last point ages out, see TrailSystem::update.
    orphan.detach_on_destroy = true;
}


void TrailSystem::update(float delta)
{
    // Client-side seeding: spawnProjectile only runs on the server, so a
    // replicated projectile arrives without a Trail. Mirror the server's
    // projectile trail from the replicated radar trace, which carries the
    // same MissileWeaponData color. timeout > 0 marks mines, which keep
    // their replicated particle emitter instead of getting a trail.
    // Already-trailed entities (the server's own) skip out.
    for (auto [entity, flight, radar, existing] : sp::ecs::Query<MissileFlight, RadarTrace, sp::ecs::optional<Trail>>())
    {
        if (existing || flight.timeout > 0.0f)
            continue;
        auto& trail = entity.addComponent<Trail>();
        trail.detach_on_destroy = true;
        trail.head_glow = true;
        trail.ribbons.push_back({});
        trail.ribbons.back().color = glm::vec3(radar.color.r, radar.color.g, radar.color.b) / 255.0f;
    }

    std::vector<sp::ecs::Entity> finished_orphans;

    for (auto [entity, trail, transform] : sp::ecs::Query<Trail, sp::Transform>())
    {
        // Age all existing points and drop the expired ones.
        for (auto& ribbon : trail.ribbons)
        {
            for (auto& pt : ribbon.points)
                pt.age += delta;

            ribbon.points.erase(
                std::remove_if(ribbon.points.begin(), ribbon.points.end(),
                    [&trail](const Trail::Point& p) { return p.age >= trail.max_age; }),
                ribbon.points.end());
        }

        // Append a new sample to every ribbon if enough time has elapsed.
        trail.time_since_last_sample += delta;
        if (trail.time_since_last_sample >= trail.sample_interval)
        {
            trail.time_since_last_sample = 0.0f;
            if (trail.sampling)
            {
                const glm::vec2 base = transform.getPosition();
                const float rotation = transform.getRotation();
                for (auto& ribbon : trail.ribbons)
                {
                    Trail::Point pt;
                    pt.position = base + rotateVec2(ribbon.offset, rotation);
                    pt.age = 0.0f;
                    ribbon.points.push_back(pt);

                    // Cap the buffer.
                    if (ribbon.points.size() > Trail::max_points)
                        ribbon.points.erase(ribbon.points.begin());
                }
            }
        }

        if (trail.detach_on_destroy && !trail.sampling)
        {
            bool all_empty = true;
            for (const auto& ribbon : trail.ribbons)
                all_empty &= ribbon.points.empty();
            if (all_empty)
                finished_orphans.push_back(entity);
        }
    }

    // Destroy outside the query loop: destroying an entity mutates the
    // sparse sets the query is iterating over.
    for (auto entity : finished_orphans)
        entity.destroy();
}


void TrailSystem::render3D(sp::ecs::Entity /*e*/, sp::Transform& transform, Trail& trail)
{
    struct RibbonVertex { glm::vec3 pos; glm::vec2 uv; glm::vec3 color; };

    // Render state shared by all of this entity's ribbons.
    textureManager.getTexture("particle.png")->bind();
    ShaderRegistry::ScopedShader shader(ShaderRegistry::Shaders::Trail);

    gl::ScopedVertexAttribArray positions(shader.get().attribute(ShaderRegistry::Attributes::Position));
    gl::ScopedVertexAttribArray texcoords(shader.get().attribute(ShaderRegistry::Attributes::Texcoords));
    gl::ScopedVertexAttribArray colors(shader.get().attribute(ShaderRegistry::Attributes::Color));

    for (auto& ribbon : trail.ribbons)
    {
        // Need at least two recorded points to draw the ribbon.
        const size_t n = ribbon.points.size();
        if (n < 2)
            continue;

        // Tessellate a Catmull-Rom spline through the stored points,
        // interpolating each point's age fraction along with its position.
        const float inv_max_age = 1.0f / trail.max_age;
        std::vector<SplinePoint> spine;
        spine.reserve((n - 1) * catmull_steps + 1);

        for (size_t i = 0; i < n - 1; ++i)
        {
            const glm::vec2& p0 = ribbon.points[i > 0 ? i - 1 : 0].position;
            const glm::vec2& p1 = ribbon.points[i].position;
            const glm::vec2& p2 = ribbon.points[i + 1].position;
            const glm::vec2& p3 = ribbon.points[i + 1 < n - 1 ? i + 2 : n - 1].position;
            const float age0 = ribbon.points[i].age * inv_max_age;
            const float age1 = ribbon.points[i + 1].age * inv_max_age;

            for (int s = 0; s < catmull_steps; ++s)
            {
                float t = float(s) / float(catmull_steps);
                glm::vec2 p = catmullRom(p0, p1, p2, p3, t);
                spine.push_back({{p.x, p.y, 0.0f}, age0 + (age1 - age0) * t});
            }
        }
        spine.push_back({{ribbon.points.back().position.x, ribbon.points.back().position.y, 0.0f},
                         ribbon.points.back().age * inv_max_age});

        // Build a camera-facing ribbon as a triangle strip.
        // For each spine point the eye normal is perpendicular to both the
        // local tangent and the vector toward the camera, giving correct
        // orientation at any camera pitch.
        std::vector<RibbonVertex> vertices;
        vertices.reserve(spine.size() * 2);

        for (size_t i = 0; i < spine.size(); ++i)
        {
            // Tangent: difference to the next (or previous at the very end).
            glm::vec3 tangent;
            if (i + 1 < spine.size())
                tangent = spine[i + 1].pos - spine[i].pos;
            else
                tangent = spine[i].pos - spine[i - 1].pos;

            if (glm::length(tangent) < 1e-6f)
                tangent = glm::vec3(1, 0, 0);
            tangent = glm::normalize(tangent);

            glm::vec3 to_camera = glm::normalize(camera_position - spine[i].pos);
            glm::vec3 side = glm::normalize(glm::cross(tangent, to_camera));

            glm::vec3 color;
            float half_w;
            smoke_params(spine[i].age_frac, ribbon, color, half_w);
            float v = float(i) / float(spine.size() - 1);

            vertices.push_back({spine[i].pos + side * half_w, {0.0f, v}, color});
            vertices.push_back({spine[i].pos - side * half_w, {1.0f, v}, color});
        }

        glVertexAttribPointer(positions.get(), 3, GL_FLOAT, GL_FALSE, sizeof(RibbonVertex),
                              reinterpret_cast<const GLvoid*>(&vertices[0].pos));
        glVertexAttribPointer(texcoords.get(), 2, GL_FLOAT, GL_FALSE, sizeof(RibbonVertex),
                              reinterpret_cast<const GLvoid*>(&vertices[0].uv));
        glVertexAttribPointer(colors.get(), 3, GL_FLOAT, GL_FALSE, sizeof(RibbonVertex),
                              reinterpret_cast<const GLvoid*>(&vertices[0].color));

        // Draw pairs of quads with opposite winding for double-sided rendering,
        // since the ribbon may be viewed from either side depending on camera angle.
        std::vector<uint16_t> indices;
        indices.reserve((spine.size() - 1) * 12);
        for (size_t i = 0; i + 1 < spine.size(); ++i)
        {
            uint16_t a = uint16_t(i * 2);
            uint16_t b = uint16_t(i * 2 + 1);
            uint16_t c = uint16_t(i * 2 + 2);
            uint16_t d = uint16_t(i * 2 + 3);
            // Front face
            indices.insert(indices.end(), {a, b, c, b, d, c});
            // Back face
            indices.insert(indices.end(), {a, c, b, b, c, d});
        }

        glDrawElements(GL_TRIANGLES, static_cast<GLsizei>(indices.size()), GL_UNSIGNED_SHORT, indices.data());
    }

    // Head glow — a view-space-expanded billboard marking the entity's
    // position, standing in for a rendered model on projectiles.
    // Drawn after the ribbons so we don't disturb their attribute state.
    if (trail.head_glow && !trail.ribbons.empty())
    {
        glm::vec3 origin(transform.getPosition().x, transform.getPosition().y, 0.0f);
        // Bright while fresh; scales down with the head point's age so a
        // detached glow fades out with its smoke instead of popping.
        const auto& head_ribbon = trail.ribbons[0];
        float brightness = 1.0f;
        if (!head_ribbon.points.empty())
            brightness = 1.0f - std::min(head_ribbon.points.back().age / trail.max_age, 1.0f);
        const glm::vec3 color = head_ribbon.color * brightness;

        // All four vertices at the origin; the Billboard shader expands in view space.
        struct GlowVertex { glm::vec3 pos; glm::vec2 uv; };
        std::array<GlowVertex, 4> quad{{
            {{0,0,0}, {0.f, 0.f}},
            {{0,0,0}, {1.f, 0.f}},
            {{0,0,0}, {1.f, 1.f}},
            {{0,0,0}, {0.f, 1.f}},
        }};
        constexpr std::array<uint16_t, 6> glow_indices{0, 1, 2, 2, 3, 0};

        ShaderRegistry::ScopedShader billboard(ShaderRegistry::Shaders::Billboard);
        auto model_matrix = glm::translate(glm::identity<glm::mat4>(), origin);
        glUniformMatrix4fv(billboard.get().uniform(ShaderRegistry::Uniforms::Model), 1, GL_FALSE, glm::value_ptr(model_matrix));
        // Alpha doubles as the view-space expansion size in the Billboard shader.
        glUniform4f(billboard.get().uniform(ShaderRegistry::Uniforms::Color),
                    color.r, color.g, color.b, 20.0f);

        gl::ScopedVertexAttribArray bill_pos(billboard.get().attribute(ShaderRegistry::Attributes::Position));
        gl::ScopedVertexAttribArray bill_tex(billboard.get().attribute(ShaderRegistry::Attributes::Texcoords));

        glVertexAttribPointer(bill_pos.get(), 3, GL_FLOAT, GL_FALSE, sizeof(GlowVertex),
                              reinterpret_cast<const GLvoid*>(&quad[0].pos));
        glVertexAttribPointer(bill_tex.get(), 2, GL_FLOAT, GL_FALSE, sizeof(GlowVertex),
                              reinterpret_cast<const GLvoid*>(&quad[0].uv));
        glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, glow_indices.data());
    }
}
