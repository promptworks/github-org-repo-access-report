require 'dotenv/load'
require 'octokit'
require 'tqdm'
require 'set'
require 'active_support'
require 'faraday-http-cache'
require 'memoist'

require_relative 'lib/cached_octokit'
require_relative 'ext/enumerable'

Octokit.middleware = Faraday::RackBuilder.new do |builder|
  builder.use Faraday::HttpCache,
    serializer: Marshal,
    shared_cache: false,
    store: ActiveSupport::Cache.lookup_store(:memory_store)
  builder.use Octokit::Response::RaiseError
  builder.adapter Faraday.default_adapter
end

@octokit = CachedOctokit.new(Octokit, moneta: [:LevelDB, dir: 'build/cache/leveldb'])

REPO_PERMISSION_LEVELS = %w[ admin push pull ]

# https://developer.github.com/v3/orgs/#input
ORGANIZATION_DEFAULT_PERMISSION_OPTIONS = {
  'admin' => { admin: true,  push: true,  pull: true  },
  'write' => { admin: false, push: true,  pull: true  },
  'read'  => { admin: false, push: false, pull: true  },
  'none'  => { admin: false, push: false, pull: false },
}

# https://developer.github.com/v3/teams/members/#parameters
TEAM_PERMISSION_OPTIONS = %w[ member maintainer ]

# https://developer.github.com/v3/orgs/members/#add-or-update-organization-membership
POSSIBLE_ORGANIZATION_MEMBER_ROLES = %w[ admin member ]

def order_for_permission(permission)
  REPO_PERMISSION_LEVELS.index(permission) or raise "Could not find permission #{permission.inspect}"
end

extend Memoist

memoize def teams_for_repo(repo)
  teams_per_repo[repo.full_name].sort_by{|team| order_for_permission(team.permission) }
end

memoize def teams_for_user_on_repo(user, repo)
  repo_team_ids = teams_for_repo(repo).map(&:id).to_set

  teams_per_user_login[user.login].select do |team|
    repo_team_ids.include? team.id
  end
end

memoize def url_repo_collaboration(repo)
  "#{repo.html_url}/settings/collaboration"
end

memoize def url_org_team(team)
  "https://github.com/orgs/#{org.login}/teams/#{team.slug}"
end

memoize def url_org_people
  "https://github.com/orgs/#{org.login}/people"
end

memoize def url_org_member_settings
  "https://github.com/organizations/#{org.login}/settings/member_privileges"
end

memoize def teams_for_user_in_org(user)
  teams_per_user_login[user.login] & org_teams
end

memoize def org_id
  ENV.fetch('GITHUB__ORG_ID')
end

memoize def org
  puts 'Fetching org...'
  @octokit.org(org_id)
end

memoize def org_members
  puts 'Fetching org members...'
  @octokit.org_members(org_id)
end

memoize def org_member_logins
  org_members.map(&:login).to_set
end

memoize def org_memberships
  puts 'Fetching org memberships...'
  org_members.each.map do |user|
    @octokit.organization_membership(org_id, user: user.login)
  end
end

memoize def org_admin_logins
  org_memberships
    .select{ |membership| membership.role == 'admin' }
    .map { |membership| membership.user.login }
end

memoize def default_org_member_repo_permissions
  ORGANIZATION_DEFAULT_PERMISSION_OPTIONS.fetch(org.default_repository_permission)
end

memoize def org_teams
  puts 'Fetching teams...'
  @octokit.org_teams(org_id)
end

memoize def repos
  puts 'Fetching repos...'
  @octokit.org_repos(org_id, type: 'private')
end

memoize def raw_collaborations
  puts 'Fetching collaborators...'
  repos.each.map do |repo|
    [repo.full_name, @octokit.collaborators(repo.full_name)]
  end
end

memoize def is_legitimate_admin(collab)
  org_admin_logins.include?(collab.login) && collab.permissions[:admin]
end

memoize def is_org_member_with_default_permissions(collab)
  org_member_logins.include?(collab.login) &&
    collab.permissions.to_hash == default_org_member_repo_permissions
end

memoize def collaborations
  raw_collaborations.map do |repo_full_name, collabs|
    unexpected_collabs = collabs.reject do |collab|
      is_legitimate_admin(collab) || is_org_member_with_default_permissions(collab)
    end

    [repo_full_name, unexpected_collabs]
  end.to_h
end

memoize def teams_per_repo
  puts 'Fetching teams...'
  repos.each.map do |repo|
    [repo.full_name, @octokit.repo_teams(repo.full_name)]
  end.to_h
end

memoize def members_per_team
  puts 'Fetching team members...'
  org_teams.each.map do |team|
    [team, @octokit.team_members(team.id)]
  end.to_h
end

memoize def users
  loginables = [
    *raw_collaborations.flat_map(&:last),
    *org_members,
    *members_per_team.flat_map(&:last),
  ]

  puts 'Fetching user info...'
  loginables
    .map(&:login)
    .uniq
    .each
    .map { |login| @octokit.user(login) }
end

memoize def teams_per_user_login
  members_per_team
    .each_with_object(Hash.new{[]}) do |(team, members), hash|
    members.each do |member|
      hash[member.login] += [team]
    end
  end
end

memoize def users_by_login
  users.by(&:login)
end

require 'slim'
require 'tilt'

template = Tilt.new('audit-plan.xml.slim')

out = ARGV.first ? File.open(ARGV.first, 'w') : $stdout
out.print template.render(self)
