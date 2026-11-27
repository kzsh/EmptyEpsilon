#include <graphics/opengl.h>

#include "modelEditorScreen.h"
#include "gameGlobalInfo.h"
#include "glObjects.h"
#include "shaderRegistry.h"
#include "menus/luaConsole.h"
#include "components/rendering.h"
#include "screenComponents/rotatingModelView.h"
#include "gui/theme.h"
#include "gui/gui2_listbox.h"
#include "gui/gui2_button.h"
#include "gui/gui2_label.h"
#include "gui/gui2_textentry.h"
#include "clipboard.h"
#include "logging.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>

#include <glm/ext/matrix_transform.hpp>
#include <glm/geometric.hpp>
#include <glm/gtc/type_ptr.hpp>

namespace {

float getNumberField(lua_State* L, int table, const char* key, float fallback)
{
    lua_getfield(L, table, key);
    float result = lua_isnumber(L, -1) ? float(lua_tonumber(L, -1)) : fallback;
    lua_pop(L, 1);
    return result;
}

string getStringField(lua_State* L, int table, const char* key)
{
    lua_getfield(L, table, key);
    string result = lua_type(L, -1) == LUA_TSTRING ? lua_tostring(L, -1) : "";
    lua_pop(L, 1);
    return result;
}

glm::vec3 readVec3(lua_State* L, int table)
{
    glm::vec3 result{};
    if (!lua_istable(L, table)) return result;
    for (int n = 0; n < 3; n++)
    {
        lua_geti(L, table, n + 1);
        result[n] = float(lua_tonumber(L, -1));
        lua_pop(L, 1);
    }
    return result;
}

// Reads table[key] as an array of entries. position_key selects a sub-table
// holding the {x, y, z} triple, for engine_emitter's {position = {...}} shape.
std::vector<glm::vec3> readVec3List(lua_State* L, int table, const char* key, const char* position_key = nullptr)
{
    std::vector<glm::vec3> result;
    lua_getfield(L, table, key);
    if (lua_istable(L, -1))
    {
        int list = lua_gettop(L);
        for (int n = 1; lua_geti(L, list, n) == LUA_TTABLE; n++)
        {
            if (position_key)
            {
                lua_getfield(L, -1, position_key);
                result.push_back(readVec3(L, lua_gettop(L)));
                lua_pop(L, 1);
            }
            else
            {
                result.push_back(readVec3(L, lua_gettop(L)));
            }
            lua_pop(L, 1);
        }
        // The non-table value that ended the loop.
        lua_pop(L, 1);
    }
    lua_pop(L, 1);
    return result;
}

std::vector<ModelEditorModel::EngineStyle> readEngineStyles(lua_State* L, int table)
{
    std::vector<ModelEditorModel::EngineStyle> result;
    lua_getfield(L, table, "engine_emitter");
    if (lua_istable(L, -1))
    {
        int list = lua_gettop(L);
        for (int n = 1; lua_geti(L, list, n) == LUA_TTABLE; n++)
        {
            int emitter = lua_gettop(L);
            ModelEditorModel::EngineStyle style;
            lua_getfield(L, emitter, "color");
            style.color = readVec3(L, lua_gettop(L));
            lua_pop(L, 1);
            style.scale = getNumberField(L, emitter, "scale", 1.0f);
            result.push_back(style);
            lua_pop(L, 1);
        }
        lua_pop(L, 1);
    }
    lua_pop(L, 1);
    return result;
}

// Shortest form up to 4 decimals: 1.4 instead of 1.400000, 0 instead of -0.
string formatNumber(float value)
{
    string result = string(value, 4);
    while (result.find('.') >= 0 && (result.back() == '0' || result.back() == '.'))
    {
        const bool was_dot = result.back() == '.';
        result.pop_back();
        if (was_dot) break;
    }
    if (result == "-0") result = "0";
    return result;
}

}

