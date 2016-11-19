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

    ISSUE_PRIORITY_NORMAL = 4
    ISSUE_PRIORITY_HIGH   = 5
    ISSUE_PRIORITY_URGENT = 6
    ISSUE_PRIORITY_IMMEDIATELY = 7

    ISSUE_HIGH_PRIORITIES = [
        SlackListener::ISSUE_PRIORITY_HIGH, 
        SlackListener::ISSUE_PRIORITY_URGENT, 
        SlackListener::ISSUE_PRIORITY_IMMEDIATELY
    ]

    MANAGER_USER = 3
    TESTER_USER  = 6

    PROGRESS_EVENT_TASK_CLOSED             = 'task_closed'
    PROGRESS_EVENT_STORY_CLAIMED           = 'story_claimed'
    PROGRESS_EVENT_STORY_READY_FOR_REVIEW  = 'story_ready_for_reivew'
    PROGRESS_EVENT_STORY_PASSED_THE_REVIEW = 'story_passed_the_reivew'
    PROGRESS_EVENT_STORY_PASSED_TESTING    = 'story_passed_testing'
    PROGRESS_EVENT_STORY_ACCEPTED          = 'story_accepted'

    @users_map            = nil
    @silent_update        = false
    @isReturn             = false
    @previous_assigned_to = nil
    @previous_status_id   = nil
    @previous_priority_id = nil
    @previous_returns_count = 0    

    def controller_issues_new_after_save(context={})
        issue = context[:issue]

        return unless SlackListener::ISSUE_HIGH_PRIORITIES.include?(issue.priority.id) #No creation notifications for now        

        channel = channel_for_project issue.project
        url = url_for_project issue.project

        return unless channel and url

        attachment = prepare_issue_description(issue)
        msg = '@channel: important issue was created!'
        speak msg, channel, attachment, url

        return

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
        @previous_priority_id = issue.priority_id_was
        @previous_returns_count = get_returns_count(issue)

        journal = context[:journal]

        isReturnField = get_isReturnField(issue)        

        @isReturn = false
        if !isReturnField.nil? && isReturnField.value.to_i == 1
            @isReturn = true
            isReturnField.value = 0
            incReturnsField(issue)
        end
        
        @silent_update = false
        if !journal.notes.empty? && journal.notes.start_with?("[silent-update]")
            @silent_update = true
            journal.notes.sub!(/^\[silent-update\]/, '')
        end
    end

    def controller_issues_edit_after_save(context={})
        issue = context[:issue]
        journal = context[:journal]    

        channel = channel_for_project issue.project
        url = url_for_project issue.project

        return unless channel and url and Setting.plugin_redmine_slack[:post_updates] == '1'

        progress_event = get_progress_event(issue, journal)

        if progress_event
            msg, attachment, icon_emoji = prepare_progress_message(issue, journal, progress_event)
            if !attachment.empty?
                speak msg, channel, attachment, url, icon_emoji
            end
        end

        msg, attachment, icon_emoji = prepare_return_message(issue, journal)
        if !attachment.empty?
            speak msg, channel, attachment, url, icon_emoji
        end

        msg, attachment = prepare_assigned_change_message(issue, journal)
        if !attachment.empty?
            speak msg, channel, attachment, url, ':you_dongler:'
        end

        msg, attachment = prepare_details_change_message(issue, journal)
        if !attachment.empty?
            speak msg, channel, attachment, url
        end

        msg, attachment = prepare_priority_change_message(issue, journal)
        if !attachment.empty?
            speak msg, channel, attachment, url
        end

        if progress_event && progress_event == SlackListener::PROGRESS_EVENT_STORY_READY_FOR_REVIEW
            executor      = get_executor(issue)
            executor_mention = executor.nil? ? "" : '@' + get_slack_username(executor.login)

            msg = build_review_list(issue)
            if !msg.empty?
                speak msg, executor_mention, {}, url
            end

            msg = build_assigned_list(issue)
            if !msg.empty?
                speak msg, executor_mention, {}, url
            end
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

    def get_progress_event(issue, journal)
        executor      = get_executor(issue)

        if !is_status_changed?(journal)             
            return false
        end

        if !is_story(issue) && issue.status.id != SlackListener::ISSUE_STATUS_CLOSED
            return false
        end      

        #Status changes
        if !is_story(issue) 
            if issue.status.id == SlackListener::ISSUE_STATUS_CLOSED 
                return SlackListener::PROGRESS_EVENT_TASK_CLOSED
            end
        else 
            if (!executor.nil? && executor.id == journal.user.id && issue.status.id == SlackListener::ISSUE_STATUS_ASSIGNED)
                return SlackListener::PROGRESS_EVENT_STORY_CLAIMED
            end

            if (!executor.nil? && executor.id == journal.user.id && issue.status.id == SlackListener::ISSUE_STATUS_REVIEW)
                return SlackListener::PROGRESS_EVENT_STORY_READY_FOR_REVIEW
            end

            if (!executor.nil? && executor.id != journal.user.id && issue.status.id == SlackListener::ISSUE_STATUS_TESTING)
                return SlackListener::PROGRESS_EVENT_STORY_PASSED_THE_REVIEW
            end

            if (!executor.nil? && executor.id != journal.user.id && issue.status.id == SlackListener::ISSUE_STATUS_FEEDBACK)
                return SlackListener::PROGRESS_EVENT_STORY_PASSED_TESTING
            end

            if (!executor.nil? && executor.id != journal.user.id && issue.status.id == SlackListener::ISSUE_STATUS_ACCEPTED)
                return SlackListener::PROGRESS_EVENT_STORY_ACCEPTED
            end
        end

        return false
    end

    def prepare_issue_description(issue)
        attachment = {
            :title      => escape(issue),
            :title_link => object_url(issue),
            :text       => issue.description.nil? ? "" : escape(issue.description.delete("\r\n").truncate(230, separator: ' ')),
            :fields     => []
        }

        if issue.priority.id != SlackListener::ISSUE_PRIORITY_NORMAL
            attachment[:fields].push({
                :title => 'Priority',
                :value => escape(issue.priority.to_s),
                :short => true
            })
        end

        returns_count = get_returns_count(issue)
        if returns_count > 0
            attachment[:fields].push({
                :title => 'Returns count',
                :value => escape(returns_count.to_s),
                :short => true
            })
        end        

        return attachment
    end

    def prepare_progress_message(issue, journal, progress_event)
        executor      = get_executor(issue)
        executor_mention = executor.nil? ? "" : '@' + get_slack_username(executor.login)
        msg = ""
        attachment = {}
        icon = nil

        #Status changes
        icon_emoji = ':thumbsup_dongler:'
        
        if progress_event == SlackListener::PROGRESS_EVENT_TASK_CLOSED 
            msg = "#{escape journal.user.to_s} has finished the task :sunglasses::sunglasses::sunglasses::"
            icon = get_avatar_url(journal.user.mail)
        end

        if progress_event == SlackListener::PROGRESS_EVENT_STORY_CLAIMED 
            msg = "Hey guys, don't worry, #{escape journal.user.to_s} will take care of "
            icon_emoji = ':you_dongler:'
        end

        if progress_event == SlackListener::PROGRESS_EVENT_STORY_READY_FOR_REVIEW 
            msg = "Hey guys, #{escape journal.user.to_s} claims, that this story is ready for Review! :innocent::innocent::innocent:"
            msg += " :shamrock: @#{get_slack_username journal.user.login}++"
        end

        if progress_event == SlackListener::PROGRESS_EVENT_STORY_PASSED_THE_REVIEW 
            msg = "#{executor_mention}, good job! Your story just passed the Review! :thumbsup: Let's test it a little :smirk::smirk::smirk:"
            msg += " :shamrock: #{executor_mention}++"
        end

        if progress_event == SlackListener::PROGRESS_EVENT_STORY_PASSED_TESTING 
            msg = "#{executor_mention}, great, looks like you hid your bugs thoroughly! :ok_hand:"
            msg += " :shamrock: #{executor_mention}++"
        end

        if progress_event == SlackListener::PROGRESS_EVENT_STORY_ACCEPTED 
            msg = "#{executor_mention}, fantastic!!! Your story was just accepted! :tada::tada::tada: Mission accomplished :sunglasses::sunglasses::sunglasses:"
            msg += " @channel guys, thumbs up for the good boy!"

            returns_count = get_returns_count(issue)
            bonus = 5               
            bonus = 2 if returns_count > 0

            karmaMsg  = " :shamrock: #{executor_mention}++#{bonus}"
            
            reviewer  = get_reviewer(issue)                        
            karmaMsg += " :shamrock: @#{get_slack_username reviewer.login}++" if !reviewer.nil?
            
            tester      = get_tester(issue)
            karmaMsg += " :shamrock: @#{get_slack_username tester.login}++"
            
            msg += karmaMsg            

            icon_emoji = ':tada_dongler:'
        end

        if msg != ""  && !executor.nil?
            icon = get_avatar_url(executor.mail)
        end                
        

        if msg != "" 
            attachment = prepare_issue_description(issue)
            attachment[:color] = "good"
            
            if (issue.assigned_to != nil && issue.assigned_to.id != journal.user.id) 
                assigned_user = "@" + get_slack_username(issue.assigned_to.login)
                msg += " #{assigned_user}, it's your turn now!"
            end

            #attachment[:pretext] = msg
        end

        if !icon.nil?
            attachment[:thumb_url] = icon
        end

        return msg, attachment, icon_emoji
    end

    def prepare_return_message(issue, journal)
        executor      = get_executor(issue)
        executor_mention = executor.nil? ? "" : '@' + get_slack_username(executor.login)
        msg        = ""
        attachment = {}
        icon       = nil
        icon_emoji = nil

        if is_status_changed?(journal) 
            return msg, attachment, icon_emoji
        end

        if !is_assigned_user_changed?(journal)
            return msg, attachment, icon_emoji
        end

        if issue.assigned_to == nil
            return msg, attachment, icon_emoji
        end

        if executor.nil? || (executor.id != issue.assigned_to.id || issue.assigned_to.id == journal.user.id)
            return msg, attachment, icon_emoji
        end

        returns_count = get_returns_count(issue)

        if !@isReturn
            return msg, attachment, icon_emoji
        end
            
        assigned_user = "@" + get_slack_username(issue.assigned_to.login)
        msg = "#{assigned_user} Issue was returned :cry::cry::cry: to you (by #{escape journal.user.to_s})"
        icon = get_avatar_url(issue.assigned_to.mail)

        attachment = prepare_issue_description(issue)

        penalty=""        
        penalty = returns_count if returns_count > 0

        karmaMsg = " :japanese_ogre: #{assigned_user}--#{penalty}"

        if issue.status.id == SlackListener::ISSUE_STATUS_FEEDBACK
            icon_emoji         = ':upset_dongler:'
            attachment[:color] = "danger"
                        
            reviewer    = get_reviewer(issue)
            karmaMsg += " :japanese_ogre: @#{get_slack_username reviewer.login}--" if !reviewer.nil?

            if journal.user.id != SlackListener::MANAGER_USER                
                tester      = get_tester(issue)
                karmaMsg += " :japanese_ogre: @#{get_slack_username tester.login}--"
                
                manager     = get_manager(issue)
                karmaMsg += " :japanese_ogre: @#{get_slack_username manager.login}--"
            end
        else
            icon_emoji         = ':sad_dongler:'
            attachment[:color] = "warning"
        end

        msg += karmaMsg

        #attachment[:pretext] = msg

        if !icon.nil?
            attachment[:thumb_url] = icon
        end

        return msg, attachment, icon_emoji
    end

    def prepare_assigned_change_message(issue, journal)
        executor   = get_executor(issue)
        msg        = ""
        attachment = {}
        icon       = nil

        if !is_story(issue)
            return msg, attachment
        end

        if is_status_changed?(journal) 
            return msg, attachment
        end       
        
        if !is_assigned_user_changed?(journal)
            return msg, attachment
        end

        if issue.assigned_to == nil
            return msg, attachment
        end

        returns_count = get_returns_count(issue)

        if !executor.nil? && executor.id == issue.assigned_to.id && issue.assigned_to.id != journal.user.id && @isReturn
            return msg, attachment
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
        #attachment[:pretext] = msg

        if !icon.nil?
            attachment[:thumb_url] = icon
        end

        return msg, attachment
    end

    def prepare_details_change_message(issue, journal)
        msg = ""
        attachment = {}
        icon = nil

        if !is_story(issue)
            return msg, attachment
        end

        if is_status_changed?(journal) 
            return msg, attachment
        end

        #Fields & comments changes
        fields = journal.details.map { |d| detail_to_field d }.compact

        if fields.empty? && (journal.notes.empty? || @silent_update)
           return msg, attachment 
        end

        if !fields.empty?
            msg = "#{escape journal.user.to_s} updated <#{object_url issue}|#{escape issue}>"
        end

        if msg == "" && !journal.notes.empty? && !@silent_update
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

        #msg += "#{mentions journal.notes}"
        comment = convert_usernames_to_slack(journal.notes)
                        

        #attachment[:pretext] = msg
        attachment[:thumb_url] = get_avatar_url(journal.user.mail)

        attachment[:text]    = escape comment if !comment.empty?
        attachment[:fields]  = fields if !fields.empty?      

        return msg, attachment
    end

    def prepare_priority_change_message(issue, journal)
        msg = ''
        attachment = {}

        if (@previous_priority_id == issue.priority_id)
            return msg, attachment
        end        

        issueWasImportant   = SlackListener::ISSUE_HIGH_PRIORITIES.include?(@previous_priority_id)
        issueIsImportantNow = SlackListener::ISSUE_HIGH_PRIORITIES.include?(issue.priority_id)
        
        if !issueWasImportant && issueIsImportantNow
            msg = '@channel: issue priority has been raised!'
            attachment = prepare_issue_description(issue)
        end

        return msg, attachment
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

    def get_isReturnField(issue)
        issue.custom_field_values.each do |field|
          if field.custom_field.name == "Is return"
            return field
          end
        end

        return nil
    end

    def incReturnsField(issue)
        issue.custom_field_values.each do |field|
          if field.custom_field.name == "Returns count"
            field.value = field.value.to_i + 1
            return
          end
        end
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

    def get_reviewer(issue)
        field_id = CustomField.where(:name => "Ревьюер").first.id
        value = issue.custom_value_for(field_id).value

        if !value.blank?
            value = User.find(value)
        else
            value = nil
        end
        
        return value        
    end

    def get_tester(issue)
        value = SlackListener::TESTER_USER
        value = User.find(value)
        
        return value        
    end

    def get_manager(issue)
        value = SlackListener::MANAGER_USER
        value = User.find(value)
        
        return value        
    end


    def get_returns_count(issue)
        field_id = CustomField.where(:name => "Returns count").first.id
        valueObject = issue.custom_value_for(field_id)
        value = 0
        value = valueObject.value.to_i if !valueObject.nil?

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
        when "priority"
            priority = IssuePriority.find(detail.value) rescue nil
            value = escape priority.to_s
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

        text = text.gsub(/(?<=@)[a-zA-Z0-9][a-zA-Z0-9_\-]*/) { |username| 
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

    def format_issue_for_list(issue)
        return "• #{issue.project.name} - <#{object_url issue}|#{issue.tracker.name} ##{issue.id}: #{issue.subject}> (#{issue.status.name}) [#{issue.priority.name}]"
    end

    def build_review_list(issue)
        reviewList = "The following tasks are waiting for review:\r\n"

        issues = get_issues_for_review()
        if issues.empty? 
            return ''
        end

        issues.collect!{|issue|
            format_issue_for_list(issue)
        }

        reviewList += issues.join("\r\n")

        return reviewList
    end

    def get_issues_for_review
        ir_query = IssueQuery.find(8)
        issues = ir_query.issues
        issues
    end

    def build_assigned_list(issue)
        assignedList = "The following tasks are waiting for your attention:\r\n"

        issues = get_assigned_issues()        
        if issues.empty?
            return ''
        end

        issues.collect!{|issue|
            format_issue_for_list(issue)
        }

        assignedList += issues.join("\r\n")

        return assignedList
    end

    def get_assigned_issues
        ir_query = IssueQuery.find(4)
        issues = ir_query.issues[0..9]
        if issues.empty? 
            return ''
        end

        issues
    end

end
