require 'httpclient'

class SlackListener < Redmine::Hook::Listener
    include ERB::Util  
    include GravatarHelper::PublicMethods

    ISSUE_STATUS_ASSIGNED = 2
    ISSUE_STATUS_CLOSED   = 5
    ISSUE_STATUS_REVIEW   = 8
    ISSUE_STATUS_TESTING  = 7
    ISSUE_STATUS_FEEDBACK = 4
    ISSUE_STATUS_ACCEPTED = 9

    @users_map            = nil
    @previous_assigned_to = nil
    @previous_status_id   = nil

    def controller_issues_new_after_save(context={})
        return #No creation notifications for now

        issue = context[:issue]

        channel = channel_for_project issue.project
        url = url_for_project issue.project

        return unless channel and url       

        msg = "[#{escape issue.project}] #{escape issue.author} created <#{object_url issue}|#{escape issue}>#{mentions issue.description}"

        attachment = {}
        attachment[:text] = escape issue.description if issue.description
        attachment[:fields] = [{
            :title => I18n.t("field_status"),
            :value => escape(issue.status.to_s),
            :short => true
        }, {
            :title => I18n.t("field_priority"),
            :value => escape(issue.priority.to_s),
            :short => true
        }, {
            :title => I18n.t("field_assigned_to"),
            :value => escape(issue.assigned_to.to_s),
            :short => true
        }]

        attachment[:fields] << {
            :title => I18n.t("field_watcher"),
            :value => escape(issue.watcher_users.join(', ')),
            :short => true
        } if Setting.plugin_redmine_slack[:display_watchers] == 'yes'

        speak msg, channel, attachment, url
    end  

    def controller_issues_edit_before_save(context={})
        issue = context[:issue]
        @previous_assigned_to = issue.assigned_to_was
        @previous_status_id   = issue.status_id_was
    end

    def controller_issues_edit_after_save(context={})
        issue = context[:issue]
        journal = context[:journal]

        channel = channel_for_project issue.project
        url = url_for_project issue.project

        return unless channel and url and Setting.plugin_redmine_slack[:post_updates] == '1'

        attachment, icon_emoji = prepare_progress_message(issue, journal)
        if !attachment.empty?
            speak "", channel, attachment, url, icon_emoji
        end

        attachment, icon_emoji = prepare_return_message(issue, journal)
        if !attachment.empty?
            speak "", channel, attachment, url, icon_emoji
        end

        attachment = prepare_assigned_change_message(issue, journal)
        if !attachment.empty?
            speak "", channel, attachment, url, ':you_dongler:'
        end

        attachment = prepare_details_change_message(issue, journal)
        if !attachment.empty?
            speak "", channel, attachment, url
        end    
    end

    def model_changeset_scan_commit_for_issue_ids_pre_issue_update(context={})
        issue = context[:issue]
        journal = issue.current_journal
        changeset = context[:changeset]

        channel = channel_for_project issue.project
        url = url_for_project issue.project

        return unless channel and url and issue.save

        repository = changeset.repository

        revision_url = Rails.application.routes.url_for(
            :controller => 'repositories',
            :action => 'revision',
            :id => repository.project,
            :repository_id => repository.identifier_param,
            :rev => changeset.revision,
            :host => Setting.host_name,
            :protocol => Setting.protocol
        )

        attachment = {}
        attachment[:text] = ll(Setting.default_language, :text_status_changed_by_changeset, "<#{revision_url}|#{escape changeset.comments}>")
        attachment[:fields] = journal.details.map { |d| detail_to_field d }.compact

        speak msg, channel, attachment, url
    end

    def speak(msg, channel, attachment={}, url=nil, icon_emoji=nil)
        url = Setting.plugin_redmine_slack[:slack_url] if not url
        username = Setting.plugin_redmine_slack[:username]
        icon = Setting.plugin_redmine_slack[:icon]

        params = {
            :text => msg,
            :link_names => 1,
        }

        params[:username] = username if username
        params[:channel] = channel if channel

        params[:attachments] = [attachment] if !attachment.empty?

        if icon and not icon.empty?
            if icon.start_with? ':'
                params[:icon_emoji] = icon
            else
                params[:icon_url] = icon
            end
        end

        params[:icon_emoji] = icon_emoji if icon_emoji

        client = HTTPClient.new
        client.ssl_config.cert_store.set_default_paths
        client.ssl_config.ssl_version = "SSLv23"
        client.post url, {:payload => params.to_json}
    end