namespace sp::script {
    template<> struct Convert<std::vector<ModelEditorModel>> {
        static std::vector<ModelEditorModel> fromLua(lua_State* L, int idx) {
            std::vector<ModelEditorModel> result;
            idx = lua_absindex(L, idx);
            if (!lua_istable(L, idx)) return result;

            lua_pushnil(L);
            while (lua_next(L, idx))
            {
                if (lua_type(L, -2) == LUA_TSTRING && lua_istable(L, -1))
                {
                    int entry = lua_gettop(L);
                    ModelEditorModel model;
                    model.name = lua_tostring(L, -2);

                    lua_getfield(L, entry, "mesh_render");
                    if (lua_istable(L, -1))
                    {
                        int mesh_render = lua_gettop(L);
                        model.mesh = getStringField(L, mesh_render, "mesh");
                        model.texture = getStringField(L, mesh_render, "texture");
                        model.specular_texture = getStringField(L, mesh_render, "specular_texture");
                        model.illumination_texture = getStringField(L, mesh_render, "illumination_texture");
                        model.normal_texture = getStringField(L, mesh_render, "normal_texture");
                        model.scale = getNumberField(L, mesh_render, "scale", 1.0f);
                        lua_getfield(L, mesh_render, "mesh_offset");
                        model.mesh_offset = readVec3(L, lua_gettop(L));
                        lua_pop(L, 1);
                    }
                    lua_pop(L, 1);

                    model.beams = readVec3List(L, entry, "__beam_positions");
                    model.tubes = readVec3List(L, entry, "__tube_positions");
                    // addEngineEmitter() stores positions premultiplied by
                    // mesh_render.scale, unlike beam and tube positions.
                    model.engines = readVec3List(L, entry, "engine_emitter", "position");
                    model.engine_styles = readEngineStyles(L, entry);
                    if (model.scale != 0.0f)
                    {
                        for (auto& engine : model.engines)
                            engine /= model.scale;
                        for (auto& style : model.engine_styles)
                            style.scale /= model.scale;
                    }

                    result.push_back(std::move(model));
                }
                lua_pop(L, 1);
            }

            std::sort(result.begin(), result.end(), [](const auto& a, const auto& b) { return a.name < b.name; });
            return result;
        }
    };
}

class ModelEditorView : public GuiRotatingModelView
{
public:
    ModelEditorView(GuiContainer* owner, string id, sp::ecs::Entity& entity)
    : GuiRotatingModelView(owner, id, entity)
    {
    }

