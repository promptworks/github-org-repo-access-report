require 'sinatra'
require 'dotenv/load'
require 'octokit'
require 'tqdm'
require 'set'
require 'nokogiri'

require_relative 'lib/cached_octokit'

Octokit.configure do |config|
  config.login = ENV.fetch('GITHUB__LOGIN')
  config.password = ENV.fetch('GITHUB__PERSONAL_ACCESS_TOKEN')
  config.auto_paginate = true
end
octokit = CachedOctokit.new(Octokit, moneta: [:Sqlite, file: 'octokit_cache.sqlite3'])

module Enumerable
  def by
    each_with_object({}) do |item, hash|
      hash[yield(item)] = item
    end
  end
end

helpers do
  def permission_details(permission)
    case permission.to_s
    when 'admin' then { name: 'admin', label: 'label-danger',  order: 0, emoji: '🔴' }
    when 'push'  then { name: 'write', label: 'label-warning', order: 1, emoji: '🌕' }
    when 'pull'  then { name: 'read',  label: 'label-info',    order: 2, emoji: '🔵' }
    else raise "Don't know permission #{permission.inspect}"
    end
  end

  def order_for_permission(permission)
    permission_details(permission).fetch(:order)
  end

  def teams_for_repo(repo)
    @teams_per_repo[repo.full_name].sort_by{|team| order_for_permission(team.permission) }
  end

  def teams_for_user_on_repo(user, repo)
    repo_team_ids = teams_for_repo(repo).map(&:id).to_set

    @teams_per_user_login[user.login].select do |team|
      repo_team_ids.include? team.id
    end
  end

  def url_repo_collaboration(repo)
    "#{repo.html_url}/settings/collaboration"
  end

  def url_org_team(team)
    "https://github.com/orgs/#{@org.login}/teams/#{team.slug}"
  end

  def url_org_people
    "https://github.com/orgs/#{@org.login}/people"
  end

  def url_org_member_settings
    "https://github.com/organizations/#{@org.login}/settings/member_privileges"
  end

  def teams_for_user_in_org(user)
    @teams_per_user_login[user.login] & @org_teams
  end
end

class LazyDelegator < BasicObject
  def initialize(block, count)
    @block = block
    @count = count
  end

  def __target__
    @target ||= begin
                  $stdout.puts "Lazy: #{@count}"
                  @block.call
                end
  end

  def method_missing(*args, &block)
    if block
      __target__.public_send(*args, &block)
    else
      __target__.public_send(*args)
    end
  end

  def respond_to_missing?(*args)
    __target__.respond_to?(*args)
  end
end

def lazily(&block)
  @lazily_count ||= 0
  @lazily_count += 1

  LazyDelegator.new(block, @lazily_count)
end

get '/' do
  @org_id = ENV.fetch('GITHUB__ORG_ID')

  @org = lazily do
    puts 'Fetching org...'
    octokit.org(@org_id)
  end

  @org_members = lazily do
    puts 'Fetching org members...'
    octokit.org_members(@org_id)
  end
  @org_member_logins = lazily { @org_members.map(&:login).to_set }

  @org_memberships = lazily do
    puts 'Fetching org memberships...'
    @org_members.each.with_progress.map do |user|
      octokit.organization_membership(@org_id, user: user.login)
    end
  end

  # https://developer.github.com/v3/orgs/members/#add-or-update-organization-membership
  @possible_organization_member_roles = %w[ admin member ]

  @org_admin_logins = lazily do
    @org_memberships
      .select{ |membership| membership.role == 'admin' }
      .map { |membership| membership.user.login }
  end

  # https://developer.github.com/v3/teams/members/#parameters
  @team_permission_options = %w[ member maintainer ]

  # https://developer.github.com/v3/orgs/#input
  @organization_default_permission_options = {
    'admin' => { admin: true,  push: true,  pull: true  },
    'write' => { admin: false, push: true,  pull: true  },
    'read'  => { admin: false, push: false, pull: true  },
    'none'  => { admin: false, push: false, pull: false },
  }

  @default_org_member_repo_permissions = lazily do
    @organization_default_permission_options.fetch(@org.default_repository_permission)
  end

  @org_teams = lazily do
    puts 'Fetching teams...'
    octokit.org_teams(@org_id)
  end

  @repos = lazily do
    puts 'Fetching repos...'
    octokit.org_repos(@org_id, type: 'private')
  end

  raw_collaborations = lazily do
    puts 'Fetching collaborators...'
    @repos.each.with_progress.map do |repo|
      [repo.full_name, octokit.collaborators(repo.full_name)]
    end
  end

  is_legitimate_admin = -> (collab) do
    @org_admin_logins.include?(collab.login) && collab.permissions[:admin]
  end

  is_org_member_with_default_permissions = -> (collab) do
    @org_member_logins.include?(collab.login) &&
      collab.permissions.to_hash == @default_org_member_repo_permissions
  end

  @collaborations = lazily do
    raw_collaborations.map do |repo_full_name, collabs|
      unexpected_collabs = collabs.reject do |collab|
        is_legitimate_admin.(collab) || is_org_member_with_default_permissions.(collab)
      end

      [repo_full_name, unexpected_collabs]
    end.to_h
  end

  @teams_per_repo = lazily do
    puts 'Fetching teams...'
    @repos.each.with_progress.map do |repo|
      [repo.full_name, octokit.repo_teams(repo.full_name)]
    end.to_h
  end

  @members_per_team = lazily do
    puts 'Fetching team members...'
    @org_teams.each.with_progress.map do |team|
      [team, octokit.team_members(team.id)]
    end.to_h
  end

  @users = lazily do
    loginables = [
      *raw_collaborations.flat_map(&:last),
      *@org_members,
      *@members_per_team.flat_map(&:last),
    ]

    puts 'Fetching user info...'
    loginables
      .map(&:login)
      .uniq
      .each.with_progress
      .map { |login| octokit.user(login) }
  end

  @teams_per_user_login = lazily do
    @members_per_team
      .each_with_object(Hash.new{[]}) do |(team, members), hash|
        members.each do |member|
          hash[member.login] += [team]
        end
      end
  end

  @users_by_login = lazily { @users.by(&:login) }

  content_type 'text/xml'
  xml = slim :'index.xml'
  # Nokogiri::XML(xml)
  # require 'pry'; binding.pry
  # jbuilder :'index'
end
