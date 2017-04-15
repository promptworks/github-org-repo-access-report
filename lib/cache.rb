require 'moneta'

class Cache
  def initialize(*moneta_args)
    @store = Moneta.build do
      use :Transformer, key: :marshal, value: :marshal

      use :Cache do
        adapter { adapter(*moneta_args) }
        cache { adapter :Memory }
      end
    end
  end

  def call(*key, &block)
    if cached_value = @store[key]
      cached_value.first
    else
      yield.tap do |value|
        @store[key] = [value]
      end
    end
  end
end