    void setModel(const ModelEditorModel* new_model) { model = new_model; }
    void setSelection(MountSelection new_selection) { selection = new_selection; }

protected:
    void drawOverlay(const glm::mat4& view_matrix, float mesh_radius) override
    {
        if (!model) return;

        // Markers draw through the hull so mounts on the far side stay visible,
        // and unculled: the preview turns a full 360 degrees, so arrows are seen
        // from behind as often as from the front. Both states are saved rather
        // than assumed, as the overlay runs inside the shared model view's draw.
        const GLboolean depth_enabled = glIsEnabled(GL_DEPTH_TEST);
        const GLboolean cull_enabled = glIsEnabled(GL_CULL_FACE);
        glDisable(GL_DEPTH_TEST);
        glDisable(GL_CULL_FACE);

        ShaderRegistry::ScopedShader shader(ShaderRegistry::Shaders::BasicColor);
        const auto identity = glm::identity<glm::mat4>();
        glUniformMatrix4fv(shader.get().uniform(ShaderRegistry::Uniforms::Model), 1, GL_FALSE, glm::value_ptr(identity));
        gl::ScopedVertexAttribArray positions(shader.get().attribute(ShaderRegistry::Attributes::Position));

        // Camera right and up in world space are the rows of the view
        // matrix rotation (GLM is column-major: view[col][row]).
        const glm::vec3 cam_right = glm::normalize(glm::vec3(view_matrix[0][0], view_matrix[1][0], view_matrix[2][0]));
        const glm::vec3 cam_up = glm::normalize(glm::vec3(view_matrix[0][1], view_matrix[1][1], view_matrix[2][1]));
        const float marker_radius = mesh_radius * 0.025f;

        auto drawMarker = [&](glm::vec3 point, float radius, glm::vec4 color)
        {
            glUniform4fv(shader.get().uniform(ShaderRegistry::Uniforms::Color), 1, glm::value_ptr(color));
            // Game systems place mounts at position * scale relative to
            // the entity origin, without the mesh's 180-degree turn or
            // mesh_offset; see BeamWeaponSys and viewport3d engine emitters.
            const glm::vec3 center = point * model->scale;
            constexpr int segments = 16;
            glm::vec3 vertices[segments];
            for (int n = 0; n < segments; n++)
            {
                const float angle = float(n) / float(segments) * glm::two_pi<float>();
                vertices[n] = center + glm::cos(angle) * radius * cam_right + glm::sin(angle) * radius * cam_up;
            }
            glVertexAttribPointer(positions.get(), 3, GL_FLOAT, GL_FALSE, 0, vertices);
            glDrawArrays(GL_TRIANGLE_FAN, 0, segments);
        };

        // Arrow geometry uses the markers' coordinate space. The axis is a
        // convention, not data: see emissionAxis().
        auto drawArrow = [&](glm::vec3 point, glm::vec3 axis, float radius, glm::vec4 color)
        {
            const glm::vec3 dir = glm::normalize(axis);
            // u spans the ring plane with dir. The reference axis must not be
            // parallel to dir or the cross product degenerates to zero.
            const glm::vec3 ref = std::abs(dir.x) < 0.9f ? glm::vec3{1.0f, 0.0f, 0.0f} : glm::vec3{0.0f, 1.0f, 0.0f};
            const glm::vec3 u = glm::normalize(glm::cross(dir, ref));
            const glm::vec3 v = glm::cross(dir, u);
            const glm::vec3 base = point * model->scale;
            const float length = marker_radius * 5.0f;
            const glm::vec3 neck = base + dir * (length * 0.7f);
            const float head_radius = radius * 2.5f;
            constexpr int segments = 10;

            glUniform4fv(shader.get().uniform(ShaderRegistry::Uniforms::Color), 1, glm::value_ptr(color));

            {
                // Shaft: two rings, wound around the axis.
                glm::vec3 vertices[(segments + 1) * 2];
                int count = 0;
                for (int n = 0; n <= segments; n++)
                {
                    const float angle = float(n) / segments * glm::two_pi<float>();
                    const glm::vec3 ring = (u * glm::cos(angle) + v * glm::sin(angle)) * radius;
                    vertices[count++] = base + ring;
                    vertices[count++] = neck + ring;
                }
                glVertexAttribPointer(positions.get(), 3, GL_FLOAT, GL_FALSE, 0, vertices);
                glDrawArrays(GL_TRIANGLE_STRIP, 0, count);
            }
            {
                // Head: fan from the apex back to a wider ring at the neck.
                // The rim vertex is repeated to close the fan.
                glm::vec3 vertices[segments + 2];
                vertices[0] = base + dir * length;
                for (int n = 0; n <= segments; n++)
                {
                    const float angle = float(n) / segments * glm::two_pi<float>();
                    vertices[n + 1] = neck + (u * glm::cos(angle) + v * glm::sin(angle)) * head_radius;
                }
                glVertexAttribPointer(positions.get(), 3, GL_FLOAT, GL_FALSE, 0, vertices);
                glDrawArrays(GL_TRIANGLE_FAN, 0, segments + 2);
            }
        };

        auto arrowRadius = marker_radius * 0.35f;
        for (auto category : {MountCategory::Beam, MountCategory::Tube, MountCategory::Engine})
            for (const auto& point : model->mounts(category))
            {
                drawMarker(point, marker_radius, categoryColor(category));
                if (const auto axis = emissionAxis(category); glm::length2(axis) > 0.0f)
                    drawArrow(point, axis, arrowRadius, categoryColor(category));
            }

        // Selected mount last, so it sits on top: a white disc with the
        // category-colored marker over it reads as a ring.
        const auto& selected_points = model->mounts(selection.category);
        if (selection.index >= 0 && selection.index < int(selected_points.size()))
        {
            const auto point = selected_points[selection.index];
            drawMarker(point, marker_radius * 1.2f, {1.0f, 1.0f, 1.0f, 1.0f});
            drawMarker(point, marker_radius, categoryColor(selection.category));
            if (const auto axis = emissionAxis(selection.category); glm::length2(axis) > 0.0f)
                drawArrow(point, axis, arrowRadius, categoryColor(selection.category));
        }

        if (depth_enabled)
            glEnable(GL_DEPTH_TEST);
        if (cull_enabled)
            glEnable(GL_CULL_FACE);
    }

private:
    // Emission direction, in model_data coordinates. There +X is the bow:
    // mirrored port/starboard mounts share an X and differ in Y (destroyer beams
    // at 34,-17 and 34,17), fore/aft spread is in X (same destroyer: beams at
    // x=34 and x=-5, engine at x=-30), and Z is height.
    // Neither axis is stored per mount. EngineEmitter has no direction and its
    // particles spawn with start equal to end, so exhaust has no travel vector at
    // all; aft is what every emitter's position implies. Tube direction is
    // per-ship template data (MissileTubes::MountPoint::direction), unavailable
    // here; its default of zero is forward. Beams are aimed by the template's
    // arc, so no axis.
    static glm::vec3 emissionAxis(MountCategory category)
    {
        switch (category)
        {
        case MountCategory::Beam: return {};
        case MountCategory::Tube: return {1.0f, 0.0f, 0.0f};
        case MountCategory::Engine: break;
        }
        return {-1.0f, 0.0f, 0.0f};
    }

