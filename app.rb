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

admin_logins = ENV.fetch('APP__ADMINS', '').split(/\s*,\s*/).to_set
org_id = ENV.fetch('GITHUB__ORG_ID')

puts 'Fetching org...'
org = octokit.org(org_id)

default_org_member_repo_permissions = case org.default_repository_permission
                                      when 'admin' then { admin: true, push: true, pull: true }
                                      when 'write' then { admin: false, push: true, pull: true }
                                      when 'read'  then { admin: false, push: false, pull: true }
                                      when 'none'  then { admin: false, push: false, pull: false }
                                      else raise "I don't understand #{org.default_repository_permission.inspect}"
                                      end

puts 'Fetching teams...'
org_teams = octokit.org_teams(org_id)

puts 'Fetching repos...'
repos = octokit.org_repos(org_id, type: 'private')

puts 'Fetching org members...'
org_members = octokit.org_members(org_id)
org_member_logins = org_members.map(&:login).to_set

puts 'Fetching collaborators...'
raw_collaborations = repos.each.with_progress.map do |repo|
  [repo.full_name, octokit.collaborators(repo.full_name)]
end

is_legitimate_admin = -> (collab) do
  admin_logins.include?(collab.login) && collab.permissions[:admin]
end

is_org_member_with_default_permissions = -> (collab) do
  org_member_logins.include?(collab.login) &&
    collab.permissions.to_hash == default_org_member_repo_permissions
end

collaborations = raw_collaborations.map do |repo_full_name, collabs|
  unexpected_collabs = collabs.reject do |collab|
    is_legitimate_admin.(collab) || is_org_member_with_default_permissions.(collab)
  end

  [repo_full_name, unexpected_collabs]
end.to_h

puts 'Fetching teams...'
teams_per_repo = repos.each.with_progress.map do |repo|
  [repo.full_name, octokit.repo_teams(repo.full_name)]
end.to_h

puts 'Fetching team members...'
members_per_team = org_teams.each.with_progress.map do |team|
  [team, octokit.team_members(team.id)]
end.to_h

puts 'Fetching user info...'
loginables = raw_collaborations.flat_map(&:last) + org_members + members_per_team.flat_map(&:last)
users = loginables.map(&:login).uniq.each.with_progress.map do |login|
  octokit.user(login)
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
  org_teams: org_teams,
  repos: repos,
  org_members: org_members,
  collaborations: collaborations,
  users: users,
  users_by_login: users_by_login,
  teams_per_repo: teams_per_repo,
  teams_per_user_login: teams_per_user_login,
  admin_logins: admin_logins,
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

  def teams_for_repo(repo)
    teams_per_repo[repo.full_name].sort_by{|team| order_for_permission(team.permission) }
  end

  def teams_for_user_on_repo(user, repo)
    repo_team_ids = teams_for_repo(repo).map(&:id).to_set

    teams_per_user_login[user.login].select do |team|
      repo_team_ids.include? team.id
    end
  end

  def url_repo_collaboration(repo)
    "#{repo.html_url}/settings/collaboration"
  end

  def url_org_team(team)
    "https://github.com/orgs/#{org.login}/teams/#{team.slug}"
  end

  def url_org_people
    "https://github.com/orgs/#{org.login}/people"
  end

  Issue = Struct.new :type_name, :title, :body do
    def body_html
      "<pre>#{body}</pre>"
    end
  end

  def teams_for_user_in_org(user)
    teams_per_user_login[user.login] & org_teams
  end

  def issue_remove_member(user)
    teams_list = teams_for_user_in_org(user).map do |team|
      "- [#{team.name}](#{url_org_team(team)})"
    end.join("\n")

    Issue.new(
      'Should be removed?',
      "❓Remove #{user.name} / #{user.login} from #{org.name} organization?",
      <<~BODY
        Should [#{user.name} (`#{user.login}`)](#{user.html_url}) be removed from the #{org.name} Github organization?

        They are currently a member of the organization wich gives them `#{org.default_repository_permission}` access to every repo in the organization.

        Perhaps they should be a moved to an outside collaborator instead.

        Modify memberships here: [List of organization members](#{url_org_people})

        Currently on teams:

        #{teams_list}
      BODY
    )
  end
end

require 'slim'
template = Slim::Template.new('index.html.slim')
path = '/tmp/github-audit.html'
File.open(path, 'w') { |f| f.print template.render(template_helpers_and_data) }
`open #{path}`

require 'pry'; binding.pry
