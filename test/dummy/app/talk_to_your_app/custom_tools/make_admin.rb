# frozen_string_literal: true

# Custom MCP tool, exposed by the :custom_tools plugin as "custom.make_admin".
# Generated layout (rails g talk_to_your_app:custom_tool MakeAdmin); writes user state.
class MakeAdmin < TalkToYourApp::Tool
  name        "custom.make_admin"
  description "Grant admin to a user by id."
  argument    :user_id, :integer, required: true

  def call(args, _ctx)
    user = User.find_by(id: args[:user_id])
    return error("User #{args[:user_id]} not found") unless user

    user.update!(admin: true)
    json(id: user.id, name: user.name, admin: user.admin)
  end
end