    static glm::vec4 categoryColor(MountCategory category)
    {
        switch (category)
        {
        case MountCategory::Beam: return {1.0f, 0.2f, 0.2f, 1.0f};
        case MountCategory::Tube: return {1.0f, 0.9f, 0.2f, 1.0f};
        case MountCategory::Engine: break;
        }
        return {0.2f, 0.7f, 1.0f, 1.0f};
    }

    const ModelEditorModel* model = nullptr;
    MountSelection selection;
};

ModelEditorScreen::ModelEditorScreen(GuiContainer* owner)
: GuiOverlay(owner, "MODEL_EDITOR_SCREEN", GuiTheme::getColor("background"))
{
    (new GuiOverlay(this, "BACKGROUND_CROSSES", glm::u8vec4{255,255,255,255}))
        ->setTextureTiled("gui/background/crosses.png");

    // model_data.lua runs in the base environment, so __model_data lives there.
    if (gameGlobalInfo && gameGlobalInfo->script_environment_base)
    {
        auto res = gameGlobalInfo->script_environment_base->run<std::vector<ModelEditorModel>>("return __model_data");
        LuaConsole::checkResult(res);
        if (res.isOk())
            models = res.value();
    }

    preview = sp::ecs::Entity::create();

    auto layout = new GuiElement(this, "MODEL_EDITOR_LAYOUT");
    layout
        ->setSize(GuiElement::GuiSizeMax, GuiElement::GuiSizeMax)
        ->setAttribute("layout", "horizontal");
    layout->setAttribute("padding", "20");

    // Browse and edit panels share the left column; one is visible at a time.
    auto left_column = new GuiElement(layout, "MODEL_EDITOR_LEFT");
    left_column
        ->setSize(400.0f, GuiElement::GuiSizeMax)
        ->setAttribute("margin", "0, 20, 0, 0");

    browse_panel = new GuiElement(left_column, "MODEL_EDITOR_BROWSE");
    browse_panel
        ->setSize(GuiElement::GuiSizeMax, GuiElement::GuiSizeMax)
        ->setAttribute("layout", "vertical");

    model_list = new GuiListbox(browse_panel, "MODEL_EDITOR_MODEL_LIST", [this](int index, string) { selectModel(index); });
    model_list
        ->setSize(GuiElement::GuiSizeMax, GuiElement::GuiSizeMax)
        ->setAttribute("margin", "0, 0, 0, 20");
    for (const auto& model : models)
        model_list->addEntry(model.name, model.name);

    (new GuiButton(browse_panel, "MODEL_EDITOR_EDIT", "Edit", [this]() { setEditing(true); }))
        ->setSize(GuiElement::GuiSizeMax, 50.0f);

    edit_panel = new GuiElement(left_column, "MODEL_EDITOR_EDIT_PANEL");
    edit_panel
        ->setSize(GuiElement::GuiSizeMax, GuiElement::GuiSizeMax)
        ->setAttribute("layout", "vertical");
    edit_panel->hide();

    (new GuiButton(edit_panel, "MODEL_EDITOR_BACK", "Back to models", [this]() { setEditing(false); }))
        ->setSize(GuiElement::GuiSizeMax, 50.0f)
        ->setAttribute("margin", "0, 0, 0, 10");

    edit_title = new GuiLabel(edit_panel, "MODEL_EDITOR_TITLE", "", 30.0f);
    edit_title
        ->setSize(GuiElement::GuiSizeMax, 40.0f)
        ->setAttribute("margin", "0, 0, 0, 10");

    manifest = new GuiListbox(edit_panel, "MODEL_EDITOR_MANIFEST", [this](int index, string)
    {
        if (index < 0 || index >= int(manifest_mounts.size())) return;
        const auto clicked = manifest_mounts[index];
        // A second click on the selected entry deselects it.
        if (clicked.category == selection.category && clicked.index == selection.index)
            setSelection({});
        else
            setSelection(clicked);
    });
    manifest
        ->setSize(GuiElement::GuiSizeMax, GuiElement::GuiSizeMax)
        ->setAttribute("margin", "0, 0, 0, 10");

    (new GuiButton(edit_panel, "MODEL_EDITOR_EXPORT", "Copy Lua to clipboard", [this]() { exportLua(); }))
        ->setSize(GuiElement::GuiSizeMax, 50.0f);

    view = new ModelEditorView(layout, "MODEL_EDITOR_VIEW", preview);
    view->setSize(GuiElement::GuiSizeMax, GuiElement::GuiSizeMax);

    // Shown for the whole of edit mode, so the view keeps its width when
    // the selection changes.
    details_panel = new GuiElement(layout, "MODEL_EDITOR_DETAILS");
    details_panel
        ->setSize(300.0f, GuiElement::GuiSizeMax)
        ->setAttribute("layout", "vertical");
    details_panel->setAttribute("margin", "20, 0, 0, 0");
    details_panel->hide();

    details_title = new GuiLabel(details_panel, "MODEL_EDITOR_DETAILS_TITLE", "", 30.0f);
    details_title
        ->setSize(GuiElement::GuiSizeMax, 40.0f)
        ->setAttribute("margin", "0, 0, 0, 10");

    const char* axis_names[3] = {"x", "y", "z"};
    for (int n = 0; n < 3; n++)
    {
        details_axis_rows[n] = new GuiElement(details_panel, "");
        details_axis_rows[n]
            ->setSize(GuiElement::GuiSizeMax, 50.0f)
            ->setAttribute("layout", "horizontal");
        details_axis_rows[n]->setAttribute("margin", "0, 0, 0, 10");

        (new GuiLabel(details_axis_rows[n], "", axis_names[n], 30.0f))
            ->setSize(40.0f, GuiElement::GuiSizeMax);

        details_axes[n] = new GuiTextEntry(details_axis_rows[n], "", "");
        details_axes[n]->setSize(GuiElement::GuiSizeMax, GuiElement::GuiSizeMax);
        details_axes[n]->enterCallback([this, n](string text) { commitAxis(n, text); });
    }

    details_hint = new GuiElement(details_panel, "MODEL_EDITOR_DETAILS_HINT");
    details_hint
        ->setSize(GuiElement::GuiSizeMax, 50.0f)
        ->setAttribute("layout", "vertical");
    for (auto line : {"Press Enter to apply.", "Non-numeric values revert."})
    {
        (new GuiLabel(details_hint, "", line, 20.0f))
            ->setAlignment(sp::Alignment::CenterLeft)
            ->setSize(GuiElement::GuiSizeMax, 25.0f);
    }

    if (!models.empty())
    {
        model_list->setSelectionIndex(0);
        selectModel(0);
    }
}

