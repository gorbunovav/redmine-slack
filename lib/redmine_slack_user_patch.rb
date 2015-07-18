require_dependency 'user'

module RedmineSlack
  class Preference
    def initialize(user)
      @user = user
      @prefs = {}
    end

    def []=(attr, value)
      prefixed = "rslack_#{attr}".intern

      case attr
        when :username
          value = value.to_s.strip
        else
          raise "Unsupported attribute '#{attr}'"
      end

      @user.pref[prefixed] = value
      @prefs[prefixed] = value
      @user.pref.save!
    end

    def [](attr)
      prefixed = "rslack_#{attr}".intern

      unless @prefs.include?(prefixed)
        value = @user.pref[prefixed].to_s.strip

        case attr
          when :username
            if value == '' # assign default
              self[attr] = value
            end
          else
            raise "Unsupported attribute '#{attr}'"
        end

        @prefs[prefixed] = value
      end

      return @prefs[prefixed]
    end
  end

  module UserPatch
    def self.included(base) # :nodoc:
      base.extend(ClassMethods)
      base.send(:include, InstanceMethods)
    end

    module ClassMethods
    end

    module InstanceMethods

      def rslack_preference
        @rslack_preference ||= Preference.new(self)
      end

    end
  end
end

User.send(:include, RedmineSlack::UserPatch) unless User.included_modules.include? RedmineSlack::UserPatch
