A tool to generate a report of who has access to each of your private repos on GitHub.

# Setup

1. First:

        bundle install

2. Create a `.env` with these variables

    - The id of your organization

            GITHUB__ORG_ID="promptworks"

    - A GitHub username and personal access token ([add one here](https://github.com/settings/tokens)) of an account that has `owner` privileges in the GitHub organization

            GITHUB__LOGIN="nicholaides"
            GITHUB__PERSONAL_ACCESS_TOKEN="abcXYZ"

    - A comma separated list of owners.
    The purpose of this is to keep these people from being listed as admins on every single repo.
    That's noisy and not helpful.

            GITHUB__ORG_OWNER_LOGINS="nicholaides,bobbarker,stevensegal"

3. Run it

    Run `shotgun app.rb` to start a Sinatra app server on [http://127.0.0.1:9393/](http://127.0.0.1:9393/) to serve up the report.

    The first time you run it, it will take a while to download all the info from Github.
    This is normal.
    It caches all the GitHub data in a file called `octokit_cache.gdb`

4. Repeat

    For subsequent audits, or if you changed stuff and want fresh data, delete the `octokit_cache.gdb` file and reload the page.
