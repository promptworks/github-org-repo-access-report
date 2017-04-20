require 'sinatra'
require 'dotenv/load'
require 'octokit'
require 'tqdm'
require 'set'
require_relative 'lib/cached_octokit'

Octokit.configure do |config|
  config.login = ENV.fetch('GITHUB__LOGIN')
  config.password = ENV.fetch('GITHUB__PERSONAL_ACCESS_TOKEN')
  config.auto_paginate = true
end
octokit = CachedOctokit.new(Octokit, moneta: [:GDBM, file: 'octokit_cache.gdb'])


Issue = Struct.new :type_name, :title, :body do
  def body_html
    "<pre>#{body}</pre>"
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

  def highest_permission(permissions)
    %i[admin push pull].detect {|p| permissions.to_h.fetch(p) }
  end

  def highest_permission_details(permissions)
    permission_details(highest_permission(permissions))
  end

  def label_for_permission(permission)
    permission_details(permission).fetch(:label)
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

  def teams_for_user_in_org(user)
    @teams_per_user_login[user.login] & @org_teams
  end

  def issue_remove_member(user)
    teams_list = teams_for_user_in_org(user).map do |team|
      "- [#{team.name}](#{url_org_team(team)})"
    end.join("\n")

    Issue.new(
      'Should be removed?',
      "❓Remove #{user.name} / #{user.login} from #{@org.name} organization?",
      <<~BODY
        Should [#{user.name} (`#{user.login}`)](#{user.html_url}) be removed from the #{@org.name} Github organization?

        They are currently a member of the organization wich gives them `#{@org.default_repository_permission}` access to every repo in the organization.

        Perhaps they should be a moved to an outside collaborator instead.

        Modify memberships here: [List of organization members](#{url_org_people})

        Currently on teams:

        #{teams_list}

        We can discuss on this card.
      BODY
    )
  end

  def issue_archive_repo(repo)
    Issue.new(
      'Archive repo?',
      "❓Archive #{repo.name} repo?",
      <<~BODY
        Should we archive the [#{repo.name} repo](#{repo.html_url})?

        Is it still needed? If so, should we transfer it to another owner?

        Our usual archival method is to move it to Bitbucket so it doesn't cost us money.

        We can discuss on this card.
      BODY
    )
  end

  def md_permission_label(permission_name)
    permission = permission_details(permission_name)
    "#{permission.fetch(:emoji)} #{permission.fetch(:name)}"
  end

  def issue_delegate_audit(repo, repo_teams, collaborators)
    repo_teams_list = repo_teams.map do |team|
      "- [#{team.name}](#{url_org_team(team)}) #{md_permission_label(team.permission)}"
    end.join("\n")

    collabs_list = collaborators.map do |collaborator|
      user = @users_by_login[collaborator.login]

      teams = teams_for_user_on_repo(user, repo)

      teams_list = if teams.any?
                     teams.map{|team| "*#{team.name}*" }.join(', ')
                   else
                     "*None*"
                   end

      permission_md = md_permission_label(highest_permission(collaborator.permissions))
      <<~USER

        ---

        ## #{user.name || user.login}
        [#{user.login}](#{user.html_url}) — #{permission_md}

        Teams: #{teams_list}
      USER
    end.join("\n")

    Issue.new(
      'Delegate audit',
      "Confirm #{repo.name} repo collaborators",
      <<~BODY
        Can you confirm that the following users should have access to the [#{repo.name} repo](#{repo.html_url}) and that their access level is correct?

        Also, note, that every [PromptWorks organization member](#{url_repo_collaboration(repo)}) has write access to this repo.

        If you are an admin, you can [see the access permissions here].

        We can discuss on this card.

        # Teams
        [View on Github](#{url_repo_collaboration(repo)})

        #{repo_teams.any? ? repo_teams_list : '*None*'}

        # Collaborators
        #{collaborators.any? ? collabs_list : '*None*'}

      BODY
    )
  end

  def issue_button(issue)
    slim :'_issue_button.html', locals: { issue: issue }
  end
end

get '/' do
  @org_owner_logins = ENV.fetch('GITHUB__ORG_OWNER_LOGINS', '').split(/\s*,\s*/).to_set
  @org_id = ENV.fetch('GITHUB__ORG_ID')

  puts 'Fetching org...'
  @org = octokit.org(@org_id)

  @default_org_member_repo_permissions = case @org.default_repository_permission
                                         when 'admin' then { admin: true, push: true, pull: true }
                                         when 'write' then { admin: false, push: true, pull: true }
                                         when 'read'  then { admin: false, push: false, pull: true }
                                         when 'none'  then { admin: false, push: false, pull: false }
                                         else raise "I don't understand #{@org.default_repository_permission.inspect}"
                                         end

  puts 'Fetching teams...'
  @org_teams = octokit.org_teams(@org_id)

  puts 'Fetching repos...'
  @repos = octokit.org_repos(@org_id, type: 'private')

  puts 'Fetching org members...'
  @org_members = octokit.org_members(@org_id)
  @org_member_logins = @org_members.map(&:login).to_set

  puts 'Fetching collaborators...'
  raw_collaborations = @repos.each.with_progress.map do |repo|
    [repo.full_name, octokit.collaborators(repo.full_name)]
  end

  is_legitimate_admin = -> (collab) do
    @org_owner_logins.include?(collab.login) && collab.permissions[:admin]
  end

  is_org_member_with_default_permissions = -> (collab) do
    @org_member_logins.include?(collab.login) &&
      collab.permissions.to_hash == @default_org_member_repo_permissions
  end

  @collaborations = raw_collaborations.map do |repo_full_name, collabs|
    unexpected_collabs = collabs.reject do |collab|
      is_legitimate_admin.(collab) || is_org_member_with_default_permissions.(collab)
    end

    [repo_full_name, unexpected_collabs]
  end.to_h

  puts 'Fetching teams...'
  @teams_per_repo = @repos.each.with_progress.map do |repo|
    [repo.full_name, octokit.repo_teams(repo.full_name)]
  end.to_h

  puts 'Fetching team members...'
  @members_per_team = @org_teams.each.with_progress.map do |team|
    [team, octokit.team_members(team.id)]
  end.to_h

  puts 'Fetching user info...'
  loginables = raw_collaborations.flat_map(&:last) + @org_members + @members_per_team.flat_map(&:last)
  @users = loginables.map(&:login).uniq.each.with_progress.map do |login|
    octokit.user(login)
  end

  @teams_per_user_login = @members_per_team.each_with_object(Hash.new{|hash, key| hash[key] = []}) do |(team, members), hash|
    members.each do |member|
      hash[member.login] << team
    end
  end

  @users_by_login = @users.map { |user| [user.login, user] }.to_h

  slim :'index.html'
end
