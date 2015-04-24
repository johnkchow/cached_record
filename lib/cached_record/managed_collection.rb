class CachedRecord
  class ManagedCollection
    attr_reader :store, :mapper, :sort_key

    def initialize(store:, mapper:, sort_key:)
      @store = store
      @mapper = mapper
      @sort_key = sort_key
    end

    def values(offset: 0, limit:)
      items = store.items(offset: offset, limit: limit)
      items.map { |i| mapper.from_raw_data(i) }
    end

    def insert(id, object, name = nil)
      mapped_model = mapper.map_data_object(object, name: name)

      insert_mapped_model(mapped_model)
    end

    def update_or_insert(id, object, name = nil)
      mapped_model = mapper.map_data_object(object, name: name)

      update_mapped_model(mapped_model) || insert_mapped_model(mapped_model)
    end

    def update_model(model)
      # return if the model hasn't been modified
      #
      # check hash to see where the block is loaded
      # get the raw attributes for the model
      # go into the block and update the appropriate item
      #   check block hash to get model index; else build up hash
      #   overwrite the element in array with the new attributes
      # persist the block
      #   serialize all block data
      #   write to key
    end

    def update(id, object, name = nil)
      mapped_model = mapper.map_data_object(object, name: name)

      update_mapped_model(mapped_model)
    end

    def add(id, object, type = nil)
    end

    protected

    def update_mapped_model(mapped_model)
      return unless managed_item = find_store_item_by_id_type(id, mapped_model.type)
      managed_item.value = mapped_model.to_hash
      managed_item.save!
      mapped_model
    end

    def insert_mapped_model(mapped_model)
      meta_key = model_meta_key(mapped_model)
      key = model_sort_key(mapped_model)

      store.insert(meta_key, key, mapped_model.to_hash)
      mapped_model
    end

    def model_meta_key(mapped_model)
      {
        id: mapped_model.attribute(:id),
        type: mapped_model.type
      }
    end

    def model_sort_key(mapped_model)
      mapped_model.attribute(sort_key)
    end

    # TODO: get the sort key, do binary search
    def find_store_item_by_id_type(id, type)
      store.find_by_meta {|meta| meta[:id] == id && meta[:type] == type}
    end
  end
end
