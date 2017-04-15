require_relative 'cache'

class CachedOctokit
  def initialize(octokit, moneta: :Memory)
    @octokit = octokit
    @cache = Cache.new(*moneta)
  end

  def method_missing(*args)
    @cache.call(*args) do
      @octokit.public_send(*args)
    end
  end
end
