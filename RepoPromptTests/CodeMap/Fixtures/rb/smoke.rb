require "json"
require_relative "util"

MAX_USERS = 1000
$global_count = 0

class User
	DEFAULT_ROLE = "user"
	@@max_users = MAX_USERS

	def initialize(name)
		@name = name
	end

	def self.build(name)
		new(name)
	end
end

module Admin
	def self.role
		"admin"
	end
end

def top_level(x, y)
	x + y
end
