# Redmine - project management software
# Copyright (C) 2006-2011  Jean-Philippe Lang
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

class RbJournal < ActiveRecord::Base
  belongs_to :issue
  before_save :normalize
  after_initialize :denormalize

  private

  def normalize
    case self.value
      when true
        self.value = "true"
      when false
        self.value = "false"
      else
        self.value = self.value.to_s
    end
    self.property = self.property.to_s unless self.property.is_a?(String)
  end

  def denormalize
    self.property = self.property.intern unless self.property.is_a?(Symbol)

    return if self.value.nil?

    self.value = case self.property
      when :status_open, :status_success
        (self.value.downcase == 'true')
      when :fixed_version_id
        Integer(c.value)
      when :story_points, :remaining_hours
        Float(c.value)
      else
        raise "Unknown cache property #{property.inspect}"
    end
  end
end
