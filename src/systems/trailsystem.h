#pragma once

#include <ecs/system.h>
#include "components/trail.h"
#include "systems/rendering.h"


class TrailSystem : public sp::ecs::System, public Render3DInterface<Trail, true>
{
public:
    void update(float delta) override;
    void render3D(sp::ecs::Entity e, sp::Transform& transform, Trail& trail) override;

    // Called from the entity pre-destroy hook; transfers detachable trails
    // to an orphan entity so they fade out instead of vanishing.
    static void onEntityDestroyed(sp::ecs::Entity entity);
};
