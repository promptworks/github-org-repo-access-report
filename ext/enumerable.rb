module Enumerable
  def by
    each_with_object({}) do |item, hash|
      hash[yield(item)] = item
    end
  end
end