private
    def get_users_map
        if @users_map.nil?
            users = User.sorted.active.preload(:preference)

            users_map = {}

            users.each do |u|
              slack_username = u.rslack_preference[:username]
              unless (slack_username == "")
                users_map[u.login] = slack_username
              else 
                users_map[u.login] = u.login.downcase
              end
            end

            @users_map = users_map
        end

        return @users_map
    end

    def get_avatar_url(email)
        return gravatar_url(email, {:size => 150})
    end

    def prepare_issue_description(issue)
        return {
            :title      => escape(issue),
            :title_link => object_url(issue),
            :text       => issue.description.truncate(230, separator: ' ')
        }
    end

    def prepare_progress_message(issue, journal)
        executor      = get_executor(issue)
        executor_mention = executor.nil? ? "" : '@' + get_slack_username(executor.login)
        msg = ""
        attachment = {}
        icon = nil
        icon_emoji = nil

        if !is_status_changed?(journal)             
            return attachment, icon_emoji
        end

        if !is_story(issue) && issue.status.id != SlackListener::ISSUE_STATUS_CLOSED
            return attachment, icon_emoji
        end      
        
        #Status changes
        icon_emoji = ':thumbsup_dongler:'

        if !is_story(issue) 
            if issue.status.id == SlackListener::ISSUE_STATUS_CLOSED 
                msg = "#{escape journal.user.to_s} has finished the task :sunglasses::sunglasses::sunglasses::"
                icon = get_avatar_url(journal.user.mail)
            end
        else 
            if (!executor.nil? && executor.id == journal.user.id && issue.status.id == SlackListener::ISSUE_STATUS_ASSIGNED)
                msg = "Hey guys, don't worry, #{escape journal.user.to_s} will take care of "
                icon_emoji = ':you_dongler:'
            end

            if (!executor.nil? && executor.id == journal.user.id && issue.status.id == SlackListener::ISSUE_STATUS_REVIEW)
                msg = "Hey guys, #{escape journal.user.to_s} claims, that this story is ready for Review! :innocent::innocent::innocent:"
            end

            if (!executor.nil? && executor.id != journal.user.id && issue.status.id == SlackListener::ISSUE_STATUS_TESTING)
                msg = "#{executor_mention}, good job! Your story just passed the Review! :thumbsup: Let's test it a little :smirk::smirk::smirk:"
            end

            if (!executor.nil? && executor.id != journal.user.id && issue.status.id == SlackListener::ISSUE_STATUS_FEEDBACK)
                msg = "#{executor_mention}, great, looks like you hid your bugs thoroughly! :ok_hand:"
            end

            if (!executor.nil? && executor.id != journal.user.id && issue.status.id == SlackListener::ISSUE_STATUS_ACCEPTED)
                msg = "#{executor_mention}, fantastic!!! Your story was just accepted! :tada::tada::tada: Mission accomplished :sunglasses::sunglasses::sunglasses:"
                msg += "\n@channel guys, thumbs up for the good boy!"
                icon_emoji = ':tada_dongler:'
            end

            if msg != "" 
                icon = get_avatar_url(executor.mail)
            end                
        end

        if msg != "" 
            attachment = prepare_issue_description(issue)
            attachment[:color] = "good"
            
            if (issue.assigned_to != nil && issue.assigned_to.id != journal.user.id) 
                assigned_user = "@" + get_slack_username(issue.assigned_to.login)
                msg += "\n#{assigned_user}, it's your turn now!"
            end

            attachment[:pretext] = msg
        end

        if !icon.nil?
            attachment[:thumb_url] = icon
        end

        return attachment, icon_emoji
    end

    def prepare_return_message(issue, journal)
        executor      = get_executor(issue)
        executor_mention = executor.nil? ? "" : '@' + get_slack_username(executor.login)
        msg        = ""
        attachment = {}
        icon       = nil
        icon_emoji = nil

        if is_status_changed?(journal) 
            return attachment, icon_emoji
        end

        if !is_assigned_user_changed?(journal)
            return attachment, icon_emoji
        end

        if issue.assigned_to == nil
            return attachment, icon_emoji
        end

        if executor.nil? || (executor.id != issue.assigned_to.id || issue.assigned_to.id == journal.user.id)
            return attachment, icon_emoji
        end
            
        assigned_user = "@" + get_slack_username(issue.assigned_to.login)
        msg = "#{assigned_user} Issue was returned :cry::cry::cry: to you (by #{escape journal.user.to_s})"
        icon = get_avatar_url(issue.assigned_to.mail)

        attachment = prepare_issue_description(issue)

        if issue.status.id == SlackListener::ISSUE_STATUS_FEEDBACK
            icon_emoji         = ':upset_dongler:'
            attachment[:color] = "danger"
        else 
            icon_emoji         = ':sad_dongler:'
            attachment[:color] = "warning"
        end

        attachment[:pretext] = msg

        if !icon.nil?
            attachment[:thumb_url] = icon
        end

        return attachment, icon_emoji
    end

    def prepare_assigned_change_message(issue, journal)
        executor   = get_executor(issue)
        msg        = ""
        attachment = {}
        icon       = nil

        if !is_story(issue)
            return attachment
        end

        if is_status_changed?(journal) 
            return attachment
        end       
        
        if !is_assigned_user_changed?(journal)
            return attachment
        end

        if issue.assigned_to == nil
            return attachment
        end

        if !executor.nil? && executor.id == issue.assigned_to.id && issue.assigned_to.id != journal.user.id
            return attachment
        end

        previous_owner = ""
        if !@previous_assigned_to.nil? && @previous_assigned_to.id != journal.user.id
            previous_owner = "@" + get_slack_username(@previous_assigned_to.login) + ", "
        end

        if (issue.assigned_to.id == journal.user.id)            
            msg  = "#{previous_owner}Story was captured by #{issue.assigned_to.to_s}"
            #icon = get_avatar_url(issue.assigned_to.mail)
        else
            assigned_user = "@" + get_slack_username(issue.assigned_to.login)
            msg  = "#{previous_owner}Issue was transferred to #{assigned_user} (by #{escape journal.user.to_s})"
        end

        attachment = prepare_issue_description(issue)
        attachment[:pretext] = msg

        if !icon.nil?
            attachment[:thumb_url] = icon
        end

        return attachment
    end

    def prepare_details_change_message(issue, journal)
        msg = ""
        attachment = {}
        icon = nil

        if !is_story(issue)
            return attachment
        end

        if is_status_changed?(journal) 
            return attachment
        end

        #Fields & comments changes
        fields = journal.details.map { |d| detail_to_field d }.compact

        if fields.empty? && journal.notes.empty?
           return attachment 
        end

        if !fields.empty?
            msg = "#{escape journal.user.to_s} updated <#{object_url issue}|#{escape issue}>"
        end

        if msg == "" && !journal.notes.empty?
            msg = "#{escape journal.user.to_s} commented on <#{object_url issue}|#{escape issue}>"
        end

        
        mention = ""

        if (!issue.assigned_to.nil? && issue.assigned_to.id != journal.user.id) 
            mention = "@" + get_slack_username(issue.assigned_to.login) + " "
        end

        executor      = get_executor(issue)

        if (!executor.nil? && executor.id != journal.user.id && (issue.assigned_to.nil? || issue.assigned_to.id != executor.id)) 
            mention = mention + "@" + get_slack_username(executor.login) + " "
        end

        msg = mention + msg

        msg += "#{mentions journal.notes}"
                        

        attachment[:pretext] = msg
        attachment[:thumb_url] = get_avatar_url(journal.user.mail)

        attachment[:text]    = escape journal.notes if !journal.notes.empty?
        attachment[:fields]  = fields if !fields.empty?      

        return attachment
    end

    def get_slack_username(username) 
        users_map = get_users_map()
        
        if users_map.key?(username)
            return users_map[username]
        else 
            return username.downcase
        end
    end

    def is_assigned_user_changed?(journal)
        return journal.details.any?{|item| 
            item.prop_key.to_s == "assigned_to_id"
        }
    end

    def is_status_changed?(journal)
        return journal.details.any?{|item| 
            item.prop_key.to_s == "status_id"
        }
    end

    def get_description(journal)
        return journal.details.find{|item| 
            item.prop_key.to_s == "description"
        }
    end

    def is_story(issue)
        return [1, 3, 4, 5].include?(issue.tracker.id)
    end

    def get_executor(issue)
        field_id = CustomField.where(:name => "Исполнитель").first.id
        value = issue.custom_value_for(field_id).value

        if !value.blank?
            value = User.find(value)
        else
            value = nil
        end
        
        return value        
    end

    def escape(msg)
        msg.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
    end

    def object_url(obj)
        Rails.application.routes.url_for(obj.event_url({:host => Setting.host_name, :protocol => Setting.protocol}))
    end

    def url_for_project(proj)
        return nil if proj.blank?

        cf = ProjectCustomField.find_by_name("Slack URL")

        return [
            (proj.custom_value_for(cf).value rescue nil),
            (url_for_project proj.parent),
            Setting.plugin_redmine_slack[:slack_url],
        ].find{|v| v.present?}
    end

    def channel_for_project(proj)
        return nil if proj.blank?

        cf = ProjectCustomField.find_by_name("Slack Channel")

        val = [
            (proj.custom_value_for(cf).value rescue nil),
            (channel_for_project proj.parent),
            Setting.plugin_redmine_slack[:channel],
        ].find{|v| v.present?}

        if val.to_s.starts_with? '#'
            val
        else
            nil
        end
    end

    def detail_to_field(detail)
        if detail.property == "cf"
            return
        elsif detail.property == "attachment"
            return
        else
            key = detail.prop_key.to_s.sub("_id", "")
            title = I18n.t "field_#{key}"
        end

        short = true
        value = escape detail.value.to_s

        case key
        when "title", "subject"
            short = false
        when "description"
            short = false
            value = value.truncate(230, separator: ' ')
        else
            return
        end

        value = "-" if value.empty?

        result = { :title => title, :value => value }
        result[:short] = true if short
        result
    end

    def mentions text
        text  = convert_usernames_to_slack text
        names = extract_usernames text
        names.present? ? "\nTo: @" + names.map(&:downcase).join(', @') : nil        
    end

    def convert_usernames_to_slack text
        users_map = get_users_map()

        text.gsub!(/(?<=@)[a-zA-Z0-9][a-zA-Z0-9_\-]*/) { |username| 
            if users_map.key?(username)
                users_map[username]
            else 
                username.downcase
            end
        }

        text
    end

    def extract_usernames text = ''
        # slack usernames may only contain lowercase letters, numbers,
        # dashes and underscores and must start with a letter or number.
        text.scan(/(?<=@)[a-zA-Z0-9][a-zA-Z0-9_\-]*/).uniq
    end


    def detail_to_field_full(detail)
        if detail.property == "cf"
            key = CustomField.find(detail.prop_key).name rescue nil
            title = key
        elsif detail.property == "attachment"
            key = "attachment"
            title = I18n.t :label_attachment
        else
            key = detail.prop_key.to_s.sub("_id", "")
            title = I18n.t "field_#{key}"
        end

        short = true
        value = escape detail.value.to_s

        case key
        when "title", "subject", "description"
            short = false
        when "tracker"
            tracker = Tracker.find(detail.value) rescue nil
            value = escape tracker.to_s
        when "project"
            project = Project.find(detail.value) rescue nil
            value = escape project.to_s
        when "status"
            status = IssueStatus.find(detail.value) rescue nil
            value = escape status.to_s
        when "priority"
            priority = IssuePriority.find(detail.value) rescue nil
            value = escape priority.to_s
        when "category"
            category = IssueCategory.find(detail.value) rescue nil
            value = escape category.to_s
        when "assigned_to"
            user = User.find(detail.value) rescue nil
            value = escape user.to_s
        when "fixed_version"
            version = Version.find(detail.value) rescue nil
            value = escape version.to_s
        when "attachment"
            attachment = Attachment.find(detail.prop_key) rescue nil
            value = "<#{object_url attachment}|#{escape attachment.filename}>" if attachment
        when "parent"
            issue = Issue.find(detail.value) rescue nil
            value = "<#{object_url issue}|#{escape issue}>" if issue
        end

        value = "-" if value.empty?

        result = { :title => title, :value => value }
        result[:short] = true if short
        result
    end
end
