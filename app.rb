require 'dotenv/load'
require 'octokit'
require_relative 'lib/cached_octokit'
require 'tqdm'
require 'set'

require 'awesome_print'

Octokit.configure do |config|
  config.login = ENV.fetch('GITHUB__LOGIN_NAME')
  config.password = ENV.fetch('GITHUB__PERSONAL_TOKEN')
  config.auto_paginate = true
end

octokit = CachedOctokit.new(Octokit, moneta: [:GDBM, file: 'octokit_cache.gdb'])

puts 'Fetching org...'
org = octokit.org('promptworks')

if org.default_repository_permission != 'write'
  raise 'This script currently assumes that `write` is the default permission of members'
end
default_org_member_repo_permissions = { admin: false, push: true, pull: true }

puts 'Fetching repos...'
repos = octokit.org_repos('promptworks', type: 'private')

puts 'Fetching org members...'
org_members = octokit.org_members('promptworks')
org_member_logins = org_members.map(&:login).to_set

puts 'Fetching collaborators...'
raw_collaborations = repos.each.with_progress.map do |repo|
  [repo.full_name, octokit.collaborators(repo.full_name)]
end

collaborations = raw_collaborations.map do |repo_full_name, collabs|
  filtered_collabs = collabs.reject do |collab|
    org_member_logins.include?(collab.login) && collab.permissions.to_hash == default_org_member_repo_permissions
  end

  [repo_full_name, filtered_collabs]
end.to_h

all_collaborators = collaborations.flat_map(&:last).uniq(&:login)

puts 'Fetching teams...'
teams_per_repo = repos.each.with_progress.map do |repo|
  [repo.full_name, octokit.repo_teams(repo.full_name)]
end.to_h

all_teams = teams_per_repo.flat_map(&:last).uniq(&:id)

puts 'Fetching team members...'
members_per_team = all_teams.each.with_progress.map do |team|
  [team, octokit.team_members(team.id)]
end.to_h

puts 'Fetching user info...'
users = all_collaborators.each.with_progress.map do |collaborator|
  octokit.user(collaborator.login)
end

teams_per_user_login = members_per_team.each_with_object(Hash.new{|hash, key| hash[key] = []}) do |(team, members), hash|
  members.each do |member|
    hash[member.login] << team
  end
end

users_by_login = users.map { |user| [user.login, user] }.to_h

require 'ostruct'
template_helpers_and_data = OpenStruct.new(
  org: org,
  repos: repos,
  org_members: org_members,
  collaborations: collaborations,
  users: users,
  users_by_login: users_by_login,
  teams_per_repo: teams_per_repo,
  teams_per_user_login: teams_per_user_login,
)

template_helpers_and_data.instance_eval do
  def permission_details(permission)
    case permission.to_s
    when 'admin' then { label: 'label-danger',  order: 0 }
    when 'push'  then { label: 'label-warning', order: 1 }
    when 'pull'  then { label: 'label-info',    order: 2 }
    else raise "Don't know permission #{permission.inspect}"
    end
  end

  def label_for_permission(permission)
    permission_details(permission).fetch(:label)
  end

  def order_for_permission(permission)
    permission_details(permission).fetch(:order)
  end
end

require 'slim'
template = Slim::Template.new('index.html.slim')
path = '/tmp/github-audit.html'
File.open(path, 'w') { |f| f.print template.render(template_helpers_and_data) }
`open #{path}`

require 'pry'; binding.pry