ModelEditorScreen::~ModelEditorScreen()
{
    preview.destroy();
}

void ModelEditorScreen::selectModel(int index)
{
    if (index < 0 || index >= int(models.size())) return;
    selected_model = index;
    const auto& model = models[index];

    auto& mrc = preview.addComponent<MeshRenderComponent>();
    mrc.mesh.name = model.mesh;
    mrc.texture.name = model.texture;
    mrc.specular_texture.name = model.specular_texture;
    mrc.illumination_texture.name = model.illumination_texture;
    mrc.normal_texture.name = model.normal_texture;
    mrc.mesh_offset = model.mesh_offset;
    mrc.scale = model.scale;

    view->setModel(&model);
}

void ModelEditorScreen::setSelection(MountSelection new_selection)
{
    selection = new_selection;
    view->setSelection(selection);

    int entry = -1;
    for (int n = 0; n < int(manifest_mounts.size()); n++)
        if (manifest_mounts[n].category == selection.category && manifest_mounts[n].index == selection.index)
            entry = n;
    manifest->setSelectionIndex(entry);

    if (entry < 0)
    {
        details_title->setText("No selection");
        for (auto* row : details_axis_rows)
            row->hide();
        details_hint->hide();
        return;
    }

    // Model coordinates, as written in model_data.lua.
    const auto point = models[selected_model].mounts(selection.category)[selection.index];
    details_title->setText(manifest->getEntryName(entry));
    for (int n = 0; n < 3; n++)
    {
        details_axes[n]->setText(string(point[n], 3));
        details_axis_rows[n]->show();
    }
    details_hint->show();
}

