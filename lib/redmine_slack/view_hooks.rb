module RedmineSlack
  module RedmineSlack
    class Hooks  < Redmine::Hook::ViewListener
      render_on(:view_my_account, :partial => 'hooks/slack_view_my_account')
      render_on(:view_users_form, :partial => 'hooks/slack_view_users_form')
    end
  end
end