module KVStore
  def store
    @_map ||= {}
  end

  def pointer()
    store
  end

  def put(k, v)
    store[k] = v
    self
  end

  def respond_to_missing?(method)
    return true if store.respond_to?(method)
    super
  end

  def method_missing(method, *args, &block)
    return store.send(method, *args, &block) if store.respond_to?(method)
    super
  end
end