require_dependency 'users_controller'

module RedmineSlack
  module UsersControllerPatch
    def self.included(base) # :nodoc:
      base.extend(ClassMethods)
      base.send(:include, InstanceMethods)

      base.class_eval do
        unloadable # Send unloadable so it will not be unloaded in development
        alias_method_chain :create, :slack
        alias_method_chain :update, :slack

        #after_filter :save_slack_preferences, :only => [:edit]
      end
    end

    module ClassMethods
    end

    module InstanceMethods
      def create_with_slack
        create_without_slack
        unless @user.id.nil? 
          unless params[:redmine_slack].nil?
            username  = params[:redmine_slack][:username].to_s
            @user.rslack_preference[:username]  = username
            @user.pref.save 
          end         
        end 
      end

      def update_with_slack
        update_without_slack
          unless params[:redmine_slack].nil?
            username  = params[:redmine_slack][:username].to_s
            @user.rslack_preference[:username]  = username
            @user.pref.save 
        end 
      end
    end
  end
end

UsersController.send(:include, RedmineSlack::UsersControllerPatch) unless UsersController.included_modules.include? RedmineSlack::UsersControllerPatch
