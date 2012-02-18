require_dependency 'issue'

module Backlogs
  module IssuePatch
    def self.included(base) # :nodoc:
      base.extend(ClassMethods)
      base.send(:include, InstanceMethods)

      base.class_eval do
        unloadable

        alias_method_chain :move_to_project_without_transaction, :autolink

        before_save :backlogs_before_save
        after_save  :backlogs_after_save
        after_destroy :backlogs_after_destroy
      end
    end

    module ClassMethods
    end

    module InstanceMethods
      def move_to_project_without_transaction_with_autolink(new_project, new_tracker = nil, options = {})
        newissue = move_to_project_without_transaction_without_autolink(new_project, new_tracker, options)
        return newissue if newissue.blank? || !self.project.module_enabled?('backlogs')

        if project_id == newissue.project_id and is_story? and newissue.is_story? and id != newissue.id
          relation = IssueRelation.new :relation_type => IssueRelation::TYPE_DUPLICATES
          relation.issue_from = self
          relation.issue_to = newissue
          relation.save
        end

        return newissue
      end

      def journalized_update_attributes!(attribs)
        init_journal(User.current)
        return update_attributes!(attribs)
      end

      def journalized_update_attributes(attribs)
        init_journal(User.current)
        return update_attributes(attribs)
      end

      def journalized_update_attribute(attrib, v)
        init_journal(User.current)
        update_attribute(attrib, v)
      end

      def is_story?
        return RbStory.trackers.include?(tracker_id)
      end

      def is_task?
        return (tracker_id == RbTask.tracker)
      end

      def story
        if @rb_story.nil?
          if self.new_record?
            parent_id = self.parent_id
            parent_id = self.parent_issue_id if parent_id.blank?
            parent_id = nil if parent_id.blank?
            parent = parent_id ? Issue.find(parent_id) : nil

            if parent.nil?
              @rb_story = nil
            elsif parent.is_story?
              @rb_story = parent.becomes(RbStory)
            else
              @rb_story = parent.story
            end
          else
            @rb_story = Issue.find(:first, :order => 'lft DESC', :conditions => [ "root_id = ? and lft < ? and rgt > ? and tracker_id in (?)", root_id, lft, rgt, RbStory.trackers ])
            @rb_story = @rb_story.becomes(RbStory) if @rb_story
          end
        end
        return @rb_story
      end

      def blocks
        # return issues that I block that aren't closed
        return [] if closed?
        relations_from.collect {|ir| ir.relation_type == 'blocks' && !ir.issue_to.closed? ? ir.issue_to : nil}.compact
      end

      def blockers
        # return issues that block me
        return [] if closed?
        relations_to.collect {|ir| ir.relation_type == 'blocks' && !ir.issue_from.closed? ? ir.issue_from : nil}.compact
      end

      def velocity_based_estimate
        return nil if !self.is_story? || ! self.story_points || self.story_points <= 0

        hpp = self.project.scrum_statistics.hours_per_point
        return nil if ! hpp

        return Integer(self.story_points * (hpp / 8))
      end

      def backlogs_before_save
        if project.module_enabled?('backlogs') && (self.is_task? || self.story)
          self.remaining_hours ||= self.estimated_hours
          self.estimated_hours ||= self.remaining_hours

          self.remaining_hours = 0 if self.status.backlog_is?(:success)

          self.position = nil
          self.fixed_version_id = self.story.fixed_version_id if self.story
          self.tracker_id = RbTask.tracker
          self.start_date = Date.today if self.start_date.nil? && self.status_id != IssueStatus.default.id
        elsif self.is_story?
          self.remaining_hours = self.leaves.sum("COALESCE(remaining_hours, 0)").to_f
        end

        return true
      end

      def backlogs_after_save
        ## automatically sets the tracker to the task tracker for
        ## any descendant of story, and follow the version_id
        ## Normally one of the _before_save hooks ought to take
        ## care of this, but appearantly neither root_id nor
        ## parent_id are set at that point

        return unless self.project.module_enabled? 'backlogs'

        if self.is_story?
          # raw sql and manual journal here because not
          # doing so causes an update loop when Issue calls
          # update_parent :<
          Issue.find(:all, :conditions => ["root_id=? and lft>? and rgt<? and
                                          (
                                            (? is NULL and not fixed_version_id is NULL)
                                            or
                                            (not ? is NULL and fixed_version_id is NULL)
                                            or
                                            (not ? is NULL and not fixed_version_id is NULL and ?<>fixed_version_id)
                                          )", root_id, lft, rgt, fixed_version_id, fixed_version_id, fixed_version_id, fixed_version_id]).each{|task|
            j = Journal.new
            j.journalized = task
            case Backlogs.platform 
              when :redmine
                j.created_on = Time.now
                j.details << JournalDetail.new(:property => 'attr', :prop_key => 'fixed_version_id', :old_value => task.fixed_version_id, :value => fixed_version_id)
              when :chiliproject
                j.created_at = Time.now
                j.details = {'fixed_version_id' => [task.fixed_version_id, fixed_version_id]}
            end
            j.user = User.current
            j.save!
          }

          connection.execute("update issues set tracker_id = #{RbTask.tracker}, fixed_version_id = #{connection.quote(fixed_version_id)} where root_id = #{self.root_id} and lft > #{self.lft} and rgt < #{self.rgt}")

          # safe to do by sql since we don't want any of this logged
          unless self.position
            max = 0
            connection.execute('select max(position) from issues where not position is null').each {|i| max = i[0] }
            connection.execute("update issues set position = #{connection.quote(max)} + 1 where id = #{id}")
          end
        end

        if self.story || self.is_task?
          connection.execute("update issues set tracker_id = #{RbTask.tracker} where root_id = #{self.root_id} and lft >= #{self.lft} and rgt <= #{self.rgt}")
        end
      end

      def backlogs_after_destroy
        return if self.position.nil?
        Issue.connection.execute("update issues set position = position - 1 where position > #{self.position}")
      end

      def value_at(property, time)
        return history(property, [time.to_date])[0]
      end

      def history(property, days)
        days = days.to_a
        created_day = created_on.to_date
        active_days = days.select{|d| d >= created_day}

        # if not active, don't do anything
        return [nil] * (days.size + 1) if active_days.size == 0

        # anything before the creation date is nil
        prefix = [nil] * (days.size - active_days.size)

        # add one extra day as end-of-last-day
        active_days << (active_days[-1] + 1)

        if !RbJournal.exists?(:issue_id => self.id, :property => property, :start_time => self.created_on) || !RbJournal.exists?(:issue_id => self.id, :property => property, :end_time => self.updated_on)
          prop = [:status_success, :status_open].include?(property) ? :status_id : property

          case Backlogs.platform
            when :redmine
              changes = JournalDetail.find(:all, :order => "journals.created_on asc" , :joins => :journal,
                                                 :conditions => ["property = 'attr' and prop_key = ?
                                                      and journalized_type = 'Issue' and journalized_id = ?",
                                                      prop.to_s, self.id]).collect {|detail|
                {:time => detail.journal.created_on, :old => detail.old_value, :new => detail.value}
              }
              
            when :chiliproject
              # the chiliproject changelog is screwed up beyond all reckoning...
              # a truly horrid journals design -- worse than RMs, and that takes some doing
              # I know this should be using activerecord introspection, but someone else will have to go
              # rummaging through the docs for self.class.reflect_on_association et al.
              table = case prop
                when :status_id then 'issue_statuses'
                else nil
              end

              valid_ids = table ? RbStory.connection.select_values("select id from #{table}").collect{|x| x.to_i} : nil
              changes = self.journals.reject{|j| j.created_at < self.created_on || j.changes[property_s].nil?}.collect{|j|
                delta = valid_ids ? j.changes[property_s].collect{|v| valid_ids.include?(v) ? v : nil} : j.changes[property_s]
                {:time => j.created_at, :old => delta[0], :new => delta[1]}
              }
          end

          issue_status = {}
          if [:status_success, :status_open].include?(property)
            changes.each{|change|
              [:old, :new].each{|k|
                status_id = change[k]
                next if status_id.nil?

                if issue_status[status_id].nil?
                  case property
                    when :status_open
                      issue_status[status_id] = !(IssueStatus.find(status_id).is_closed?)
                    when :status_success
                      issue_status[status_id] = !!(IssueStatus.find(status_id).backlog_is?(:success))
                  end
                end

                change[k] = issue_status[status_id]
              }
            }
          end

          RbJournal.destroy_all(:issue_id => self.id, :property => property)

          changes.each_with_index{|change, i|
            j = RbJournal.new(:issue_id => self.id, :property => property, :value => change[:old])

            if i == 0
              j.start_time = self.created_on
            else
              j.start_time = changes[i-1][:time]
            end

            if i == changes.size - 1
              j.end_time = self.updated_on
            else
              j.end_time = change[:time]
            end

            j.save
          }
        end

        changes = RbJournal.find(:all,
                    :conditions => ['issue_id = ? and property = ? and (start_time between ? and ? or end_time between ? and ?)',
                                    self.id, property, active_days[0].to_time, active_days[-1].to_time, active_days[0].to_time, active_days[-1].to_time],
                    :order => 'start_time')

        current_value = case property
          when :status_open
            !self.status.is_closed?
          when :status_success
            self.status.backlog_is?(:success)
          else
            self.send(property)
          end

        values = [(changes.size > 0 ? changes[0].value : current_value)] * active_days.size

        changes.each{|change|
          day = active_days.index{|d| d.to_time >= change.start_time}
          next unless day.nil?
          values.fill(change.value, day)
        }

        # ignore the start-of-day value for issues created mid-sprint
        values[0] = nil if created_day > days[0]

        return prefix + values
      end

    end
  end
end

Issue.send(:include, Backlogs::IssuePatch) unless Issue.included_modules.include? Backlogs::IssuePatch
