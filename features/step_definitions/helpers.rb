def get_project(identifier)
  Project.find(:first, :conditions => "identifier='#{identifier}'")
end

def time_offset(o)
  o = o.to_s.strip
  return nil if o == ''

  m = o.match(/^(-?)(([0-9]+)d)?(([0-9]+)h)?(([0-9]+)m)?$/)
  raise "Not a valid offset spec '#{o}'" unless m && o != '-'
  _, sign, _, d, _, h, _, m = m.to_a

  return ((((d.to_i * 24) + h.to_i) * 60) + m.to_i) * 60 * (sign == '-' ? -1 : 1)
end

def initialize_story_params
  @story = HashWithIndifferentAccess.new(RbStory.new.attributes)
  @story['project_id'] = @project.id
  @story['tracker_id'] = RbStory.trackers.first
  @story['author_id']  = @user.id
  @story
end

def initialize_task_params(story_id)
  params = HashWithIndifferentAccess.new(RbTask.new.attributes)
  params['project_id'] = @project.id
  params['tracker_id'] = RbTask.tracker
  params['author_id']  = @user.id
  params['parent_issue_id'] = story_id
  params['status_id'] = IssueStatus.find(:first).id
  params
end

def initialize_impediment_params(sprint_id)
  params = HashWithIndifferentAccess.new(RbTask.new.attributes)
  params['project_id'] = @project.id
  params['tracker_id'] = RbTask.tracker
  params['author_id']  = @user.id
  params['fixed_version_id'] = sprint_id
  params['status_id'] = IssueStatus.find(:first).id
  params
end

def initialize_sprint_params
  params = HashWithIndifferentAccess.new(RbSprint.new.attributes)
  params['project_id'] = @project.id
  params
end

def login(permissions)
  User.delete_all(:login => 'cucumber')
  Role.delete_all(:name => 'cucumber')

  @user = User.new
  @user.login = 'cucumber'
  @user.password = 'cucumber'
  @user.firstname = 'cucumber'
  @user.lastname = 'cucumber'
  @user.mail = 'cucumber@example.org'
  @user.save!

  role = Role.new(:name => 'cucumber')
  permissions.each{|p| role.permissions << p}
  role.save!

  member = Member.new(:user => @user, :project => @project)
  member.role_ids = [role.id]
  @project.members << member
  @project.save!

  visit url_for(:controller => 'account', :action=>'login')
  fill_in 'username', :with => 'cucumber'
  fill_in 'password', :with => 'cucumber'
  page.find(:xpath, '//input[@name="login"]').click
end

def task_position(task)
  p1 = task.story.tasks.select{|t| t.id == task.id}[0].rank
  p2 = task.rank
  p1.should == p2
  return p1
end

def story_position(story)
  p1 = RbStory.backlog(story.project, story.fixed_version_id).select{|s| s.id == story.id}[0].rank
  p2 = story.rank
  p1.should == p2

  RbStory.at_rank(story.project_id, story.fixed_version_id, p1).id.should == story.id
  return p1
end

def logout
  visit url_for(:controller => 'account', :action=>'logout')
  @user = nil
end

def show_table(title, header, data)
  fixed_sizes = header.collect{|h| h.is_a?(Array) ? h[1] : nil}

  dynamic_sizes = [0] * header.size
  data.each{|row|
    dynamic_sizes = row.collect{|v| v.to_s.length}.zip(dynamic_sizes).collect{|h| h.max}
  }
  sizes = fixed_sizes.zip(dynamic_sizes).collect{|s| s[0].nil? ? s[1] : s[0]}

  header = header.collect{|h| h.is_a?(Array) ? h[0] : h}
  header = header.zip(sizes).collect{|hs| hs[0].ljust(hs[1]) }

  puts "\n#{title}"
  puts "\t| #{header.join(' | ')} |"

  data.each {|row|
    row = row.zip(sizes).collect{|rs| rs[0].to_s[0,rs[1]].ljust(rs[1]) }
    puts "\t| #{row.join(' | ')} |"
  }

  puts "\n\n"
end

def story_before(pos)
  pos= pos.to_s

  if pos == '' # add to the bottom
    prev = Issue.find(:first, :conditions => ['not position is null'], :order => 'position desc')
    return prev ? prev.id : nil
  end

  pos = pos.to_i

  # add to the top
  return nil if pos == 1

  # position after
  stories = [] + Issue.find(:all, :order =>  'position asc')
  stories.size.should be > (pos - 2)
  return stories[pos - 2].id
end