void ModelEditorScreen::exportLua()
{
    if (selected_model < 0) return;
    const auto& model = models[selected_model];

    auto vec3Args = [](glm::vec3 v)
    {
        return formatNumber(v.x) + ", " + formatNumber(v.y) + ", " + formatNumber(v.z);
    };

    // Mount lines only, to paste over the existing ones in model_data.lua.
    string lua;
    for (const auto& point : model.beams)
        lua += "model:addBeamPosition(" + vec3Args(point) + ")\n";
    for (const auto& point : model.tubes)
        lua += "model:addTubePosition(" + vec3Args(point) + ")\n";
    for (size_t n = 0; n < model.engines.size(); n++)
    {
        const auto style = n < model.engine_styles.size() ? model.engine_styles[n] : ModelEditorModel::EngineStyle{};
        lua += "model:addEngineEmitter(" + vec3Args(model.engines[n]) + ",  " + vec3Args(style.color) + ", " + formatNumber(style.scale) + ")\n";
    }

    Clipboard::setClipboard(lua);
    LOG(Info, "Model editor export for ", model.name, ":\n", lua);
}

void ModelEditorScreen::commitAxis(int axis, const string& text)
{
    if (selected_model < 0 || selection.index < 0) return;
    auto& point = models[selected_model].mounts(selection.category)[selection.index];

    // Whole field must parse; "1.2x" or "" reverts instead of committing a prefix or 0.
    const char* begin = text.c_str();
    char* end = nullptr;
    const float value = std::strtof(begin, &end);
    while (*end == ' ' || *end == '\t') end++;
    if (end != begin && *end == '\0' && std::isfinite(value))
        point[axis] = value;

    details_axes[axis]->setText(string(point[axis], 3));
}

void ModelEditorScreen::setEditing(bool editing)
{
    if (editing && selected_model < 0) return;
    if (editing)
    {
        const auto& model = models[selected_model];
        edit_title->setText(model.name);

        // Indices are 0-based to match ShipTemplate:setBeamWeapon(index, ...).
        manifest->clear();
        manifest_mounts.clear();
        auto addEntries = [this, &model](MountCategory category, const string& label)
        {
            for (int n = 0; n < int(model.mounts(category).size()); n++)
            {
                manifest->addEntry(label + " " + string(n), label + " " + string(n));
                manifest_mounts.push_back({category, n});
            }
        };
        addEntries(MountCategory::Beam, "Beam");
        addEntries(MountCategory::Tube, "Tube");
        addEntries(MountCategory::Engine, "Engine");
    }
    setSelection({});
    browse_panel->setVisible(!editing);
    edit_panel->setVisible(editing);
    details_panel->setVisible(editing);
}
