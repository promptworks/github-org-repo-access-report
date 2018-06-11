require 'moneta'

class Cache
  def initialize(*moneta_args)
    @store = Moneta.build do
      use :Transformer, key: :marshal, value: :marshal
      adapter(*moneta_args)
      # use :Cache do
      #   # Use in-memory cache as well, so that if we make the same call more
      #   # than once during the process, we don't even need to go to the disk
      #   cache { adapter :Memory }
      #
      #   adapter { adapter(*moneta_args) }
      # end
    end
  end

  def call(*key)
    key = JSON.load(JSON.dump(key))

    if value = @store[key]
      $stderr.puts "Cache hit: #{key}"
      value
    else
      $stderr.puts "Cache miss: #{key}"
      @store[key] = yield
    end
  end
end
