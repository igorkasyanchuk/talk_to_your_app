# frozen_string_literal: true

# Custom MCP tool, exposed by the :custom_tools plugin as "custom.toggle_active".
# Generated layout (rails g talk_to_your_app:custom_tool ToggleActive); writes user state.
class ToggleActive < TalkToYourApp::Tool
  name        "custom.toggle_active"
  description "Toggle a user's active flag by id."
  argument    :user_id, :integer, required: true

  def call(args, _ctx)
    user = User.find_by(id: args[:user_id])
    return error("User #{args[:user_id]} not found") unless user

    user.update!(active: !user.active)
    json(id: user.id, name: user.name, active: user.active)
  end
end
