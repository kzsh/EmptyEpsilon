#pragma once

#include "gui/gui2_overlay.h"
#include "ecs/entity.h"

#include <glm/vec3.hpp>
#include <utility>
#include <vector>

class GuiListbox;
class GuiLabel;
class GuiTextEntry;
class ModelEditorView;

enum class MountCategory { Beam, Tube, Engine };

struct MountSelection
{
    MountCategory category = MountCategory::Beam;
    // -1 when nothing is selected.
    int index = -1;
};

// One ModelData entry from __model_data. Positions are in ModelData
// coordinates, as passed to addBeamPosition() and friends: unscaled,
// mesh_offset excluded.
struct ModelEditorModel
{
    string name;
    string mesh;
    string texture;
    string specular_texture;
    string illumination_texture;
    string normal_texture;
    glm::vec3 mesh_offset{};
    float scale = 1.0f;
    std::vector<glm::vec3> beams;
    std::vector<glm::vec3> tubes;
    std::vector<glm::vec3> engines;
    // Parallel to engines: the r, g, b and scale arguments of addEngineEmitter().
    struct EngineStyle { glm::vec3 color{}; float scale = 1.0f; };
    std::vector<EngineStyle> engine_styles;

    std::vector<glm::vec3>& mounts(MountCategory category)
    {
        return const_cast<std::vector<glm::vec3>&>(std::as_const(*this).mounts(category));
    }
    const std::vector<glm::vec3>& mounts(MountCategory category) const
    {
        switch (category)
        {
        case MountCategory::Beam: return beams;
        case MountCategory::Tube: return tubes;
        case MountCategory::Engine: break;
        }
        return engines;
    }
};

class ModelEditorScreen : public GuiOverlay
{
public:
    ModelEditorScreen(GuiContainer* owner);
    virtual ~ModelEditorScreen();

private:
    void selectModel(int index);
    void setEditing(bool editing);
    void setSelection(MountSelection new_selection);
    void commitAxis(int axis, const string& text);
    void exportLua();

    std::vector<ModelEditorModel> models;
    // Carries the MeshRenderComponent the view draws; never given a Transform,
    // so the game viewport ignores it.
    sp::ecs::Entity preview;
    int selected_model = -1;
    GuiElement* browse_panel = nullptr;
    GuiListbox* model_list = nullptr;
    GuiElement* edit_panel = nullptr;
    GuiLabel* edit_title = nullptr;
    GuiListbox* manifest = nullptr;
    // Parallel to the manifest's entries.
    std::vector<MountSelection> manifest_mounts;
    MountSelection selection;
    GuiElement* details_panel = nullptr;
    GuiLabel* details_title = nullptr;
    GuiElement* details_axis_rows[3] = {};
    GuiTextEntry* details_axes[3] = {};
    GuiElement* details_hint = nullptr;
    ModelEditorView* view = nullptr;
};
