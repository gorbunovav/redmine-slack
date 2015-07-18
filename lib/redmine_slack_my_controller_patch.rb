require_dependency 'my_controller'

module RedmineSlack
  module MyControllerPatch
    def self.included(base) # :nodoc:
      base.extend(ClassMethods)
      base.send(:include, InstanceMethods)

      base.class_eval do
        unloadable # Send unloadable so it will not be unloaded in development
        after_filter :save_slack_preferences, :only => [:account]
      end
    end

    module ClassMethods
    end

    module InstanceMethods
      def save_slack_preferences
        if request.post? && flash[:notice] == l(:notice_account_updated)
          unless params[:redmine_slack].nil?
            username  = params[:redmine_slack][:username].to_s
            User.current.rslack_preference[:username]  = username
          end
        end
      end
    end
  end
end

MyController.send(:include, RedmineSlack::MyControllerPatch) unless MyController.included_modules.include? RedmineSlack::MyControllerPatch
